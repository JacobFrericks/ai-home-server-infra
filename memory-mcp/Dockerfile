# memory-mcp — MCP server giving the local AI a persistent, hand-editable
# markdown memory. No off-the-shelf image fits, so we build a tiny one (matches
# the DIY comfyui-mcp pattern). Runs streamable-HTTP on loopback 127.0.0.1:9400.
FROM python:3.14-slim@sha256:cad9a2c871761c413caa6fdd6441c783451e740a48aaeba60ae62a8b53525ef6

# Debian security updates on top of the pinned base. Measured 2026-09-13
# against the pinned CVE database: this clears 3 CRITICAL and 9 HIGH, and
# afterwards NOTHING in the image has a fix available upstream -- the 44 HIGH
# that remain are unpatched in Debian 13, not ignored here.
#
# The base digest was already the newest python:3.14-slim, so this is not a
# missed image bump. Debian ships security updates continuously while the
# python image is rebuilt on its own slower cadence, and the gap between the
# two is exactly what this closes.
#
# ⚠️ THIS IS THE ONE UNPINNED INPUT IN THE BUILD, so the tradeoff is stated
# rather than buried: two builds of the same commit can now install different
# package versions. That is in tension with image-scan.yml's invariant that the
# gate "only turns red when THIS REPO changes", and it was still taken --
# because pinning apt versions instead is worse. Debian's archive carries only
# the CURRENT version of each package, so `apt-get install pkg=1.2-3+deb13u1`
# starts failing the moment +deb13u2 supersedes it. A pin that breaks the build
# on someone else's release schedule is not reproducibility.
#
# What keeps the invariant close to intact: the CVE database is pinned, so the
# finding set is (that snapshot) x (installed packages). Against a FIXED
# database, installing newer packages can only hold counts level or lower them.
# New disclosures still arrive the reviewed way -- as a trivy-db Renovate PR.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
# pip is dropped after the install: nothing at runtime uses it, and trivy
# reads pip/_vendor/vendor.txt, so the vendored msgpack + setuptools pins
# show up as findings we cannot upgrade independently of pip itself.
RUN pip install --no-cache-dir -r requirements.txt \
 && pip uninstall -y pip

COPY server.py .

# Bound on loopback via env (see docker-compose.yml). host networking is used so
# the host-networked open-webui can reach it. MEMORY_DIR is a bind mount owned by
# jacob (uid 1000); the container runs as 1000:1000 so files stay hand-editable.
ENV MCP_HTTP_HOST=127.0.0.1 \
    MCP_HTTP_PORT=9400 \
    MEMORY_DIR=/data/memory

CMD ["python", "server.py"]
