#!/usr/bin/env python3
"""
Deepgram Agentic Tools — MCP server (Streamable HTTP).

Exposes the core Deepgram developer tools as MCP tools by wrapping Deepgram's
REST API, so an AI agent (brokered/audited by CyberArk SAIA) can call them:

    - transcribe_audio    (speech-to-text  -> POST /v1/listen)
    - synthesize_speech   (text-to-speech  -> POST /v1/speak)
    - analyze_text        (text intelligence -> POST /v1/read)
    - list_models         (GET /v1/models)
    - get_usage           (GET /v1/projects/{id}/usage)

Auth model for the SAIA demo:
    The MCP layer itself is UNAUTHENTICATED (no OAuth) — register it in SAIA with
    Authentication = "None" so CyberArk's Identity Broker becomes the auth/audit
    layer. This server holds the Deepgram API key server-side (from env / .env)
    and never exposes it to the agent.

Run:
    DEEPGRAM_API_KEY=... ./venv/bin/python deepgram_tools_mcp.py --host 127.0.0.1 --port 8787
    # MCP endpoint will be at  http://<host>:<port>/mcp
"""

from __future__ import annotations

import argparse
import base64
import datetime as _dt
import os
import sys
from pathlib import Path
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

# Trust the OS/system certificate store (macOS keychain, corporate root CAs, etc.)
# so TLS-inspection proxies don't break outbound HTTPS. Falls back silently if
# truststore isn't available.
try:
    import truststore as _truststore

    _truststore.inject_into_ssl()
except Exception:  # noqa: BLE001
    pass

DEEPGRAM_API = "https://api.deepgram.com/v1"
HERE = Path(__file__).resolve().parent
OUTPUT_DIR = HERE / "output"


def _load_env() -> None:
    env = HERE / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def _api_key() -> str:
    key = os.getenv("DEEPGRAM_API_KEY")
    if not key:
        raise RuntimeError("DEEPGRAM_API_KEY is not set (env var or .env file).")
    return key


def _headers(json_body: bool = True) -> dict[str, str]:
    h = {"Authorization": f"Token {_api_key()}"}
    if json_body:
        h["Content-Type"] = "application/json"
    return h


async def _get(path: str, params: dict[str, Any] | None = None) -> Any:
    async with httpx.AsyncClient(timeout=60) as client:
        r = await client.get(f"{DEEPGRAM_API}{path}", headers=_headers(False), params=params)
        r.raise_for_status()
        return r.json()


mcp = FastMCP(
    name="Deepgram Agentic Tools",
    instructions=(
        "Deepgram speech, transcription, and audio intelligence tools. "
        "Use transcribe_audio for speech-to-text, synthesize_speech for text-to-speech, "
        "analyze_text for sentiment/topics/summarization, list_models to browse models, "
        "and get_usage for account usage."
    ),
    stateless_http=True,
    json_response=True,
    # The server runs behind an HTTPS tunnel (ngrok) and the CyberArk Identity
    # Broker for the demo, and the external hostname changes, so disable the
    # built-in Host/Origin (DNS-rebinding) validation that would otherwise
    # reject those hostnames with HTTP 421 "Invalid Host header".
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)


@mcp.tool()
async def transcribe_audio(
    url: str | None = None,
    file_path: str | None = None,
    model: str = "nova-3",
    language: str | None = None,
    detect_language: bool = False,
    smart_format: bool = True,
    punctuate: bool = True,
    diarize: bool = False,
    summarize: bool = False,
) -> dict[str, Any]:
    """Transcribe speech to text using Deepgram.

    Provide either `url` (a publicly reachable audio URL) or `file_path` (a local
    audio file path on the server). Returns the transcript plus useful metadata.
    """
    if not url and not file_path:
        return {"error": "Provide either 'url' or 'file_path'."}

    params: dict[str, Any] = {
        "model": model,
        "smart_format": str(smart_format).lower(),
        "punctuate": str(punctuate).lower(),
        "diarize": str(diarize).lower(),
    }
    if summarize:
        params["summarize"] = "v2"
    if detect_language:
        params["detect_language"] = "true"
    elif language:
        params["language"] = language

    async with httpx.AsyncClient(timeout=300) as client:
        if url:
            r = await client.post(
                f"{DEEPGRAM_API}/listen", headers=_headers(True), params=params, json={"url": url}
            )
        else:
            p = Path(file_path)  # type: ignore[arg-type]
            if not p.exists():
                return {"error": f"file_path not found: {file_path}"}
            r = await client.post(
                f"{DEEPGRAM_API}/listen",
                headers={"Authorization": f"Token {_api_key()}", "Content-Type": "audio/*"},
                params=params,
                content=p.read_bytes(),
            )
    if r.status_code != 200:
        return {"error": f"Deepgram {r.status_code}", "detail": r.text[:500]}

    data = r.json()
    try:
        alt = data["results"]["channels"][0]["alternatives"][0]
        out: dict[str, Any] = {
            "transcript": alt.get("transcript", ""),
            "confidence": alt.get("confidence"),
            "model": model,
            "duration_seconds": data.get("metadata", {}).get("duration"),
            "request_id": data.get("metadata", {}).get("request_id"),
        }
        summary = data.get("results", {}).get("summary")
        if summary:
            out["summary"] = summary.get("short") or summary
        return out
    except (KeyError, IndexError):
        return {"raw": data}


