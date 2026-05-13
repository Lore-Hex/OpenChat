defmodule OpenChat.Store.ConversationView do
  @moduledoc false

  alias OpenChat.Store.{Conversations, Entities, Indexes, Unread}

  def messages(state, conv_id, params) do
    state
    |> get_in(["conversation_messages", conv_id])
    |> List.wrap()
    |> messages_by_ids(state, params)
  end

  def messages_by_ids(ids, state, params) do
    ids
    |> Enum.map(&get_in(state, ["messages", to_s(&1)]))
    |> Enum.reject(&is_nil/1)
    |> filter_messages(params)
    |> paginate_messages(params)
  end

  def ids_for_user(state, uid) do
    indexed = Indexes.conversation_ids_for_user(state, uid)

    legacy_direct =
      state["conversation_messages"]
      |> Map.keys()
      |> Enum.filter(&user_conversation_for?(state, uid, &1))

    (indexed ++ legacy_direct)
    |> Enum.uniq()
    |> Enum.reject(&hidden?(state, uid, &1))
  end

  def build(_state, _uid, nil), do: nil

  def build(state, uid, conv_id) do
    last = latest_message(state, conv_id)

    if is_nil(last) or hidden?(state, uid, conv_id) do
      nil
    else
      type = if String.starts_with?(conv_id, "group_"), do: "group", else: "user"
      latest = to_s(last["id"])
      read = get_in(state, ["reads", uid, conv_id]) || %{}
      delivered = get_in(state, ["delivered", uid, conv_id]) || %{}

      %{
        "conversationId" => conv_id,
        "conversationType" => type,
        "lastMessage" => last,
        "conversationWith" => conversation_with(state, uid, conv_id),
        "unreadMessageCount" => Unread.count(state, uid, conv_id),
        "tags" => [],
        "unreadMentionsCount" => 0,
        "lastReadMessageId" => to_s(read["messageId"] || ""),
        "lastDeliveredMessageId" => to_s(delivered["messageId"] || ""),
        "deliveredAt" => delivered["deliveredAt"],
        "latestMessageId" => latest
      }
    end
  end

  def unread_count_row(state, uid, conv_id, count) do
    case conv_id do
      "group_" <> guid ->
        %{
          "entity" =>
            Entities.with_members_count(
              state["groups"][guid] || Entities.group(%{"guid" => guid}),
              state
            ),
          "entityType" => "group",
          "entityId" => guid,
          "count" => count
        }

      "user_" <> rest ->
        peer = user_peer_uid(state, uid, "user_" <> rest)

        %{
          "entity" =>
            Entities.public_user(state["users"][peer] || Entities.user(%{"uid" => peer})),
          "entityType" => "user",
          "entityId" => peer,
          "count" => count
        }
    end
  end

  def latest_message(state, conv_id), do: Conversations.latest_message(state, conv_id)

  def hidden?(state, uid, conv_id) do
    hidden = get_in(state, ["hidden_conversations", uid, conv_id])
    latest = latest_message(state, conv_id)

    not is_nil(hidden) and
      (is_nil(latest) or to_int(latest["id"]) <= to_int(hidden["messageId"]))
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
    |> Enum.filter(fn message -> not hide_deleted or blank?(message["deletedAt"]) end)
    |> Enum.filter(fn message -> blank?(type) or message["type"] == type end)
    |> Enum.filter(fn message -> blank?(category) or message["category"] == category end)
    |> filter_cursor(cursor_field, timestamp || id, affix)
  end

  defp filter_cursor(messages, _field, nil, _affix), do: messages

  defp filter_cursor(messages, field, value, affix) do
    value_i = to_int(value)
    field = if field == "id", do: "id", else: "sentAt"

    Enum.filter(messages, fn message ->
      v = to_int(message[field])
      if affix == "append", do: v > value_i, else: v < value_i
    end)
  end

  defp paginate_messages(messages, params) do
    params = stringify_keys(params)
    limit = clamp(to_int(params["per_page"] || params["limit"] || 30), 1, 100)
    affix = params["cursorAffix"] || params["affix"] || "prepend"

    messages =
      Enum.sort_by(messages, fn message ->
        {to_int(message["sentAt"]), to_int(message["id"])}
      end)

    messages = if affix == "append", do: messages, else: Enum.reverse(messages)
    Enum.take(messages, limit)
  end

  defp user_conversation_for?(state, uid, "user_" <> _ = conv_id) do
    case latest_message(state, conv_id) do
      %{"sender" => sender, "receiver" => receiver} ->
        uid in [to_s(sender), to_s(receiver)]

      _other ->
        case String.split(conv_id, "_") do
          ["user", a, b] -> uid in [a, b]
          _other -> false
        end
    end
  end

  defp user_conversation_for?(_state, _uid, _conv_id), do: false

  defp conversation_with(state, _uid, "group_" <> guid) do
    state["groups"][guid]
    |> Kernel.||(Entities.group(%{"guid" => guid, "name" => guid}))
    |> Entities.with_members_count(state)
  end

  defp conversation_with(state, uid, "user_" <> _rest = conv_id) do
    peer = user_peer_uid(state, uid, conv_id)
    Entities.public_user(state["users"][peer] || Entities.user(%{"uid" => peer}))
  end

  defp user_peer_uid(state, uid, conv_id) do
    case latest_message(state, conv_id) do
      %{"sender" => sender, "receiver" => receiver} ->
        sender = to_s(sender)
        receiver = to_s(receiver)

        if sender == uid, do: receiver, else: sender

      _other ->
        fallback_user_peer_uid(uid, conv_id)
    end
  end

  defp fallback_user_peer_uid(uid, "user_" <> rest) do
    case String.split(rest, "_", parts: 2) do
      [^uid, peer] -> peer
      [peer, ^uid] -> peer
      [_first, peer] -> peer
      [peer] -> peer
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_s(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp truthy?(value), do: value in [true, 1, "1", "true", "TRUE", "yes"]
  defp blank?(value), do: value in [nil, "", false]
  defp clamp(value, lo, hi), do: value |> Kernel.max(lo) |> Kernel.min(hi)

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, _rest} -> i
      :error -> 0
    end
  end

  defp to_int(value), do: value |> to_s() |> to_int()
end
