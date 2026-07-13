# Migrating the AI Home Server from Docker Compose to k3s — a hands-on walkthrough

> **Status: DRAFT for review — do not run yet.** This page is the human-readable
> companion to the internal migration plan. It contains every command and the
> reasoning behind it, written to be read top-to-bottom. Nothing here has been
> executed. Before running it, fill in the one run-time placeholder
> (`<METALLB_POOL>`) and pin the chart/manifest versions noted inline.

## Why do this at all

This server already runs beautifully on Docker Compose. So why move anything?

Two reasons, and they pull in different directions:

1. **I want to learn Kubernetes properly** — not a toy cluster, but the real
   thing I set up, break, fix, and *maintain* over time. It should look good on a
   résumé because it *is* real: GitOps, an eBPF dataplane, GPU scheduling, load
   balancing, ingress with automated TLS, monitoring, and disaster recovery.
2. **The family cannot notice.** My partner talks to Home Assistant every day and
   we watch Plex every night. "The lights stopped responding because I was
   learning Kubernetes" is not acceptable. Reliability is a hard requirement.

Those two goals give us a rule that decides *everything* below:

> **If a service can't work *well* on Kubernetes, it doesn't belong on Kubernetes.**

On a **single node**, Kubernetes gives you no high-availability benefit — if the
box dies, everything dies either way. So we're not chasing uptime; we're chasing
*orchestration value* (declarative config, self-healing, rollouts, GPU
scheduling, GitOps) for the workloads that actually benefit, and we deliberately
leave everything else where it already works.

### What moves, and what stays

**Stays on Docker Compose — on purpose:**

- **Home Assistant** — host networking, `NET_ADMIN`/`NET_RAW` for Bluetooth,
  mDNS device discovery, and daily family use. Fragile and painful on k8s, and
  the most punishing thing to get wrong.
- **Piper (TTS) + Whisper (STT)** — the Wyoming voice pipeline, tightly coupled
  to Home Assistant.
- **Plex** — ~1 TB of media bind-mounted at native paths, GPU transcode, and
  DLNA discovery that wants host networking.

Keeping these on Compose is not a cop-out — being able to explain *why* you left
stateful, hardware-coupled, family-critical services off a single-node cluster
is exactly the judgment that separates operating Kubernetes from merely
installing it.

**Moves to k3s — because it genuinely benefits:**

- **The web/search tier** — Open WebUI, SearXNG, and the SearXNG-MCP server.
  Clean HTTP services, ideal behind an ingress.
- **Ollama** — the flagship. GPU-scheduled inference is the single most
  résumé-relevant piece here, and an inference server is single-replica by
  nature, so we lose nothing to the single node.
- **Monitoring** — Prometheus/Grafana/Loki as a proper in-cluster stack.

### The distribution: k3s, with the training wheels removed

We use **k3s** — it's certified, conformant Kubernetes (same API, same
`kubectl`, same manifests), just packaged as a single binary that's far less
likely to break during an upgrade than a hand-rolled `kubeadm` cluster. That
directly serves the "family can't notice" requirement.

But k3s ships with batteries included (Traefik, ServiceLB, flannel, kube-proxy),
and installing those for me would skip the learning. So we **disable them and
wire the real components ourselves**:

| Bundled (disabled) | We install instead | Why |
|---|---|---|
| flannel (CNI) | **Cilium** (eBPF) | Modern dataplane, network policy, résumé-relevant |
| kube-proxy | **Cilium kube-proxy replacement** | Learn how service routing really works |
| ServiceLB | **MetalLB** | Real LAN load-balancer, name-recognized skill |
| Traefik | **ingress-nginx** + **cert-manager** | The most common ingress in the wild |
| SQLite datastore | **embedded etcd** | Enables `etcd-snapshot` backups / real DR |

We also add **Argo CD** (GitOps) and **Sealed Secrets**, so the cluster is
driven from git exactly like this repo's existing pull-based deploy — just
leveled up.

## This environment (the facts the commands assume)

