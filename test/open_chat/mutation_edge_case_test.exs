defmodule OpenChat.MutationEdgeCaseTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store

  setup do
    Store.reset!()
    :ok
  end

  test "cannot send message to a deactivated user" do
    Store.ensure_user("active_sender")
    Store.ensure_user("deactivated_receiver")
    Store.delete_user("deactivated_receiver")

    result = Store.send_message("active_sender", %{
      "receiver" => "deactivated_receiver",
      "receiverType" => "user",
      "data" => %{"text" => "hello"}
    })

    # This should probably fail
    assert {:error, %{"code" => "ERR_UID_NOT_FOUND"}} = result
  end

  test "cannot send message from a deactivated user (as non-admin)" do
    Store.ensure_user("deactivated_sender")
    Store.delete_user("deactivated_sender")

    result = Store.send_message("deactivated_sender", %{
      "receiver" => "alice",
      "receiverType" => "user",
      "data" => %{"text" => "hello"}
    }, [], admin?: false)

    assert {:error, %{"code" => "ERR_NO_AUTH"}} = result
  end

  test "deleting an already deleted message returns the same action" do
    {:ok, msg} = Store.send_message("alice", %{
      "receiver" => "bob",
      "receiverType" => "user",
      "data" => %{"text" => "delete me"}
    })

    {:ok, action1} = Store.delete_message("alice", msg["id"])
    assert action1["data"]["action"] == "deleted"

    # Second delete
    result = Store.delete_message("alice", msg["id"])
    assert {:error, %{"message" => "Deleted messages cannot be edited or deleted."}} = result
  end
end
