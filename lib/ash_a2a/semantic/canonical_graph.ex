defmodule AshA2A.Semantic.CanonicalGraph do
  @moduledoc """
  The single authoritative RFC-SA2A-001 S12 canonical graph identity primitive
  for this repository.

  ## The algorithm, named precisely (the Root Manifest pins this)

  `canonical_digest/1` is exactly:

  1. Parse the input as RDF 1.1 Turtle (`RDF.Turtle.read_string/1`). A parse
     failure is a typed `{:error, {:parse_error, message}}` -- never a digest.
  2. Canonicalize the resulting graph with **RDFC-1.0**
     (RDF Dataset Canonicalization 1.0, W3C), as implemented by
     `RDF.Canonicalization` in `:rdf` (RDF.ex) 3.0.
  3. Serialize the canonical graph to **N-Quads sorted by Unicode code point
     order** (`RDF.NQuads.write_string!(sort: true)`).
  4. Hash that serialization with **SHA-256** and render it as lowercase hex.

  Steps 2-4 are `RDF.Graph.canonical_hash/1`; this module owns steps 0-1 (the
  encoding guard and the typed parse-failure contract) and the naming/pinning
  surface (`algorithm/0`, `hash_function/0`, `algorithm_id/0`).

  Note that RDFC-1.0 *also* uses SHA-256 internally, for its blank-node
  first-degree/n-degree quad hashes. That internal use and the step-4 digest
  hash are separate knobs in RDF.ex; this module pins both to their defaults
  and does not expose an override, because an S12 identity that can be
  reparameterized at the call site is not an identity.

  ## Why not the GraphLaw wasm export

  `graph_hash` in the vendored praxis-graphlaw wasm law package is **not**
  RDFC-1.0 and must not be described as such. Measured against
  praxis-graphlaw v26.7.5:

    * it IS invariant under prefix relabeling and triple reordering;
    * it is **NOT** invariant under blank-node relabeling;
    * on unparseable input it returns the **empty-graph digest**
      (`af1349b9...`, BLAKE3 of the empty string) rather than an error, so a
      garbage document and an empty document are indistinguishable in a
      receipt.

  Both properties are disqualifying for a canonical graph identity, so S12
  identity lives here, in-BEAM, on RDF.ex. GraphLaw keeps S14 ShEx, S15 SHACL,
  S16 Datalog, S17 N3 and S18 SPARQL, where nothing else in reach comes close.
  See `docs/explanation/canonical-graph-identity.md` for the full measurement
  record, including the real digests.

  RDF.ex is used here for **canonicalization and serialization only**. No
  validation and no reasoning is performed in Elixir; that stays in GraphLaw.

  ## Failing closed

  Every failure mode returns a typed `{:error, reason}`; none of them returns a
  digest. In particular a non-UTF-8 binary is rejected *before* it reaches any
  parser, because the downstream wasm law package marshals its argument as a
  Rust `&str` and a single invalid byte is not a recoverable condition there.

      iex> AshA2A.Semantic.CanonicalGraph.canonical_digest("@@@ not turtle")
      {:error, {:parse_error, "Turtle scanner error on line 1: {:illegal, ~c\\"@@\\"}"}}

      iex> AshA2A.Semantic.CanonicalGraph.canonical_digest(<<0xFF>>)
      {:error, {:invalid_encoding, 0}}

      iex> ttl = "@prefix ex: <http://example.org/> .\\nex:a ex:p ex:b .\\nex:b ex:p ex:c .\\n"
      iex> AshA2A.Semantic.CanonicalGraph.canonical_digest(ttl)
      {:ok, "09be9b797c5854a65e9568cbfeb7a9435e8ce690bb8c67a299ac7e7c3b4e2efa"}

  Blank-node relabeling does not change the identity, which is the whole point:

      iex> a = "@prefix ex: <http://example.org/> .\\nex:a ex:p _:b1 .\\n_:b1 ex:p ex:c .\\n"
      iex> b = "@prefix ex: <http://example.org/> .\\nex:a ex:p _:zzz9 .\\n_:zzz9 ex:p ex:c .\\n"
      iex> AshA2A.Semantic.CanonicalGraph.canonical_digest(a) ==
      ...>   AshA2A.Semantic.CanonicalGraph.canonical_digest(b)
      true
  """

  @algorithm "RDFC-1.0"
  @hash_function "SHA-256"
  @serialization "application/n-quads; sorted=code-point"
  @input_media_type "text/turtle"

  @typedoc """
  Accepted S12 input: a UTF-8 Turtle document, or an already-parsed
  `RDF.Graph`.
  """
  @type input :: String.t() | RDF.Graph.t()

  @typedoc """
  Every way this module refuses to produce a digest.

    * `{:invalid_encoding, byte_offset}` -- the binary is not valid UTF-8; the
      offset is the index of the first invalid byte.
    * `{:parse_error, message}` -- the document is not well-formed Turtle;
      the message is RDF.ex's own, propagated verbatim.
    * `{:unsupported_input, description}` -- the term is neither a binary nor
      an `RDF.Graph`.
  """
  @type error ::
          {:invalid_encoding, non_neg_integer()}
          | {:parse_error, String.t()}
          | {:unsupported_input, String.t()}

  @doc """
  The canonicalization algorithm this module implements, by its W3C name.
  """
  @spec algorithm() :: String.t()
  def algorithm, do: @algorithm

  @doc """
  The hash function applied to the canonical serialization.
  """
  @spec hash_function() :: String.t()
  def hash_function, do: @hash_function

  @doc """
  The canonical serialization form that is hashed.
  """
  @spec serialization() :: String.t()
  def serialization, do: @serialization

  @doc """
  The full identity of the S12 primitive, as a single pinnable string.

  This is the value a Root Manifest should record, so that a receipt naming an
  S12 digest also names what produced it.

      iex> AshA2A.Semantic.CanonicalGraph.algorithm_id()
      "RDFC-1.0/SHA-256/n-quads-sorted"
  """
  @spec algorithm_id() :: String.t()
  def algorithm_id, do: "#{@algorithm}/#{@hash_function}/n-quads-sorted"

  @doc """
  The media type of the textual input form accepted by `canonical_digest/1`.
  """
  @spec input_media_type() :: String.t()
  def input_media_type, do: @input_media_type

  @doc """
  Returns the RDFC-1.0 canonical digest of `input`, or a typed error.

  See the module documentation for the exact algorithm and the failure
  contract. This function never returns a digest for input it could not
  parse, and never returns a digest for a non-UTF-8 binary.
  """
  @spec canonical_digest(input()) :: {:ok, String.t()} | {:error, error()}
  def canonical_digest(input) do
    with {:ok, graph} <- to_graph(input) do
      {:ok, RDF.Graph.canonical_hash(graph)}
    end
  end

  @doc """
  Bang variant of `canonical_digest/1`.

  Raises `ArgumentError` carrying the typed reason rather than returning a
  digest for input that has none.
  """
  @spec canonical_digest!(input()) :: String.t()
  def canonical_digest!(input) do
    case canonical_digest(input) do
      {:ok, digest} ->
        digest

      {:error, reason} ->
        raise ArgumentError, "no canonical graph identity for input: #{describe(reason)}"
    end
  end

  @doc """
  Returns the RDFC-1.0 canonical N-Quads serialization of `input` -- the exact
  byte string that `canonical_digest/1` hashes.

  This is the interchange form: it is what a second engine must be handed if
  the two are to be compared on canonical form rather than on the accident of
  a particular concrete syntax.
  """
  @spec canonical_nquads(input()) :: {:ok, String.t()} | {:error, error()}
  def canonical_nquads(input) do
    with {:ok, graph} <- to_graph(input) do
      {:ok,
       graph
       |> RDF.Graph.canonicalize()
       |> RDF.NQuads.write_string!(sort: true)}
    end
  end

  @doc """
  Parses `turtle` into an `RDF.Graph`, failing closed on non-UTF-8 input and on
  malformed Turtle.

  Exposed separately because callers that need the graph itself should not have
  to re-implement the encoding guard to get it.
  """
  @spec parse(String.t()) :: {:ok, RDF.Graph.t()} | {:error, error()}
  def parse(turtle) when is_binary(turtle) do
    with :ok <- ensure_utf8(turtle) do
      case RDF.Turtle.read_string(turtle) do
        {:ok, %RDF.Graph{} = graph} -> {:ok, graph}
        {:error, reason} -> {:error, {:parse_error, to_message(reason)}}
      end
    end
  end

  @doc """
  Returns `:ok` when `binary` is valid UTF-8, or
  `{:error, {:invalid_encoding, byte_offset}}` naming the first invalid byte.

  This guard is deliberately public. `AshA2A.GraphLaw.Wasm.graph_hash/3` guards
  only `is_binary/1`, but the wasm export it calls takes a Rust `&str`; a
  single `0xFF` byte is not a parse failure there but a marshalling failure
  that poisons the instance. Any Elixir caller of a wasm string export should
  run this first.

      iex> AshA2A.Semantic.CanonicalGraph.ensure_utf8("ok")
      :ok

      iex> AshA2A.Semantic.CanonicalGraph.ensure_utf8(<<"ok", 0xFF>>)
      {:error, {:invalid_encoding, 2}}
  """
  @spec ensure_utf8(binary()) :: :ok | {:error, {:invalid_encoding, non_neg_integer()}}
  def ensure_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      :ok
    else
      {:error, {:invalid_encoding, first_invalid_byte_offset(binary)}}
    end
  end

  @doc """
  Renders a typed `t:error/0` as a single human-readable line, for receipts and
  exception messages.

      iex> AshA2A.Semantic.CanonicalGraph.describe({:invalid_encoding, 7})
      "input is not valid UTF-8 (first invalid byte at offset 7)"
  """
  @spec describe(error()) :: String.t()
  def describe({:invalid_encoding, offset}),
    do: "input is not valid UTF-8 (first invalid byte at offset #{offset})"

  def describe({:parse_error, message}), do: "input is not well-formed Turtle: #{message}"
  def describe({:unsupported_input, description}), do: "unsupported input: #{description}"

  defp to_graph(%RDF.Graph{} = graph), do: {:ok, graph}
  defp to_graph(turtle) when is_binary(turtle), do: parse(turtle)
  defp to_graph(other), do: {:error, {:unsupported_input, inspect(other, limit: 5)}}

  defp first_invalid_byte_offset(binary), do: scan_utf8(binary, 0)

  defp scan_utf8(<<>>, offset), do: offset

  defp scan_utf8(binary, offset) do
    case binary do
      <<_::utf8, rest::binary>> ->
        scan_utf8(rest, offset + (byte_size(binary) - byte_size(rest)))

      _ ->
        offset
    end
  end

  defp to_message(reason) when is_binary(reason), do: reason
  defp to_message(%{message: message}) when is_binary(message), do: message
  defp to_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp to_message(reason), do: inspect(reason)
end