Everything below is written for *this specific box*. Swap nothing without
thinking.

- **Host:** `homeserver`, reachable as `ssh homeserver` (`jacob@192.168.86.63`).
- **OS:** Debian 13 (trixie), kernel 6.12, 32 cores, 123 GiB RAM, ~1.8 TB free
  on `/`.
- **GPU:** NVIDIA RTX 3090 (24 GB), driver **590.44.01**, CUDA 13.1,
  **nvidia-container-toolkit 1.19.1** already installed and working for Docker.
  Driver/CUDA are deliberately held at the OS level.
- **Network:** interface `enp15s0`, **192.168.86.63/24**, a **DHCP reservation**
  on the Nest Wifi router (gateway **192.168.86.1**). avahi/mDNS is active
  (`homeserver.local` resolves). The IP is stable across reboots, so we keep it.
- **Existing app stack** (`/home/jacob/docker/ai-stack`, compose project
  `ai-stack`): `ollama`, `open-webui`, `searxng`, `searxng-mcp`,
  `homeassistant`, `piper`, `whisper`, `plex`.
- **Existing monitoring stack** (`monitoring/`, separate compose project):
  Grafana/Prometheus/Loki + exporters.
- **Ports already bound on the host** (watch for collisions): `22`, `3000`
  (Grafana), `8080` (Open WebUI), `8123` (Home Assistant), `10200`/`10300`
  (voice), `32400` (Plex). **Free and reserved for k8s:** `80`, `443`, `6443`.
- **Ollama model store:** `/usr/share/ollama/.ollama` — we reuse it in-place via
  a `hostPath`, so **no multi-hundred-GB copy**. The model wired for tools/search
  is **`gemma4:31b`** (~19 GB); it's the only model we touch here.
- **Deploy model today:** a weekly cron runs `deploy.sh` (git pull → `compose
  pull && up -d` → health check). We keep this for the services that stay on
  Compose.

### A coupling you must respect: SearXNG-MCP feeds *two* consumers

`searxng-mcp` (loopback `127.0.0.1:9200/mcp`) is the web-search tool for **both**
Open WebUI **and** the Home Assistant voice agent. SearXNG and the MCP server are
deliberately **loopback-only** — never on the LAN, no ufw rule. That shapes the
web-tier migration: when Open WebUI moves into the cluster, SearXNG-MCP has to
move with it, *and* Home Assistant (staying on Compose) still needs to reach it.
We solve that with a **host-restricted** service (reachable by the host/HA, not
advertised to the whole LAN) — see Phase 6. We never widen its exposure.

## Security posture (non-negotiable, applies throughout)

- **Least-privilege firewall, default deny.** On a single node the control plane
  talks to *itself*, so **nothing** about it goes on the LAN. The Kubernetes API
  (`6443`), kubelet (`10250`), etcd (`2379/2380`), and MetalLB memberlist
  (`7946`) stay node-internal. We administer over SSH, so `kubectl` hits the API
  on `localhost`. Only the ingress (`80/443`) and *specific*, justified service
  ports ever face the LAN. We re-check `sudo ufw status numbered` after every
  change.
- **GitOps stays pull-based → zero inbound from GitHub.** Argo CD pulls the repo;
  the server initiates every connection, exactly like `deploy.sh`. GitHub's
  runners never contact the server, so there is **no inbound hole to open** for
  CI/CD. That's the whole point of the pull model.
- **If a push trigger is ever added, verify the GitHub OIDC token.** Should we
  later want an Action to reach the server (a sync webhook, an image push), the
  receiving endpoint must validate the runner's short-lived **GitHub OIDC JWT** —
  signature against GitHub's JWKS, and the claims
  `iss=https://token.actions.githubusercontent.com`, the expected `aud`, and
  `repository=JacobFrericks/...`. Never a long-lived PAT, never exposing `6443`.
- **Secrets never land in git.** This repo is public. Under GitOps we use
  **Sealed Secrets**: only encrypted material is committed; the cluster holds the
  key. This preserves today's "secrets only on the server" property.
