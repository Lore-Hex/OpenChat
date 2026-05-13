defmodule OpenChat.RedisPersistenceTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store

  @redis_url System.get_env("REDIS_TEST_URL") || "redis://localhost:6379/15"

  setup_all do
    case Redix.start_link(@redis_url) do
      {:ok, redis} ->
        {:ok, redis: redis, redis_url: @redis_url}

      {:error, reason} ->
        {:ok, redis_unavailable: reason}
    end
  end

  setup context do
    if reason = context[:redis_unavailable] do
      {:ok, skip_redis?: reason}
    else
      prefix = "open_chat:test:#{System.unique_integer([:positive])}"
      snapshot_key = "#{prefix}:legacy_snapshot"
      delete_prefix(context.redis, prefix)

      old_redis_url = Application.get_env(:open_chat, :redis_url)
      old_key_prefix = Application.get_env(:open_chat, :redis_key_prefix)
      old_snapshot_key = Application.get_env(:open_chat, :redis_snapshot_key)

      Application.put_env(:open_chat, :redis_url, context.redis_url)
      Application.put_env(:open_chat, :redis_key_prefix, prefix)
      Application.put_env(:open_chat, :redis_snapshot_key, snapshot_key)
      restart_store!()

      on_exit(fn ->
        Application.put_env(:open_chat, :redis_url, old_redis_url)
        Application.put_env(:open_chat, :redis_key_prefix, old_key_prefix)
        Application.put_env(:open_chat, :redis_snapshot_key, old_snapshot_key)
        restart_store!()
        delete_prefix(context.redis, prefix)
      end)

      {:ok, prefix: prefix, snapshot_key: snapshot_key}
    end
  end

  test "persists records under per-entity Redis keys instead of a whole-state snapshot",
       context do
    with_redis(context, fn ->
      assert {:ok, user} = Store.upsert_user(%{"uid" => "redis-user", "name" => "Redis User"})
      assert user["uid"] == "redis-user"

      assert {:ok, auth} = Store.create_auth_token("redis-user")
      assert {:ok, group} = Store.upsert_group(%{"guid" => "redis-room", "type" => "public"})
      assert group["guid"] == "redis-room"
      assert {:ok, _members} = Store.add_group_members("redis-room", ["redis-user"], "admin")

      assert {:ok, message} =
               Store.send_message("redis-user", %{
                 "receiver" => "alice",
                 "receiverType" => "user",
                 "data" => %{"text" => "stored per key"}
               })

      assert {:ok, _message} = Store.add_reaction("alice", message["id"], "👍")

      assert redis_get(context, "meta", "version") == "3"
      assert redis_get_raw(context, context.snapshot_key) == nil

      assert "redis-user" in redis_members(context, "index", "users")
      assert auth["authToken"] in redis_members(context, "index", "tokens")
      assert "redis-room" in redis_members(context, "index", "groups")
      assert to_string(message["id"]) in redis_members(context, "index", "messages")

      assert redis_json(context, "users", "redis-user")["name"] == "Redis User"
      assert redis_json(context, "tokens", auth["authToken"]) == "redis-user"
      assert redis_json(context, "members", "redis-room")["redis-user"]["scope"] == "admin"
      assert redis_json(context, "messages", message["id"])["data"]["text"] == "stored per key"
      assert redis_json(context, "reactions", message["id"])["👍"]["alice"]["uid"] == "alice"
    end)
  end

  test "reloads users, tokens, groups, messages, counters, and reactions from per-key Redis",
       context do
    with_redis(context, fn ->
      assert {:ok, auth} = Store.create_auth_token("reload-user")
      assert {:ok, _group} = Store.upsert_group(%{"guid" => "reload-room", "type" => "public"})
      assert {:ok, _joined} = Store.join_group("reload-room", "reload-user", %{})

      assert {:ok, message} =
               Store.send_message("reload-user", %{
                 "receiver" => "alice",
                 "receiverType" => "user",
                 "data" => %{"text" => "before restart"}
               })

      assert {:ok, _message} = Store.add_reaction("alice", message["id"], "🔥")

      restart_store!()

      assert {:ok, me} = Store.me(auth["authToken"])
      assert me["uid"] == "reload-user"

      assert {:ok, [%{"guid" => "reload-room"}]} = Store.groups_for_user("reload-user")

      assert {:ok, [loaded_message]} =
               Store.messages_for_user("alice", "reload-user", %{"limit" => 10})

      assert loaded_message["id"] == message["id"]
      assert get_in(loaded_message, ["data", "text"]) == "before restart"

      assert {:ok, reloaded_reactions} = Store.reactions("alice", message["id"], "🔥")
      assert [%{"uid" => "alice", "reaction" => "🔥"}] = reloaded_reactions

      assert {:ok, next_message} =
               Store.send_message("reload-user", %{
                 "receiver" => "alice",
                 "receiverType" => "user",
                 "data" => %{"text" => "after restart"}
               })

      assert next_message["id"] > message["id"]
    end)
  end

  test "imports a legacy single-key snapshot into the per-key layout", context do
    with_redis(context, fn ->
      legacy_state = %{
        "users" => %{
          "legacy-user" => %{
            "uid" => "legacy-user",
            "name" => "Legacy User",
            "status" => "available",
            "metadata" => %{},
            "role" => "default",
            "lastActiveAt" => 1,
            "tags" => []
          }
        },
        "tokens" => %{"legacy-token" => "legacy-user"},
        "groups" => %{},
        "members" => %{},
        "messages" => %{},
        "conversation_messages" => %{},
        "thread_messages" => %{},
        "reads" => %{},
        "hidden_conversations" => %{},
        "reactions" => %{},
        "blocks" => %{},
        "banned" => %{},
        "next_id" => 42,
        "next_reaction_id" => 7
      }

      Redix.command!(context.redis, ["DEL", redis_key(context, "meta", "version")])
      Redix.command!(context.redis, ["SET", context.snapshot_key, Jason.encode!(legacy_state)])

      restart_store!()

      assert {:ok, me} = Store.me("legacy-token")
      assert me["uid"] == "legacy-user"
      assert redis_get(context, "meta", "version") == "3"
      assert redis_json(context, "users", "legacy-user")["name"] == "Legacy User"

      assert {:ok, message} =
               Store.send_message("legacy-user", %{
                 "receiver" => "alice",
                 "receiverType" => "user",
                 "data" => %{"text" => "counter migrated"}
               })

      assert message["id"] == 42
    end)
  end

  test "removes deleted token, conversation, member, ban, block, and reaction records from indexes",
       context do
    with_redis(context, fn ->
      assert {:ok, auth} = Store.create_auth_token("cleanup-user")

      assert {:ok, message} =
               Store.send_message("cleanup-user", %{
                 "receiver" => "alice",
                 "receiverType" => "user",
                 "data" => %{"text" => "cleanup"}
               })

      assert {:ok, _message} = Store.add_reaction("alice", message["id"], "👍")
      assert {:ok, _blocked} = Store.block_users("cleanup-user", ["alice"])
      assert {:ok, _group} = Store.upsert_group(%{"guid" => "cleanup-room"})
      assert {:ok, _members} = Store.add_group_members("cleanup-room", ["cleanup-user"])

      assert "cleanup-room" in redis_members(context, "index", "members")

      assert {:ok, _ban} = Store.ban_group_member("cleanup-room", "cleanup-user")

      assert auth["authToken"] in redis_members(context, "index", "tokens")
      assert "user_alice_cleanup-user" in redis_members(context, "index", "conversation_messages")
      assert to_string(message["id"]) in redis_members(context, "index", "reactions")
      assert "cleanup-user" in redis_members(context, "index", "blocks")
      assert "cleanup-room" in redis_members(context, "index", "banned")

      assert {:ok, _hidden} = Store.hide_conversation("cleanup-user", "user", "alice")
      assert "cleanup-user" in redis_members(context, "index", "hidden_conversations")

      assert {:ok, _revoked} = Store.revoke_auth_token(auth["authToken"])
      assert {:ok, _unreacted} = Store.remove_reaction("alice", message["id"], "👍")
      assert {:ok, _unblocked} = Store.unblock_users("cleanup-user", ["alice"])
      assert {:ok, _unbanned} = Store.unban_group_member("cleanup-room", "cleanup-user")
      assert {:ok, _deleted} = Store.delete_conversation("user_alice_cleanup-user")

      refute auth["authToken"] in redis_members(context, "index", "tokens")
      refute "user_alice_cleanup-user" in redis_members(context, "index", "conversation_messages")
      refute to_string(message["id"]) in redis_members(context, "index", "reactions")
      refute "cleanup-user" in redis_members(context, "index", "blocks")
      refute "cleanup-user" in redis_members(context, "index", "hidden_conversations")
      refute "cleanup-room" in redis_members(context, "index", "members")
      refute "cleanup-room" in redis_members(context, "index", "banned")

      assert redis_get_raw(context, redis_key(context, "tokens", auth["authToken"])) == nil
      assert redis_get_raw(context, redis_key(context, "reactions", message["id"])) == nil
      assert redis_get_raw(context, redis_key(context, "blocks", "cleanup-user")) == nil

      assert redis_get_raw(context, redis_key(context, "hidden_conversations", "cleanup-user")) ==
               nil

      assert redis_get_raw(context, redis_key(context, "members", "cleanup-room")) == nil
      assert redis_get_raw(context, redis_key(context, "banned", "cleanup-room")) == nil
    end)
  end

  test "persists conversation hides and removes deleted group records from Redis", context do
    with_redis(context, fn ->
      assert {:ok, _group} = Store.upsert_group(%{"guid" => "redis-delete-room"})
      assert {:ok, _members} = Store.add_group_members("redis-delete-room", ["alice", "bob"])
      assert {:ok, _ban} = Store.ban_group_member("redis-delete-room", "carol")

      assert {:ok, message} =
               Store.send_message("alice", %{
                 "receiver" => "redis-delete-room",
                 "receiverType" => "group",
                 "data" => %{"text" => "delete me"}
               })

      assert {:ok, _reaction} = Store.add_reaction("bob", message["id"], "👍")
      assert {:ok, _read} = Store.mark_read("bob", "group", "redis-delete-room", message["id"])
      assert {:ok, _hidden} = Store.hide_conversation("alice", "group", "redis-delete-room")

      assert "redis-delete-room" in redis_members(context, "index", "groups")
      assert "redis-delete-room" in redis_members(context, "index", "members")
      assert "redis-delete-room" in redis_members(context, "index", "banned")
      assert "group_redis-delete-room" in redis_members(context, "index", "conversation_messages")
      assert to_string(message["id"]) in redis_members(context, "index", "messages")
      assert to_string(message["id"]) in redis_members(context, "index", "reactions")
      assert "alice" in redis_members(context, "index", "hidden_conversations")
      assert "bob" in redis_members(context, "index", "reads")

      assert {:ok, _deleted} = Store.delete_group("redis-delete-room")

      refute "redis-delete-room" in redis_members(context, "index", "groups")
      refute "redis-delete-room" in redis_members(context, "index", "members")
      refute "redis-delete-room" in redis_members(context, "index", "banned")
      refute "group_redis-delete-room" in redis_members(context, "index", "conversation_messages")
      refute to_string(message["id"]) in redis_members(context, "index", "messages")
      refute to_string(message["id"]) in redis_members(context, "index", "reactions")
      refute "alice" in redis_members(context, "index", "hidden_conversations")
      refute "bob" in redis_members(context, "index", "reads")

      assert redis_get_raw(context, redis_key(context, "groups", "redis-delete-room")) == nil
      assert redis_get_raw(context, redis_key(context, "members", "redis-delete-room")) == nil
      assert redis_get_raw(context, redis_key(context, "banned", "redis-delete-room")) == nil
      assert redis_get_raw(context, redis_key(context, "messages", message["id"])) == nil
      assert redis_get_raw(context, redis_key(context, "reactions", message["id"])) == nil
    end)
  end

  test "refreshes local state from Redis before serving calls", context do
    with_redis(context, fn ->
      assert {:ok, user} =
               Store.upsert_user(%{
                 "uid" => "externally-updated",
                 "name" => "Before Redis Update"
               })

      assert user["name"] == "Before Redis Update"

      external_user =
        user
        |> Map.put("name", "After Redis Update")
        |> Jason.encode!()

      Redix.command!(
        context.redis,
        ["SET", redis_key(context, "users", "externally-updated"), external_user]
      )

      assert {:ok, updated} = Store.get_user("externally-updated")
      assert updated["name"] == "After Redis Update"
    end)
  end

  defp with_redis(%{skip_redis?: reason}, _fun) do
    IO.puts("Skipping Redis persistence test; Redis unavailable: #{inspect(reason)}")
    :ok
  end

  defp with_redis(_context, fun), do: fun.()

  defp restart_store! do
    if Process.whereis(OpenChat.Store) do
      :ok = Supervisor.terminate_child(OpenChat.Supervisor, OpenChat.Store)
    end

    if pid = Process.whereis(OpenChat.Redis) do
      Process.exit(pid, :kill)
      wait_until_stopped(OpenChat.Redis)
    end

    case Supervisor.restart_child(OpenChat.Supervisor, OpenChat.Store) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> flunk("failed to restart OpenChat.Store: #{inspect(other)}")
    end
  end

  defp wait_until_stopped(name, attempts \\ 20)
  defp wait_until_stopped(_name, 0), do: :ok

  defp wait_until_stopped(name, attempts) do
    if Process.whereis(name) do
      Process.sleep(10)
      wait_until_stopped(name, attempts - 1)
    else
      :ok
    end
  end

  defp redis_json(context, parts) when is_list(parts) do
    context
    |> redis_get_raw(redis_key(context, parts))
    |> Jason.decode!()
  end

  defp redis_json(context, part_a, part_b), do: redis_json(context, [part_a, part_b])

  defp redis_get(context, parts) when is_list(parts),
    do: redis_get_raw(context, redis_key(context, parts))

  defp redis_get(context, part_a, part_b), do: redis_get(context, [part_a, part_b])

  defp redis_get_raw(context, key) do
    {:ok, value} = Redix.command(context.redis, ["GET", key])
    value
  end

  defp redis_members(context, parts) when is_list(parts) do
    {:ok, members} = Redix.command(context.redis, ["SMEMBERS", redis_key(context, parts)])
    members
  end

  defp redis_members(context, part_a, part_b), do: redis_members(context, [part_a, part_b])

  defp redis_key(context, parts) when is_list(parts), do: Enum.join([context.prefix | parts], ":")
  defp redis_key(context, part_a, part_b), do: redis_key(context, [part_a, part_b])

  defp delete_prefix(redis, prefix, cursor \\ "0") do
    {:ok, [next_cursor, keys]} =
      Redix.command(redis, ["SCAN", cursor, "MATCH", "#{prefix}:*", "COUNT", "1000"])

    if keys != [] do
      Redix.command!(redis, ["DEL" | keys])
    end

    if next_cursor != "0" do
      delete_prefix(redis, prefix, next_cursor)
    end
  end
end
