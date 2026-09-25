defmodule AshA2A.MixProject do
  use Mix.Project

  def cli do
    [
      preferred_envs: [
        "test.all": :test,
        "test.serial": :test,
        "test.serial.shard": :test,
        "test.serial.solo": :test
      ]
    ]
  end

  def project do
    [
      app: :ash_a2a,
      version: "26.9.24",
      source_url: "https://github.com/seanchatmangpt/ash_a2a",
      homepage_url: "https://hexdocs.pm/ash_a2a/",
      elixir: "~> 1.19",
      description: description(),
      package: package(),
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      docs: docs(),
      aliases: aliases()
    ]
  end

  defp aliases do
    [
      # `mix test` is now the fast-iteration default: the ~96 files tagged
      # `:serial` are `async: false` for real shared-state reasons (see
      # `test/test_helper.exs`'s broker comment, and each file's own
      # moduledoc -- mostly a shared global `:telemetry` observer used for
      # stimulus attribution) and run strictly one-at-a-time regardless of
      # `--max-cases`, dominating full-suite wall clock (measured: ~240s
      # for the fast lane vs. ~740-1300s for everything). Full coverage
      # (what CI runs) is `mix test.all`; `mix test.serial` runs just the
      # excluded tail.
      #
      # `test.all` deliberately reads `"test --include serial"`, not
      # `"test"`: Mix's alias self-reference loop guard only fires when an
      # alias invokes a task of its OWN name, not when a *different*
      # alias's step resolves to an already-aliased task name -- so a bare
      # `"test.all": "test"` would silently re-enter the `test` alias
      # above (still excluding `:serial`) instead of reaching the real
      # underlying task. `--include serial` is ExUnit's own, native way to
      # cancel the earlier `--exclude serial`: ExUnit applies include/
      # exclude filters for a tag in the order given, so the later
      # `--include` wins for that tag, correctly yielding the full suite
      # with zero custom logic.
      test: "test --exclude serial",
      "test.all": "test --include serial",
      "test.serial": "test --only serial",

      # `:serial` (all 96) splits into two DISJOINT, independently-tagged
      # subsets rather than "serial minus an exclude": ExUnit's `--only`
      # is a sole selector, not intersected with a same-invocation
      # `--exclude` for a different tag (confirmed empirically -- `--only
      # serial --exclude serial_solo` silently ran a `serial_solo`-tagged
      # test anyway, letting a `:benchmark` resource-ceiling test slip
      # through onto a loaded host). So instead of trying to subtract,
      # each file gets exactly one of two positive tags:
      #   - `:serial_solo` (~23 files): holds a real host-level shared
      #     resource across OS processes (a fixed port, a real
      #     `:peer`/multinode spawn, the shared Postgres test database,
      #     the `hddl_cli` native subprocess) -- must run together in one
      #     `mix test.serial.solo` invocation, never sharded.
      #   - `:serial_shard` (~73 files): serial only for real but
      #     VM-local shared state (a shared `:telemetry` observer, the
      #     shared `AshA2A.Authority.Broker.InMemory`) -- safe to run via
      #     `MIX_TEST_PARTITION=<n> mix test.serial.shard --partitions <N>`
      #     launched as N separate OS processes (each tracked by its own
      #     PID, never stopped by name/pattern) -- see the how-to guide.
      "test.serial.shard": "test --only serial_shard",
      "test.serial.solo": "test --only serial_solo"
    ]
  end

  defp docs do
    [
      main: "readme",
      extras:
        Enum.map(
          [
            # Project
            "README.md",
            "CHANGELOG.md",
            "docs/PHOENIX_RUNTIME_PRIOR_ART_AUDIT.md",
            # Tutorials
            "docs/tutorials/getting-started.md",
            # How-to guides
            "docs/how-to/authenticate-agent-requests.md",
            "docs/how-to/verify-authority-on-async-paths.md",
            "docs/how-to/enable-semantic-requests.md",
            "docs/how-to/observe-dispatch-with-ocel.md",
            "docs/how-to/use-role-based-llm-resolution.md",
            "docs/how-to/test-your-ash_a2a-app.md",
            # Reference
            "docs/reference/index.md",
            "docs/reference/dsl.md",
            "docs/reference/configuration.md",
            "docs/reference/telemetry.md",
            "docs/reference/mix-tasks.md",
            "docs/reference/a2a-endpoint-contract.md",
            "docs/reference/a2a-spec-version-mapping.md",
            # Explanation
            "docs/explanation/architecture.md",
            "docs/explanation/message-lifecycle.md",
            "docs/explanation/canonical-graph-identity.md",
            "docs/explanation/graphlaw-wasm-integration.md"
          ],
          &{&1, []}
        ),
      groups_for_extras: [
        Project: ~r"README|CHANGELOG|PHOENIX",
        Tutorials: ~r"docs/tutorials",
        "How-to guides": ~r"docs/how-to",
        Reference: ~r"docs/reference",
        Explanation: ~r"docs/explanation"
      ]
    ]
  end

  defp description do
    "A Spark.Dsl.Extension that exposes Ash.Resource/Ash.Domain actions as " <>
      "A2A protocol agent skills, compiling a verified AgentCard and " <>
      "dispatching inbound A2A messages to Ash actions."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/seanchatmangpt/ash_a2a"},
      # The four Diataxis quadrants ship in the package so `mix hex.publish`
      # can build the ExDoc extras declared in docs/0 above. Internal trees
      # (docs/archive, docs/rfc, research) deliberately do NOT ship.
      files:
        ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE docs/tutorials docs/how-to docs/reference docs/explanation)
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AshA2A.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.0"},
      {:igniter, "~> 0.6"},
      # `only: :dev`: real, disclosed finding (swarm-test Docker build,
      # this session) -- zero references to `GgenIgniter`/`ggen_igniter`
      # anywhere in this repo's own lib/ or test/ (confirmed via a real
      # grep across both), yet it was declared with no `:only`
      # restriction, so every consumer's `MIX_ENV=prod` release build
      # (not just interactive dev use) unconditionally paid its real,
      # heavy transitive cost: a Rustler NIF (`ggen_graph_nif`) linking a
      # vendored RocksDB via `oxrocksdb-sys` and using `bindgen`, which
      # needs a real Rust toolchain, `libclang`, and a C++ toolchain at
      # build time -- confirmed by two real, disclosed Docker build
      # failures before this fix (missing Rust toolchain, then missing
      # libclang) in swarm/Dockerfile's own commit history. Scoping to
      # `:dev` keeps `mix ggen_igniter.doctor`/interactive use fully
      # available; a real `MIX_ENV=prod mix deps.get` for this repo (and
      # this feature's own swarm-test release) simply no longer fetches
      # or compiles it.
      {:ggen_igniter, "~> 26.9", only: :dev},
      {:a2a, "~> 0.2"},
      {:ash_ai, "~> 1.0"},
      # AshA2A.Telemetry.OcelForwarder's real HTTP POST to beam4pm's real
      # OCEL ingest endpoint -- already transitively present (via :a2a's
      # optional dep / :igniter), promoted to direct since this module
      # calls it explicitly.
      {:req, "~> 0.5"},
      # Real local Bandit server for
      # test/ash_a2a_telemetry_ocel_forwarder_test.exs's fixture standing
      # in for BeamPM.OcelIngest.Router (same MicroBeam4pm-style pattern
      # already used in ex4pm/ash_ex4pm/xaas this session).
      {:bandit, "~> 1.5", only: :test},
      {:req_llm, "~> 1.18"},
      {:ash_r2rml, "~> 26.8"},
      # `:plug` is an optional dep of `:a2a` (A2A.Plug/A2A.Plug.Auth). Also
      # now pulled in transitively as a normal dep via `:ash_ai`'s
      # `:websock_adapter` dependency, so it can no longer be restricted to
      # `only: :test` (Mix rejects a narrower :only than a transitive dep
      # requires). test/ash_a2a_plug_agent_card_test.exs drives a REAL
      # A2A.Plug HTTP pipeline via Plug.Test.
      {:plug, "~> 1.16"},
      # Real provider implementations for the three runtime-provider
      # boundaries: AshA2A.Execution.FLAME (Placement),
      # AshA2A.Durability.DurableServer (Durability), and
      # AshA2A.Topology.Presence (Topology). Declaring them as resolvable
      # deps makes each adapter's available?/0 (or available?/1) true and
      # its call path reachable; the adapters themselves remain
      # authority-free regardless -- they never gain independent DO
      # capability, only observed provider evidence via RuntimeReceipt.
      {:flame, "~> 0.5"},
      {:durable_server, "~> 0.1.5"},
      # v26.9.14: real provider implementations closing GAP D
      # (AshA2A.Delivery.Oban, AshA2A.TaskLifecycle's AshStateMachine
      # adapter). Same pattern as flame/durable_server above -- declaring
      # them as resolvable deps makes each adapter's available?/0 true and
      # its real call path reachable; the adapters themselves stay
      # authority-free (queue acceptance is not an execution receipt; a
      # state transition is not a DO -- both still funnel any real
      # consequence through AshA2A.CommandBus).
      {:oban, "~> 2.24"},
      {:ash_oban, "~> 0.8"},
      {:ash_state_machine, "~> 0.2"},
      # Oban's real PostgreSQL storage engine driver, exercised for real
      # against a real disposable local Postgres instance in this repo's
      # own test suite. Cannot be `only: :test` -- `:ash_oban` itself
      # requires `:postgrex` unconditionally (same real Mix dependency-only
      # narrowing constraint the `:plug` comment above already documents).
      {:postgrex, "~> 0.18"},
      # DurableServer.Backends.EKVStore's real local storage engine, used by
      # AshA2A.RuntimeProvidersIntegrationTest so Durability can be
      # exercised with a real local durable-KV backend instead of the
      # default ObjectStore/S3 backend (which needs cloud credentials).
      # Promoted out of `only: :test`: AshA2A.ReceiptStore.Ekv (a real
      # durable receipt store, not a test double) and
      # AshA2A.Application.receipt_store_children/0's automatic EKV wiring
      # both call the :ekv package directly outside of Mix.env() == :test,
      # the same reason :plug was promoted out of only: :test earlier in
      # this repo's history.
      {:ekv, "~> 0.4"},
      # Real property/fuzz testing (test/ash_a2a_property_fuzz_test.exs).
      # Already a required, unrestricted (non-`only:`) transitive dep of
      # `:ash` itself (mix.lock: "stream_data": {:hex, :stream_data,
      # "1.4.0", ...}; deps/ash/mix.exs declares it with no `:only`) --
      # promoted to an explicit direct dep here so this repo's own property
      # tests declare their real dependency instead of relying on an
      # incidental transitive pin ash could drop or relax in a future
      # version. Cannot be narrowed to `only: :test` -- Mix rejects a
      # narrower `:only` than a transitive dependency requires, the same
      # real constraint already documented above for `:plug`/`:postgrex`.
      {:stream_data, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix, "~> 1.7"},
      # v26.9.16: real libcluster + Horde proof-of-concept (real node
      # discovery + a real CRDT-backed distributed process registry),
      # named as prior art for the compute/coordination lenses in this
      # session's requirements synthesis. `libcluster` is already a real
      # dep of the separate `swarm/` mix project (`swarm/mix.exs`,
      # `Cluster.Strategy.Kubernetes.DNS`) -- this declares it (and the
      # new `Horde.Registry`/`Horde.DynamicSupervisor` pair) directly on
      # the root `:ash_a2a` app instead, scoped to `:test` because the
      # whole PoC lives in
      # `test/ash_a2a/libcluster_horde_poc_test.exs` (real `:peer`-spawned
      # second BEAM node, same pattern as
      # `test/ash_a2a/distributed_node_loss_test.exs`) -- nothing in
      # `lib/` references either module yet, so `only: :test` keeps a real
      # `MIX_ENV=prod mix deps.get` from paying their cost, the same
      # narrowing reasoning already documented above for `:bandit`.
      {:libcluster, "~> 3.5", only: :test},
      {:horde, "~> 0.10.0", only: :test},
      # v26.9.16 (RFC-SA2A-001 S12/S79): CANONICALIZATION AND
      # SERIALIZATION/PARSING ONLY. ONE declaration, two real `lib/` uses:
      #
      #   * `AshA2A.Semantic.CanonicalGraph` -- the single authoritative RFC
      #     S12 canonical graph identity: RDFC-1.0 (`RDF.Canonicalization`)
      #     -> code-point-sorted N-Quads -> SHA-256, pinned as
      #     `"RDFC-1.0/SHA-256/n-quads-sorted"`. The praxis-graphlaw wasm
      #     `graph_hash` export is NOT RDFC-1.0 (not blank-node-relabel
      #     invariant; see docs/explanation/canonical-graph-identity.md), so
      #     S12 identity is taken in-BEAM here.
      #   * `AshA2A.Semantic.Serialize.verify/3` -- an *independent* real
      #     parser gating the engine canonical-digest path.
      #
      # Never for validation, reasoning or entailment, all of which stay in
      # the praxis-graphlaw law package (S14 ShEx, S15 SHACL, S16 Datalog,
      # S17 N3, S18 SPARQL); `:sparql`, `:json_ld` and `:shex` are NOT added
      # and must not be.
      #
      # The `Serialize.verify/3` gate is not optional decoration. A real
      # probe of the real prebuilt praxis-graphlaw wasm established that its
      # `graph_hash/1` has no parse-error channel and reports no parsed-triple
      # count:
      # `graph_hash(good <> "GARBAGE !!!")` returned bit-for-bit the same
      # digest as `graph_hash(good)`, and `graph_hash("GARBAGE !!!")`
      # returned `af1349b9f5f9a1a6...` == `BLAKE3("")` == `graph_hash("")`.
      # A malformed serialization therefore yields a confident, valid-looking
      # digest of a *smaller or empty* graph. Parsing our own output back
      # with a second real implementation is the only way to detect it.
      #
      # Zero marginal dependency weight: `rdf` 3.0.1 is ALREADY a required,
      # unrestricted transitive dep of `:ash_r2rml` (a direct dep of this
      # project) and is already pinned in `mix.lock` and present in `deps/` --
      # adding `{:rdf, "~> 3.0"}` here left `mix.lock` byte-for-byte
      # unchanged (verified with a real `mix deps.get` + `git diff mix.lock`).
      # Promoted to an explicit direct dep for exactly the reason `:stream_data`
      # above already documents: declare the real dependency instead of
      # relying on an incidental transitive pin. Cannot be narrowed to
      # `only: :test` -- `lib/ash_a2a/semantic/serialize.ex` and
      # `lib/ash_a2a/semantic/canonical_graph.ex` call it outside the test
      # env, the same real constraint documented for `:plug`/`:ekv`.
      {:rdf, "~> 3.0"},
      # v26.9.16 (RFC-SA2A-001 S12/S79): the real in-BEAM WebAssembly host
      # runtime. ONE declaration shared by two independent hosts of the same
      # vendored `priv/graphlaw/praxis_graphlaw.wasm` law package:
      #
      #   * `AshA2A.GraphLaw.WasmexSession` -- runtime A of
      #     `AshA2A.SA2A.Conformance` (the SA2A conformance court). It checks
      #     `Code.ensure_loaded?(Wasmex)` and returns a typed
      #     `:wasmex_unavailable` refusal rather than raising.
      #   * `AshA2A.GraphLaw.WasmexHost` -- the application-supervised,
      #     long-lived Wasmtime instance (started in `AshA2A.Application`).
      #
      # `:wasmex` wraps a real Wasmtime engine via a Rustler NIF; on
      # aarch64-apple-darwin (and the other tier-1 targets)
      # `rustler_precompiled` downloads a prebuilt NIF, so this does NOT
      # require a Rust toolchain at build time -- unlike `:ggen_igniter`
      # above, which is why that one is `only: :dev` and this one is not
      # similarly restricted. Unrestricted (not `only:`) also because
      # `lib/ash_a2a/graph_law/wasmex_host.ex` is real runtime library code,
      # not a test fixture. This repo does NOT own an RDF canonicalization /
      # SHACL / ShEx / Datalog / N3 implementation and must not grow one --
      # `praxis-graphlaw` already is one; Elixir's job at this boundary is
      # envelope, standing, refusal typing, authority, receipts and admission
      # orchestration, never the derivation itself.
      {:wasmex, "~> 0.15.1"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
