defmodule OpenChat.Store do
  @moduledoc """
  Small CometChat-compatible data store.

  The default backend is in-memory OTP state. If `REDIS_URL` is set, this GenServer
  snapshots the whole state into one Redis JSON value after each mutation. That is
  intentionally simple: it keeps the replacement drop-in and easy to audit for AGPL
  use while still allowing durable storage on AWS ElastiCache/Redis.
  """

  use GenServer
  require Logger

  alias OpenChat.{Config, Errors, Time}

  @default_state %{
    "users" => %{},
    "tokens" => %{},
    "groups" => %{},
    "members" => %{},
    "messages" => %{},
    "conversation_messages" => %{},
    "thread_messages" => %{},
    "reads" => %{},
    "reactions" => %{},
    "blocks" => %{},
    "banned" => %{},
    "next_id" => 1,
    "next_reaction_id" => 1
  }

  # Public API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def reset!, do: GenServer.call(__MODULE__, :reset)
  def get_user(uid), do: GenServer.call(__MODULE__, {:get_user, to_s(uid)})

  def get_user_for(viewer_uid, uid),
    do: GenServer.call(__MODULE__, {:get_user_for, to_s(viewer_uid), to_s(uid)})

  def ensure_user(uid), do: GenServer.call(__MODULE__, {:ensure_user, to_s(uid)})
  def upsert_user(attrs), do: GenServer.call(__MODULE__, {:upsert_user, attrs})
  def list_users(params \\ %{}), do: GenServer.call(__MODULE__, {:list_users, params})
  def delete_user(uid), do: GenServer.call(__MODULE__, {:delete_user, to_s(uid)})
  def reactivate_users(uids), do: GenServer.call(__MODULE__, {:reactivate_users, uids})
  def block_users(uid, uids), do: GenServer.call(__MODULE__, {:block_users, to_s(uid), uids})
  def unblock_users(uid, uids), do: GenServer.call(__MODULE__, {:unblock_users, to_s(uid), uids})

  def blocked_users(uid, params \\ %{}),
    do: GenServer.call(__MODULE__, {:blocked_users, to_s(uid), params})

  def create_auth_token(uid), do: GenServer.call(__MODULE__, {:create_auth_token, to_s(uid)})
  def revoke_auth_token(token), do: GenServer.call(__MODULE__, {:revoke_auth_token, token})
  def authenticate(token), do: GenServer.call(__MODULE__, {:authenticate, token})
  def me(token), do: GenServer.call(__MODULE__, {:me, token})

  def upsert_group(attrs), do: GenServer.call(__MODULE__, {:upsert_group, attrs})
  def get_group(guid), do: GenServer.call(__MODULE__, {:get_group, to_s(guid)})
  def list_groups(params \\ %{}), do: GenServer.call(__MODULE__, {:list_groups, params})

  def join_group(guid, uid, params \\ %{}),
    do: GenServer.call(__MODULE__, {:join_group, to_s(guid), to_s(uid), params})

  def leave_group(guid, uid),
    do: GenServer.call(__MODULE__, {:leave_group, to_s(guid), to_s(uid)})

  def add_group_members(guid, uids, scope \\ "participant"),
    do: GenServer.call(__MODULE__, {:add_group_members, to_s(guid), uids, scope})

  def group_members(guid, params \\ %{}),
    do: GenServer.call(__MODULE__, {:group_members, to_s(guid), params})

  def groups_for_user(uid), do: GenServer.call(__MODULE__, {:groups_for_user, to_s(uid)})

  def set_group_scopes(guid, scope_map),
    do: GenServer.call(__MODULE__, {:set_group_scopes, to_s(guid), scope_map})

  def ban_group_member(guid, uid),
    do: GenServer.call(__MODULE__, {:ban_group_member, to_s(guid), to_s(uid)})

  def unban_group_member(guid, uid),
    do: GenServer.call(__MODULE__, {:unban_group_member, to_s(guid), to_s(uid)})

  def banned_group_members(guid, params \\ %{}),
    do: GenServer.call(__MODULE__, {:banned_group_members, to_s(guid), params})

  def send_message(sender_uid, params, uploads \\ [], opts \\ []),
    do: GenServer.call(__MODULE__, {:send_message, to_s(sender_uid), params, uploads, opts})

  def edit_message(uid, id, params),
    do: GenServer.call(__MODULE__, {:edit_message, to_s(uid), to_s(id), params})

  def delete_message(uid, id),
    do: GenServer.call(__MODULE__, {:delete_message, to_s(uid), to_s(id)})

  def delete_conversation(conversation_id),
    do: GenServer.call(__MODULE__, {:delete_conversation, to_s(conversation_id)})

  def get_message(id), do: GenServer.call(__MODULE__, {:get_message, to_s(id)})

  def find_message_by_muid(muid),
    do: GenServer.call(__MODULE__, {:find_message_by_muid, to_s(muid)})

  def messages_for_user(uid, peer_uid, params \\ %{}),
    do: GenServer.call(__MODULE__, {:messages_for_user, to_s(uid), to_s(peer_uid), params})

  def messages_for_group(uid, guid, params \\ %{}),
    do: GenServer.call(__MODULE__, {:messages_for_group, to_s(uid), to_s(guid), params})

  def messages_for_thread(uid, parent_id, params \\ %{}),
    do: GenServer.call(__MODULE__, {:messages_for_thread, to_s(uid), to_s(parent_id), params})

  def mark_read(uid, receiver_type, receiver_id, message_id),
    do:
      GenServer.call(
        __MODULE__,
        {:mark_read, to_s(uid), to_s(receiver_type), to_s(receiver_id), to_s(message_id)}
      )

  def mark_unread(uid, receiver_type, receiver_id, message_id),
    do:
      GenServer.call(
        __MODULE__,
        {:mark_unread, to_s(uid), to_s(receiver_type), to_s(receiver_id), to_s(message_id)}
      )

  def unread_counts(uid, params \\ %{}),
    do: GenServer.call(__MODULE__, {:unread_counts, to_s(uid), params})

  def conversations(uid, params \\ %{}),
    do: GenServer.call(__MODULE__, {:conversations, to_s(uid), params})

  def conversation(uid, receiver_type, receiver_id),
    do:
      GenServer.call(
        __MODULE__,
        {:conversation, to_s(uid), to_s(receiver_type), to_s(receiver_id)}
      )

  def add_reaction(uid, id, reaction),
    do: GenServer.call(__MODULE__, {:add_reaction, to_s(uid), to_s(id), reaction})

  def remove_reaction(uid, id, reaction),
    do: GenServer.call(__MODULE__, {:remove_reaction, to_s(uid), to_s(id), reaction})

  def reactions(uid, id, reaction \\ nil),
    do: GenServer.call(__MODULE__, {:reactions, to_s(uid), to_s(id), reaction})

  # GenServer

  @impl true
  def init(_opts) do
    state = load_or_seed_state()
    {:ok, state}
  end

  @impl true
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
    persist(state)
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
      persist(state)
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
        persist(state)
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

    persist(state)
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

    persist(state)
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

    persist(state)
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
    persist(state)
    {:reply, {:ok, me_payload(user, token)}, state}
  end

  def handle_call({:revoke_auth_token, token}, _from, state) do
    state = update_in(state, ["tokens"], &Map.delete(&1 || %{}, token))
    persist(state)
    {:reply, {:ok, %{"success" => true}}, state}
  end

  def handle_call({:authenticate, token}, _from, state) do
    {reply, state} = authenticate_in_state(state, token)
    persist(state)
    {:reply, reply, state}
  end

  def handle_call({:me, token}, _from, state) do
    case authenticate_in_state(state, token) do
      {{:ok, user}, state} ->
        persist(state)
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
      persist(state)
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

          true ->
            {_user, state} = ensure_user_in_state(state, uid)
            state = add_member_to_state(state, guid, uid, "participant")

            group =
              state["groups"][guid] |> Map.put("hasJoined", true) |> with_members_count(state)

            action = group_action(state, uid, group, uid, "joined")
            publish_to_group(state, guid, action, except: uid)
            persist(state)
            {:reply, {:ok, group}, state}
        end
    end
  end

  def handle_call({:leave_group, guid, uid}, _from, state) do
    state = update_in(state, ["members", guid], fn members -> Map.delete(members || %{}, uid) end)
    group = state["groups"][guid]

    if group do
      action = group_action(state, uid, group, uid, "left")
      publish_to_group(state, guid, action, except: uid)
    end

    persist(state)
    {:reply, {:ok, %{"success" => true}}, state}
  end

  def handle_call({:add_group_members, guid, uids, scope}, _from, state) do
    with {:ok, group} <- Map.fetch(state["groups"], guid) do
      {state, result} =
        Enum.reduce(List.wrap(uids), {state, %{}}, fn uid, {st, acc} ->
          uid = to_s(uid)
          {_user, st} = ensure_user_in_state(st, uid)
          st = add_member_to_state(st, guid, uid, scope || "participant")
          {st, Map.put(acc, uid, %{"success" => true, "message" => "Member added."})}
        end)

      group = with_members_count(group, state)
      persist(state)
      {:reply, {:ok, %{"success" => result, "group" => group}}, state}
    else
      :error -> {:reply, {:error, Errors.group_not_found(guid)}, state}
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

  def handle_call({:set_group_scopes, guid, scope_map}, _from, state) do
    scope_map = stringify_keys(scope_map || %{})
    state = ensure_group_in_state(state, guid)

    assignments = [
      {"participant", scope_map["participants"] || scope_map["members"] || []},
      {"moderator", scope_map["moderators"] || []},
      {"admin", scope_map["admins"] || []},
      {scope_map["scope"] || "participant", scope_map["uids"] || []}
    ]

    {state, touched} =
      Enum.reduce(assignments, {state, []}, fn {scope, uids}, {st, acc} ->
        Enum.reduce(List.wrap(uids), {st, acc}, fn uid, {st2, acc2} ->
          uid = to_s(uid)
          {_user, st2} = ensure_user_in_state(st2, uid)
          st2 = add_member_to_state(st2, guid, uid, scope)

          {st2,
           [
             %{
               "uid" => uid,
               "scope" => normalise_scope(scope),
               "guid" => guid,
               "joinedAt" => Time.now()
             }
             | acc2
           ]}
        end)
      end)

    first = List.first(Enum.reverse(touched)) || %{"guid" => guid}
    persist(state)

    {:reply, {:ok, Map.merge(%{"success" => true, "members" => Enum.reverse(touched)}, first)},
     state}
  end

  def handle_call({:ban_group_member, guid, uid}, _from, state) do
    state = ensure_group_in_state(state, guid)
    {_user, state} = ensure_user_in_state(state, uid)
    now = Time.now()

    state =
      update_in(
        state,
        ["banned", guid],
        &Map.put(&1 || %{}, uid, %{"uid" => uid, "guid" => guid, "bannedAt" => now})
      )

    state = update_in(state, ["members", guid], &Map.delete(&1 || %{}, uid))
    persist(state)

    {:reply,
     {:ok, %{"success" => true, "message" => "User banned.", "uid" => uid, "guid" => guid}},
     state}
  end

  def handle_call({:unban_group_member, guid, uid}, _from, state) do
    state = update_in(state, ["banned", guid], &Map.delete(&1 || %{}, uid))
    persist(state)

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
      state["members"]
      |> Enum.filter(fn {_guid, members} -> Map.has_key?(members, uid) end)
      |> Enum.map(fn {guid, _members} -> state["groups"][guid] end)
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
        id_key = to_s(message["id"])
        conv_id = message["conversationId"]
        state = put_in(state, ["messages", id_key], message)

        state =
          update_in(state, ["conversation_messages", conv_id], fn ids ->
            (ids || []) ++ [id_key]
          end)

        state =
          if parent_id = message["parentId"] || message["parentMessageId"] do
            update_in(state, ["thread_messages", to_s(parent_id)], fn ids ->
              (ids || []) ++ [id_key]
            end)
          else
            state
          end

        publish_message(state, message)
        persist(state)
        {:reply, {:ok, message}, state}
    end
  end

  def handle_call({:edit_message, uid, id, params}, _from, state) do
    params = stringify_keys(params)

    case Map.fetch(state["messages"], id) do
      :error ->
        {:reply, {:error, Errors.message_not_found(id)}, state}

      {:ok, message} ->
        now = Time.now()
        data = merge_message_data(message["data"] || %{}, params["data"] || params)

        message =
          message
          |> Map.put("data", enrich_data_entities(state, message, data))
          |> Map.put("editedAt", now)
          |> Map.put("editedBy", uid)
          |> Map.put("updatedAt", now)

        state = put_in(state, ["messages", id], message)
        action = message_action(state, uid, message, "edited")
        publish_message(state, action)
        persist(state)
        {:reply, {:ok, action}, state}
    end
  end

  def handle_call({:delete_message, uid, id}, _from, state) do
    case Map.fetch(state["messages"], id) do
      :error ->
        {:reply, {:error, Errors.message_not_found(id)}, state}

      {:ok, message} ->
        now = Time.now()

        message =
          message
          |> Map.put("deletedAt", now)
          |> Map.put("deletedBy", uid)
          |> Map.put("updatedAt", now)

        state = put_in(state, ["messages", id], message)
        action = message_action(state, uid, message, "deleted")
        publish_message(state, action)
        persist(state)
        {:reply, {:ok, action}, state}
    end
  end

  def handle_call({:get_message, id}, _from, state) do
    {:reply, Map.fetch(state["messages"], id), state}
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

    state =
      Enum.reduce(ids, state, fn conv_id, st ->
        update_in(st, ["conversation_messages"], &Map.delete(&1 || %{}, conv_id))
      end)

    persist(state)
    {:reply, {:ok, %{"success" => true, "conversationId" => conversation_id}}, state}
  end

  def handle_call({:find_message_by_muid, muid}, _from, state) do
    result = Enum.find(Map.values(state["messages"]), fn m -> to_s(m["muid"]) == muid end)
    {:reply, if(result, do: {:ok, result}, else: :error), state}
  end

  def handle_call({:messages_for_user, uid, peer_uid, params}, _from, state) do
    conv_id = user_conversation_id(uid, peer_uid)
    messages = fetch_messages_from_conversation(state, conv_id, params)
    {:reply, {:ok, messages}, state}
  end

  def handle_call({:messages_for_group, uid, guid, params}, _from, state) do
    if member?(state, guid, uid) do
      conv_id = group_conversation_id(guid)
      messages = fetch_messages_from_conversation(state, conv_id, params)
      {:reply, {:ok, messages}, state}
    else
      {:reply, {:error, Errors.not_member(guid)}, state}
    end
  end

  def handle_call({:messages_for_thread, _uid, parent_id, params}, _from, state) do
    ids = Map.get(state["thread_messages"], parent_id, [])

    messages =
      ids
      |> Enum.map(&state["messages"][&1])
      |> Enum.reject(&is_nil/1)
      |> filter_messages(params)
      |> paginate_messages(params)

    {:reply, {:ok, messages}, state}
  end

  def handle_call({:mark_read, uid, receiver_type, receiver_id, message_id}, _from, state) do
    conv_id = conversation_id_for(uid, receiver_type, receiver_id)
    now = Time.now()

    state =
      update_in(state, ["reads", uid], fn reads ->
        Map.put(reads || %{}, conv_id, %{"messageId" => message_id, "readAt" => now})
      end)

    persist(state)

    {:reply,
     {:ok,
      %{
        "success" => true,
        "conversationId" => conv_id,
        "messageId" => message_id,
        "readAt" => now
      }}, state}
  end

  def handle_call({:mark_unread, uid, receiver_type, receiver_id, message_id}, _from, state) do
    conv_id = conversation_id_for(uid, receiver_type, receiver_id)

    state =
      update_in(state, ["reads", uid], fn reads ->
        Map.put(reads || %{}, conv_id, %{
          "messageId" => previous_message_id(state, conv_id, message_id),
          "readAt" => Time.now()
        })
      end)

    conv = build_conversation(state, uid, conv_id)
    persist(state)
    {:reply, {:ok, %{"conversation" => conv}}, state}
  end

  def handle_call({:unread_counts, uid, params}, _from, state) do
    params = stringify_keys(params)
    receiver_type = params["receiverType"]

    counts =
      all_conversation_ids_for_user(state, uid)
      |> Enum.map(fn conv_id -> {conv_id, unread_count(state, uid, conv_id)} end)
      |> Enum.filter(fn {_conv_id, count} -> count > 0 end)
      |> Enum.map(fn {conv_id, count} -> unread_count_row(state, uid, conv_id, count) end)
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
      all_conversation_ids_for_user(state, uid)
      |> Enum.map(&build_conversation(state, uid, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn conv -> blank?(type) or conv["conversationType"] == type end)
      |> Enum.sort_by(fn conv -> -(get_in(conv, ["lastMessage", "sentAt"]) || 0) end)
      |> paginate(params, 30, 50)

    {:reply, {:ok, convs}, state}
  end

  def handle_call({:conversation, uid, receiver_type, receiver_id}, _from, state) do
    conv_id = conversation_id_for(uid, receiver_type, receiver_id)
    {:reply, {:ok, build_conversation(state, uid, conv_id)}, state}
  end

  def handle_call({:add_reaction, uid, id, reaction}, _from, state) do
    with {:ok, message} <- Map.fetch(state["messages"], id) do
      reaction = URI.decode(to_s(reaction))
      now = Time.now()
      reaction_id = state["next_reaction_id"]
      user = public_user(state["users"][uid] || normalise_user(%{"uid" => uid}))

      reaction_obj = %{
        "id" => reaction_id,
        "messageId" => message["id"],
        "reaction" => reaction,
        "uid" => uid,
        "reactedAt" => now,
        "reactedBy" => user
      }

      state =
        update_in(state, ["reactions", id], fn reaction_map ->
          Map.update(reaction_map || %{}, reaction, %{uid => reaction_obj}, fn by_uid ->
            Map.put(by_uid || %{}, uid, reaction_obj)
          end)
        end)

      state = Map.put(state, "next_reaction_id", reaction_id + 1)
      message = refresh_message_reactions(state, message, uid)
      state = put_in(state, ["messages", id], message)
      publish_reaction(state, message, reaction_obj, "message_reaction_added", uid)
      persist(state)
      {:reply, {:ok, message}, state}
    else
      :error -> {:reply, {:error, Errors.message_not_found(id)}, state}
    end
  end

  def handle_call({:remove_reaction, uid, id, reaction}, _from, state) do
    with {:ok, message} <- Map.fetch(state["messages"], id) do
      reaction = URI.decode(to_s(reaction))

      reaction_obj =
        get_in(state, ["reactions", id, reaction, uid]) ||
          %{
            "messageId" => message["id"],
            "reaction" => reaction,
            "uid" => uid,
            "reactedAt" => Time.now(),
            "reactedBy" => public_user(state["users"][uid] || normalise_user(%{"uid" => uid}))
          }

      state =
        update_in(state, ["reactions", id], fn reaction_map ->
          Map.update(reaction_map || %{}, reaction, %{}, fn by_uid ->
            Map.delete(by_uid || %{}, uid)
          end)
        end)

      message = refresh_message_reactions(state, message, uid)
      state = put_in(state, ["messages", id], message)
      publish_reaction(state, message, reaction_obj, "message_reaction_removed", uid)
      persist(state)
      {:reply, {:ok, message}, state}
    else
      :error -> {:reply, {:error, Errors.message_not_found(id)}, state}
    end
  end

  def handle_call({:reactions, uid, id, reaction}, _from, state) do
    rows =
      state
      |> get_in(["reactions", id])
      |> case do
        nil -> []
        map when is_binary(reaction) -> map |> Map.get(URI.decode(reaction), %{}) |> Map.values()
        map -> map |> Map.values() |> Enum.flat_map(&Map.values/1)
      end
      |> Enum.map(fn r -> Map.put(r, "reactedByMe", r["uid"] == uid) end)

    {:reply, {:ok, rows}, state}
  end

  # Loading/persistence

  defp load_or_seed_state do
    case Config.redis_url() do
      nil ->
        seed_state()

      "" ->
        seed_state()

      url ->
        case Redix.start_link(url, name: OpenChat.Redis) do
          {:ok, _pid} ->
            case Redix.command(OpenChat.Redis, ["GET", Config.redis_snapshot_key()]) do
              {:ok, nil} ->
                state = seed_state()
                persist(state)
                state

              {:ok, json} ->
                Jason.decode!(json)

              {:error, reason} ->
                Logger.warning("Redis snapshot load failed: #{inspect(reason)}; using seeds")
                seed_state()
            end

          {:error, reason} ->
            Logger.warning("Redis connection failed: #{inspect(reason)}; using in-memory store")
            seed_state()
        end
    end
  end

  defp persist(state) do
    if Process.whereis(OpenChat.Redis) do
      Redix.command(OpenChat.Redis, ["SET", Config.redis_snapshot_key(), Jason.encode!(state)])
    end

    :ok
  rescue
    e ->
      Logger.warning("Redis snapshot persist failed: #{Exception.message(e)}")
      :ok
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

    Enum.reduce(groups, state, fn group, st ->
      st
      |> put_in(["groups", group["guid"]], group)
      |> ensure_group_member_map(group["guid"])
    end)
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
        id = state["next_id"]
        now = Time.now()
        type = params["type"] || infer_type(params, uploads)
        category = params["category"] || "message"
        data = normalise_message_data(params, uploads)

        message = %{
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
          "resource" => params["resource"]
        }

        message =
          message
          |> maybe_put("parentId", params["parentId"] || params["parentMessageId"])
          |> maybe_put("tags", params["tags"])

        data =
          data
          |> Map.put_new("reactions", [])
          |> put_entity("sender", "user", public_user(sender))
          |> put_entity("receiver", receiver_type, receiver_entity)

        message = Map.put(message, "data", data)
        state = Map.put(state, "next_id", id + 1)
        {:ok, message, state}
    end
  end

  defp infer_type(params, uploads) do
    data = normalise_data(params["data"] || %{})

    cond do
      params["category"] == "custom" -> params["type"] || "custom"
      Map.has_key?(data, "customData") -> "custom"
      uploads != [] -> params["type"] || "file"
      Map.has_key?(data, "url") -> params["type"] || "file"
      true -> "text"
    end
  end

  defp normalise_message_data(params, uploads) do
    base = normalise_data(params["data"] || %{})

    base =
      cond do
        Map.has_key?(params, "text") and not Map.has_key?(base, "text") ->
          Map.put(base, "text", params["text"])

        Map.has_key?(params, "caption") and not Map.has_key?(base, "text") ->
          Map.put(base, "text", params["caption"])

        true ->
          base
      end

    base =
      if Map.has_key?(params, "metadata") and not Map.has_key?(base, "metadata") do
        Map.put(base, "metadata", normalise_data(params["metadata"]))
      else
        base
      end

    base =
      if Map.has_key?(params, "customData") and not Map.has_key?(base, "customData") do
        Map.put(base, "customData", normalise_data(params["customData"]))
      else
        base
      end

    attachments = upload_attachments(uploads)

    if attachments == [] do
      base
    else
      base
      |> Map.put("attachments", attachments)
      |> Map.put_new("url", List.first(attachments)["url"])
    end
  end

  defp normalise_data(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> stringify_keys(decoded)
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp normalise_data(value) when is_map(value), do: stringify_keys(value)
  defp normalise_data(nil), do: %{}
  defp normalise_data(other), do: other

  defp upload_attachments(uploads) do
    uploads
    |> List.wrap()
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&persist_upload/1)
  end

  defp persist_upload(%Plug.Upload{} = upload) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false)
    filename = Path.basename(upload.filename || id)
    dest = Path.join(Config.upload_dir(), id <> "-" <> filename)
    File.cp!(upload.path, dest)
    stat = File.stat!(dest)
    mime = upload.content_type || MIME.from_path(filename) || "application/octet-stream"

    %{
      "extension" => filename |> Path.extname() |> String.trim_leading("."),
      "mimeType" => mime,
      "name" => filename,
      "size" => stat.size,
      "url" => media_url(id <> "-" <> filename)
    }
  end

  defp persist_upload(%{"path" => path, "filename" => filename} = upload) do
    persist_upload(%Plug.Upload{
      path: path,
      filename: filename,
      content_type: upload["content_type"]
    })
  end

  defp persist_upload(other) do
    %{
      "extension" => "",
      "mimeType" => "application/octet-stream",
      "name" => to_s(other),
      "size" => 0,
      "url" => to_s(other)
    }
  end

  defp media_url(filename) do
    base = Application.get_env(:open_chat, :public_media_base_url)

    if blank?(base),
      do: "/media/#{URI.encode(filename)}",
      else: String.trim_trailing(base, "/") <> "/media/#{URI.encode(filename)}"
  end

  defp merge_message_data(old, new) do
    new = normalise_data(new)

    cond do
      is_map(new) and Map.has_key?(new, "data") ->
        Map.merge(old || %{}, normalise_data(new["data"]))

      is_map(new) ->
        Map.merge(old || %{}, new)

      true ->
        old || %{}
    end
  end

  defp enrich_data_entities(state, message, data) do
    sender =
      state["users"][to_s(message["sender"])] || normalise_user(%{"uid" => message["sender"]})

    {_state, receiver_entity} =
      ensure_receiver_entity(state, message["receiverType"], message["receiver"])

    data
    |> Map.put_new("reactions", get_in(message, ["data", "reactions"]) || [])
    |> put_entity("sender", "user", public_user(sender))
    |> put_entity("receiver", message["receiverType"], receiver_entity)
  end

  defp put_entity(data, key, entity_type, entity) do
    Map.update(
      data,
      "entities",
      %{key => %{"entityType" => entity_type, "entity" => entity}},
      fn entities ->
        Map.put(entities || %{}, key, %{"entityType" => entity_type, "entity" => entity})
      end
    )
  end

  defp fetch_messages_from_conversation(state, conv_id, params) do
    ids = Map.get(state["conversation_messages"], conv_id, [])

    ids
    |> Enum.map(&state["messages"][&1])
    |> Enum.reject(&is_nil/1)
    |> filter_messages(params)
    |> paginate_messages(params)
  end

  defp filter_messages(messages, params) do
    params = stringify_keys(params)
    hide_deleted = truthy?(params["hideDeleted"] || params["hideDeletedMessages"])
    type = params["type"]
    category = params["category"]
    timestamp = params["sentAt"] || params["timestamp"]
    id = params["id"] || params["cursorValue"]
    affix = params["cursorAffix"] || params["affix"] || "prepend"
    cursor_field = params["cursorField"] || if(id, do: "id", else: "sentAt")

    messages
    |> Enum.filter(fn m -> not hide_deleted or blank?(m["deletedAt"]) end)
    |> Enum.filter(fn m -> blank?(type) or m["type"] == type end)
    |> Enum.filter(fn m -> blank?(category) or m["category"] == category end)
    |> filter_cursor(cursor_field, timestamp || id, affix)
  end

  defp filter_cursor(messages, _field, nil, _affix), do: messages

  defp filter_cursor(messages, field, value, affix) do
    value_i = to_int(value)
    field = if field == "id", do: "id", else: "sentAt"

    Enum.filter(messages, fn m ->
      v = to_int(m[field])
      if affix == "append", do: v > value_i, else: v < value_i
    end)
  end

  defp paginate_messages(messages, params) do
    params = stringify_keys(params)
    limit = clamp(to_int(params["per_page"] || params["limit"] || 30), 1, 100)
    affix = params["cursorAffix"] || params["affix"] || "prepend"

    messages = Enum.sort_by(messages, &to_int(&1["sentAt"]))
    messages = if affix == "append", do: messages, else: Enum.reverse(messages)
    Enum.take(messages, limit)
  end

  defp previous_message_id(state, conv_id, message_id) do
    ids = Map.get(state["conversation_messages"], conv_id, [])
    idx = Enum.find_index(ids, &(&1 == to_s(message_id))) || 0
    Enum.at(ids, max(idx - 1, 0), "0")
  end

  defp all_conversation_ids_for_user(state, uid) do
    direct =
      state["conversation_messages"]
      |> Map.keys()
      |> Enum.filter(fn conv_id ->
        case String.split(conv_id, "_") do
          ["user", a, b] -> a == uid or b == uid
          _ -> false
        end
      end)

    groups =
      state["members"]
      |> Enum.filter(fn {_guid, members} -> Map.has_key?(members, uid) end)
      |> Enum.map(fn {guid, _} -> group_conversation_id(guid) end)
      |> Enum.filter(&Map.has_key?(state["conversation_messages"], &1))

    Enum.uniq(direct ++ groups)
  end

  defp build_conversation(_state, _uid, nil), do: nil

  defp build_conversation(state, uid, conv_id) do
    ids = Map.get(state["conversation_messages"], conv_id, [])
    last = ids |> Enum.reverse() |> Enum.map(&state["messages"][&1]) |> Enum.find(& &1)

    if is_nil(last) do
      nil
    else
      type = if String.starts_with?(conv_id, "group_"), do: "group", else: "user"
      with_entity = conversation_with(state, uid, conv_id)
      latest = to_s(last["id"])
      read = get_in(state, ["reads", uid, conv_id]) || %{}

      %{
        "conversationId" => conv_id,
        "conversationType" => type,
        "lastMessage" => last,
        "conversationWith" => with_entity,
        "unreadMessageCount" => unread_count(state, uid, conv_id),
        "tags" => [],
        "unreadMentionsCount" => 0,
        "lastReadMessageId" => to_s(read["messageId"] || ""),
        "latestMessageId" => latest
      }
    end
  end

  defp conversation_with(state, _uid, "group_" <> guid),
    do:
      with_members_count(
        state["groups"][guid] || normalise_group(%{"guid" => guid, "name" => guid}),
        state
      )

  defp conversation_with(state, uid, "user_" <> rest) do
    [a, b] = String.split(rest, "_", parts: 2)
    peer = if a == uid, do: b, else: a
    public_user(state["users"][peer] || normalise_user(%{"uid" => peer}))
  end

  defp unread_count(state, uid, conv_id) do
    read_id = get_in(state, ["reads", uid, conv_id, "messageId"]) |> to_int()

    state["conversation_messages"]
    |> Map.get(conv_id, [])
    |> Enum.map(&state["messages"][&1])
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(fn m -> to_s(m["sender"]) == uid end)
    |> Enum.reject(fn m -> not blank?(m["deletedAt"]) end)
    |> Enum.count(fn m -> to_int(m["id"]) > read_id end)
  end

  defp unread_count_row(state, uid, conv_id, count) do
    case conv_id do
      "group_" <> guid ->
        %{
          "entity" =>
            with_members_count(state["groups"][guid] || normalise_group(%{"guid" => guid}), state),
          "entityType" => "group",
          "entityId" => guid,
          "count" => count
        }

      "user_" <> rest ->
        [a, b] = String.split(rest, "_", parts: 2)
        peer = if a == uid, do: b, else: a

        %{
          "entity" => public_user(state["users"][peer] || normalise_user(%{"uid" => peer})),
          "entityType" => "user",
          "entityId" => peer,
          "count" => count
        }
    end
  end

  defp conversation_id_for(uid, "user", receiver), do: user_conversation_id(uid, receiver)
  defp conversation_id_for(_uid, "group", receiver), do: group_conversation_id(receiver)

  defp user_conversation_id(a, b) do
    [x, y] = [to_s(a), to_s(b)] |> Enum.sort()
    "user_#{x}_#{y}"
  end

  defp group_conversation_id(guid), do: "group_#{to_s(guid)}"

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
          Enum.map(reaction_map, fn {reaction, by_uid} ->
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

  defp message_action(state, actor_uid, message, action) do
    id = state["next_id"] || Time.now_ms()
    actor = public_user(state["users"][actor_uid] || normalise_user(%{"uid" => actor_uid}))

    receiver_entity =
      elem(ensure_receiver_entity(state, message["receiverType"], message["receiver"]), 1)

    %{
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
    }
  end

  defp group_action(state, actor_uid, group, on_uid, action) do
    id = (state["next_id"] || 1) + 10_000_000
    actor = public_user(state["users"][actor_uid] || normalise_user(%{"uid" => actor_uid}))
    on_user = public_user(state["users"][on_uid] || normalise_user(%{"uid" => on_uid}))

    %{
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

  defp recipient_keys(_state, %{"receiverType" => "user"} = message) do
    sender = to_s(message["sender"])
    receiver = to_s(message["receiver"])
    [{:user, receiver}, {:user, sender}]
  end

  defp recipient_keys(state, %{"receiverType" => "group"} = message) do
    sender = to_s(message["sender"])

    state["members"]
    |> Map.get(to_s(message["receiver"]), %{})
    |> Map.keys()
    |> Enum.reject(&(&1 == sender))
    |> Enum.map(&{:user, &1})
  end

  defp publish_to_group(state, guid, action, opts) do
    except = Keyword.get(opts, :except)

    keys =
      state["members"]
      |> Map.get(guid, %{})
      |> Map.keys()
      |> Enum.reject(&(&1 == except))
      |> Enum.map(&{:user, &1})

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
    with ["local", payload, "unsigned"] <- String.split(token, ".", parts: 3),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"token" => auth_token}} <- Jason.decode(json) do
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
    payload = Jason.encode!(%{"uid" => user["uid"], "token" => token, "iat" => Time.now()})
    "local." <> Base.url_encode64(payload, padding: false) <> ".unsigned"
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
    attrs = stringify_keys(attrs)
    uid = to_s(attrs["uid"] || attrs["id"])

    %{
      "uid" => uid,
      "name" => to_s(attrs["name"] || uid),
      "avatar" => attrs["avatar"],
      "link" => attrs["link"],
      "metadata" => normalise_data(attrs["metadata"] || %{}),
      "role" => attrs["role"] || "default",
      "status" => attrs["status"] || "available",
      "statusMessage" => attrs["statusMessage"],
      "lastActiveAt" => attrs["lastActiveAt"] || Time.now(),
      "tags" => attrs["tags"] || [],
      "deactivatedAt" => attrs["deactivatedAt"],
      "authToken" => attrs["authToken"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp public_user(nil), do: nil
  defp public_user(user), do: Map.drop(user, ["authToken"])

  defp public_user_with_block_state(_state, nil, user), do: public_user(user)

  defp public_user_with_block_state(state, viewer_uid, user) do
    user = public_user(user)
    target_uid = user["uid"]

    user
    |> Map.put("blockedByMe", blocked?(state, viewer_uid, target_uid))
    |> Map.put("hasBlockedMe", blocked?(state, target_uid, viewer_uid))
  end

  defp normalise_group(attrs) do
    attrs = stringify_keys(attrs)
    guid = to_s(attrs["guid"] || attrs["id"])

    %{
      "guid" => guid,
      "name" => to_s(attrs["name"] || guid),
      "type" => attrs["type"] || "public",
      "password" => attrs["password"],
      "icon" => attrs["icon"],
      "description" => attrs["description"],
      "owner" => attrs["owner"] || "system",
      "metadata" => normalise_data(attrs["metadata"] || %{}),
      "tags" => attrs["tags"] || [],
      "createdAt" => attrs["createdAt"] || Time.now(),
      "hasJoined" => attrs["hasJoined"] || false,
      "membersCount" => attrs["membersCount"] || 0
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
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
    state = ensure_group_member_map(state, guid)
    scope = normalise_scope(scope)

    put_in(state, ["members", guid, uid], %{
      "uid" => uid,
      "scope" => scope,
      "role" => scope,
      "joinedAt" => Time.now(),
      "guid" => guid
    })
  end

  defp member?(state, guid, uid), do: Map.has_key?(get_in(state, ["members", guid]) || %{}, uid)

  defp blocked?(state, blocker_uid, blocked_uid),
    do: get_in(state, ["blocks", blocker_uid, blocked_uid]) == true

  defp normalise_scope("participants"), do: "participant"
  defp normalise_scope("members"), do: "participant"
  defp normalise_scope(scope) when scope in ["admin", "moderator", "participant"], do: scope
  defp normalise_scope(_scope), do: "participant"

  defp with_members_count(nil, _state), do: nil

  defp with_members_count(group, state) do
    guid = group["guid"]
    count = state["members"] |> Map.get(guid, %{}) |> map_size()
    group |> Map.put("membersCount", count)
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

  defp blank?(value), do: value in [nil, "", false]
  defp truthy?(value), do: value in [true, 1, "1", "true", "TRUE", "yes"]
  defp contains?(a, b), do: String.contains?(String.downcase(to_s(a)), String.downcase(to_s(b)))
  defp clamp(value, lo, hi), do: value |> Kernel.max(lo) |> Kernel.min(hi)

  defp sort_by_key(rows, key), do: Enum.sort_by(rows, &to_s(&1[key]))

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp decode_seed(json, default) do
    case Jason.decode(json || "") do
      {:ok, list} when is_list(list) -> list
      {:ok, map} when is_map(map) -> Map.values(map)
      _ -> default
    end
  end

  defp default_users do
    [
      %{"uid" => "alice", "name" => "Alice Example", "authToken" => "uid:alice"},
      %{"uid" => "bob", "name" => "Bob Example", "authToken" => "uid:bob"},
      %{"uid" => "carol", "name" => "Carol Example", "authToken" => "uid:carol"},
      %{"uid" => "system", "name" => "System"}
    ]
  end

  defp default_groups do
    [
      %{"guid" => "lobby", "name" => "Lobby", "type" => "public", "owner" => "system"}
    ]
  end
end
