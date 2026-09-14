# memory-mcp — MCP server giving the local AI a persistent, hand-editable
# markdown memory. No off-the-shelf image fits, so we build a tiny one (matches
# the DIY comfyui-mcp pattern). Runs streamable-HTTP on loopback 127.0.0.1:9400.
FROM python:3.14-alpine@sha256:c6ead215bfd31f1e433d968853b7a769989117115b728874824e6c0a27cb96fc

# ⚠️ WHY ALPINE AND NOT python:3.14-slim, because the diff looks like churn and
# is not: on 2026-09-13 both images sat at 44 accepted HIGH with NOTHING left to
# patch. `apt-get upgrade` had already taken every fixable finding to zero; the
# remainder was 8 distinct CVEs that Debian 13 marks `affected` or
# `fix_deferred`, inflated to 44 because util-linux alone ships 9 binary
# packages. They live in util-linux, ncurses, systemd and perl-base -- a Debian
# userland this server never calls. There was no patch left to apply, so the
# only lever was the base itself.
#
# Measured with the same trivy 0.74.0 and the same database, against an image
# carrying this repo's real dependencies: alpine reports 30 OS packages and ZERO
# findings at any severity, where slim reports 87 packages and the 44 above.
# Distilled the alternatives too -- distroless/python3-debian12 was WORSE (still
# Debian, and no apt to upgrade with), and chainguard's free tier publishes only
# a moving `:latest` whose old digests are collected, which cannot be pinned the
# way everything else here is.
#
# Safe because neither server touches the C world: both are stdlib plus `mcp`
# and `httpx`, no subprocess, no shelling out. Every wheel resolves prebuilt for
# musllinux, so musl-vs-glibc costs nothing here.

# Alpine security updates on top of the pinned base. The base at this digest
# carries 9 HIGH, every one of them with a fix available; this clears all 9 and
# leaves the image at 0 CRITICAL / 0 HIGH.
#
# ⚠️ THIS IS THE ONE UNPINNED INPUT IN THE BUILD, unchanged by the move off
# Debian, so the tradeoff is stated rather than buried: two builds of the same
# commit can install different package versions. That is in tension with
# image-scan.yml's invariant that the gate "only turns red when THIS REPO
# changes", and it was still taken -- because pinning apk versions instead is
# worse, for the same reason it was under apt. Alpine's repository carries only
# the CURRENT version of each package, so `apk add pkg=1.2.3-r4` starts failing
# the moment -r5 supersedes it. A pin that breaks the build on someone else's
# release schedule is not reproducibility.
#
# What keeps the invariant close to intact: the CVE database is pinned, so the
# finding set is (that snapshot) x (installed packages). Against a FIXED
# database, installing newer packages can only hold counts level or lower them.
# New disclosures still arrive the reviewed way -- as a trivy-db Renovate PR.
RUN apk upgrade --no-cache

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
