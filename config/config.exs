import Config

default_api_key = if config_env() == :prod, do: "", else: "local-api-key"
default_local_jwt_secret = if config_env() == :prod, do: "", else: "local-jwt-secret"

accept_uid_tokens =
  case System.get_env("ACCEPT_UID_TOKENS") do
    "true" -> true
    "false" -> false
    nil -> config_env() == :test
    _other -> false
  end

config :logger, :default_formatter, format: "[$level] $message\n"

config :open_chat,
  port: String.to_integer(System.get_env("PORT") || "4000"),
  host: System.get_env("PUBLIC_HOST") || "localhost",
  ws_port: System.get_env("PUBLIC_WS_PORT") || System.get_env("PORT") || "4000",
  app_id: System.get_env("COMETCHAT_APP_ID") || "local-app",
  api_key: System.get_env("COMETCHAT_API_KEY") || default_api_key,
  local_jwt_secret:
    System.get_env("LOCAL_JWT_SECRET") || System.get_env("COMETCHAT_API_KEY") ||
      default_local_jwt_secret,
  region: System.get_env("COMETCHAT_REGION") || "us",
  extension_domain:
    System.get_env("EXTENSION_DOMAIN") || System.get_env("PUBLIC_HOST") || "localhost",
  upload_dir: System.get_env("UPLOAD_DIR") || "priv/static/uploads",
  public_media_base_url: System.get_env("PUBLIC_MEDIA_BASE_URL"),
  redis_url: System.get_env("REDIS_URL"),
  redis_key_prefix: System.get_env("REDIS_KEY_PREFIX") || "open_chat",
  redis_snapshot_key: System.get_env("REDIS_SNAPSHOT_KEY") || "open_chat:snapshot:v1",
  seed_users_json: System.get_env("SEED_USERS_JSON"),
  seed_groups_json: System.get_env("SEED_GROUPS_JSON"),
  accept_uid_tokens: accept_uid_tokens
