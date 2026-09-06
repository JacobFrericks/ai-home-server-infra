# comfyui-mcp — MCP server that drives the local ComfyUI (SDXL) for image gen.
# No off-the-shelf image exists, so we build a tiny one (matches the DIY pattern
# used elsewhere in this stack). Runs streamable-HTTP on loopback 127.0.0.1:9300.
FROM python:3.14-slim@sha256:cad9a2c871761c413caa6fdd6441c783451e740a48aaeba60ae62a8b53525ef6

WORKDIR /app

COPY requirements.txt .
# pip is dropped after the install: nothing at runtime uses it, and trivy
# reads pip/_vendor/vendor.txt, so the vendored msgpack + setuptools pins
# show up as findings we cannot upgrade independently of pip itself.
RUN pip install --no-cache-dir -r requirements.txt \
 && pip uninstall -y pip

COPY server.py .

# Bound on loopback via env (see docker-compose.yml). host networking is used so
# it can reach ComfyUI at 127.0.0.1:8188 and be reached by open-webui.
ENV MCP_HTTP_HOST=127.0.0.1 \
    MCP_HTTP_PORT=9300 \
    COMFYUI_URL=http://127.0.0.1:8188

CMD ["python", "server.py"]
