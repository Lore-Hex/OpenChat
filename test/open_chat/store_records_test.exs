defmodule OpenChat.StoreRecordsTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.Records
  alias OpenChat.Store.Records.{Group, Member, Message, User}

  test "user records are typed internally and expose CometChat-shaped maps" do
    record = Records.new_user(%{uid: "typed-user", metadata: ~s({"ageBand":"teen"})})

    assert %User{} = record
    assert record.uid == "typed-user"
    assert record.metadata == %{"ageBand" => "teen"}

    assert Records.to_map(record) == %{
             "uid" => "typed-user",
             "name" => "typed-user",
             "metadata" => %{"ageBand" => "teen"},
             "role" => "default",
             "status" => "available",
             "lastActiveAt" => record.last_active_at,
             "tags" => []
           }
  end

  test "group and member records normalize compatibility aliases" do
    group = Records.new_group(%{"id" => "typed-room", "ownerUid" => "owner"})
    member = Records.new_member("typed-room", "alice", "members", 123)

    assert %Group{} = group
    assert Records.to_map(group)["guid"] == "typed-room"
    assert Records.to_map(group)["owner"] == "owner"

    assert %Member{} = member

    assert Records.to_map(member) == %{
             "uid" => "alice",
             "guid" => "typed-room",
             "scope" => "participant",
             "role" => "participant",
             "joinedAt" => 123
           }
  end

  test "message records keep domain shape while omitting nil wire fields" do
    message =
      Records.new_message(%{
        id: 42,
        sender: "alice",
        receiver: "bob",
        receiverType: "USER",
        type: "text",
        category: "message",
        data: %{text: "hello"},
        sentAt: 1_700_000_000,
        conversationId: "user_alice_bob"
      })

    assert %Message{} = message

    assert Records.to_map(message) == %{
             "id" => 42,
             "sender" => "alice",
             "receiver" => "bob",
             "receiverType" => "user",
             "type" => "text",
             "category" => "message",
             "data" => %{"text" => "hello"},
             "sentAt" => 1_700_000_000,
             "updatedAt" => 1_700_000_000,
             "conversationId" => "user_alice_bob"
           }
  end
end
