defmodule OpenChatWeb.JSON do
  @moduledoc false
  import Plug.Conn

  def ok(conn, data, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"data" => data}))
  end

  def raw(conn, body, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  def error(conn, error, status \\ 400) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => error}))
  end
end
