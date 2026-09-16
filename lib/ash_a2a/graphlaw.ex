defmodule AshA2A.GraphLaw do
  @moduledoc """
  Locations of the vendored GraphLaw semantic law package.

  GraphLaw (`praxis-graphlaw`) is the user's own prior Rust work -- a native
  N3 / Datalog / SPARQL 1.1 / SHACL / ShEx law-state engine. This repository
  **reuses** it as a content-addressed WebAssembly artifact; it deliberately
  does not reimplement any of that validation logic in Elixir.

  The Elixir side owns only: envelope, standing, refusal typing, authority,
  receipts, admission orchestration, and the A2A boundary. Every graph-shaped
  judgement (canonical graph identity, SHACL/ShEx validation, hook evaluation)
  is delegated to the vendored module.

  Nothing in this module (or under `AshA2A.GraphLaw.*`) carries authority.
  A digest, a validation verdict, and a `graph_hash` are all *observations*;
  any real consequence still has to pass `AshA2A.CommandBus`.

  See `docs/explanation/graphlaw-wasm-integration.md`.
  """

  @artifact "praxis_graphlaw.wasm"
  @manifest "MANIFEST.json"
  @host "host/graphlaw_host.mjs"

  @doc """
  Absolute path of the vendored law-package directory.

  Resolves via `:code.priv_dir/1` when this app is a compiled dependency, and
  falls back to a path relative to this source file when it is not (for
  example during a bare `mix format`/doc build in a fresh checkout).
  """
  @spec dir() :: String.t()
  def dir do
    case :code.priv_dir(:ash_a2a) do
      {:error, :bad_name} -> Path.expand("../../priv/graphlaw", __DIR__)
      priv -> Path.join(List.to_string(priv), "graphlaw")
    end
  end

  @doc "Absolute path of the vendored `.wasm` artifact."
  @spec wasm_path() :: String.t()
  def wasm_path, do: Path.join(dir(), @artifact)

  @doc "Absolute path of the vendored `MANIFEST.json`."
  @spec manifest_path() :: String.t()
  def manifest_path, do: Path.join(dir(), @manifest)

  @doc "Absolute path of the dependency-free JS host used to execute the artifact."
  @spec host_path() :: String.t()
  def host_path, do: Path.join(dir(), @host)

  @doc "Absolute path of a named conformance fixture, e.g. `fixture_path(\"base.ttl\")`."
  @spec fixture_path(String.t()) :: String.t()
  def fixture_path(name) when is_binary(name), do: Path.join([dir(), "fixtures", name])

  @doc "Basename of the vendored artifact, as recorded in the manifest."
  @spec artifact_name() :: String.t()
  def artifact_name, do: @artifact
end
