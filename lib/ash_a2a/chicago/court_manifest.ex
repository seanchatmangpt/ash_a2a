defmodule AshA2A.Chicago.CourtManifest do
  @moduledoc """
  Court versioning and court meta-admission (RFC-SA2A-002 §136, §137).

  The conformance court is semantic machinery. Its normative machinery is
  admitted through a deterministic, content-addressed document,
  `priv/sa2a/chicago_court_manifest.json`, produced by
  `mix ash_a2a.chicago.pin_court_manifest` from the compiled discoverable
  courts and reviewed like any other change. It binds, per §137:

    * `court_version` -- the court machinery version (`version/0`) and the
      RFC `specification`;
    * per court: module, gate, profile, declared falsifier ids, the
      `falsifier_corpus_digest` and `conformance_query_digest` of exactly its
      declarations (`AshA2A.Chicago.StandingReceipt.corpus_digest/1`,
      `query_set_digest/1`), and `ocel_mapping_digest` -- the sorted
      `(source, event, activity)` declarations of its OCEL mappings;
    * `ocel_validator` -- the independent OCEL validator's module and declared
      identity (`name`, `version`, `specification`);
    * `standing_schema` -- the standing receipt schema identity.

  Every value is derived from declarations, never from BEAM bytes, so the
  document is reproducible on any machine that compiles the same court
  source. The receipt additionally records the validator's BEAM md5.

  ## Admission of running court machinery

  `admission/2` compares the machinery about to run -- the selected courts
  and the OCEL validator -- against the admitted document:

    * the document's own `digest` must be the digest of its contents;
    * `specification`, `court_version`, `standing_schema` and
      `ocel_validator` must be equal;
    * every running court must have an entry with equal module, gate,
      profile, falsifier ids and digests.

  The outcome is `{:admitted, digest}` or `{:drift, digest | nil, [field]}`
  (`"court:<id>:unadmitted"`, `"court:<id>:falsifier_corpus_digest"`,
  `"ocel_validator"`, `"court_manifest_unavailable"`, ...), emitted as
  `[:ash_a2a, :chicago, :court_manifest, :verified]`.
  `AshA2A.Chicago.Runner` computes it before any court runs and
  `AshA2A.Chicago.StandingReceipt` binds it and refuses `CONFORMANT` on drift:
  a newer court revision may find defects an older one missed (§136), but
  standing is only issued by the admitted revision.
  """

  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Json, StandingReceipt}

  @schema "ash_a2a.chicago.court_manifest/1"
  @version "chicago-court/1"
  @relative_path "sa2a/chicago_court_manifest.json"
  @verified_event [:ash_a2a, :chicago, :court_manifest, :verified]
  @default_validator AshA2A.Chicago.Ocel.Validator

  @refusal_codes %{court_manifest_not_an_object: :refused_structure}

  @doc false
  def __sa2a_refusal_codes__, do: @refusal_codes

  @type admission ::
          :not_evaluated
          | {:admitted, String.t()}
          | {:drift, String.t() | nil, [String.t()]}

  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "The court machinery version bound by every manifest and receipt."
  @spec version() :: String.t()
  def version, do: @version

  @spec verified_event() :: [atom()]
  def verified_event, do: @verified_event

  @doc "Committed court manifest path inside this app's `priv/`."
  @spec default_path() :: String.t()
  def default_path, do: Path.join(to_string(:code.priv_dir(:ash_a2a)), @relative_path)

  @doc """
  Builds the manifest document for `courts` (default every discoverable
  court). `opts[:ocel_validator]` names the validator (default
  `AshA2A.Chicago.Ocel.Validator`).
  """
  @spec build([module()] | nil, keyword()) :: map()
  def build(courts \\ nil, opts \\ []) do
    courts = courts || Chicago.courts()

    doc = %{
      "schema" => @schema,
      "specification" => StandingReceipt.specification(),
      "court_version" => @version,
      "standing_schema" => StandingReceipt.schema(),
      "ocel_validator" =>
        validator_identity(Keyword.get(opts, :ocel_validator, @default_validator)),
      "courts" => courts |> Enum.map(&court_entry/1) |> Enum.sort_by(& &1["id"])
    }

    Map.put(doc, "digest", digest(doc))
  end

  @doc "sha256 over the canonical JSON of the document without `digest`."
  @spec digest(map()) :: String.t()
  def digest(doc) do
    doc
    |> Map.delete("digest")
    |> Json.canonical()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "The admitted identity entry of one court."
  @spec court_entry(module()) :: map()
  def court_entry(court) do
    falsifiers = court.falsifiers()

    %{
      "id" => court.id(),
      "module" => inspect(court),
      "gate" => court.gate(),
      "profile" => Atom.to_string(court.profile()),
      "falsifier_ids" => falsifiers |> Enum.map(& &1.id) |> Enum.sort(),
      "falsifier_corpus_digest" => StandingReceipt.corpus_digest(falsifiers),
      "conformance_query_digest" => StandingReceipt.query_set_digest(falsifiers),
      "ocel_mapping_digest" => mapping_declaration_digest(court.ocel_mappings())
    }
  end

  @doc "Declared identity of an OCEL validator module (no BEAM bytes)."
  @spec validator_identity(module()) :: map()
  def validator_identity(validator) do
    declared =
      if Code.ensure_loaded?(validator) and function_exported?(validator, :identity, 0) do
        validator.identity() |> Map.new(fn {k, v} -> {to_string(k), v} end)
      else
        %{}
      end

    declared
    |> Map.take(["name", "version", "specification"])
    |> Map.put("module", inspect(validator))
  end

  @doc "Writes `doc` as canonical JSON (one trailing newline)."
  @spec write!(map(), Path.t()) :: :ok
  def write!(doc, path \\ default_path()) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Json.canonical(doc) <> "\n")
  end

  @doc "Reads a manifest document; `{:error, reason}` when absent or not a JSON object."
  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path \\ default_path()) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{} = doc} <- JSON.decode(raw) do
      {:ok, doc}
    else
      {:ok, _other} -> {:error, :court_manifest_not_an_object}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Admission of the running court machinery against `source` -- a path, a
  decoded document, or `nil` for `default_path/0`. `opts[:ocel_validator]` is
  the validator the run will use. Emits `verified_event/0`.
  """
  @spec admission([module()], keyword(), Path.t() | map() | nil) :: admission()
  def admission(courts, opts \\ [], source \\ nil) do
    result =
      case resolve(source) do
        {:ok, admitted} -> compare(admitted, build(courts, opts))
        {:error, reason} -> {:drift, nil, ["court_manifest_unavailable:#{inspect(reason)}"]}
      end

    emit(result, courts)
    result
  end

  @doc "JSON-safe form of an admission, as bound by the standing receipt."
  @spec to_map(admission()) :: map()
  def to_map(:not_evaluated), do: %{"verification" => "not_evaluated"}

  def to_map({:admitted, digest}),
    do: %{"verification" => "admitted", "admitted_digest" => digest, "drift" => []}

  def to_map({:drift, digest, fields}),
    do: %{"verification" => "drift", "admitted_digest" => digest, "drift" => fields}

  @doc "Inverse of `to_map/1`; an absent or malformed section is `:not_evaluated`."
  @spec from_map(term()) :: admission()
  def from_map(%{"verification" => "admitted", "admitted_digest" => d}) when is_binary(d),
    do: {:admitted, d}

  def from_map(%{"verification" => "drift", "admitted_digest" => d, "drift" => fields})
      when (is_binary(d) or is_nil(d)) and is_list(fields),
      do: {:drift, d, fields}

  def from_map(_), do: :not_evaluated

  @doc "The wire outcome name: `\"admitted\" | \"drift\" | \"not_evaluated\"`."
  @spec outcome(admission()) :: String.t()
  def outcome(admission), do: to_map(admission)["verification"]

  # --- internals ---------------------------------------------------------------

  defp resolve(nil), do: load(default_path())
  defp resolve(path) when is_binary(path), do: load(path)
  defp resolve(%{} = doc), do: {:ok, doc}
  defp resolve(other), do: {:error, {:unsupported_source, inspect(other, limit: 3)}}

  defp compare(admitted, running) do
    recorded = admitted["digest"]

    self_drift =
      if is_binary(recorded) and recorded == digest(admitted),
        do: [],
        else: ["court_manifest_digest"]

    top_drift =
      for key <- ~w(schema specification court_version standing_schema ocel_validator),
          admitted[key] != running[key],
          do: key

    admitted_courts = Map.new(List.wrap(admitted["courts"]), &{&1["id"], &1})

    court_drift =
      Enum.flat_map(running["courts"], fn entry ->
        case Map.get(admitted_courts, entry["id"]) do
          nil ->
            ["court:#{entry["id"]}:unadmitted"]

          admitted_entry ->
            for {key, value} <- Enum.sort(entry),
                admitted_entry[key] != value,
                do: "court:#{entry["id"]}:#{key}"
        end
      end)

    case self_drift ++ top_drift ++ court_drift do
      [] -> {:admitted, recorded}
      fields -> {:drift, if(is_binary(recorded), do: recorded), fields}
    end
  end

  defp mapping_declaration_digest(mappings) do
    mappings
    |> Enum.map(fn m ->
      [inspect(m.source), Enum.map_join(m.event, ".", &Atom.to_string/1), m.activity]
    end)
    |> Enum.sort()
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp emit(result, courts) do
    {outcome, digest, fields} =
      case result do
        {:admitted, digest} -> {:admitted, digest, []}
        {:drift, digest, fields} -> {:drift, digest, fields}
      end

    :telemetry.execute(@verified_event, %{drift_count: length(fields)}, %{
      outcome: outcome,
      admitted_digest: digest,
      drift: Enum.join(fields, ","),
      court_ids: courts |> Enum.map(& &1.id()) |> Enum.sort() |> Enum.join(",")
    })
  end
end
