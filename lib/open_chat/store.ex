defmodule OpenChat.Store do
  @moduledoc """
  Small CometChat-compatible data store.

  The default backend is in-memory OTP state. If `REDIS_URL` is set, this GenServer
  also persists records into Redis under per-entity keys and index sets. That keeps
  the replacement drop-in while avoiding one large whole-state JSON value.
  """

  use GenServer

  alias OpenChat.{Config, Errors, Time}

  alias OpenChat.Store.{
    Access,
    AuthTokens,
    ConversationView,
    Conversations,
    Entities,
    GroupPermissions,
    Indexes,
    MessageData,
    MessagePermissions,
    PersistenceOps,
    RedisPersistence,
    RequestPlan,
    Retention,
    Unread
  }

  @default_state %{
    "users" => %{},
    "tokens" => %{},
    "groups" => %{},
    "members" => %{},
    "messages" => %{},
    "conversation_messages" => %{},
    "conversation_latest" => %{},
    "thread_messages" => %{},
    "reads" => %{},
    "delivered" => %{},
    "hidden_conversations" => %{},
    "reactions" => %{},
    "blocks" => %{},
    "banned" => %{},
    "message_muids" => %{},
    "user_conversations" => %{},
    "conversation_users" => %{},
    "user_groups" => %{},
    "unread_counts" => %{},
    "presence" => %{},
    "next_id" => 1,
    "next_reaction_id" => 1
  }

  # Public API

  def start_link(opts \\ []) do
    {start_opts, init_opts} = Keyword.split(opts, [:name])

    start_opts =
      case Keyword.fetch(start_opts, :name) do
        {:ok, nil} -> []
        {:ok, _name} -> start_opts
        :error -> [name: __MODULE__]
      end

    GenServer.start_link(__MODULE__, init_opts, start_opts)
  end

  def reset!, do: call(:reset)
  def get_user(uid), do: call({:get_user, to_s(uid)})

  def get_user_for(viewer_uid, uid),
    do: call({:get_user_for, to_s(viewer_uid), to_s(uid)})

  def ensure_user(uid), do: call({:ensure_user, to_s(uid)})
  def upsert_user(attrs), do: call({:upsert_user, attrs})
  def list_users(params \\ %{}), do: call({:list_users, params})
  def delete_user(uid), do: call({:delete_user, to_s(uid)})
  def reactivate_users(uids), do: call({:reactivate_users, uids})
  def block_users(uid, uids), do: call({:block_users, to_s(uid), uids})
  def unblock_users(uid, uids), do: call({:unblock_users, to_s(uid), uids})

  def blocked_users(uid, params \\ %{}),
    do: call({:blocked_users, to_s(uid), params})

  def create_auth_token(uid), do: call({:create_auth_token, to_s(uid)})
  def revoke_auth_token(token), do: call({:revoke_auth_token, token})
  def authenticate(token), do: call({:authenticate, token})
  def me(token), do: call({:me, token})

  def upsert_group(attrs), do: call({:upsert_group, attrs})
  def get_group(guid), do: call({:get_group, to_s(guid)})
  def list_groups(params \\ %{}), do: call({:list_groups, params})
  def delete_group(guid), do: call({:delete_group, to_s(guid)})

  def join_group(guid, uid, params \\ %{}),
    do: call({:join_group, to_s(guid), to_s(uid), params})

  def leave_group(guid, uid),
    do: call({:leave_group, to_s(guid), to_s(uid)})

  def add_group_members(guid, uids, scope \\ "participant", opts \\ []),
    do: call({:add_group_members, to_s(guid), uids, scope, opts})

  def group_members(guid, params \\ %{}),
    do: call({:group_members, to_s(guid), params})

  def groups_for_user(uid), do: call({:groups_for_user, to_s(uid)})

  def set_group_scopes(guid, scope_map, opts \\ []),
    do: call({:set_group_scopes, to_s(guid), scope_map, opts})

  def ban_group_member(guid, uid),
    do: call({:ban_group_member, to_s(guid), to_s(uid)})

  def unban_group_member(guid, uid),
    do: call({:unban_group_member, to_s(guid), to_s(uid)})

  def banned_group_members(guid, params \\ %{}),
    do: call({:banned_group_members, to_s(guid), params})

  def send_message(sender_uid, params, uploads \\ [], opts \\ []),
    do: call({:send_message, to_s(sender_uid), params, uploads, opts})

  def edit_message(uid, id, params, opts \\ []),
    do: call({:edit_message, to_s(uid), to_s(id), params, opts})

  def delete_message(uid, id, opts \\ []),
    do: call({:delete_message, to_s(uid), to_s(id), opts})

  def delete_conversation(conversation_id),
    do: call({:delete_conversation, to_s(conversation_id)})

  def hide_conversation(uid, receiver_type, receiver_id),
    do: call({:hide_conversation, to_s(uid), to_s(receiver_type), to_s(receiver_id)})

  def get_message(id), do: call({:get_message, to_s(id)})

  def get_message_for(uid, id, opts \\ []),
    do: call({:get_message_for, to_s(uid), to_s(id), opts})

  def find_message_by_muid(muid),
    do: call({:find_message_by_muid, to_s(muid)})

  def find_message_by_muid_for(uid, muid, opts \\ []),
    do: call({:find_message_by_muid_for, to_s(uid), to_s(muid), opts})

  def messages_for_user(uid, peer_uid, params \\ %{}),
    do: call({:messages_for_user, to_s(uid), to_s(peer_uid), params})

  def messages_for_group(uid, guid, params \\ %{}),
    do: call({:messages_for_group, to_s(uid), to_s(guid), params})

  def messages_for_thread(uid, parent_id, params \\ %{}),
    do: call({:messages_for_thread, to_s(uid), to_s(parent_id), params})

  def mark_read(uid, receiver_type, receiver_id, message_id),
    do: call({:mark_read, to_s(uid), to_s(receiver_type), to_s(receiver_id), to_s(message_id)})

  def mark_unread(uid, receiver_type, receiver_id, message_id),
    do: call({:mark_unread, to_s(uid), to_s(receiver_type), to_s(receiver_id), to_s(message_id)})

  def mark_delivered(uid, receiver_type, receiver_id, message_id),
    do:
      call({:mark_delivered, to_s(uid), to_s(receiver_type), to_s(receiver_id), to_s(message_id)})

  def unread_counts(uid, params \\ %{}),
    do: call({:unread_counts, to_s(uid), params})

  def conversations(uid, params \\ %{}),
    do: call({:conversations, to_s(uid), params})

  def conversation(uid, receiver_type, receiver_id),
    do: call({:conversation, to_s(uid), to_s(receiver_type), to_s(receiver_id)})

  def add_reaction(uid, id, reaction),
    do: call({:add_reaction, to_s(uid), to_s(id), reaction})

  def remove_reaction(uid, id, reaction),
    do: call({:remove_reaction, to_s(uid), to_s(id), reaction})

  def reactions(uid, id, reaction \\ nil),
    do: call({:reactions, to_s(uid), to_s(id), reaction})

  def call_on(server, request), do: call(server, request)

  defp call(request), do: call(__MODULE__, request)

  defp call(server, request) do
    plan = RequestPlan.build(request)

    if plan.mutating? do
      RedisPersistence.with_locks(plan.locks, fn ->
        GenServer.call(server, {:locked_call, request, plan.refresh}, :infinity)
      end)
    else
      GenServer.call(server, {:cache_call, request, plan.refresh}, :infinity)
    end
  end

  # GenServer

  @impl true
  def init(_opts) do
    state = load_or_seed_state()
    {:ok, state}
  end

  @impl true
  def handle_call({:locked_call, request, refresh}, from, state) do
    request
    |> handle_call(
      from,
      refresh_request_state(request, state, refresh)
    )
  end

  def handle_call({:cache_call, request, refresh}, from, state) do
    request
    |> handle_call(
      from,
      refresh_request_state(request, state, refresh)
    )
  end

  def handle_call(:reset, _from, _state) do
    state = seed_state()
    persist(state)
    {:reply, :ok, state}
  end

  def handle_call({:get_user, uid}, _from, state) do
    {:reply, fetch_public_user(state, nil, uid), state}
  end

  def handle_call({:get_user_for, viewer_uid, uid}, _from, state) do
    {:reply, fetch_public_user(state, viewer_uid, uid), state}
  end

  def handle_call({:ensure_user, uid}, _from, state) do
    {user, state} = ensure_user_in_state(state, uid)
    persist_ops(PersistenceOps.user(state, [user["uid"]]))
    {:reply, {:ok, user}, state}
  end

  def handle_call({:upsert_user, attrs}, _from, state) do
    attrs = stringify_keys(attrs)
    uid = attrs["uid"] || attrs["id"]

    if blank?(uid) do
      {:reply, {:error, Errors.missing("uid")}, state}
    else
      user = normalise_user(Map.merge(Map.get(state["users"], to_s(uid), %{}), attrs))
      state = put_in(state, ["users", user["uid"]], user)
      state = maybe_store_embedded_token(state, user)
      persist_ops(PersistenceOps.user_with_embedded_token(user))
      {:reply, {:ok, public_user(user)}, state}
    end
  end

  def handle_call({:delete_user, uid}, _from, state) do
    case Map.fetch(state["users"], uid) do
      :error ->
        {:reply, {:error, Errors.user_not_found(uid)}, state}

      {:ok, user} ->
        user = user |> Map.put("deactivatedAt", Time.now()) |> Map.put("status", "offline")
        state = put_in(state, ["users", uid], user)
        persist_ops(PersistenceOps.user(state, [uid]))
        {:reply, {:ok, %{"success" => true, "uid" => uid}}, state}
    end
  end

  def handle_call({:reactivate_users, uids}, _from, state) do
    {state, result} =
      List.wrap(uids)
      |> Enum.reduce({state, %{}}, fn uid, {st, acc} ->
        uid = to_s(uid)
        {user, st} = ensure_user_in_state(st, uid)
        user = user |> Map.delete("deactivatedAt") |> Map.put("status", "available")
        st = put_in(st, ["users", uid], user)
        {st, Map.put(acc, uid, %{"success" => true})}
      end)

    persist_ops(PersistenceOps.user(state, Map.keys(result)))
    {:reply, {:ok, %{"success" => result}}, state}
  end

  def handle_call({:list_users, params}, _from, state) do
    params = stringify_keys(params)
    users = state["users"] |> Map.values() |> Enum.map(&public_user/1) |> sort_by_key("uid")
    search = params["searchKey"] || params["search"]

    users =
      if blank?(search),
        do: users,
        else:
          Enum.filter(users, fn u ->
            contains?(u["uid"], search) or contains?(u["name"], search)
          end)

    {:reply, {:ok, paginate(users, params, 30, 100)}, state}
  end

  def handle_call({:block_users, uid, uids}, _from, state) do
    {state, result} =
      List.wrap(uids)
      |> Enum.reduce({state, %{}}, fn blocked_uid, {st, acc} ->
        blocked_uid = to_s(blocked_uid)
        {_user, st} = ensure_user_in_state(st, blocked_uid)
        st = update_in(st, ["blocks", uid], &Map.put(&1 || %{}, blocked_uid, true))
        {st, Map.put(acc, blocked_uid, %{"success" => true, "message" => "User blocked."})}
      end)

    persist_ops(PersistenceOps.user(state, Map.keys(result)) ++ PersistenceOps.blocks(state, uid))
    {:reply, {:ok, result}, state}
  end

  def handle_call({:unblock_users, uid, uids}, _from, state) do
    {state, result} =
      List.wrap(uids)
      |> Enum.reduce({state, %{}}, fn blocked_uid, {st, acc} ->
        blocked_uid = to_s(blocked_uid)
        st = update_in(st, ["blocks", uid], &Map.delete(&1 || %{}, blocked_uid))
        {st, Map.put(acc, blocked_uid, %{"success" => true, "message" => "User unblocked."})}
      end)

    persist_ops(PersistenceOps.blocks(state, uid))
    {:reply, {:ok, result}, state}
  end

  def handle_call({:blocked_users, uid, params}, _from, state) do
    params = stringify_keys(params)
    direction = params["direction"] || "both"
    blocked_by_me = state["blocks"] |> Map.get(uid, %{}) |> Map.keys()

    has_blocked_me =
      state["blocks"]
      |> Enum.filter(fn {_blocker, blocked} -> Map.has_key?(blocked || %{}, uid) end)
      |> Enum.map(fn {blocker, _blocked} -> blocker end)

    uids =
      case direction do
        "blockedByMe" -> blocked_by_me
        "hasBlockedMe" -> has_blocked_me
        _ -> Enum.uniq(blocked_by_me ++ has_blocked_me)
      end

    search = params["searchKey"] || params["search"]

    users =
      uids
      |> Enum.map(fn target_uid ->
        user = state["users"][target_uid] || normalise_user(%{"uid" => target_uid})
        public_user_with_block_state(state, uid, user)
      end)
      |> Enum.filter(fn user ->
        blank?(search) or contains?(user["uid"], search) or contains?(user["name"], search)
      end)
      |> sort_by_key("uid")

    {page, meta} = paginate_with_meta(users, params, 30, 100)
    {:reply, {:ok, page, meta}, state}
  end

  def handle_call({:create_auth_token, uid}, _from, state) do
    {user, state} = ensure_user_in_state(state, uid)
    token = "auth_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    state = put_in(state, ["tokens", token], user["uid"])
    persist_ops(PersistenceOps.user(state, [user["uid"]]) ++ PersistenceOps.token(state, token))
    {:reply, {:ok, me_payload(user, token)}, state}
  end

  def handle_call({:revoke_auth_token, token}, _from, state) do
    state = update_in(state, ["tokens"], &Map.delete(&1 || %{}, token))
    persist_ops([RedisPersistence.delete("tokens", token)])
    {:reply, {:ok, %{"success" => true}}, state}
  end

  def handle_call({:authenticate, token}, _from, state) do
    {reply, state} = authenticate_in_state(state, token)
    persist_ops(PersistenceOps.auth_token(state, token))
    {:reply, reply, state}
  end

  def handle_call({:me, token}, _from, state) do
    case authenticate_in_state(state, token) do
      {{:ok, user}, state} ->
        persist_ops(PersistenceOps.auth_token(state, token))
        {:reply, {:ok, me_payload(user, token)}, state}

      {error, state} ->
        {:reply, error, state}
    end
  end

  def handle_call({:upsert_group, attrs}, _from, state) do
    attrs = stringify_keys(attrs)
    guid = attrs["guid"] || attrs["id"]

    if blank?(guid) do
      {:reply, {:error, Errors.missing("guid")}, state}
    else
      group = normalise_group(Map.merge(Map.get(state["groups"], to_s(guid), %{}), attrs))
      state = put_in(state, ["groups", group["guid"]], group)
      state = ensure_group_member_map(state, group["guid"])

      persist_ops(
        PersistenceOps.group(state, group["guid"]) ++ PersistenceOps.members(state, group["guid"])
      )

      {:reply, {:ok, group}, state}
    end
  end

  def handle_call({:get_group, guid}, _from, state) do
    {:reply, Map.fetch(state["groups"], guid), state}
  end

  def handle_call({:list_groups, params}, _from, state) do
    params = stringify_keys(params)

    groups =
      state["groups"]
      |> Map.values()
      |> Enum.map(&with_members_count(&1, state))
      |> sort_by_key("guid")

    search = params["searchKey"] || params["search"]

    groups =
      if blank?(search),
        do: groups,
        else:
          Enum.filter(groups, fn g ->
            contains?(g["guid"], search) or contains?(g["name"], search)
          end)

    {:reply, {:ok, paginate(groups, params, 30, 100)}, state}
  end

  def handle_call({:delete_group, guid}, _from, state) do
    conv_id = group_conversation_id(guid)
    message_ids = Map.get(state["conversation_messages"], conv_id, [])

    {state, conversation_ops} = delete_conversation_indexes(state, [conv_id])
    {state, message_ops} = delete_message_records(state, message_ids)
    member_uids = state |> get_in(["members", guid]) |> map_keys()
    state = Indexes.remove_group(state, guid)

    state =
      state
      |> update_in(["groups"], &Map.delete(&1 || %{}, guid))
      |> update_in(["members"], &Map.delete(&1 || %{}, guid))
      |> update_in(["banned"], &Map.delete(&1 || %{}, guid))

    persist_ops(
      [
        RedisPersistence.delete("groups", guid),
        RedisPersistence.delete("members", guid),
        RedisPersistence.delete("banned", guid)
      ] ++
        PersistenceOps.user_groups(state, member_uids) ++ conversation_ops ++ message_ops
    )

    notify_membership_changed(member_uids)
    {:reply, {:ok, %{"success" => true, "guid" => guid}}, state}
  end

  def handle_call({:join_group, guid, uid, params}, _from, state) do
    params = stringify_keys(params)

    case Map.fetch(state["groups"], guid) do
      :error ->
        {:reply, {:error, Errors.group_not_found(guid)}, state}

      {:ok, group} ->
        cond do
          group["type"] == "private" ->
            {:reply, {:error, Errors.forbidden("Private groups must add members server-side.")},
             state}

          group["type"] == "password" and to_s(params["password"]) != to_s(group["password"]) ->
            {:reply, {:error, Errors.invalid("password", "Invalid group password.")}, state}

          banned?(state, guid, uid) ->
            {:reply, {:error, Errors.forbidden("You are banned from this group.")}, state}

          transient_group_join?(state, group, guid, uid, params) ->
            {_user, state} = ensure_user_in_state(state, uid)
            state = mark_group_presence(state, guid, uid)

            group =
              state["groups"][guid]
              |> Map.put("hasJoined", true)
              |> Map.put("transient", true)
              |> with_members_count(state)

            persist_ops(PersistenceOps.user(state, [uid]))
            {:reply, {:ok, group}, state}

          group_member_limit_reached?(state, guid, uid) ->
            {:reply, {:error, group_member_limit_error(guid)}, state}

          true ->
            {_user, state} = ensure_user_in_state(state, uid)
            state = add_member_to_state(state, guid, uid, "participant")

            group =
              state["groups"][guid] |> Map.put("hasJoined", true) |> with_members_count(state)

            {action, state} = group_action(state, uid, group, uid, "joined")
            publish_to_group(state, guid, action, except: uid)

            persist_ops(
              PersistenceOps.user(state, [uid]) ++
                PersistenceOps.members(state, guid) ++
                PersistenceOps.user_groups(state, [uid]) ++
                PersistenceOps.unread_counts(state, [uid]) ++
                PersistenceOps.next_id(state)
            )

            notify_membership_changed([uid])
            {:reply, {:ok, group}, state}
        end
    end
  end

  def handle_call({:leave_group, guid, uid}, _from, state) do
    state = remove_member_from_state(state, guid, uid)
    group = state["groups"][guid]

    state =
      if group do
        {action, state} = group_action(state, uid, group, uid, "left")
        publish_to_group(state, guid, action, except: uid)
        state
      else
        state
      end

    persist_ops(
      PersistenceOps.members(state, guid) ++
        PersistenceOps.user_groups(state, [uid]) ++
        PersistenceOps.unread_counts(state, [uid]) ++
        PersistenceOps.next_id(state)
    )

    notify_membership_changed([uid])
    {:reply, {:ok, %{"success" => true}}, state}
  end

  def handle_call({:add_group_members, guid, uids, scope, opts}, _from, state) do
    with {:ok, group} <- Map.fetch(state["groups"], guid),
         :ok <- authorize_group_moderation(state, guid, opts) do
      {state, result, touched_uids} =
        Enum.reduce(List.wrap(uids), {state, %{}, []}, fn uid, {st, acc, touched} ->
          uid = to_s(uid)

          if group_member_limit_reached?(st, guid, uid) do
            error = group_member_limit_error(guid)
            {st, Map.put(acc, uid, member_failure(error)), touched}
          else
            {_user, st} = ensure_user_in_state(st, uid)
            st = add_member_to_state(st, guid, uid, scope || "participant")

            {st, Map.put(acc, uid, %{"success" => true, "message" => "Member added."}),
             [uid | touched]}
          end
        end)

      group = with_members_count(group, state)
      touched_uids = Enum.uniq(touched_uids)

      persist_ops(
        PersistenceOps.user(state, touched_uids) ++
          PersistenceOps.members(state, guid) ++
          PersistenceOps.user_groups(state, touched_uids) ++
          PersistenceOps.unread_counts(state, touched_uids)
      )

      notify_membership_changed(touched_uids)
      {:reply, {:ok, %{"success" => result, "group" => group}}, state}
    else
      :error -> {:reply, {:error, Errors.group_not_found(guid)}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:group_members, guid, params}, _from, state) do
    params = stringify_keys(params)

    case Map.fetch(state["groups"], guid) do
      :error ->
        {:reply, {:error, Errors.group_not_found(guid)}, state}

      {:ok, _group} ->
        scopes =
          params["scope"]
          |> to_s()
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)

        members =
          state["members"]
          |> Map.get(guid, %{})
          |> Enum.filter(fn {_uid, meta} -> scopes == [] or meta["scope"] in scopes end)
          |> Enum.map(fn {uid, meta} ->
            scope = meta["scope"] || "participant"

            state["users"][uid]
            |> Kernel.||(normalise_user(%{"uid" => uid}))
            |> public_user()
            |> Map.merge(meta)
            |> Map.put("role", scope)
            |> Map.put("scope", scope)
          end)
          |> sort_by_key("uid")

        {:reply, {:ok, members}, state}
    end
  end

  def handle_call({:set_group_scopes, guid, scope_map, opts}, _from, state) do
    scope_map = stringify_keys(scope_map || %{})
    state = ensure_group_in_state(state, guid)

    case authorize_group_moderation(state, guid, opts) do
      :ok ->
        assignments = [
          {"participant", scope_map["participants"] || scope_map["members"] || []},
          {"moderator", scope_map["moderators"] || []},
          {"admin", scope_map["admins"] || []},
          {scope_map["scope"] || "participant", scope_map["uids"] || []}
        ]

        {state, touched, failed} =
          Enum.reduce(assignments, {state, [], %{}}, fn {scope, uids}, {st, acc, failed} ->
            Enum.reduce(List.wrap(uids), {st, acc, failed}, fn uid, {st2, acc2, failed2} ->
              uid = to_s(uid)

              if group_member_limit_reached?(st2, guid, uid) do
                {st2, acc2, Map.put(failed2, uid, member_failure(group_member_limit_error(guid)))}
              else
                {_user, st2} = ensure_user_in_state(st2, uid)
                st2 = add_member_to_state(st2, guid, uid, scope)

                {st2, [Entities.member(guid, uid, scope, Time.now()) | acc2], failed2}
              end
            end)
          end)

        first = List.first(Enum.reverse(touched)) || %{"guid" => guid}

        touched_uids = Enum.map(touched, & &1["uid"])

        persist_ops(
          PersistenceOps.group(state, guid) ++
            PersistenceOps.members(state, guid) ++
            PersistenceOps.user(state, touched_uids) ++
            PersistenceOps.user_groups(state, touched_uids) ++
            PersistenceOps.unread_counts(state, touched_uids)
        )

        notify_membership_changed(touched_uids)

        payload =
          %{
            "success" => map_size(failed) == 0,
            "members" => Enum.reverse(touched),
            "failed" => failed
          }
          |> Map.merge(first)

        {:reply, {:ok, payload}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:ban_group_member, guid, uid}, _from, state) do
    state = ensure_group_in_state(state, guid)
    {_user, state} = ensure_user_in_state(state, uid)
    now = Time.now()

    state =
      update_in(state, ["banned", guid], &Map.put(&1 || %{}, uid, Entities.ban(guid, uid, now)))

    state = remove_member_from_state(state, guid, uid)

    persist_ops(
      PersistenceOps.group(state, guid) ++
        PersistenceOps.user(state, [uid]) ++
        PersistenceOps.banned(state, guid) ++
        PersistenceOps.members(state, guid) ++
        PersistenceOps.user_groups(state, [uid]) ++
        PersistenceOps.unread_counts(state, [uid])
    )

    notify_membership_changed([uid])

    {:reply,
     {:ok, %{"success" => true, "message" => "User banned.", "uid" => uid, "guid" => guid}},
     state}
  end

  def handle_call({:unban_group_member, guid, uid}, _from, state) do
    state = update_in(state, ["banned", guid], &Map.delete(&1 || %{}, uid))
    persist_ops(PersistenceOps.banned(state, guid))

    {:reply,
     {:ok, %{"success" => true, "message" => "User unbanned.", "uid" => uid, "guid" => guid}},
     state}
  end

  def handle_call({:banned_group_members, guid, params}, _from, state) do
    params = stringify_keys(params)
    search = params["searchKey"] || params["search"]

    members =
      state["banned"]
      |> Map.get(guid, %{})
      |> Enum.map(fn {uid, meta} ->
        Map.merge(public_user(state["users"][uid] || normalise_user(%{"uid" => uid})), meta)
      end)
      |> Enum.filter(fn user ->
        blank?(search) or contains?(user["uid"], search) or contains?(user["name"], search)
      end)
      |> sort_by_key("uid")
      |> paginate(params, 30, 100)

    {:reply, {:ok, members}, state}
  end

  def handle_call({:groups_for_user, uid}, _from, state) do
    groups =
      state
      |> get_in(["user_groups", uid])
      |> List.wrap()
      |> Enum.map(fn guid -> state["groups"][guid] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&with_members_count(&1, state))

    {:reply, {:ok, groups}, state}
  end

  def handle_call({:send_message, sender_uid, params, uploads, opts}, _from, state) do
    params = stringify_keys(params)

    case build_message(state, sender_uid, params, uploads, opts) do
      {:error, error} ->
        {:reply, {:error, error}, state}

      {:ok, message, state} ->
        {state, retention_ops} = store_message_with_retention(state, message)
        publish_message(state, message)
        persist_ops(PersistenceOps.message_create(state, message) ++ retention_ops)
        {:reply, {:ok, message}, state}
    end
  end

  def handle_call({:edit_message, uid, id, params, opts}, _from, state) do
    params = stringify_keys(params)

    case Map.fetch(state["messages"], id) do
      :error ->
        {:reply, {:error, Errors.message_not_found(id)}, state}

      {:ok, message} ->
        case MessagePermissions.authorize(state, uid, message, :edit, opts) do
          :ok ->
            now = Time.now()
            data = MessageData.merge(message["data"] || %{}, params["data"] || params)

            message =
              message
              |> Map.put("data", enrich_data_entities(state, message, data))
              |> Map.put("editedAt", now)
              |> Map.put("editedBy", uid)
              |> Map.put("updatedAt", now)

            state = put_in(state, ["messages", id], message)
            {action, state} = message_action(state, uid, message, "edited")
            {state, retention_ops} = store_message_with_retention(state, action)
            publish_message(state, action)

            persist_ops(
              [RedisPersistence.put("messages", id, message)] ++
                PersistenceOps.stored_message(state, action) ++
                retention_ops ++ PersistenceOps.next_id(state)
            )

            {:reply, {:ok, action}, state}

          {:error, error} ->
            {:reply, {:error, error}, state}
        end
    end
  end

  def handle_call({:delete_message, uid, id, opts}, _from, state) do
    case Map.fetch(state["messages"], id) do
      :error ->
        {:reply, {:error, Errors.message_not_found(id)}, state}

      {:ok, message} ->
        case MessagePermissions.authorize(state, uid, message, :delete, opts) do
          :ok ->
            now = Time.now()
            original_participants = Unread.participants(state, message)
            state = Unread.message_deleted(state, message)

            message =
              message
              |> Map.put("deletedAt", now)
              |> Map.put("deletedBy", uid)
              |> Map.put("updatedAt", now)

            state = put_in(state, ["messages", id], message)
            {action, state} = message_action(state, uid, message, "deleted")
            {state, retention_ops} = store_message_with_retention(state, action)
            publish_message(state, action)

            persist_ops(
              [RedisPersistence.put("messages", id, message)] ++
                PersistenceOps.stored_message(state, action) ++
                retention_ops ++
                PersistenceOps.unread_counts(state, original_participants) ++
                PersistenceOps.next_id(state)
            )

            {:reply, {:ok, action}, state}

          {:error, error} ->
            {:reply, {:error, error}, state}
        end
    end
  end

  def handle_call({:get_message, id}, _from, state) do
    {:reply, Map.fetch(state["messages"], id), state}
  end

  def handle_call({:get_message_for, uid, id, opts}, _from, state) do
    reply =
      case Map.fetch(state["messages"], id) do
        {:ok, message} ->
          case Access.message(state, uid, message, opts) do
            :ok -> {:ok, message}
            {:error, error} -> {:error, error}
          end

        :error ->
          :error
      end

    {:reply, reply, state}
  end

  def handle_call({:delete_conversation, conversation_id}, _from, state) do
    ids =
      [conversation_id]
      |> Kernel.++(
        if String.starts_with?(conversation_id, "group_"),
          do: [],
          else: [group_conversation_id(conversation_id)]
      )
      |> Enum.uniq()

    {state, ops} = delete_conversation_indexes(state, ids)

    persist_ops(ops)
    {:reply, {:ok, %{"success" => true, "conversationId" => conversation_id}}, state}
  end

  def handle_call({:hide_conversation, uid, receiver_type, receiver_id}, _from, state) do
    case Access.conversation(state, uid, receiver_type, receiver_id) do
      :ok ->
        {state, payload} = Conversations.hide(state, uid, receiver_type, receiver_id, Time.now())
        persist_ops(PersistenceOps.hidden_conversations(state, uid))
        {:reply, {:ok, payload}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:find_message_by_muid, muid}, _from, state) do
    result =
      case get_in(state, ["message_muids", muid]) do
        nil -> nil
        id -> get_in(state, ["messages", to_s(id)])
      end

    {:reply, if(result, do: {:ok, result}, else: :error), state}
  end

  def handle_call({:find_message_by_muid_for, uid, muid, opts}, _from, state) do
    result =
      case get_in(state, ["message_muids", muid]) do
        nil -> nil
        id -> get_in(state, ["messages", to_s(id)])
      end

    reply =
      case result do
        nil ->
          :error

        message ->
          case Access.message(state, uid, message, opts) do
            :ok -> {:ok, message}
            {:error, error} -> {:error, error}
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:messages_for_user, uid, peer_uid, params}, _from, state) do
    conv_id = user_conversation_id(uid, peer_uid)
    messages = ConversationView.messages(state, conv_id, params)
    {:reply, {:ok, messages}, state}
  end

  def handle_call({:messages_for_group, uid, guid, params}, _from, state) do
    if group_read_allowed?(state, guid, uid) do
      conv_id = group_conversation_id(guid)
      messages = ConversationView.messages(state, conv_id, params)
      {:reply, {:ok, messages}, state}
    else
      {:reply, {:error, Errors.not_member(guid)}, state}
    end
  end

  def handle_call({:messages_for_thread, uid, parent_id, params}, _from, state) do
    with {:ok, parent} <- Map.fetch(state["messages"], parent_id),
         :ok <- Access.message(state, uid, parent) do
      ids = Map.get(state["thread_messages"], parent_id, [])

      messages =
        ids
        |> ConversationView.messages_by_ids(state, params)

      {:reply, {:ok, messages}, state}
    else
      :error -> {:reply, {:ok, []}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:mark_read, uid, receiver_type, receiver_id, message_id}, _from, state) do
    case Access.receipt(state, uid, receiver_type, receiver_id, message_id) do
      :ok ->
        {state, payload} =
          Conversations.mark_read(state, uid, receiver_type, receiver_id, message_id, Time.now())

        persist_ops(PersistenceOps.reads(state, uid) ++ PersistenceOps.unread_counts(state, uid))
        {:reply, {:ok, payload}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:mark_delivered, uid, receiver_type, receiver_id, message_id}, _from, state) do
    case Access.receipt(state, uid, receiver_type, receiver_id, message_id) do
      :ok ->
        {state, payload} =
          Conversations.mark_delivered(
            state,
            uid,
            receiver_type,
            receiver_id,
            message_id,
            Time.now()
          )

        persist_ops(PersistenceOps.delivered(state, uid))
        publish_receipt(payload, uid, receiver_type, receiver_id, "delivered")
        {:reply, {:ok, payload}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:mark_unread, uid, receiver_type, receiver_id, message_id}, _from, state) do
    case Access.receipt(state, uid, receiver_type, receiver_id, message_id) do
      :ok ->
        {state, conv_id} =
          Conversations.mark_unread(
            state,
            uid,
            receiver_type,
            receiver_id,
            message_id,
            Time.now()
          )

        conv = ConversationView.build(state, uid, conv_id)
        persist_ops(PersistenceOps.reads(state, uid) ++ PersistenceOps.unread_counts(state, uid))
        {:reply, {:ok, %{"conversation" => conv}}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:unread_counts, uid, params}, _from, state) do
    params = stringify_keys(params)
    receiver_type = params["receiverType"]

    counts =
      ConversationView.ids_for_user(state, uid)
      |> Enum.map(fn conv_id -> {conv_id, Unread.count(state, uid, conv_id)} end)
      |> Enum.filter(fn {_conv_id, count} -> count > 0 end)
      |> Enum.map(fn {conv_id, count} ->
        ConversationView.unread_count_row(state, uid, conv_id, count)
      end)
      |> Enum.filter(fn row -> blank?(receiver_type) or row["entityType"] == receiver_type end)
      |> Enum.filter(fn row ->
        cond do
          not blank?(params["uid"]) ->
            row["entityType"] == "user" and row["entityId"] == to_s(params["uid"])

          not blank?(params["guid"]) ->
            row["entityType"] == "group" and row["entityId"] == to_s(params["guid"])

          true ->
            true
        end
      end)

    {:reply, {:ok, counts}, state}
  end

  def handle_call({:conversations, uid, params}, _from, state) do
    params = stringify_keys(params)
    type = params["conversationType"] || params["type"]

    convs =
      ConversationView.ids_for_user(state, uid)
      |> Enum.map(&ConversationView.build(state, uid, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn conv -> blank?(type) or conv["conversationType"] == type end)
      |> Enum.sort_by(fn conv -> -(get_in(conv, ["lastMessage", "sentAt"]) || 0) end)
      |> paginate(params, 30, 50)

    {:reply, {:ok, convs}, state}
  end

  def handle_call({:conversation, uid, receiver_type, receiver_id}, _from, state) do
    case Access.conversation(state, uid, receiver_type, receiver_id) do
      :ok ->
        conv_id = conversation_id_for(uid, receiver_type, receiver_id)
        {:reply, {:ok, ConversationView.build(state, uid, conv_id)}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:add_reaction, uid, id, reaction}, _from, state) do
    with {:ok, message} <- Map.fetch(state["messages"], id),
         :ok <- Access.message(state, uid, message) do
      reaction = URI.decode(to_s(reaction))
      now = Time.now()
      {reaction_id, state} = take_counter(state, "next_reaction_id")
      user = public_user(state["users"][uid] || normalise_user(%{"uid" => uid}))

      reaction_obj =
        Entities.reaction(%{
          "id" => reaction_id,
          "messageId" => message["id"],
          "reaction" => reaction,
          "uid" => uid,
          "reactedAt" => now,
          "reactedBy" => user
        })

      state =
        update_in(state, ["reactions", id], fn reaction_map ->
          Map.update(reaction_map || %{}, reaction, %{uid => reaction_obj}, fn by_uid ->
            Map.put(by_uid || %{}, uid, reaction_obj)
          end)
        end)

      message = refresh_message_reactions(state, message, uid)
      state = put_in(state, ["messages", id], message)
      publish_reaction(state, message, reaction_obj, "message_reaction_added", uid)

      persist_ops(
        PersistenceOps.reactions(state, id) ++
          [RedisPersistence.put("messages", id, message)] ++
          PersistenceOps.next_reaction_id(state)
      )

      {:reply, {:ok, message}, state}
    else
      :error -> {:reply, {:error, Errors.message_not_found(id)}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:remove_reaction, uid, id, reaction}, _from, state) do
    with {:ok, message} <- Map.fetch(state["messages"], id),
         :ok <- Access.message(state, uid, message) do
      reaction = URI.decode(to_s(reaction))

      reaction_obj =
        get_in(state, ["reactions", id, reaction, uid]) ||
          Entities.reaction(%{
            "messageId" => message["id"],
            "reaction" => reaction,
            "uid" => uid,
            "reactedAt" => Time.now(),
            "reactedBy" => public_user(state["users"][uid] || normalise_user(%{"uid" => uid}))
          })

      state = remove_reaction_from_state(state, id, reaction, uid)

      message = refresh_message_reactions(state, message, uid)
      state = put_in(state, ["messages", id], message)
      publish_reaction(state, message, reaction_obj, "message_reaction_removed", uid)

      persist_ops(
        PersistenceOps.reactions(state, id) ++ [RedisPersistence.put("messages", id, message)]
      )

      {:reply, {:ok, message}, state}
    else
      :error -> {:reply, {:error, Errors.message_not_found(id)}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:reactions, uid, id, reaction}, _from, state) do
    with {:ok, message} <- Map.fetch(state["messages"], id),
         :ok <- Access.message(state, uid, message) do
      rows =
        state
        |> get_in(["reactions", id])
        |> case do
          nil ->
            []

          map when is_binary(reaction) ->
            map |> Map.get(URI.decode(reaction), %{}) |> Map.values()

          map ->
            map |> Map.values() |> Enum.flat_map(&Map.values/1)
        end
        |> Enum.map(fn r -> Map.put(r, "reactedByMe", r["uid"] == uid) end)

      {:reply, {:ok, rows}, state}
    else
      :error -> {:reply, {:error, Errors.message_not_found(id)}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  # Loading/persistence

  defp load_or_seed_state do
    state =
      @default_state
      |> RedisPersistence.load_or_seed(&seed_state/0)
      |> Indexes.rebuild()
      |> Conversations.rebuild_latest()
      |> Unread.rebuild()

    persist_ops(
      PersistenceOps.secondary_indexes(state) ++
        PersistenceOps.conversation_latest(state, Map.keys(state["conversation_latest"])) ++
        PersistenceOps.unread_counts(state, Map.keys(state["unread_counts"]))
    )

    state
  end

  defp persist(state) do
    RedisPersistence.replace_all(state)
  end

  defp persist_ops(ops), do: RedisPersistence.write(ops)

  defp refresh_request_state(request, state, refresh) do
    state = RedisPersistence.refresh_keys(@default_state, state, refresh)

    RedisPersistence.refresh_keys(
      @default_state,
      state,
      RequestPlan.followup_refresh(request, state)
    )
  end

  defp take_counter(state, counter) do
    fallback = max(to_int(state[counter]), 1)
    value = RedisPersistence.take_counter(counter, fallback)
    value = if value < 1, do: fallback, else: value
    {value, Map.put(state, counter, max(fallback, value + 1))}
  end

  defp seed_state do
    users = decode_seed(Config.seed_users_json(), default_users()) |> Enum.map(&normalise_user/1)

    groups =
      decode_seed(Config.seed_groups_json(), default_groups()) |> Enum.map(&normalise_group/1)

    state = @default_state

    state =
      Enum.reduce(users, state, fn user, st ->
        st
        |> put_in(["users", user["uid"]], user)
        |> maybe_store_embedded_token(user)
      end)

    state =
      Enum.reduce(groups, state, fn group, st ->
        st
        |> put_in(["groups", group["guid"]], group)
        |> ensure_group_member_map(group["guid"])
      end)

    Indexes.rebuild(state)
  end

  # Message and conversation helpers

  defp build_message(state, sender_uid, params, uploads, opts) do
    receiver = params["receiver"] || params["receiverId"]
    receiver_type = params["receiverType"] || "user"
    receiver_type = receiver_type |> to_s() |> String.downcase()
    admin? = Keyword.get(opts, :admin?, false)

    state =
      if admin? and receiver_type == "group" and not blank?(receiver),
        do: ensure_group_in_state(state, to_s(receiver)),
        else: state

    cond do
      blank?(receiver) ->
        {:error, Errors.missing("receiver")}

      receiver_type not in ["user", "group"] ->
        {:error, Errors.invalid("receiverType", "receiverType must be user or group.")}

      receiver_type == "group" and not Map.has_key?(state["groups"], to_s(receiver)) ->
        {:error, Errors.group_not_found(receiver)}

      receiver_type == "group" and not admin? and not member?(state, to_s(receiver), sender_uid) ->
        {:error, Errors.not_member(receiver)}

      true ->
        {sender, state} = ensure_user_in_state(state, sender_uid)
        {state, receiver_entity} = ensure_receiver_entity(state, receiver_type, to_s(receiver))
        {id, state} = take_counter(state, "next_id")
        now = Time.now()
        type = params["type"] || MessageData.infer_type(params, uploads)
        category = params["category"] || "message"

        case MessageData.normalise(params, uploads) do
          {:ok, data} ->
            message =
              Entities.message(%{
                "id" => id,
                "muid" => params["muid"],
                "sender" => sender["uid"],
                "receiver" => to_s(receiver),
                "receiverType" => receiver_type,
                "type" => type,
                "category" => category,
                "data" => %{},
                "sentAt" => now,
                "updatedAt" => now,
                "conversationId" => conversation_id_for(sender_uid, receiver_type, receiver),
                "resource" => params["resource"],
                "parentId" => params["parentId"] || params["parentMessageId"],
                "tags" => params["tags"]
              })

            parent_id = params["parentId"] || params["parentMessageId"]

            case Access.parent_message(state, sender_uid, parent_id, message["conversationId"],
                   admin?: admin?
                 ) do
              :ok ->
                data =
                  data
                  |> Map.put_new("reactions", [])
                  |> MessageData.put_entity("sender", "user", public_user(sender))
                  |> MessageData.put_entity("receiver", receiver_type, receiver_entity)

                {:ok, Map.put(message, "data", data), state}

              {:error, error} ->
                {:error, error}
            end

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp store_message_with_retention(state, message) do
    state
    |> store_message_in_state(message)
    |> Retention.trim_group_history(message)
  end

  defp store_message_in_state(state, message) do
    id_key = to_s(message["id"])
    conv_id = message["conversationId"]

    state =
      state
      |> put_in(["messages", id_key], message)
      |> update_in(["conversation_messages", conv_id], fn ids -> (ids || []) ++ [id_key] end)
      |> Indexes.link_message(message)
      |> Conversations.put_latest(message)
      |> Unread.message_created(message)

    if parent_id = message["parentId"] || message["parentMessageId"] do
      update_in(state, ["thread_messages", to_s(parent_id)], fn ids ->
        (ids || []) ++ [id_key]
      end)
    else
      state
    end
  end

  defp enrich_data_entities(state, message, data) do
    sender =
      state["users"][to_s(message["sender"])] || normalise_user(%{"uid" => message["sender"]})

    {_state, receiver_entity} =
      ensure_receiver_entity(state, message["receiverType"], message["receiver"])

    data
    |> Map.put_new("reactions", get_in(message, ["data", "reactions"]) || [])
    |> MessageData.put_entity("sender", "user", public_user(sender))
    |> MessageData.put_entity("receiver", message["receiverType"], receiver_entity)
  end

  defp delete_conversation_indexes(state, conv_ids) do
    {state, %{conversation_ids: conv_ids, touched_user_buckets: touched}} =
      Conversations.delete_indexes(state, conv_ids, [
        "reads",
        "delivered",
        "hidden_conversations",
        "user_conversations",
        "unread_counts"
      ])

    conversation_user_uids =
      conv_ids
      |> Enum.flat_map(fn conv_id -> get_in(state, ["conversation_users", conv_id]) || [] end)
      |> Enum.uniq()

    state = Indexes.remove_conversations(state, conv_ids)

    touched_user_conversation_uids =
      ((touched["user_conversations"] || []) ++ conversation_user_uids)
      |> Enum.uniq()

    ops =
      Enum.map(conv_ids, &RedisPersistence.delete("conversation_messages", &1)) ++
        Enum.map(conv_ids, &RedisPersistence.delete("conversation_latest", &1)) ++
        Enum.map(conv_ids, &RedisPersistence.delete("conversation_users", &1)) ++
        Enum.flat_map(touched["reads"], &PersistenceOps.reads(state, &1)) ++
        Enum.flat_map(touched["delivered"], &PersistenceOps.delivered(state, &1)) ++
        Enum.flat_map(
          touched["hidden_conversations"],
          &PersistenceOps.hidden_conversations(state, &1)
        ) ++
        PersistenceOps.user_conversations(state, touched_user_conversation_uids) ++
        PersistenceOps.unread_counts(
          state,
          ((touched["unread_counts"] || []) ++ conversation_user_uids) |> Enum.uniq()
        )

    {state, ops}
  end

  defp delete_message_records(state, message_ids) do
    messages =
      message_ids
      |> List.wrap()
      |> Enum.map(&to_s/1)
      |> Enum.map(&state["messages"][&1])
      |> Enum.reject(&is_nil/1)

    state = Indexes.remove_messages(state, messages)

    {state, %{message_ids: message_ids, thread_ids: thread_ids}} =
      Conversations.delete_message_records(state, message_ids)

    ops =
      Enum.map(message_ids, &RedisPersistence.delete("messages", &1)) ++
        Enum.map(message_ids, &RedisPersistence.delete("reactions", &1)) ++
        Enum.flat_map(messages, &delete_message_muid_ops/1) ++
        Enum.map(thread_ids, &RedisPersistence.delete("thread_messages", &1))

    {state, ops}
  end

  defp conversation_id_for(uid, receiver_type, receiver),
    do: Conversations.conversation_id_for(uid, receiver_type, receiver)

  defp user_conversation_id(a, b), do: Conversations.user_conversation_id(a, b)

  defp group_conversation_id(guid), do: Conversations.group_conversation_id(guid)

  defp ensure_receiver_entity(state, "user", uid) do
    {user, state} = ensure_user_in_state(state, uid)
    {state, public_user(user)}
  end

  defp ensure_receiver_entity(state, "group", guid) do
    group = state["groups"][guid] || normalise_group(%{"guid" => guid, "name" => guid})
    state = put_in(state, ["groups", guid], group)
    {state, with_members_count(group, state)}
  end

  defp refresh_message_reactions(state, message, current_uid) do
    counts =
      state
      |> get_in(["reactions", to_s(message["id"])])
      |> case do
        nil ->
          []

        reaction_map ->
          reaction_map
          |> Enum.reject(fn {_reaction, by_uid} -> map_size(by_uid) == 0 end)
          |> Enum.map(fn {reaction, by_uid} ->
            %{
              "reaction" => reaction,
              "count" => map_size(by_uid),
              "reactedByMe" => Map.has_key?(by_uid, current_uid)
            }
          end)
      end

    data = (message["data"] || %{}) |> Map.put("reactions", counts)
    Map.put(message, "data", data)
  end

  defp remove_reaction_from_state(state, id, reaction, uid) do
    update_in(state, ["reactions", id], fn reaction_map ->
      reaction_map = reaction_map || %{}
      by_uid = reaction_map |> Map.get(reaction, %{}) |> Map.delete(uid)

      if map_size(by_uid) == 0 do
        Map.delete(reaction_map, reaction)
      else
        Map.put(reaction_map, reaction, by_uid)
      end
    end)
  end

  defp message_action(state, actor_uid, message, action) do
    {id, state} = take_counter(state, "next_id")
    actor = public_user(state["users"][actor_uid] || normalise_user(%{"uid" => actor_uid}))

    receiver_entity =
      elem(ensure_receiver_entity(state, message["receiverType"], message["receiver"]), 1)

    {
      Entities.message(%{
        "id" => id,
        "sender" => actor_uid,
        "receiver" => message["receiver"],
        "receiverType" => message["receiverType"],
        "type" => "message",
        "category" => "action",
        "sentAt" => Time.now(),
        "conversationId" => message["conversationId"],
        "data" => %{
          "action" => action,
          "entities" => %{
            "by" => %{"entityType" => "user", "entity" => actor},
            "for" => %{"entityType" => message["receiverType"], "entity" => receiver_entity},
            "on" => %{"entityType" => "message", "entity" => message}
          }
        }
      }),
      state
    }
  end

  defp group_action(state, actor_uid, group, on_uid, action) do
    {id, state} = take_counter(state, "next_id")
    actor = public_user(state["users"][actor_uid] || normalise_user(%{"uid" => actor_uid}))
    on_user = public_user(state["users"][on_uid] || normalise_user(%{"uid" => on_uid}))

    {
      Entities.message(%{
        "id" => id,
        "sender" => actor_uid,
        "receiver" => group["guid"],
        "receiverType" => "group",
        "type" => "groupMember",
        "category" => "action",
        "sentAt" => Time.now(),
        "conversationId" => group_conversation_id(group["guid"]),
        "data" => %{
          "action" => action,
          "entities" => %{
            "by" => %{"entityType" => "user", "entity" => actor},
            "for" => %{"entityType" => "group", "entity" => group},
            "on" => %{"entityType" => "user", "entity" => on_user}
          }
        }
      }),
      state
    }
  end

  # PubSub helpers

  defp publish_message(state, message) do
    event = %{
      "appId" => Config.app_id(),
      "receiver" => message["receiver"],
      "receiverType" => message["receiverType"],
      "deviceId" => "server",
      "type" => "message",
      "sender" => to_s(message["sender"]),
      "body" => message
    }

    keys = recipient_keys(state, message)
    OpenChat.PubSub.broadcast(keys, event)
  end

  defp publish_reaction(state, message, reaction_obj, action, actor_uid) do
    event = %{
      "appId" => Config.app_id(),
      "receiver" => message["receiver"],
      "receiverType" => message["receiverType"],
      "deviceId" => "server",
      "type" => "reaction",
      "sender" => actor_uid,
      "body" => %{
        "action" => action,
        "id" => reaction_obj["id"],
        "messageId" => message["id"],
        "reaction" => reaction_obj["reaction"],
        "reactedBy" => reaction_obj["reactedBy"],
        "reactedAt" => reaction_obj["reactedAt"]
      }
    }

    OpenChat.PubSub.broadcast(recipient_keys(state, message), event)
  end

  defp publish_receipt(payload, uid, receiver_type, receiver_id, action) do
    event = %{
      "appId" => Config.app_id(),
      "receiver" => receiver_id,
      "receiverType" => receiver_type,
      "deviceId" => "server",
      "type" => "receipts",
      "sender" => uid,
      "body" => %{
        "action" => action,
        "messageId" => payload["messageId"],
        "conversationId" => payload["conversationId"],
        "timestamp" => payload["deliveredAt"] || payload["readAt"]
      }
    }

    targets =
      if receiver_type == "group", do: [{:group, receiver_id}], else: [{:user, receiver_id}]

    OpenChat.PubSub.broadcast(targets, event)
  end

  defp recipient_keys(_state, %{"receiverType" => "user"} = message) do
    sender = to_s(message["sender"])
    receiver = to_s(message["receiver"])
    [{:user, receiver}, {:user, sender}]
  end

  defp recipient_keys(state, %{"receiverType" => "group"} = message) do
    sender = to_s(message["sender"])
    group_recipient_keys(state, to_s(message["receiver"]), except: sender)
  end

  defp publish_to_group(state, guid, action, opts) do
    except = Keyword.get(opts, :except)

    keys = group_recipient_keys(state, guid, except: except)

    event = %{
      "appId" => Config.app_id(),
      "receiver" => guid,
      "receiverType" => "group",
      "deviceId" => "server",
      "type" => "message",
      "sender" => action["sender"],
      "body" => action
    }

    OpenChat.PubSub.broadcast(keys, event)
  end

  defp notify_membership_changed(uids) do
    keys =
      uids
      |> List.wrap()
      |> Enum.map(&to_s/1)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.map(&{:user, &1})

    if keys != [] do
      OpenChat.PubSub.broadcast_system(keys, %{"type" => "membership_changed"})
    end

    :ok
  end

  defp group_recipient_keys(state, guid, opts) do
    except = opts |> Keyword.get(:except) |> to_s()
    members = state["members"] |> Map.get(guid, %{})

    if map_size(members) > Config.group_unread_fanout_limit() do
      [{:group, guid}]
    else
      members
      |> Map.keys()
      |> Enum.reject(&(to_s(&1) == except))
      |> Enum.map(&{:user, &1})
    end
  end

  # Auth/users/groups

  defp authenticate_in_state(state, token) when token in [nil, ""],
    do: {{:error, Errors.no_auth()}, state}

  defp authenticate_in_state(state, token) do
    token = to_s(token)

    cond do
      uid = state["tokens"][token] ->
        user = state["users"][uid] || normalise_user(%{"uid" => uid})
        {{:ok, user}, state}

      Config.accept_uid_tokens?() and String.starts_with?(token, "uid:") ->
        uid = String.replace_prefix(token, "uid:", "")
        {user, state} = ensure_user_in_state(state, uid)
        state = put_in(state, ["tokens", token], user["uid"])
        {{:ok, user}, state}

      String.starts_with?(token, "local.") ->
        authenticate_local_jwt(state, token)

      true ->
        {{:error, Errors.no_auth()}, state}
    end
  end

  defp authenticate_local_jwt(state, token) do
    with {:ok, auth_token} <- AuthTokens.local_jwt_token(token) do
      authenticate_in_state(state, auth_token)
    else
      _ -> {{:error, Errors.no_auth()}, state}
    end
  end

  defp me_payload(user, token) do
    user
    |> public_user()
    |> Map.merge(%{
      "authToken" => token,
      "jwt" => jwt_for(user, token),
      "fat" => token,
      "wsChannel" => "user_#{user["uid"]}",
      "settings" => Config.settings()
    })
  end

  defp jwt_for(user, token) do
    AuthTokens.local_jwt(user["uid"], token)
  end

  defp ensure_user_in_state(state, uid) do
    uid = to_s(uid)

    case state["users"][uid] do
      nil ->
        user = normalise_user(%{"uid" => uid, "name" => uid})
        {user, put_in(state, ["users", uid], user)}

      user ->
        {user, state}
    end
  end

  defp maybe_store_embedded_token(state, %{"authToken" => token, "uid" => uid})
       when is_binary(token) and token != "" do
    put_in(state, ["tokens", token], uid)
  end

  defp maybe_store_embedded_token(state, _), do: state

  defp fetch_public_user(state, viewer_uid, uid) do
    case Map.fetch(state["users"], uid) do
      {:ok, user} -> {:ok, public_user_with_block_state(state, viewer_uid, user)}
      :error -> :error
    end
  end

  defp normalise_user(attrs) do
    Entities.user(attrs)
  end

  defp public_user(user), do: Entities.public_user(user)

  defp public_user_with_block_state(_state, nil, user), do: public_user(user)

  defp public_user_with_block_state(state, viewer_uid, user) do
    user = public_user(user)
    target_uid = user["uid"]

    user
    |> Map.put("blockedByMe", blocked?(state, viewer_uid, target_uid))
    |> Map.put("hasBlockedMe", blocked?(state, target_uid, viewer_uid))
  end

  defp normalise_group(attrs) do
    Entities.group(attrs)
  end

  defp ensure_group_member_map(state, guid), do: update_in(state, ["members", guid], &(&1 || %{}))

  defp ensure_group_in_state(state, guid) do
    if Map.has_key?(state["groups"], guid) do
      ensure_group_member_map(state, guid)
    else
      group =
        normalise_group(%{"guid" => guid, "name" => guid, "type" => "public", "owner" => "system"})

      state
      |> put_in(["groups", guid], group)
      |> ensure_group_member_map(guid)
    end
  end

  defp add_member_to_state(state, guid, uid, scope) do
    previous_count = map_size(get_in(state, ["members", guid]) || %{})

    state
    |> ensure_group_member_map(guid)
    |> clear_group_presence(guid, uid)
    |> Indexes.put_member(guid, uid, scope)
    |> sync_group_unread_after_member_add(guid, uid, previous_count)
  end

  defp remove_member_from_state(state, guid, uid) do
    state
    |> Indexes.remove_member(guid, uid)
    |> Unread.remove_conversation(uid, group_conversation_id(guid))
  end

  defp authorize_group_moderation(_state, _guid, opts) when opts in [nil, []], do: :ok

  defp authorize_group_moderation(state, guid, opts) do
    if Keyword.get(opts, :admin?, false) do
      :ok
    else
      actor_uid = Keyword.get(opts, :actor_uid) || Keyword.get(opts, :uid)

      if GroupPermissions.can_moderate?(state, guid, actor_uid) do
        :ok
      else
        {:error,
         Errors.forbidden(
           "Only group owners, admins, moderators, and coOwners can manage members."
         )}
      end
    end
  end

  defp transient_group_join?(state, group, guid, uid, params) do
    group["type"] == "public" and
      not member?(state, guid, uid) and
      not truthy?(params["durable"]) and
      (truthy?(params["transient"]) or truthy?(params["visitor"]) or
         truthy?(params["asVisitor"]) or Config.public_group_joins_as_visits?())
  end

  defp group_read_allowed?(state, guid, uid) do
    case Map.fetch(state["groups"], guid) do
      :error ->
        false

      {:ok, group} ->
        not banned?(state, guid, uid) and
          (member?(state, guid, uid) or
             (not blank?(uid) and group["type"] == "public" and
                Config.public_group_reads_enabled?()))
    end
  end

  defp group_member_limit_reached?(state, guid, uid) do
    not member?(state, guid, uid) and
      map_size(get_in(state, ["members", guid]) || %{}) >= Config.group_max_members()
  end

  defp group_member_limit_error(guid) do
    Errors.error("ERR_LIMIT_EXCEEDED", "Group #{guid} has reached its member limit.", %{
      "guid" => guid,
      "limit" => Config.group_max_members()
    })
  end

  defp member_failure(error) do
    %{
      "success" => false,
      "code" => error["code"],
      "error" => error["message"],
      "message" => error["message"]
    }
  end

  defp sync_group_unread_after_member_add(state, guid, uid, previous_count) do
    conv_id = group_conversation_id(guid)
    member_count = map_size(get_in(state, ["members", guid]) || %{})

    cond do
      previous_count <= Config.group_unread_fanout_limit() and
          member_count > Config.group_unread_fanout_limit() ->
        clear_group_unread_counts(state, guid)

      member_count > Config.group_unread_fanout_limit() ->
        Unread.remove_conversation(state, uid, conv_id)

      true ->
        Unread.sync(state, uid, conv_id)
    end
  end

  defp clear_group_unread_counts(state, guid) do
    conv_id = group_conversation_id(guid)

    state
    |> get_in(["members", guid])
    |> map_keys()
    |> Enum.reduce(state, fn uid, acc ->
      Unread.remove_conversation(acc, uid, conv_id)
    end)
  end

  defp mark_group_presence(state, guid, uid) do
    now = Time.now()
    presence = Entities.presence(guid, uid, now, Config.group_presence_ttl_seconds())

    update_in(state, ["presence", guid], fn rows ->
      rows
      |> Kernel.||(%{})
      |> Enum.reject(fn {_uid, presence} -> to_int(presence["expiresAt"]) <= now end)
      |> Map.new()
      |> Map.put(uid, presence)
      |> cap_presence()
    end)
  end

  defp clear_group_presence(state, guid, uid) do
    update_in(state, ["presence", guid], fn rows ->
      rows = Map.delete(rows || %{}, uid)
      if rows == %{}, do: nil, else: rows
    end)
  end

  defp cap_presence(rows) do
    limit = Config.group_max_presence()

    if map_size(rows) <= limit do
      rows
    else
      rows
      |> Enum.sort_by(fn {_uid, presence} -> -to_int(presence["lastSeenAt"]) end)
      |> Enum.take(limit)
      |> Map.new()
    end
  end

  defp member?(state, guid, uid), do: Map.has_key?(get_in(state, ["members", guid]) || %{}, uid)

  defp banned?(state, guid, uid), do: Map.has_key?(get_in(state, ["banned", guid]) || %{}, uid)

  defp blocked?(state, blocker_uid, blocked_uid),
    do: get_in(state, ["blocks", blocker_uid, blocked_uid]) == true

  defp with_members_count(group, state) do
    Entities.with_members_count(group, state)
  end

  # Generic helpers

  defp stringify_keys(%{__struct__: _} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_s(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_int(value), do: value |> to_s() |> to_int()

  defp truthy?(value), do: value in [true, 1, "1", "true", "TRUE", "yes", "YES"]
  defp blank?(value), do: value in [nil, "", false]
  defp contains?(a, b), do: String.contains?(String.downcase(to_s(a)), String.downcase(to_s(b)))
  defp clamp(value, lo, hi), do: value |> Kernel.max(lo) |> Kernel.min(hi)

  defp sort_by_key(rows, key), do: Enum.sort_by(rows, &to_s(&1[key]))

  defp map_keys(map) when is_map(map), do: Map.keys(map)
  defp map_keys(_other), do: []

  defp delete_message_muid_ops(message) do
    case to_s(message["muid"]) do
      "" -> []
      muid -> [RedisPersistence.delete("message_muids", muid)]
    end
  end

  defp paginate(rows, params, default_limit, max_limit) do
    params = stringify_keys(params)
    limit = clamp(to_int(params["per_page"] || params["limit"] || default_limit), 1, max_limit)
    page = max(to_int(params["page"] || 1), 1)
    rows |> Enum.drop((page - 1) * limit) |> Enum.take(limit)
  end

  defp paginate_with_meta(rows, params, default_limit, max_limit) do
    params = stringify_keys(params)
    limit = clamp(to_int(params["per_page"] || params["limit"] || default_limit), 1, max_limit)
    page = max(to_int(params["page"] || 1), 1)
    total = length(rows)
    page_rows = rows |> Enum.drop((page - 1) * limit) |> Enum.take(limit)
    total_pages = if total == 0, do: 0, else: ceil(total / limit)

    meta = %{
      "pagination" => %{
        "total" => total,
        "count" => length(page_rows),
        "per_page" => limit,
        "current_page" => page,
        "total_pages" => total_pages
      },
      "cursor" => %{}
    }

    {page_rows, meta}
  end

  defp decode_seed(json, default) do
    case Jason.decode(json || "") do
      {:ok, list} when is_list(list) -> list
      {:ok, map} when is_map(map) -> Map.values(map)
      _ -> default
    end
  end

  defp default_users do
    [
      %{"uid" => "alice", "name" => "Alice Example"},
      %{"uid" => "bob", "name" => "Bob Example"},
      %{"uid" => "carol", "name" => "Carol Example"},
      %{"uid" => "system", "name" => "System"}
    ]
  end

  defp default_groups do
    [
      %{"guid" => "lobby", "name" => "Lobby", "type" => "public", "owner" => "system"}
    ]
  end
end
