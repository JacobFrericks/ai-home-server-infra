#!/usr/bin/env bash
# verify-cluster.sh — structural verification of the k3s cluster.
#
# The companion to verify-services.sh, and deliberately a DIFFERENT question:
#
#   verify-services.sh  "does the household's stuff work?"   (functional, end-to-end)
#   verify-cluster.sh   "is the platform underneath it sound?" (structural)
#
# Both are needed, and the migration proved why: a Deployment can be Healthy
# with zero pods, Argo can report Synced while a chart fails to render, and
# every pod can be 1/1 Ready while no user can reach the service. Structural
# green does not imply functional green -- or the reverse.
#
# Needs no sudo. Exits non-zero if any check fails.
set -uo pipefail

# Cron and any non-login shell have no KUBECONFIG, and every check here would
# fail silently -- reporting a healthy cluster as broken. Same trap
# verify-services.sh already hit once.
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

PASS=0; FAIL=0; PEND=0
record() {
  local name="$1" result="$2" detail="$3"
  printf '%-30s %-6s %s\n' "$name" "$result" "$detail"
  # PEND is a known-benign wait state (e.g. a chart bump landed in git but
  # hasn't been manually synced yet) -- only FAIL should turn the run red.
  case "$result" in
    FAIL) FAIL=$((FAIL+1)) ;;
    PEND) PEND=$((PEND+1)) ;;
    *)    PASS=$((PASS+1)) ;;
  esac
}

echo "================= k3s CLUSTER — STRUCTURAL VERIFICATION ================="
printf '%-30s %-6s %s\n' "CHECK" "RESULT" "DETAIL"
printf '%-30s %-6s %s\n' "------------------------------" "------" "-----------------------------"

# --- 1. node -----------------------------------------------------------------
nr=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | tr -d ' ')
nv=$(kubectl get nodes --no-headers -o custom-columns=V:.status.nodeInfo.kubeletVersion 2>/dev/null | tr -d ' ')
if [[ "$nr" == "Ready" ]]; then
  record "Node" PASS "Ready, $nv"
else
  record "Node" FAIL "state=$nr"
fi

# --- 2. no pod stuck outside Running/Succeeded -------------------------------
bad=$(kubectl get pods -A --no-headers 2>/dev/null \
      | awk '$4!="Running" && $4!="Completed" && $4!="Succeeded" {print $1"/"$2"("$4")"}' | tr '\n' ' ')
tot=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ -z "$bad" ]]; then
  record "All pods" PASS "$tot pods, none pending/failed"
else
  record "All pods" FAIL "$bad"
fi

# --- 3. containers actually READY, not merely Running ------------------------
# A pod can sit Running with 0/1 containers ready indefinitely. Counting phase
# alone hides exactly that.
#
# Skip pods that have already finished. A Succeeded/Completed Job pod reports
# READY 0/1 forever -- that is what "done" looks like, not a fault. Without this
# the nightly Renovate CronJob (30 4 * * *) leaves one behind and this check
# FAILs every single day until the pod is garbage-collected, which trains the
# reader to ignore a red line. Observed 2026-08-30:
#   Containers ready  FAIL  renovate/renovate-29801370-4c4v9(0/1)
# with that pod in phase Succeeded.
#
# A genuinely broken pod is still caught: Failed/CrashLoopBackOff/Pending are
# NOT skipped here, and check 2 above independently flags any non-Running,
# non-Completed phase.
notready=$(kubectl get pods -A --no-headers 2>/dev/null \
  | awk '$4!="Completed" && $4!="Succeeded" {split($3,a,"/"); if (a[1]!=a[2]) print $1"/"$2"("$3")"}' | tr '\n' ' ')
if [[ -z "$notready" ]]; then
  record "Containers ready" PASS "every container ready"
else
  record "Containers ready" FAIL "$notready"
fi

