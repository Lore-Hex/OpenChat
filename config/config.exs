import Config

default_api_key = if config_env() == :prod, do: "", else: "local-api-key"
default_local_jwt_secret = if config_env() == :prod, do: "", else: "local-jwt-secret"
default_cors_allowed_origins = if config_env() == :prod, do: "", else: "*"
default_request_body_limit = 10_000_000
default_upload_max_bytes = 10_000_000

default_upload_allowed_mime_types =
  "image/jpeg,image/png,image/gif,image/webp,video/mp4,video/webm,audio/mpeg,audio/mp4,audio/ogg,audio/webm,application/pdf,text/plain"

config :logger, :default_formatter, format: "[$level] $message\n"

config :open_chat,
  port: 4000,
  host: "localhost",
  ws_port: "4000",
  app_id: "local-app",
  api_key: default_api_key,
  local_jwt_secret: default_local_jwt_secret,
  region: "us",
  cors_allowed_origins: default_cors_allowed_origins,
  extension_domain: "localhost",
  upload_dir: "priv/static/uploads",
  request_body_limit: default_request_body_limit,
  upload_max_bytes: default_upload_max_bytes,
  upload_allowed_mime_types: default_upload_allowed_mime_types,
  public_media_base_url: nil,
  redis_url: nil,
  redis_key_prefix: "open_chat",
  redis_snapshot_key: "open_chat:snapshot:v1",
  seed_users_json: nil,
  seed_groups_json: nil,
  accept_uid_tokens: config_env() == :test
