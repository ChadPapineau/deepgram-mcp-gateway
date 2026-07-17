#!/usr/bin/env bash
#
# Registers an OAuth 2.1 client with Deepgram's authorization server (id.dx.deepgram.com)
# via Dynamic Client Registration (RFC 7591), so it can be used by CyberArk SAIA to
# connect to Deepgram's hosted MCP server (https://api.dx.deepgram.com/kapa/mcp).
#
# Deepgram only issues PUBLIC (PKCE) clients: you get a client_id and NO client secret.
# In the SAIA "Register MCP server" form, paste the client_id into "OAuth app Client ID"
# and leave "Client secret (optional)" blank.
#
# Usage:
#   ./register-deepgram-oauth-client.sh "<SAIA_REDIRECT_URL>" ["<SECOND_REDIRECT_URL>" ...]
#
# Example:
#   ./register-deepgram-oauth-client.sh "https://tiger-prod.data.aigw.cyberark.cloud/mcp/deepgram/oauth/callback"
#
# Get the exact redirect URL from the SAIA "Register MCP server" screen (the "Redirect URL"
# field with the Copy button) after you enter the Server URL and it discovers OAuth 2.1.

set -euo pipefail

REG_ENDPOINT="https://id.dx.deepgram.com/register"

if [ "$#" -lt 1 ]; then
  echo "ERROR: provide at least one redirect URL (copy it from the SAIA form)." >&2
  echo "Usage: $0 \"<SAIA_REDIRECT_URL>\" [\"<SECOND_REDIRECT_URL>\" ...]" >&2
  exit 1
fi

# Build a JSON array of redirect URIs from all args.
redirect_json=$(printf '%s\n' "$@" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')

payload=$(python3 - "$redirect_json" <<'PY'
import json, sys
redirects = json.loads(sys.argv[1])
print(json.dumps({
    "client_name": "CyberArk SAIA - Deepgram MCP",
    "redirect_uris": redirects,
    "grant_types": ["authorization_code", "refresh_token"],
    "response_types": ["code"],
    "token_endpoint_auth_method": "none",
    "scope": "openid profile email usage:listen usage:speak usage:agent",
}))
PY
)

echo ">> Registering OAuth client at ${REG_ENDPOINT}"
echo ">> Redirect URIs: ${redirect_json}"
echo

response=$(curl -sS -X POST "${REG_ENDPOINT}" \
  -H "Content-Type: application/json" \
  -d "${payload}")

echo "----- Raw response -----"
echo "${response}" | python3 -m json.tool 2>/dev/null || echo "${response}"
echo

client_id=$(echo "${response}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("client_id",""))' 2>/dev/null || true)

if [ -n "${client_id}" ]; then
  echo "========================================================"
  echo "  SUCCESS"
  echo "  Paste this into SAIA -> 'OAuth app Client ID':"
  echo
  echo "      ${client_id}"
  echo
  echo "  Leave 'Client secret (optional)' BLANK (public/PKCE client)."
  echo "========================================================"
else
  echo "!! No client_id returned. Check the error above." >&2
  echo "   Common fix: redirect URL must be an exact HTTPS URL with no fragment/wildcard." >&2
  exit 1
fi