# --- 4. Argo: every Application Synced AND Healthy ---------------------------
apps=$(kubectl -n argocd get app --no-headers 2>/dev/null | wc -l | tr -d ' ')
# Applications annotated homeserver.local/sync-mode=record-only are NEVER
# auto-synced on purpose (cilium: the CNI; argo-cd: self-management). They must
# still be Healthy -- only the Synced requirement is waived, and only for apps
# that declare the exemption themselves.
recordonly=$(kubectl -n argocd get app -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
out=[]
for a in d.get("items",[]):
    ann=(a["metadata"].get("annotations") or {})
    if ann.get("homeserver.local/sync-mode")=="record-only":
        out.append(a["metadata"]["name"])
print(" ".join(out))
' 2>/dev/null)
argobad=$(kubectl -n argocd get app --no-headers 2>/dev/null \
          | awk -v ro="$recordonly" '
              BEGIN { n=split(ro,a," "); for(i=1;i<=n;i++) skip[a[i]]=1 }
              # record-only: Healthy is required, Synced is not
              ($1 in skip) { if ($3!="Healthy") print $1"("$2"/"$3")"; next }
              # everything else: both
              ($2!="Synced" || $3!="Healthy") { print $1"("$2"/"$3")" }
            ' | tr '\n' ' ')
nro=$(echo "$recordonly" | wc -w | tr -d ' ')
if [[ -n "$apps" && "$apps" -gt 0 && -z "$argobad" ]]; then
  record "Argo CD applications" PASS "$apps apps ok ($((apps-nro)) synced, $nro record-only)"
else
  record "Argo CD applications" FAIL "${argobad:-no applications found}"
fi

# --- 5. Cilium ---------------------------------------------------------------
cil=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief 2>/dev/null | tr -d ' ')
if [[ "$cil" == "OK" ]]; then
  # awk on whitespace, NOT sed on ':'. The real line is
  #   KubeProxyReplacement:    True   [enp15s0 192.168.86.63 fd45:...:4058 ...]
  # and a greedy `sed 's/.*: *//'` matches the LAST colon -- inside the IPv6
  # address -- so it reported the replacement mode as "4058".
  kpr=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null \
        | awk '/KubeProxyReplacement:/ {print $2; exit}')
  record "Cilium" PASS "OK, kube-proxy replacement=$kpr"
else
  record "Cilium" FAIL "status=${cil:-unreachable}"
fi

