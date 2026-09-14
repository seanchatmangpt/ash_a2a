defmodule AshA2A.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_a2a,
      version: "26.9.14",
      elixir: "~> 1.19",
      description: description(),
      package: package(),
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"]
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
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE)
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
      {:ggen_igniter, "~> 26.9"},
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
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix, "~> 1.7"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
