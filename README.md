# Deepgram Agentic Tools — MCP Server for CyberArk Secure AI Agents (SAIA)

A small, self-hosted **Model Context Protocol (MCP)** server that exposes Deepgram's
core developer tools — speech-to-text, text-to-speech, text intelligence, model
listing, and usage — so an AI agent can call them **through CyberArk Secure AI
Agents (SAIA / Idira)**, with the CyberArk Identity Broker enforcing and auditing
access.

It speaks **Streamable HTTP** MCP and is deployed to **AWS App Runner** for a
permanent, stable HTTPS endpoint that is compliant with corporate network security
policies.

---

## Table of contents

- [Why this project exists](#why-this-project-exists)
- [What it does](#what-it-does)
- [Architecture](#architecture)
- [Authentication model (why "None" in SAIA)](#authentication-model-why-none-in-saia)
- [Prerequisites](#prerequisites)
- [AWS App Runner deployment (recommended)](#aws-app-runner-deployment-recommended)
- [Local development (optional)](#local-development-optional)
- [Registering the server in SAIA](#registering-the-server-in-saia)
- [Testing with Claude](#testing-with-claude)
- [The tools](#the-tools)
- [Corporate TLS inspection / `truststore`](#corporate-tls-inspection--truststore)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)
- [Security notes](#security-notes)
- [Appendix: the Deepgram "docs MCP" red herring](#appendix-the-deepgram-docs-mcp-red-herring)

---

## Why this project exists

The goal was to demo CyberArk's **Secure AI Agents (SAIA)** brokering an agent's
access to a real third-party MCP server — specifically Deepgram's speech tools
(`transcribe_audio`, `synthesize_speech`, `analyze_text`, `list_models`,
`get_usage`).

During setup we discovered two things that make a purpose-built server necessary:

1. **Deepgram's published `deepgram-mcp` package and `dg mcp` CLI do not actually
   serve those agentic tools.** Both proxy to `https://api.dx.deepgram.com/kapa/mcp`,
   which is Deepgram's **documentation Q&A** server (powered by kapa.ai). A live
   `tools/list` against it returns exactly one tool:
   `search_deepgram_knowledge_sources`. See the
   [appendix](#appendix-the-deepgram-docs-mcp-red-herring) for the evidence.

2. **SAIA registers _remote_ MCP servers by URL** (it discovers the server over
   HTTPS and requires either OAuth 2.1 or "None" auth). Deepgram's real speech
   tools are only reachable via its **REST API** with an API key — there is no
   hosted MCP endpoint for them.

So this project **wraps Deepgram's REST API in a proper MCP server** that we
self-host and expose over HTTPS, then register in SAIA. This is also the cleanest
SAIA story: the underlying server has no user-facing auth, so **CyberArk becomes
the authorization + audit layer.**

## What it does

`deepgram_tools_mcp.py` is a FastMCP (Streamable HTTP) server that exposes five
tools, each a thin wrapper over a Deepgram REST endpoint:

| MCP tool            | Deepgram REST call                     | Purpose                              |
| ------------------- | -------------------------------------- | ------------------------------------ |
| `transcribe_audio`  | `POST /v1/listen`                      | Speech-to-text (URL or local file)   |
| `synthesize_speech` | `POST /v1/speak`                       | Text-to-speech (Aura), saved to disk |
| `analyze_text`      | `POST /v1/read`                        | Summary, sentiment, topics, intents  |
| `list_models`       | `GET /v1/models`                       | List STT/TTS models                  |
| `get_usage`         | `GET /v1/projects/{id}/usage`          | Account usage (needs `usage:read`)   |

The Deepgram API key is held **server-side** (from `.env`) and is never exposed to
the agent or the MCP client.

## Architecture

```mermaid
flowchart LR
    subgraph Agent side
      A["AI Agent\n(e.g. Claude)"]
    end
    subgraph CyberArk
      B["SAIA / Idira\nIdentity Broker\n(authN + authZ + audit)"]
    end
    subgraph AWS
      R["App Runner\nhttps://xxxx.us-east-1.awsapprunner.com/mcp"]
      SM["Secrets Manager\nDEEPGRAM_API_KEY"]
    end
    D["Deepgram REST API\napi.deepgram.com/v1"]

    A -->|MCP over HTTPS| B
    B -->|forwards to registered Server URL| R
    R -->|reads secret at startup| SM
    R -->|Authorization: Token API_KEY| D
```

Request flow: the agent talks to CyberArk; CyberArk authenticates, authorizes, and
audits the request, then forwards the MCP call to the registered **Server URL** (the
App Runner HTTPS endpoint); App Runner runs the MCP server which calls Deepgram's
REST API using the API key injected from Secrets Manager.

## Why ngrok is required

SAIA registers **remote** MCP servers — it needs a **publicly reachable HTTPS URL**
that its Identity Broker (running in CyberArk's cloud) can call. The MCP server in
this repo runs **locally** on `127.0.0.1:8787`, which CyberArk cannot reach.

**ngrok bridges that gap.** It opens a secure outbound tunnel from your machine to
ngrok's edge and gives you a public `https://<random>.ngrok-free.dev` URL that
forwards inbound requests to your local server. This lets you demo a locally-hosted
MCP server through SAIA without deploying to a cloud host, opening firewall ports,
or provisioning a TLS certificate (ngrok terminates TLS at its edge).

Notes and alternatives:

- **The free ngrok URL changes on every restart.** Re-paste the new URL into SAIA
  after each restart, or use a **reserved ngrok domain** (`NGROK_DOMAIN=... ./run.sh`)
  to keep it stable.
- ngrok is a **demo/dev convenience**, not a production requirement. For a
  persistent deployment, host the server on any HTTPS-reachable endpoint
  (Cloud Run, a VM behind a reverse proxy, etc.) and register that URL instead.
- Any equivalent tunnel (Cloudflare Tunnel, Tailscale Funnel) would also work.

## Authentication model (why "None" in SAIA)


SAIA supports two auth methods for a registered MCP server: **OAuth 2.1** or **None**.

- This server intentionally exposes **no OAuth** on the MCP layer. When SAIA runs
  discovery, the server returns no `WWW-Authenticate` challenge, so SAIA classifies
  it as **Authentication = None**.
- With **None**, CyberArk's Identity Broker becomes the authorization service:
  every agent call is authenticated, authorized, and audited by CyberArk before it
  reaches the server. The human user, the agent identity, the tool used, and the
  target server are all captured in CyberArk's audit trail.
- The Deepgram credential (API key) lives only on the server and is never seen by
  the agent — CyberArk governs *whether the agent may call the tool at all*.

This is the intended demo narrative: **CyberArk secures and audits access to an
otherwise-unauthenticated MCP server.**

## Prerequisites

- A **Deepgram API key** — free at <https://console.deepgram.com>
- An **AWS account** with permissions to use App Runner, IAM, and Secrets Manager
- AWS CLI configured (automatic in CloudShell; or `aws configure` locally)

## AWS App Runner deployment (recommended)

AWS App Runner gives you a **permanent, stable HTTPS URL** with no servers to manage,
no tunneling tools, and automatic TLS — the correct approach for any environment with
corporate network security controls.

### Step 1 — One-time: connect App Runner to GitHub

This is done in the AWS Console (browser) and only needs to be done once.

1. Open: **AWS Console → App Runner → GitHub connections**  
   Direct link: `https://console.aws.amazon.com/apprunner/home#/github-connections`
2. Click **Add new**, authorise GitHub when prompted, complete the setup
3. Copy the **Connection ARN** — you will paste it into `deploy.sh`

### Step 2 — Run the deployment script

The script works from **AWS CloudShell** (no local setup needed) or from any
machine with the AWS CLI configured.

**From AWS CloudShell (recommended):**

```bash
# Open CloudShell from the AWS Console (the terminal icon in the top nav bar)
git clone https://github.com/ChadPapineau/deepgram-mcp-gateway
cd deepgram-mcp-gateway
bash deploy.sh
```

**From a local terminal:**

```bash
git clone https://github.com/ChadPapineau/deepgram-mcp-gateway
cd deepgram-mcp-gateway
bash deploy.sh
```

The script will prompt for:

| Prompt | What to enter |
|--------|---------------|
| AWS Region | e.g. `us-east-1` (or press Enter to use your configured default) |
| Service name | e.g. `deepgram-mcp-gateway` |
| GitHub repo URL | `https://github.com/ChadPapineau/deepgram-mcp-gateway` |
| Branch | `main` |
| GitHub Connection ARN | Paste the ARN from Step 1 |
| Deepgram API key | Your key — stored in Secrets Manager, never committed |

When it finishes (~3 minutes) it prints:

```
╔══════════════════════════════════════════════════════════════╗
║   Deployment complete!                                        ║
║                                                               ║
║  MCP endpoint: https://xxxx.us-east-1.awsapprunner.com/mcp   ║
║                                                               ║
║  Steps to register in CyberArk SAIA (Idira):                 ║
║    1. Open SAIA → Register MCP server                         ║
║    2. Paste the URL above into 'Server URL'                   ║
║    3. Click Discover → Auth method should be 'None'           ║
║    4. Fill in name/category and click Register                ║
╚══════════════════════════════════════════════════════════════╝
```

### Redeploying after code changes

Auto-deploy is enabled — any `git push origin main` automatically triggers a
rebuild and redeploy on App Runner. No manual steps required.

### Rotating the Deepgram API key

Re-run `bash deploy.sh` and enter the new key when prompted. The script updates
Secrets Manager and triggers a fresh deployment.

### Stopping / deleting the service

```bash
# Find the service ARN
aws apprunner list-services --region YOUR_REGION \
  --query "ServiceSummaryList[?ServiceName=='deepgram-mcp-gateway'].ServiceArn" \
  --output text

# Delete it
aws apprunner delete-service --service-arn YOUR_SERVICE_ARN --region YOUR_REGION
```

---

## Local development (optional)

For development and testing only — **not for production or corporate use**.

```bash
# 1) Clone and install
git clone https://github.com/ChadPapineau/deepgram-mcp-gateway
cd deepgram-mcp-gateway
python3 -m venv --copies venv
./venv/bin/pip install -r requirements.txt

# 2) Add your Deepgram API key
echo 'DEEPGRAM_API_KEY=your_key_here' > .env

# 3) Start the server locally
./venv/bin/python deepgram_tools_mcp.py --host 127.0.0.1 --port 8787
```

**Quick local self-test:**

```bash
curl -s -X POST http://127.0.0.1:8787/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

**Health check:**

```bash
curl http://127.0.0.1:8787/health
# → {"status":"ok","server":"deepgram-mcp-gateway"}
```

**Stopping the server:**

```bash
pkill -f deepgram_tools_mcp
```

## Registering the server in SAIA

1. In SAIA, open **Register MCP server**.
2. **MCP server name:** e.g. `DeepgramTools`.
3. **Server URL:** the ngrok URL from `run.sh`, ending in `/mcp`.
4. Click **Discover**. It should set **Authentication method = None**.
5. Fill in Category / Owners / Tags as desired and click **Register**.
6. Connect the server to your AI agent. The agent will now see all five tools.

If **Discover** fails or demands OAuth metadata, the server can be extended with a
`.well-known/oauth-protected-resource` discovery route; open an issue / ask before
adding it, since a plain "None" server generally should not advertise OAuth.

## Testing with Claude

After registering the MCP server in SAIA and adding the Deepgram connector in
claude.ai, use these prompts to verify each tool. Every call is brokered and
audited by CyberArk.

**1. Transcribe audio (speech-to-text)**
> "Transcribe this recording and give me the text: https://dpgr.am/spacewalk.wav"

Exercises `transcribe_audio`. Returns the full transcript and confidence score.

**2. Transcribe + summarize**
> "Transcribe https://dpgr.am/spacewalk.wav and summarize the key points in three
> bullet points."

Exercises `transcribe_audio` with `summarize: true`, then Claude summarises the
result.

**3. Text-to-speech**
> "Use Deepgram to convert this text to speech with the Aura voice: 'Welcome to
> the Secure AI Agents demo, powered by CyberArk and Deepgram.'"

Exercises `synthesize_speech`. Saves an MP3 to `output/` on the server. Play it
locally with:
```bash
afplay output/speech_*.mp3
```

**4. Text intelligence**
> "Analyze the sentiment and main topics of this text: 'The onboarding was rough
> at first, but support was fantastic and the API latency is incredible.'"

Exercises `analyze_text`. Returns sentiment score and extracted topics.

**5. Model discovery**
> "What Deepgram speech-to-text and text-to-speech models are available?"

Exercises `list_models`. Returns the full STT/TTS model catalog.

> **Tip:** After running any of these, show the corresponding entries in CyberArk's
> audit trail — human user → agent identity → tool used → target server — to make
> the SAIA value proposition land in the demo.

---

## The tools

Example arguments (all callable via MCP `tools/call`):

- **`transcribe_audio`** — `{ "url": "https://dpgr.am/spacewalk.wav", "model": "nova-3", "smart_format": true, "diarize": false, "summarize": false }`
  (or `{ "file_path": "/path/to/audio.wav" }`). Returns transcript, confidence, and duration.
- **`synthesize_speech`** — `{ "text": "Hello world", "model": "aura-2-thalia-en" }`.
  Writes an MP3 to `output/` and returns the file path and byte size.
- **`analyze_text`** — `{ "text": "…", "language": "en", "summarize": true, "sentiment": true, "topics": true, "intents": false }`.
- **`list_models`** — no args. Returns STT and TTS model lists.
- **`get_usage`** — `{ "start": "2026-06-01", "end": "2026-07-01" }` (both optional).
  Requires an API key with the `usage:read` scope (Owner/Admin role); otherwise it
  returns a clear "insufficient_permissions" message instead of failing.

## Corporate TLS inspection / `truststore`

On corporate networks (e.g., with a TLS-inspection proxy), Python's default
`certifi` CA bundle does **not** include the corporate root CA, so outbound HTTPS
from Python fails with `CERTIFICATE_VERIFY_FAILED: self-signed certificate in
certificate chain` — even though `curl` works (it uses the OS keychain).

This project uses the [`truststore`](https://pypi.org/project/truststore/) package
and calls `truststore.inject_into_ssl()` at startup so Python uses the **operating
system trust store** (which includes your corporate root CA). If you're on a plain
network this is a harmless no-op.

## Troubleshooting

| Symptom | Cause / Fix |
| ------- | ----------- |
| Claude says "connector's server errored out" | The App Runner service may be paused or deploying. Check its status in the AWS Console → App Runner. |
| `[Errno 2] No such file or directory` on tool calls (local dev) | Stale SSL context after machine sleep. Restart: `pkill -f deepgram_tools_mcp && ./venv/bin/python deepgram_tools_mcp.py`. |
| `SSL: CERTIFICATE_VERIFY_FAILED ... self-signed certificate` (local dev) | Corporate TLS inspection proxy. Handled by `truststore`; ensure it's installed (`pip install -r requirements.txt`). |
| App Runner health check failing | Confirm `/health` returns HTTP 200: `curl https://YOUR_URL/health` |
| `get_usage` returns `insufficient_permissions` | API key lacks `usage:read` scope. Create an Owner/Admin key in the Deepgram console, then re-run `deploy.sh`. |
| `analyze_text` 400 "missing field `language`" | `language` is required by Deepgram's `/v1/read`; the server defaults to `en`. |
| SAIA "discovery failed" on registration | Confirm the URL ends in `/mcp` and `curl https://YOUR_URL/mcp` returns HTTP 200. |
| `deploy.sh` fails: "connection not found" or similar | The GitHub Connection ARN may be wrong or the connection is not in `AVAILABLE` status. Check App Runner → GitHub connections in the console. |
| App Runner build fails (Python version) | App Runner uses `PYTHON_3` runtime (Python 3.12). Ensure `requirements.txt` has no version-pinned packages incompatible with 3.12. |
| `AccessDenied` creating IAM role | Your AWS user/role needs `iam:CreateRole`, `iam:PutRolePolicy`, `iam:GetRole`. Ask your AWS admin to grant these. |

## Repository layout

```
.
├── deepgram_tools_mcp.py          # The MCP server (5 tools, Streamable HTTP + /health)
├── deploy.sh                      # Interactive AWS App Runner deployment script
├── apprunner.yaml                 # App Runner build/run config (used by deploy.sh)
├── Dockerfile                     # Container image (alternative/future ECR deployment)
├── requirements.txt               # Python dependencies
├── run.sh                         # Local development launcher (not for production)
├── list_deepgram_mcp_tools.py     # Diagnostic: proves kapa endpoint is docs-only
├── register-deepgram-oauth-client.sh  # (Optional) DCR helper for Deepgram's OAuth docs endpoint
├── README.md
├── .gitignore
├── .env.example                   # Template — copy to .env for local dev
├── .env                           # NOT committed — holds DEEPGRAM_API_KEY (local dev only)
├── venv/                          # NOT committed — local Python venv
└── output/                        # NOT committed — generated TTS audio (local dev)
```

## Security notes

- **Never commit `.env`** (it holds your Deepgram API key). It is git-ignored.
- In the AWS deployment, the API key is stored in **Secrets Manager** — not in the
  repo, not in App Runner environment config in plain text, and not in any log.
- The API key stays server-side; it is never sent to the agent or MCP client.
- The App Runner HTTPS URL is unauthenticated at the MCP layer — access control is
  enforced by CyberArk SAIA. Share the URL only through the SAIA registration; do
  not paste it in public channels.
- If a key is ever exposed, rotate it in the Deepgram console and re-run `deploy.sh`.

## Appendix: the Deepgram "docs MCP" red herring

Deepgram's docs advertise a `dg mcp` / `deepgram-mcp` server with tools like
`transcribe_audio`. In practice, the shipped code (`deepgram-mcp` 0.1.1 and
`deepctl`'s `deepctl_cmd_mcp`) both call the same `run_proxy()` that connects to:

```
https://api.dx.deepgram.com/kapa/mcp
```

A live `tools/list` against that endpoint (authenticated with a Deepgram API key)
returns a single tool:

```
search_deepgram_knowledge_sources  — semantic retrieval over Deepgram's docs
```

That endpoint also identifies itself as `deepgram-mcp-relay` and is the kapa.ai
documentation assistant — **not** the speech tools. `list_deepgram_mcp_tools.py` in
this repo reproduces that check. This is why we wrap the REST API ourselves rather
than reusing Deepgram's MCP package.

> Separately, `https://api.dx.deepgram.com/kapa/mcp` *is* a fully OAuth 2.1–compliant
> MCP resource (RFC 9728 protected-resource metadata, dynamic client registration at
> `https://id.dx.deepgram.com/register`). `register-deepgram-oauth-client.sh` can
> register an OAuth client there — but it only unlocks the **docs** tool, so it's not
> used in this demo.
