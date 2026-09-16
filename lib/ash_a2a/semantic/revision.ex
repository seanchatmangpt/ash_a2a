defmodule AshA2A.Semantic.Revision do
  @moduledoc """
  Immutable admitted artifacts, and compatibility declared separately from
  version numbering (RFC-SA2A-001 S45).

  Two rules, both enforced rather than described.

  ## 1. Admitted artifacts are immutable by semantic identity

  A revision's identity is `{semantic_id, calver}`; its content identity is a
  SHA-256 `content_digest` over the exact admitted bytes. `check_immutable/2`
  refuses a second artifact that reuses the same `{semantic_id, calver}` with
  different content: `:admitted_artifact_mutation_refused`. A change does not
  edit a revision -- it produces a new one, which is what `revise/3` returns
  (with `supersedes` pointing at the digest it replaces).

  ## 2. A newer CalVer MUST NOT be assumed compatible

  `compatible?/3` returns `{:ok, ...}` only when an explicit compatibility
  declaration names the other revision's `content_digest`. Ordering is never
  evidence: a strictly newer CalVer with no declaration returns
  `{:error, %{code: :compatibility_undeclared}}`, and the refusal says so in
  as many words. `compare_calver/2` exists so a caller can order revisions, and
  it deliberately returns only an ordering -- never a compatibility verdict.

  Compatibility is also directional and not inferred backwards: declaring that
  `2026.09.16` is compatible with `2026.08.01` says nothing about the reverse
  direction unless that too is declared.
  """

  alias AshA2A.Semantic.Iri

  @type refusal :: %{code: atom(), detail: String.t()}

  @enforce_keys [:semantic_id, :calver, :content_digest]
  defstruct [
    :semantic_id,
    :calver,
    :content_digest,
    :supersedes,
    :admitted_at,
    compatible_with: []
  ]

  @type t :: %__MODULE__{
          semantic_id: String.t(),
          calver: String.t(),
          content_digest: String.t(),
          supersedes: String.t() | nil,
          admitted_at: String.t() | nil,
          compatible_with: [String.t()]
        }

  @calver_pattern ~r/^(\d{4})\.(\d{1,2})(?:\.(\d{1,2}))?(?:[.\-+](.+))?$/

  @doc """
  Builds a revision for admitted content.

  `semantic_id` must be a valid IRI, `calver` must parse as CalVer, and
  `content` is hashed (SHA-256) to produce the immutable content identity.
  `:compatible_with` is an explicit, separate declaration -- it is never
  derived from `calver`.
  """
  @spec new(String.t(), String.t(), binary(), keyword()) :: {:ok, t()} | {:error, refusal()}
  def new(semantic_id, calver, content, opts \\ []) when is_binary(content) do
    with {:ok, semantic_id} <- Iri.validate(semantic_id),
         :ok <- check_calver(calver),
         {:ok, compatible_with} <- check_declarations(Keyword.get(opts, :compatible_with, [])) do
      {:ok,
       %__MODULE__{
         semantic_id: semantic_id,
         calver: calver,
         content_digest: digest(content),
         supersedes: Keyword.get(opts, :supersedes),
         admitted_at: Keyword.get(opts, :admitted_at),
         compatible_with: compatible_with
       }}
    end
  end

  @doc """
  Produces the NEW revision that a content change creates.

  Refuses to reuse the previous revision's CalVer for different content
  (`:admitted_artifact_mutation_refused`) -- that is the immutability rule, not
  a naming convention. The returned revision's `supersedes` is the previous
  revision's `content_digest`, and its `compatible_with` starts empty: a new
  revision is not compatible with its predecessor until that is declared.
  """
  @spec revise(t(), String.t(), binary(), keyword()) :: {:ok, t()} | {:error, refusal()}
  def revise(%__MODULE__{} = previous, calver, content, opts \\ []) when is_binary(content) do
    with {:ok, next} <-
           new(
             previous.semantic_id,
             calver,
             content,
             Keyword.put(opts, :supersedes, previous.content_digest)
           ),
         :ok <- check_immutable(previous, next) do
      {:ok, next}
    end
  end

  @doc """
  Immutability check between an already-admitted revision and an incoming one.

  Same semantic identity + same CalVer + different content is refused. Same
  identity, same CalVer and byte-identical content is `:ok` (a re-admission of
  the same artifact is not a mutation).
  """
  @spec check_immutable(t(), t()) :: :ok | {:error, refusal()}
  def check_immutable(%__MODULE__{} = existing, %__MODULE__{} = incoming) do
    cond do
      existing.semantic_id != incoming.semantic_id ->
        :ok

      existing.calver != incoming.calver ->
        :ok

      existing.content_digest == incoming.content_digest ->
        :ok

      true ->
        {:error,
         %{
           code: :admitted_artifact_mutation_refused,
           detail:
             "#{existing.semantic_id} @ #{existing.calver} is already admitted with content " <>
               "#{existing.content_digest}; admitted artifacts are immutable by semantic identity " <>
               "(RFC S45). Content #{incoming.content_digest} must be admitted as a NEW revision, " <>
               "not under the same version."
         }}
    end
  end

  @doc """
  Compatibility between two revisions -- declared, never inferred.

  Returns `{:ok, %{compatible: true, basis: :declared}}` only when `to` (or, if
  `opts[:bidirectional]` is true, either side) explicitly declares the other's
  `content_digest` in `compatible_with`.

  A strictly newer CalVer with no declaration is
  `{:error, %{code: :compatibility_undeclared}}`. That is the point of the
  rule: version ordering carries no compatibility information.
  """
  @spec compatible?(t(), t(), keyword()) :: {:ok, map()} | {:error, refusal()}
  def compatible?(%__MODULE__{} = from, %__MODULE__{} = to, opts \\ []) do
    bidirectional? = Keyword.get(opts, :bidirectional, false)

    declared? =
      from.content_digest in to.compatible_with or
        (bidirectional? and to.content_digest in from.compatible_with)

    cond do
      from.semantic_id != to.semantic_id ->
        {:error,
         %{
           code: :compatibility_cross_identity,
           detail:
             "compatibility is only meaningful within one semantic identity; " <>
               "#{from.semantic_id} and #{to.semantic_id} are different artifacts -- use " <>
               "AshA2A.Semantic.MappingRegistry for cross-identity relationships"
         }}

      declared? ->
        {:ok, %{compatible: true, basis: :declared, from: from.calver, to: to.calver}}

      true ->
        {:error,
         %{
           code: :compatibility_undeclared,
           detail:
             "#{to.semantic_id} @ #{to.calver} does not declare compatibility with " <>
               "#{from.calver} (#{from.content_digest}). RFC S45 requires compatibility to be " <>
               "declared separately from version numbering: " <>
               "#{ordering_note(from.calver, to.calver)}",
           from: from.calver,
           to: to.calver,
           ordering: compare_calver(from.calver, to.calver)
         }}
    end
  end

  @doc """
  Orders two CalVer strings.

  Returns `:lt`, `:eq`, `:gt` or `{:error, refusal}`. This is an ordering and
  nothing more -- it deliberately says nothing about compatibility.
  """
  @spec compare_calver(String.t(), String.t()) :: :lt | :eq | :gt | {:error, refusal()}
  def compare_calver(a, b) do
    with {:ok, parsed_a} <- parse_calver(a),
         {:ok, parsed_b} <- parse_calver(b) do
      cond do
        parsed_a < parsed_b -> :lt
        parsed_a > parsed_b -> :gt
        true -> :eq
      end
    end
  end

  @doc "SHA-256 hex digest of admitted content bytes."
  @spec digest(binary()) :: String.t()
  def digest(content) when is_binary(content),
    do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  # -- internals --------------------------------------------------------------

  defp ordering_note(from, to) do
    case compare_calver(from, to) do
      :gt ->
        "#{to} is OLDER than #{from}, which is still not evidence either way"

      :lt ->
        "#{to} is newer than #{from}, and a newer CalVer MUST NOT be assumed compatible"

      :eq ->
        "both revisions carry CalVer #{to}"

      {:error, _} ->
        "neither ordering nor compatibility can be established"
    end
  end

  defp check_calver(calver) when is_binary(calver) do
    case parse_calver(calver) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp check_calver(calver),
    do:
      {:error,
       %{code: :calver_invalid, detail: "CalVer must be a string, got #{inspect(calver)}"}}

  defp parse_calver(value) when is_binary(value) do
    case Regex.run(@calver_pattern, value) do
      [_full, year, minor] ->
        {:ok, {String.to_integer(year), String.to_integer(minor), 0}}

      [_full, year, minor, ""] ->
        {:ok, {String.to_integer(year), String.to_integer(minor), 0}}

      [_full, year, minor, micro | _] ->
        {:ok, {String.to_integer(year), String.to_integer(minor), to_int(micro)}}

      nil ->
        {:error,
         %{
           code: :calver_invalid,
           detail: "#{inspect(value)} is not CalVer (expected YYYY.MM or YYYY.MM.MICRO)"
         }}
    end
  end

  defp parse_calver(value),
    do:
      {:error, %{code: :calver_invalid, detail: "CalVer must be a string, got #{inspect(value)}"}}

  defp to_int(""), do: 0
  defp to_int(value), do: String.to_integer(value)

  defp check_declarations(list) when is_list(list) do
    case Enum.reject(list, &(is_binary(&1) and &1 != "")) do
      [] ->
        {:ok, Enum.map(list, &String.downcase/1)}

      invalid ->
        {:error,
         %{
           code: :compatibility_declaration_invalid,
           detail:
             ":compatible_with must list content digests of the revisions this one is declared " <>
               "compatible with, got invalid entries #{inspect(invalid)}"
         }}
    end
  end

  defp check_declarations(other),
    do:
      {:error,
       %{
         code: :compatibility_declaration_invalid,
         detail: ":compatible_with must be a list of content digests, got #{inspect(other)}"
       }}
end
