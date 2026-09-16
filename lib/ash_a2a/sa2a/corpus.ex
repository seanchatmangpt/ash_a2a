defmodule AshA2A.SA2A.Corpus do
  @moduledoc """
  Loader for the SA2A Portable Semantic Execution Conformance corpus in
  `priv/sa2a_conformance/`.

  The corpus is a **content-addressed package**: `MANIFEST.json` carries the
  real SHA-256 and BLAKE3 of every file in it, plus the identity of the
  GraphLaw wasm artifact the expected values were measured against. This module
  re-computes the SHA-256 of every manifested file at load time and **fails
  closed** if a single byte drifted, so an edited fixture is a load error rather
  than a quietly different test result.

  ## Digest algorithms, and why only one of them is enforced here

  `MANIFEST.json` records both digests per file:

    * `sha256` -- over the raw file bytes. Recomputed and **enforced** here via
      `:crypto.hash(:sha256, ...)`, which is in OTP and needs no dependency.
    * `blake3` -- over the file decoded as UTF-8, computed BY the pinned wasm's
      own `blake3_hex/1` export. There is no BLAKE3 implementation in this
      project's dependency tree (measured: no `b3`/`blake3` package in `deps/`),
      so this module carries the value as recorded engine-side provenance and
      does not recompute it. A runtime that has the wasm instantiated can verify
      it against the same export; `blake3/2` exposes the recorded value for that
      comparison.

  This split is deliberate and is the honest state: the load gate is real and
  enforced (SHA-256), and the engine-provenance digest is recorded, not
  pretended to be checked.

  ## What a vector is

  Each vector is a Turtle graph plus a `.expected.json` sidecar. Every expected
  value in a sidecar is either a **digest** or a **typed refusal code** -- never
  a serialized RDF string, because representation differences between two
  runtimes would contaminate the portability claim being made.

  A sidecar separates two different kinds of statement, and this module keeps
  them separate:

    * `expected` -- what RFC-SA2A-001 requires of any conformant runtime.
    * `measured_on_pinned_engine` -- what the pinned wasm actually did when the
      corpus was built. This is evidence, not law.

  `conformance` says whether those two agree. Two vectors currently do not, and
  say so (`:failing_on_pinned_engine`) rather than being quietly weakened to
  match the engine -- see `priv/sa2a_conformance/README.md` and
  `MANIFEST.json`'s `deferred` array.

  ## The law graph

  `validate_all/5` and `run_hooks/2` do not consume a vector's graph alone: they
  consume the **law graph**, which is the vector's subject graph concatenated
  with the admitted rules (`rules/denials.n3`) and the admitted hooks
  (`hooks/admitted_hooks.ttl`), joined by `"\\n"`. `law_graph/2` builds exactly
  that text; the S12 identity vectors hash the subject graph alone. Both digests
  are recorded per vector (`graph_digest` and `law_graph_digest`).

  ## Usage

      corpus = AshA2A.SA2A.Corpus.load!()
      vector = AshA2A.SA2A.Corpus.fetch_vector!(corpus, "shacl_warning_only")
      vector.expected_admission        #=> :admitted
      law_text = AshA2A.SA2A.Corpus.law_graph(corpus, vector)

  This module owns no validation logic of its own. Deciding admission over the
  law graph is GraphLaw's job (SHACL/ShEx/Datalog/N3/canonicalization) and the
  Elixir side's job is the envelope: loading, digest integrity, refusal typing,
  and handing real bytes to the engine.
  """

  alias AshA2A.SA2A.Corpus.Vector

  @manifest_file "MANIFEST.json"
  @corpus_subdir "sa2a_conformance"

  @admissions %{"ADMITTED" => :admitted, "REFUSED" => :refused}

  @doc """
  The typed refusal codes this corpus is allowed to name.

  An unrecognised code in a sidecar is a load failure, not a new atom: refusal
  typing is a closed vocabulary, so a typo cannot invent a refusal class.
  """
  @refusal_codes %{
    "sa2a_shacl_violation" => :sa2a_shacl_violation,
    "sa2a_shex_nonconformant" => :sa2a_shex_nonconformant,
    "sa2a_denial_fired" => :sa2a_denial_fired,
    "sa2a_unadmitted_predicate" => :sa2a_unadmitted_predicate,
    "sa2a_malformed_graph" => :sa2a_malformed_graph
  }

  @conformances %{
    "HOLDS" => :holds,
    "FAILING_ON_PINNED_ENGINE" => :failing_on_pinned_engine,
    "HOST_GATE_REQUIRED" => :host_gate_required
  }

  @enforce_keys [:dir, :manifest, :files, :vectors, :parts]
  defstruct [:dir, :manifest, :files, :vectors, :parts]

  @type t :: %__MODULE__{
          dir: String.t(),
          manifest: map(),
          files: %{String.t() => map()},
          vectors: %{String.t() => Vector.t()},
          parts: %{atom() => String.t()}
        }

  @doc """
  Resolves the corpus directory: `opts[:dir]`, else
  `Application.get_env(:ash_a2a, :sa2a_corpus_dir)`, else
  `priv/sa2a_conformance` of the loaded `:ash_a2a` application.
  """
  @spec dir(keyword()) :: String.t()
  def dir(opts \\ []) do
    Keyword.get(opts, :dir) ||
      Application.get_env(:ash_a2a, :sa2a_corpus_dir) ||
      Path.join(to_string(:code.priv_dir(:ash_a2a)), @corpus_subdir)
  end

  @doc """
  Loads and integrity-checks the corpus.

  Returns `{:ok, t()}` only when every manifested file exists and its real
  SHA-256 matches `MANIFEST.json`, every file on disk is manifested, and every
  sidecar decodes into a well-typed `Vector`. Otherwise `{:error, map}` carrying
  a `:code` key:

    * `:sa2a_corpus_dir_missing`
    * `:sa2a_corpus_manifest_unreadable` / `:sa2a_corpus_manifest_invalid`
    * `:sa2a_corpus_file_missing`
    * `:sa2a_corpus_digest_mismatch`
    * `:sa2a_corpus_unmanifested_file`
    * `:sa2a_corpus_vector_invalid`
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, map()}
  def load(opts \\ []) do
    d = dir(opts)

    with :ok <- check_dir(d),
         {:ok, manifest} <- read_manifest(d),
         {:ok, files} <- manifest_files(manifest),
         :ok <- verify_files(d, files),
         :ok <- verify_no_unmanifested(d, files),
         {:ok, vectors} <- load_vectors(d, files) do
      {:ok,
       %__MODULE__{
         dir: d,
         manifest: manifest,
         files: files,
         vectors: vectors,
         parts: read_parts(d)
       }}
    end
  end

  @doc "Same as `load/1` but raises `RuntimeError` on any integrity failure."
  @spec load!(keyword()) :: t()
  def load!(opts \\ []) do
    case load(opts) do
      {:ok, corpus} ->
        corpus

      {:error, err} ->
        raise "SA2A corpus load failed: #{inspect(err)}"
    end
  end

  @doc "All vectors, sorted by name."
  @spec vectors(t()) :: [Vector.t()]
  def vectors(%__MODULE__{vectors: v}), do: v |> Map.values() |> Enum.sort_by(& &1.name)

  @doc "Fetches one vector by name."
  @spec fetch_vector(t(), String.t()) :: {:ok, Vector.t()} | :error
  def fetch_vector(%__MODULE__{vectors: v}, name), do: Map.fetch(v, name)

  @doc "Fetches one vector by name, raising if absent."
  @spec fetch_vector!(t(), String.t()) :: Vector.t()
  def fetch_vector!(%__MODULE__{vectors: v} = c, name) do
    case Map.fetch(v, name) do
      {:ok, vector} -> vector
      :error -> raise KeyError, key: name, term: Map.keys(c.vectors)
    end
  end

  @doc """
  One of the fixed, non-vector parts of the law package, as real file text:
  `:profile`, `:shapes`, `:shapes_violations`, `:shapes_warnings`,
  `:shex_schema`, `:shape_map`, `:rules`, `:hooks`, `:event`.
  """
  @spec part(t(), atom()) :: String.t()
  def part(%__MODULE__{parts: parts}, key), do: Map.fetch!(parts, key)

  @doc """
  Builds the law graph text a runtime actually validates: the vector's subject
  graph concatenated with the admitted rules and hooks, joined by `"\\n"`.

  This composition is not incidental -- it is recorded in `MANIFEST.json` under
  `composition.law_graph`, and `Vector.law_graph_digest` is the measured digest
  of exactly this text.
  """
  @spec law_graph(t(), Vector.t()) :: String.t()
  def law_graph(%__MODULE__{parts: parts}, %Vector{graph: graph}) do
    Enum.join([graph, parts.rules, parts.hooks], "\n")
  end

  @doc "The recorded (engine-computed) BLAKE3 of a manifested file."
  @spec blake3(t(), String.t()) :: {:ok, String.t()} | :error
  def blake3(%__MODULE__{files: files}, rel) do
    case Map.fetch(files, rel) do
      {:ok, %{"blake3" => b3}} -> {:ok, b3}
      _ -> :error
    end
  end

  @doc "The pinned engine identity the expected values were measured against."
  @spec engine(t()) :: map()
  def engine(%__MODULE__{manifest: m}), do: Map.fetch!(m, "engine")

  @doc """
  The honestly-recorded gaps between what the RFC requires and what the pinned
  engine does. Each entry carries `id`, `status`, `measured` and `consequence`.
  """
  @spec deferred(t()) :: [map()]
  def deferred(%__MODULE__{manifest: m}), do: Map.get(m, "deferred", [])

  # --- integrity ---------------------------------------------------------

  defp check_dir(d) do
    if File.dir?(d), do: :ok, else: {:error, %{code: :sa2a_corpus_dir_missing, detail: d}}
  end

  defp read_manifest(d) do
    path = Path.join(d, @manifest_file)

    with {:read, {:ok, raw}} <- {:read, File.read(path)},
         {:decode, {:ok, decoded}} <- {:decode, JSON.decode(raw)},
         {:shape, true} <- {:shape, is_map(decoded) and is_map(decoded["files"])} do
      {:ok, decoded}
    else
      {:read, {:error, reason}} ->
        {:error, %{code: :sa2a_corpus_manifest_unreadable, detail: %{path: path, reason: reason}}}

      {:decode, _} ->
        {:error, %{code: :sa2a_corpus_manifest_invalid, detail: %{path: path, reason: :not_json}}}

      {:shape, _} ->
        {:error,
         %{code: :sa2a_corpus_manifest_invalid, detail: %{path: path, reason: :missing_files_map}}}
    end
  end

  defp manifest_files(%{"files" => files}) when is_map(files), do: {:ok, files}

  defp verify_files(d, files) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {rel, entry}, :ok ->
      path = Path.join(d, rel)

      case File.read(path) do
        {:error, reason} ->
          {:halt,
           {:error, %{code: :sa2a_corpus_file_missing, detail: %{file: rel, reason: reason}}}}

        {:ok, bytes} ->
          actual = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

          if actual == entry["sha256"] do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              %{
                code: :sa2a_corpus_digest_mismatch,
                detail: %{
                  file: rel,
                  algorithm: :sha256,
                  expected: entry["sha256"],
                  actual: actual
                }
              }}}
          end
      end
    end)
  end

  defp verify_no_unmanifested(d, files) do
    on_disk =
      d
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, d))
      |> Enum.reject(&(&1 == @manifest_file))
      |> MapSet.new()

    case MapSet.difference(on_disk, MapSet.new(Map.keys(files))) |> Enum.sort() do
      [] ->
        :ok

      extra ->
        {:error, %{code: :sa2a_corpus_unmanifested_file, detail: extra}}
    end
  end

  # --- vectors -----------------------------------------------------------

  defp load_vectors(d, files) do
    files
    |> Map.keys()
    |> Enum.filter(&String.ends_with?(&1, ".expected.json"))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn rel, {:ok, acc} ->
      case load_vector(d, rel) do
        {:ok, vector} -> {:cont, {:ok, Map.put(acc, vector.name, vector)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp load_vector(d, rel) do
    with {:ok, raw} <- File.read(Path.join(d, rel)),
         {:ok, s} <- JSON.decode(raw),
         {:ok, admission} <- fetch_mapped(@admissions, s["expected"]["sa2a_admission"], rel),
         {:ok, conformance} <- fetch_mapped(@conformances, s["conformance"], rel),
         {:ok, refusal} <- decode_refusal(s["expected"]["refusal"], rel),
         {:ok, graph} <- File.read(Path.join(d, s["file"])) do
      {:ok,
       %Vector{
         name: s["vector"],
         file: s["file"],
         class: s["class"],
         rfc_sections: s["rfc_sections"] || [],
         description: s["description"],
         graph: graph,
         expected_admission: admission,
         expected_refusal: refusal,
         graph_digest: s["expected"]["graph_digest_blake3"],
         law_graph_digest: s["expected"]["law_graph_digest_blake3"],
         digest_must_equal_vector: s["expected"]["graph_digest_must_equal_vector"],
         digest_must_differ_from_vector: s["expected"]["graph_digest_must_differ_from_vector"],
         measured: s["measured_on_pinned_engine"] || %{},
         conformance: conformance,
         failure: s["failure"]
       }}
    else
      {:error, %{code: _} = err} ->
        {:error, err}

      {:error, reason} ->
        {:error, %{code: :sa2a_corpus_vector_invalid, detail: %{file: rel, reason: reason}}}
    end
  end

  defp decode_refusal(nil, _rel), do: {:ok, nil}

  defp decode_refusal(%{"code" => code} = refusal, rel) do
    case Map.fetch(@refusal_codes, code) do
      {:ok, atom} ->
        {:ok, %{code: atom, dialect: refusal["dialect"], severity: refusal["severity"]}}

      :error ->
        {:error,
         %{code: :sa2a_corpus_vector_invalid, detail: %{file: rel, unknown_refusal_code: code}}}
    end
  end

  defp decode_refusal(other, rel),
    do: {:error, %{code: :sa2a_corpus_vector_invalid, detail: %{file: rel, refusal: other}}}

  defp fetch_mapped(map, key, rel) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, %{code: :sa2a_corpus_vector_invalid, detail: %{file: rel, unknown: key}}}
    end
  end

  # --- fixed parts -------------------------------------------------------

  defp read_parts(d) do
    %{
      base: File.read!(Path.join(d, "base.ttl")),
      event: File.read!(Path.join(d, "event.ttl")),
      profile: File.read!(Path.join(d, "profile.ttl")),
      shapes: File.read!(Path.join(d, "shapes.shacl.ttl")),
      shapes_violations: File.read!(Path.join(d, "shapes.violations.shacl.ttl")),
      shapes_warnings: File.read!(Path.join(d, "shapes.warnings.shacl.ttl")),
      shex_schema: File.read!(Path.join(d, "schema.shex")),
      shape_map: File.read!(Path.join(d, "shape_map.json")),
      rules: File.read!(Path.join(d, "rules/denials.n3")),
      hooks: File.read!(Path.join(d, "hooks/admitted_hooks.ttl"))
    }
  end
end
