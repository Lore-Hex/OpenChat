defmodule OpenChat.StoreRegressionTest do
  use ExUnit.Case, async: false

  alias OpenChat.{Store, Time}
  alias OpenChat.Store.AuthTokens

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
    refute String.ends_with?(jwt, ".unsigned")

    tampered = String.replace(jwt, "local.", "localx.", global: false)
    assert {:error, %{"code" => "ERR_NO_AUTH"}} = Store.me(tampered)

    expired = AuthTokens.local_jwt("alice", token, Time.now() - 90_000)
    assert {:error, %{"code" => "ERR_NO_AUTH"}} = Store.me(expired)

    assert {:ok, %{"success" => true}} = Store.revoke_auth_token(token)
    assert {:error, %{"code" => "ERR_NO_AUTH"}} = Store.authenticate(token)
    assert {:error, %{"code" => "ERR_NO_AUTH"}} = Store.me(jwt)
  end

  test "local JWTs reject legacy unsigned, malformed, tampered, and rotated-secret tokens" do
    old_secret = Application.get_env(:open_chat, :local_jwt_secret)

    on_exit(fn ->
      Application.put_env(:open_chat, :local_jwt_secret, old_secret)
    end)

    Application.put_env(:open_chat, :local_jwt_secret, "jwt-secret-a")

    assert {:ok, payload} = Store.create_auth_token("jwt-edge")
    token = payload["authToken"]
    jwt = payload["jwt"]

    assert {:ok, ^token} = AuthTokens.local_jwt_token(jwt)

    ["local", encoded_payload, signature] = String.split(jwt, ".", parts: 3)
    assert signature != "unsigned"

    payload_map = encoded_payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert payload_map["uid"] == "jwt-edge"
    assert payload_map["token"] == token
    assert payload_map["exp"] > payload_map["iat"]

    legacy_unsigned =
      "local." <>
        Base.url_encode64(
          Jason.encode!(%{"uid" => "jwt-edge", "token" => token, "iat" => Time.now()}),
          padding: false
        ) <> ".unsigned"

    assert :error = AuthTokens.local_jwt_token(legacy_unsigned)
    assert :error = AuthTokens.local_jwt_token("local.not-base64.signature")

    tampered_payload =
      payload_map
      |> Map.put("token", "uid:alice")
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert :error = AuthTokens.local_jwt_token("local." <> tampered_payload <> "." <> signature)

    Application.put_env(:open_chat, :local_jwt_secret, "jwt-secret-b")
    assert :error = AuthTokens.local_jwt_token(jwt)
    assert {:error, %{"code" => "ERR_NO_AUTH"}} = Store.me(jwt)
  end

  test "uid developer tokens are runtime gated and not embedded in default seed users" do
    old_accept_uid_tokens = Application.fetch_env!(:open_chat, :accept_uid_tokens)

    on_exit(fn ->
      Application.put_env(:open_chat, :accept_uid_tokens, old_accept_uid_tokens)
      Store.reset!()
    end)

    Application.put_env(:open_chat, :accept_uid_tokens, false)
    Store.reset!()

    assert {:error, %{"code" => "ERR_NO_AUTH"}} = Store.me("uid:alice")
    assert {:error, %{"code" => "ERR_NO_AUTH"}} = Store.me("uid:not-seeded")

    Application.put_env(:open_chat, :accept_uid_tokens, true)
    Store.reset!()

    assert {:ok, %{"uid" => "alice", "authToken" => "uid:alice"}} = Store.me("uid:alice")
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

  test "message edits and deletes require sender or group moderator privileges" do
    assert {:ok, direct} =
             Store.send_message("alice", %{
               "receiver" => "bob",
               "receiverType" => "user",
               "data" => %{"text" => "direct"}
             })

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.edit_message("bob", direct["id"], %{"data" => %{"text" => "nope"}})

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} = Store.delete_message("bob", direct["id"])

    assert {:ok, edited} =
             Store.edit_message("alice", direct["id"], %{"data" => %{"text" => "ok"}})

    assert edited["data"]["action"] == "edited"

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.delete_message("alice", edited["id"])

    guid = "secure-room"

    assert {:ok, _group} =
             Store.upsert_group(%{"guid" => guid, "type" => "public", "owner" => "owner"})

    assert {:ok, _members} = Store.add_group_members(guid, ["alice", "bob"], "participant")
    assert {:ok, _mod} = Store.add_group_members(guid, ["mod"], "moderator")
    assert {:ok, _admin} = Store.add_group_members(guid, ["admin"], "admin")
    assert {:ok, _co_owner} = Store.add_group_members(guid, ["co-owner"], "coOwner")

    assert {:ok, group_message} =
             Store.send_message("alice", %{
               "receiver" => guid,
               "receiverType" => "group",
               "data" => %{"text" => "group"}
             })

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.delete_message("bob", group_message["id"])

    assert {:ok, owner_deleted} = Store.delete_message("owner", group_message["id"])
    assert owner_deleted["data"]["action"] == "deleted"

    assert {:ok, second_group_message} =
             Store.send_message("alice", %{
               "receiver" => guid,
               "receiverType" => "group",
               "data" => %{"text" => "group 2"}
             })

    assert {:ok, mod_deleted} = Store.delete_message("mod", second_group_message["id"])
    assert mod_deleted["data"]["action"] == "deleted"

    assert {:ok, third_group_message} =
             Store.send_message("alice", %{
               "receiver" => guid,
               "receiverType" => "group",
               "data" => %{"text" => "group 3"}
             })

    assert {:ok, admin_edited} =
             Store.edit_message("admin", third_group_message["id"], %{
               "data" => %{"text" => "edited"}
             })

    assert admin_edited["data"]["action"] == "edited"

    assert {:ok, fourth_group_message} =
             Store.send_message("alice", %{
               "receiver" => guid,
               "receiverType" => "group",
               "data" => %{"text" => "group 4"}
             })

    assert {:ok, co_owner_deleted} = Store.delete_message("co-owner", fourth_group_message["id"])
    assert co_owner_deleted["data"]["action"] == "deleted"
  end

  test "actor-aware group member management blocks participant escalation" do
    guid = "member-security-room"

    assert {:ok, _group} =
             Store.upsert_group(%{"guid" => guid, "type" => "public", "ownerUid" => "owner"})

    assert {:ok, _members} = Store.add_group_members(guid, ["participant"], "participant")
    assert {:ok, _moderator} = Store.add_group_members(guid, ["moderator"], "moderator")
    assert {:ok, _co_owner} = Store.add_group_members(guid, ["co-owner"], "coOwner")

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.add_group_members(guid, ["victim"], "admin", actor_uid: "participant")

    assert {:ok, members} = Store.group_members(guid)
    refute Enum.any?(members, &(&1["uid"] == "victim"))

    assert {:ok, _owner_added} =
             Store.add_group_members(guid, ["owner-added"], "participant", actor_uid: "owner")

    assert {:ok, _moderator_added} =
             Store.add_group_members(guid, ["mod-added"], "participant", actor_uid: "moderator")

    assert {:ok, _co_owner_added} =
             Store.add_group_members(guid, ["co-added"], "participant", actor_uid: "co-owner")

    assert {:ok, members} = Store.group_members(guid)
    assert Enum.any?(members, &(&1["uid"] == "owner-added"))
    assert Enum.any?(members, &(&1["uid"] == "mod-added"))
    assert Enum.any?(members, &(&1["uid"] == "co-added"))
  end

  test "server-side admin option can moderate without message ownership" do
    assert {:ok, direct} =
             Store.send_message("alice", %{
               "receiver" => "bob",
               "receiverType" => "user",
               "data" => %{"text" => "before admin edit"}
             })

    assert {:ok, edited} =
             Store.edit_message(
               "moderation-service",
               direct["id"],
               %{
                 "data" => %{"text" => "after admin edit"}
               },
               admin?: true
             )

    assert edited["sender"] == "moderation-service"
    assert get_in(edited, ["data", "action"]) == "edited"

    assert get_in(edited, ["data", "entities", "on", "entity", "editedBy"]) ==
             "moderation-service"

    assert {:ok, group} =
             Store.upsert_group(%{
               "guid" => "owner-uid-room",
               "type" => "public",
               "ownerUid" => "owner-uid"
             })

    assert group["owner"] == "owner-uid"
    assert {:ok, _members} = Store.add_group_members("owner-uid-room", ["alice"], "participant")

    assert {:ok, group_message} =
             Store.send_message("alice", %{
               "receiver" => "owner-uid-room",
               "receiverType" => "group",
               "data" => %{"text" => "owned room"}
             })

    assert {:ok, owner_deleted} = Store.delete_message("owner-uid", group_message["id"])
    assert owner_deleted["data"]["action"] == "deleted"
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

    assert {:error, %{"code" => "ERR_MESSAGE_NOT_FOUND"}} =
             Store.reactions("bob", parent["id"], "👍")

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
    assert {:ok, _reacted} = Store.add_reaction("alice", message["id"], "👍")
    assert {:ok, reacted} = Store.add_reaction("bob", message["id"], "🔥")

    assert Enum.find(reacted["data"]["reactions"], &(&1["reaction"] == "👍"))["count"] == 2
    assert Enum.find(reacted["data"]["reactions"], &(&1["reaction"] == "🔥"))["count"] == 1

    assert {:ok, rows} = Store.reactions("bob", message["id"], "👍")
    assert Enum.map(rows, & &1["uid"]) |> Enum.sort() == ["alice", "bob"]

    assert {:ok, after_remove} = Store.remove_reaction("bob", message["id"], "👍")
    thumbs_up = Enum.find(after_remove["data"]["reactions"], &(&1["reaction"] == "👍"))
    assert thumbs_up["count"] == 1
    assert thumbs_up["reactedByMe"] == false

    assert {:ok, after_final_remove} = Store.remove_reaction("alice", message["id"], "👍")
    refute Enum.any?(after_final_remove["data"]["reactions"], &(&1["reaction"] == "👍"))
  end

  test "message reads, threads, reactions, and receipts require conversation participation" do
    assert {:ok, parent} =
             Store.send_message("alice", %{
               "receiver" => "bob",
               "receiverType" => "user",
               "muid" => "private-parent",
               "data" => %{"text" => "private"}
             })

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.get_message_for("carol", parent["id"])

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.find_message_by_muid_for("carol", "private-parent")

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.messages_for_thread("carol", parent["id"])

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.add_reaction("carol", parent["id"], "👍")

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.reactions("carol", parent["id"])

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.mark_read("carol", "user", "alice", parent["id"])

    assert {:ok, _read} = Store.mark_read("bob", "user", "alice", parent["id"])

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.send_message("carol", %{
               "receiver" => "alice",
               "receiverType" => "user",
               "parentId" => parent["id"],
               "data" => %{"text" => "snoop reply"}
             })
  end

  test "access policy protects group conversations and validates receipt and thread conversations" do
    assert {:ok, _group} = Store.upsert_group(%{"guid" => "policy-room", "type" => "public"})
    assert {:ok, _members} = Store.add_group_members("policy-room", ["alice", "bob"])

    assert {:ok, group_message} =
             Store.send_message("alice", %{
               "receiver" => "policy-room",
               "receiverType" => "group",
               "data" => %{"text" => "group private"}
             })

    assert {:ok, _message} = Store.get_message_for("bob", group_message["id"])
    assert {:ok, _conversation} = Store.conversation("bob", "group", "policy-room")
    assert {:ok, _reaction} = Store.add_reaction("bob", group_message["id"], "👍")

    for result <- [
          Store.get_message_for("carol", group_message["id"]),
          Store.conversation("carol", "group", "policy-room"),
          Store.hide_conversation("carol", "group", "policy-room"),
          Store.mark_read("carol", "group", "policy-room", group_message["id"]),
          Store.mark_unread("carol", "group", "policy-room", group_message["id"]),
          Store.mark_delivered("carol", "group", "policy-room", group_message["id"]),
          Store.remove_reaction("carol", group_message["id"], "👍")
        ] do
      assert {:error, %{"code" => "ERR_FORBIDDEN"}} = result
    end

    assert {:ok, direct_parent} =
             Store.send_message("alice", %{
               "receiver" => "bob",
               "receiverType" => "user",
               "data" => %{"text" => "direct private"}
             })

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.mark_read("alice", "user", "carol", direct_parent["id"])

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.mark_delivered("bob", "user", "carol", direct_parent["id"])

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             Store.send_message("bob", %{
               "receiver" => "carol",
               "receiverType" => "user",
               "parentId" => direct_parent["id"],
               "data" => %{"text" => "wrong conversation reply"}
             })
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