- **Preserve each service's exposure contract.** Ollama and SearXNG-MCP are
  private today; they stay private after the move.

## How to stop safely at any point

This is a multi-day job and you might have to walk away mid-step. The whole
approach is **additive**:

- Phases 1–5 build the cluster *next to* Compose and touch **zero** running
  services. Stop anywhere in 1–5 and the family stack is untouched.
- Every workload cutover (Phases 6–8) is ordered: **(1)** bring up the k8s copy
  while Compose keeps serving, **(2)** fully verify it, **(3)** *only then* stop
  the Compose copy. Interrupted before step 3 → both copies run (harmless), never
  an outage.
- Roll back a service by re-enabling it in `docker-compose.yml` and
  `docker compose up -d`. Roll back the cluster with an etcd snapshot, or remove
  it entirely with `/usr/local/bin/k3s-uninstall.sh` — which doesn't touch Docker
  at all.

---

# Phase 0 — Prep & safety

**Goal:** a rollback baseline, a chosen MetalLB IP range, and a firewall plan.
No cluster yet.

First, capture what "healthy" looks like now, so we can prove later that nothing
regressed:

```bash
ssh homeserver
cd /home/jacob/docker/ai-stack
./scripts/verify-services.sh          # baseline health of every service
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
git status                             # confirm the repo is clean
```

Note the working URLs in your browser now: Open WebUI `http://homeserver.local:8080`,
Home Assistant `:8123`, Plex `:32400`, Grafana `:3000`. These are your
regression checks.

**Pick the MetalLB address block.** MetalLB will hand out LAN IPs to
`LoadBalancer` services, so they must be real addresses on `192.168.86.0/24`
that the **Nest router won't also hand out via DHCP**. Open the Google Home app →
Wifi → DHCP/IP settings and note the DHCP range. Choose ~8 addresses *outside*
it — a common choice near the top of the subnet:

```bash
# Example ONLY — confirm these are outside the Nest DHCP pool and unused:
for ip in 240 241 242 243 244 245 246 247; do
  ping -c1 -W1 192.168.86.$ip >/dev/null && echo "192.168.86.$ip IN USE" || echo "192.168.86.$ip free"
done
```

Record your final choice as `<METALLB_POOL>` (e.g. `192.168.86.240-192.168.86.247`);
you'll paste it into Phase 3.

**Plan the firewall (apply later, just-in-time).** ufw is enabled. The key idea:
open as little as possible, and **never** put the control plane on the LAN. We'll
apply these in the phases that need them, but here's the whole set so you can see
the shape:

```bash
# Intra-host pod/service traffic (NOT LAN exposure) — lets ufw's forward policy
# pass Cilium traffic. Applied in Phase 2:
sudo ufw allow from 10.42.0.0/16    # pod CIDR
sudo ufw allow from 10.43.0.0/16    # service CIDR

# Ingress, LAN-facing — applied in Phase 4:
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# DELIBERATELY NOT OPENED to the LAN: 6443 (API), 10250 (kubelet),
# 2379/2380 (etcd), 7946 (MetalLB). They stay node-internal.
sudo ufw status numbered            # re-run after every change
```

**Prove the control plane isn't exposed** (from your laptop, later):

```bash
nmap -p 6443,10250,2379 192.168.86.63   # expect: closed/filtered
```

**Family-safe checkpoint:** nothing changed. ✅

---

# Phase 1 — Install k3s (control plane only)

**Goal:** a running k3s server with the bundled extras disabled, `kubectl`
usable as `jacob`, and the CLI toolbelt installed. The node will be
**NotReady** at the end — that's expected, because we haven't installed a CNI
yet.

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --cluster-init \
  --disable traefik \
  --disable servicelb \
  --disable-network-policy \
  --flannel-backend=none \
  --disable-kube-proxy" sh -
