defmodule AshA2A.Chicago.Requalification do
  @moduledoc """
  Requalification and cross-version standing reuse (RFC-SA2A-002 §119-§120).

  A prior Chicago standing MAY be reused only if every identity relevant to
  the claim is unchanged (§119). `dependent_gates/2` maps each changed
  identity field between an old and a new subject to the crown gates (§31)
  that must be requalified; `decide/2` applies it to a durable prior standing
  receipt.

  CalVer ordering never implies compatibility (§120): `version` is compared
  for equality like any other identity field and never ordered, so a newer
  version number cannot shorten the requalification set, let alone inherit
  standing.

  ## Field -> gate map

  | changed identity           | gates to requalify | why |
  |----------------------------|--------------------|-----|
  | `source_revision`, `dirty` | 1-12 | every executed path may have changed |
  | `artifact_digests`         | 1-12 | the executable (incl. WASM) under every gate changed |
  | `runtime`, `lock_digest`   | 1-12 | runtime version / dependency closure executes every gate |
  | `config_digest`            | 1-12 | configuration can alter any boundary |
  | `validator_digests`        | 1, 2, 5, 12 | admission, whole-plan preflight, KNOWN-class routing |
  | `root_manifest_digest`     | 1, 2, 5, 9, 10, 11 | admission, preflight, receipt binding, replay, fresh consumer |
  | `tag`, `tag_commit`, `version` | 1 | release identity binding only (same code) |
  | court `ocel_mapping_digest`, `query_set_digest`, `falsifier_corpus_digest`, `revision` | 1-12 | the evidence interpretation behind every gate changed |
  | court `standing_schema`    | 9, 10, 11 | receipt schema: binding, replay, fresh consumer |
  | anything unmapped          | 1-12 | fail closed (§130) |

  Gate 1 is always included whenever anything changed: a subject that is not
  the prior one must re-prove its exact identity.
  """

  alias AshA2A.Chicago.{StandingReceipt, Subject}

  @all_gates Enum.to_list(1..12)

  @field_gates %{
    "source_revision" => @all_gates,
    "dirty" => @all_gates,
    "artifact_digests" => @all_gates,
    "runtime" => @all_gates,
    "lock_digest" => @all_gates,
    "config_digest" => @all_gates,
    "validator_digests" => [1, 2, 5, 12],
    "root_manifest_digest" => [1, 2, 5, 9, 10, 11],
    "tag" => [1],
    "tag_commit" => [1],
    "version" => [1],
    "court.ocel_mapping_digest" => @all_gates,
    "court.query_set_digest" => @all_gates,
    "court.falsifier_corpus_digest" => @all_gates,
    "court.revision" => @all_gates,
    "court.standing_schema" => [9, 10, 11],
    "receipt_digest" => @all_gates
  }

  @subject_fields ~w(source_revision dirty tag tag_commit version root_manifest_digest
                     validator_digests config_digest lock_digest artifact_digests runtime)

  @decided_event [:ash_a2a, :chicago, :requalification, :decided]

  @type subject_like :: Subject.t() | map()
  @type decision :: {:reuse, String.t()} | {:requalify, %{fields: [String.t()], gates: [1..12]}}

  @doc "The telemetry event `decide/3` emits."
  @spec decided_event() :: [atom()]
  def decided_event, do: @decided_event

  @doc "Gates that must be requalified when `field` changes (unmapped: all, fail closed)."
  @spec gates_for_field(String.t() | atom()) :: [1..12]
  def gates_for_field(field), do: Map.get(@field_gates, to_string(field), @all_gates)

  @doc """
  Identity fields that differ between `old` and `new` (subjects or their JSON
  maps). A new subject that is not self-consistent -- dirty, or a tag whose
  commit is not its revision -- reports that field as changed too: it cannot
  be the subject a prior standing was issued for.
  """
  @spec changed_fields(subject_like(), subject_like()) :: [String.t()]
  def changed_fields(old, new) do
    old = normalize(old)
    new = normalize(new)

    differing = Enum.filter(@subject_fields, &(Map.get(old, &1) != Map.get(new, &1)))

    inconsistent =
      if(new["dirty"] != false, do: ["dirty"], else: []) ++
        if(new["tag"] && new["tag_commit"] != new["source_revision"],
          do: ["tag_commit"],
          else: []
        )

    Enum.uniq(differing ++ inconsistent)
  end

  @doc """
  Crown gates that must be requalified when moving from `old` to `new`.
  `[]` means every identity relevant to the claim is unchanged (§119).
  """
  @spec dependent_gates(subject_like(), subject_like()) :: [1..12]
  def dependent_gates(old, new), do: old |> changed_fields(new) |> gates_for_fields()

  @doc "Union of the gates for `fields`, always including gate 1 when non-empty."
  @spec gates_for_fields([String.t()]) :: [1..12]
  def gates_for_fields([]), do: []

  def gates_for_fields(fields) do
    fields
    |> Enum.flat_map(&gates_for_field/1)
    |> Kernel.++([1])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Decides whether a durable prior standing receipt (the decoded
  `standing_receipt.json`) may be reused for `new_subject`.

  Reuse requires the receipt's own digest to verify and every subject
  identity to be unchanged. When `:court` is given (a map shaped like a
  receipt's `"court"` section, optionally with `"standing_schema"`), every
  court identity it names must be unchanged as well. Anything else is `{:requalify, ...}` with
  the changed fields and dependent gates. Emits
  `[:ash_a2a, :chicago, :requalification, :decided]`.
  """
  @spec decide(map(), subject_like(), keyword()) :: decision()
  def decide(prior_receipt, new_subject, opts \\ []) when is_map(prior_receipt) do
    new = normalize(new_subject)
    prior_subject = Map.get(prior_receipt, "subject") || %{}

    fields =
      case StandingReceipt.verify_digest(prior_receipt) do
        :ok ->
          changed_fields(prior_subject, new) ++
            court_changes(prior_receipt, Keyword.get(opts, :court))

        _ ->
          ["receipt_digest"]
      end

    fields = Enum.uniq(fields)
    gates = gates_for_fields(fields)
    prior_standing = prior_receipt["standing"]

    decision =
      if fields == [],
        do: {:reuse, prior_standing},
        else: {:requalify, %{fields: fields, gates: gates}}

    :telemetry.execute(@decided_event, %{gate_count: length(gates)}, %{
      outcome: if(fields == [], do: :reuse, else: :requalify),
      fields: fields,
      gates: gates,
      prior_standing: prior_standing,
      prior_version: prior_subject["version"],
      new_version: new["version"],
      prior_identity: prior_subject["identity"],
      new_identity: identity(new_subject),
      prior_receipt_digest: prior_receipt["receipt_digest"]
    })

    decision
  end

  @doc "True only when `decide/3` would reuse the prior standing."
  @spec inherits_standing?(map(), subject_like(), keyword()) :: boolean()
  def inherits_standing?(prior_receipt, new_subject, opts \\ []),
    do: match?({:reuse, _}, decide(prior_receipt, new_subject, opts))

  defp court_changes(_prior, nil), do: []

  defp court_changes(prior_receipt, current) when is_map(current) do
    prior =
      Map.put(prior_receipt["court"] || %{}, "standing_schema", prior_receipt["standing_schema"])

    ~w(ocel_mapping_digest query_set_digest falsifier_corpus_digest revision standing_schema)
    |> Enum.filter(&(Map.has_key?(current, &1) and Map.get(prior, &1) != Map.get(current, &1)))
    |> Enum.map(&("court." <> &1))
  end

  defp normalize(%Subject{} = subject), do: Subject.to_map(subject)
  defp normalize(%{} = map), do: map

  defp identity(%Subject{} = subject), do: Subject.digest(subject)

  defp identity(%{} = map) do
    case Subject.from_map(Map.delete(map, "identity")) do
      {:ok, subject} -> Subject.digest(subject)
      :error -> nil
    end
  end
end
