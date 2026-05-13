defmodule OpenChat.Config do
  @moduledoc "Runtime configuration helpers."

  def app_id, do: Application.fetch_env!(:open_chat, :app_id)
  def api_key, do: Application.fetch_env!(:open_chat, :api_key)

  def local_jwt_secret do
    case Application.get_env(:open_chat, :local_jwt_secret) do
      value when value in [nil, ""] -> runtime_secret(:open_chat_local_jwt_secret)
      value -> value
    end
  end

  def region, do: Application.fetch_env!(:open_chat, :region)
  def host, do: Application.fetch_env!(:open_chat, :host)
  def ws_port, do: Application.fetch_env!(:open_chat, :ws_port)
  def extension_domain, do: Application.fetch_env!(:open_chat, :extension_domain)
  def upload_dir, do: Application.fetch_env!(:open_chat, :upload_dir)
  def redis_url, do: Application.get_env(:open_chat, :redis_url)
  def redis_key_prefix, do: Application.fetch_env!(:open_chat, :redis_key_prefix)
  def redis_snapshot_key, do: Application.fetch_env!(:open_chat, :redis_snapshot_key)
  def seed_users_json, do: Application.fetch_env!(:open_chat, :seed_users_json)
  def seed_groups_json, do: Application.fetch_env!(:open_chat, :seed_groups_json)
  def accept_uid_tokens?, do: Application.fetch_env!(:open_chat, :accept_uid_tokens)

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
end