```

What each flag buys us:

- `--cluster-init` — use **embedded etcd** instead of the default SQLite. etcd is
  what real clusters run, and it's what `k3s etcd-snapshot` backs up (our DR in
  Phase 9).
- `--disable traefik` — we'll run ingress-nginx (Phase 4).
- `--disable servicelb` — we'll run MetalLB (Phase 3).
- `--disable-network-policy` — k3s's built-in policy engine (kube-router) would
  fight Cilium; Cilium provides policy.
- `--flannel-backend=none` — no bundled CNI; **Cilium** takes over (Phase 2).
  This is *why* the node starts NotReady.
- `--disable-kube-proxy` — Cilium will replace kube-proxy in eBPF. Deliberately
  the "hard mode" that teaches how service routing actually works.

Give `jacob` a working kubeconfig (root-owned by default — we copy it and lock
the perms rather than world-reading it):

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config
export KUBECONFIG=~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
```

Install the toolbelt:

```bash
# kubectl (matches server version; k3s also ships it, but a standalone is handy)
sudo curl -Lo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo chmod +x /usr/local/bin/kubectl

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# cilium CLI (for status + connectivity test in Phase 2)
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin && rm cilium-linux-amd64.tar.gz
```

**Verify:**

```bash
kubectl get nodes          # STATUS = NotReady  ← correct, no CNI yet
kubectl get pods -A        # coredns Pending; that's expected too
```

**Family-safe checkpoint:** the cluster exists but does nothing; Compose is
untouched. The NotReady node is an *intentional* incomplete state — don't mistake
it for breakage.

---

# Phase 2 — Cilium (CNI + kube-proxy replacement)

**Goal:** a **Ready** node with an eBPF dataplane, validated end-to-end.

Because we disabled kube-proxy, Cilium must reach the API server directly, so we
tell it where the API lives:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=127.0.0.1 \
  --set k8sServicePort=6443 \
  --set operator.replicas=1 \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

- `kubeProxyReplacement=true` — Cilium does service load-balancing in eBPF
  instead of iptables/kube-proxy.
- `k8sServiceHost/Port` — the bootstrap detail: with no kube-proxy, Cilium can't
  rely on the in-cluster service IP to find the API, so we point it at the node's
  API endpoint.
- `operator.replicas=1` — single node; no point running two.
- `hubble.*` — flow observability we'll use to *prove* NetworkPolicies work in
  Phase 9.

Apply the intra-host firewall rules from Phase 0 now:

```bash
sudo ufw allow from 10.42.0.0/16
sudo ufw allow from 10.43.0.0/16
sudo ufw status numbered
```

**Verify** — this is the single best "is my cluster's networking actually
working" check you'll ever run:

```bash
cilium status --wait
kubectl get nodes                 # STATUS = Ready now
cilium connectivity test          # takes a few minutes; expect all green
```

**Family-safe checkpoint:** infrastructure only; Compose untouched.

---

# Phase 3 — MetalLB (LAN load-balancer)

**Goal:** `LoadBalancer` services get a real, pingable LAN IP from your pool.

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm install metallb metallb/metallb -n metallb-system --create-namespace
kubectl -n metallb-system rollout status deploy/metallb-controller
```

Now define the address pool. **Paste your Phase-0 block into `<METALLB_POOL>`:**

```yaml
# metallb-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses:
    - <METALLB_POOL>        # e.g. 192.168.86.240-192.168.86.247
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement       # L2 mode: the node answers ARP for these VIPs
metadata:
  name: lan-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - lan-pool
```

```bash
kubectl apply -f metallb-pool.yaml
```

**Verify** with a throwaway service, then delete it:

```bash
kubectl create deploy testlb --image=nginx
kubectl expose deploy testlb --port=80 --type=LoadBalancer
kubectl get svc testlb -w        # wait for EXTERNAL-IP from your pool
curl -s http://<that-ip> | head  # reachable from the host and your laptop
kubectl delete deploy,svc testlb
```

**Family-safe checkpoint:** infrastructure only.

---

# Phase 4 — ingress-nginx, cert-manager, and DNS

**Goal:** one HTTPS front door, automatic certificates, and hostnames that work
without fighting the Nest router's DNS.

Install ingress-nginx as a `LoadBalancer` — it will claim one IP from the MetalLB
pool, and that single VIP fronts *all* your web apps by hostname:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer
kubectl -n ingress-nginx get svc ingress-nginx-controller   # note the EXTERNAL-IP
```

