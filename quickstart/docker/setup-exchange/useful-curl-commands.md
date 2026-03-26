# Useful curl Commands

Quick reference for querying Canton participants and validators on the quickstart localnet.

## Generate a Shared-Secret JWT

All Canton JSON API v2 calls require a Bearer token. For shared-secret auth:

```bash
TOKEN=$(printf '{"alg":"HS256","typ":"JWT"}' | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=' | { read h; printf '{"sub":"ledger-api-user","aud":"https://canton.network.global","iat":'$(date +%s)',"exp":'$(($(date +%s)+86400))',"iss":"unsafe-auth"}' | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=' | { read p; printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "unsafe" -binary | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=' | { read s; echo "$h.$p.$s"; }; }; })
```

## Port Reference

| Participant | JSON API | Validator API | Ledger API (gRPC) |
|-------------|----------|---------------|-------------------|
| Trading Partner | 1975 | 1903 | 1901 |
| App User | 2975 | 2903 | 2901 |
| App Provider | 3975 | 3903 | 3901 |
| Super Validator | 4975 | 4903 | 4901 |

## Check User Party on a Participant

Query the primary party for the `ledger-api-user` on each participant:

```bash
# App Provider
curl -s http://localhost:3975/v2/users/ledger-api-user \
  -H "Authorization: Bearer $TOKEN" | jq .user.primaryParty

# App User
curl -s http://localhost:2975/v2/users/ledger-api-user \
  -H "Authorization: Bearer $TOKEN" | jq .user.primaryParty

# Trading Partner
curl -s http://localhost:1975/v2/users/ledger-api-user \
  -H "Authorization: Bearer $TOKEN" | jq .user.primaryParty

# Super Validator
curl -s http://localhost:4975/v2/users/ledger-api-user \
  -H "Authorization: Bearer $TOKEN" | jq .user.primaryParty
```

## List All Users on a Participant

Returns all Canton users registered on a participant, including their primary party. Useful for finding external parties that were onboarded with Canton user accounts.

```bash
# List users (adjust pageSize as needed, max 1000)
curl -s "http://localhost:2975/v2/users?pageSize=100" \
  -H "Authorization: Bearer $TOKEN" | jq '.users[] | {id: .id, primaryParty: .primaryParty}'

# Count total users
curl -s "http://localhost:2975/v2/users?pageSize=1000" \
  -H "Authorization: Bearer $TOKEN" | jq '.users | length'
```

## Check if a Party Exists on a Participant

```bash
# Replace <PARTY_ID> with the full party ID (e.g., "trading_partner_quickstart-...::1220...")
curl -s "http://localhost:1975/v2/parties/party?parties=<PARTY_ID>" \
  -H "Authorization: Bearer $TOKEN" | jq .
```

## Check Validator Onboarding Status (DSO Party)

Validators expose a scan-proxy endpoint that returns the DSO party ID. If this responds, the validator is onboarded:

```bash
# App Provider
curl -s http://localhost:3903/api/validator/v0/scan-proxy/dso-party-id | jq .

# App User
curl -s http://localhost:2903/api/validator/v0/scan-proxy/dso-party-id | jq .

# Trading Partner
curl -s http://localhost:1903/api/validator/v0/scan-proxy/dso-party-id | jq .

# Super Validator
curl -s http://localhost:4903/api/validator/v0/scan-proxy/dso-party-id | jq .
```

## Check Connected Synchronizers

```bash
curl -s http://localhost:1975/v2/state/connected-synchronizers \
  -H "Authorization: Bearer $TOKEN" | jq .connectedSynchronizers
```

## List Uploaded Packages

```bash
curl -s http://localhost:1975/v2/packages \
  -H "Authorization: Bearer $TOKEN" | jq '.packageIds | length'
```

## Query Active Contracts for a Party

```bash
# Replace <PARTY_ID> and <TEMPLATE_ID>
curl -s http://localhost:1975/v2/state/active-contracts \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "filter": {
      "filtersByParty": {
        "<PARTY_ID>": {
          "cumulative": [{
            "identifierFilter": {
              "TemplateFilter": {
                "value": { "templateId": "<TEMPLATE_ID>" }
              }
            }
          }]
        }
      }
    },
    "verbose": false
  }' | jq .
```

## Get Ledger End Offset

```bash
curl -s http://localhost:1975/v2/state/ledger-end \
  -H "Authorization: Bearer $TOKEN" | jq .offset
```

## Check Canton Version

No auth required:

```bash
curl -s http://localhost:1975/v2/version | jq .version
```
