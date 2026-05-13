defmodule OpenChat.Store.MessagePermissions do
  @moduledoc false

  alias OpenChat.Errors

  @moderator_scopes MapSet.new(["owner", "admin", "moderator", "coOwner"])

  def authorize(state, actor_uid, message, action, opts \\ []) do
    actor_uid = to_s(actor_uid)

    cond do
      Keyword.get(opts, :admin?, false) ->
        :ok

      blank?(actor_uid) ->
        forbidden(action)

      action_message?(message) ->
        Errors.forbidden("Action messages cannot be edited or deleted.")

      deleted?(message) ->
        Errors.forbidden("Deleted messages cannot be edited or deleted.")

      message_sender?(message, actor_uid) ->
        :ok

      group_moderator?(state, message, actor_uid) ->
        :ok

      true ->
        forbidden(action)
    end
    |> case do
      :ok -> :ok
      error -> {:error, error}
    end
  end

  defp forbidden(:edit),
    do: Errors.forbidden("You can edit only your own messages unless you moderate the group.")

  defp forbidden(:delete),
    do: Errors.forbidden("You can delete only your own messages unless you moderate the group.")

  defp action_message?(message), do: message["category"] == "action"
  defp deleted?(message), do: not blank?(message["deletedAt"])
  defp message_sender?(message, uid), do: to_s(message["sender"]) == uid

  defp group_moderator?(state, %{"receiverType" => "group", "receiver" => guid}, uid) do
    group = get_in(state, ["groups", to_s(guid)]) || %{}
    group_owner?(group, uid) or member_scope(state, guid, uid) in @moderator_scopes
  end

  defp group_moderator?(_state, _message, _uid), do: false

  defp group_owner?(group, uid) do
    [
      group["owner"],
      group["ownerUid"],
      group["ownerUuid"]
    ]
    |> Enum.any?(&(to_s(&1) == uid))
  end

  defp member_scope(state, guid, uid) do
    member = get_in(state, ["members", to_s(guid), uid]) || %{}
    to_s(member["scope"] || member["role"])
  end

  defp blank?(value), do: value in [nil, "", false]

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