Open the LAN-facing ingress ports now (nothing else LAN-facing gets opened):

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status numbered
```

**DNS without a DNS server.** Nest Wifi won't let you add local DNS records, so
instead of running Pi-hole we use **sslip.io**: any hostname of the form
`anything.<ip>.sslip.io` resolves to `<ip>` with zero configuration. If your
ingress VIP is `192.168.86.240`, then `openwebui.192.168.86.240.sslip.io` just
works, everywhere on the LAN. (Upgrade path: if you ever point a real domain at
the house, swap these for it and use Let's Encrypt DNS-01.)

Install cert-manager and a self-signed internal CA, so every ingress gets TLS
(browsers will warn until you trust the CA — fine for a home LAN):

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set crds.enabled=true
```

```yaml
# internal-ca.yaml — a self-signed root, then a CA issuer that signs app certs
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-root
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: home-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: home-ca
  secretName: home-ca-key-pair
  issuerRef:
    name: selfsigned-root
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: home-ca-issuer
spec:
  ca:
    secretName: home-ca-key-pair
```

```bash
kubectl apply -f internal-ca.yaml
```

**Verify** with a demo app (delete it after):

```bash
kubectl create deploy demo --image=nginx
kubectl expose deploy demo --port=80
kubectl create ingress demo --class=nginx \
  --rule="demo.<ingress-ip>.sslip.io/*=demo:80,tls" \
  --annotation cert-manager.io/cluster-issuer=home-ca-issuer
curl -k https://demo.<ingress-ip>.sslip.io    # served via ingress, TLS from your CA
kubectl delete deploy,svc,ingress demo
```

**Family-safe checkpoint:** infrastructure only.

---

# Phase 5 — Argo CD + Sealed Secrets + the GitOps repo

**Goal:** git becomes the source of truth. From here on, we change the cluster by
committing manifests, not by running `kubectl apply` — the same pull-based
philosophy as this repo's `deploy.sh`, but continuously reconciled.

Install Argo CD:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
```

Get the initial admin password, **then rotate it** and treat the UI as a
sensitive admin surface — reach it via a port-forward (note: local port `8080`
is taken by Open WebUI on this host, so use `8083`), *not* a LAN-published
ingress:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8083:443   # browse https://localhost:8083 over the SSH tunnel
```

Install **Sealed Secrets** *before any workload*, so no plaintext secret is ever
committed to this public-repo-adjacent GitOps repo:

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
# kubeseal CLI to encrypt secrets locally against the cluster's public key:
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep tag_name | cut -d'"' -f4 | tr -d v)
curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" | tar xz kubeseal
sudo install kubeseal /usr/local/bin/ && rm kubeseal
```

Create the GitOps repo `ai-home-server-k8s` with an **app-of-apps** layout:

```
ai-home-server-k8s/
  bootstrap/root-app.yaml         # the one Argo Application that owns all others
  infra/                          # metallb pool, ingress, cert-manager issuers, sealed-secrets
  workloads/
    web/                          # open-webui, searxng, searxng-mcp
    ollama/                       # gpu deployment
    monitoring/                   # kube-prometheus-stack values
  .github/workflows/ci.yml        # kubeconform + gitleaks, mirroring this repo
```

Point Argo at it once; everything else flows through git:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

**How secrets flow** (e.g. `WEBUI_SECRET_KEY`): create the Secret locally, seal
it, commit only the sealed version:

```bash
kubectl create secret generic open-webui-secret \
  --from-literal=WEBUI_SECRET_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > workloads/web/open-webui-sealedsecret.yaml
