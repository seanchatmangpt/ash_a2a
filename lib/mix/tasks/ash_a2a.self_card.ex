# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.SelfCard do
  @shortdoc "Generate ash_a2a's own A2A agent card from its shipped protocol surface"

  @moduledoc """
  Generates ash_a2a's self agent card from the protocol surfaces the library
  itself ships, using the same projection path as any other agent's card
  (`AshA2A.CapabilityIndex.build_agent_card/2`).

  The skills are the four protocol surfaces ash_a2a serves as an agent:

    * `codec.encode_decode`      -- `AshA2A.Protocol.JSON` (wire codec)
    * `card.sign_verify`         -- `AshA2A.Protocol.CardSigning` (card signing)
    * `plug.serve_a2a`           -- `AshA2A.Transport.Plug` (A2A server on Plug)
    * `capability_index.compile` -- `AshA2A.CapabilityIndex` (capability
      index compiler)

  Each skill's description is derived from the compiled module docs
  (`Code.fetch_docs/1`) of the corresponding module — never invented. The
  card is served-shape v1.0: the builder normalizes `supported_interfaces`
  to `AshA2A.Protocol.Version.protocol_version/0` (`"1.0"`).

  ## Usage

      mix ash_a2a.self_card                    # writes priv/sa2a/self-agent-card.json
      mix ash_a2a.self_card --output PATH      # custom output path
      mix ash_a2a.self_card --url URL          # advertised card url
      mix ash_a2a.self_card --stdout           # print instead of write

  ## Options

    * `--output` -- output file (default `priv/sa2a/self-agent-card.json`)
    * `--url` -- the card's advertised url (default `http://localhost:4000`)
    * `--stdout` -- print the card JSON to stdout instead of writing a file

  ## Determinism

  Re-running the task against the same compiled sources is byte-stable:
  skills are sorted by id, descriptions come from compiled docs, and the
  codec emits a fixed key order.
  """

  use Mix.Task

  alias AshA2A.Protocol.AgentCard
  alias AshA2A.Protocol.JSON

  @default_output "priv/sa2a/self-agent-card.json"
  @default_url "http://localhost:4000"

  # The shipped protocol surfaces this card honestly advertises. Order here
  # does not matter: the card builder sorts skills by id.
  @surfaces [
    {AshA2A.Protocol.JSON, "codec.encode_decode", "protocol"},
    {AshA2A.Protocol.CardSigning, "card.sign_verify", "protocol"},
    {AshA2A.Transport.Plug, "plug.serve_a2a", "transport"},
    {AshA2A.CapabilityIndex, "capability_index.compile", "capability"}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: [output: :string, url: :string, stdout: :boolean])

    if invalid != [] or rest != [] do
      Mix.raise("invalid arguments: #{inspect(invalid ++ rest)}")
    end

    Mix.Task.run("compile", [])

    card = build_self_card(url: Keyword.get(opts, :url, @default_url))
    url = card.url

    json = card |> JSON.encode_agent_card(url: url) |> Jason.encode!(pretty: true)

    if Keyword.get(opts, :stdout, false) do
      IO.puts(json)
    else
      output = Keyword.get(opts, :output, @default_output)
      File.mkdir_p!(Path.dirname(output))
      File.write!(output, json <> "\n")
      Mix.shell().info("wrote #{output}")
    end
  end

  @doc false
  # Builds the self card struct. Exposed for the test suite.
  #
  # The card envelope comes from the real builder
  # (`AshA2A.CapabilityIndex.build_agent_card/2`) so the CONF-06 capability
  # defaults and `supported_interfaces` v1.0 normalization are shared, not
  # duplicated. The per-skill real-Ash-action introspection in
  # `AgentCardBuilder.build_agent_card_skill/2` requires actual Ash resources;
  # the self card's skills are shipped protocol modules, not Ash actions, so
  # they are projected as card-skill maps after the envelope build.
  @spec build_self_card(keyword()) :: AgentCard.t()
  def build_self_card(opts \\ []) do
    url = Keyword.get(opts, :url, @default_url)

    AshA2A.CapabilityIndex.build_agent_card([], url: url)
    |> Map.put(:skills, Enum.map(@surfaces, &build_surface_skill/1))
    |> then(fn card ->
      %AgentCard{
        card
        | name: "ash_a2a",
          description:
            "ash_a2a protocol surface agent (self card). Authority: this " <>
              "card is descriptive only; it grants no authority — every " <>
              "consequential operation is admitted only through the " <>
              "receipted A2A admission boundary (typed refusals, fail-closed).",
          version: self_version()
      }
    end)
  end

  @spec build_surface_skill({module(), String.t(), String.t()}) :: AgentCard.skill()
  defp build_surface_skill({module, id, tag}) do
    %{
      id: id,
      name: id,
      description: module_doc_summary(module),
      tags: [tag, "a2a"]
    }
  end

  # First sentence of the module's compiled @moduledoc, or a typed fallback.
  @doc false
  @spec module_doc_summary(module()) :: String.t()
  def module_doc_summary(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} ->
        moduledoc
        |> String.trim()
        |> String.split(~r/\.\s/, parts: 2)
        |> hd()
        |> String.trim_trailing(".")

      _ ->
        "Ships as part of the ash_a2a protocol surface."
    end
  end

  defp self_version do
    case :application.get_key(:ash_a2a, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      :undefined -> "0.0.0"
    end
  end
end