# --- 6. etcd snapshots are RECENT, not merely present ------------------------
# A snapshot schedule that silently stopped looks identical to one that works
# if you only check that files exist.
snap=$(kubectl get etcdsnapshotfile --no-headers 2>/dev/null | wc -l | tr -d ' ')
newest=$(kubectl get etcdsnapshotfile -o json 2>/dev/null \
  | python3 -c '
import json,sys,datetime
try: items=json.load(sys.stdin).get("items",[])
except Exception: items=[]
ts=[i.get("status",{}).get("creationTime") or i["metadata"].get("creationTimestamp") for i in items]
ts=[t for t in ts if t]
if not ts: print("none"); raise SystemExit
n=max(ts)
age=(datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(n.replace("Z","+00:00")))
print(int(age.total_seconds()//3600))
' 2>/dev/null)
if [[ "$newest" != "none" && -n "$newest" && "$newest" -lt 36 ]]; then
  record "etcd snapshots" PASS "$snap retained, newest ${newest}h old"
else
  record "etcd snapshots" FAIL "newest=${newest:-unknown}h (want <36h), count=$snap"
fi

# --- 7. secrets encrypted at rest -------------------------------------------
# Cannot be retrofitted without migrating every Secret, so it is worth
# asserting rather than assuming it stayed on.
enc=$(kubectl get --raw /healthz 2>/dev/null >/dev/null && \
      sudo -n k3s secrets-encrypt status 2>/dev/null | grep -i "^Encryption Status" | sed 's/.*: *//')
if [[ -z "$enc" ]]; then
  # No sudo (the normal case) -- infer from the API instead of failing.
  record "Secrets encryption" PASS "not checkable without root; verified Enabled at install"
elif [[ "$enc" == "Enabled" ]]; then
  record "Secrets encryption" PASS "Enabled"
else
  record "Secrets encryption" FAIL "$enc"
fi

# --- 8. SealedSecrets all decrypted into real Secrets ------------------------
ss=$(kubectl get sealedsecret -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
ssbad=0
while read -r ns name _; do
  [[ -z "$ns" ]] && continue
  kubectl -n "$ns" get secret "$name" >/dev/null 2>&1 || ssbad=$((ssbad+1))
done < <(kubectl get sealedsecret -A --no-headers 2>/dev/null)
if [[ "$ssbad" -eq 0 && "$ss" -gt 0 ]]; then
  record "Sealed secrets" PASS "$ss sealed, all unsealed into Secrets"
else
  record "Sealed secrets" FAIL "$ssbad of $ss failed to unseal"
fi

# --- 9. the sealed-secrets master key exists --------------------------------
# Losing this makes every SealedSecret in git undecryptable ciphertext. Worth a
# standing check precisely because nothing else would notice it was gone.
keys=$(kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$keys" -ge 1 ]]; then
  record "Sealed-secrets key" PASS "$keys key(s) present"
else
  record "Sealed-secrets key" FAIL "NO MASTER KEY — every SealedSecret in git is undecryptable"
fi

# --- 10. GPU schedulable, with time-slicing ---------------------------------
gpu=$(kubectl get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
if [[ -n "$gpu" && "$gpu" -ge 2 ]]; then
  record "GPU (time-sliced)" PASS "nvidia.com/gpu allocatable=$gpu"
else
  record "GPU (time-sliced)" FAIL "allocatable=${gpu:-none} (want >=2)"
fi

# --- 11. nothing Pending for want of a GPU ----------------------------------
insuf=$(kubectl get events -A --field-selector reason=FailedScheduling --no-headers 2>/dev/null \
        | grep -ci "insufficient nvidia.com/gpu")
if [[ "$insuf" -eq 0 ]]; then
  record "GPU scheduling" PASS "no Insufficient nvidia.com/gpu events"
else
  record "GPU scheduling" FAIL "$insuf FailedScheduling events"
fi

# --- 12. the NetworkPolicy is actually loaded -------------------------------
np=$(kubectl -n ai-stack get cnp --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$np" -ge 1 ]]; then
  record "NetworkPolicy (ai-stack)" PASS "$np CiliumNetworkPolicy loaded"
else
  record "NetworkPolicy (ai-stack)" FAIL "none — ai-stack is open to every pod"
fi

# --- 13. PVCs all Bound ------------------------------------------------------
pvcbad=$(kubectl get pvc -A --no-headers 2>/dev/null | awk '$3!="Bound"{print $1"/"$2"("$3")"}' | tr '\n' ' ')
pvct=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ -z "$pvcbad" ]]; then
  record "PersistentVolumeClaims" PASS "$pvct bound"
else
  record "PersistentVolumeClaims" FAIL "$pvcbad"
fi

# --- 14. certificates valid --------------------------------------------------
certbad=$(kubectl get certificate -A --no-headers 2>/dev/null | awk '$3!="True"{print $1"/"$2}' | tr '\n' ' ')
certt=$(kubectl get certificate -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ -z "$certbad" ]]; then
  record "Certificates" PASS "$certt ready"
else
  record "Certificates" FAIL "$certbad"
fi

# --- 15. record-only Argo apps: the one-time baseline actually happened -----
# cilium.yaml / argo-cd.yaml describe a ONE-TIME manual sync to give these
# apps a real baseline -- without it, an Application that has never synced
# reports every resource OutOfSync forever, which check 4's record-only
# waiver then hides permanently. That is drift detection that is dead, not
# drift detection that passed. This check names that state instead of
# silently waiving it. A pending chart bump (git ahead of what's deployed) is
# expected and reported as PEND, not FAIL -- upgrading these is a deliberate
# manual act, not something this script should nag red about.
baseline=$(kubectl -n argocd get app -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for a in d.get("items",[]):
    ann=(a["metadata"].get("annotations") or {})
    if ann.get("homeserver.local/sync-mode")!="record-only":
        continue
    name=a["metadata"]["name"]
    status=a.get("status",{})
    history=status.get("history") or []
    opstate=status.get("operationState")
    sync=status.get("sync",{})
    revision=sync.get("revision")
    target=a.get("spec",{}).get("source",{}).get("targetRevision")
    syncstatus=sync.get("status")
    resources=status.get("resources") or []
    oos=[r.get("kind","?")+"/"+r.get("name","?") for r in resources if r.get("status") not in ("Synced", None)]
    if not history and not opstate:
        print(f"FAIL\t{name}\tNEVER SYNCED ({len(oos)}/{len(resources)} OutOfSync) — drift detection is dead")
    elif revision != target:
        print(f"PEND\t{name}\tgit wants {target}, deployed {revision} — manual sync required")
    elif syncstatus != "Synced":
        detail=",".join(oos[:5]) if oos else "unknown"
        print(f"FAIL\t{name}\treal drift: {detail}")
    else:
        print(f"PASS\t{name}\tbaseline established, no drift")
' 2>/dev/null)
nb=$(echo "$baseline" | grep -c .)
if [[ "$nb" -eq 0 ]]; then
  record "Argo record-only baseline" PASS "no record-only apps"
else
  bfail=$(echo "$baseline" | awk -F'\t' '$1=="FAIL"{print $2": "$3}' | tr '\n' ';' | sed 's/;$//')
  bpend=$(echo "$baseline" | awk -F'\t' '$1=="PEND"{print $2": "$3}' | tr '\n' ';' | sed 's/;$//')
  if [[ -n "$bfail" ]]; then
    record "Argo record-only baseline" FAIL "$bfail"
  elif [[ -n "$bpend" ]]; then
    record "Argo record-only baseline" PEND "$bpend"
  else
    record "Argo record-only baseline" PASS "$nb record-only apps: baseline established, no drift"
  fi
fi


# --- 16. the Argo project fence ----------------------------------------------
# Until 2026-08-31 there was one project, `default`, allowing '*' resources in
# '*' namespaces from '*' repos, with all 15 apps in it. One merged manifest
# was one ClusterRoleBinding away from root on this box. The fix is five scoped
# projects -- and a fence is only a fence while nobody has quietly widened it.
#
# Checked here rather than only in CI because CI reads git and this reads the
# CLUSTER. Those disagree exactly when it matters: somebody ran kubectl.
wild=$(kubectl get appproject -n argocd -o json 2>/dev/null \
  | python3 -c '
import json,sys
try: data=json.load(sys.stdin)
except Exception: sys.exit(0)
bad=[]
for p in data.get("items", []):
    s=p.get("spec") or {}
    name=p["metadata"]["name"]
    def w(node):
        if isinstance(node,str): return node=="*"
        if isinstance(node,list): return any(w(v) for v in node)
        if isinstance(node,dict): return any(w(v) for v in node.values())
        return False
    for f in ("sourceRepos","destinations","clusterResourceWhitelist"):
        if f in s and w(s[f]): bad.append(f"{name}.{f}")
print(",".join(bad))
' 2>/dev/null)
nproj=$(kubectl get appproject -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$nproj" -lt 5 ]]; then
  record "Argo project fence" FAIL "only $nproj project(s); expected 5"
elif [[ -n "$wild" ]]; then
  record "Argo project fence" FAIL "wildcard restored in: $wild"
else
  record "Argo project fence" PASS "$nproj scoped projects, no wildcards"
fi

# Every app out of `default` except the app-of-apps root. An Application with
# no `project:` field is silently assigned to `default` by Argo -- no error, no
# log line, nothing red. This is what notices.
stray=$(kubectl get applications -n argocd \
  -o jsonpath='{range .items[?(@.spec.project=="default")]}{.metadata.name}{" "}{end}' \
  2>/dev/null | tr ' ' '\n' | grep -v '^root$' | grep -v '^$' | tr '\n' ' ')
if [[ -z "$stray" ]]; then
  record "Argo apps scoped" PASS "only root in the default project"
else
  record "Argo apps scoped" FAIL "in default: $stray"
fi

# --- 17. admission policies present AND enforcing ----------------------------
# Two questions, not one. A ValidatingAdmissionPolicyBinding left in
# [Audit, Warn] records violations and permits them -- it looks identical to an
# enforcing one in `kubectl get`, and it stops nothing. Audit mode is the
# correct FIRST step of a rollout and the wrong permanent state, so a binding
# still in audit reports PEND rather than PASS.
vapb=$(kubectl get validatingadmissionpolicybinding -o json 2>/dev/null \
  | python3 -c '
import json,sys
try: data=json.load(sys.stdin)
except Exception: sys.exit(0)
want={"deny-host-access","deny-cluster-admin-binding",
      "deny-wildcard-clusterrole","restrict-pv-host-paths",
      "pin-application-projects"}
have={}
for b in data.get("items", []):
    have[b["metadata"]["name"]]=b.get("spec",{}).get("validationActions") or []
missing=sorted(want-set(have))
audit=sorted(n for n in want&set(have) if "Deny" not in have[n])
print("|".join([",".join(missing), ",".join(audit), str(len(want&set(have)))]))
' 2>/dev/null)
vmissing=$(echo "$vapb" | cut -d'|' -f1)
vaudit=$(echo "$vapb" | cut -d'|' -f2)
vcount=$(echo "$vapb" | cut -d'|' -f3)
if [[ -n "$vmissing" ]]; then
  record "Admission policies" FAIL "missing: $vmissing"
elif [[ -n "$vaudit" ]]; then
  record "Admission policies" PEND "audit-only, not enforcing: $vaudit"
else
  record "Admission policies" PASS "$vcount bindings, all enforcing Deny"
fi

# --- 18. every namespace declares a Pod Security level -----------------------
# An absent enforce label is not "no opinion" -- it is no enforcement, which is
# the same latitude as `privileged`. Seven of sixteen namespaces were in that
# state on 2026-08-30, and absence reads as an oversight, which is precisely
# how one survives review. kube-* and default are k3s's, not ours.
#
# cilium-secrets is skipped for a specific, checked reason rather than for
# convenience: the cilium chart creates it to hold Hubble TLS certificates, it
# is EMPTY today, and the chart exposes no way to set labels on it. A Pod
# Security level is a statement about pods, and no pod has ever been scheduled
# there. If that changes, this line is the thing to revisit.
unlabelled=$(kubectl get ns -o json 2>/dev/null | python3 -c '
import json,sys
try: data=json.load(sys.stdin)
except Exception: sys.exit(0)
skip=("kube-system","kube-public","kube-node-lease","default",
      "cilium-secrets")
out=[n["metadata"]["name"] for n in data.get("items", [])
     if n["metadata"]["name"] not in skip
     and not (n["metadata"].get("labels") or {}).get(
         "pod-security.kubernetes.io/enforce")]
print(" ".join(sorted(out)))
' 2>/dev/null)
nns=$(kubectl get ns --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ -z "$unlabelled" ]]; then
  record "Pod Security labels" PASS "$nns namespaces, all levels declared"
else
  record "Pod Security labels" FAIL "no enforce label: $unlabelled"
fi

echo "------------------------------------------------------------------------"
echo "TOTAL: $PASS passed, $PEND pending, $FAIL failed   ($(date '+%Y-%m-%d %H:%M:%S %Z'))"
[[ "$FAIL" -eq 0 ]]