# ^ commit this. Only the cluster can decrypt it. The plaintext never hits git.
```

CI mirrors this repo's guardrails on GitHub-hosted runners — **pull-based, no
inbound to the server**:

```yaml
# .github/workflows/ci.yml (sketch)
# - kubeconform / kustomize build : validate every manifest
# - gitleaks                       : block any real secret from being committed
# NOTE: if a push-to-server trigger is ever added, the receiver MUST verify the
#       GitHub OIDC JWT (iss/aud/repository claims) — never a long-lived token.
```

**Verify:** commit a trivial manifest and watch Argo sync it in the UI with no
`kubectl apply`.

**Family-safe checkpoint:** infrastructure only. The whole platform is now up and
**still nothing family-facing has moved.**

---

# Phase 6 — Migrate the web/search tier

**Goal:** the first real workloads — Open WebUI, SearXNG, and SearXNG-MCP —
proving the platform end to end. This trio moves *together* because of the
coupling noted earlier.

Author manifests (committed to `workloads/web/`, synced by Argo):

- **searxng** — `Deployment` + `ClusterIP` Service. Its `settings.yml` (with the
  real `secret_key` and the required `formats: [html, json]`) becomes a **Sealed
  Secret** mounted at `/etc/searxng`. In-cluster it can be a normal ClusterIP —
  no loopback tricks needed, because its only client (searxng-mcp) is now a pod
  too.
- **searxng-mcp** — `Deployment` + Service, `SEARXNG_URL` pointing at the
  in-cluster `searxng` Service DNS name. This is the piece Home Assistant also
  needs (below).
- **open-webui** — `Deployment` + Service + **Ingress** at
  `openwebui.<ingress-ip>.sslip.io`, `OLLAMA_BASE_URL` still pointing at the
  Compose Ollama for now (we migrate Ollama in Phase 7), `ENABLE_WEB_SEARCH=false`
  and the MCP tool pointed at the in-cluster `searxng-mcp` Service. Its data
  (the `open-webui` Docker named volume, holding `webui.db`) migrates into a PVC.

**Migrate Open WebUI's data** without loss — copy the Docker volume into a PVC via
a helper pod:

```bash
# 1. Create the PVC (in the manifest). 2. Copy the old volume's contents in:
docker run --rm -v open-webui:/from -v /tmp/owui-export:/to alpine \
  sh -c 'cp -a /from/. /to/'
kubectl -n web run owui-import --image=alpine --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"c","image":"alpine","command":["sleep","3600"],
    "volumeMounts":[{"name":"d","mountPath":"/data"}]}],
    "volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"open-webui-data"}}]}}'
kubectl -n web cp /tmp/owui-export/. owui-import:/data/
kubectl -n web delete pod owui-import
```

**Give Home Assistant its endpoint to the moved MCP server.** HA stays on
Compose (host networking) and currently calls `http://127.0.0.1:9200/mcp`. Expose
`searxng-mcp` on a **host-restricted** LoadBalancer so only the host/HA can reach
it — *not* the whole LAN — preserving its private contract:

```yaml
# searxng-mcp Service — locked to this host only
apiVersion: v1
kind: Service
metadata:
  name: searxng-mcp
  namespace: web
  annotations:
    metallb.universe.org/loadBalancerIPs: <one-pool-ip-for-mcp>
spec:
  type: LoadBalancer
  loadBalancerSourceRanges:
    - 192.168.86.63/32     # the host itself only; HA reaches it here
  ports:
    - port: 9200
      targetPort: 9200
```

We do **not** open `9200` in ufw to the LAN. A Cilium NetworkPolicy (Phase 9)
will further restrict who can talk to it.

**Cutover (safe ordering):**

```bash
# 1. k8s versions are up and verified (below) while Compose still serves.
# 2. THEN stop the Compose copies to free host :8080 and loopback :8888/:9200:
cd /home/jacob/docker/ai-stack
# remove open-webui, searxng, searxng-mcp from docker-compose.yml, then:
docker compose up -d --remove-orphans     # --remove-orphans actually tears down removed services
git commit -am "Move web/search tier to k3s"   # keep the Compose repo honest
```

**Verify (before step 2 above):**

