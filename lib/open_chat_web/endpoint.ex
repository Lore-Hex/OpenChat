defmodule OpenChatWeb.Endpoint do
  @moduledoc false
  use Plug.Router
  @request_body_limit OpenChat.Config.request_body_limit()

  plug(:cors)
  plug(:security_headers)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: @request_body_limit
  )

  plug(:match)
  plug(:dispatch)

  defp cors(conn, _opts) do
    origin = conn |> Plug.Conn.get_req_header("origin") |> List.first()

    conn
    |> put_allow_origin(OpenChat.Config.cors_allowed_origin(origin))
    |> Plug.Conn.put_resp_header(
      "access-control-allow-methods",
      "GET,POST,PUT,PATCH,DELETE,OPTIONS"
    )
    |> Plug.Conn.put_resp_header(
      "access-control-allow-headers",
      "Authorization,Content-Type,Accept,appId,apiKey,authToken,resource,sdk,chatApiVersion,settingsHash,settingsHashReceivedAt"
    )
    |> Plug.Conn.put_resp_header("access-control-expose-headers", "*")
  end

  defp put_allow_origin(conn, nil), do: conn

  defp put_allow_origin(conn, origin) do
    Plug.Conn.put_resp_header(conn, "access-control-allow-origin", origin)
  end

  defp security_headers(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
    |> Plug.Conn.put_resp_header("x-frame-options", "DENY")
    |> Plug.Conn.put_resp_header("referrer-policy", "no-referrer")
  end

  options _ do
    send_resp(conn, 204, "")
  end

  forward("/v3", to: OpenChatWeb.ApiRouter)
  forward("/v3.0", to: OpenChatWeb.ApiRouter)
  forward("/", to: OpenChatWeb.ApiRouter)
end
