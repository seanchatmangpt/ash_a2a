defmodule AshA2A.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_a2a,
      version: "26.9.10",
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
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