```bash
curl -k https://openwebui.<ingress-ip>.sslip.io          # loads
# In the UI: send a chat (hits Compose Ollama for now) and a web-search query
# (Open WebUI → searxng-mcp → searxng). Confirm HA voice search still works after
# repointing HA's MCP Client at the host-restricted :9200.
./scripts/verify-services.sh                              # remaining services green
```

If you must walk away mid-phase: leave the Compose copies **running** (skip step
2). Two copies of a stateless service is harmless; a stopped service with no
replacement is not.

**Family-safe checkpoint:** family voice/search intact throughout.

---

# Phase 7 — Ollama on the GPU (the flagship)

**Goal:** GPU-scheduled inference in k8s, with Home Assistant's voice Assist cut
over to it. This is the headline. It's also the most sensitive cutover, so it's a
**single-sitting, do-not-split** step.

First, make the GPU schedulable. k3s uses its own containerd; because
nvidia-container-toolkit is installed, k3s should auto-create an `nvidia`
RuntimeClass — confirm it:

```bash
kubectl get runtimeclass          # expect: nvidia
# if missing, configure k3s's containerd for the nvidia runtime, then restart k3s:
sudo nvidia-ctk runtime configure --runtime=containerd \
  --config=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
sudo systemctl restart k3s
```

Install the NVIDIA device plugin so the 3090 becomes an allocatable
`nvidia.com/gpu` resource, running under the nvidia runtime:

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm install nvdp nvdp/nvidia-device-plugin \
  -n nvidia-device-plugin --create-namespace \
  --set runtimeClassName=nvidia
kubectl describe node | grep nvidia.com/gpu    # capacity/allocatable: 1
```

Deploy Ollama (committed to `workloads/ollama/`), reusing the existing models
in-place via `hostPath` — **no copy**:

```yaml
# ollama Deployment (essentials)
spec:
  runtimeClassName: nvidia
  containers:
    - name: ollama
      image: ollama/ollama:0.31.2        # match the Compose pin
      env:
        - name: OLLAMA_HOST
          value: "0.0.0.0:11434"         # in-pod; exposure is controlled by the Service
      resources:
        limits:
          nvidia.com/gpu: 1
      volumeMounts:
        - name: models
          mountPath: /root/.ollama
  volumes:
    - name: models
      hostPath:
        path: /usr/share/ollama/.ollama  # the existing gemma4:31b / 26b store
        type: Directory
```

**Preserve Ollama's private contract.** Today it binds loopback only, no auth.
Home Assistant is on the same host, so expose the k8s Ollama on a
**host-restricted** LoadBalancer (like SearXNG-MCP), *not* the LAN:

```yaml
spec:
  type: LoadBalancer
  loadBalancerSourceRanges: ["192.168.86.63/32"]   # host/HA only
  ports: [{ port: 11434, targetPort: 11434 }]
```

**Parallel validation (do-not-split from here to cutover):** the Compose Ollama
still owns `127.0.0.1:11434`; the k8s Ollama has its own host-restricted IP.
**VRAM safety:** `gemma4:31b` is ~19 GB, so do **not** load it in both Ollamas at
once (2×19 > 24 GB). Validate with the Compose one idle:

```bash
# from the host, against the k8s Ollama IP:
curl http://<ollama-k8s-ip>:11434/api/generate \
  -d '{"model":"gemma4:31b","prompt":"say hi","stream":false}'
