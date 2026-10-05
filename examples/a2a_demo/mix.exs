defmodule A2aDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :a2a_demo,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {A2aDemo.Application, []}]
  end

  defp deps do
    [
      # `env: :dev`: Mix compiles path deps under its default `:prod` env;
      # ash_a2a's compile-time security profile (`AshA2A.SecurityProfile`)
      # must be compiled under a non-prod env for demo profiles to exist.
      {:ash_a2a, path: "../..", env: :dev},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      # Ash policies (Ash.Policy.Authorizer) need a SAT solver; the pure
      # Elixir one keeps the demo NIF-free.
      {:simple_sat, "~> 0.1"}
    ]
  end
end
