# Migrating a home server from Docker Compose to k3s

A working single-node Kubernetes migration of a live home server — Open WebUI, Ollama,
ComfyUI, SearXNG, three MCP servers, and a full Prometheus/Grafana/Loki stack — carried out
without breaking the household services that depend on them.

**Result: 20 containers → 4.** Docker Compose now runs only Home Assistant, Piper, Whisper and
Plex, which stay on Compose permanently by design. Everything else runs on k3s, deployed by
Argo CD from git.

This document is the **public, condensed** version. It deliberately contains no addresses,
hostnames, credentials or topology — only what generalises.

*Updated 2026-08-31: the two weeks after the migration produced four more failures worth
having, and a claim in the original version of this document that turned out to be false. Both
are below.*

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
| Admission | **built-in policy engine**, not a webhook | on one node, a webhook is a new single point of failure — see failure 9 |
| Backups | **content-addressed snapshots**, mirrored locally and copied to cold object storage | a RAID mirror replicates a deletion; it is not a backup |

Every platform chart is a GitOps `Application` with a pinned version, rather than a `helm
install` in someone's shell history — so a rebuild is a `git apply`, not a memory exercise.

### The version-pinning claim, and what happened when it was measured

The first version of this document said:

> Workloads referenced by **image digest**, not tag, so what runs changes only through a
> reviewed commit.

That was the intent. Measured two weeks later, during an audit of where the running code
actually came from: **3 of 21 image references carried a digest.** The rest were tags —
several from personal accounts with a single maintainer, which are the softest link in any
image supply chain.

Nobody had lied. It was written down at a moment when it was nearly true and never measured
again. **A convention that nothing enforces decays back to convenience, and the document goes
on describing the version you meant.**

It is true now, and it is true because something checks: every image in both repositories is
`repo:tag@sha256:...`, and a CI script fails the build if one is not. The tag stays as
human-readable provenance; the digest is what resolves. That script also fails if it finds
*zero* images to check — a pass that can happen while checking nothing eventually will.

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

### 7. A required pull request with zero approvals is not a gate

Both repositories required changes to `main` to arrive via a pull request. Neither required an
approval, and neither required a status check to pass.

A rule satisfied by "it was a pull request" is satisfied by a pull request that one identity
opens and merges by itself, in three API calls. And `main` deploys itself — a scheduled job
pulls it and runs it, and a GitOps controller syncs it within minutes.

So a single write-capable credential meant arbitrary code on the host, with no human in the
loop and nothing to review it. Not through a clever chain: through the intended path, working
exactly as designed. The existing CI — secret scanning, manifest validation — ran on every
pull request and blocked nothing, because it was never required.

> **An optional green check is worth about as much as a red one nobody reads.** Requiring a
> check and an approval was the single largest risk reduction in the project, and it was two
> settings.

**A trap that comes with it:** you cannot approve your own pull request. On a repository with
one maintainer, requiring an approval makes your own changes permanently unmergeable — unless
the work is pushed by a separate bot identity that the human then approves. That is the
separation of duties the control was asking for, and it only becomes visible once the control
is switched on.

### 8. A fix can report success and change nothing

Several namespaces were missing a security label. The orchestration tool has an option that
looks purpose-built for setting it. The option was added, the change was reviewed and merged,
and the sync reported:

```
sync: Synced      health: Healthy
op:   Succeeded   "successfully synced (no more tasks)"
```

The label was not applied. Not partially — not at all.

The option only governs a namespace the tool **creates itself**. These namespaces predated it;
they had been created by hand long before and adopted later, so the tool had never held them.
Rather than say so, it managed nothing and reported success.

Forcing a full manual sync did not help. What found it was **counting**: asking how many of
the 46 objects the application managed were namespaces. The answer was zero.

> **This is worse than an error, because an error stops you.** It produced a green
> application, a success message, and the exact gap it was meant to close — now wearing a
> badge that said it was fixed.
>
> The operational form of failure 4, arrived at from a completely different direction, two
> weeks later, by the person who wrote failure 4: **after a change reports success, read the
> object back.**

### 9. On one node, a webhook is a new single point of failure

