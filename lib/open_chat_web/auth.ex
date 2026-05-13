defmodule OpenChatWeb.Auth do
  @moduledoc false

  import Plug.Conn

  alias OpenChat.{Config, Errors, Store}
  alias OpenChatWeb.JSON

  def with_user(conn, fun) do
    token = token(conn)

    case Store.authenticate(token) do
      {:ok, user} -> fun.(conn, user, token)
      {:error, e} -> JSON.error(conn, e, 401)
    end
  end

  def with_admin(conn, fun) do
    if admin?(conn) do
      fun.(conn)
    else
      JSON.error(conn, Errors.forbidden("Invalid apiKey."), 403)
    end
  end

  def with_admin_or_user(conn, admin_fun, user_fun) do
    api_key = api_key(conn)

    cond do
      blank?(api_key) ->
        user_fun.(conn)

      valid_api_key?(api_key) ->
        admin_fun.(conn)

      true ->
        JSON.error(conn, Errors.forbidden("Invalid apiKey."), 403)
    end
  end

  def admin?(conn), do: valid_api_key?(api_key(conn))

  def token(conn),
    do:
      header(conn, "authtoken") || header(conn, "authToken") || bearer_token(conn) ||
        conn.params["authToken"]

  defp valid_api_key?(api_key) do
    configured = Config.api_key()
    not blank?(configured) and not blank?(api_key) and api_key == configured
  end

  defp api_key(conn), do: header(conn, "apikey") || header(conn, "apiKey")

  defp bearer_token(conn) do
    case header(conn, "authorization") do
      "Bearer " <> token -> token
      "bearer " <> token -> token
      _other -> nil
    end
  end

  defp header(conn, key), do: conn |> get_req_header(String.downcase(key)) |> List.first()

  defp blank?(value), do: value in [nil, "", false]
end
