defmodule AshA2A.Semantic.CanonicalTermDigest do
  @moduledoc """
  Deterministic, inspectable canonical encoding + digest for semantic
  planning structures (RFC-SA2A-001 S23/S24/S26/S27).

  Not to be confused with `AshA2A.Semantic.CanonicalDigest`, which is the
  RFC S12 *RDF graph* identity path (`Ontology -> serialize -> verify ->
  praxis-graphlaw graph_hash`). This module digests plain Elixir planning
  *terms*; that one digests RDF graphs through the native engine. The two
  answer different questions and their digests are not interchangeable
  (`"sha256:<hex>"` here vs a bare 64-hex GraphLaw digest there).

  ## Why this exists rather than `:erlang.term_to_binary/1`

  Every pre-existing fingerprint in `AshA2A.Semantic.*` (`Ontology`,
  `PlanningIR`, `ExecutionPackage`, `Planning.Candidate`) hashes
  `:erlang.term_to_binary(term)`. That is deterministic *within one BEAM
  release for one term shape*, but it is not a canonical form: it is an
  internal serialization whose map-key ordering and small/large-map
  representation are properties of the runtime, not of the value. For the
  planning-projection work (S27's "a projection whose recomputed digest
  disagrees with its recorded source is refused") the digest has to be a
  function of the *value*, reproducible by reading this module, so two maps
  that differ only in insertion order digest identically.

  This module is NOT an RDF canonicalization. It does not implement RDFC-1.0
  and must never be described as doing so -- canonical graph identity for
  RFC S12 belongs to `praxis-graphlaw`'s real `graph_hash` (oxrdf
  `rdfc-10`), never to Elixir. This encodes plain Elixir planning terms
  (maps, lists, tuples, atoms, binaries, numbers) only.

  ## The encoding

    * map (non-struct) -> `{k=v,...}` with entries **sorted** by encoded key
      (map key order is not semantic)
    * struct            -> `%Module{...}` over its non-`__struct__` fields,
      same sorted-map rule
    * list              -> `[a,b,c]` in **declared order** (plan step order
      IS semantic -- never sorted)
    * tuple             -> `(a,b,c)` in declared order (the
      `AshA2A.HddlOperator.fact()` `{predicate, args}` shape)
    * atom              -> `:name`, `nil` -> `nil`, booleans -> `:true`/`:false`
    * binary            -> `"..."` with `\\` and `"` escaped, so
      `["a", "b"]` and `["a\\",\\"b"]` cannot collide
    * integer/float     -> their canonical text form

  `digest/1` returns `"sha256:" <> lowercase_hex`, the exact shape
  `AshA2A.SemanticSubject.new/1` already enforces, so a digest produced here
  is directly usable as a `graph_digest`/`projection_digest`/
  `manufacturer_digest` without reformatting.
  """

  @doc """
  Canonical iodata encoding of `term`. Exposed (not private) because a
  refusal that says "digest mismatch" is only debuggable if the exact bytes
  that were hashed can be inspected.
  """
  @spec encode(term()) :: iodata()
  def encode(%_struct{} = struct) do
    module = struct.__struct__

    fields =
      struct
      |> Map.from_struct()
      |> encode_pairs()

    ["%", inspect(module), "{", fields, "}"]
  end

  def encode(map) when is_map(map), do: ["{", encode_pairs(map), "}"]

  def encode(list) when is_list(list) do
    ["[", list |> Enum.map(&encode/1) |> Enum.intersperse(","), "]"]
  end

  def encode(tuple) when is_tuple(tuple) do
    ["(", tuple |> Tuple.to_list() |> Enum.map(&encode/1) |> Enum.intersperse(","), ")"]
  end

  def encode(nil), do: "nil"
  def encode(atom) when is_atom(atom), do: [":", Atom.to_string(atom)]
  def encode(binary) when is_binary(binary), do: ["\"", escape(binary), "\""]
  def encode(integer) when is_integer(integer), do: Integer.to_string(integer)
  def encode(float) when is_float(float), do: Float.to_string(float)

  @doc """
  `"sha256:" <> lowercase_hex` over `encode/1`'s canonical bytes.
  """
  @spec digest(term()) :: String.t()
  def digest(term) do
    hex =
      term
      |> encode()
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "sha256:" <> hex
  end

  defp encode_pairs(map) do
    map
    |> Enum.map(fn {key, value} ->
      [IO.iodata_to_binary(encode(key)), "=", IO.iodata_to_binary(encode(value))]
    end)
    |> Enum.sort()
    |> Enum.intersperse(",")
  end

  defp escape(binary) do
    binary
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
