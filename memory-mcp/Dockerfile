# memory-mcp — MCP server giving the local AI a persistent, hand-editable
# markdown memory. No off-the-shelf image fits, so we build a tiny one (matches
# the DIY comfyui-mcp pattern). Runs streamable-HTTP on loopback 127.0.0.1:9400.
FROM python:3.14-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

# Bound on loopback via env (see docker-compose.yml). host networking is used so
# the host-networked open-webui can reach it. MEMORY_DIR is a bind mount owned by
# jacob (uid 1000); the container runs as 1000:1000 so files stay hand-editable.
ENV MCP_HTTP_HOST=127.0.0.1 \
    MCP_HTTP_PORT=9400 \
    MEMORY_DIR=/data/memory

CMD ["python", "server.py"]
