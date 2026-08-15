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
