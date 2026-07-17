#!/usr/bin/env bash
#
# Starts the Deepgram Agentic Tools MCP server + an ngrok HTTPS tunnel, then
# prints the public /mcp URL to paste into CyberArk SAIA's "Server URL" field.
#
# Prereqs (one-time):
#   - .env contains DEEPGRAM_API_KEY=...
#   - ./ngrok config add-authtoken <your_token>
#
# Usage:
#   ./run.sh                      # ephemeral ngrok URL
#   NGROK_DOMAIN=your.ngrok.app ./run.sh   # pin to your reserved ngrok domain
#
# Stop everything with Ctrl+C.

set -euo pipefail
cd "$(dirname "$0")"

PORT="${MCP_PORT:-8787}"
PY="./venv/bin/python"
NGROK_BIN="${NGROK_BIN:-}"

if [ ! -x "$PY" ]; then
  echo "ERROR: venv not found. Run: python3 -m venv --copies venv && ./venv/bin/pip install -r requirements.txt" >&2
  exit 1
fi
if [ ! -f .env ] || ! grep -q '^DEEPGRAM_API_KEY=..' .env; then
  echo "ERROR: put DEEPGRAM_API_KEY=... in .env" >&2
  exit 1
fi
if [ -z "$NGROK_BIN" ]; then
  if command -v ngrok >/dev/null 2>&1; then
    NGROK_BIN="$(command -v ngrok)"
  elif [ -x "./ngrok" ]; then
    NGROK_BIN="./ngrok"
  else
    echo "ERROR: ngrok not found. Install ngrok or set NGROK_BIN=/path/to/ngrok." >&2
    exit 1
  fi
fi

cleanup() {
  echo; echo ">> stopping..."
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "${NGROK_PID:-}" ] && kill "$NGROK_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo ">> starting MCP server on 127.0.0.1:${PORT}"
"$PY" deepgram_tools_mcp.py --host 127.0.0.1 --port "$PORT" >/tmp/dg_mcp_server.log 2>&1 &
SERVER_PID=$!
sleep 3

echo ">> starting ngrok tunnel"
if [ -n "${NGROK_DOMAIN:-}" ]; then
  "$NGROK_BIN" http "$PORT" --domain "$NGROK_DOMAIN" --log stdout --log-format logfmt >/tmp/dg_ngrok.log 2>&1 &
else
  "$NGROK_BIN" http "$PORT" --log stdout --log-format logfmt >/tmp/dg_ngrok.log 2>&1 &
fi
NGROK_PID=$!

# Wait for the ngrok local API to report the public URL.
PUB=""
for _ in $(seq 1 20); do
  PUB=$(curl -sS http://127.0.0.1:4040/api/tunnels 2>/dev/null \
    | "$PY" -c 'import json,sys
try: d=json.load(sys.stdin)
except: sys.exit()
print(next((t["public_url"] for t in d.get("tunnels",[]) if t.get("public_url","").startswith("https")), ""))' 2>/dev/null || true)
  [ -n "$PUB" ] && break
  sleep 1
done

if [ -z "$PUB" ]; then
  echo "ERROR: could not get ngrok URL. See /tmp/dg_ngrok.log" >&2
  exit 1
fi

echo
echo "============================================================"
echo "  Deepgram MCP is live."
echo
echo "  Paste this into SAIA -> Register MCP server -> Server URL:"
echo
echo "      ${PUB}/mcp"
echo
echo "  Authentication method: None (CyberArk brokers/audits access)"
echo "============================================================"
echo
echo ">> server log: /tmp/dg_mcp_server.log   ngrok log: /tmp/dg_ngrok.log"
echo ">> Press Ctrl+C to stop."
wait
