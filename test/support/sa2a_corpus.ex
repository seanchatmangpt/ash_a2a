defmodule AshA2A.Test.Support.Sa2aCorpus do
  @moduledoc """
  Stages a real, writable copy of the SA2A conformance corpus on disk.

  Not a fixture in the test-double sense: this copies the REAL corpus files
  (`priv/sa2a/conformance/`) to a real temporary directory and builds a real
  `AshA2A.Semantic.RootManifest` over them with real SHA-256 digests. Tests
  that must mutate a pinned artifact (to prove drift is caught) need a
  writable corpus, and must never scribble on the committed one.
  """

  alias AshA2A.Semantic.RootManifest
  alias AshA2A.Semantic.RootManifest.ConformanceCorpus

  @doc """
  Copies the real corpus to a fresh temp root, builds the manifest over it,
  writes `root_manifest.json`, and returns `%{root:, path:, manifest:}`.

  `opts` are forwarded to `ConformanceCorpus.spec/1`, so a caller can stage a
  corpus pinned to a deliberately wrong engine version to prove the engine
  drift check bites.
  """
  @spec stage!(keyword()) :: %{root: String.t(), path: String.t(), manifest: RootManifest.t()}
  def stage!(opts \\ []) do
    root =
      Path.join(
        System.tmp_dir!(),
        "sa2a_corpus_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)

    File.cp_r!(
      Path.join(ConformanceCorpus.root(), "conformance"),
      Path.join(root, "conformance")
    )

    {:ok, manifest} = RootManifest.build(root, ConformanceCorpus.spec(opts))
    path = Path.join(root, "root_manifest.json")
    RootManifest.write!(manifest, path)

    %{root: root, path: path, manifest: manifest}
  end

  @doc "Removes a staged corpus root."
  @spec cleanup(String.t()) :: :ok
  def cleanup(root) do
    File.rm_rf!(root)
    :ok
  end
end
