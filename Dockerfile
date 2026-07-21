FROM python:3.12-slim

WORKDIR /app

# Install dependencies first (layer-cached)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY deepgram_tools_mcp.py .

# Create output dir for TTS audio
RUN mkdir -p output

# App Runner / container default port
EXPOSE 8080

# DEEPGRAM_API_KEY is injected at runtime via Secrets Manager (see deploy.sh)
ENV MCP_HOST=0.0.0.0
ENV MCP_PORT=8080

CMD ["python", "deepgram_tools_mcp.py", "--host", "0.0.0.0", "--port", "8080"]