watch -n1 nvidia-smi        # confirm the k8s pod holds the model; VRAM within budget
```

**Cutover:** repoint Home Assistant's Ollama integration (and Open WebUI's
`OLLAMA_BASE_URL`) at the k8s Ollama IP, confirm voice Assist answers end to end,
*then* remove Ollama from `docker-compose.yml`:

```bash
cd /home/jacob/docker/ai-stack
# remove the `ollama:` service, then:
docker compose up -d --remove-orphans
git commit -am "Move Ollama to k3s (GPU-scheduled)"
```

If interrupted before removing the Compose Ollama, HA is still pointed at the
working Compose instance — nothing is lost. Only remove it once k8s is confirmed.

**The GPU is now shared** by k8s-Ollama and Compose-Plex with no hard partition.
That's fine — `gemma4:31b` (~19 GB) + Plex transcode fits in 24 GB — but it's a
*monitored budget*, not an isolation guarantee. Time-slicing/MPS is a future
exercise.

**Verify:**

```bash
kubectl describe node | grep -A2 'Allocated resources' | grep gpu   # gpu allocated
# HA: trigger a voice command; Plex: start a transcoding stream — both work.
```

**Family-safe checkpoint:** voice + Plex intact; only the inference backend moved.

---

# Phase 8 — Monitoring (kube-prometheus-stack)

**Goal:** observability in-cluster, still covering the services that stayed on
Compose.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
# Install via an Argo Application (values in workloads/monitoring/), with PVCs for
# Grafana + Prometheus and an ingress at grafana.<ingress-ip>.sslip.io.
```

Keep scraping the Compose-side exporters (node-exporter, cadvisor,
nvidia-gpu-exporter, plex-exporter) over the LAN via `additionalScrapeConfigs`,
and import your existing Grafana dashboards. Then retire the old Compose
monitoring project (frees `:3000`):

```bash
cd /home/jacob/docker/ai-stack/monitoring
docker compose down          # only after the k8s Grafana shows parity
```

**Verify:** `grafana.<ingress-ip>.sslip.io` shows both cluster metrics *and* the
host/GPU/Plex dashboards.

---

# Phase 9 — Harden, back up, document

**Goal:** make it maintainable — the "and *maintain* it" half of the point.

**etcd snapshots (cluster-level DR):**

```bash
sudo k3s etcd-snapshot save --name pre-change
# schedule + retention are configurable; snapshots land in
# /var/lib/rancher/k3s/server/db/snapshots
```

**GitOps rollback drill:** revert a commit and watch Argo reconcile back — no
imperative commands.

**Zero-trust east-west (Cilium NetworkPolicies):** apply default-deny per
namespace, then allow only the flows that must exist (web → searxng-mcp → searxng,
web → ollama, prometheus → targets). Prove a denied flow is actually dropped:

```bash
cilium hubble port-forward &
hubble observe --verdict DROPPED       # watch an unauthorized flow get dropped
```

**Firewall re-audit** (from your laptop):

```bash
nmap -p 22,80,443,6443,10250,2379,3000,8080 192.168.86.63
# expect open: 22, 80, 443 (and only the deliberately-chosen service ports).
# expect closed/filtered: 6443, 10250, 2379.
```

**Secret rotation drill:** re-seal a secret, commit, let Argo sync — proving the
Sealed Secrets loop works before you need it in anger.

**Automation + docs:** add Dependabot/Renovate for the k8s repo's charts/images
(mirroring this repo's auto-merge policy: patch/minor auto, majors manual); add a
`verify-cluster.sh`; update both READMEs.

---

# The end state

**On k3s:** Cilium (eBPF, kube-proxy replacement) · MetalLB · ingress-nginx +
cert-manager · Argo CD + Sealed Secrets · Open WebUI · SearXNG · SearXNG-MCP ·
**Ollama (GPU)** · kube-prometheus-stack.

**On Docker Compose (by design):** Home Assistant · Piper · Whisper · Plex.

**The wiring across the boundary:** Home Assistant → k8s Ollama and k8s
SearXNG-MCP over host-restricted endpoints; k8s Prometheus → Compose exporters
over the LAN; the 3090 shared between k8s-Ollama and Compose-Plex on a monitored
VRAM budget.

**The résumé sentence, every word true:** *a GitOps-driven, single-node k3s
cluster with an eBPF dataplane and kube-proxy replacement, MetalLB load
balancing, ingress with automated TLS, GPU-scheduled LLM inference, a Prometheus/
Grafana stack, zero-trust NetworkPolicies, sealed secrets, and etcd-snapshot
disaster recovery — built alongside a family smart-home/media stack that never
went down.*
