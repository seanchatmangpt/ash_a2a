# ash_a2a real distributed-agent swarm test (kind + act)

## What this proves

A real, falsifiable claim: `AshA2A.Agent` GenServers running on genuinely
separate Kubernetes pods (real network-isolated Linux containers, not
`:peer`-spawned same-machine BEAM processes like
`test/ash_a2a/distributed_node_loss_test.exs` already exercises) can
discover each other via real DNS and dispatch a real cross-pod A2A
message, receiving back a reply that names the actual remote node that
executed it -- not a same-node stand-in.

`swarm/lib/swarm_node/probe.ex`'s `SwarmNode.Probe.run/0` is the whole
test: dispatch `SwarmNode.EchoAgent`'s `:ping` skill against every real
peer node `Node.list/0` reports, and verify at least one reply's `node`
field is a real peer, not `node()` itself.

## Why a new `swarm/` app instead of extending ash_a2a's own release

`ash_a2a` is a pure library (`mix.exs`'s own `description/0`: "A
Spark.Dsl.Extension that exposes Ash.Resource/Ash.Domain actions...").
It declares `mod: {AshA2A.Application, []}` so any host app depending on
it gets `A2A.AgentSupervisor` for free, but it deliberately carries no
release config, no Dockerfile, and no runtime host of its own -- adding
one directly to `ash_a2a` would blur that boundary for every other real
consumer of this library. `swarm/` is a small, separate, real Mix
project (`swarm/mix.exs`) that depends on `ash_a2a` via a real `path:`
dependency, exactly the way any other host app would.

## Real components (all real, no test doubles)

- **`swarm/lib/swarm_node/echo.ex`** -- one real `Ash.Resource` (`:ping`
  generic action) + domain, `extensions: [AshA2A]`.
- **`swarm/lib/swarm_node/echo_agent.ex`** -- `use AshA2A.Agent,
  resource_or_domain: SwarmNode.Echo`, the exact real macro every other
  consumer in this repo's own `test/support/*.ex` fixtures uses.
- **`swarm/lib/swarm_node/application.ex`** -- starts `libcluster`'s
  `Cluster.Supervisor` (real cluster membership); `ash_a2a`'s own
  `AshA2A.Application` (started automatically as a dependency) owns
  `A2A.AgentSupervisor`/the receipt store/OCEL forwarder.
- **`swarm/lib/swarm_node/probe.ex`** -- the real cross-pod dispatch
  probe described above.
- **`swarm/Dockerfile`** -- multi-stage build, `hexpm/elixir:1.19.5-erlang-27.2.4-debian-bookworm-20260824-slim`
  (the date-pinned tag actually used by the Dockerfile; this repo's own real
  `.tool-versions` pins the same Elixir/OTP pair) → `debian:bookworm-slim`
  runtime, non-root UID 10001.
- **`k8s/*.yaml`** -- Namespace (Pod Security Admission `restricted`),
  ResourceQuota, ServiceAccount, headless Service (DNS-based peer
  discovery), Deployment (3 replicas).
- **`k8s/deploy.sh`** -- builds the image, creates/reuses a `kind`
  cluster, loads the image, applies every manifest, waits for rollout,
  execs the real probe, and greps its real JSON output for
  `"swarm_dispatch_verified":true`.
- **`k8s/verify_network_isolation.sh`** -- real, permanent NetworkPolicy
  egress-isolation regression check (positive+negative control), run
  automatically by `k8s/deploy.sh` after the swarm-dispatch probe and
  before the resilience/chaos test -- see the dedicated section below.

## Security posture: grounded in `~/ggen-marketplace/packs/kubernetes-workload-pack`

Per the user's own standing instruction to prefer `ggen-marketplace`
packs as source of truth over ad hoc research: `k8s/deployment.yaml`'s
security posture is copied field-for-field from that pack's real,
NIST-SP-800-53-Rev.5/NIST-SP-800-190/CIS-Kubernetes-Benchmark-mapped
`examples/high-assurance-workload/facts.ttl` (see that pack's
`examples/control-mapping/control-map.md` for the full control matrix and
citations) -- non-root execution, explicit `runAsUser`/`runAsGroup`/
`fsGroup`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation:
false`, `capabilities.drop: ["ALL"]`, `readOnlyRootFilesystem: true`,
explicit resource requests/limits, a dedicated `ServiceAccount`. This
workload additionally sets `automountServiceAccountToken: false`
(SEC-ID-002) with full justification, not just copied: libcluster's
`Cluster.Strategy.Kubernetes.DNS` strategy talks to plain DNS, never the
Kubernetes API server, so this workload needs zero RBAC.

**Real, disclosed extension made to that pack this session** (not silent
scope creep): the pack's `k8s:Workload` vocabulary had no way to express
a headless Service (`spec.clusterIP: None`), which real DNS-based BEAM
clustering requires. Added `k8s:serviceClusterIP` (optional, additive,
regression-verified against the pack's own existing fixtures) --
`~/ggen-marketplace/packs/kubernetes-workload-pack`, commit
`a24193705`. **Not used to render this manifest, though** -- see the next
section.

## Real, disclosed limitation: manifests are hand-authored, not `ggen sync run`

The `ggen` CLI on this machine (`~/.local/bin/ggen`, a Docker-wrapped
binary: `docker run --rm -v "$PWD:/workspace" -w /workspace
ghcr.io/seanchatmangpt/ggen-ecosystem:v26.8.28 ggen "$@"`) bind-mounts
only the current working directory. A pack fixture's own `ggen.toml`
`path:../..` pack reference (climbing to the pack root two directories
up) only resolves when the pack root itself is mounted -- e.g. `docker
run -v <pack-root>:/workspace -w /workspace/examples/<name> ... ggen
sync run`, confirmed working this session by re-rendering
`high-assurance-workload` that way. Running `ggen` with cwd = the
example directory directly (matching that pack's own
`qualification/orthogonal_scan.sh`) does not work on this machine today.

Since `ash_a2a` (this repo) and `~/ggen-marketplace` are two separate
directories with no common mounted root short of the whole home
directory, and this was a two-file, hand-verifiable manifest (not a
large generated surface), `k8s/*.yaml` here are hand-authored directly
from the pack's real field values rather than blocked on resolving that
CLI limitation in this same session. The limitation itself is real and
disclosed (not fixed) -- a future session wanting `ggen sync run` for
this manifest should mount a common root (e.g. the whole home directory,
or vendor a copy of the pack under this repo) rather than assume the
bare `cd <dir> && ggen sync run` invocation this pack's own
`qualification/orthogonal_scan.sh` uses will work unmodified.

## Network isolation verification is now automated, not a manual one-off

Earlier evidence-gathering for this workload (see
`docs/archive/reports/AIRGAP_READINESS_REPORT.md`'s "1. Egress falsifier" and
`docs/archive/reports/ENTERPRISE_READINESS_REPORT.md`'s "Correction (re-derived from a
real falsifier, not assumed)") confirmed egress isolation by hand:
delete `k8s/network-policy.yaml`, confirm a real
`:gen_tcp.connect/4` to a public IP succeeds (positive control),
re-apply the policy, confirm the identical call now times out (negative
control). That was a real result, but a manual one -- nothing re-ran it
on the next deploy, so a future regression (someone loosens or deletes
the egress-deny rule) would have gone unnoticed until someone thought to
repeat the manual steps.

**`k8s/verify_network_isolation.sh` closes that gap permanently.** It
automates the exact same positive/negative control against a real
running pod and exits non-zero if either control fails to produce its
expected result (egress succeeds with the policy removed; egress times
out with the policy re-applied). `k8s/deploy.sh` now runs it
automatically on every deploy, right after the swarm-dispatch probe and
before the resilience/chaos test -- this is a standing regression check
now, not a one-off manual finding that could go stale silently.

Run it standalone against an already-deployed cluster:

    bash k8s/verify_network_isolation.sh [namespace] [app-label]
    # defaults: namespace=ash-a2a-swarm, app-label=ash-a2a-swarm

## Running it

Two prerequisites worth knowing before the one-liner:

- **The cookie Secret is created by `deploy.sh`, not by any manifest.**
  `k8s/deployment.yaml` references a Secret named `ash-a2a-swarm-cookie`
  that no YAML file defines — `deploy.sh` (and `swarm-test.yml`) generate
  it with `openssl rand -hex 32`. A plain `kubectl apply -f k8s/` without
  it leaves pods in `CreateContainerConfigError`.
- **There are no HTTP liveness/readiness probes, by design.** The swarm
  nodes expose no HTTP server; the workload's health signal is the
  `bin/swarm_node rpc` exec probe (and only the distribution ports
  4369/9000 could be probed at the transport level). The deployment
  carries no liveness/readiness/startup probes as deployed.

    bash k8s/deploy.sh                    # creates/reuses a kind cluster named ash-a2a-swarm,
                                           # deploys, probes cross-pod dispatch, verifies real
                                           # NetworkPolicy egress isolation (permanent regression
                                           # check), then runs a real pod-kill resilience test

Or via `act` (this new workflow never needs `erlef/setup-beam` on the
*host* runner -- all Elixir/OTP work happens inside the Docker build
step, sidestepping this repo's own previously-disclosed
`bin/ci-local.sh` limitation, which was specifically about installing
OTP directly on an act runner image):

    act workflow_dispatch -W .github/workflows/swarm-test.yml \
      --container-daemon-socket unix:///var/run/docker.sock

(`--container-daemon-socket unix:///var/run/docker.sock` is required on
this class of host -- see the real, disclosed `act` findings below;
without it, or with the macOS-side forwarding socket path, the runner
container fails to start at all.)

See `docs/archive/reports/ENTERPRISE_READINESS_REPORT.md` (security posture + resilience
evidence) and `docs/archive/reports/AIRGAP_READINESS_REPORT.md` (zero-outbound-
connectivity evidence, with an honest correction of this file's own
earlier NetworkPolicy-enforcement claim -- see that report's "Correction"
section) for real, reproducible evidence gathered against this exact
manifest set.

### Real, disclosed `act` findings (this session, run on this machine)

Running this workflow through `act` (not just `ci.yml`) surfaced two
real, distinct limitations, neither a defect in the swarm test itself --
both confirmed by directly `docker exec`-ing into the still-running
runner container after the job reported failure and re-running the
exact same real commands by hand:

1. **Docker-socket bind-mount path.** `act`'s default behavior of
   bind-mounting `$DOCKER_HOST`'s own socket path into the runner
   container fails on this host's Colima setup with `mkdir ...: operation
   not supported`, because that path (`~/.colima/default/docker.sock`) is
   a macOS-side forwarding proxy, not a real path from the Docker
   daemon's own (Linux VM-side) filesystem perspective. Passing
   `--container-daemon-socket -` (disable entirely) instead breaks the
   *opposite* way: no docker.sock is mounted at all, so any step needing
   Docker (this workflow's own `docker build`) fails immediately with
   `connect: no such file or directory`. The real fix is
   `--container-daemon-socket unix:///var/run/docker.sock` -- the
   daemon's own real, internal socket path (confirmed via `colima ssh --
   ls -la /var/run/docker.sock`), valid as a bind-mount source because
   it's already local to the daemon's own host, not proxied from macOS.
2. **A real, narrower `act`-runner instability under forced amd64
   emulation** (`.actrc`'s own `--container-architecture linux/amd64`,
   needed because `catthehacker/ubuntu:act-latest` ships no arm64
   variant): with the socket fix above, the full job ran for real --
   image build (3m40s), kind cluster creation, image load, every
   manifest apply, and Deployment rollout all **succeeded** -- but the
   "Real cross-pod swarm-dispatch probe" step's multi-line bash (an
   array index, a `sleep`, a `kubectl exec`) crashed with a bare
   `exitcode '139'` (SIGSEGV) and zero captured output; the next step
   (kubeconform, a separately-built Go binary) crashed the same way with
   an explicit `unexpected fault address`. Both are consistent with
   genuine QEMU/amd64-emulation instability for certain subprocess/shell
   patterns on this Apple-Silicon host, not a defect in the workflow's
   own commands: the exact same real `kubectl exec ... swarm_node rpc
   "SwarmNode.Probe.run()"` command, run by hand against the still-live
   runner container and its still-live kind cluster right after the
   crash, returned the real, correct
   `{"swarm_dispatch_verified":true,...}` result -- and a real,
   additional pod-kill performed the same way reconfirmed the resilience
   test too. The underlying capability is proven; `act`'s own shell
   execution under this host's forced emulation is the disclosed, narrow
   limitation, matching this repo's own established pattern
   (`bin/ci-local.sh`'s comments) of treating real hosted GitHub Actions
   as the authoritative signal on this class of machine rather than
   assuming `act` reproduces it perfectly.

## Digest-pinning readiness (prep only -- not yet executed)

Real gap disclosed in `docs/archive/reports/ENTERPRISE_READINESS_REPORT.md`'s caveat
(SEC-IMG-001) and `~/ggen-marketplace/packs/kubernetes-workload-pack`'s
`control-map.md` SEC-COSIGN-001 row: this workload's image has never
been pushed to a real registry, so there is no real digest to pin
`k8s/deployment.yaml`'s `image:` field to, and running `cosign verify`
against a non-pushed image would fabricate a result. This section
documents the exact real command sequence to close that gap for real,
in a later session -- **nothing below has been run this session**.
`k8s/deployment.yaml`'s `image:` field now carries a clearly-commented
`PLACEHOLDER` value (see that file), not a real digest. Do not read
this section as digest-pinning being done; it is prep only, real
execution pending.

### Exact real steps (to run for real, not simulated)

1. **Start a real local OCI registry** (Docker's own reference registry
   image, not a mock):

       docker run -d --restart=always -p 5000:5000 --name ash-a2a-local-registry registry:2

2. **Tag the already-built real local image for that registry** (reuses
   the exact image `k8s/deploy.sh` already builds -- no rebuild needed):

       docker tag ash-a2a-swarm-node:local localhost:5000/ash-a2a-swarm-node:local

3. **Push it for real:**

       docker push localhost:5000/ash-a2a-swarm-node:local

4. **Capture the real digest** the registry assigned (do not hand-write
   one):

       docker inspect --format='{{index .RepoDigests 0}}' localhost:5000/ash-a2a-swarm-node:local

   This prints `localhost:5000/ash-a2a-swarm-node@sha256:<REAL_DIGEST>`.

5. **Generate a real cosign keypair, once** (interactive password
   prompt -- never script the password, never commit `cosign.key`):

       cosign generate-key-pair

6. **Sign the real, pushed, digest-referenced image:**

       cosign sign --key cosign.key \
         --allow-http-registry=true \
         --tlog-upload=false --use-signing-config=false \
         localhost:5000/ash-a2a-swarm-node@sha256:<REAL_DIGEST>

7. **Verify the real signature** (the actual falsifiable check --
   SEC-COSIGN-001 only closes if this exits 0 against the real pushed
   digest, never a placeholder):

       cosign verify --key cosign.pub \
         --allow-http-registry=true \
         --insecure-ignore-tlog=true \
         localhost:5000/ash-a2a-swarm-node@sha256:<REAL_DIGEST>

   **Why the extra flags (confirmed against the real, installed
   `cosign v3.1.3` -- `cosign sign --help` / `cosign verify --help` --
   plain `cosign sign`/`cosign verify` against `localhost:5000` fails
   without them):**

   - `--allow-http-registry=true` (`sign` and `verify`) -- "whether to
     allow using HTTP protocol while connecting to registries." The
     local registry (`registry:2`, step 1) speaks plain HTTP on
     `localhost:5000`, no TLS at all -- distinct from
     `--allow-insecure-registry`, which is for HTTPS registries with
     *expired or self-signed* certs. Without this flag `cosign` still
     probes `https://localhost:5000/v2/` first (and can succeed via an
     unrelated cert-less HTTP fallback purely because the host is
     `localhost`), but the flag is the documented, explicit way to
     declare HTTP intent rather than rely on that undocumented
     loopback special-case.
   - `--tlog-upload=false` (`sign` only) -- skip uploading the
     signature to the Rekor transparency log. A local `registry:2`
     instance has no real Rekor deployment reachable from it, so a
     tlog upload would either hang or hit the public Sigstore Rekor
     for an image nobody can look up there. **Real, version-specific
     wrinkle found live on this host's installed `cosign v3.1.3`:**
     `--tlog-upload` is deprecated as of cosign v3.0.3 ("Deprecate
     tlog-upload flag") and, run alone, now errors outright --
     `--tlog-upload=false is not supported with --signing-config or
     --use-signing-config` -- because `cosign sign` defaults to
     `--use-signing-config=true` (a TUF-provided signing config that
     still names a tlog service). It must be paired with
     `--use-signing-config=false` below; confirmed live by running both
     commands against an unreachable local port and reading the real
     error text (flag-parse errors disappeared, only a real "connection
     refused" network error remained).
   - `--use-signing-config=false` (`sign` only) -- disables cosign's
     default TUF-provided signing config so `--tlog-upload=false` above
     is actually honored instead of rejected. (The non-deprecated
     replacement path is a hand-built `--signing-config` file with no
     transparency-log service entries; this recipe uses the simpler,
     still-functional deprecated flag pair since it is a one-off local
     test registry, not a production signing pipeline.)
   - `--insecure-ignore-tlog=true` (`verify` only) -- the verify-side
     counterpart: don't require or check transparency-log inclusion,
     since step 6 never uploaded to one. `cosign verify` prints its own
     real warning when this is set ("Skipping tlog verification is an
     insecure practice...") -- expected and correct for this local,
     non-public registry, not a sign of misconfiguration.

8. **Substitute the real digest into `k8s/deployment.yaml`**, replacing
   the `PLACEHOLDER` `image:` line (see the comment block already in
   place there) with:

       image: localhost:5000/ash-a2a-swarm-node@sha256:<REAL_DIGEST>

   `imagePullPolicy: Never` stays unchanged -- load the same
   digest-referenced image into `kind` directly rather than wiring a
   containerd registry-mirror config (kind's own
   [local-registry pattern](https://kind.sigs.k8s.io/docs/user/local-registry/))
   into every node, which is real extra surface this ephemeral test
   workload doesn't need:

       kind load docker-image localhost:5000/ash-a2a-swarm-node@sha256:<REAL_DIGEST> --name ash-a2a-swarm

9. **Re-run `bash k8s/deploy.sh`** and re-confirm the same real
   `"swarm_dispatch_verified":true` probe result against the now
   digest-pinned + cosign-verified image, then re-run `kyverno apply`
   (the one prior failing control in
   `docs/archive/reports/ENTERPRISE_READINESS_REPORT.md`'s scanner table) to confirm the
   digest-pinning control now passes for real.

### Why this is prep, not execution

None of the 9 steps above have been run this session. `k8s/deployment.yaml`
still deploys real, verified, working swarm pods today via the unpinned
`ash-a2a-swarm-node:local` tag -- this section only makes the next real
step ready to execute (exact commands, no ambiguity, no placeholder
digest hand-waved into a manifest), matching this repo's own standing
discipline of never fabricating a Cosign result against an image that
was never really pushed.

## Cleanup

    kind delete cluster --name ash-a2a-swarm

## Explicitly out of scope this pass (disclosed, matching this pack's own backlog discipline)

- RBAC Role/RoleBinding beyond the ServiceAccount itself (none needed --
  see `docs/archive/reports/ENTERPRISE_READINESS_REPORT.md`), HorizontalPodAutoscaler,
  PodDisruptionBudget -- same NAMESPACE_CONTROL/CLUSTER_CONTROL boundary
  `kubernetes-workload-pack`'s own control-map.md documents; not this
  ephemeral test workload's concern. (NetworkPolicy itself, `k8s/
  network-policy.yaml`, IS implemented and real-verified -- see the
  reports above.)
- Image signing/provenance (Sigstore/cosign), SBOM -- this is a local
  `kind`-loaded image, never pushed to a registry; control-map.md's own
  SEC-COSIGN-001 row already documents why running Cosign against a
  non-pushed image would fabricate a result. **Prep-only readiness for
  closing this real gap** (parameterized `image:` placeholder in
  `k8s/deployment.yaml` + the exact real command sequence, not yet
  executed) is now documented in "Digest-pinning readiness (prep only)"
  above -- still not run this session, do not read this bullet or that
  section as the gap being closed.
- `AshA2A.Topology.Group`-based identity registration/lookup across the
  swarm (richer than the plain `{module, node}` GenServer addressing
  `SwarmNode.Probe` uses) -- a real, valuable follow-on, not bundled into
  this first real slice.
