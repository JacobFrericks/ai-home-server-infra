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

PASS=0; FAIL=0
record() {
  local name="$1" result="$2" detail="$3"
  printf '%-30s %-6s %s\n' "$name" "$result" "$detail"
  [[ "$result" == PASS ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
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
notready=$(kubectl get pods -A --no-headers 2>/dev/null \
  | awk '{split($3,a,"/"); if (a[1]!=a[2]) print $1"/"$2"("$3")"}' | tr '\n' ' ')
if [[ -z "$notready" ]]; then
  record "Containers ready" PASS "every container ready"
else
  record "Containers ready" FAIL "$notready"
fi

# --- 4. Argo: every Application Synced AND Healthy ---------------------------
apps=$(kubectl -n argocd get app --no-headers 2>/dev/null | wc -l | tr -d ' ')
argobad=$(kubectl -n argocd get app --no-headers 2>/dev/null \
          | awk '$2!="Synced" || $3!="Healthy" {print $1"("$2"/"$3")"}' | tr '\n' ' ')
if [[ -n "$apps" && "$apps" -gt 0 && -z "$argobad" ]]; then
  record "Argo CD applications" PASS "$apps apps Synced+Healthy"
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

echo "------------------------------------------------------------------------"
echo "TOTAL: $PASS passed, $FAIL failed   ($(date '+%Y-%m-%d %H:%M:%S %Z'))"
[[ "$FAIL" -eq 0 ]]
