defmodule AuthorityService.MixProject do
  use Mix.Project

  def project do
    [
      app: :authority_service,
      version: "26.9.29",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases(),
      description:
        "Issue-only AuthorityService (RFC-SA2A-006 s7.4/s13): verifies approvals, issues " <>
          "ActuationCertificates, never executes effects."
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :public_key],
      mod: {AuthorityService.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Depends ONLY on the crypto standing substrate; never on ash_a2a.
  defp deps, do: [{:sa2a_crypto, path: "../sa2a_crypto"}]

  defp releases do
    [
      authority_service: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
