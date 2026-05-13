import Config

default_api_key = if config_env() == :prod, do: "", else: "local-api-key"
default_local_jwt_secret = if config_env() == :prod, do: "", else: "local-jwt-secret"
default_cors_allowed_origins = if config_env() == :prod, do: "", else: "*"
default_request_body_limit = 10_000_000
default_upload_max_bytes = 10_000_000

default_upload_allowed_mime_types =
  "image/jpeg,image/png,image/gif,image/webp,video/mp4,video/webm,audio/mpeg,audio/mp4,audio/ogg,audio/webm,application/pdf,text/plain"

integer_env = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value -> String.to_integer(value)
  end
end

accept_uid_tokens =
  case System.get_env("ACCEPT_UID_TOKENS") do
    "true" -> true
    "false" -> false
    nil -> config_env() == :test
    _other -> false
  end

public_host = System.get_env("PUBLIC_HOST") || "localhost"
api_key = System.get_env("COMETCHAT_API_KEY") || default_api_key

config :open_chat,
  port: integer_env.("PORT", 4000),
  host: public_host,
  ws_port: System.get_env("PUBLIC_WS_PORT") || System.get_env("PORT") || "4000",
  app_id: System.get_env("COMETCHAT_APP_ID") || "local-app",
  api_key: api_key,
  local_jwt_secret:
    System.get_env("LOCAL_JWT_SECRET") || System.get_env("COMETCHAT_API_KEY") ||
      default_local_jwt_secret,
  region: System.get_env("COMETCHAT_REGION") || "us",
  cors_allowed_origins: System.get_env("CORS_ALLOWED_ORIGINS") || default_cors_allowed_origins,
  extension_domain: System.get_env("EXTENSION_DOMAIN") || public_host,
  upload_dir: System.get_env("UPLOAD_DIR") || "priv/static/uploads",
  request_body_limit: integer_env.("REQUEST_BODY_LIMIT", default_request_body_limit),
  upload_max_bytes: integer_env.("UPLOAD_MAX_BYTES", default_upload_max_bytes),
  upload_allowed_mime_types:
    System.get_env("UPLOAD_ALLOWED_MIME_TYPES") || default_upload_allowed_mime_types,
  public_media_base_url: System.get_env("PUBLIC_MEDIA_BASE_URL"),
  redis_url: System.get_env("REDIS_URL"),
  redis_key_prefix: System.get_env("REDIS_KEY_PREFIX") || "open_chat",
  redis_snapshot_key: System.get_env("REDIS_SNAPSHOT_KEY") || "open_chat:snapshot:v1",
  seed_users_json: System.get_env("SEED_USERS_JSON"),
  seed_groups_json: System.get_env("SEED_GROUPS_JSON"),
  accept_uid_tokens: accept_uid_tokens
