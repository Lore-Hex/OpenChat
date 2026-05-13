defmodule OpenChatWeb.WSHandlerTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store
  alias OpenChatWeb.WSHandler

  setup do
    Store.reset!()
    :ok
  end

  test "auth event accepts a valid token and returns the CometChat websocket payload" do
    {:reply, {:text, json}, state} =
      WSHandler.websocket_handle(
        {:text,
         Jason.encode!(%{
           "type" => "auth",
           "appId" => "local-app",
           "deviceId" => "device-1",
           "body" => %{"auth" => "uid:alice"}
         })},
        %{uid: nil, token: nil, device_id: nil}
      )

    reply = Jason.decode!(json)

    assert state.uid == "alice"
    assert state.token == "uid:alice"
    assert state.device_id == "device-1"
    assert reply["type"] == "auth"
    assert reply["sender"] == "alice"
    assert reply["body"] == %{"status" => "OK", "code" => "200"}
  end

  test "auth event returns an error payload for invalid tokens" do
    {:reply, {:text, json}, state} =
      WSHandler.websocket_handle(
        {:text, Jason.encode!(%{"type" => "auth", "body" => %{"auth" => "bad-token"}})},
        %{uid: nil, token: nil, device_id: nil}
      )

    reply = Jason.decode!(json)

    assert state.uid == nil
    assert reply["type"] == "auth"
    assert reply["sender"] == ""
    assert reply["body"]["status"] == "ERROR"
    assert reply["body"]["code"] == "ERR_NO_AUTH"
  end

  test "ping frames and malformed JSON do not mutate websocket state" do
    state = %{uid: "alice", token: "uid:alice", device_id: "device-1"}

    assert {:reply, {:text, pong}, ^state} =
             WSHandler.websocket_handle({:text, Jason.encode!(%{"type" => "ping"})}, state)

    assert Jason.decode!(pong) == %{"action" => "pong"}
    assert {:reply, :pong, ^state} = WSHandler.websocket_handle(:ping, state)
    assert {:ok, ^state} = WSHandler.websocket_handle({:text, "not-json"}, state)
  end

  test "authenticated read receipts update unread counts and broadcast a timestamped receipt" do
    {:ok, message} =
      Store.send_message("bob", %{
        "receiver" => "alice",
        "receiverType" => "user",
        "data" => %{"text" => "please read"}
      })

    assert {:ok, [%{"entityId" => "bob", "count" => 1}]} =
             Store.unread_counts("alice", %{"receiverType" => "user"})

    OpenChat.PubSub.subscribe({:user, "bob"})

    state = %{uid: "alice", token: "uid:alice", device_id: "device-1"}

    assert {:ok, ^state} =
             WSHandler.websocket_handle(
               {:text,
                Jason.encode!(%{
                  "type" => "receipts",
                  "receiver" => "bob",
                  "receiverType" => "user",
                  "body" => %{"messageId" => message["id"], "action" => "read"}
                })},
               state
             )

    assert {:ok, []} = Store.unread_counts("alice", %{"receiverType" => "user"})

    assert_receive {:comet_event, event}
    assert event["type"] == "receipts"
    assert event["receiver"] == "bob"
    assert is_integer(get_in(event, ["body", "timestamp"]))
  end

  test "receipt events are ignored until the websocket is authenticated" do
    {:ok, message} =
      Store.send_message("bob", %{
        "receiver" => "alice",
        "receiverType" => "user",
        "data" => %{"text" => "still unread"}
      })

    assert {:ok, state} =
             WSHandler.websocket_handle(
               {:text,
                Jason.encode!(%{
                  "type" => "receipts",
                  "receiver" => "bob",
                  "receiverType" => "user",
                  "body" => %{"messageId" => message["id"], "action" => "read"}
                })},
               %{uid: nil, token: nil, device_id: nil}
             )

    assert state.uid == nil

    assert {:ok, [%{"entityId" => "bob", "count" => 1}]} =
             Store.unread_counts("alice", %{"receiverType" => "user"})
  end
end