@mcp.tool()
async def synthesize_speech(
    text: str,
    model: str = "aura-2-thalia-en",
    encoding: str = "mp3",
) -> dict[str, Any]:
    """Convert text to speech using Deepgram TTS (Aura).

    Saves the audio to ./output and returns the file path, byte size, and a short
    base64 preview. `model` examples: aura-2-thalia-en, aura-2-andromeda-en.
    """
    if not text.strip():
        return {"error": "text is required."}
    params = {"model": model}
    if encoding and encoding != "mp3":
        params["encoding"] = encoding
    async with httpx.AsyncClient(timeout=120) as client:
        r = await client.post(
            f"{DEEPGRAM_API}/speak", headers=_headers(True), params=params, json={"text": text}
        )
    if r.status_code != 200:
        return {"error": f"Deepgram {r.status_code}", "detail": r.text[:500]}

    audio = r.content
    OUTPUT_DIR.mkdir(exist_ok=True)
    ext = "mp3" if encoding == "mp3" else encoding
    ts = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    fname = OUTPUT_DIR / f"speech_{ts}.{ext}"
    fname.write_bytes(audio)
    return {
        "file_path": str(fname),
        "bytes": len(audio),
        "content_type": r.headers.get("content-type"),
        "model": model,
        "audio_base64_preview": base64.b64encode(audio[:96]).decode() + "...",
    }


@mcp.tool()
async def analyze_text(
    text: str | None = None,
    url: str | None = None,
    language: str = "en",
    summarize: bool = True,
    sentiment: bool = True,
    topics: bool = True,
    intents: bool = False,
) -> dict[str, Any]:
    """Run Deepgram text intelligence (Read): summarization, sentiment, topics, intents."""
    if not text and not url:
        return {"error": "Provide either 'text' or 'url'."}
    params: dict[str, Any] = {"language": language}
    if summarize:
        params["summarize"] = "true"
    if sentiment:
        params["sentiment"] = "true"
    if topics:
        params["topics"] = "true"
    if intents:
        params["intents"] = "true"
    body = {"url": url} if url else {"text": text}
    async with httpx.AsyncClient(timeout=120) as client:
        r = await client.post(
            f"{DEEPGRAM_API}/read", headers=_headers(True), params=params, json=body
        )
    if r.status_code != 200:
        return {"error": f"Deepgram {r.status_code}", "detail": r.text[:500]}
    data = r.json()
    results = data.get("results", {})
    out: dict[str, Any] = {}
    if "summary" in results:
        out["summary"] = results["summary"].get("text")
    if "sentiments" in results:
        out["sentiment_average"] = results["sentiments"].get("average")
    if "topics" in results:
        segs = results["topics"].get("segments", [])
        out["topics"] = sorted({t["topic"] for s in segs for t in s.get("topics", [])})
    if "intents" in results:
        segs = results["intents"].get("segments", [])
        out["intents"] = sorted({i["intent"] for s in segs for i in s.get("intents", [])})
    return out or {"raw": data}


