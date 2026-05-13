defmodule OpenChat.Store.AuthTokens do
  @moduledoc false

  def lookup_tokens(token) do
    token = to_s(token)

    token
    |> local_jwt_token()
    |> case do
      {:ok, auth_token} -> [auth_token]
      :error -> [token]
    end
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  def local_jwt_token(token) do
    with ["local", payload, "unsigned"] <- String.split(to_s(token), ".", parts: 3),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"token" => auth_token}} <- Jason.decode(json),
         auth_token <- to_s(auth_token),
         false <- blank?(auth_token) do
      {:ok, auth_token}
    else
      _ -> :error
    end
  end

  def uid_token("uid:" <> uid) when uid != "", do: {:ok, uid}
  def uid_token(_token), do: :error

  defp blank?(value), do: value in [nil, "", false]

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
