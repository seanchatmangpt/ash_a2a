defmodule AshA2A.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_a2a,
      version: "26.9.10",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
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
      {:a2a, path: "/Users/sac/xaas/deps/a2a"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end
end
