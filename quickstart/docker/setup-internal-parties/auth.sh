#!/bin/bash
# Shared authentication helpers for setup-internal-parties scripts.
# Supports both shared-secret (HS256 JWT) and OAuth2 (client_credentials) modes.
#
# Required env vars:
#   AUTH_MODE              — "shared-secret" or "oauth2" (default: shared-secret)
#
# For shared-secret:
#   SHARED_SECRET          — JWT signing secret (default: unsafe)
#   SHARED_SECRET_AUDIENCE — JWT audience (default: https://canton.network.global)
#   SHARED_SECRET_USER     — Default admin user (default: ledger-api-user)
#
# For oauth2:
#   OAUTH2_TOKEN_URL       — Token endpoint URL
#   OAUTH2_CLIENT_ID       — Client ID
#   OAUTH2_CLIENT_SECRET   — Client secret
#   OAUTH2_AUDIENCE        — Audience for the Canton JSON API (optional)
#   OAUTH2_VALIDATOR_AUDIENCE — Audience for the Validator Admin API (optional;
#                               defaults to OAUTH2_AUDIENCE if not set)
#
# Exported functions:
#   get_participant_token  — Get a token for the participant JSON API
#   get_validator_token    — Get a token for the validator admin API
#                            (uses OAUTH2_VALIDATOR_AUDIENCE in oauth2 mode)
#   get_user_token <user>  — Get a token for a specific user (shared-secret only;
#                            in oauth2 mode, returns the participant token)

# Generate a shared-secret JWT (HS256)
_generate_jwt() {
  local sub="$1"
  local aud="$2"
  local secret="$3"
  local now
  now=$(date +%s)
  local exp=$((now + 86400))

  _b64url() {
    openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
  }

  local header
  header=$(printf '{"alg":"HS256","typ":"JWT"}' | _b64url)
  local payload
  payload=$(printf '{"sub":"%s","aud":"%s","iat":%d,"exp":%d,"iss":"unsafe-auth"}' "$sub" "$aud" "$now" "$exp" | _b64url)
  local signature
  signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$secret" -binary | _b64url)

  echo "${header}.${payload}.${signature}"
}

# Get OAuth2 client_credentials token
_get_oauth2_token() {
  local token_url="$1"
  local client_id="$2"
  local client_secret="$3"
  local audience="${4:-}"

  local args=(-s -S -w "\n%{http_code}" "$token_url"
    -H 'Content-Type: application/x-www-form-urlencoded'
    -d "client_id=${client_id}"
    -d "client_secret=${client_secret}"
    -d 'grant_type=client_credentials')

  if [ -n "$audience" ]; then
    args+=(-d "audience=${audience}")
  fi

  local response
  response=$(curl "${args[@]}")

  local http_code
  http_code=$(echo "$response" | tail -n1 | tr -d '\r')
  local response_body
  response_body=$(echo "$response" | sed '$d')

  if [ "$http_code" -ne "200" ] && [ "$http_code" -ne "201" ]; then
    echo "[auth] ERROR: OAuth2 token request to $token_url failed with HTTP $http_code" >&2
    echo "[auth] ERROR: Client ID: $client_id, Audience: ${audience:-<empty>}" >&2
    echo "[auth] ERROR: Response: $response_body" >&2
    return 1
  fi

  local token
  token=$(echo "$response_body" | jq -r '.access_token // empty')
  if [ -z "$token" ]; then
    echo "[auth] ERROR: OAuth2 response missing access_token" >&2
    echo "[auth] ERROR: Response: $response_body" >&2
    return 1
  fi

  echo "$token"
}

# Get a token for the participant JSON API
get_participant_token() {
  if [ "${AUTH_MODE:-shared-secret}" = "oauth2" ]; then
    _get_oauth2_token "$OAUTH2_TOKEN_URL" "$OAUTH2_CLIENT_ID" "$OAUTH2_CLIENT_SECRET" "${OAUTH2_AUDIENCE:-}"
  else
    _generate_jwt "${SHARED_SECRET_USER:-ledger-api-user}" "${SHARED_SECRET_AUDIENCE:-https://canton.network.global}" "${SHARED_SECRET:-unsafe}"
  fi
}

# Get a token for the validator admin API
# On devnet, the validator may require a different audience than the JSON API.
get_validator_token() {
  if [ "${AUTH_MODE:-shared-secret}" = "oauth2" ]; then
    local val_audience="${OAUTH2_VALIDATOR_AUDIENCE:-${OAUTH2_AUDIENCE:-}}"
    _get_oauth2_token "$OAUTH2_TOKEN_URL" "$OAUTH2_CLIENT_ID" "$OAUTH2_CLIENT_SECRET" "$val_audience"
  else
    _generate_jwt "${SHARED_SECRET_USER:-ledger-api-user}" "${SHARED_SECRET_AUDIENCE:-https://canton.network.global}" "${SHARED_SECRET:-unsafe}"
  fi
}

# Get a token for a specific Canton user (for acting as that user)
# In oauth2 mode, there's no per-user token — the main participant token is used.
get_user_token() {
  local user="$1"
  if [ "${AUTH_MODE:-shared-secret}" = "oauth2" ]; then
    get_participant_token
  else
    _generate_jwt "$user" "${SHARED_SECRET_AUDIENCE:-https://canton.network.global}" "${SHARED_SECRET:-unsafe}"
  fi
}
