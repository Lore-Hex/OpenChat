#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
TAG="${OPENCHAT_IMAGE_TAG:-$(git rev-parse --short HEAD)}"
STACK_NAME="${OPENCHAT_STACK_NAME:-openchat-scalable}"
TEMPLATE_FILE="${OPENCHAT_TEMPLATE_FILE:-infra/aws/openchat-ecs-fargate.yaml}"

STAGING_PROFILE="${OPENCHAT_STAGING_PROFILE:-tt-staging}"
PRODUCTION_PROFILE="${OPENCHAT_PRODUCTION_PROFILE:-awsproduction-ttfm}"

STAGING_ACCOUNT="036958288468"
PRODUCTION_ACCOUNT="829838608284"

STAGING_DOMAIN="openchat.staging.tt.fm"
PRODUCTION_DOMAIN="openchat.prod.tt.fm"

STAGING_CORS_ALLOWED_ORIGINS="${OPENCHAT_STAGING_CORS_ALLOWED_ORIGINS:-https://staging.hang.fm,https://staging.tt.live,https://staging.hangout.fm,http://localhost:3000,http://localhost:4173,http://localhost:5173}"
PRODUCTION_CORS_ALLOWED_ORIGINS="${OPENCHAT_PRODUCTION_CORS_ALLOWED_ORIGINS:-https://hang.fm,https://www.hang.fm,https://hangout.fm,https://www.hangout.fm,https://tt.live,https://www.tt.live}"

STAGING_HOSTED_ZONE_ID="Z012303725HTFF0I5JI42"
PRODUCTION_HOSTED_ZONE_ID="Z10095773LLWNGK1FKJ1Q"

STAGING_VPC_ID="vpc-79269412"
STAGING_SUBNET_1="subnet-a0c366cb"
STAGING_SUBNET_2="subnet-9d1f0ce7"

PRODUCTION_VPC_ID="vpc-9973f1f2"
PRODUCTION_SUBNET_1="subnet-570ca63c"
PRODUCTION_SUBNET_2="subnet-61bb581c"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_command aws
require_command docker
require_command git
require_command jq

if [ "${ALLOW_DIRTY:-false}" != "true" ] && [ -n "$(git status --porcelain)" ]; then
  echo "Refusing to deploy with a dirty worktree. Set ALLOW_DIRTY=true to override." >&2
  git status --short >&2
  exit 1
fi

check_account() {
  local profile="$1"
  local expected="$2"
  local actual

  actual="$(aws sts get-caller-identity --profile "$profile" --region "$REGION" --query Account --output text)"

  if [ "$actual" != "$expected" ]; then
    echo "Refusing to use profile $profile: expected account $expected, got $actual" >&2
    exit 1
  fi
}

ensure_ecr_repo() {
  local profile="$1"

  aws ecr describe-repositories \
    --profile "$profile" \
    --region "$REGION" \
    --repository-names openchat >/dev/null 2>&1 ||
    aws ecr create-repository \
      --profile "$profile" \
      --region "$REGION" \
      --repository-name openchat >/dev/null
}

ecr_auth() {
  local profile="$1"
  local password

  password="$(aws ecr get-login-password --profile "$profile" --region "$REGION")"
  printf 'AWS:%s' "$password" | base64 | tr -d '\n'
}

build_and_push() {
  local staging_registry="$STAGING_ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
  local production_registry="$PRODUCTION_ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
  local staging_auth production_auth auth_config

  ensure_ecr_repo "$STAGING_PROFILE"
  ensure_ecr_repo "$PRODUCTION_PROFILE"

  staging_auth="$(ecr_auth "$STAGING_PROFILE")"
  production_auth="$(ecr_auth "$PRODUCTION_PROFILE")"

  auth_config="$(jq -n \
    --arg sr "$staging_registry" --arg sa "$staging_auth" \
    --arg pr "$production_registry" --arg pa "$production_auth" \
    '{auths:{($sr):{auth:$sa},($pr):{auth:$pa}}}')"

  DOCKER_AUTH_CONFIG="$auth_config" docker buildx build --platform linux/arm64 \
    -t "$staging_registry/openchat:$TAG" \
    -t "$staging_registry/openchat:latest" \
    -t "$production_registry/openchat:$TAG" \
    -t "$production_registry/openchat:latest" \
    --push .
}

