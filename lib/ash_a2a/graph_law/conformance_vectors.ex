defmodule AshA2A.GraphLaw.ConformanceVectors do
  @moduledoc """
  The finite conformance suite for the SA2A portable-semantic-execution claim,
  loaded from `priv/graphlaw/conformance_vectors.json`.

  ## What the vectors are for

  The claim under test is exactly:

      Runtime_A != Runtime_B,  WASM_A = WASM_B,  O*_input,A = O*_input,B
      =>  Admission_A = Admission_B,  O*_output,A = O*_output,B,
          Refusal_A = Refusal_B

  ...over a *finite* suite. This module is that suite's single source of truth,
  so Runtime A (BEAM-embedded) and Runtime B (`AshA2A.GraphLaw.RuntimeB`, a
  non-BEAM Wasmtime subprocess) are compared on identical inputs rather than on
  two independently typed-in lists that could silently drift apart.

  It establishes nothing about universal semantic equivalence, production
  readiness, security completeness, or cross-*implementation* equivalence.

  ## Shape

  Each vector is a map with string keys `"id"`, `"fn"`, `"args"`, `"expect"`
  and `"note"`. The `"expect"` value is the exact string the wasm export
  returned when the suite was recorded, including the raw JSON of
  `run_hooks`/`validate_all` results.

  The document also carries `"wasm_sha256"`: the digest of the artifact the
  expectations were recorded against. A runtime that reports a different digest
  is not running the same artifact, so its agreement (or disagreement) with
  these vectors says nothing about host independence.
  """

  @default_path Path.expand("../../../priv/graphlaw/conformance_vectors.json", __DIR__)

  @doc "Resolved path to the vector document."
  @spec path(keyword()) :: String.t()
  def path(opts \\ []) do
    Keyword.get(opts, :vectors_path) ||
      Application.get_env(:ash_a2a, :graphlaw_conformance_vectors_path, @default_path)
  end

  @doc """
  Loads and decodes the vector document from the real file on disk.

  Returns `{:error, %{code: :conformance_vectors_missing | :non_json_vectors}}`
  rather than raising, so a caller can refuse rather than crash.
  """
  @spec load(keyword()) :: {:ok, map()} | {:error, map()}
  def load(opts \\ []) do
    file = path(opts)

    with {:ok, raw} <- read(file),
         {:ok, decoded} <- decode(raw, file) do
      {:ok, decoded}
    end
  end

  @doc """
  The vector list alone, in document order.
  """
  @spec vectors(keyword()) :: {:ok, [map()]} | {:error, map()}
  def vectors(opts \\ []) do
    with {:ok, doc} <- load(opts) do
      {:ok, Map.get(doc, "vectors", [])}
    end
  end

  @doc """
  The vectors rendered as `{function_name, args}` job tuples, ready to hand to
  `AshA2A.GraphLaw.RuntimeB.batch/2` (or to any other runtime's batch entry
  point) so both runtimes are driven from one list.
  """
  @spec jobs(keyword()) :: {:ok, [{String.t(), [String.t()]}]} | {:error, map()}
  def jobs(opts \\ []) do
    with {:ok, vectors} <- vectors(opts) do
      {:ok, Enum.map(vectors, fn v -> {v["fn"], v["args"]} end)}
    end
  end

  @doc """
  The artifact digest the expectations were recorded against.
  """
  @spec wasm_sha256(keyword()) :: {:ok, String.t()} | {:error, map()}
  def wasm_sha256(opts \\ []) do
    with {:ok, doc} <- load(opts) do
      case Map.get(doc, "wasm_sha256") do
        digest when is_binary(digest) -> {:ok, digest}
        _ -> {:error, %{code: :conformance_vectors_missing_digest, path: path(opts)}}
      end
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, raw} ->
        {:ok, raw}

      {:error, reason} ->
        {:error, %{code: :conformance_vectors_missing, path: file, reason: reason}}
    end
  end

  defp decode(raw, file) do
    case JSON.decode(raw) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, other} ->
        {:error, %{code: :non_json_vectors, path: file, raw: other}}

      {:error, reason} ->
        {:error, %{code: :non_json_vectors, path: file, reason: reason}}
    end
  end
end
