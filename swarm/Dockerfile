# Real multi-stage build for SwarmNode.MixProject -- the minimal, real
# distributed-Erlang swarm-test host app for ash_a2a (see
# swarm/mix.exs's own moduledoc for the real scope boundary: this is NOT
# ash_a2a's release story, ash_a2a stays a pure library).
#
# Build context MUST be the repo root (ash_a2a/), not swarm/ itself --
# this Dockerfile COPYs both the ash_a2a checkout (the real `path:`
# dependency `swarm/mix.exs` declares) and swarm/ into the image:
#
#   docker build -f swarm/Dockerfile -t ash-a2a-swarm-node:local .
#
# Elixir/OTP versions pinned to this repo's own real `.tool-versions`
# (elixir 1.20.4-otp-29, erlang 29.1.1) -- the exact same toolchain every
# other real verification step in this repo already runs against, not a
# separately-chosen version.
#
# Both FROM lines are pinned by content digest (DEP-08), not by mutable tag:
# a tag can be re-pointed upstream, a digest cannot. Digests resolved with
# `docker buildx imagetools inspect <tag>` on 2026-09-27 (builder digest re-resolved 2026-09-28 via the Docker Hub registry API for the OTP 29 bump) (OCI image index, so
# multi-arch). Bump by re-resolving the tag and replacing the digest.
FROM hexpm/elixir:1.20.4-erlang-29.1.1-debian-bookworm-20260918-slim@sha256:037687742ae12c329b59a681a230d62ef3ddd555c0275e577ce41c61539e5248 AS builder

# build-essential + git: ash_a2a's own real dependency tree includes a
# NIF (ekv, a transitive dependency of durable_server) whose
# `make_precompiler: {:nif, CCPrecompiler}` falls back to local
# compilation when no matching precompiled target is fetched -- a real,
# disclosed requirement, not a defensive guess.
#
# No Rust/libclang/cmake needed here (real, verified, not assumed):
# ash_a2a's mix.exs originally declared `{:ggen_igniter, "~> 26.9"}` with
# no `:only` restriction, and ggen_igniter compiles a real Rustler NIF
# (native/ggen_graph_nif, linking a vendored RocksDB via oxrocksdb-sys,
# using bindgen -- a real Rust+libclang+C++ toolchain cost this Dockerfile
# used to pay unconditionally, confirmed by two real build failures
# before that was understood). ash_a2a's own mix.exs now scopes that
# dependency to `only: :dev` -- confirmed here by `MIX_ENV=prod mix deps`
# (both from ash_a2a's own root and from this swarm/ subproject) showing
# zero rustler/ggen_igniter entries in the prod dependency tree, so a
# release build never fetches or compiles it. Only build-essential (for
# ekv's C NIF) is needed.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
       build-essential git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

WORKDIR /build

RUN mix local.hex --force \
    && mix local.rebar --force

# Real Docker layer-cache fix (measured this session: this image was
# rebuilt 5+ times, each paying a full re-fetch/recompile because the
# ORIGINAL ordering copied ash_a2a's own lib/ -- which changes on nearly
# every commit -- before `mix deps.get`, invalidating that step's cache
# layer on every unrelated lib/ change even though `deps.get` only reads
# mix.exs/mix.lock, never lib/ content). Copy only the manifest files
# first (ash_a2a's own mix.exs/mix.lock, the real `path:` dependency
# swarm/mix.exs resolves against, plus swarm's own manifest), fetch
# deps against those alone, THEN copy the real source. `deps.get`'s own
# Docker layer now only invalidates when a manifest file actually
# changes, not on every unrelated ash_a2a lib/ edit.
#
# `mix deps.compile`/`mix compile` still correctly re-run on every
# build regardless (ash_a2a is a real `path:` dependency here, not a
# Hex package -- its own compiled output must reflect whatever lib/
# contains right now; that recompilation cost is real and unavoidable
# without ash_a2a's own release story, not something this reordering
# claims to remove).
COPY mix.exs mix.lock ./
COPY swarm/mix.exs swarm/mix.lock ./swarm/

WORKDIR /build/swarm

RUN mix deps.get --only prod

WORKDIR /build

COPY lib ./lib
# priv/ carries the GraphLaw WASM (priv/graphlaw/praxis_graphlaw.wasm), the
# SA2A corpus, conformance vectors and the court manifest -- everything
# ash_a2a resolves through :code.priv_dir(:ash_a2a). Without it the release
# boots with every semantic/SA2A admission surface degraded to typed errors
# (DEP-01); the RUN test below and SwarmNode.Health.boot_gate/1 make that a
# build failure and a boot failure respectively, never a silent degradation.
COPY priv ./priv
COPY swarm ./swarm

WORKDIR /build/swarm

RUN mix deps.compile
RUN mix compile
RUN mix release swarm_node \
    && test -s "$(ls -d /build/swarm/_build/prod/rel/swarm_node/lib/ash_a2a-*)/priv/graphlaw/praxis_graphlaw.wasm" \
    && test -s /build/swarm/_build/prod/rel/swarm_node/ssl_dist.conf \
    && test -s /build/swarm/_build/prod/rel/swarm_node/capability_release.json

# --- Runtime stage: minimal, non-root, matches the k8s podSecurityContext
# this image is deployed under (runAsUser/runAsGroup 10001, per
# ash_a2a's own k8s/README.md and the kubernetes-workload-pack
# high-assurance-workload example this manifest is modeled on).
FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends libncurses6 libstdc++6 openssl locales ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 10001 swarm \
    && useradd -u 10001 -g swarm -m -s /usr/sbin/nologin swarm

WORKDIR /app
COPY --from=builder --chown=10001:10001 /build/swarm/_build/prod/rel/swarm_node ./

# Persistent state root (receipts, broker, outbox): a PVC is mounted here by
# the StatefulSet (k8s/deployment.yaml); created here so ownership is right
# even when run without a volume.
RUN mkdir -p /var/lib/ash_a2a && chown 10001:10001 /var/lib/ash_a2a

USER 10001:10001

ENV RELEASE_DISTRIBUTION=name
ENV LANG=C.UTF-8

ENTRYPOINT ["/app/bin/swarm_node"]
CMD ["start"]