@mcp.tool()
async def list_models() -> dict[str, Any]:
    """List available Deepgram models (speech-to-text and text-to-speech)."""
    data = await _get("/models")
    def slim(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
        return [
            {
                "name": m.get("canonical_name") or m.get("name"),
                "languages": m.get("languages"),
                "streaming": m.get("streaming"),
            }
            for m in items
        ]
    return {
        "stt": slim(data.get("stt", [])),
        "tts": slim(data.get("tts", [])),
    }


@mcp.tool()
async def get_usage(start: str | None = None, end: str | None = None) -> dict[str, Any]:
    """Get Deepgram API usage for your project. Optional start/end dates (YYYY-MM-DD)."""
    projects = await _get("/projects")
    plist = projects.get("projects", []) if isinstance(projects, dict) else projects
    if not plist:
        return {"error": "No projects found for this API key."}
    project_id = plist[0].get("project_id")
    params: dict[str, Any] = {}
    if start:
        params["start"] = start
    if end:
        params["end"] = end
    try:
        usage = await _get(f"/projects/{project_id}/usage", params=params or None)
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 403:
            return {
                "project_id": project_id,
                "project_name": plist[0].get("name"),
                "error": "insufficient_permissions",
                "detail": (
                    "The Deepgram API key lacks the 'usage:read' scope. Create an API key "
                    "with an Owner/Admin role (or usage:read scope) in the Deepgram console "
                    "to enable this tool."
                ),
            }
        return {"error": f"Deepgram {e.response.status_code}", "detail": e.response.text[:300]}
    return {
        "project_id": project_id,
        "project_name": plist[0].get("name"),
        "usage": usage,
    }


async def _health(request: Request) -> JSONResponse:
    """Simple liveness probe used by AWS ECS / ALB health checks."""
    return JSONResponse({"status": "ok", "server": "deepgram-mcp-gateway"})


async def _oauth_authorization_server(request: Request) -> JSONResponse:
    """
    RFC 8414 — OAuth 2.0 Authorization Server Metadata.

    CyberArk SAIA calls this endpoint during 'Discover' to determine the MCP
    server's authentication method.  Returning empty response_types and
    grant_types (with no authorization_endpoint) signals that this server has
    NO OAuth flows — i.e. auth method = None.  SAIA will then allow the user
    to select / confirm 'None' as the authentication method when registering.
    """
    base = str(request.base_url).rstrip("/")
    return JSONResponse(
        {
            "issuer": base,
            "scopes_supported": [],
            "response_types_supported": [],
            "grant_types_supported": [],
        },
        headers={"Access-Control-Allow-Origin": "*"},
    )


async def _oauth_protected_resource(request: Request) -> JSONResponse:
    """
    RFC 9396 — OAuth 2.0 Protected Resource Metadata.

    'authorization_servers': [] means there are NO OAuth authorization servers
    protecting this resource — i.e. public / no-auth access is permitted.
    MCP clients and CyberArk SAIA use this as the definitive signal that
    auth method = None.
    """
    base = str(request.base_url).rstrip("/")
    return JSONResponse(
        {
            "resource": f"{base}/mcp",
            "authorization_servers": [],
            "bearer_methods_supported": [],
            "resource_signing_alg_values_supported": [],
        },
        headers={"Access-Control-Allow-Origin": "*"},
    )


def main() -> None:
    _load_env()
    parser = argparse.ArgumentParser(description="Deepgram Agentic Tools MCP server")
    parser.add_argument("--host", default=os.getenv("MCP_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.getenv("MCP_PORT", "8787")))
    args = parser.parse_args()

    try:
        _api_key()
    except RuntimeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    mcp.settings.host = args.host
    mcp.settings.port = args.port

    # Wrap the FastMCP ASGI app with a top-level Starlette app so we can add
    # extra routes (e.g. /health for App Runner / ALB health checks) alongside
    # the MCP endpoint at /mcp.
    mcp_asgi = mcp.streamable_http_app()
    app = Starlette(
        routes=[
            Route("/health", endpoint=_health, methods=["GET"]),
            # OAuth discovery endpoints — SAIA queries these during 'Discover'
            # to determine authentication requirements.  Empty arrays signal
            # that no OAuth/auth is needed (auth method = None).
            Route(
                "/.well-known/oauth-authorization-server",
                endpoint=_oauth_authorization_server,
                methods=["GET"],
            ),
            Route(
                "/.well-known/oauth-protected-resource",
                endpoint=_oauth_protected_resource,
                methods=["GET"],
            ),
            Mount("/", app=mcp_asgi),
        ]
    )

    import uvicorn

    print(f">> Deepgram Agentic Tools MCP on http://{args.host}:{args.port}/mcp", file=sys.stderr)
    print(f">> Health check at http://{args.host}:{args.port}/health", file=sys.stderr)
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
