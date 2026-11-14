# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MixProject do
  use Mix.Project

  @version "26.11.13"

  # Whole-suite line-coverage floor, enforced by `mix test.all --cover`.
  @coverage_threshold 75

  def cli do
    [
      preferred_envs: [
        "test.all": :test,
        "test.serial": :test,
        "test.live": :test,
        "test.serial.shard": :test,
        "test.serial.solo": :test,
        muzak: :test,
        "muzak.sec": :test
      ]
    ]
  end

  def project do
    [
      app: :ash_a2a,
      version: @version,
      source_url: "https://github.com/seanchatmangpt/ash_a2a",
      homepage_url: "https://hexdocs.pm/ash_a2a/",
      elixir: "~> 1.19",
      description: description(),
      package: package(),
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # Mutation-testing oracle scope. Unset = whole `test/` tree. Example:
      #   MUZAK_TEST_PATHS=test/ash_a2a/protocol/plug MIX_ENV=test mix muzak.sec
      test_paths: muzak_test_paths(),
      deps: deps(),
      docs: docs(),
      aliases: aliases(),
      test_coverage: test_coverage(),
      # :mix and :ex_unit in the PLT so lib/mix/tasks/* modules type-check.
      dialyzer: [plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  defp aliases do
    [
      # `mix test` is the fast default and skips the `:serial` files
      # (`async: false` for shared-state reasons). `mix test.all` is the full
      # suite CI runs. `--include serial` cancels the earlier `--exclude
      # serial`; the trailing excludes re-apply the machine-conditional
      # exclusions from test/test_helper.exs, which `--include serial` would
      # otherwise override.
      test: "test --exclude serial",
      "test.all":
        "test --include serial --exclude graphlaw --exclude graphlaw_engine --exclude sibling_repos",
      "test.serial": "test --only serial",
      # Live, paid, networked LLM round-trips: explicit opt-in only.
      "test.live": "cmd ASH_A2A_LIVE_LLM=1 mix test --include serial --only external_api",

      # `:serial` splits into two disjoint positive tags (ExUnit `--only` does
      # not intersect with `--exclude` for another tag):
      #   :serial_solo  - host-level shared resources (fixed port, :peer
      #                   nodes, shared Postgres, native subprocess); run in
      #                   one invocation, never sharded.
      #   :serial_shard - VM-local shared state; safe to shard with
      #                   `MIX_TEST_PARTITION=<n> mix test.serial.shard --partitions <N>`.
      "test.serial.shard": "test --only serial_shard",
      "test.serial.solo": "test --only serial_solo",

      # Compile with stdout redirected to stderr first, so `ref=$(mix
      # ash_a2a.standing_ref)` captures only the SHA on a cold `_build`.
      "ash_a2a.standing_ref": [&compile_on_stderr/1, "ash_a2a.standing_ref"],

      # One-command quality gate; stages are selectable, e.g.
      #   CHECK_STAGES=compile,test mix check
      # See `.check.exs` for the stage list.
      check: "run .check.exs",

      # Mutation testing over the auth/verify surface, scoped by `.muzak.exs`.
      # Bound runs: `MIX_ENV=test mix muzak.sec --mutations 25`.
      "muzak.sec": ["muzak"]
    ]
  end

  # Same redirect as `Mix.Tasks.AshA2a.StandingRef.on_stderr/1`, which cannot
  # be called here: on a cold `_build` that module does not exist yet.
  defp compile_on_stderr(_args) do
    stdout = Process.group_leader()
    Process.group_leader(self(), Process.whereis(:standard_error))

    try do
      Mix.Task.run("compile", [])
    after
      Process.group_leader(self(), stdout)
    end
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
            "usage-rules.md",
            # Tutorials
            "docs/tutorials/getting-started.md",
            "documentation/tutorials/a2a-your-first-agent.livemd",
            "documentation/tutorials/secure-your-agent.livemd",
            "documentation/tutorials/stream-and-elicit.livemd",
            # How-to guides
            "docs/how-to/authenticate-agent-requests.md",
            "docs/how-to/verify-authority-on-async-paths.md",
            "docs/how-to/enable-semantic-requests.md",
            "docs/how-to/observe-dispatch-with-ocel.md",
            "docs/how-to/use-role-based-llm-resolution.md",
            "docs/how-to/test-your-ash_a2a-app.md",
            "docs/how-to/test-governed-actions.md",
            "docs/how-to/migrate-legacy-to-strict.md",
            "docs/how-to/operate-by-email.md",
            # Reference
            "docs/reference/index.md",
            {"documentation/dsls/DSL-AshA2A.md",
             search_data:
               if(Code.ensure_loaded?(Spark.Docs) and Code.ensure_loaded?(AshA2A),
                 do: Spark.Docs.search_data_for(AshA2A),
                 else: []
               )},
            "docs/reference/dsl.md",
            "docs/reference/configuration.md",
            "docs/reference/telemetry.md",
            "docs/reference/mix-tasks.md",
            "docs/reference/a2a-endpoint-contract.md",
            "docs/reference/a2a-spec-version-mapping.md",
            "docs/reference/c2-certificate.md",
            "docs/reference/a2a-v1-conformance.md",
            "docs/reference/a2a-v1-1-conformance.md",
            "docs/reference/performance.md",
            "docs/reference/c2-wire-interop.md",
            "docs/reference/conformance-claim.md",
            "docs/reference/conformance-profiles.md",
            # Explanation
            "docs/explanation/architecture.md",
            "docs/explanation/message-lifecycle.md",
            "docs/explanation/canonical-graph-identity.md",
            "docs/explanation/graphlaw-wasm-integration.md"
          ],
          # Entries already shaped as {path, opts} pass through unchanged.
          fn
            {_, _} = entry -> entry
            entry -> {entry, []}
          end
        ),
      groups_for_extras: [
        Project: ~r"README|CHANGELOG|usage-rules",
        Tutorials: ~r"(docs|documentation)/tutorials",
        "How-to guides": ~r"docs/how-to",
        Reference: ~r"docs/reference|documentation/dsls",
        Explanation: ~r"docs/explanation"
      ],
      source_ref: "v#{@version}",
      source_url: "https://github.com/seanchatmangpt/ash_a2a",
      groups_for_modules: [
        "Getting started": [AshA2A, AshA2A.Agent, AshA2A.Info, AshA2A.Domain, AshA2A.Dsl],
        Protocol: ~r/^AshA2A\.Protocol\./,
        Transports: ~r/^AshA2A\.(Transport|A2ATransport)\./,
        Storage: ~r/^AshA2A\.(TaskStore|ReceiptStore)/,
        Security: ~r/^AshA2A\.(Security|Authority|AuthZEN|SecurityProfile)/,
        Telemetry: ~r/^AshA2A\.Telemetry/,
        "Conformance and assurance":
          ~r/^AshA2A\.(Chicago|Gall|C2|C3|CS2|Twin|ConsequenceKernel|DfCM|Hilt)/
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
      links: %{
        "GitHub" => "https://github.com/seanchatmangpt/ash_a2a",
        "Changelog" => "https://hexdocs.pm/ash_a2a/changelog.html"
      },
      # Ships lib, the priv subtrees read at runtime, and the docs that back
      # the ExDoc extras. `sa2a_crypto/lib` must ship: `elixirc_paths/1`
      # compiles it into this app (lib/ references SA2ACrypto modules).
      files: ~w(lib
           priv/architecture priv/dfcm priv/graphlaw priv/graphlaw_host priv/proto
           priv/sa2a priv/sa2a_conformance priv/sa2a_conformance_vectors
           priv/sa2a_graphlaw priv/semantic priv/spg_conformance
           mix.exs README.md CHANGELOG.md LICENSE LICENSES REUSE.toml SECURITY.md
           usage-rules.md
           documentation/dsls
           docs/tutorials/*.md docs/how-to/*.md docs/reference/*.md
           docs/explanation/architecture.md
           docs/explanation/message-lifecycle.md
           docs/explanation/canonical-graph-identity.md
           docs/explanation/graphlaw-wasm-integration.md
           sa2a_crypto/lib) ++ native_package_files()
    ]
  end

  # Coverage gate: `mix test.all --cover` exits 3 below the threshold.
  # Chicago bench/fixture code and test support are not library surface.
  defp test_coverage do
    [
      summary: [threshold: @coverage_threshold],
      ignore_modules: [
        ~r/^AshA2A\.Chicago\.(Bench|Fixtures)\./,
        ~r/^AshA2A\.Test\./
      ]
    ]
  end

  # sa2a_crypto stays independently testable as a nested Mix project, while
  # its runtime modules are vendored into this package (Hex packages cannot
  # depend on local path projects).
  @native_crates ~w(hddl_cli graphlaw_host)
  @doc false
  def native_package_files do
    for crate <- @native_crates,
        file <- ~w(Cargo.toml Cargo.lock rust-toolchain.toml src),
        do: "native/#{crate}/#{file}"
  end

  defp elixirc_paths(:test), do: ["lib", "sa2a_crypto/lib", "test/support", "test/conference_sim"]
  defp elixirc_paths(_), do: ["lib", "sa2a_crypto/lib"]

  # Unset => nil => Mix default ("test"); set => comma-separated scoped oracle.
  defp muzak_test_paths do
    case System.get_env("MUZAK_TEST_PATHS") do
      nil -> nil
      "" -> nil
      paths -> String.split(paths, ",", trim: true)
    end
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {AshA2A.Application, []}
    ]
  end

  # Sibling-checkout override for cross-repo development: with
  # `ASH_A2A_LOCAL_DEPS=1`, :ash_graphlaw and :ash_pplan resolve from
  # ../ash_graphlaw and ../ash_pplan instead of Hex. Versions are unchanged.
  defp local_deps?, do: System.get_env("ASH_A2A_LOCAL_DEPS") == "1"

  defp ash_graphlaw_dep do
    if local_deps?(),
      do: {:ash_graphlaw, path: "../ash_graphlaw"},
      else: {:ash_graphlaw, "~> 26.10"}
  end

  defp ash_pplan_dep do
    if local_deps?(),
      do: {:ash_pplan, path: "../ash_pplan", only: :test},
      else: {:ash_pplan, "~> 26.11", only: :test}
  end

  defp pm4exunit_dep do
    if local_deps?(),
      do: {:pm4exunit, path: "../pm4exunit", only: :test},
      else: {:pm4exunit, "~> 26.11", only: :test}
  end

  defp deps do
    [
      # >= 3.33.11: EEF-CVE-2026-93477 (private action args settable via bulk update/destroy)
      {:ash, "~> 3.33 and >= 3.33.11"},
      {:igniter, "~> 0.6"},
      # Dev only: its transitive Rustler/RocksDB NIF needs a Rust toolchain
      # and libclang, and nothing in lib/ or test/ references it.
      {:ggen_igniter, "~> 26.9", only: :dev},
      ash_graphlaw_dep(),
      {:ash_affidavit, "~> 26.10"},
      {:ash_ex4pm, "~> 26.10"},
      {:ash_ai, "~> 1.0", only: :test},
      # HTTP client used by AshA2A.Telemetry.OcelForwarder.
      {:req, "~> 0.5"},
      # Local server for the OCEL forwarder test fixture.
      {:bandit, "~> 1.5", only: :test},
      # SAT solver for Ash policy verification in test fixtures (optional in Ash).
      {:simple_sat, "~> 0.1 and >= 0.1.1", only: :test},
      ash_pplan_dep(),
      pm4exunit_dep(),
      # Mutation testing (`mix muzak.sec`); needs :test because its oracle is
      # the ExUnit suite. Compatibility shims live in `.muzak.exs`.
      {:muzak, "~> 1.1", only: :test, runtime: false},
      {:opentelemetry_api, "~> 1.4", only: :test},
      {:req_llm, "~> 1.18", optional: true},
      {:ash_r2rml, "~> 26.8"},
      # Required in the prod closure by :phoenix, :ash_json_api and
      # :open_api_spex, so it cannot be `only: :test`.
      {:plug, "~> 1.16"},
      # Runtime provider adapters: AshA2A.Execution.FLAME,
      # AshA2A.Durability.DurableServer, AshA2A.Topology.Presence.
      {:flame, "~> 0.5", optional: true},
      {:durable_server, "~> 0.1.5", optional: true},
      # Delivery and task-lifecycle adapters: AshA2A.Delivery.Oban,
      # AshA2A.TaskLifecycle (AshStateMachine).
      {:oban, "~> 2.24", optional: true},
      {:ash_oban, "~> 0.8 or ~> 0.9", optional: true},
      {:ash_state_machine, "~> 0.2", optional: true},
      # Required unconditionally by :ash_oban.
      {:postgrex, "~> 0.18", optional: true},
      # Backs AshA2A.ReceiptStore.Ekv and the automatic EKV wiring in
      # AshA2A.Application.
      {:ekv, "~> 0.4"},
      # Property tests; also a required transitive dep of :ash.
      {:stream_data, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:spark, "~> 2.2"},
      {:reactor, "~> 1.0"},
      {:finch, "~> 0.18"},
      {:yaml_elixir, "~> 2.9"},
      {:sourceror, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix, "~> 1.7"},
      # Cluster/CRDT test fixtures only; nothing in lib/ references them.
      {:libcluster, "~> 3.5", only: :test},
      {:horde, "~> 0.10.0", only: :test},
      # RDF canonicalization and parsing only (AshA2A.Semantic.CanonicalGraph:
      # RDFC-1.0 -> sorted N-Quads -> SHA-256; AshA2A.Semantic.Serialize.verify/3:
      # independent parser gating the engine digest). Validation and reasoning
      # stay in the graphlaw wasm engine; do not add :sparql, :json_ld or :shex.
      {:rdf, "~> 3.0"},
      # RFC 8785 JSON Canonicalization, used by release-closure portable identity.
      {:jcs, "~> 0.2"},
      # In-BEAM Wasmtime host for the vendored priv/graphlaw wasm
      # (AshA2A.GraphLaw.WasmexHost, AshA2A.GraphLaw.WasmexSession). Uses a
      # precompiled NIF, so no Rust toolchain is needed at build time.
      {:wasmex, "~> 0.15.1"},
      # gRPC binding: :protobuf runs the generated lib/ash_a2a/transport/grpc/pb
      # modules (from priv/proto/a2a.proto); :grpc_server is the server runtime;
      # :grpc supplies the client stub used by the generated service module.
      {:protobuf, "~> 0.17"},
      {:grpc_server, "~> 1.0"},
      {:grpc, "~> 1.0"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # `mix check` gate stages.
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:sobelow, "~> 0.13", only: :dev, runtime: false}
    ]
  end
end
