defmodule AshA2A.SA2A.Vector do
  @moduledoc """
  One conformance vector: a real directory of real RDF/SHACL/ShEx files under
  `priv/sa2a_conformance_vectors/`.

  Deliberately NOT `priv/sa2a_conformance/`: that directory belongs to
  `AshA2A.SA2A.Corpus`, a separately-built corpus with a different (flat,
  manifest-checked) layout whose loader refuses any file its `MANIFEST.json`
  does not list. The two formats shared one directory when their branches
  merged, and `Corpus.load!/1` correctly refused this module's per-vector
  subdirectories as unmanifested. Each format now owns its own directory.

  A vector is pure input. It carries no expected digest, because a digest
  baked into the corpus would only prove that a runtime agrees with whoever
  wrote the file down. The conformance claim is an equality *between two live
  runtimes*, so the corpus supplies the inputs and the court measures the
  agreement.

  ## Directory layout

      priv/sa2a_conformance_vectors/<id>/
        vector.json          -- metadata: id, title, intent, rfc_sections
        base.ttl             -- required; the graph under test
        profile.ttl          -- optional; semantic profile for validate_all/5
        shapes.shacl.ttl     -- optional; SHACL shapes graph
        schema.shex          -- optional; ShEx schema, ShExJ (JSON) encoded
        shapemap.txt         -- optional; ShEx shape map, [[node, shape], ..]
        event.ttl            -- optional; event delta for run_hooks/2

  Every optional file defaults to the empty string, which is exactly what the
  GraphLaw entry points treat as "not provided".

  The two ShEx encodings are not a choice: the wasm boundary reaches
  `validate_shex_native/3`, which does `serde_json::from_str` into GraphLaw's
  own ShExJ AST, so the crate's ShExC front end (`shexc_parser::parse_shexc`)
  is not callable from here, and `parse_shape_map/1` requires the JSON
  array-of-pairs form. Both were established by reading the engine after
  earlier revisions of `v007` were refused for using the compact syntaxes.
  """

  @enforce_keys [
    :id,
    :dir,
    :base,
    :profile,
    :shacl,
    :shex,
    :shape_map,
    :event,
    :metadata,
    :digest
  ]
  defstruct [:id, :dir, :base, :profile, :shacl, :shex, :shape_map, :event, :metadata, :digest]

  @type t :: %__MODULE__{
          id: String.t(),
          dir: String.t(),
          base: String.t(),
          profile: String.t(),
          shacl: String.t(),
          shex: String.t(),
          shape_map: String.t(),
          event: String.t(),
          metadata: map(),
          digest: String.t()
        }

  @files [
    {:base, "base.ttl"},
    {:profile, "profile.ttl"},
    {:shacl, "shapes.shacl.ttl"},
    {:shex, "schema.shex"},
    {:shape_map, "shapemap.txt"},
    {:event, "event.ttl"}
  ]

  @doc """
  Default corpus directory: `opts[:corpus_dir]`, then
  `:ash_a2a, :sa2a_corpus_dir`, then `priv/sa2a_conformance_vectors`.
  """
  @spec corpus_dir(keyword()) :: String.t()
  def corpus_dir(opts \\ []) do
    Keyword.get(opts, :corpus_dir) ||
      Application.get_env(:ash_a2a, :sa2a_corpus_dir) ||
      Path.join(:code.priv_dir(:ash_a2a) |> to_string(), "sa2a_conformance_vectors")
  end

  @doc """
  Loads every vector in the corpus directory, ordered by id.

  Returns `{:error, %{code: :sa2a_corpus_empty}}` when the directory holds no
  vectors: an empty corpus would make every assertion vacuously true, which
  is precisely the failure mode the court exists to prevent.
  """
  @spec load_all(keyword()) :: {:ok, [t()]} | {:error, map()}
  def load_all(opts \\ []) do
    dir = corpus_dir(opts)

    cond do
      not File.dir?(dir) ->
        {:error, %{code: :sa2a_corpus_not_found, path: dir}}

      true ->
        vectors =
          dir
          |> File.ls!()
          |> Enum.sort()
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.filter(&File.exists?(Path.join(&1, "base.ttl")))
          |> Enum.map(&load!/1)

        if vectors == [] do
          {:error,
           %{
             code: :sa2a_corpus_empty,
             path: dir,
             message: "no vectors found; an empty corpus cannot establish conformance"
           }}
        else
          {:ok, vectors}
        end
    end
  end

  @doc "Loads one vector directory. Raises if `base.ttl` is missing."
  @spec load!(String.t()) :: t()
  def load!(dir) do
    contents = Map.new(@files, fn {key, name} -> {key, read(dir, name)} end)

    metadata =
      case File.read(Path.join(dir, "vector.json")) do
        {:ok, raw} -> JSON.decode!(raw)
        {:error, _} -> %{}
      end

    id = Map.get(metadata, "id") || Path.basename(dir)

    struct!(
      __MODULE__,
      Map.merge(contents, %{
        id: id,
        dir: dir,
        metadata: metadata,
        digest: digest(id, contents)
      })
    )
  end

  @doc """
  The canonical manifest line for one vector: its id and the SHA-256 of every
  input file, in fixed field order. This is the string whose digest pins the
  vector's identity in the receipt.
  """
  @spec manifest_line(t()) :: String.t()
  def manifest_line(%__MODULE__{} = vector) do
    "#{vector.id}=#{vector.digest}"
  end

  @doc """
  The canonical corpus manifest: one `manifest_line/1` per vector, ordered by
  id, newline-terminated. Both runtimes hash this identical string, so a
  disagreement on `root_manifest_digest` can only be a runtime disagreement,
  never a corpus-ordering artifact.
  """
  @spec root_manifest([t()]) :: String.t()
  def root_manifest(vectors) do
    vectors
    |> Enum.sort_by(& &1.id)
    |> Enum.map_join("", &(manifest_line(&1) <> "\n"))
  end

  defp read(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end

  defp digest(id, contents) do
    payload =
      @files
      |> Enum.map_join("", fn {key, name} ->
        "#{name}=#{sha256(Map.fetch!(contents, key))}\n"
      end)

    sha256("id=#{id}\n" <> payload)
  end

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
