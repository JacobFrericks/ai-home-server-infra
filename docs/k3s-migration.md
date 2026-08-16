# Migrating a home server from Docker Compose to k3s

A working single-node Kubernetes migration of a live home server — Open WebUI, Ollama,
ComfyUI, SearXNG, three MCP servers, and a full Prometheus/Grafana/Loki stack — carried out
without breaking the household services that depend on them.

**Result: 20 containers → 4.** Docker Compose now runs only Home Assistant, Piper, Whisper and
Plex, which stay on Compose permanently by design. Everything else runs on k3s, deployed by
Argo CD from git.

This document is the **public, condensed** version. It deliberately contains no addresses,
hostnames, credentials or topology — only what generalises.

---

## The stack

| Layer | Choice | Why not the default |
|---|---|---|
| Distribution | **k3s**, embedded etcd | SQLite gives no `etcd-snapshot`; snapshots and a restore drill were required |
| CNI | **Cilium**, `kubeProxyReplacement` | replaces flannel *and* kube-proxy; eBPF dataplane |
| LoadBalancer | **MetalLB**, L2 | bare metal has no cloud LB; ServiceLB is a node-port shim |
| Ingress | **ingress-nginx** | replaces bundled Traefik; more widely transferable |
| Certificates | **cert-manager**, self-signed internal CA | no public domain, and no inbound path is a feature |
| GitOps | **Argo CD**, app-of-apps | pull-based, so no inbound hole for CI/CD |
| Secrets | **Sealed Secrets** | only ciphertext is ever committed |
| Images | **self-hosted in-cluster registry** | containerd cannot see the Docker daemon's images |
| GPU | **NVIDIA device plugin + time-slicing** | two workloads, one consumer-class card |

Everything is version-pinned. Charts installed with an explicit `--version`; workloads
referenced by **image digest**, not tag, so what runs changes only through a reviewed commit.

---

## The method: parallel, then cut over

Every service was deployed into the cluster **alongside** its running Compose copy, verified
there, and only then removed from Compose. Nothing was deleted until its replacement was
proven.

Three cutovers, each gated on a full functional verification suite:

1. **Web tier** — Open WebUI, SearXNG, and two MCP servers
2. **GPU tier** — Ollama, ComfyUI, and an MCP shim
3. **Monitoring** — the entire Prometheus/Grafana/Loki project

The verification suite is the load-bearing part. It exercises features end to end — an actual
chat completion, an actual search, an actual voice round-trip, an actual image generated *and
rendered on the mobile client* — rather than asserting that pods are `Running`.

That distinction turned out to matter more than any other decision in the project.

---

## What actually went wrong

Fourteen documented failures. These six generalise beyond this stack.

### 1. Deleting a component deletes behaviours you never chose

The plan's primary access control for a service with **no authentication** was
`loadBalancerSourceRanges`. That enforcement is conventionally **kube-proxy's** — and the
cluster runs `--disable-kube-proxy`.

The control did not exist. It was replaced with ClusterIP-only exposure, which is stronger:
there is no LAN surface to filter rather than a filtered one.

> **Write down what each `--disable` actually removes.**

### 2. eBPF exposure is invisible to your usual instruments

An internal registry was deployed with a host port bound to loopback. Three checks, in order:

- `ss` showed **no listener** — Cilium implements host ports in eBPF, not as a socket
- a request **from another machine** returned HTTP 401 — it was published to the network
- a firewall `deny` rule **did nothing** — eBPF runs before netfilter

An unauthenticated registry that the cluster pulls executable images from, reachable by
anything on the network. The only thing preventing that was basic auth added over the author's
objection, on the strength of a threat model dismissed as theoretical.

> **Verify every exposure from a second machine, with a real request.** A socket table and a
> firewall config are not verification. And keep the control you think is ceremony.

### 3. Pod health is not user-facing health

A default-deny NetworkPolicy took the primary web service off the network. **Every pod stayed
`1/1 Ready` throughout**, because readiness probes originate from the node — an identity the
policy allowed — while real clients arrived as a different identity entirely.

Cilium preserves the client IP through `externalIPs` rather than translating it, so LAN clients
are `world`, not `host`. That assumption was written into the policy's own comment as fact,
untested.

