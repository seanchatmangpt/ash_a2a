defmodule Sa2aCrypto.MixProject do
  use Mix.Project

  def project do
    [
      app: :sa2a_crypto,
      version: "26.9.28",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Affidavit-shaped cryptographic standing substrate for SA2A (certify, don't decide)."
    ]
  end

  def application, do: [extra_applications: [:crypto]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps, do: [{:jcs, "~> 0.2"}, {:jason, "~> 1.4"}]
end
