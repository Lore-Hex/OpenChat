defmodule OpenChatWeb.WSHandler do
  @moduledoc false
  @behaviour :cowboy_websocket

  alias OpenChat.{Config, Store, Time}

  @impl true
  def init(req, _state) do
    {:cowboy_websocket, req, %{uid: nil, token: nil, device_id: nil}}
  end

  @impl true
  def websocket_init(state), do: {:ok, state}

  @impl true
  def websocket_handle({:text, json}, state) do
    case Jason.decode(json) do
      {:ok, %{"type" => "auth"} = event} ->
        handle_auth(event, state)

      {:ok, %{"type" => "receipts"} = event} ->
        handle_receipt(event, state)

      {:ok, %{"type" => "ping"}} ->
        {:reply, {:text, Jason.encode!(%{"action" => "pong"})}, state}

      {:ok, %{"action" => "ping"}} ->
        {:reply, {:text, Jason.encode!(%{"action" => "pong"})}, state}

      {:ok, _other} ->
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  def websocket_handle(:ping, state), do: {:reply, :pong, state}
  def websocket_handle(_frame, state), do: {:ok, state}

  @impl true
  def websocket_info({:comet_event, event}, state),
    do: {:reply, {:text, Jason.encode!(event)}, state}

  def websocket_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _req, _state), do: :ok

  defp handle_auth(event, state) do
    body = event["body"] || %{}
    token = body["auth"] || event["auth"] || body["token"] || event["token"]
    device_id = event["deviceId"] || body["deviceId"] || ""

    case Store.authenticate(token) do
      {:ok, user} ->
        uid = user["uid"]
        OpenChat.PubSub.subscribe({:user, uid})

        case Store.groups_for_user(uid) do
          {:ok, groups} ->
            Enum.each(groups, fn group -> OpenChat.PubSub.subscribe({:group, group["guid"]}) end)

          _ ->
            :ok
        end

        reply = %{
          "appId" => event["appId"] || Config.app_id(),
          "receiver" => event["receiver"] || "",
          "receiverType" => event["receiverType"] || "",
          "deviceId" => device_id,
          "type" => "auth",
          "sender" => uid,
          "body" => %{"status" => "OK", "code" => "200"}
        }

        {:reply, {:text, Jason.encode!(reply)},
         %{state | uid: uid, token: token, device_id: device_id}}

      {:error, error} ->
        reply = %{
          "appId" => event["appId"] || Config.app_id(),
          "receiver" => event["receiver"] || "",
          "receiverType" => event["receiverType"] || "",
          "deviceId" => device_id,
          "type" => "auth",
          "sender" => event["sender"] || "",
          "body" => %{"status" => "ERROR", "code" => error["code"] || "401"}
        }

        {:reply, {:text, Jason.encode!(reply)}, state}
    end
  end

  defp handle_receipt(event, %{uid: uid} = state) when is_binary(uid) and uid != "" do
    body = event["body"] || %{}
    receiver = event["receiver"] || body["receiver"]
    receiver_type = event["receiverType"] || body["receiverType"] || "user"
    message_id = body["messageId"] || body["id"] || "0"
    action = body["action"] || "read"
    timestamp = Time.now()

    delivered? = action in ["delivered", "deliver", "message_delivered"]

    cond do
      action == "read" ->
        Store.mark_read(uid, receiver_type, receiver, message_id)

      delivered? ->
        Store.mark_delivered(uid, receiver_type, receiver, message_id)

      true ->
        :ok
    end

    receipt = put_in(event, ["body", "timestamp"], timestamp)
    targets = if receiver_type == "group", do: [{:group, receiver}], else: [{:user, receiver}]

    unless delivered? do
      OpenChat.PubSub.broadcast(targets, receipt)
    end

    {:ok, state}
  end

  defp handle_receipt(_event, state), do: {:ok, state}
end
