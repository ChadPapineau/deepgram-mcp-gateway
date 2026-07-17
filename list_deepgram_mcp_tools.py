#!/usr/bin/env python3
"""
Connects to Deepgram's hosted MCP endpoint (the one the deepgram-mcp / `dg mcp`
proxy actually uses) and prints the real tool list, so we can see whether it
exposes the agentic developer tools (transcribe_audio, synthesize_speech, ...)
or only the kapa.ai documentation Q&A tools.

Usage:
    DEEPGRAM_API_KEY=your_key ./venv/bin/python list_deepgram_mcp_tools.py
    # or put DEEPGRAM_API_KEY=... in a .env file next to this script.

Nothing is created or modified on Deepgram's side; this only reads the tool list.
"""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path


def load_env() -> None:
    env = Path(__file__).with_name(".env")
    if env.exists():
        for line in env.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


async def main() -> int:
    load_env()
    api_key = os.getenv("DEEPGRAM_API_KEY")
    if not api_key:
        print("ERROR: set DEEPGRAM_API_KEY (env var or .env file).", file=sys.stderr)
        return 1

    base_url = os.getenv("DEEPGRAM_DX_URL", "https://api.dx.deepgram.com").rstrip("/")
    mcp_url = f"{base_url}/kapa/mcp"

    from mcp.client.session import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    headers = {"Authorization": f"Token {api_key}"}
    print(f">> Connecting to {mcp_url}")
    print(f">> Auth scheme: Token <api_key> (len={len(api_key)})\n")

    async with streamablehttp_client(url=mcp_url, headers=headers) as (r, w, _):
        async with ClientSession(r, w) as session:
            init = await session.initialize()
            info = getattr(init, "serverInfo", None)
            if info is not None:
                print(f"Server: {getattr(info, 'name', '?')} v{getattr(info, 'version', '?')}\n")

            tools = (await session.list_tools()).tools
            print(f"===== {len(tools)} TOOL(S) EXPOSED =====")
            for t in tools:
                desc = (t.description or "").strip().replace("\n", " ")
                if len(desc) > 140:
                    desc = desc[:137] + "..."
                print(f"\n- {t.name}\n    {desc}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except Exception as e:  # noqa: BLE001
        print(f"\nError: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(1)
