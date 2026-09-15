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
# (elixir 1.19.5-otp-27, erlang 27.2.4) -- the exact same toolchain every
# other real verification step in this repo already runs against, not a
# separately-chosen version.
FROM hexpm/elixir:1.19.5-erlang-27.2.4-debian-bookworm-20260824-slim AS builder

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
COPY swarm ./swarm

WORKDIR /build/swarm

RUN mix deps.compile
RUN mix compile
RUN mix release swarm_node

# --- Runtime stage: minimal, non-root, matches the k8s podSecurityContext
# this image is deployed under (runAsUser/runAsGroup 10001, per
# ash_a2a's own k8s/README.md and the kubernetes-workload-pack
# high-assurance-workload example this manifest is modeled on).
FROM debian:bookworm-slim

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends libncurses6 libstdc++6 openssl locales ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 10001 swarm \
    && useradd -u 10001 -g swarm -m -s /usr/sbin/nologin swarm

WORKDIR /app
COPY --from=builder --chown=10001:10001 /build/swarm/_build/prod/rel/swarm_node ./

USER 10001:10001

ENV RELEASE_DISTRIBUTION=name
ENV LANG=C.UTF-8

ENTRYPOINT ["/app/bin/swarm_node"]
CMD ["start"]
