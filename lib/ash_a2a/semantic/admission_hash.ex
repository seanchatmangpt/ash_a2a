defmodule AshA2A.Semantic.AdmissionHash do
  @moduledoc """
  The RFC-SA2A-001 admission hash (S12, S31, S33, S52, S60).

      h = BLAKE3( Canonicalize(O*) || Validators || Rules || Profile )

  ## Why it exists

  A peer receiving `(O*, h, R_alpha)` must not be asked to accept *"trust me,
  I validated this"*. `h` binds the exact semantic state to the exact
  admitted machinery that judged it, so a second peer that holds the same
  `O*` and runs the same machinery can recompute `h` and compare. When two
  peers disagree, the struct returned here also carries the four component
  digests, so the disagreement localises to *which* component differs --
  the graph, the validators, the rules, or the profile -- instead of
  producing an opaque mismatch. See `differing_components/2`.

  This is one piece of the "SA2A Portable Semantic Execution Conformance"
  court. On its own it establishes only that two computations of `h` over
  the same inputs and the same engine agree; it does not establish semantic
  equivalence of arbitrary runtimes, production readiness, or security
  completeness.

  ## Where the primitives come from

  Nothing here canonicalizes RDF or computes BLAKE3 in Elixir. Both come
  from `AshA2A.GraphLaw.WasmDriver`, i.e. from the real `praxis-graphlaw` wasm
  module -- the same bytes both sides of the court execute. Elixir owns only
  the *encoding* of the four components into an unambiguous preimage.

  ## The encoding, stated exactly

  Plain `||` concatenation is not injective: with `Validators = "a"` and
  `Rules = "bc"` against `Validators = "ab"` and `Rules = "c"`, a naive
  concatenation yields the same preimage `"abc"` and therefore the same `h`
  for two genuinely different admissions. Every boundary in this
  implementation is therefore explicit.

  Two layers, both prefix-free:

  **1. Netstring framing.** `netstring(b) = byte_size(b) <> ":" <> b <> ","`
  (DJB netstrings). A netstring stream is uniquely decodable, so no byte can
  migrate across a component boundary without changing the encoding.

  **2. Domain separation.** Each component's preimage is prefixed with its
  own domain tag, so a validators list and an identically-shaped rules list
  hash differently.

  Component preimages:

      validators_preimage = "sa2a/validators/v1" <> Enum.map_join(items, &netstring/1)
      rules_preimage      = "sa2a/rules/v1"      <> Enum.map_join(items, &netstring/1)
      profile_preimage    = "sa2a/profile/v1"    <> encoded_profile

  where a string profile encodes as `netstring(profile)` and a map profile
  encodes as `Enum.map_join(Enum.sort(pairs), fn {k, v} -> netstring(k) <> netstring(v) end)`.

  Component digests:

      graph_digest      = GraphLaw.WasmDriver.graph_hash(graph_ttl)     # engine digest, see below
      validators_digest = GraphLaw.WasmDriver.blake3_hex(validators_preimage)
      rules_digest      = GraphLaw.WasmDriver.blake3_hex(rules_preimage)
      profile_digest    = GraphLaw.WasmDriver.blake3_hex(profile_preimage)

  Composite preimage and the hash itself:

      composite = "sa2a-admission-hash/v1\\n"
                  <> netstring("graph")      <> netstring(graph_digest)
                  <> netstring("validators") <> netstring(validators_digest)
                  <> netstring("rules")      <> netstring(rules_digest)
                  <> netstring("profile")    <> netstring(profile_digest)

      admission_hash = GraphLaw.WasmDriver.blake3_hex(composite)

  Hashing the *component digests* rather than the raw components means the
  composite preimage is fixed-width by construction, and it is what makes
  `differing_components/2` possible at all.

  ## What `graph_digest` is, and is not (measured)

  `graph_digest` is the engine's `graph_hash`: invariant under prefix labels
  and triple order, but **not** under blank-node relabelling, so it is not
  RDFC-1.0. Two peers holding the same `O*` written with different blank-node
  labels therefore disagree on `h`, and `differing_components/2` localises
  that to `[:graph]` (pinned by the "MEASURED ENGINE LIMITATION" test in
  `test/ash_a2a/semantic_admission_hash_test.exs`).

  The in-BEAM RDFC-1.0 identity `AshA2A.Semantic.AdmissionPipeline` uses
  (RDF.ex `RDF.Graph.canonical_hash/1`) is deliberately not substituted here:
  this hash's contract is that every digest in it comes from the same wasm
  bytes a non-BEAM peer can execute, and its malformed-input and N-Triples
  agreement tests pin the engine's behaviour specifically. The
  `:canonicalization` field (`"praxis-graphlaw/graph_hash"`) records which
  graph digest was used, so a future RDFC-1.0 variant is a distinguishable
  encoding rather than a silent change of meaning.

  ## Set semantics for validators and rules

  By default `validators` and `rules` are treated as **sets**: each list is
  normalised with `Enum.sort/1` and `Enum.uniq/1` before framing, because
  the identity of *admitted machinery* is which validators and rules were
  in force, not the order they happened to be listed in. Pass
  `preserve_order: true` to keep the given sequence for an engine where rule
  application order is semantically load-bearing. The choice is recorded in
  the struct's `:normalization` field, because two peers that disagree on it
  will disagree on `h` for the same admission.
  """

  alias AshA2A.GraphLaw.WasmDriver

  @encoding "sa2a-admission-hash/v1"
  @algorithm "blake3"
  @canonicalization "praxis-graphlaw/graph_hash"

  @components [:graph, :validators, :rules, :profile]

  @enforce_keys [
    :admission_hash,
    :graph_digest,
    :validators_digest,
    :rules_digest,
    :profile_digest
  ]
  defstruct [
    :admission_hash,
    :graph_digest,
    :validators_digest,
    :rules_digest,
    :profile_digest,
    :engine_version,
    encoding: @encoding,
    algorithm: @algorithm,
    canonicalization: @canonicalization,
    normalization: :sorted_set
  ]

  @type t :: %__MODULE__{
          admission_hash: String.t(),
          graph_digest: String.t(),
          validators_digest: String.t(),
          rules_digest: String.t(),
          profile_digest: String.t(),
          engine_version: String.t() | nil,
          encoding: String.t(),
          algorithm: String.t(),
          canonicalization: String.t(),
          normalization: :sorted_set | :preserved_order
        }

  @type error :: %{required(:code) => atom(), optional(atom()) => term()}

  @doc "The four component names, in the order they enter the composite preimage."
  @spec components() :: [atom()]
  def components, do: @components

  @doc """
  Canonical graph digest of a Turtle document.

  Delegates to the real engine -- `AshA2A.GraphLaw.WasmDriver.graph_hash/2` -- so
  the digest is the engine's prefix- and order-invariant graph hash and not
  an Elixir-side sort-then-hash. It is not blank-node-relabel invariant (not
  RDFC-1.0); see the moduledoc.
  """
  @spec canonical_graph_digest(String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def canonical_graph_digest(graph_ttl, opts \\ []) when is_binary(graph_ttl),
    do: WasmDriver.graph_hash(graph_ttl, opts)

  @doc """
  Computes the full admission hash over `(O*, Validators, Rules, Profile)`.

  `graph_ttl` is the Turtle serialisation of `O*`. `validators` and `rules`
  are lists of identifiers (anything `to_string/1` accepts). `profile` is
  either a string identifier or a map of string-able key/value pairs.

  Returns `{:ok, %AshA2A.Semantic.AdmissionHash{}}` carrying the composite
  hash *and* all four component digests, or a typed `{:error, map}`.

  Options:

    * `:preserve_order` -- keep the given order of `validators`/`rules`
      instead of the default sort-and-dedup set normalisation.
    * `:wasm_path`, `:tmp_dir` -- forwarded to `AshA2A.GraphLaw.WasmDriver`.

  The whole computation costs exactly two real engine round-trips: one
  batched call for the four component digests plus the engine version, and
  one for the composite.
  """
  @spec admission_hash(String.t(), [term()], [term()], term(), keyword()) ::
          {:ok, t()} | {:error, error()}
  def admission_hash(graph_ttl, validators, rules, profile, opts \\ [])
      when is_binary(graph_ttl) and is_list(validators) and is_list(rules) do
    normalization = if opts[:preserve_order], do: :preserved_order, else: :sorted_set

    calls = [
      {"graph_hash", [graph_ttl]},
      {"blake3_hex", [validators_preimage(validators, normalization)]},
      {"blake3_hex", [rules_preimage(rules, normalization)]},
      {"blake3_hex", [profile_preimage(profile)]},
      {"graphlaw_version", []}
    ]

    with {:ok, results} <- WasmDriver.call_many(calls, opts),
         {:ok, [graph, validators_d, rules_d, profile_d, engine]} <- unwrap(results),
         composite = composite_preimage(graph, validators_d, rules_d, profile_d),
         {:ok, hash} <- WasmDriver.blake3_hex(composite, opts) do
      {:ok,
       %__MODULE__{
         admission_hash: hash,
         graph_digest: graph,
         validators_digest: validators_d,
         rules_digest: rules_d,
         profile_digest: profile_d,
         engine_version: engine,
         normalization: normalization
       }}
    end
  end

  defp unwrap(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _} = error, _ -> {:halt, error}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Names the components on which two admission hashes disagree.

  Returns `[]` when the two admissions are component-identical. A verifier
  uses this to report *what* diverged rather than merely *that* something
  did: a differing `:graph` means the peers do not hold the same `O*`, while
  a differing `:rules` with an identical `:graph` means they hold the same
  semantic state but admitted it against different machinery.

  `:encoding_mismatch` and `:normalization_mismatch` are reported when the
  two structs were not produced under comparable encodings at all, in which
  case the component-level comparison below is not meaningful on its own.
  """
  @spec differing_components(t(), t()) :: [atom()]
  def differing_components(%__MODULE__{} = a, %__MODULE__{} = b) do
    encoding = if a.encoding == b.encoding, do: [], else: [:encoding_mismatch]
    normalization = if a.normalization == b.normalization, do: [], else: [:normalization_mismatch]

    component =
      Enum.filter(@components, fn component ->
        Map.fetch!(a, digest_key(component)) != Map.fetch!(b, digest_key(component))
      end)

    encoding ++ normalization ++ component
  end

  @doc """
  True iff two admission hashes agree on the composite *and* on every
  component digest.

  Both are checked deliberately: agreement on the composite alone would
  leave a component-level disagreement undetected if the composite encoding
  ever lost injectivity, and this is the property the conformance court
  asserts.
  """
  @spec agree?(t(), t()) :: boolean()
  def agree?(%__MODULE__{} = a, %__MODULE__{} = b),
    do: a.admission_hash == b.admission_hash and differing_components(a, b) == []

  defp digest_key(:graph), do: :graph_digest
  defp digest_key(:validators), do: :validators_digest
  defp digest_key(:rules), do: :rules_digest
  defp digest_key(:profile), do: :profile_digest

  @doc """
  The exact composite preimage that gets BLAKE3'd, given four component
  digests. Exposed so a conformance suite can assert on the preimage bytes
  themselves, not only on the resulting hash.
  """
  @spec composite_preimage(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def composite_preimage(graph_digest, validators_digest, rules_digest, profile_digest) do
    @encoding <>
      "\n" <>
      netstring("graph") <>
      netstring(graph_digest) <>
      netstring("validators") <>
      netstring(validators_digest) <>
      netstring("rules") <>
      netstring(rules_digest) <>
      netstring("profile") <> netstring(profile_digest)
  end

  @doc "The exact preimage hashed to produce `validators_digest`."
  @spec validators_preimage([term()], :sorted_set | :preserved_order) :: String.t()
  def validators_preimage(validators, normalization \\ :sorted_set),
    do: "sa2a/validators/v1" <> list_body(validators, normalization)

  @doc "The exact preimage hashed to produce `rules_digest`."
  @spec rules_preimage([term()], :sorted_set | :preserved_order) :: String.t()
  def rules_preimage(rules, normalization \\ :sorted_set),
    do: "sa2a/rules/v1" <> list_body(rules, normalization)

  @doc "The exact preimage hashed to produce `profile_digest`."
  @spec profile_preimage(term()) :: String.t()
  def profile_preimage(profile) when is_map(profile) and not is_struct(profile) do
    body =
      profile
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> Enum.sort()
      |> Enum.map_join(fn {k, v} -> netstring(k) <> netstring(v) end)

    "sa2a/profile/v1" <> body
  end

  def profile_preimage(profile), do: "sa2a/profile/v1" <> netstring(to_string(profile))

  defp list_body(list, normalization) do
    list
    |> Enum.map(&to_string/1)
    |> then(fn items ->
      case normalization do
        :sorted_set -> items |> Enum.uniq() |> Enum.sort()
        :preserved_order -> items
      end
    end)
    |> Enum.map_join(&netstring/1)
  end

  @doc """
  DJB netstring framing: `byte_size(b) <> ":" <> b <> ","`.

  Prefix-free and uniquely decodable, which is precisely the property that
  makes the concatenation above injective.

      iex> AshA2A.Semantic.AdmissionHash.netstring("abc")
      "3:abc,"
      iex> AshA2A.Semantic.AdmissionHash.netstring("")
      "0:,"
  """
  @spec netstring(String.t()) :: String.t()
  def netstring(binary) when is_binary(binary),
    do: Integer.to_string(byte_size(binary)) <> ":" <> binary <> ","
end