admin_key() {
  local env_name="$1"
  local env_var="$2"
  local file_var="$3"
  local default_file="$4"

  if [ -n "${!env_var:-}" ]; then
    printf '%s' "${!env_var}"
    return
  fi

  local key_file="${!file_var:-$default_file}"
  if [ -s "$key_file" ]; then
    cat "$key_file"
    return
  fi

  echo "Missing $env_name admin API key. Set $env_var or $file_var." >&2
  exit 1
}

deploy_env() {
  local env_name="$1"
  local profile="$2"
  local account="$3"
  local domain="$4"
  local hosted_zone_id="$5"
  local vpc_id="$6"
  local subnet_1="$7"
  local subnet_2="$8"
  local admin_api_key="$9"
  local cors_allowed_origins="${10}"
  local image_uri="$account.dkr.ecr.$REGION.amazonaws.com/openchat:$TAG"

  aws cloudformation deploy \
    --profile "$profile" \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --template-file "$TEMPLATE_FILE" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      EnvironmentName="$env_name" \
      DomainName="$domain" \
      HostedZoneId="$hosted_zone_id" \
      VpcId="$vpc_id" \
      PublicSubnet1="$subnet_1" \
      PublicSubnet2="$subnet_2" \
      ImageUri="$image_uri" \
      AdminApiKey="$admin_api_key" \
      CorsAllowedOrigins="$cors_allowed_origins"
}

verify_env() {
  local profile="$1"
  local cluster="$2"
  local task_family="$3"
  local domain="$4"
  local account="$5"

  aws ecs describe-services \
    --profile "$profile" \
    --region "$REGION" \
    --cluster "$cluster" \
    --services openchat \
    --query 'services[0].[status,desiredCount,runningCount,pendingCount,deployments[0].rolloutState]' \
    --output text

  aws ecs describe-task-definition \
    --profile "$profile" \
    --region "$REGION" \
    --task-definition "$task_family" \
    --query 'taskDefinition.containerDefinitions[?name==`openchat`].image' \
    --output text | grep -F "$account.dkr.ecr.$REGION.amazonaws.com/openchat:$TAG" >/dev/null

  curl -fsS "https://$domain/v3.0/settings" |
    jq -e --arg domain "$domain" '.data.CHAT_HOST == $domain and .data.CHAT_WSS_PORT == "443"' >/dev/null
}

main() {
  check_account "$STAGING_PROFILE" "$STAGING_ACCOUNT"
  check_account "$PRODUCTION_PROFILE" "$PRODUCTION_ACCOUNT"

  echo "Building and pushing OpenChat image tag $TAG"
  build_and_push

  local staging_key production_key
  staging_key="$(admin_key staging OPENCHAT_STAGING_ADMIN_API_KEY OPENCHAT_STAGING_ADMIN_API_KEY_FILE /tmp/openchat-staging-admin-key)"
  production_key="$(admin_key production OPENCHAT_PRODUCTION_ADMIN_API_KEY OPENCHAT_PRODUCTION_ADMIN_API_KEY_FILE /tmp/openchat-prod-admin-key)"

  echo "Deploying staging"
  deploy_env staging "$STAGING_PROFILE" "$STAGING_ACCOUNT" "$STAGING_DOMAIN" "$STAGING_HOSTED_ZONE_ID" \
    "$STAGING_VPC_ID" "$STAGING_SUBNET_1" "$STAGING_SUBNET_2" "$staging_key" "$STAGING_CORS_ALLOWED_ORIGINS"

  echo "Deploying production"
  deploy_env production "$PRODUCTION_PROFILE" "$PRODUCTION_ACCOUNT" "$PRODUCTION_DOMAIN" "$PRODUCTION_HOSTED_ZONE_ID" \
    "$PRODUCTION_VPC_ID" "$PRODUCTION_SUBNET_1" "$PRODUCTION_SUBNET_2" "$production_key" "$PRODUCTION_CORS_ALLOWED_ORIGINS"

  echo "Verifying staging"
  verify_env "$STAGING_PROFILE" openchat-staging openchat-staging "$STAGING_DOMAIN" "$STAGING_ACCOUNT"

  echo "Verifying production"
  verify_env "$PRODUCTION_PROFILE" openchat-production openchat-production "$PRODUCTION_DOMAIN" "$PRODUCTION_ACCOUNT"

  echo "OpenChat $TAG deployed to staging and production."
}

main "$@"
