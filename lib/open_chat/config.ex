defmodule OpenChat.Config do
  @moduledoc "Runtime configuration helpers."

  @default_request_body_limit 10_000_000
  @default_upload_max_bytes 10_000_000
  @default_upload_allowed_mime_types ~w(
    image/jpeg
    image/png
    image/gif
    image/webp
    video/mp4
    video/webm
    audio/mpeg
    audio/mp4
    audio/ogg
    audio/webm
    application/pdf
    text/plain
  )

  def app_id, do: Application.fetch_env!(:open_chat, :app_id)
  def api_key, do: Application.fetch_env!(:open_chat, :api_key)

  def local_jwt_secret do
    case Application.get_env(:open_chat, :local_jwt_secret) do
      value when value in [nil, ""] -> runtime_secret(:open_chat_local_jwt_secret)
      value -> value
    end
  end

  def region, do: Application.fetch_env!(:open_chat, :region)
  def cors_allowed_origins, do: cors_csv_env(:cors_allowed_origins)
  def host, do: Application.fetch_env!(:open_chat, :host)
  def ws_port, do: Application.fetch_env!(:open_chat, :ws_port)
  def extension_domain, do: Application.fetch_env!(:open_chat, :extension_domain)
  def upload_dir, do: Application.fetch_env!(:open_chat, :upload_dir)

  def request_body_limit,
    do: Application.get_env(:open_chat, :request_body_limit, @default_request_body_limit)

  def upload_max_bytes,
    do: Application.get_env(:open_chat, :upload_max_bytes, @default_upload_max_bytes)

  def upload_allowed_mime_types,
    do: csv_env(:upload_allowed_mime_types, @default_upload_allowed_mime_types)

  def redis_url, do: Application.get_env(:open_chat, :redis_url)
  def redis_key_prefix, do: Application.fetch_env!(:open_chat, :redis_key_prefix)
  def redis_snapshot_key, do: Application.fetch_env!(:open_chat, :redis_snapshot_key)
  def seed_users_json, do: Application.fetch_env!(:open_chat, :seed_users_json)
  def seed_groups_json, do: Application.fetch_env!(:open_chat, :seed_groups_json)
  def accept_uid_tokens?, do: Application.fetch_env!(:open_chat, :accept_uid_tokens)

  def cors_allowed_origin(origin) do
    allowed = cors_allowed_origins()

    cond do
      "*" in allowed -> "*"
      origin in allowed -> origin
      true -> nil
    end
  end

  def settings do
    %{
      "CHAT_HOST" => host(),
      "CHAT_HOST_OVERRIDE" => nil,
      "CHAT_HOST_APP_SPECIFIC" => nil,
      "CHAT_USE_SSL" => true,
      "CHAT_WSS_PORT" => to_string(ws_port()),
      "CHAT_WS_PORT" => to_string(ws_port()),
      "CHAT_API_VERSION" => "v3.0",
      "WS_API_VERSION" => "v3.0",
      "ADMIN_API_HOST" => host(),
      "CLIENT_API_HOST" => host(),
      "MAIN_DOMAIN" => host(),
      "REGION" => region(),
      "MODE" => "DEFAULT",
      "APP_VERSION" => 4,
      "ANALYTICS_PING_DISABLED" => true,
      "ANALYTICS_HOST" => host(),
      "ANALYTICS_VERSION" => "v1",
      "ANALYTICS_USE_SSL" => true,
      "POLLING_ENABLED" => false,
      "DENY_FALLBACK_TO_POLLING" => false,
      "EXTENSION_DOMAIN" => extension_domain(),
      "extensions" => [%{"id" => "reactions", "name" => "reactions"}],
      "SECURED_MEDIA_HOST" => nil,
      "settingsHash" => "open-chat-0.1.0",
      "settingsHashReceivedAt" => OpenChat.Time.now()
    }
  end

  defp runtime_secret(key) do
    case :persistent_term.get(key, nil) do
      nil ->
        secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        :persistent_term.put(key, secret)
        secret

      secret ->
        secret
    end
  end

  defp csv_env(key, fallback) do
    case Application.get_env(:open_chat, key) do
      value when value in [nil, ""] ->
        fallback

      value when is_list(value) ->
        value

      value ->
        value
        |> to_string()
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp cors_csv_env(key) do
    case Application.get_env(:open_chat, key, "*") do
      nil ->
        ["*"]

      "" ->
        []

      value when is_list(value) ->
        value

      value ->
        value
        |> to_string()
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end
end
