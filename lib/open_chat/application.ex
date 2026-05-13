defmodule OpenChat.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    upload_dir = Application.fetch_env!(:open_chat, :upload_dir)
    File.mkdir_p!(upload_dir)

    port = Application.fetch_env!(:open_chat, :port)

    children = [
      {Registry, keys: :duplicate, name: OpenChat.PubSub},
      OpenChat.Store,
      OpenChat.RedisBus,
      {Plug.Cowboy,
       scheme: :http, plug: OpenChatWeb.Endpoint, options: [port: port, dispatch: dispatch()]}
    ]

    Logger.info("OpenChat listening on :#{port}")
    Supervisor.start_link(children, strategy: :one_for_one, name: OpenChat.Supervisor)
  end

  defp dispatch do
    [
      {:_,
       [
         {"/socket", OpenChatWeb.WSHandler, []},
         {"/ws", OpenChatWeb.WSHandler, []},
         {"/", OpenChatWeb.WSHandler, []},
         {:_, Plug.Cowboy.Handler, {OpenChatWeb.Endpoint, []}}
       ]}
    ]
  end
end
