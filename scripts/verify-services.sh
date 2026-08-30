#!/usr/bin/env bash
# verify-services.sh — functional verification of the home-server AI/media/monitoring stack.
# Runs as jacob (no sudo required: uses the docker group + jacob-owned monitoring/.env).
# Exercises each service end-to-end and prints a PASS/FAIL table. Exit 0 iff all pass.
# Contains NO secrets: reads ha_token via `docker cp` and creds from monitoring/.env at runtime.
# Only ever RUNS the gemma4:26b Ollama model (a 1-token generation). Other models
# (gemma4:12b/26b) are only listed for presence, never loaded; ComfyUI is checked
# for reachability + checkpoint but no image is generated (that would load SDXL).
set -uo pipefail

# Half the stack now runs on k3s, so this script calls kubectl. Under cron (or any
# non-login shell) there is no KUBECONFIG in the environment and every kubectl check
# would fail silently, reporting a healthy service as broken.
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

STACK_DIR="/home/jacob/docker/ai-stack"

# ---- in-cluster endpoints (ollama/comfyui/comfyui-mcp migrated to k3s) -------
# Resolved via kubectl, not hardcoded: this script runs on the HOST, which cannot
# resolve *.svc.cluster.local, but a baked-in ClusterIP would silently go stale if
# a Service were ever recreated. The host reaches ClusterIPs via Cilium.
clusterip() { kubectl -n ai-stack get svc "$1" -o jsonpath='{.spec.clusterIP}' 2>/dev/null; }
clusterip_ns() { kubectl -n "$1" get svc "$2" -o jsonpath='{.spec.clusterIP}' 2>/dev/null; }
export GRAFANA_EP="$(clusterip_ns monitoring kube-prometheus-stack-grafana):3000"
export OLLAMA_EP="http://$(clusterip ollama):11434"
export COMFY_EP="http://$(clusterip comfyui):8188"
export COMFYMCP_EP="http://$(clusterip comfyui-mcp):9300/mcp"

cd "$STACK_DIR" 2>/dev/null || { echo "cannot cd $STACK_DIR"; exit 2; }

