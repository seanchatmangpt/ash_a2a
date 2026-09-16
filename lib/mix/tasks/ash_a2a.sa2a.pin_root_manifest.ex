defmodule Mix.Tasks.AshA2a.Sa2a.PinRootManifest do
  @shortdoc "Rebuilds priv/sa2a/root_manifest.json from the real conformance corpus"

  @moduledoc """
  Recomputes every pin in the SA2A Root Manifest from the real bytes of the
  real corpus files under `priv/sa2a/conformance/`, then writes the manifest
  with its newly derived content address.

  Run this after a legitimate, reviewed change to a pinned artifact. Running
  it over an unchanged corpus is a no-op in content terms: the recomputed
  content address is identical, which is exactly what
  `test/ash_a2a/semantic/root_manifest_test.exs` asserts.

  ## This task is a build tool, not an authority bypass

  `AshA2A.Semantic.RootManifest.mutate/5`'s authority gate governs mutation
  of a manifest LOADED INSIDE the BEAM. This task writes a file, and file
  writes are governed by the operating system, not by Elixir -- a point the
  `RootManifest` moduledoc states plainly rather than papering over. What
  the design does guarantee is detectability: any change here moves the
  content address, so every consumer pinned to the previous address refuses.

      mix ash_a2a.sa2a.pin_root_manifest

  Options:

    * `--engine-version` - override the expected `graphlaw_version()` string
      to pin (default: the corpus's recorded expected version).
    * `--engine-path` - override the path to the `praxis-graphlaw` wasm
      artifact being pinned.
  """

  use Mix.Task

  alias AshA2A.Semantic.RootManifest
  alias AshA2A.Semantic.RootManifest.ConformanceCorpus

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")

    {parsed, _, _} =
      OptionParser.parse(argv, strict: [engine_version: :string, engine_path: :string])

    opts =
      []
      |> maybe_put(:expected_version, parsed[:engine_version])
      |> maybe_put(:engine_path, parsed[:engine_path])

    manifest = ConformanceCorpus.regenerate!(opts)

    Mix.shell().info("""
    wrote #{ConformanceCorpus.manifest_path()}
      content address : #{manifest.digest}
      engine          : #{Map.get(manifest.engine, "id")} \
    #{Map.get(manifest.engine, "expected_version")}
      engine digest   : #{Map.get(manifest.engine, "artifact_digest")}
      pinned artifacts: #{length(RootManifest.all_pins(manifest))}
    """)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
