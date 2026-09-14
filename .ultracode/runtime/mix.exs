defmodule Ultracode.MixProject do
  use Mix.Project

  # This is a standalone, non-published sibling application to ash_a2a --
  # NOT part of the ash_a2a Hex package (ash_a2a's own mix.exs `package.files`
  # whitelists only `lib priv mix.exs README.md CHANGELOG.md LICENSE`; this
  # entire `.ultracode/runtime/` tree lives outside that list and is never
  # bundled into a Hex release). It exists to give ash_a2a a durable,
  # AshOban-scheduled operating loop that survives terminal/session death --
  # see `../ULTRACODE.md` for the operating law it executes, and the design
  # rationale in this repo's own conversation history for why this must not
  # live under ash_a2a's own `lib/` (a self-mutating 50-agent scheduler has
  # no business being installed by every consumer of the ash_a2a library).

  def project do
    [
      app: :ultracode,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Ultracode.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.13"},
      {:ash_oban, "~> 0.8"},
      {:oban, "~> 2.24"},
      {:postgrex, "~> 0.18"},
      {:reactor, "~> 1.0"},
      # Real ZAI glm-5.3-flash HTTP client -- the same real provider seam
      # already used by ash_a2a's own AshA2A.Planning.SemanticSynthesis
      # (config :ash_a2a, :llm_profiles, semantic_reasoner: [provider:
      # :zai_coder, ...]). This app configures its own, independent
      # :zai_coder profile rather than reading ash_a2a's config, since this
      # app does not compile-depend on ash_a2a at all -- it only shells out
      # to `mix` inside the ash_a2a working tree as a subprocess.
      {:req_llm, "~> 1.18"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
