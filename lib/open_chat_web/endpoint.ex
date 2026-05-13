defmodule OpenChatWeb.Endpoint do
  @moduledoc false
  use Plug.Router

  plug(:cors)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 100_000_000
  )

  plug(:match)
  plug(:dispatch)

  defp cors(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
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

  options _ do
    send_resp(conn, 204, "")
  end

  forward("/v3", to: OpenChatWeb.ApiRouter)
  forward("/v3.0", to: OpenChatWeb.ApiRouter)
  forward("/", to: OpenChatWeb.ApiRouter)
end
