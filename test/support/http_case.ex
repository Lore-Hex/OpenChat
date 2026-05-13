defmodule OpenChat.HttpCase do
  use ExUnit.CaseTemplate
  import Plug.Test

  using do
    quote do
      import Plug.Test
      alias OpenChatWeb.Endpoint
      import OpenChat.HttpCase
    end
  end

  setup do
    OpenChat.Store.reset!()
    :ok
  end

  def json(conn) do
    Jason.decode!(conn.resp_body)
  end

  def auth_conn(method, path, body \\ %{}, token \\ "uid:alice") do
    conn(method, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authtoken", token)
    |> OpenChatWeb.Endpoint.call([])
  end

  def admin_conn(method, path, body \\ %{}) do
    conn(method, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("apikey", "local-api-key")
    |> OpenChatWeb.Endpoint.call([])
  end
end
