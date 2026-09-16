defmodule AshA2A.Semantic.TermRegistry do
  @moduledoc """
  The admitted public term index, and the S7.3 no-runtime-semantic-individualism
  fence.

  ## What the index actually is

  `from_cache/1` builds the index from `AshA2A.Semantic.OntologyCache` -- every
  document is digest-verified before it is parsed, and parsing uses the real
  `RDF.Turtle` reader from the `rdf` hex package. No RDF parsing, validation or
  canonicalization is hand-written in Elixir anywhere in this module: the terms
  are whatever the real public ontology documents actually declare.

  As shipped, the pinned cache holds the four real W3C vocabulary documents that
  are available fully offline (rdf, rdfs, owl, skos), so the index is a real
  term set (hundreds of real IRIs), not a fixture list.

  ## S7.3 -- no runtime semantic individualism

  > Under the Strict profile an agent MUST NOT invent a vocabulary term during
  > consequential operation and immediately use it as operational semantics.
  > Novel semantic candidates return to admission.

  `admit_operational_use/3` is that rule as an executable refusal:

    * an admitted term returns `{:ok, {:admitted, iri}}` -- it may be used as
      operational semantics;
    * a novel term under the `:strict` profile during a **consequential**
      operation is refused with `:runtime_semantic_individualism_refused`, and
      the refusal carries `return_to: :admission`;
    * a novel term in any non-consequential position returns
      `{:ok, {:candidate, iri}}` -- a candidate is explicitly *not* operational
      semantics, and it too carries `return_to: :admission`.

  There is no code path by which a term first seen at runtime becomes
  `:admitted` without going back through admission.
  """

  alias AshA2A.Semantic.{Iri, OntologyCache}

  @type refusal :: %{code: atom(), detail: String.t()}
  @type profile :: :strict | :permissive

  @enforce_keys [:terms, :namespaces, :profile]
  defstruct terms: %{}, namespaces: [], profile: :strict, sources: []

  @type t :: %__MODULE__{
          terms: %{optional(String.t()) => %{local_name: String.t(), labels: [String.t()]}},
          namespaces: [String.t()],
          profile: profile(),
          sources: [map()]
        }

  @rdfs_label "http://www.w3.org/2000/01/rdf-schema#label"
  @profiles [:strict, :permissive]

  @doc """
  Builds the index from the pinned, digest-verified local ontology cache.

  Every manifest entry is loaded through `AshA2A.Semantic.OntologyCache.load/2`,
  so a drifted cached document fails the build closed rather than silently
  contributing terms.

  ## Options

    * `:root` -- cache root (defaults to the shipped `priv` cache)
    * `:profile` -- `:strict` (default) or `:permissive`
    * `:only` -- restrict to these import IRIs
  """
  @spec from_cache(keyword()) :: {:ok, t()} | {:error, refusal()}
  def from_cache(opts \\ []) do
    root = Keyword.get(opts, :root, OntologyCache.default_root())
    profile = Keyword.get(opts, :profile, :strict)
    only = Keyword.get(opts, :only)

    with :ok <- check_profile(profile),
         {:ok, entries} <- OntologyCache.manifest(root) do
      entries
      |> then(fn list -> if only, do: Enum.filter(list, &(&1.iri in only)), else: list end)
      |> Enum.reduce_while({:ok, %__MODULE__{terms: %{}, namespaces: [], profile: profile}}, fn
        entry, {:ok, acc} ->
          case ingest(acc, entry, root) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, _} = error -> {:halt, error}
          end
      end)
      |> case do
        {:ok, registry} ->
          {:ok,
           %{
             registry
             | namespaces: Enum.sort(registry.namespaces),
               sources: Enum.sort_by(registry.sources, & &1.iri)
           }}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc "Number of admitted terms in the index."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{terms: terms}), do: map_size(terms)

  @doc "All admitted term IRIs, sorted."
  @spec iris(t()) :: [String.t()]
  def iris(%__MODULE__{terms: terms}), do: terms |> Map.keys() |> Enum.sort()

  @doc "True when the IRI is an admitted term."
  @spec member?(t(), term()) :: boolean()
  def member?(%__MODULE__{terms: terms}, iri) when is_binary(iri), do: Map.has_key?(terms, iri)
  def member?(%__MODULE__{}, _iri), do: false

  @doc "True when the IRI sits inside an admitted, pinned namespace."
  @spec in_admitted_namespace?(t(), term()) :: boolean()
  def in_admitted_namespace?(%__MODULE__{namespaces: namespaces}, iri) when is_binary(iri),
    do: Enum.any?(namespaces, &String.starts_with?(iri, &1))

  def in_admitted_namespace?(%__MODULE__{}, _iri), do: false

  @doc """
  S7.2 step 1: exact concept search over the admitted public sources.

  Matches a term whose local name or whose `rdfs:label` equals the concept
  label, comparing case-insensitively with separators normalized away (so
  `"prefLabel"`, `"pref label"` and `"Pref-Label"` all find `skos:prefLabel`).
  Results are sorted, so the sequence is deterministic.
  """
  @spec search_exact(t(), String.t()) :: [String.t()]
  def search_exact(%__MODULE__{terms: terms}, label) when is_binary(label) do
    key = normalize(label)

    terms
    |> Enum.filter(fn {_iri, %{local_name: local, labels: labels}} ->
      normalize(local) == key or Enum.any?(labels, &(normalize(&1) == key))
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc """
  S7.2 step 3: equivalent or composable public representation search.

  A deliberately conservative real search: a term qualifies when its normalized
  local name or label contains the normalized concept key, or vice versa.
  Exact matches are excluded (step 1 already reported those). Sorted.
  """
  @spec search_equivalent(t(), String.t()) :: [String.t()]
  def search_equivalent(%__MODULE__{terms: terms} = registry, label) when is_binary(label) do
    key = normalize(label)
    exact = MapSet.new(search_exact(registry, label))

    if String.length(key) < 3 do
      []
    else
      terms
      |> Enum.filter(fn {iri, %{local_name: local, labels: labels}} ->
        not MapSet.member?(exact, iri) and
          Enum.any?([local | labels], fn candidate ->
            normalized = normalize(candidate)

            normalized != "" and
              (String.contains?(normalized, key) or String.contains?(key, normalized))
          end)
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
    end
  end

  @doc """
  S7.3: decides whether an IRI may be used as operational semantics right now.

  ## Options

    * `:consequential?` -- defaults to `true`. A consequential operation is one
      crossing the `AshA2A.CommandBus` DO boundary.
    * `:profile` -- overrides the registry's profile for this call.
  """
  @spec admit_operational_use(t(), term(), keyword()) ::
          {:ok, {:admitted | :candidate, String.t()}} | {:error, map()}
  def admit_operational_use(%__MODULE__{} = registry, iri, opts \\ []) do
    profile = Keyword.get(opts, :profile, registry.profile)
    consequential? = Keyword.get(opts, :consequential?, true)

    with :ok <- check_profile(profile),
         {:ok, iri} <- Iri.validate(iri) do
      cond do
        member?(registry, iri) ->
          {:ok, {:admitted, iri}}

        profile == :strict and consequential? ->
          {:error,
           %{
             code: :runtime_semantic_individualism_refused,
             detail:
               "#{iri} is not an admitted vocabulary term. Under the Strict profile (RFC S7.3) " <>
                 "an agent MUST NOT invent a vocabulary term during consequential operation and " <>
                 "immediately use it as operational semantics; this candidate returns to admission.",
             return_to: :admission,
             candidate: iri,
             profile: profile
           }}

        true ->
          {:ok, {:candidate, iri}}
      end
    end
  end

  @doc """
  Convenience predicate: may this IRI be used as operational semantics?

  `true` only for `{:admitted, _}` -- a `:candidate` is never operational
  semantics.
  """
  @spec operational?(t(), term(), keyword()) :: boolean()
  def operational?(%__MODULE__{} = registry, iri, opts \\ []),
    do: match?({:ok, {:admitted, _}}, admit_operational_use(registry, iri, opts))

  # -- internals --------------------------------------------------------------

  defp ingest(acc, entry, root) do
    with {:ok, %{body: body, digest: digest}} <- OntologyCache.load(entry.iri, root: root),
         {:ok, graph} <- parse(body, entry) do
      terms =
        graph
        |> RDF.Graph.descriptions()
        |> Enum.reduce(acc.terms, fn description, terms ->
          subject = to_string(description.subject)

          if String.starts_with?(subject, entry.iri) and subject != entry.iri do
            Map.put(terms, subject, %{
              local_name: local_name(subject, entry.iri),
              labels: labels(description)
            })
          else
            terms
          end
        end)

      {:ok,
       %{
         acc
         | terms: terms,
           namespaces: [entry.iri | acc.namespaces],
           sources: [
             %{iri: entry.iri, version: entry.version, digest: digest, prefix: entry.prefix}
             | acc.sources
           ]
       }}
    end
  end

  defp parse(body, entry) do
    case RDF.Turtle.read_string(body) do
      {:ok, graph} ->
        {:ok, graph}

      {:error, reason} ->
        {:error,
         %{
           code: :ontology_unparseable,
           detail: "pinned document for #{entry.iri} did not parse as Turtle: #{inspect(reason)}"
         }}
    end
  end

  defp labels(description) do
    description
    |> RDF.Description.get(RDF.iri(@rdfs_label))
    |> List.wrap()
    |> Enum.map(fn
      %RDF.Literal{} = literal -> to_string(RDF.Literal.lexical(literal))
      other -> to_string(other)
    end)
  end

  defp local_name(iri, namespace) do
    iri
    |> String.replace_prefix(namespace, "")
    |> case do
      "" -> iri |> String.split(["#", "/"]) |> List.last()
      local -> local
    end
  end

  defp normalize(value) when is_binary(value) do
    value
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "")
  end

  defp normalize(_), do: ""

  defp check_profile(profile) when profile in @profiles, do: :ok

  defp check_profile(profile),
    do:
      {:error,
       %{
         code: :semantic_profile_unknown,
         detail: "profile must be one of #{inspect(@profiles)}, got #{inspect(profile)}"
       }}
end
