#!/bin/bash
# Shared authentication helpers for setup-trading-partner scripts.
# Supports both shared-secret (HS256) and OAuth2 (client_credentials) modes.
#
# Required env vars:
#   AUTH_MODE              — "shared-secret" or "oauth2" (default: shared-secret)
#
# For shared-secret (trading-partner node):
#   SHARED_SECRET          — JWT signing secret (default: unsafe)
#   SHARED_SECRET_AUDIENCE — JWT audience (default: https://canton.network.global)
#   SHARED_SECRET_TRADING_PARTNER_USER — Admin user sub claim (default: ledger-api-user)
#
# For oauth2 (trading-partner node):
#   OAUTH2_TOKEN_URL       — Token endpoint URL
#   OAUTH2_CLIENT_ID       — Client ID
#   OAUTH2_CLIENT_SECRET   — Client secret
#   OAUTH2_AUDIENCE        — Audience for the Canton JSON API (optional)
#   OAUTH2_VALIDATOR_AUDIENCE — Audience for the Validator Admin API (optional;
#                               defaults to OAUTH2_AUDIENCE if not set)
#
# App-provider node auth (used by test-trade-request.sh step 3b and
# 04-withdraw-allocation.sh — querying the exchange's participant):
#   AP_AUTH_MODE           — "shared-secret" or "oauth2" (default: shared-secret)
#   AP_SHARED_SECRET_USER  — Admin user sub claim for AP node (default: ledger-api-user)
#   AP_OAUTH2_TOKEN_URL    — Token endpoint for AP node (oauth2 only)
#   AP_OAUTH2_CLIENT_ID    — Client ID for AP node (oauth2 only)
#   AP_OAUTH2_CLIENT_SECRET — Client secret for AP node (oauth2 only)
#   AP_OAUTH2_AUDIENCE     — Audience for AP JSON API (oauth2 only)
#
# Exported functions:
#   get_participant_token  — Admin token for the trading-partner JSON API
#   get_validator_token    — Token for the trading-partner Validator Admin API
#   get_user_token <user>  — Per-user token for the trading-partner node
#                            (in oauth2 mode returns the participant token)
#   get_ap_token           — Token for the app-provider JSON API

# Normalise SHARED_SECRET_USER so functions below always have a consistent var
SHARED_SECRET_USER="${SHARED_SECRET_USER:-${SHARED_SECRET_TRADING_PARTNER_USER:-ledger-api-user}}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

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
  payload=$(printf '{"sub":"%s","aud":"%s","iat":%d,"exp":%d,"iss":"unsafe-auth"}' \
    "$sub" "$aud" "$now" "$exp" | _b64url)
  local signature
  signature=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -hmac "$secret" -binary | _b64url)

  echo "${header}.${payload}.${signature}"
}

# Obtain an OAuth2 client_credentials token
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

  [ -n "$audience" ] && args+=(-d "audience=${audience}")

  local response
  response=$(curl "${args[@]}")

  local http_code
  http_code=$(echo "$response" | tail -n1 | tr -d '\r')
  local body
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" -ne "200" ] && [ "$http_code" -ne "201" ]; then
    echo "[auth] ERROR: OAuth2 token request to $token_url failed with HTTP $http_code" >&2
    echo "[auth] ERROR: Response: $body" >&2
    return 1
  fi

  local token
  token=$(echo "$body" | jq -r '.access_token // empty')
  if [ -z "$token" ]; then
    echo "[auth] ERROR: OAuth2 response missing access_token" >&2
    return 1
  fi

  echo "$token"
}

# ---------------------------------------------------------------------------
# Trading-partner node
# ---------------------------------------------------------------------------

# Admin token for the trading-partner JSON API
get_participant_token() {
  if [ "${AUTH_MODE:-shared-secret}" = "oauth2" ]; then
    _get_oauth2_token "$OAUTH2_TOKEN_URL" "$OAUTH2_CLIENT_ID" \
      "$OAUTH2_CLIENT_SECRET" "${OAUTH2_AUDIENCE:-}"
  else
    _generate_jwt "$SHARED_SECRET_USER" \
      "${SHARED_SECRET_AUDIENCE:-https://canton.network.global}" \
      "${SHARED_SECRET:-unsafe}"
  fi
}

# Token for the trading-partner Validator Admin API
# Some environments use a different audience for the validator API.
get_validator_token() {
  if [ "${AUTH_MODE:-shared-secret}" = "oauth2" ]; then
    local val_aud="${OAUTH2_VALIDATOR_AUDIENCE:-${OAUTH2_AUDIENCE:-}}"
    _get_oauth2_token "$OAUTH2_TOKEN_URL" "$OAUTH2_CLIENT_ID" \
      "$OAUTH2_CLIENT_SECRET" "$val_aud"
  else
    _generate_jwt "$SHARED_SECRET_USER" \
      "${SHARED_SECRET_AUDIENCE:-https://canton.network.global}" \
      "${SHARED_SECRET:-unsafe}"
  fi
}

# Per-user token for acting as a specific party on the trading-partner node.
# In oauth2 mode there is no per-user token — the participant token is returned.
get_user_token() {
  local user="$1"
  if [ "${AUTH_MODE:-shared-secret}" = "oauth2" ]; then
    get_participant_token
  else
    _generate_jwt "$user" \
      "${SHARED_SECRET_AUDIENCE:-https://canton.network.global}" \
      "${SHARED_SECRET:-unsafe}"
  fi
}

# ---------------------------------------------------------------------------
# App-provider node (exchange's Canton participant — used in test and withdraw)
# ---------------------------------------------------------------------------

# Admin token for the app-provider JSON API.
# Defaults to shared-secret so that no extra config is needed when the TP uses
# oauth2 but the exchange side is still on shared-secret (common on localnet).
get_ap_token() {
  if [ "${AP_AUTH_MODE:-shared-secret}" = "oauth2" ]; then
    _get_oauth2_token "$AP_OAUTH2_TOKEN_URL" "$AP_OAUTH2_CLIENT_ID" \
      "$AP_OAUTH2_CLIENT_SECRET" "${AP_OAUTH2_AUDIENCE:-}"
  else
    _generate_jwt "${AP_SHARED_SECRET_USER:-ledger-api-user}" \
      "${SHARED_SECRET_AUDIENCE:-https://canton.network.global}" \
      "${SHARED_SECRET:-unsafe}"
  fi
}
