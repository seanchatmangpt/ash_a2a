defmodule AshA2A.Semantic.Envelope do
  @moduledoc """
  RFC-SA2A-001 S11 semantic envelope: the wire object that crosses the A2A
  boundary, and the only object standing is ever attached to.

  ## Received is not admitted

  The single structural invariant this module exists to make true:

  > An envelope constructed from inbound input is **always** at standing
  > `:candidate`, no matter what the input says.

  There is no constructor -- public or private -- that accepts a standing
  from raw input. `new/1` and `from_json/1` both hard-set `:candidate`, and
  an inbound payload that *claims* a higher standing is not silently
  downgraded, it is refused (`:standing_self_declared`, `REFUSED_META_RIGOR`,
  see `AshA2A.Semantic.Standing`'s forbidden-inference-source #11). The only
  way an envelope's standing ever rises is
  `AshA2A.Semantic.Standing.transition/3`, which demands real evidence for
  every single step.

  ## The `:standing` field alone is not a standing claim

  This struct is public, so `%Envelope{envelope_id: "x", kind: "sa2a:Request",
  standing: :admitted}` is three lines any caller can write -- and that used to
  be enough, because `Standing.transition/3` read `:standing` straight off the
  struct with no authenticity check at all. It no longer is. `:standing` is now
  only meaningful in combination with `:standing_history` and
  `:standing_seal`, the append-only evidence ledger `Standing.transition/3`
  maintains and re-verifies on **every** transition. A struct carrying
  `standing: :admitted` with no matching sealed ledger is refused
  (`:standing_ledger_absent`), and a struct carrying a fabricated history is
  refused (`:standing_ledger_unsealed`). See that module's "Standing cannot be
  forged" section for exactly what the seal does and does not defend against.

  `:standing_seal` is deliberately **not** part of `to_map/1`/`to_json/1`. It
  is a local, runtime-keyed integrity value, not a transportable credential;
  serialized standing stays audit evidence, exactly as the paragraph below
  already says, and `from_json/1` still refuses any inbound standing history.

  A consequence worth stating plainly: `to_json/1` of an envelope that has
  been raised above `:candidate` is **not** re-ingestible by `from_json/1`.
  That is deliberate. Serialized standing is audit evidence, not a
  credential -- re-ingesting it would be exactly the self-declaration this
  boundary refuses. Round-tripping is total for the inbound class
  (`:candidate` envelopes), which is the class `from_json/1` is for.

  ## Wire shape (S11)

  JSON keys are camelCase per the RFC; struct keys are snake_case per
  Elixir. `to_map/1`/`from_map/1` do the translation, `to_json/1`/
  `from_json/1` add Jason encode/decode around them.

      {
        "profile":              "urn:sa2a:profile:core:v26.9.16",
        "kind":                 "sa2a:Request",
        "envelopeId":           "urn:uuid:...",
        "subjects":             ["urn:example:subject:1"],
        "standing":             "candidate",
        "semanticBasis":        ["urn:sa2a:basis:shapes:v1"],
        "graph": {
          "mediaType": "text/turtle",
          "digest":    "blake3:9b81...",
          "content":   "@prefix ex: <https://example.org/> . ..."
        },
        "provenance":           {"agent": "urn:example:agent:a"},
        "consequenceClass":     "none",
        "authorityRequirement": "none",
        "bounds":               {"maxTriples": 10000},
        "receipts":             [],
        "standingHistory":      []
      }

  `standingHistory` is an ash_a2a extension to the RFC S11 field list, not
  an RFC field. It is the append-only evidence chain `Standing.transition/3`
  writes, and it is what makes a standing claim auditable rather than
  asserted. Each entry records `from`/`to`/`at`/`evidenceKeys`/
  `evidenceDigest` -- the digest, never the raw evidence, so an envelope
  does not grow without bound and does not re-export payloads it merely
  observed.

  The evidence digest is a local SHA-256 over a sorted key=value rendering.
  It is deliberately **not** an RDF canonicalization: canonical graph
  identity (RFC S12) is `praxis-graphlaw`'s `graph_hash/1` (RDFC-1.0), and
  nothing in this module attempts to substitute for it. This digest
  identifies an evidence *map*, which is a plain Elixir term, not a graph.

  ## Defaults

  `consequenceClass` and `authorityRequirement` both default to `"none"`.
  An envelope that does not say what it will do, and does not say what
  authority it needs, gets the lowest possible reading of both -- never a
  permissive one.
  """

  alias AshA2A.Semantic.{Refusal, Standing, Vocabulary}

  @default_profile "urn:sa2a:profile:core:v26.9.16"
  @known_profiles [
    @default_profile,
    "urn:sa2a:profile:conformance:v26.9.16"
  ]

  # Aligned with `AshA2A.CommandBus`'s real consequence atoms
  # (`:observe` / `:change` / `:external_do`), plus the S11 `"none"` default
  # for an envelope that carries no consequence at all. `"unknown"` is
  # deliberately absent: an envelope may not declare itself unclassified and
  # expect to proceed -- that is what `REFUSED_CONSEQUENCE` is for.
  @consequence_classes ~w(none observe change external_do)

  @authority_requirements ~w(none delegated principal attested)

  # `Vocabulary.prefixes/0` is the existing prior-art-first namespace
  # registry (rdf/rdfs/owl/prov/time/odrl/skos/schema/oa/sosa). `sa2a` is
  # this RFC's own prefix and is admitted alongside them.
  @extra_prefixes ["sa2a"]

  @enforce_keys [:envelope_id, :kind]
  defstruct [
    :envelope_id,
    :kind,
    :graph,
    profile: @default_profile,
    subjects: [],
    standing: :candidate,
    semantic_basis: [],
    provenance: %{},
    consequence_class: "none",
    authority_requirement: "none",
    bounds: %{},
    receipts: [],
    standing_history: [],
    standing_seal: nil
  ]

  @type graph :: %{media_type: String.t(), digest: String.t(), content: String.t()}

  @type history_entry :: %{
          from: atom(),
          to: atom(),
          at: String.t(),
          evidence_keys: [String.t()],
          evidence_digest: String.t()
        }

  @type t :: %__MODULE__{
          envelope_id: String.t(),
          kind: String.t(),
          graph: graph() | nil,
          profile: String.t(),
          subjects: [term()],
          standing: atom(),
          semantic_basis: [term()],
          provenance: map(),
          consequence_class: String.t(),
          authority_requirement: String.t(),
          bounds: map(),
          receipts: [term()],
          standing_history: [history_entry()],
          standing_seal: String.t() | nil
        }

  @doc "The profile this build defaults to and considers canonical."
  @spec default_profile() :: String.t()
  def default_profile, do: @default_profile

  @doc "Profiles this runtime actually implements. Anything else is `UNSUPPORTED_PROFILE`."
  @spec known_profiles() :: [String.t()]
  def known_profiles, do: @known_profiles

  @doc "Admissible `consequenceClass` values."
  @spec consequence_classes() :: [String.t()]
  def consequence_classes, do: @consequence_classes

  @doc "Admissible `authorityRequirement` values."
  @spec authority_requirements() :: [String.t()]
  def authority_requirements, do: @authority_requirements

  @doc """
  Constructs a candidate envelope from attributes (atom- or string-keyed).

  Standing is forced to `:candidate`; there is no option to raise it here.

      iex> alias AshA2A.Semantic.Envelope
      iex> {:ok, e} = Envelope.new(%{envelope_id: "urn:uuid:1", kind: "sa2a:Request"})
      iex> {e.standing, e.consequence_class, e.authority_requirement}
      {:candidate, "none", "none"}
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Refusal.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    envelope = %__MODULE__{
      envelope_id: fetch(attrs, :envelope_id, "envelopeId"),
      kind: fetch(attrs, :kind, "kind"),
      graph: normalize_graph(fetch(attrs, :graph, "graph")),
      profile: fetch(attrs, :profile, "profile") || @default_profile,
      subjects: fetch(attrs, :subjects, "subjects") || [],
      standing: :candidate,
      semantic_basis: fetch(attrs, :semantic_basis, "semanticBasis") || [],
      provenance: fetch(attrs, :provenance, "provenance") || %{},
      consequence_class: fetch(attrs, :consequence_class, "consequenceClass") || "none",
      authority_requirement:
        fetch(attrs, :authority_requirement, "authorityRequirement") || "none",
      bounds: fetch(attrs, :bounds, "bounds") || %{},
      receipts: fetch(attrs, :receipts, "receipts") || [],
      standing_history: []
    }

    with :ok <- reject_declared_standing(attrs),
         :ok <- validate(envelope) do
      {:ok, envelope}
    end
  end

  def new(other), do: {:error, refuse(:refused_structure, :envelope_payload_invalid, other)}

  @doc "Like `new/1`, raising on refusal. Test/script convenience only."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, envelope} -> envelope
      {:error, refusal} -> raise ArgumentError, "Envelope.new!/1 refused: #{inspect(refusal)}"
    end
  end

  @doc """
  Parses an inbound envelope from a JSON binary or an already-decoded map.

  Always yields `:candidate` standing. A payload that claims any other
  standing, or that carries a non-empty `standingHistory`, is refused --
  standing is evidence held by this runtime, never a field the sender
  gets to fill in.

      iex> alias AshA2A.Semantic.Envelope
      iex> json = ~s({"envelopeId":"urn:uuid:2","kind":"sa2a:Request","standing":"admitted"})
      iex> {:error, refusal} = Envelope.from_json(json)
      iex> {refusal.class, refusal.code}
      {:refused_meta_rigor, :standing_self_declared}
  """
  @spec from_json(String.t() | map()) :: {:ok, t()} | {:error, Refusal.t()}
  def from_json(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) ->
        from_json(decoded)

      {:ok, other} ->
        {:error, refuse(:refused_structure, :envelope_json_invalid, other)}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, refuse(:refused_structure, :envelope_json_invalid, Exception.message(error))}
    end
  end

  def from_json(payload) when is_map(payload) do
    with {:ok, envelope} <- new(payload),
         {:ok, history} <- decode_history(payload) do
      {:ok, %{envelope | standing_history: history}}
    end
  end

  def from_json(other), do: {:error, refuse(:refused_structure, :envelope_payload_invalid, other)}

  @doc "Alias of `from_json/1` for an already-decoded map. Same candidate-only guarantee."
  @spec from_map(map()) :: {:ok, t()} | {:error, Refusal.t()}
  def from_map(payload) when is_map(payload), do: from_json(payload)

  @doc """
  Serializes to the S11 JSON-shaped map (camelCase string keys).

      iex> alias AshA2A.Semantic.Envelope
      iex> {:ok, e} = Envelope.new(%{envelope_id: "urn:uuid:3", kind: "sa2a:Request"})
      iex> map = Envelope.to_map(e)
      iex> {map["envelopeId"], map["standing"], map["standingHistory"]}
      {"urn:uuid:3", "candidate", []}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = envelope) do
    %{
      "profile" => envelope.profile,
      "kind" => envelope.kind,
      "envelopeId" => envelope.envelope_id,
      "subjects" => envelope.subjects,
      "standing" => Atom.to_string(envelope.standing),
      "semanticBasis" => envelope.semantic_basis,
      "graph" => encode_graph(envelope.graph),
      "provenance" => envelope.provenance,
      "consequenceClass" => envelope.consequence_class,
      "authorityRequirement" => envelope.authority_requirement,
      "bounds" => envelope.bounds,
      "receipts" => envelope.receipts,
      "standingHistory" => Enum.map(envelope.standing_history, &encode_history_entry/1)
    }
  end

  @doc "Serializes to a JSON binary."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = envelope), do: envelope |> to_map() |> Jason.encode!()

  @doc """
  Builds one evidenced standing-history entry.

  This is a **pure entry constructor**: it returns a map, it does not touch an
  envelope, it does not raise standing, and -- critically -- it does not seal
  anything. `AshA2A.Semantic.Standing.transition/3` is the only code path that
  appends an entry to an envelope and extends that envelope's ledger seal, and
  the sealing functions are private to that module precisely so that no public
  function anywhere can mint a ledger a caller did not earn. See
  `AshA2A.Semantic.Standing`'s "Standing cannot be forged" section.

      iex> entry = AshA2A.Semantic.Envelope.history_entry(:candidate, :received, %{transport: "https"})
      iex> {entry.from, entry.to, entry.evidence_keys}
      {:candidate, :received, ["transport"]}
  """
  @spec history_entry(atom(), atom(), map()) :: history_entry()
  def history_entry(from, to, evidence)
      when is_atom(from) and is_atom(to) and is_map(evidence) do
    %{
      from: from,
      to: to,
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      evidence_keys: evidence |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
      evidence_digest: evidence_digest(evidence)
    }
  end

  @doc """
  Deterministic SHA-256 digest of an evidence map.

  Local evidence identity only. This is **not** RDF canonicalization --
  RFC S12 canonical graph identity is `praxis-graphlaw`'s RDFC-1.0
  `graph_hash/1`, and this function makes no claim about graphs.

      iex> AshA2A.Semantic.Envelope.evidence_digest(%{a: 1, b: 2}) ==
      ...>   AshA2A.Semantic.Envelope.evidence_digest(%{b: 2, a: 1})
      true
  """
  @spec evidence_digest(map()) :: String.t()
  def evidence_digest(evidence) when is_map(evidence) do
    payload =
      evidence
      |> Enum.map(fn {key, value} ->
        "#{key}=#{inspect(value, limit: :infinity, printable_limit: :infinity)}"
      end)
      |> Enum.sort()
      |> Enum.join("\n")

    "sha256:" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  # --- validation ---------------------------------------------------------

  defp validate(%__MODULE__{} = envelope) do
    with :ok <- validate_profile(envelope.profile),
         :ok <- validate_envelope_id(envelope.envelope_id),
         :ok <- validate_kind(envelope.kind),
         :ok <- validate_list(:subjects, envelope.subjects),
         :ok <- validate_list(:semantic_basis, envelope.semantic_basis),
         :ok <- validate_list(:receipts, envelope.receipts),
         :ok <- validate_map(:provenance, envelope.provenance),
         :ok <- validate_map(:bounds, envelope.bounds),
         :ok <- validate_graph(envelope.graph),
         :ok <- validate_consequence_class(envelope.consequence_class) do
      validate_authority_requirement(envelope.authority_requirement)
    end
  end

  defp validate_profile(profile) when is_binary(profile) and profile != "" do
    if profile in @known_profiles do
      :ok
    else
      {:error, refuse(:unsupported_profile, :unknown_profile, profile)}
    end
  end

  defp validate_profile(other),
    do: {:error, refuse(:refused_profile, :profile_invalid, other)}

  defp validate_envelope_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_envelope_id(other),
    do: {:error, refuse(:refused_identity, :envelope_id_missing, other)}

  defp validate_kind(kind) when is_binary(kind) and kind != "" do
    case String.split(kind, ":", parts: 2) do
      [prefix, local] when local != "" ->
        if prefix in registered_prefixes() do
          :ok
        else
          {:error, refuse(:refused_namespace, :kind_namespace_unregistered, prefix)}
        end

      _ ->
        {:error, refuse(:refused_namespace, :kind_namespace_unregistered, kind)}
    end
  end

  defp validate_kind(other), do: {:error, refuse(:refused_structure, :kind_missing, other)}

  defp registered_prefixes, do: Map.keys(Vocabulary.prefixes()) ++ @extra_prefixes

  defp validate_list(_field, value) when is_list(value), do: :ok

  defp validate_list(field, value),
    do:
      {:error, refuse(:refused_structure, :envelope_field_invalid, %{field: field, value: value})}

  defp validate_map(_field, value) when is_map(value), do: :ok

  defp validate_map(field, value),
    do:
      {:error, refuse(:refused_structure, :envelope_field_invalid, %{field: field, value: value})}

  defp validate_graph(nil), do: :ok

  defp validate_graph(%{media_type: media_type, digest: digest, content: content})
       when is_binary(media_type) and media_type != "" and is_binary(digest) and digest != "" and
              is_binary(content),
       do: :ok

  defp validate_graph(other),
    do: {:error, refuse(:refused_structure, :graph_shape_invalid, other)}

  defp validate_consequence_class(value) when value in @consequence_classes, do: :ok

  defp validate_consequence_class(other),
    do: {:error, refuse(:refused_consequence, :consequence_class_unknown, other)}

  defp validate_authority_requirement(value) when value in @authority_requirements, do: :ok

  defp validate_authority_requirement(other),
    do: {:error, refuse(:refused_authority, :authority_requirement_unknown, other)}

  # S6 forbidden inference source #11: standing self-declared by the sender.
  defp reject_declared_standing(attrs) do
    case fetch(attrs, :standing, "standing") do
      nil -> :ok
      "candidate" -> :ok
      :candidate -> :ok
      claimed -> {:error, refuse(:refused_meta_rigor, :standing_self_declared, claimed)}
    end
  end

  defp decode_history(attrs) do
    case fetch(attrs, :standing_history, "standingHistory") do
      nil -> {:ok, []}
      [] -> {:ok, []}
      claimed -> {:error, refuse(:refused_meta_rigor, :standing_history_declared, claimed)}
    end
  end

  # --- serialization helpers ---------------------------------------------

  defp normalize_graph(nil), do: nil

  defp normalize_graph(graph) when is_map(graph) do
    media_type = fetch(graph, :media_type, "mediaType")
    digest = fetch(graph, :digest, "digest")
    content = fetch(graph, :content, "content")

    if is_nil(media_type) and is_nil(digest) and is_nil(content) do
      graph
    else
      %{media_type: media_type, digest: digest, content: content}
    end
  end

  defp normalize_graph(other), do: other

  defp encode_graph(nil), do: nil

  defp encode_graph(%{media_type: media_type, digest: digest, content: content}) do
    %{"mediaType" => media_type, "digest" => digest, "content" => content}
  end

  defp encode_history_entry(entry) do
    %{
      "from" => Atom.to_string(entry.from),
      "to" => Atom.to_string(entry.to),
      "at" => entry.at,
      "evidenceKeys" => entry.evidence_keys,
      "evidenceDigest" => entry.evidence_digest
    }
  end

  @doc """
  Decodes a serialized standing string back to an atom, restricted to the
  real `AshA2A.Semantic.Standing` state set.

  Never `String.to_atom/1` on wire input: an unrecognized standing string
  is a refusal, not a new atom.

      iex> AshA2A.Semantic.Envelope.decode_standing("admitted")
      {:ok, :admitted}
      iex> {:error, refusal} = AshA2A.Semantic.Envelope.decode_standing("wizard")
      iex> refusal.code
      :standing_state_unknown
  """
  @spec decode_standing(String.t()) :: {:ok, atom()} | {:error, Refusal.t()}
  def decode_standing(value) when is_binary(value) do
    all = Standing.states() ++ Standing.terminal_states()

    case Enum.find(all, fn state -> Atom.to_string(state) == value end) do
      nil -> {:error, refuse(:refused_structure, :standing_state_unknown, value)}
      state -> {:ok, state}
    end
  end

  def decode_standing(other),
    do: {:error, refuse(:refused_structure, :standing_state_unknown, other)}

  defp fetch(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end

  defp refuse(class, code, detail), do: Refusal.new(class, code, :envelope, detail)
end
