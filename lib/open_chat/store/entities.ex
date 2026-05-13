defmodule OpenChat.Store.Entities do
  @moduledoc false

  alias OpenChat.Time

  def user(attrs) do
    attrs = stringify_keys(attrs)
    uid = to_s(attrs["uid"] || attrs["id"])

    %{
      "uid" => uid,
      "name" => to_s(attrs["name"] || uid),
      "avatar" => attrs["avatar"],
      "link" => attrs["link"],
      "metadata" => normalise_data(attrs["metadata"] || %{}),
      "role" => attrs["role"] || "default",
      "status" => attrs["status"] || "available",
      "statusMessage" => attrs["statusMessage"],
      "lastActiveAt" => attrs["lastActiveAt"] || Time.now(),
      "tags" => attrs["tags"] || [],
      "deactivatedAt" => attrs["deactivatedAt"],
      "authToken" => attrs["authToken"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def public_user(nil), do: nil
  def public_user(user), do: Map.drop(user, ["authToken"])

  def group(attrs) do
    attrs = stringify_keys(attrs)
    guid = to_s(attrs["guid"] || attrs["id"])

    %{
      "guid" => guid,
      "name" => to_s(attrs["name"] || guid),
      "type" => attrs["type"] || "public",
      "password" => attrs["password"],
      "icon" => attrs["icon"],
      "description" => attrs["description"],
      "owner" => attrs["owner"] || attrs["ownerUid"] || attrs["ownerUuid"] || "system",
      "metadata" => normalise_data(attrs["metadata"] || %{}),
      "tags" => attrs["tags"] || [],
      "createdAt" => attrs["createdAt"] || Time.now(),
      "hasJoined" => attrs["hasJoined"] || false,
      "membersCount" => attrs["membersCount"] || 0
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def with_members_count(nil, _state), do: nil

  def with_members_count(group, state) do
    guid = group["guid"]
    count = state["members"] |> Map.get(guid, %{}) |> map_size()
    group |> Map.put("membersCount", count)
  end

  def scope("participants"), do: "participant"
  def scope("members"), do: "participant"

  def scope(scope) when scope in ["owner", "admin", "moderator", "participant"],
    do: scope

  def scope("coOwner"), do: "coOwner"
  def scope(_scope), do: "participant"

  defp normalise_data(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> stringify_keys(decoded)
      {:ok, decoded} -> decoded
      _other -> value
    end
  end

  defp normalise_data(value) when is_map(value), do: stringify_keys(value)
  defp normalise_data(nil), do: %{}
  defp normalise_data(other), do: other

  defp stringify_keys(%{__struct__: _} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_s(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
