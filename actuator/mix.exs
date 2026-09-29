defmodule Actuator.MixProject do
  use Mix.Project

  def project do
    [
      app: :actuator,
      version: "26.9.28",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases(),
      description:
        "Minimal unintelligent SA2A Actuator: 16-check final actuation fence, durable " <>
          "write-ahead effect claims, closed effector registry, hash-chained effect ledger."
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :ssl], mod: {Actuator.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Depends on the crypto standing substrate only (never on the control-plane application). :jason and :jcs are
  # the same pins sa2a_crypto resolves; declared here because this app calls them directly.
  defp deps do
    [
      {:sa2a_crypto, path: "../sa2a_crypto"},
      {:jcs, "~> 0.2"},
      {:jason, "~> 1.4"}
    ]
  end

  # RELEASE_DISTRIBUTION=none is pinned in rel/env.sh.eex (RFC-SA2A-007 E-D): no Erlang
  # distribution, no epmd. The release ships with its own state directory (config).
  defp releases do
    [
      actuator: [
        include_executables_for: [:unix],
        applications: [actuator: :permanent],
        strip_beams: true
      ]
    ]
  end
end
