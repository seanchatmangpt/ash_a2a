defmodule AshA2A.Semantic.OntologyCache do
  @moduledoc """
  Local, pinned, content-addressed ontology import cache (RFC-SA2A-001 S46).

  S46 requires ontology imports to be **explicit, version-pinned,
  content-addressed where possible, canonicalized, admitted, and locally
  cacheable**, and requires that production admission **not dereference
  arbitrary mutable web resources during execution**.

  This module is the enforcement of that rule, not a description of it:

    * `admit_import/1` refuses an import declaration that is not explicit and
      version-pinned (`:ontology_import_unpinned`). `"latest"`, `""` and `nil`
      are all refused pins.
    * `dereference/1` **always** refuses an `http`/`https` fetch
      (`:ontology_remote_dereference_refused`). There is no network code path
      in this module at all; the refusal is the code path.
    * `load/2` re-computes the SHA-256 of the cached bytes on every load and
      compares it against the digest pinned in `manifest.json`. A mismatch
      fails closed with `:ontology_digest_drift` -- the drifted bytes are never
      returned to the caller.
    * An IRI absent from the manifest is `:ontology_cache_miss`. The cache
      never falls back to a fetch.
    * `manifest.json` itself must hash to an admitted digest
      (`admitted_manifest_digests/0`, pinned in source outside the datastore),
      or every read fails closed with `:ontology_manifest_unadmitted`.

  ## Canonicalization is pinned, never recomputed here

  `canonical_digest` is a *pinned manifest field*; this cache never recomputes
  it. RFC S12 canonical graph identity (RDFC-1.0) is
  `AshA2A.Semantic.CanonicalGraph`, over RDF.ex -- not `praxis-graphlaw`'s
  `graph_hash/1` wasm export, which is not RDFC-1.0 (the engine's `oxrdf`
  `rdfc-10` canonicalization is not wired to any wasm export; see
  `docs/explanation/canonical-graph-identity.md`). This repository implements
  no canonicalization algorithm of its own. When an entry carries no pinned
  `canonical_digest`, `canonical_digest/2` returns a typed
  `:canonicalization_not_local` refusal naming the identity primitive rather
  than substituting a locally computed pseudo-canonical value. The four seeded
  entries are honestly marked `"canonicalization": "not_canonicalized"`.

  The `content_digest` check is separate and fully real: it is a byte-identity
  check over the exact cached octets and is what makes the cache fail closed.
  """

  alias AshA2A.Semantic.Iri

  @type refusal :: %{code: atom(), detail: String.t()}

  @type entry :: %{
          iri: String.t(),
          prefix: String.t() | nil,
          version: String.t(),
          object: String.t(),
          content_digest: String.t(),
          byte_size: non_neg_integer(),
          media_type: String.t(),
          canonical_digest: String.t() | nil,
          canonicalization: String.t(),
          provenance: String.t(),
          admitted_at: String.t(),
          compatibility: map()
        }

  @digest_algorithm :sha256

  # RFC-SA2A-002 §78 (SA2A-CANONMUT-002): the manifest lives inside the datastore
  # it pins, so a direct write that rewrites a document AND its manifest entry
  # would re-pin itself. The admitted manifest bytes are therefore pinned here,
  # outside the datastore, in reviewed source: admitting a new cache manifest is
  # a code change, never a file write. A copy of the admitted cache at another
  # root carries the same bytes and still loads.
  @admitted_manifest_sha256 ["7a98d50e98fb533c4c3b3f2d125b89d6d764263bb1b75ef905856c14ca781c1e"]
  @unpinned_versions ["", "latest", "LATEST", "head", "HEAD", "main", "master", "*"]

  @doc "Default on-disk cache root shipped with the application."
  @spec default_root() :: String.t()
  def default_root, do: Path.join(:code.priv_dir(:ash_a2a), "semantic/ontology_cache")

  @doc """
  Reads and validates the pinned manifest.

  Returns `{:ok, [entry]}` or a typed refusal. Every entry must carry an IRI
  that passes `AshA2A.Semantic.Iri.validate/1` and a non-placeholder version
  pin -- an unpinned manifest entry is refused at read time, not at use time.
  """
  @spec manifest(String.t()) :: {:ok, [entry()]} | {:error, refusal()}
  def manifest(root \\ default_root()) do
    path = Path.join(root, "manifest.json")

    with {:ok, raw} <- read_file(path),
         :ok <- admitted_manifest(raw, path),
         {:ok, decoded} <- decode_json(raw, path),
         {:ok, list} <- fetch_entries(decoded, path) do
      Enum.reduce_while(list, {:ok, []}, fn raw_entry, {:ok, acc} ->
        case normalize_entry(raw_entry) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Looks up one pinned entry by import IRI (and optionally by exact version).

  `opts[:version]` pins the lookup: a manifest entry whose version differs is
  `:ontology_version_mismatch`, never a silent newest-wins.
  """
  @spec entry(String.t(), keyword()) :: {:ok, entry()} | {:error, refusal()}
  def entry(iri, opts \\ []) do
    root = Keyword.get(opts, :root, default_root())

    with {:ok, entries} <- manifest(root) do
      case Enum.find(entries, &(&1.iri == iri)) do
        nil ->
          {:error,
           refusal(
             :ontology_cache_miss,
             "no pinned manifest entry for #{inspect(iri)}; remote dereference is refused " <>
               "(RFC S46) -- add an explicit, version-pinned, content-addressed entry instead"
           )}

        found ->
          case Keyword.get(opts, :version) do
            nil ->
              {:ok, found}

            version when version == found.version ->
              {:ok, found}

            version ->
              {:error,
               refusal(
                 :ontology_version_mismatch,
                 "requested version #{inspect(version)} but manifest pins #{inspect(found.version)} for #{iri}"
               )}
          end
      end
    end
  end

  @doc """
  Loads the cached bytes for an import IRI, re-verifying the pinned digest.

  Fails closed: on any digest mismatch the bytes are discarded and
  `:ontology_digest_drift` is returned with both digests in the detail.
  """
  @spec load(String.t(), keyword()) ::
          {:ok, %{entry: entry(), body: String.t(), digest: String.t()}} | {:error, refusal()}
  def load(iri, opts \\ []) do
    root = Keyword.get(opts, :root, default_root())

    result =
      with {:ok, entry} <- entry(iri, Keyword.put(opts, :root, root)),
           object_path = Path.join(root, entry.object),
           {:ok, body} <- read_object(object_path, entry),
           :ok <- verify_size(body, entry, object_path),
           {:ok, digest} <- verify_digest(body, entry, object_path) do
        {:ok, %{entry: entry, body: body, digest: digest}}
      end

    # RFC-SA2A-002 §12 attempt evidence, emitted where the load decision is made.
    :telemetry.execute([:ash_a2a, :semantic, :ontology_cache, :load], %{}, %{
      outcome: if(match?({:ok, _}, result), do: :loaded, else: :refused),
      code: with({:error, %{code: code}} <- result, do: code, else: (_ -> nil)),
      iri: iri
    })

    result
  end

  @doc """
  Returns the pinned canonical (RDFC-1.0) digest for an entry.

  Never computes one locally. An entry with no pinned canonical digest returns
  a `:canonicalization_not_local` refusal naming the RFC S12 identity
  primitive, `AshA2A.Semantic.CanonicalGraph`, and stating that
  `praxis-graphlaw`'s wasm `graph_hash/1` is not an RDFC-1.0 substitute.
  """
  @spec canonical_digest(String.t(), keyword()) :: {:ok, String.t()} | {:error, refusal()}
  def canonical_digest(iri, opts \\ []) do
    with {:ok, entry} <- entry(iri, opts) do
      case entry.canonical_digest do
        digest when is_binary(digest) and digest != "" ->
          {:ok, digest}

        _ ->
          {:error,
           refusal(
             :canonicalization_not_local,
             "no canonical_digest pinned for #{iri}; this cache never recomputes graph identity. " <>
               "RFC S12 RDFC-1.0 identity is AshA2A.Semantic.CanonicalGraph " <>
               "(RDFC-1.0/SHA-256/n-quads-sorted); praxis-graphlaw's wasm export graph_hash/1 " <>
               "is not RDFC-1.0 and is no substitute -- pin the digest in manifest.json"
           )}
      end
    end
  end

  @doc """
  Admits an ontology import declaration (RFC S46).

  Requires an explicit IRI and an explicit, non-placeholder version pin.
  Optionally requires the declared content digest to match what is actually
  pinned in the manifest.
  """
  @spec admit_import(map(), keyword()) :: {:ok, entry()} | {:error, refusal()}
  def admit_import(declaration, opts \\ [])

  def admit_import(%{} = declaration, opts) do
    iri = declaration[:iri] || declaration["iri"]
    version = declaration[:version] || declaration["version"]
    declared_digest = declaration[:content_digest] || declaration["content_digest"]

    with {:ok, iri} <- Iri.validate(iri),
         :ok <- require_pin(iri, version),
         {:ok, entry} <- entry(iri, Keyword.put(opts, :version, version)),
         :ok <- match_declared_digest(entry, declared_digest),
         {:ok, _loaded} <- load(iri, Keyword.put(opts, :version, version)) do
      {:ok, entry}
    end
  end

  def admit_import(other, _opts),
    do:
      {:error,
       refusal(
         :ontology_import_malformed,
         "import declaration must be a map with :iri and :version, got #{inspect(other)}"
       )}

  @doc """
  The one network-shaped entry point, which always refuses.

  Present so that "production admission must not dereference arbitrary mutable
  web resources" is an executable refusal rather than a convention.
  """
  @spec dereference(String.t()) :: {:error, refusal()}
  def dereference(iri) when is_binary(iri) do
    {:error,
     refusal(
       :ontology_remote_dereference_refused,
       "refused to dereference #{inspect(iri)} during admission (RFC S46): imports must be " <>
         "resolved from the local pinned content-addressed cache, never fetched at execution time"
     )}
  end

  @doc """
  Honest backing report for `AshA2A.Semantic.Vocabulary`'s registered prefixes.

  For each registered prefix, reports whether the cache actually holds a real
  local ontology *document* for its namespace, or whether the prefix is
  currently only a prefix string with no document behind it.
  """
  @spec prefix_backing_report(keyword()) :: [
          %{prefix: String.t(), iri: String.t(), backing: :local_document | :prefix_only}
        ]
  def prefix_backing_report(opts \\ []) do
    entries =
      case manifest(Keyword.get(opts, :root, default_root())) do
        {:ok, entries} -> entries
        {:error, _} -> []
      end

    backed = MapSet.new(entries, & &1.iri)

    AshA2A.Semantic.Vocabulary.prefixes()
    |> Enum.map(fn {prefix, iri} ->
      backing = if MapSet.member?(backed, iri), do: :local_document, else: :prefix_only
      %{prefix: prefix, iri: iri, backing: backing}
    end)
    |> Enum.sort_by(& &1.prefix)
  end

  @doc "SHA-256 digests of the cache manifests admitted as canonical vocabulary datastores."
  @spec admitted_manifest_digests() :: [String.t()]
  def admitted_manifest_digests, do: @admitted_manifest_sha256

  @doc false
  def __sa2a_refusal_codes__, do: %{ontology_manifest_unadmitted: :refused_meta_rigor}

  @doc "SHA-256 hex digest of the given bytes."
  @spec digest(binary()) :: String.t()
  def digest(bytes) when is_binary(bytes),
    do: @digest_algorithm |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # -- internals --------------------------------------------------------------

  defp read_file(path) do
    case File.read(path) do
      {:ok, raw} ->
        {:ok, raw}

      {:error, reason} ->
        {:error, refusal(:ontology_manifest_unreadable, "#{path}: #{:file.format_error(reason)}")}
    end
  end

  defp admitted_manifest(raw, path) do
    actual = digest(raw)

    if actual in @admitted_manifest_sha256 do
      :ok
    else
      {:error,
       refusal(
         :ontology_manifest_unadmitted,
         "#{path} has sha256 #{actual}, which is not an admitted cache manifest " <>
           "(#{Enum.join(@admitted_manifest_sha256, ", ")}); a manifest rewritten in place does " <>
           "not re-pin its own documents -- failing closed"
       )}
    end
  end

  defp decode_json(raw, path) do
    case Jason.decode(raw) do
      {:ok, %{} = decoded} ->
        {:ok, decoded}

      {:ok, other} ->
        {:error, refusal(:ontology_manifest_malformed, "#{path}: #{inspect(other)}")}

      {:error, error} ->
        {:error, refusal(:ontology_manifest_malformed, "#{path}: #{inspect(error)}")}
    end
  end

  defp fetch_entries(%{"entries" => entries}, _path) when is_list(entries), do: {:ok, entries}

  defp fetch_entries(_decoded, path),
    do: {:error, refusal(:ontology_manifest_malformed, "#{path}: missing \"entries\" list")}

  defp normalize_entry(%{} = raw) do
    iri = raw["iri"]
    version = raw["version"]

    with {:ok, iri} <- Iri.validate(iri),
         :ok <- require_pin(iri, version),
         :ok <- require_binary(raw["object"], iri, "object"),
         :ok <- require_binary(raw["content_digest"], iri, "content_digest") do
      {:ok,
       %{
         iri: iri,
         prefix: raw["prefix"],
         version: version,
         object: raw["object"],
         content_digest: String.downcase(raw["content_digest"]),
         byte_size: raw["byte_size"],
         media_type: raw["media_type"] || "text/turtle",
         canonical_digest: raw["canonical_digest"],
         canonicalization: raw["canonicalization"] || "not_canonicalized",
         provenance: raw["provenance"] || "",
         admitted_at: raw["admitted_at"] || "",
         compatibility: raw["compatibility"] || %{}
       }}
    end
  end

  defp normalize_entry(other),
    do:
      {:error, refusal(:ontology_manifest_malformed, "entry is not an object: #{inspect(other)}")}

  defp require_pin(iri, version) when is_binary(version) do
    if version in @unpinned_versions do
      {:error,
       refusal(
         :ontology_import_unpinned,
         "import of #{iri} declares version #{inspect(version)}, which is a moving pointer, " <>
           "not a pin (RFC S46 requires version-pinned imports)"
       )}
    else
      :ok
    end
  end

  defp require_pin(iri, version),
    do:
      {:error,
       refusal(
         :ontology_import_unpinned,
         "import of #{iri} declares no version (#{inspect(version)}); RFC S46 requires an " <>
           "explicit version pin"
       )}

  defp require_binary(value, _iri, _field) when is_binary(value) and value != "", do: :ok

  defp require_binary(value, iri, field),
    do:
      {:error,
       refusal(
         :ontology_manifest_malformed,
         "entry #{iri} has invalid #{field}: #{inspect(value)}"
       )}

  defp read_object(path, entry) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         refusal(
           :ontology_object_missing,
           "pinned object for #{entry.iri} is missing at #{path}: #{:file.format_error(reason)}"
         )}
    end
  end

  defp verify_size(body, %{byte_size: expected} = entry, path) when is_integer(expected) do
    actual = byte_size(body)

    if actual == expected do
      :ok
    else
      {:error,
       refusal(
         :ontology_digest_drift,
         "byte_size drift for #{entry.iri} at #{path}: pinned #{expected}, on disk #{actual}"
       )}
    end
  end

  defp verify_size(_body, _entry, _path), do: :ok

  defp verify_digest(body, entry, path) do
    actual = digest(body)

    if actual == entry.content_digest do
      {:ok, actual}
    else
      {:error,
       refusal(
         :ontology_digest_drift,
         "sha256 drift for #{entry.iri} at #{path}: pinned #{entry.content_digest}, " <>
           "on disk #{actual} -- failing closed, drifted bytes are not returned"
       )}
    end
  end

  defp match_declared_digest(_entry, nil), do: :ok

  defp match_declared_digest(entry, declared) when is_binary(declared) do
    if String.downcase(declared) == entry.content_digest do
      :ok
    else
      {:error,
       refusal(
         :ontology_digest_drift,
         "import of #{entry.iri} declares content_digest #{declared} but the manifest pins " <>
           "#{entry.content_digest}"
       )}
    end
  end

  defp refusal(code, detail), do: %{code: code, detail: detail}
end
