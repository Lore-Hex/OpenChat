defmodule OpenChat.StoreRegressionTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store

  setup do
    Store.reset!()
    :ok
  end

  test "user lifecycle validates required fields, normalises metadata, and strips auth tokens" do
    assert {:error, %{"code" => "MISSING_PARAMETERS"}} = Store.upsert_user(%{})

    assert {:ok, user} =
             Store.upsert_user(%{
               "uid" => "zoe",
               "name" => "Zoe",
               "metadata" => Jason.encode!(%{"tier" => "gold"}),
               "authToken" => "token-zoe"
             })

    assert user["metadata"] == %{"tier" => "gold"}
    refute Map.has_key?(user, "authToken")

    assert {:ok, me} = Store.me("token-zoe")
    assert me["uid"] == "zoe"
    assert me["authToken"] == "token-zoe"

    assert {:ok, [%{"uid" => "zoe"}]} = Store.list_users(%{"search" => "zo", "limit" => 10})

    assert {:ok, %{"success" => true}} = Store.delete_user("zoe")
    assert {:ok, deleted} = Store.get_user("zoe")
    assert deleted["status"] == "offline"
    assert deleted["deactivatedAt"]

    assert {:ok, %{"success" => %{"new-user" => %{"success" => true}, "zoe" => _}}} =
             Store.reactivate_users(["zoe", "new-user"])

    assert {:ok, reactivated} = Store.get_user("zoe")
    assert reactivated["status"] == "available"
    refute Map.has_key?(reactivated, "deactivatedAt")
  end

  test "auth tokens can be revoked and local JWTs honor the underlying token state" do
    assert {:ok, payload} = Store.create_auth_token("alice")
    token = payload["authToken"]
    jwt = payload["jwt"]

    assert {:ok, %{"uid" => "alice"}} = Store.me(token)
    assert {:ok, %{"uid" => "alice"}} = Store.me(jwt)

    assert {:ok, %{"success" => true}} = Store.revoke_auth_token(token)
    assert {:error, %{"code" => "ERR_NO_AUTH"}} = Store.authenticate(token)
    assert {:error, %{"code" => "ERR_NO_AUTH"}} = Store.me(jwt)
  end

  test "group permissions, password joins, scopes, bans, and user group listings" do
    assert {:ok, _group} =
             Store.upsert_group(%{"guid" => "private-room", "type" => "private"})

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.join_group("private-room", "alice", %{})

    assert {:ok, _group} =
             Store.upsert_group(%{
               "guid" => "password-room",
               "type" => "password",
               "password" => "secret"
             })

    assert {:error, %{"code" => "INVALID_PASSWORD"}} =
             Store.join_group("password-room", "alice", %{"password" => "wrong"})

    assert {:ok, %{"hasJoined" => true}} =
             Store.join_group("password-room", "alice", %{"password" => "secret"})

    assert {:ok, _group} = Store.upsert_group(%{"guid" => "scoped-room", "type" => "public"})

    assert {:ok, _data} =
             Store.set_group_scopes("scoped-room", %{
               "participants" => ["alice"],
               "moderators" => ["bob"],
               "admins" => ["carol"]
             })

    assert {:ok, scoped} = Store.group_members("scoped-room", %{"scope" => "admin,moderator"})

    assert Enum.map(scoped, &{&1["uid"], &1["scope"]}) == [
             {"bob", "moderator"},
             {"carol", "admin"}
           ]

    assert {:ok, _data} = Store.ban_group_member("scoped-room", "bob")
    assert {:ok, [%{"uid" => "bob"}]} = Store.banned_group_members("scoped-room")

    assert {:ok, members} = Store.group_members("scoped-room")
    refute Enum.any?(members, &(&1["uid"] == "bob"))

    assert {:ok, _data} = Store.unban_group_member("scoped-room", "bob")
    assert {:ok, []} = Store.banned_group_members("scoped-room")

    assert {:ok, groups} = Store.groups_for_user("alice")
    assert Enum.any?(groups, &(&1["guid"] == "scoped-room"))
  end

  test "message validation, deterministic pagination, cursor filters, and hidden deletes" do
    assert {:error, %{"code" => "MISSING_PARAMETERS"}} =
             Store.send_message("alice", %{"receiverType" => "user"})

    assert {:error, %{"code" => "INVALID_RECEIVERTYPE"}} =
             Store.send_message("alice", %{"receiver" => "bob", "receiverType" => "bot"})

    assert {:error, %{"code" => "ERR_NOT_A_MEMBER"}} =
             Store.send_message("alice", %{
               "receiver" => "lobby",
               "receiverType" => "group",
               "data" => %{"text" => "nope"}
             })

    messages =
      for index <- 1..4 do
        {:ok, message} =
          Store.send_message("alice", %{
            "receiver" => "bob",
            "receiverType" => "user",
            "type" => "text",
            "category" => "message",
            "data" => %{"text" => "message #{index}"}
          })

        message
      end

    assert {:ok, latest_two} = Store.messages_for_user("bob", "alice", %{"limit" => 2})
    assert Enum.map(latest_two, &get_in(&1, ["data", "text"])) == ["message 4", "message 3"]

    third_id = messages |> Enum.at(2) |> Map.fetch!("id")
    assert {:ok, before_third} = Store.messages_for_user("bob", "alice", %{"id" => third_id})
    assert Enum.map(before_third, &get_in(&1, ["data", "text"])) == ["message 2", "message 1"]

    fourth_id = messages |> Enum.at(3) |> Map.fetch!("id")
    assert {:ok, _action} = Store.delete_message("alice", fourth_id)

    assert {:ok, visible_messages} =
             Store.messages_for_user("bob", "alice", %{
               "hideDeleted" => "true",
               "category" => "message"
             })

    refute Enum.any?(visible_messages, &(&1["id"] == fourth_id))
  end

  test "threads, muid lookup, unread filters, conversations, and conversation deletion" do
    assert {:ok, parent} =
             Store.send_message("alice", %{
               "receiver" => "bob",
               "receiverType" => "user",
               "muid" => "client-generated-id",
               "data" => %{"text" => "parent"}
             })

    assert {:ok, reply} =
             Store.send_message("bob", %{
               "receiver" => "alice",
               "receiverType" => "user",
               "parentId" => parent["id"],
               "data" => %{"text" => "thread reply"}
             })

    assert {:ok, found} = Store.find_message_by_muid("client-generated-id")
    assert found["id"] == parent["id"]

    assert {:ok, thread_messages} = Store.messages_for_thread("alice", parent["id"])
    assert Enum.map(thread_messages, & &1["id"]) == [reply["id"]]

    assert {:ok, counts} = Store.unread_counts("alice", %{"uid" => "bob"})
    assert [%{"entityType" => "user", "entityId" => "bob", "count" => 1}] = counts

    assert {:ok, conversations} = Store.conversations("alice", %{"conversationType" => "user"})
    assert [%{"conversationWith" => %{"uid" => "bob"}}] = conversations

    assert {:ok, %{"success" => true}} = Store.delete_conversation("user_alice_bob")
    assert {:ok, []} = Store.conversations("alice", %{"conversationType" => "user"})
  end

  test "conversation hiding is per viewer and a new message reveals it again" do
    assert {:ok, first} =
             Store.send_message("alice", %{
               "receiver" => "bob",
               "receiverType" => "user",
               "data" => %{"text" => "hide me"}
             })

    assert {:ok, [%{"latestMessageId" => latest_id}]} = Store.conversations("alice")
    assert latest_id == to_string(first["id"])

    assert {:ok, hidden} = Store.hide_conversation("alice", "user", "bob")
    assert hidden["conversationId"] == "user_alice_bob"
    assert hidden["messageId"] == to_string(first["id"])

    assert {:ok, []} = Store.conversations("alice")
    assert {:ok, nil} = Store.conversation("alice", "user", "bob")

    assert {:ok, [%{"conversationWith" => %{"uid" => "alice"}}]} = Store.conversations("bob")

    assert {:ok, second} =
             Store.send_message("bob", %{
               "receiver" => "alice",
               "receiverType" => "user",
               "data" => %{"text" => "new after hide"}
             })

    assert {:ok, [%{"latestMessageId" => latest_id}]} = Store.conversations("alice")
    assert latest_id == to_string(second["id"])
  end

  test "group deletion removes group state, indexes, messages, reactions, and thread lists" do
    assert {:ok, _group} = Store.upsert_group(%{"guid" => "delete-room", "type" => "public"})
    assert {:ok, _members} = Store.add_group_members("delete-room", ["alice", "bob"])
    assert {:ok, _ban} = Store.ban_group_member("delete-room", "carol")

    assert {:ok, parent} =
             Store.send_message("alice", %{
               "receiver" => "delete-room",
               "receiverType" => "group",
               "data" => %{"text" => "parent"}
             })

    assert {:ok, reply} =
             Store.send_message("bob", %{
               "receiver" => "delete-room",
               "receiverType" => "group",
               "parentId" => parent["id"],
               "data" => %{"text" => "reply"}
             })

    assert {:ok, _message} = Store.add_reaction("bob", parent["id"], "👍")
    assert {:ok, _read} = Store.mark_read("bob", "group", "delete-room", reply["id"])
    assert {:ok, _hidden} = Store.hide_conversation("alice", "group", "delete-room")

    assert {:ok, _deleted} = Store.delete_group("delete-room")

    assert :error = Store.get_group("delete-room")
    assert {:error, %{"code" => "ERR_GUID_NOT_FOUND"}} = Store.group_members("delete-room")
    assert {:ok, []} = Store.banned_group_members("delete-room")

    assert {:error, %{"code" => "ERR_NOT_A_MEMBER"}} =
             Store.messages_for_group("alice", "delete-room")

    assert :error = Store.get_message(parent["id"])
    assert :error = Store.get_message(reply["id"])
    assert {:ok, []} = Store.messages_for_thread("alice", parent["id"])
    assert {:ok, []} = Store.reactions("bob", parent["id"], "👍")
    assert {:ok, []} = Store.conversations("bob", %{"conversationType" => "group"})
  end

  test "media uploads use configured upload dir and public media base URL" do
    old_upload_dir = Application.get_env(:open_chat, :upload_dir)
    old_media_base_url = Application.get_env(:open_chat, :public_media_base_url)

    upload_dir =
      Path.join(System.tmp_dir!(), "open-chat-test-#{System.unique_integer([:positive])}")

    source_path =
      Path.join(System.tmp_dir!(), "open-chat-source-#{System.unique_integer([:positive])}.png")

    File.mkdir_p!(upload_dir)
    File.write!(source_path, "tiny image payload")

    Application.put_env(:open_chat, :upload_dir, upload_dir)
    Application.put_env(:open_chat, :public_media_base_url, "https://media.example")

    on_exit(fn ->
      Application.put_env(:open_chat, :upload_dir, old_upload_dir)
      Application.put_env(:open_chat, :public_media_base_url, old_media_base_url)
      File.rm_rf!(upload_dir)
      File.rm(source_path)
    end)

    assert {:ok, message} =
             Store.send_message(
               "alice",
               %{"receiver" => "bob", "receiverType" => "user", "caption" => "tiny image"},
               [%Plug.Upload{path: source_path, filename: "tiny.png", content_type: "image/png"}]
             )

    assert [%{"mimeType" => "image/png", "name" => "tiny.png", "size" => 18, "url" => url}] =
             get_in(message, ["data", "attachments"])

    assert get_in(message, ["data", "text"]) == "tiny image"
    assert String.starts_with?(url, "https://media.example/media/")
    assert {:ok, [_uploaded_file]} = File.ls(upload_dir)
  end

  test "direct conversations work when user IDs contain underscores" do
    assert {:ok, _message} =
             Store.send_message("user_one", %{
               "receiver" => "user_two",
               "receiverType" => "user",
               "data" => %{"text" => "underscore ids"}
             })

    assert {:ok, one_view} = Store.conversation("user_one", "user", "user_two")
    assert get_in(one_view, ["conversationWith", "uid"]) == "user_two"

    assert {:ok, two_view} = Store.conversation("user_two", "user", "user_one")
    assert get_in(two_view, ["conversationWith", "uid"]) == "user_one"
  end

  test "reactions are isolated by user and emoji and collapse after removals" do
    assert {:ok, message} =
             Store.send_message("alice", %{
               "receiver" => "bob",
               "receiverType" => "user",
               "data" => %{"text" => "reactable"}
             })

    assert {:ok, _message} = Store.add_reaction("bob", message["id"], "👍")
    assert {:ok, _reacted} = Store.add_reaction("carol", message["id"], "👍")
    assert {:ok, reacted} = Store.add_reaction("bob", message["id"], "🔥")

    assert Enum.find(reacted["data"]["reactions"], &(&1["reaction"] == "👍"))["count"] == 2
    assert Enum.find(reacted["data"]["reactions"], &(&1["reaction"] == "🔥"))["count"] == 1

    assert {:ok, rows} = Store.reactions("bob", message["id"], "👍")
    assert Enum.map(rows, & &1["uid"]) |> Enum.sort() == ["bob", "carol"]

    assert {:ok, after_remove} = Store.remove_reaction("bob", message["id"], "👍")
    thumbs_up = Enum.find(after_remove["data"]["reactions"], &(&1["reaction"] == "👍"))
    assert thumbs_up["count"] == 1
    assert thumbs_up["reactedByMe"] == false

    assert {:ok, after_final_remove} = Store.remove_reaction("carol", message["id"], "👍")
    refute Enum.any?(after_final_remove["data"]["reactions"], &(&1["reaction"] == "👍"))
  end

  test "missing users, groups, messages, muids, and reactions return stable errors" do
    assert :error = Store.get_user("missing-user")
    assert :error = Store.get_group("missing-group")
    assert :error = Store.get_message("404")
    assert :error = Store.find_message_by_muid("missing-muid")

    assert {:error, %{"code" => "ERR_MESSAGE_NOT_FOUND"}} =
             Store.edit_message("alice", "404", %{"data" => %{"text" => "nope"}})

    assert {:error, %{"code" => "ERR_MESSAGE_NOT_FOUND"}} = Store.delete_message("alice", "404")

    assert {:error, %{"code" => "ERR_MESSAGE_NOT_FOUND"}} =
             Store.add_reaction("alice", "404", "👍")

    assert {:error, %{"code" => "ERR_MESSAGE_NOT_FOUND"}} =
             Store.remove_reaction("alice", "404", "👍")

    assert {:error, %{"code" => "ERR_GUID_NOT_FOUND"}} = Store.group_members("missing-group")

    assert {:error, %{"code" => "ERR_GUID_NOT_FOUND"}} =
             Store.add_group_members("missing", ["alice"])
  end

  test "list groups supports search and pagination and reports member counts" do
    for guid <- ["search-room-a", "search-room-b", "other-room"] do
      assert {:ok, _group} = Store.upsert_group(%{"guid" => guid, "name" => "Name #{guid}"})
    end

    assert {:ok, _members} = Store.add_group_members("search-room-a", ["alice", "bob"])

    assert {:ok, [%{"guid" => "search-room-a", "membersCount" => 2}]} =
             Store.list_groups(%{"search" => "search-room", "limit" => 1, "page" => 1})

    assert {:ok, [%{"guid" => "search-room-b", "membersCount" => 0}]} =
             Store.list_groups(%{"search" => "search-room", "limit" => 1, "page" => 2})
  end

  test "blocked user directions and searches are symmetric" do
    assert {:ok, _blocked} = Store.block_users("alice", ["bob", "carol"])
    assert {:ok, _blocked} = Store.block_users("dave", ["alice"])

    assert {:ok, blocked_by_me, meta} =
             Store.blocked_users("alice", %{
               "direction" => "blockedByMe",
               "search" => "bo",
               "per_page" => "10"
             })

    assert [%{"uid" => "bob", "blockedByMe" => true, "hasBlockedMe" => false}] = blocked_by_me
    assert get_in(meta, ["pagination", "total"]) == 1

    assert {:ok, has_blocked_me, _meta} =
             Store.blocked_users("alice", %{"direction" => "hasBlockedMe"})

    assert Enum.map(has_blocked_me, & &1["uid"]) == ["dave"]
    assert [%{"hasBlockedMe" => true}] = has_blocked_me

    assert {:ok, _unblocked} = Store.unblock_users("alice", ["bob"])
    assert {:ok, remaining, _meta} = Store.blocked_users("alice", %{"direction" => "blockedByMe"})
    assert Enum.map(remaining, & &1["uid"]) == ["carol"]
  end

  test "mark unread on the second message rewinds to the first message" do
    {:ok, first} =
      Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "first"}
      })

    {:ok, second} =
      Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "second"}
      })

    assert {:ok, _read} = Store.mark_read("bob", "user", "alice", second["id"])
    assert {:ok, []} = Store.unread_counts("bob", %{"receiverType" => "user"})

    assert {:ok, %{"conversation" => conversation}} =
             Store.mark_unread("bob", "user", "alice", second["id"])

    assert conversation["lastReadMessageId"] == to_string(first["id"])
    assert {:ok, [%{"entityId" => "alice", "count" => 1}]} = Store.unread_counts("bob")
  end

  test "delivery receipts persist a delivered cursor and notify the sender" do
    {:ok, message} =
      Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "deliverable"}
      })

    OpenChat.PubSub.subscribe({:user, "alice"})

    assert {:ok, delivered} = Store.mark_delivered("bob", "user", "alice", message["id"])
    assert delivered["conversationId"] == "user_alice_bob"
    assert delivered["messageId"] == to_string(message["id"])
    assert is_integer(delivered["deliveredAt"])

    assert {:ok, conversation} = Store.conversation("bob", "user", "alice")
    assert conversation["lastDeliveredMessageId"] == to_string(message["id"])
    assert conversation["deliveredAt"] == delivered["deliveredAt"]

    assert_receive {:comet_event,
                    %{
                      "type" => "receipts",
                      "receiver" => "alice",
                      "sender" => "bob",
                      "body" => %{"action" => "delivered"}
                    }}
  end

  test "admin group messages can create a public group while user sends cannot" do
    assert {:error, %{"code" => "ERR_GUID_NOT_FOUND"}} =
             Store.send_message("alice", %{
               "receiver" => "server-created",
               "receiverType" => "group",
               "data" => %{"text" => "client cannot create"}
             })

    assert {:ok, message} =
             Store.send_message(
               "system",
               %{
                 "receiver" => "server-created",
                 "receiverType" => "group",
                 "data" => %{"text" => "server can create"}
               },
               [],
               admin?: true
             )

    assert message["conversationId"] == "group_server-created"

    assert {:ok, %{"guid" => "server-created", "type" => "public"}} =
             Store.get_group("server-created")
  end
end