The obvious way to enforce policy is an admission webhook, and the popular tools are all
webhooks. On a single-node cluster that is a loaded gun: a webhook that becomes unhealthy
either stops enforcing silently, or starts rejecting API calls — including the ones you would
use to remove it. There is no second node to fix it from.

The alternative is the policy engine built into the API server itself. Rules are expressions,
evaluated in process. No extra pods, no extra images to keep patched, and nothing that can
fail *between* the client and the API server. What it gives up is mutation and a reporting UI.

> **Adding a component to protect a system also adds a component that can fail.** On a large
> cluster with an on-call rota that trade is usually worth it. On one machine it is worth
> asking whether the guard is now the most fragile thing in the room.

**One test-design note**, because it nearly fooled me. The obvious way to prove a pod policy
works is to submit a pod that violates it — but the *built-in* namespace-level control rejects
it first, so that test passes identically with every custom policy deleted. Testing the
custom layer meant using a Deployment, which the built-in control does not evaluate at all.
**Read the rejection message and check which layer answered.** And test that the documented
exemption is still *accepted*: a policy that denies everything is not a working policy, it is
an outage waiting for the next upgrade.

### 10. A backup that cannot tell you it failed

The nightly backup broke and was not noticed for a day.

The chain has no exotic links. The host rebooted itself for unattended upgrades into a state
with no network, so the cluster never started. A helper asked the cluster for a path and got
empty output — successfully. That empty output was parsed as structured data, raised an
exception, and under `set -e` killed the entire run **before it reached the several hundred
gigabytes sitting on a perfectly healthy local disk that needed no cluster at all.**

The alert that would have caught it was written, correct, and sitting in an unmerged pull
request — and the alerting engine it was written for was not the one in use, so it could not
have been delivered anyway.

> **Build the notification path before the thing that needs it.** A backup system that cannot
> report its own failure looked healthy for a full day while doing nothing.

The fix has a detail worth stealing: when the cluster is unreachable, the job now backs up
what it can, tags the snapshot `incomplete`, **deliberately withholds the freshness metric**,
and exits non-zero. Publishing a fresh timestamp for a partial backup would make the
monitoring actively lie, which is worse than publishing nothing.

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

*That covered cluster **state**. Application **data** followed two weeks later: a local mirror
with nightly content-addressed snapshots, and a second copy in cold object storage — written
as an independent repository rather than a mirror, so a mistaken prune at home cannot
propagate to it.* The drill that matters was pulling the secrets-decryption key back out of
the offsite copy and comparing it byte for byte against the live one. **A restore path that
has never been walked is a plan, not a backup** — and a RAID mirror is neither: it replicates
a deletion faithfully, instantly, to both disks.

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

Added after the migration, prompted by the audit in failure 7:

- **`main` requires a passing check *and* an approval** on both repositories, with no bypass
  actors — which also turned the existing CI from advisory into blocking
- **Every image pinned by digest**, in both repositories, enforced by a CI check that fails on
  a tag and fails on an empty match set
- **Scoped GitOps projects** instead of one that permitted any resource in any namespace from
  any source — the tier holding the ordinary workloads is allowed no cluster-wide permissions
  at all
- **Admission policies enforced in the API server**, verified by attempting each thing they
  forbid and confirming the rejection came from the intended layer, plus a **negative control**
  confirming the one documented exemption is still permitted
- **Every namespace declares a pod security level**, including the ones that need a permissive
  one — with the reason written next to it, because an absent label reads as an oversight and
  nobody can tell an oversight from a decision
- **Backups local and offsite**, with the decryption key restored from cold storage and
  byte-compared against the live one

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

And the thing the following two weeks added, which is less quotable and more use: **knowing
that sentence does not protect you from it.** Failures 7, 8 and 10 were all found by counting
something, not by looking at a status, and all three were written by someone who had already
written the sentence down in bold. The habit that actually works is narrower — *after a change
reports success, read the object back* — and it has to be a habit, because the reasoning
never fires on its own.

---

*A detailed chapter-by-chapter walkthrough, with full command output and every debug journal,
is maintained privately — it contains real transcripts and topology.*
