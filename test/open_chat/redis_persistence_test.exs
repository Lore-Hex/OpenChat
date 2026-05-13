defmodule OpenChat.RedisPersistenceTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store
  alias OpenChat.Store.Conversations

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
                 "muid" => "redis-muid",
                 "data" => %{"text" => "stored per key"}
               })

      assert {:ok, _message} = Store.add_reaction("alice", message["id"], "👍")

      assert redis_get(context, "meta", "version") == "5"
      assert redis_get_raw(context, context.snapshot_key) == nil

      assert "redis-user" in redis_members(context, "index", "users")
      assert auth["authToken"] in redis_members(context, "index", "tokens")
      assert "redis-room" in redis_members(context, "index", "groups")
      assert to_string(message["id"]) in redis_members(context, "index", "messages")
      assert "redis-muid" in redis_members(context, "index", "message_muids")
      assert "redis-user" in redis_members(context, "index", "user_conversations")
      assert "alice" in redis_members(context, "index", "user_conversations")
      assert message["conversationId"] in redis_members(context, "index", "conversation_users")
      assert "redis-user" in redis_members(context, "index", "user_groups")

      assert redis_json(context, "users", "redis-user")["name"] == "Redis User"
      assert redis_json(context, "tokens", auth["authToken"]) == "redis-user"
      assert redis_json(context, "members", "redis-room")["redis-user"]["scope"] == "admin"
      assert redis_json(context, "messages", message["id"])["data"]["text"] == "stored per key"
      assert redis_json(context, "message_muids", "redis-muid") == to_string(message["id"])

      assert redis_json(context, "user_conversations", "redis-user") == [
               message["conversationId"]
             ]

      assert redis_json(context, "conversation_users", message["conversationId"]) == [
               "redis-user",
               "alice"
             ]

      assert redis_json(context, "user_groups", "redis-user") == ["redis-room"]
      assert redis_json(context, "reactions", message["id"])["👍"]["alice"]["uid"] == "alice"
    end)
  end

  test "uid-token auth persists generated users and token mappings per key", context do
    with_redis(context, fn ->
      assert {:ok, me} = Store.me("uid:redis-uid-token-user")
      assert me["uid"] == "redis-uid-token-user"

      assert redis_json(context, "users", "redis-uid-token-user")["uid"] ==
               "redis-uid-token-user"

      assert redis_json(context, "tokens", "uid:redis-uid-token-user") ==
               "redis-uid-token-user"

      assert "redis-uid-token-user" in redis_members(context, "index", "users")
      assert "uid:redis-uid-token-user" in redis_members(context, "index", "tokens")
    end)
  end

  test "auth token lookups refresh mapped users without stale writeback", context do
    with_redis(context, fn ->
      assert {:ok, _user} =
               Store.upsert_user(%{
                 "uid" => "auth-refresh-user",
                 "name" => "Before External Update"
               })

      assert {:ok, auth} = Store.create_auth_token("auth-refresh-user")

      external_user =
        context
        |> redis_json("users", "auth-refresh-user")
        |> Map.put("name", "After External Update")

      Redix.command!(
        context.redis,
        ["SET", redis_key(context, "users", "auth-refresh-user"), Jason.encode!(external_user)]
      )

      assert {:ok, me} = Store.me(auth["authToken"])
      assert me["name"] == "After External Update"
      assert redis_json(context, "users", "auth-refresh-user")["name"] == "After External Update"
    end)
  end

  test "local JWT auth refreshes the underlying token and user keys", context do
    with_redis(context, fn ->
      assert {:ok, first_me} = Store.me("uid:local-jwt-refresh-user")
      assert first_me["jwt"] =~ "local."

      external_user =
        context
        |> redis_json("users", "local-jwt-refresh-user")
        |> Map.put("name", "JWT Refreshed User")

      Redix.command!(
        context.redis,
        [
          "SET",
          redis_key(context, "users", "local-jwt-refresh-user"),
          Jason.encode!(external_user)
        ]
      )

      assert {:ok, me} = Store.me(first_me["jwt"])
      assert me["uid"] == "local-jwt-refresh-user"
      assert me["name"] == "JWT Refreshed User"

      assert redis_json(context, "users", "local-jwt-refresh-user")["name"] ==
               "JWT Refreshed User"
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
        "delivered" => %{},
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
      assert redis_get(context, "meta", "version") == "5"
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
      assert "cleanup-user" in redis_members(context, "index", "user_groups")

      assert {:ok, _ban} = Store.ban_group_member("cleanup-room", "cleanup-user")

      assert auth["authToken"] in redis_members(context, "index", "tokens")
      assert "user_alice_cleanup-user" in redis_members(context, "index", "conversation_messages")
      assert "user_alice_cleanup-user" in redis_members(context, "index", "conversation_users")
      assert "cleanup-user" in redis_members(context, "index", "user_conversations")
      assert "alice" in redis_members(context, "index", "user_conversations")
      assert to_string(message["id"]) in redis_members(context, "index", "reactions")
      assert "cleanup-user" in redis_members(context, "index", "blocks")
      assert "cleanup-room" in redis_members(context, "index", "banned")
      refute "cleanup-user" in redis_members(context, "index", "user_groups")

      assert {:ok, _hidden} = Store.hide_conversation("cleanup-user", "user", "alice")

      assert {:ok, _delivered} =
               Store.mark_delivered("cleanup-user", "user", "alice", message["id"])

      assert "cleanup-user" in redis_members(context, "index", "hidden_conversations")
      assert "cleanup-user" in redis_members(context, "index", "delivered")

      assert {:ok, _revoked} = Store.revoke_auth_token(auth["authToken"])
      assert {:ok, _unreacted} = Store.remove_reaction("alice", message["id"], "👍")
      assert {:ok, _unblocked} = Store.unblock_users("cleanup-user", ["alice"])
      assert {:ok, _unbanned} = Store.unban_group_member("cleanup-room", "cleanup-user")
      assert {:ok, _deleted} = Store.delete_conversation("user_alice_cleanup-user")

      refute auth["authToken"] in redis_members(context, "index", "tokens")
      refute "user_alice_cleanup-user" in redis_members(context, "index", "conversation_messages")
      refute "user_alice_cleanup-user" in redis_members(context, "index", "conversation_users")
      refute "cleanup-user" in redis_members(context, "index", "user_conversations")
      refute "alice" in redis_members(context, "index", "user_conversations")
      refute to_string(message["id"]) in redis_members(context, "index", "reactions")
      refute "cleanup-user" in redis_members(context, "index", "blocks")
      refute "cleanup-user" in redis_members(context, "index", "delivered")
      refute "cleanup-user" in redis_members(context, "index", "hidden_conversations")
      refute "cleanup-room" in redis_members(context, "index", "members")
      refute "cleanup-room" in redis_members(context, "index", "banned")
      refute "cleanup-user" in redis_members(context, "index", "user_groups")

      assert redis_get_raw(context, redis_key(context, "tokens", auth["authToken"])) == nil
      assert redis_get_raw(context, redis_key(context, "reactions", message["id"])) == nil
      assert redis_get_raw(context, redis_key(context, "blocks", "cleanup-user")) == nil
      assert redis_get_raw(context, redis_key(context, "delivered", "cleanup-user")) == nil

      assert redis_get_raw(context, redis_key(context, "hidden_conversations", "cleanup-user")) ==
               nil

      assert redis_get_raw(context, redis_key(context, "members", "cleanup-room")) == nil
      assert redis_get_raw(context, redis_key(context, "banned", "cleanup-room")) == nil

      assert redis_get_raw(
               context,
               redis_key(context, "conversation_users", "user_alice_cleanup-user")
             ) == nil

      assert redis_get_raw(context, redis_key(context, "user_conversations", "cleanup-user")) ==
               nil

      assert redis_get_raw(context, redis_key(context, "user_groups", "cleanup-user")) == nil
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

      assert {:ok, _delivered} =
               Store.mark_delivered("bob", "group", "redis-delete-room", message["id"])

      assert {:ok, _hidden} = Store.hide_conversation("alice", "group", "redis-delete-room")

      assert "redis-delete-room" in redis_members(context, "index", "groups")
      assert "redis-delete-room" in redis_members(context, "index", "members")
      assert "redis-delete-room" in redis_members(context, "index", "banned")
      assert "group_redis-delete-room" in redis_members(context, "index", "conversation_messages")
      assert "group_redis-delete-room" in redis_members(context, "index", "conversation_users")
      assert to_string(message["id"]) in redis_members(context, "index", "messages")
      assert to_string(message["id"]) in redis_members(context, "index", "reactions")
      assert "alice" in redis_members(context, "index", "hidden_conversations")
      assert "bob" in redis_members(context, "index", "reads")
      assert "bob" in redis_members(context, "index", "delivered")
      assert "alice" in redis_members(context, "index", "user_groups")
      assert "bob" in redis_members(context, "index", "user_groups")

      assert {:ok, _deleted} = Store.delete_group("redis-delete-room")

      refute "redis-delete-room" in redis_members(context, "index", "groups")
      refute "redis-delete-room" in redis_members(context, "index", "members")
      refute "redis-delete-room" in redis_members(context, "index", "banned")
      refute "group_redis-delete-room" in redis_members(context, "index", "conversation_messages")
      refute "group_redis-delete-room" in redis_members(context, "index", "conversation_users")
      refute to_string(message["id"]) in redis_members(context, "index", "messages")
      refute to_string(message["id"]) in redis_members(context, "index", "reactions")
      refute "alice" in redis_members(context, "index", "hidden_conversations")
      refute "bob" in redis_members(context, "index", "reads")
      refute "bob" in redis_members(context, "index", "delivered")
      refute "alice" in redis_members(context, "index", "user_groups")
      refute "bob" in redis_members(context, "index", "user_groups")

      assert redis_get_raw(context, redis_key(context, "groups", "redis-delete-room")) == nil
      assert redis_get_raw(context, redis_key(context, "members", "redis-delete-room")) == nil
      assert redis_get_raw(context, redis_key(context, "banned", "redis-delete-room")) == nil
      assert redis_get_raw(context, redis_key(context, "messages", message["id"])) == nil
      assert redis_get_raw(context, redis_key(context, "reactions", message["id"])) == nil

      assert redis_get_raw(
               context,
               redis_key(context, "conversation_users", "group_redis-delete-room")
             ) == nil

      assert redis_get_raw(context, redis_key(context, "user_groups", "alice")) == nil
      assert redis_get_raw(context, redis_key(context, "user_groups", "bob")) == nil
    end)
  end

  test "refreshes local state from Redis before mutating calls", context do
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

      Redix.command!(context.redis, ["INCR", redis_key(context, "meta", "revision")])

      assert {:ok, _auth} = Store.create_auth_token("externally-updated")
      assert {:ok, updated} = Store.get_user("externally-updated")
      assert updated["name"] == "After Redis Update"
    end)
  end

  test "targeted conversation refresh preserves externally written messages", context do
    with_redis(context, fn ->
      assert {:ok, first} =
               Store.send_message("refresh-a", %{
                 "receiver" => "refresh-b",
                 "receiverType" => "user",
                 "data" => %{"text" => "local first"}
               })

      external =
        first
        |> Map.put("id", 500)
        |> Map.put("sender", "refresh-b")
        |> Map.put("receiver", "refresh-a")
        |> put_in(["data", "text"], "external second")

      Redix.command!(
        context.redis,
        ["SET", redis_key(context, "messages", 500), Jason.encode!(external)]
      )

      Redix.command!(context.redis, ["SADD", redis_key(context, "index", "messages"), "500"])

      Redix.command!(
        context.redis,
        [
          "SET",
          redis_key(context, "conversation_messages", first["conversationId"]),
          Jason.encode!([to_string(first["id"]), "500"])
        ]
      )

      Redix.command!(
        context.redis,
        [
          "SADD",
          redis_key(context, "index", "conversation_messages"),
          first["conversationId"]
        ]
      )

      assert {:ok, second_local} =
               Store.send_message("refresh-a", %{
                 "receiver" => "refresh-b",
                 "receiverType" => "user",
                 "data" => %{"text" => "local third"}
               })

      assert redis_json(context, "messages", 500)["data"]["text"] == "external second"

      assert redis_json(context, "conversation_messages", first["conversationId"]) == [
               to_string(first["id"]),
               "500",
               to_string(second_local["id"])
             ]
    end)
  end

  test "targeted secondary-index refreshes load muid and conversation changes", context do
    with_redis(context, fn ->
      assert {:ok, first} =
               Store.send_message("secondary-a", %{
                 "receiver" => "secondary-b",
                 "receiverType" => "user",
                 "muid" => "secondary-muid",
                 "data" => %{"text" => "before external update"}
               })

      external_first =
        context
        |> redis_json("messages", first["id"])
        |> put_in(["data", "text"], "after external update")

      Redix.command!(
        context.redis,
        ["SET", redis_key(context, "messages", first["id"]), Jason.encode!(external_first)]
      )

      assert {:ok, fetched} = Store.find_message_by_muid("secondary-muid")
      assert fetched["data"]["text"] == "after external update"

      second =
        external_first
        |> Map.put("id", 999)
        |> Map.put("muid", "secondary-conversation-muid")
        |> Map.put("sender", "secondary-b")
        |> Map.put("receiver", "secondary-a")
        |> put_in(["data", "text"], "external conversation latest")

      conv_id = first["conversationId"]

      redis_put_json(context, ["messages", 999], second)
      redis_put_json(context, ["message_muids", "secondary-conversation-muid"], "999")
      redis_put_json(context, ["conversation_messages", conv_id], [to_string(first["id"]), "999"])
      redis_put_json(context, ["conversation_users", conv_id], ["secondary-a", "secondary-b"])
      redis_put_json(context, ["user_conversations", "secondary-a"], [conv_id])
      redis_put_json(context, ["user_conversations", "secondary-b"], [conv_id])

      for {bucket, id} <- [
            {"messages", "999"},
            {"message_muids", "secondary-conversation-muid"},
            {"conversation_messages", conv_id},
            {"conversation_users", conv_id},
            {"user_conversations", "secondary-a"},
            {"user_conversations", "secondary-b"}
          ] do
        Redix.command!(context.redis, ["SADD", redis_key(context, "index", bucket), id])
      end

      assert {:ok, [conversation]} = Store.conversations("secondary-a", %{"limit" => 1})
      assert get_in(conversation, ["lastMessage", "id"]) == 999

      assert get_in(conversation, ["lastMessage", "data", "text"]) ==
               "external conversation latest"
    end)
  end

  test "targeted Redis refreshes enforce actor-aware message and group access", context do
    with_redis(context, fn ->
      now = OpenChat.Time.now()
      conv_id = Conversations.user_conversation_id("redis-index-a", "redis-index-b")

      parent = %{
        "id" => 9001,
        "muid" => "redis-index-parent",
        "sender" => "redis-index-a",
        "receiver" => "redis-index-b",
        "receiverType" => "user",
        "type" => "text",
        "category" => "message",
        "data" => %{"text" => "external parent", "reactions" => []},
        "sentAt" => now,
        "updatedAt" => now,
        "conversationId" => conv_id
      }

      reply =
        parent
        |> Map.merge(%{
          "id" => 9002,
          "muid" => "redis-index-reply",
          "sender" => "redis-index-b",
          "receiver" => "redis-index-a",
          "parentId" => "9001"
        })
        |> put_in(["data", "text"], "external reply")

      redis_put_json(context, ["messages", "9001"], parent)
      redis_put_json(context, ["messages", "9002"], reply)
      redis_put_json(context, ["message_muids", "redis-index-parent"], "9001")
      redis_put_json(context, ["thread_messages", "9001"], ["9002"])
      redis_put_json(context, ["conversation_messages", conv_id], ["9001", "9002"])
      redis_put_json(context, ["conversation_users", conv_id], ["redis-index-a", "redis-index-b"])
      redis_put_json(context, ["user_conversations", "redis-index-a"], [conv_id])
      redis_put_json(context, ["user_conversations", "redis-index-b"], [conv_id])

      for {bucket, id} <- [
            {"messages", "9001"},
            {"messages", "9002"},
            {"message_muids", "redis-index-parent"},
            {"thread_messages", "9001"},
            {"conversation_messages", conv_id},
            {"conversation_users", conv_id},
            {"user_conversations", "redis-index-a"},
            {"user_conversations", "redis-index-b"}
          ] do
        redis_index!(context, bucket, id)
      end

      assert {:ok, fetched} =
               Store.find_message_by_muid_for("redis-index-b", "redis-index-parent")

      assert fetched["id"] == 9001

      assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
               Store.find_message_by_muid_for("redis-outsider", "redis-index-parent")

      assert {:ok, [thread_reply]} = Store.messages_for_thread("redis-index-a", "9001")
      assert thread_reply["id"] == 9002

      assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
               Store.messages_for_thread("redis-outsider", "9001")

      assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
               Store.mark_read("redis-outsider", "user", "redis-index-a", "9001")

      group_message = %{
        "id" => 9010,
        "sender" => "redis-member",
        "receiver" => "redis-secure-room",
        "receiverType" => "group",
        "type" => "text",
        "category" => "message",
        "data" => %{"text" => "group external", "reactions" => []},
        "sentAt" => now,
        "updatedAt" => now,
        "conversationId" => "group_redis-secure-room"
      }

      redis_put_json(context, ["groups", "redis-secure-room"], %{
        "guid" => "redis-secure-room",
        "name" => "Redis Secure Room",
        "type" => "public"
      })

      redis_put_json(context, ["members", "redis-secure-room"], %{
        "redis-member" => %{"uid" => "redis-member", "scope" => "participant"}
      })

      redis_put_json(context, ["messages", "9010"], group_message)

      for {bucket, id} <- [
            {"groups", "redis-secure-room"},
            {"members", "redis-secure-room"},
            {"messages", "9010"}
          ] do
        redis_index!(context, bucket, id)
      end

      assert {:ok, fetched_group} = Store.get_message_for("redis-member", "9010")
      assert fetched_group["id"] == 9010

      assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
               Store.get_message_for("redis-outsider", "9010")
    end)
  end

  test "Redis counter allocation ignores stale local next_id", context do
    with_redis(context, fn ->
      Redix.command!(context.redis, ["SET", redis_key(context, "counter", "next_id"), "1000"])

      assert {:ok, message} =
               Store.send_message("counter-a", %{
                 "receiver" => "counter-b",
                 "receiverType" => "user",
                 "data" => %{"text" => "from redis counter"}
               })

      assert message["id"] == 1000
      assert redis_get(context, "counter", "next_id") == "1001"
    end)
  end

  test "group membership action messages use Redis-backed IDs without reserved-offset collisions",
       context do
    with_redis(context, fn ->
      Redix.command!(context.redis, [
        "SET",
        redis_key(context, "counter", "next_id"),
        "20000000"
      ])

      assert {:ok, _group} =
               Store.upsert_group(%{"guid" => "redis-action-room", "type" => "public"})

      assert {:ok, _members} =
               Store.add_group_members("redis-action-room", ["redis-observer"], "participant")

      assert {:ok, _subscription} = OpenChat.PubSub.subscribe({:user, "redis-observer"})
      assert {:ok, _joined} = Store.join_group("redis-action-room", "redis-joiner", %{})

      assert_receive {:comet_event, %{"body" => action}}
      assert action["id"] == 20_000_000
      assert action["data"]["action"] == "joined"
      assert redis_get(context, "counter", "next_id") == "20000001"

      assert {:ok, message} =
               Store.send_message("redis-joiner", %{
                 "receiver" => "redis-observer",
                 "receiverType" => "user",
                 "data" => %{"text" => "after group action"}
               })

      assert message["id"] == 20_000_001
      assert redis_get(context, "counter", "next_id") == "20000002"
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

  defp redis_put_json(context, parts, value) do
    Redix.command!(context.redis, ["SET", redis_key(context, parts), Jason.encode!(value)])
  end

  defp redis_index!(context, bucket, id) do
    Redix.command!(context.redis, ["SADD", redis_key(context, "index", bucket), to_string(id)])
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