> **Kubernetes can be entirely satisfied while nothing works.** Test policy from a real client
> device.

### 4. A check that never asserts on coverage will lie to you

Log shipping silently stopped for **every migrated service**. The collector discovered sources
through the Docker socket; once the workloads became pods, they were no longer Docker
containers and there was simply nothing to find.

The log store was healthy. The datasource was healthy. The collector was running with no
errors. The verification suite passed — because it asked *"is the datasource up?"*

Every indicator was green **and correct**. Only coverage had collapsed, and nothing measured
coverage. The same pattern was then found in dashboard queries and, worst, in the alert rule
that pages a human.

> **A check that asserts on liveness but never on coverage will report a fully-functioning
> pipeline that is carrying nothing.**

### 5. Migrating a database migrates the old topology with it

An application that persists its own configuration ignored the environment variables in its
new manifest — because it seeds them only on first initialisation, and the migrated database
still contained the previous deployment's addresses.

The symptom was not an error. It was an **empty list** in the UI, with a manifest that read
perfectly. This recurred three times in one migration.

> **For anything that stores its own config, the database outranks the manifest.** Enumerate
> and re-assert every stored endpoint after a move — as a re-runnable script, because you will
> need it more than once.

### 6. Kubernetes has host-level costs no manifest expresses

A metrics exporter that had run for months began crash-looping immediately after moving into
the cluster:

```
inotify_init: too many open files
```

Nothing about the exporter changed. The control plane, the CNI, the GitOps controller and
every other controller now shared the same per-user inotify budget, and the kernel default no
longer covered it.

> This class of problem surfaces as an **unrelated-looking crash in whichever component asks
> for the last available resource**. It was luck that the victim was a metrics exporter and
> not the datastore.

---

## Things that went better than expected

**An accurate calculation can still support a false prediction.** The plan asserted that a
large language model and an image model could not co-reside on one consumer GPU, and built an
operational discipline around that. Tested directly with the model resident and under 2 GB
free, the image generated anyway — the image tool offloaded parts of its pipeline to system
RAM. Every number was right; the conclusion assumed the only response to running out was
failure. Mature software degrades instead.

**Monitoring improved rather than merely moving.** Scrape targets nearly doubled, because the
cluster itself became visible where it previously was not.

**Disaster recovery was proven, not assumed.** The restore drill was designed so a no-op could
not pass: snapshot, create a marker resource *after* it, restore, and require the marker to be
gone. It also demonstrated that the container runtime and the cluster are genuinely
independent on a shared host — the property the whole parallel-then-cutover strategy rests on.

---

## Security posture

- Control-plane, datastore and internal service ports verified **unreachable** from the
  network, using real requests **with a positive control** in the same run — without one, "all
  closed" is indistinguishable from a broken test
- Secrets **encrypted at rest** from first boot; this cannot be retrofitted without migrating
  every secret, and matters because snapshots would otherwise be recurring plaintext dumps
- Only ciphertext committed; the decryption key never leaves the cluster
- GitOps token verified **read-only by testing a write**, not by trusting the setting
- Default-deny east-west policy, with a denial **observed in the dataplane** rather than
  inferred
- Host-reading exporters isolated in their own namespace with a documented Pod Security
  exemption, so an elevated permission is visible rather than ambient

**Known and carried deliberately:** no egress policy yet; a privileged exporter whose
justifying metric does not currently work; and self-hosted images that no dependency bot
watches.

> ⚠️ **A note on port scanning.** A SYN-only scan disagreed with a real request about the same
> port on this host — reporting one service closed while it was serving. Audit with the
> protocol you actually care about.

---

## Would I do it again

For the household: neutral. The same services work the same way, which was the requirement.

For the operator: yes — but the value is not the finished cluster. It is that a live system
with real users produces failures a tutorial cannot, because a tutorial's author fixed them
before you arrived. Half of the findings above are corrections to confident, written-down
assumptions, and those are the ones worth having.

The most useful sentence to come out of it:

> **A check that asserts on liveness but never on coverage will report a fully-functioning
> pipeline that is carrying nothing.**

---

*A detailed chapter-by-chapter walkthrough, with full command output and every debug journal,
is maintained privately — it contains real transcripts and topology.*