PASS=0; FAIL=0
declare -a ROWS
record() { # name | PASS/FAIL | detail
  ROWS+=("$1|$2|$3")
  if [ "$2" = PASS ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}

# ---- secrets loaded at runtime, never echoed ----
HA_TOKEN=""
# Post-migration these live in Kubernetes Secrets, not in a Compose container or
# monitoring/.env -- both of which disappeared with the monitoring project.
# Values are never echoed.
HA_TOKEN=$(kubectl -n monitoring get secret ha-scrape-token -o jsonpath='{.data.ha_token}' 2>/dev/null | base64 -d 2>/dev/null | tr -d '\r\n')
PLEX_TOKEN=$(kubectl -n monitoring get secret plex-exporter -o jsonpath='{.data.PLEX_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null | tr -d '\r\n')
GRAFANA_PW=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null | tr -d '\r\n')

# =========================================================================
# 0. Host clock
# =========================================================================
# Added 2026-08-30: the host was found 63s fast with NO ntp client installed.
# Skew this large silently corrupts Prometheus/Loki timestamps, k8s token
# validity and restic snapshot times, so check it before anything else.
if systemctl is-active --quiet chrony; then
  off=$(chronyc tracking 2>/dev/null | awk -F: '/^System time/{print $2}' | awk '{print $1}')
  synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  if [ -z "$off" ]; then
    record "Host clock" FAIL "chrony running but tracking gave no offset"
  elif [ "$synced" != "yes" ]; then
    record "Host clock" FAIL "chrony up but clock not synchronised yet (offset ${off}s)"
  elif awk -v o="$off" 'BEGIN{exit !(o<1.0)}'; then
    record "Host clock" PASS "in sync, offset ${off}s from $(chronyc tracking | awk -F'[()]' '/^Reference ID/{print $2}')"
  else
    record "Host clock" FAIL "drifting: ${off}s off NTP -- chrony is not keeping up"
  fi
else
  record "Host clock" FAIL "chrony not running -- clock will free-run; see scripts/setup-time-sync.sh"
fi

# =========================================================================
# 1. Home Assistant
# =========================================================================
if [ -n "$HA_TOKEN" ]; then
  cfg=$(curl -s --max-time 15 -H "Authorization: Bearer $HA_TOKEN" http://127.0.0.1:8123/api/config)
  read -r ha_state ha_ver ha_has < <(printf '%s' "$cfg" | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin); c=set(d.get("components",[]))
    need={"ollama","wyoming"}
    print(d.get("state",""), d.get("version",""), "yes" if need & c or need <= c else ("partial" if need & c else "no"))
except Exception:
    print("ERR ERR ERR")')
  ents=$(curl -s --max-time 15 -H "Authorization: Bearer $HA_TOKEN" http://127.0.0.1:8123/api/states | python3 -c 'import sys,json
try: print(len(json.load(sys.stdin)))
except: print("ERR")' 2>/dev/null)
  errln=$(curl -s --max-time 15 -H "Authorization: Bearer $HA_TOKEN" http://127.0.0.1:8123/api/error_log | grep -icE 'ERROR|Traceback' 2>/dev/null)
  if [ "$ha_state" = RUNNING ]; then
    record "Home Assistant" PASS "state=RUNNING v$ha_ver, entities=$ents, ollama+wyoming=$ha_has, errorlog_hits=$errln"
  else
    record "Home Assistant" FAIL "state=$ha_state (expected RUNNING)"
  fi
else
  record "Home Assistant" FAIL "could not read ha_token via docker cp"
fi

# =========================================================================
# 2. Ollama  (gemma4:26b ONLY)
# =========================================================================
t0=$(date +%s.%N)
og=$(curl -s --max-time 240 ${OLLAMA_EP}/api/generate \
   -d '{"model":"gemma4:26b","prompt":"Reply with the single word: ok","stream":false,"think":false,"options":{"num_predict":16}}')
t1=$(date +%s.%N)
# Success = the model actually generated tokens (done + eval_count>0, no error),
# not merely non-empty text (a 1-token reply can render empty).
ostat=$(printf '%s' "$og" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    if d.get("error"): print("ERR|"+str(d["error"])[:50]); raise SystemExit
    ok = d.get("done") and (d.get("eval_count") or 0) > 0
    # gemma4:26b is a reasoning model — tokens may land in "thinking" before "response"
    txt=(d.get("response") or "").strip()
    if not txt: txt="[thinking] "+(d.get("thinking") or "").strip()
    txt=txt.replace("\n"," ")[:44]
    print(("OK|" if ok else "NO|")+("out=\"%s\" tokens=%s" % (txt, d.get("eval_count"))))
except SystemExit: pass
except Exception as e: print("ERR|"+str(e)[:50])')
odur=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')
if [ "${ostat%%|*}" = OK ]; then
  record "Ollama (gemma4:26b)" PASS "${ostat#*|}, ${odur}s"
else
  record "Ollama (gemma4:26b)" FAIL "${ostat#*|} (${odur}s)"
fi

# =========================================================================
# 3. Open WebUI  (health + db + config; model list needs auth, skipped)
# =========================================================================
ow_h=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://192.168.86.63:8080/health)
ow_db=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://192.168.86.63:8080/health/db)
ow_cfg=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://192.168.86.63:8080/api/config)
if [ "$ow_h" = 200 ] && [ "$ow_db" = 200 ] && [ "$ow_cfg" = 200 ]; then
  record "Open WebUI" PASS "health=200 db=200 api/config=200"
else
  record "Open WebUI" FAIL "health=$ow_h db=$ow_db api/config=$ow_cfg"
fi

# =========================================================================
# 4. SearXNG  (real search; try JSON, fall back to HTML)
# =========================================================================
sx=$(curl -s --max-time 20 "http://10.43.32.94:8080/search?q=home+assistant&format=json")
sxn=$(printf '%s' "$sx" | python3 -c 'import sys,json
try: print(len(json.load(sys.stdin).get("results",[])))
except: print("NOJSON")')
if [ "$sxn" = NOJSON ] || [ -z "$sxn" ]; then
  sxh=$(curl -s --max-time 20 "http://10.43.32.94:8080/search?q=home+assistant")
  sxn=$(printf '%s' "$sxh" | grep -oc 'class="result' || true)
  mode="html"
else
  mode="json"
fi
if [ "${sxn:-0}" -gt 0 ] 2>/dev/null; then
  record "SearXNG" PASS "$sxn results ($mode)"
else
  record "SearXNG" FAIL "no results ($mode)"
fi

# =========================================================================
# 5. SearXNG-MCP  (streamable-HTTP: initialize -> tools/list)
# =========================================================================
mcp=$(python3 - <<'PY'
import json,urllib.request
BASE="http://10.43.36.60:9200/mcp"
HDR={"Content-Type":"application/json","Accept":"application/json, text/event-stream"}
def parse(body,ct):
    body=body.decode("utf-8","replace")
    if "text/event-stream" in (ct or ""):
        for line in body.splitlines():
            if line.startswith("data:"):
                try: return json.loads(line[5:].strip())
                except: pass
        return None
    try: return json.loads(body)
    except: return None
def post(obj, sid=None):
    h=dict(HDR)
    if sid: h["Mcp-Session-Id"]=sid
    req=urllib.request.Request(BASE, data=json.dumps(obj).encode(), headers=h, method="POST")
    r=urllib.request.urlopen(req, timeout=15)
    return r, parse(r.read(), r.headers.get("Content-Type"))
try:
    init={"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}
    r,_=post(init)
    sid=r.headers.get("Mcp-Session-Id")
    # initialized notification
    try: post({"jsonrpc":"2.0","method":"notifications/initialized"}, sid)
    except Exception: pass
    r,res=post({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}, sid)
    tools=[t["name"] for t in (res or {}).get("result",{}).get("tools",[])]
    if tools: print("PASS|%d tools: %s" % (len(tools), ",".join(tools)[:80]))
    else:     print("FAIL|no tools returned")
except Exception as e:
    print("FAIL|%s" % str(e)[:80])
PY
)
record "SearXNG-MCP" "${mcp%%|*}" "${mcp#*|}"

# =========================================================================
# 5b. Image generation: ComfyUI + comfyui-mcp + gemma4:12b presence
#     NB: no image is generated here — a real generation loads SDXL and is a
#     heavy, opt-in step (see README). This block only checks reachability,
#     that the SDXL checkpoint is present, that the MCP tool is exposed, and
#     that the 12b orchestrator model exists (listed, never loaded).
# =========================================================================
cu_h=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 ${COMFY_EP}/system_stats)
cu_ckpt=$(curl -s --max-time 15 ${COMFY_EP}/object_info/CheckpointLoaderSimple | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    ck=d["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"][0]
    print("yes" if any("sd_xl_base" in c for c in ck) else "no", len(ck))
except Exception:
    print("ERR 0")')
read -r ckpt_has ckpt_n <<< "$cu_ckpt"
if [ "$cu_h" = 200 ] && [ "$ckpt_has" = yes ]; then
  record "ComfyUI (SDXL)" PASS "system_stats=200, SDXL checkpoint present ($ckpt_n ckpts)"
else
  record "ComfyUI (SDXL)" FAIL "system_stats=$cu_h, sdxl_checkpoint=$ckpt_has ($ckpt_n ckpts)"
fi

cmcp=$(python3 - <<'PY'
import json,os,urllib.request
BASE=os.environ["COMFYMCP_EP"]
HDR={"Content-Type":"application/json","Accept":"application/json, text/event-stream"}
def parse(body,ct):
    body=body.decode("utf-8","replace")
    if "text/event-stream" in (ct or ""):
        for line in body.splitlines():
            if line.startswith("data:"):
                try: return json.loads(line[5:].strip())
                except: pass
        return None
    try: return json.loads(body)
    except: return None
def post(obj, sid=None):
    h=dict(HDR)
    if sid: h["Mcp-Session-Id"]=sid
    req=urllib.request.Request(BASE, data=json.dumps(obj).encode(), headers=h, method="POST")
    r=urllib.request.urlopen(req, timeout=15)
    return r, parse(r.read(), r.headers.get("Content-Type"))
try:
    init={"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}
    r,_=post(init)
    sid=r.headers.get("Mcp-Session-Id")
    try: post({"jsonrpc":"2.0","method":"notifications/initialized"}, sid)
    except Exception: pass
    r,res=post({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}, sid)
    tools=[t["name"] for t in (res or {}).get("result",{}).get("tools",[])]
    # The MCP server names its tool "image" on purpose; Open WebUI registers it
    # as "generate_image" (connection id "generate" + tool "image"). At the raw
    # MCP level checked here the tool is "image".
    if "image" in tools: print("PASS|%d tool(s): %s (registers as generate_image)" % (len(tools), ",".join(tools)[:50]))
    else: print("FAIL|image tool missing (tools: %s)" % ",".join(tools)[:50])
except Exception as e:
    print("FAIL|%s" % str(e)[:80])
PY
)
record "comfyui-mcp" "${cmcp%%|*}" "${cmcp#*|}"

# 5c. Persistent memory: memory-mcp tools reachable + Open WebUI wiring.
#     Checks the MCP server exposes its save/list/update/delete tools, and that
#     assistant has the memory tool attached and the memory_recall filter is
#     installed (active + global). No memory is written. See README "Memory".
memmcp=$(python3 - <<'PY'
import json,urllib.request
BASE="http://10.43.96.211:9400/mcp"
HDR={"Content-Type":"application/json","Accept":"application/json, text/event-stream"}
def parse(body,ct):
    body=body.decode("utf-8","replace")
    if "text/event-stream" in (ct or ""):
        for line in body.splitlines():
            if line.startswith("data:"):
                try: return json.loads(line[5:].strip())
                except: pass
        return None
    try: return json.loads(body)
    except: return None
def post(obj, sid=None):
    h=dict(HDR)
    if sid: h["Mcp-Session-Id"]=sid
    req=urllib.request.Request(BASE, data=json.dumps(obj).encode(), headers=h, method="POST")
    r=urllib.request.urlopen(req, timeout=15)
    return r, parse(r.read(), r.headers.get("Content-Type"))
try:
    init={"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}
    r,_=post(init)
    sid=r.headers.get("Mcp-Session-Id")
    try: post({"jsonrpc":"2.0","method":"notifications/initialized"}, sid)
    except Exception: pass
    r,res=post({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}, sid)
    tools=[t["name"] for t in (res or {}).get("result",{}).get("tools",[])]
    if "save_memory" in tools: print("PASS|%d tool(s): %s" % (len(tools), ",".join(tools)[:60]))
    else: print("FAIL|save_memory missing (tools: %s)" % ",".join(tools)[:50])
except Exception as e:
    print("FAIL|%s" % str(e)[:80])
PY
)
record "memory-mcp" "${memmcp%%|*}" "${memmcp#*|}"

memwire=$(kubectl -n ai-stack exec -i deploy/open-webui -- python3 - <<'PY' 2>/dev/null
import sqlite3, json
c=sqlite3.connect("/app/backend/data/webui.db")
r=c.execute("select meta from model where id='assistant'").fetchone()
tids=(json.loads(r[0]) if r and r[0] else {}).get("toolIds") or []
f=c.execute("select is_active,is_global from function where id='memory_recall'").fetchone()
fids=(json.loads(r[0]).get("filterIds") or []) if r and r[0] else []
has_tool="server:mcp:memory" in tids
has_filter=bool(f) and f[0]==1 and (f[1]==1 or "memory_recall" in fids)
print("WIRED" if (has_tool and has_filter) else "MISSING|tool=%s filter=%s" % (has_tool, has_filter))
PY
)
if [ "${memwire%%|*}" = WIRED ]; then
  record "Memory wiring" PASS "assistant has memory tool; memory_recall filter active"
else
  record "Memory wiring" FAIL "${memwire#*|}"
fi

g12=$(curl -s --max-time 10 ${OLLAMA_EP}/api/tags | python3 -c 'import sys,json
try: print(sum(1 for m in json.load(sys.stdin).get("models",[]) if m.get("name","").startswith("gemma4:12b")))
except: print(0)')
if [ "${g12:-0}" -ge 1 ]; then
  record "Ollama (gemma4:12b present)" PASS "in ollama list (image-gen orchestrator; not loaded)"
else
  record "Ollama (gemma4:12b present)" FAIL "gemma4:12b not found in /api/tags"
fi

# =========================================================================
# 5c. Open WebUI -> Home Assistant control bridge (HA MCP Server)
#     Checks HA's mcp_server integration is loaded and that Open WebUI has a
#     bearer-authed home-assistant tool attached to assistant. Does not call
#     any HA control action.
# =========================================================================
if [ -n "$HA_TOKEN" ]; then
  ha_mcp=$(printf '%s' "$cfg" | python3 -c 'import sys,json
try: print("yes" if "mcp_server" in set(json.load(sys.stdin).get("components",[])) else "no")
except: print("ERR")')
else
  ha_mcp="ERR"
fi
owui_b=$(kubectl -n ai-stack exec deploy/open-webui -- python3 /tmp/openwebui-ha-bridge.py --check 2>/dev/null \
  || kubectl -n ai-stack exec -i deploy/open-webui -- python3 - <<'PY' 2>/dev/null
import sqlite3,json
try:
    db=sqlite3.connect("/app/backend/data/webui.db")
    row=db.execute("select value from config where key='tool_server.connections'").fetchone()
    conns=json.loads(row[0]) if row and row[0] else []
    ha=[c for c in conns if (c.get("info") or {}).get("id")=="home-assistant"]
    has_conn=bool(ha) and bool((ha[0].get("key") or "").strip()) and ha[0].get("auth_type")=="bearer"
    m=db.execute("select meta from model where id='assistant'").fetchone()
    tids=(json.loads(m[0]).get("toolIds") or []) if m and m[0] else []
    print("WIRED" if (has_conn and "server:mcp:home-assistant" in tids) else "NEEDS_TOKEN")
except Exception: print("NEEDS_TOKEN")
PY
)
if [ "$ha_mcp" = yes ] && [ "$owui_b" = WIRED ]; then
  record "OWUI->HA bridge" PASS "mcp_server loaded; assistant has home-assistant tool"
else
  record "OWUI->HA bridge" FAIL "mcp_server=$ha_mcp; owui=$owui_b"
fi

# =========================================================================
# 5d. Assist can see WHERE THE USER IS
#     The phone GPS reaches the model only through HA, and only for entities
#     exposed to Assist. Without this the model answers "weather" from the
#     search engine guessing at the house IP.
# =========================================================================
loc=$(bash "$(dirname "$0")/setup-assist-location.sh" --check 2>/dev/null || true)
loc_off=$(printf "%s" "$loc" | grep -c "exposed_to_assist=False" || true)
loc_on=$(printf "%s" "$loc" | grep -c "exposed_to_assist=True" || true)
if [ "$loc_off" = 0 ] && [ "$loc_on" -gt 0 ]; then
  record "Assist location" PASS "$loc_on entity(s) exposed: phone GPS reaches the model"
else
  record "Assist location" FAIL "$loc_off entity(s) NOT exposed to Assist"
fi

# =========================================================================
# 5e. HA weather, and the container DNS it depends on
#     Docker writes a container's /etc/resolv.conf from the HOST file at start.
#     Containers started while the host had no DHCP lease get an EMPTY one and
#     keep it for their whole life: no DNS, no cloud integrations, no met.no.
#     Nothing logs an error at the container level, so check it directly.
# =========================================================================
dns_bad=""
for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
  n=$(docker exec "$c" cat /etc/resolv.conf 2>/dev/null | grep -c '^nameserver' || true)
  [ "${n:-0}" -eq 0 ] && dns_bad="$dns_bad $c"
done
if [ -z "$dns_bad" ]; then
  record "Container DNS" PASS "every docker container has a nameserver"
else
  record "Container DNS" FAIL "no nameserver in:$dns_bad (restart them; they booted with no lease)"
fi

wx=$(bash "$(dirname "$0")/setup-ha-weather.sh" --check 2>&1 || true)
wx_line=$(printf '%s' "$wx" | grep -m1 '^  weather\.' | sed 's/^ *//')
if printf '%s' "$wx" | grep -q 'exposed_to_assist=True'; then
  record "HA weather" PASS "${wx_line:-exposed}"
else
  record "HA weather" FAIL "no weather entity exposed to Assist"
fi

# =========================================================================
# 5f. Weather at the PHONE, not at the house
#     met.no is pinned to the home coordinates, so it is wrong the moment the
#     user leaves. The rest sensor re-renders its URL from the live tracker on
#     every poll; if it goes stale or loses its Assist exposure the model
#     quietly answers with house weather instead of saying it does not know.
# =========================================================================
lw=$(bash "$(dirname "$0")/setup-ha-location-weather.sh" --check 2>&1 || true)
lw_state=$(printf '%s' "$lw" | grep -m1 'sensor.weather_at_my_location = ' | sed 's/.*= //')
if printf '%s' "$lw" | grep -q 'exposed_to_assist=True' && [ -n "$lw_state" ]; then
  record "Weather at phone" PASS "$lw_state"
else
  record "Weather at phone" FAIL "sensor missing, stale, or not exposed to Assist"
fi

# =========================================================================
# 6. Piper -> Whisper voice round-trip (raw-socket Wyoming, no installs)
# =========================================================================
voice=$(python3 - <<'PY'
import socket,json
PIPER=("127.0.0.1",10200); WHISPER=("127.0.0.1",10300)
VOICE="en_US-hfc_female-medium"; TEXT="testing one two three"
def wr(sock,typ,data=None,payload=None):
    h={"type":typ}
    if data is not None: h["data"]=data
    if payload is not None: h["payload_length"]=len(payload)
    sock.sendall((json.dumps(h)+"\n").encode())
    if payload is not None: sock.sendall(payload)
def rd(rf):
    line=rf.readline()
    if not line: return None
    o=json.loads(line.decode())
    data=o.get("data")
    if o.get("data_length"): data=json.loads(rf.read(o["data_length"]))
    payload=None
    if o.get("payload_length"): payload=rf.read(o["payload_length"])
    return {"type":o["type"],"data":data or {},"payload":payload}
try:
    # --- Piper: synthesize ---
    s=socket.create_connection(PIPER,timeout=60); s.settimeout(60); rf=s.makefile("rb")
    wr(s,"synthesize",{"text":TEXT,"voice":{"name":VOICE}})
    rate=width=channels=None; pcm=bytearray()
    while True:
        ev=rd(rf)
        if ev is None: break
        if ev["type"]=="audio-start":
            rate=ev["data"].get("rate",22050); width=ev["data"].get("width",2); channels=ev["data"].get("channels",1)
        elif ev["type"]=="audio-chunk" and ev["payload"]:
            pcm+=ev["payload"]
        elif ev["type"]=="audio-stop":
            break
    s.close()
    if not pcm:
        print("FAIL|piper produced no audio"); raise SystemExit
    rate=rate or 22050; width=width or 2; channels=channels or 1
    # --- Whisper: transcribe ---
    w=socket.create_connection(WHISPER,timeout=60); w.settimeout(60); wf=w.makefile("rb")
    wr(w,"transcribe",{"language":"en"})
    wr(w,"audio-start",{"rate":rate,"width":width,"channels":channels})
    step=8192
    for i in range(0,len(pcm),step):
        wr(w,"audio-chunk",{"rate":rate,"width":width,"channels":channels},bytes(pcm[i:i+step]))
    wr(w,"audio-stop",{})
    text=""
    while True:
        ev=rd(wf)
        if ev is None: break
        if ev["type"]=="transcript":
            text=(ev["data"].get("text") or "").strip(); break
    w.close()
    norm=text.lower().replace("-"," ")
    for a,b in [("1","one"),("2","two"),("3","three")]: norm=norm.replace(a,b)
    import re; words=set(re.findall(r"[a-z]+",norm))
    hit=sum(1 for k in ("testing","one","two","three") if k in words)
    detail='piper %dHz/%dch -> whisper: "%s" (%d/4 kw, %d PCM bytes)' % (rate,channels,text[:40],hit,len(pcm))
    print(("PASS|" if hit>=3 else "FAIL|")+detail)
except Exception as e:
    print("FAIL|%s" % str(e)[:100])
PY
)
record "Piper->Whisper voice" "${voice%%|*}" "${voice#*|}"

# Added 2026-08-30 (audit M2): piper/whisper must NOT be reachable on the LAN.
# They are published on 127.0.0.1 only; HA reaches them via localhost (net=host).
# A regression (dropping the 127.0.0.1: bind) silently re-exposes two
# unauthenticated voice services to the whole wifi.
lan_ip=$(ip -4 addr show 2>/dev/null | awk '/inet 192\.168\./{print $2}' | cut -d/ -f1 | head -1)
if [ -z "$lan_ip" ]; then
  record "Voice ports LAN-private" FAIL "could not determine LAN IP to test"
else
  open_ports=""
  for port in 10200 10300; do
    timeout 2 bash -c "echo > /dev/tcp/$lan_ip/$port" 2>/dev/null && open_ports="$open_ports $port"
  done
  if [ -n "$open_ports" ]; then
    record "Voice ports LAN-private" FAIL "reachable on $lan_ip:$open_ports -- loopback bind lost, LAN-exposed"
  else
    record "Voice ports LAN-private" PASS "10200/10300 refused on $lan_ip (loopback-only)"
  fi
fi

# =========================================================================
# 7. Plex
# =========================================================================
px_id=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:32400/identity)
if [ -n "$PLEX_TOKEN" ]; then
  px_ss=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:32400/status/sessions?X-Plex-Token=$PLEX_TOKEN")
else
  px_ss="no-token"
fi
if [ "$px_id" = 200 ] && [ "$px_ss" = 200 ]; then
  record "Plex" PASS "identity=200, status/sessions=200 (auth ok)"
else
  record "Plex" FAIL "identity=$px_id status/sessions=$px_ss"
fi

# =========================================================================
# 8. Monitoring: Prometheus targets + Grafana datasource health (covers Loki)
# =========================================================================
PROM_IP=$(clusterip_ns monitoring kube-prometheus-stack-prometheus)
if [ -n "$PROM_IP" ]; then
  ptar=$(curl -s --max-time 15 "http://$PROM_IP:9090/api/v1/targets")
  read -r p_up p_tot < <(printf '%s' "$ptar" | python3 -c 'import sys,json
try:
    t=json.load(sys.stdin)["data"]["activeTargets"]; up=sum(1 for x in t if x["health"]=="up"); print(up,len(t))
except: print(0,0)')
  if [ "${p_tot:-0}" -gt 0 ] && [ "$p_up" = "$p_tot" ]; then
    record "Prometheus" PASS "$p_up/$p_tot targets up"
  else
    record "Prometheus" FAIL "${p_up:-0}/${p_tot:-0} targets up"
  fi
else
  record "Prometheus" FAIL "could not resolve container IP"
fi

gh=$(curl -s --max-time 10 http://${GRAFANA_EP}/api/health | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("database",""))
except: print("ERR")')
if [ -n "$GRAFANA_PW" ]; then
  dsres=$(curl -s --max-time 20 -u "admin:$GRAFANA_PW" http://${GRAFANA_EP}/api/datasources | python3 -c 'import sys,json
try:
    for d in json.load(sys.stdin): print(d["uid"],d["name"])
except: pass')
  ok=0; tot=0; names=""
  while read -r uid name; do
    [ -z "$uid" ] && continue
    tot=$((tot+1))
    st=$(curl -s --max-time 20 -u "admin:$GRAFANA_PW" "http://${GRAFANA_EP}/api/datasources/uid/$uid/health" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("status",""))
except: print("ERR")')
    [ "$st" = OK ] && ok=$((ok+1))
    names="$names $name=$st"
  done <<< "$dsres"
  if [ "$gh" = ok ] && [ "$tot" -gt 0 ] && [ "$ok" = "$tot" ]; then
    record "Grafana + datasources" PASS "db=ok, datasources $ok/$tot healthy:$names"
  else
    record "Grafana + datasources" FAIL "db=$gh, datasources $ok/$tot healthy:$names"
  fi
else
  if [ "$gh" = ok ]; then record "Grafana + datasources" PASS "db=ok (no creds for datasource test)"
  else record "Grafana + datasources" FAIL "db=$gh"; fi
fi

# =========================================================================
# Backup mirror + restic
# =========================================================================
# These run unprivileged on purpose, so this script stays cron-safe as jacob.
# Everything below reads /proc, /sys or the mounted filesystem -- no sudo.

# RAID 1 health. [UU] means both members are present; [U_] or [_U] means the
# mirror is degraded and running on a single ~6-year-old disk.
if [ -e /proc/mdstat ] && grep -q "^md0" /proc/mdstat; then
  md_flags="$(grep -o '\[[U_]*\]' /proc/mdstat | head -1)"
  md_resync="$(grep -o 'resync = *[0-9.]*%' /proc/mdstat | head -1)"
  if [ "$md_flags" = "[UU]" ]; then
    record "RAID mirror (md0)" PASS "both disks up $md_flags${md_resync:+, $md_resync}"
  else
    record "RAID mirror (md0)" FAIL "DEGRADED $md_flags -- replace the failed disk"
  fi
else
  record "RAID mirror (md0)" FAIL "md0 not assembled"
fi

# The mirror is mounted with nofail, so a missing array does NOT stop the boot.
# That is deliberate, and it is exactly why this check has to exist.
if mountpoint -q /srv/backup; then
  bk_use="$(df -h --output=pcent,avail /srv/backup | tail -1 | tr -s ' ')"
  record "Backup volume" PASS "/srv/backup mounted,${bk_use} free"
else
  record "Backup volume" FAIL "/srv/backup NOT mounted -- nightly backup cannot run"
fi

# Timer enabled is not the same as backups happening; freshness is checked next.
if systemctl is-enabled --quiet homeserver-backup.timer 2>/dev/null; then
  record "Backup timer" PASS "homeserver-backup.timer enabled"
else
  record "Backup timer" FAIL "homeserver-backup.timer not enabled"
fi

# Freshness, read from the metric the backup job publishes for node-exporter.
# A silently failing backup looks identical to a working one until you need it.
BK_METRIC=/var/lib/node_exporter/textfile_collector/homeserver_backup.prom
if [ -r "$BK_METRIC" ]; then
  bk_ts="$(awk '/^homeserver_backup_last_success_timestamp_seconds/{print $2}' "$BK_METRIC")"
  bk_age=$(( ($(date +%s) - ${bk_ts:-0}) / 3600 ))
  if [ "${bk_ts:-0}" -gt 0 ] && [ "$bk_age" -lt 48 ]; then
    record "Backup freshness" PASS "last success ${bk_age}h ago"
  else
    record "Backup freshness" FAIL "last success ${bk_age}h ago (>48h)"
  fi
else
  record "Backup freshness" FAIL "no success metric at $BK_METRIC"
fi


# =========================================================================
# Offsite backup (S3 Glacier Instant Retrieval)
# =========================================================================
# The RAID 1 mirror survives a dead disk. It does not survive a fire, a theft,
# or a delete, and both members are ~6 years old and were bought together. These
# checks cover the copy that does survive those -- and, just as importantly, the
# BUCKET SETTINGS that keep it cheap and private. A misconfigured lifecycle rule
# does not break anything visibly; it just quietly bills 5x.
OFFSITE_METRIC=/var/lib/node_exporter/textfile_collector/homeserver_offsite.prom
OFFSITE_BUCKET=homeserver-restic-offsite-p5ke0zp2me

for t in critical bulk maintain; do
  if systemctl is-enabled --quiet "homeserver-offsite-$t.timer" 2>/dev/null; then
    record "Offsite timer ($t)" PASS "homeserver-offsite-$t.timer enabled"
  else
    record "Offsite timer ($t)" FAIL "homeserver-offsite-$t.timer not enabled"
  fi
done

# Freshness per tier. The thresholds match the Grafana rules in the k8s repo
# (OffsiteCriticalStale 36h, OffsiteBulkStale 10d) so the two cannot disagree.
if [ -r "$OFFSITE_METRIC" ]; then
  for spec in "critical:36" "bulk:240"; do
    t="${spec%%:*}"; limit="${spec##*:}"
    ts="$(awk -v t="$t" -F'[ {}]' '$0 ~ "tier=\""t"\"" {print $NF}' "$OFFSITE_METRIC" 2>/dev/null | tail -1)"
    if [ -n "${ts:-}" ] && [ "${ts:-0}" -gt 0 ]; then
      age=$(( ($(date +%s) - ts) / 3600 ))
      if [ "$age" -lt "$limit" ]; then
        record "Offsite freshness ($t)" PASS "last copy ${age}h ago (limit ${limit}h)"
      else
        record "Offsite freshness ($t)" FAIL "last copy ${age}h ago (>${limit}h)"
      fi
    else
      record "Offsite freshness ($t)" FAIL "no timestamp for tier '$t' in $OFFSITE_METRIC"
    fi
  done
else
  record "Offsite freshness (critical)" FAIL "no metric at $OFFSITE_METRIC"
  record "Offsite freshness (bulk)"     FAIL "no metric at $OFFSITE_METRIC"
fi

# Bucket settings. Credentials are sourced into a subshell and never echoed.
if [ -r "$STACK_DIR/.env" ] && command -v aws >/dev/null 2>&1; then
  ob_state="$(
    set -a; . "$STACK_DIR/.env" >/dev/null 2>&1; set +a
    ver="$(aws s3api get-bucket-versioning --bucket "$OFFSITE_BUCKET" --query Status --output text 2>/dev/null)"
    pab="$(aws s3api get-public-access-block --bucket "$OFFSITE_BUCKET" \
             --query "PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]" \
             --output text 2>/dev/null | tr -d " \t")"
    lc="$(aws s3api get-bucket-lifecycle-configuration --bucket "$OFFSITE_BUCKET" --output json 2>/dev/null | grep -c GLACIER_IR)"
    echo "$ver|$pab|$lc"
  )"
  IFS='|' read -r ob_ver ob_pab ob_lc <<< "$ob_state"
  problems=""
  [ "$ob_ver" = "Enabled" ]     || problems="$problems versioning=$ob_ver"
  [ "$ob_pab" = "TrueTrueTrueTrue" ] || problems="$problems public-access-block=$ob_pab"
  [ "${ob_lc:-0}" -ge 1 ]       || problems="$problems no-GLACIER_IR-lifecycle"
  if [ -z "$problems" ]; then
    record "Offsite bucket config" PASS "versioned, private, GLACIER_IR lifecycle"
  else
    record "Offsite bucket config" FAIL "issues:$problems"
  fi
else
  record "Offsite bucket config" FAIL "cannot read $STACK_DIR/.env or aws CLI missing"
fi

# =========================================================================
# Host boot readiness
# =========================================================================
# A user-scoped NIC profile once left this box up-but-unreachable for 38 hours
# after an automatic reboot: no network, so no k3s, so a silently failed backup.
# The host looked healthy from the console and dead from everywhere else.
if bootchk="$("$STACK_DIR/scripts/setup-host-boot.sh" --check 2>&1)"; then
  record "Host boot readiness" PASS "NIC system-wide, default route, k3s+sshd enabled"
else
  record "Host boot readiness" FAIL "$(printf '%s' "$bootchk" | grep -i warn | head -1)"
fi

# =========================================================================
# Alert delivery  (Grafana-native rules -> ntfy on the calendar Pi)
# =========================================================================
# This block exists because the alerts were, for five days, unable to notify
# anyone at all: #8 shipped them as a PrometheusRule, and this cluster runs
# alertmanager.enabled=false on purpose, so they were evaluated and dropped.
# "The rule exists" was true the whole time and told us nothing. These checks
# assert the DELIVERY PATH, which is the part that was actually broken.
#
# The ntfy topic is the only access control on the channel, so it is read at
# runtime and never printed -- this repo is public.
if [ -n "$GRAFANA_PW" ]; then
  gapi() { curl -s --max-time 15 -u "admin:$GRAFANA_PW" "http://${GRAFANA_EP}$1"; }

  # -- 1. both ntfy contact points provisioned, and the severity route present
  read -r cp_n route_ok < <(gapi /api/v1/provisioning/contact-points | python3 -c '
import sys,json
try: cps=json.load(sys.stdin)
except Exception: print("0 no"); raise SystemExit
names={c.get("name") for c in cps}
print(len(names & {"ntfy-critical","ntfy-warning"}), "yes" if {"ntfy-critical","ntfy-warning"} <= names else "no")')
  if [ "${cp_n:-0}" = 2 ]; then
    record "Alert contact points" PASS "ntfy-critical + ntfy-warning provisioned"
  else
    record "Alert contact points" FAIL "expected 2 ntfy contact points, found ${cp_n:-0}"
  fi

  pol=$(gapi /api/v1/provisioning/policies | python3 -c '
import sys,json
try: p=json.load(sys.stdin)
except Exception: print("ERR"); raise SystemExit
d=p.get("receiver","")
crit=[r.get("receiver") for r in (p.get("routes") or [])
      if ["severity","=","critical"] in (r.get("object_matchers") or [])]
print("%s->%s" % (d, crit[0]) if crit else "NOROUTE")')
  case "$pol" in
    "ntfy-warning->ntfy-critical") record "Alert routing" PASS "default ntfy-warning, severity=critical to ntfy-critical" ;;
    NOROUTE) record "Alert routing" FAIL "no severity=critical route -- criticals would go to the warning channel" ;;
    *)       record "Alert routing" FAIL "unexpected policy tree: $pol" ;;
  esac

  # -- 2. every rule actually EVALUATES. A rule whose query errors is a rule
  #       that will never fire, and it looks exactly like a quiet one.
  read -r r_tot r_bad < <(gapi /api/prometheus/grafana/api/v1/rules | python3 -c '
import sys,json
try: gs=json.load(sys.stdin)["data"]["groups"]
except Exception: print("0 0"); raise SystemExit
rs=[r for g in gs for r in g.get("rules",[])]
print(len(rs), sum(1 for r in rs if r.get("health")!="ok"))')
  if [ "${r_tot:-0}" -ge 11 ] && [ "${r_bad:-1}" -eq 0 ]; then
    record "Alert rules healthy" PASS "$r_tot rules, all evaluating"
  else
    record "Alert rules healthy" FAIL "${r_tot:-0} rules, ${r_bad:-?} with an evaluation error"
  fi

  # -- 3. the topic Grafana publishes to still EXISTS on the Pi.
  #       Rebuilding the Pi regenerates a random topic unless one is supplied,
  #       and ntfy is deny-all: the old topic would then 403 and every alert
  #       would vanish silently. A GET is used, not a POST, so this check never
  #       buzzes the phone. 200 = topic reachable and permitted, 403 = drift.
  ntfy_url=$(gapi /api/v1/provisioning/contact-points | python3 -c '
import sys,json
try: cps=json.load(sys.stdin)
except Exception: raise SystemExit
for c in cps:
    if c.get("name")=="ntfy-critical":
        print(c.get("settings",{}).get("url","")); break')
  if [ -n "$ntfy_url" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${ntfy_url}/json?poll=1&since=1s")
    ntfy_host=${ntfy_url#http://}; ntfy_host=${ntfy_host%%/*}
    case "$code" in
      200) record "ntfy topic reachable" PASS "$ntfy_host accepted the configured topic" ;;
      403) record "ntfy topic reachable" FAIL "$ntfy_host denied it -- topic drift, alerts are being dropped" ;;
      000) record "ntfy topic reachable" FAIL "$ntfy_host unreachable (Pi down, or ufw)" ;;
      *)   record "ntfy topic reachable" FAIL "$ntfy_host returned HTTP $code" ;;
    esac
  else
    record "ntfy topic reachable" FAIL "ntfy-critical contact point has no url"
  fi
else
  record "Alert contact points" FAIL "no grafana admin password; cannot check"
  record "Alert routing"        FAIL "no grafana admin password; cannot check"
  record "Alert rules healthy"  FAIL "no grafana admin password; cannot check"
  record "ntfy topic reachable" FAIL "no grafana admin password; cannot check"
fi

# =========================================================================
# Report
# =========================================================================
echo
echo "================= HOME SERVER — FUNCTIONAL VERIFICATION ================="
printf '%-26s %-6s %s\n' "SERVICE" "RESULT" "DETAIL"
printf '%-26s %-6s %s\n' "--------------------------" "------" "-----------------------------------------"
for r in "${ROWS[@]}"; do
  IFS='|' read -r n s d <<< "$r"
  printf '%-26s %-6s %s\n' "$n" "$s" "$d"
done
echo "------------------------------------------------------------------------"
echo "TOTAL: $PASS passed, $FAIL failed   ($(date '+%Y-%m-%d %H:%M:%S %Z'))"
[ "$FAIL" -eq 0 ]
