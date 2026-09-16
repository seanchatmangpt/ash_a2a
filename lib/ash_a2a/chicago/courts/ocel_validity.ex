defmodule AshA2A.Chicago.Courts.OcelValidity do
  @moduledoc """
  `SA2A-OCEL` -- OCEL 2.0 validity and evidence-completeness court
  (RFC-SA2A-002 §15, §16, §17, §104, §106, §107, Appendix G).

  The boundary under qualification is the independent validator
  `AshA2A.Chicago.Ocel.Validator`, which decides and emits its own evidence
  (`ocel.validated`, `ocel.completeness`). The court never fabricates a log:

    1. **Real evidence.** Inside the stimulus of `SA2A-OCEL-001` a real
       `AshA2A.Chicago.Observer` (admitted `SutMappings`) records the real
       `AshA2A.CommandBus` refusing an unauthorised `:change` command on
       `AshA2A.Chicago.Fixtures.OcelValidator.Record`, and flushes a durable
       OCEL 2.0 artifact. An independent `Ash.read!/1` confirms no row was
       written.
    2. **Positive controls (§100).** The untouched artifact validates
       (`-001`), supports the evidence an authority falsifier needs (`-011`),
       and a semantically equivalent re-serialization with different bytes
       validates (`-012`, no golden-bytes oracle, §14).
    3. **Corruptions (§11).** Each negative falsifier derives one corrupted
       artifact from those real bytes, writes it durably (§16), and asks the
       validator to judge it. Forbidden outcome: validated as valid (or, for
       `-010`, supported as complete). A refusal that does not come from the
       targeted guard is reported `UNKNOWN`, never a kill, so deleting the
       guard makes the falsifier survive (§11 last paragraph, §22).
    4. **Observer under the validator (`-021`, §138).** A real observer whose
       admitted mapping set interprets one SUT telemetry event twice must
       still produce valid OCEL 2.0 (unique event ids).
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Command, CommandBus, Identity}
  alias AshA2A.Chicago.{Context, Falsifier, Observer, Result}
  alias AshA2A.Chicago.Fixtures.OcelValidator.Record
  alias AshA2A.Chicago.Ocel.{Mapping, SutMappings, Validator}

  @court_id "SA2A-OCEL"
  @capability "AshA2A.Chicago.Fixtures.OcelValidator.Record.create"
  @validator_boundary "AshA2A.Chicago.Ocel.Validator.validate_file/1"
  @sections ["§15", "§16", "§104", "Appendix G"]

  # The evidence a no-grant authority falsifier needs from a run (§106): the
  # bus resolved the target and refused admission for lack of authority.
  @required_evidence [
    {"brce.target", %{"outcome" => "resolved"}},
    {"brce.admission", %{"outcome" => "refused", "code" => "authority_required"}}
  ]

  @impl true
  def id, do: @court_id
  @impl true
  def title, do: "OCEL 2.0 validity and evidence completeness"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§15", "§16", "§17", "§104", "§106", "§107", "§138", "Appendix G"]

  @doc "Evidence requirements `SA2A-OCEL-010`/`-011` check with `Validator.supports?/2`."
  @spec required_evidence() :: [Validator.requirement()]
  def required_evidence, do: @required_evidence

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: [:ash_a2a, :chicago, :ocel, :validated],
        activity: "ocel.validated",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"ocel_artifact", meta[:artifact_sha256], "validated_artifact"},
            {"ocel_validator", validator_ref(meta), "validator"}
          ]
        end,
        attributes: fn _m, meta ->
          Map.take(meta, [
            :outcome,
            :error_count,
            :error_codes,
            :artifact_sha256,
            :serialization,
            :validator_version
          ])
        end
      ),
      Mapping.new!(
        event: [:ash_a2a, :chicago, :ocel, :completeness],
        activity: "ocel.completeness",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"ocel_artifact", meta[:artifact_sha256], "checked_artifact"},
            {"ocel_validator", validator_ref(meta), "validator"}
          ]
        end,
        attributes: fn _m, meta ->
          Map.take(meta, [
            :outcome,
            :missing,
            :missing_count,
            :required_count,
            :artifact_sha256,
            :validator_version
          ])
        end
      )
    ]
  end

  defp validator_ref(meta) do
    case {meta[:validator], meta[:validator_version]} do
      {name, version} when is_binary(name) and is_binary(version) -> name <> "@" <> version
      _ -> nil
    end
  end

  # --- declarations -------------------------------------------------------------

  @impl true
  def falsifiers do
    [base_control()] ++
      Enum.map(corruptions(), &corruption_falsifier/1) ++
      [incomplete_falsifier(), completeness_control(), reserialization_control()] ++
      [overlapping_mappings_falsifier()]
  end

  defp fid(n), do: @court_id <> "-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp base_control do
    Falsifier.new!(
      id: fid(1),
      court_id: @court_id,
      kind: :positive_control,
      invariant:
        "A real observer-produced OCEL 2.0 artifact of a real SUT execution validates: the validator discriminates rather than refusing everything",
      stimulus:
        "real Observer records CommandBus refusing an unauthorised :change on the fixture Record; flush to disk; Validator.validate_file/1",
      boundary: @validator_boundary,
      attempt_evidence: "ocel.validated emitted by the validator for the observer artifact",
      survival_evidence:
        "brce.admission refused(authority_required) precedes ocel.validated outcome=valid; admission event object-centric (§107); no row in an independent Ash.read!",
      failure_class: :ocel_validation_failure,
      rfc_sections: ["§15", "§16", "§100", "§104", "§107"],
      attempt_predicate: {:observed, "ocel.validated"},
      outcome_predicate:
        {:all,
         [
           {:observed, "brce.admission",
            %{"outcome" => "refused", "code" => "authority_required"}},
           {:precedes, "brce.admission", "ocel.validated"},
           {:observed, "ocel.validated", %{"outcome" => "valid"}}
         ]}
    )
  end

  defp corruption_falsifier(spec) do
    Falsifier.new!(
      id: fid(spec.n),
      court_id: @court_id,
      kind: :negative,
      invariant: spec.invariant,
      stimulus: "derive from the real observer artifact: " <> spec.mutation,
      boundary: @validator_boundary,
      forbidden_outcome: "the corrupted artifact is validated as valid OCEL 2.0",
      attempt_evidence:
        "ocel.validated emitted by the validator for the corrupted artifact's sha256, attributed to this stimulus",
      survival_evidence:
        "ocel.validated outcome=valid attributed to this stimulus, or validate_file/1 returned {:ok, _}",
      guard: spec.guard,
      failure_class: :ocel_validation_failure,
      rfc_sections: @sections,
      tags: [:ocel_syntax],
      attempt_predicate: {:observed, "ocel.validated"},
      outcome_predicate: {:observed, "ocel.validated", %{"outcome" => "valid"}}
    )
  end

  defp incomplete_falsifier do
    Falsifier.new!(
      id: fid(10),
      court_id: @court_id,
      kind: :negative,
      invariant:
        "Evidence incompleteness is not conformance (§106): a syntactically valid artifact lacking a required activity is refused",
      stimulus:
        "derive from the real observer artifact: drop every brce.admission event (declarations kept, still valid OCEL 2.0); Validator.supports?/2 with the authority-falsifier evidence requirements",
      boundary: "AshA2A.Chicago.Ocel.Validator.supports?/2",
      forbidden_outcome:
        "the incomplete artifact is reported as supporting the required evidence",
      attempt_evidence:
        "ocel.validated outcome=valid (the attack kept syntax valid) and ocel.completeness emitted for the same artifact",
      survival_evidence: "ocel.completeness outcome=supported, or supports?/2 returned {:ok, _}",
      guard: "Validator.supports?/2 per-requirement event match (missing => refused)",
      failure_class: :ocel_evidence_incomplete,
      rfc_sections: ["§106", "§104", "§130"],
      tags: [:ocel_completeness],
      attempt_predicate:
        {:all,
         [
           {:observed, "ocel.validated", %{"outcome" => "valid"}},
           {:observed, "ocel.completeness"}
         ]},
      outcome_predicate: {:observed, "ocel.completeness", %{"outcome" => "supported"}}
    )
  end

  defp completeness_control do
    Falsifier.new!(
      id: fid(11),
      court_id: @court_id,
      kind: :positive_control,
      invariant:
        "The untouched real artifact supports the evidence an authority falsifier needs: completeness discriminates",
      stimulus: "Validator.supports?/2 over the untouched real observer artifact",
      boundary: "AshA2A.Chicago.Ocel.Validator.supports?/2",
      attempt_evidence: "ocel.completeness emitted for the untouched artifact",
      survival_evidence:
        "ocel.completeness outcome=supported; supports?/2 returned {:ok, missing: []}",
      failure_class: :ocel_evidence_incomplete,
      rfc_sections: ["§100", "§106"],
      attempt_predicate: {:observed, "ocel.completeness"},
      outcome_predicate: {:observed, "ocel.completeness", %{"outcome" => "supported"}}
    )
  end

  defp reserialization_control do
    Falsifier.new!(
      id: fid(12),
      court_id: @court_id,
      kind: :positive_control,
      invariant:
        "Validation judges OCEL 2.0 semantics, not producer bytes: an equivalent re-serialization with different layout and array order validates (§14)",
      stimulus:
        "decode the real artifact, reverse every array, pretty-print with a different encoder, write durably, Validator.validate_file/1",
      boundary: @validator_boundary,
      attempt_evidence:
        "ocel.validated emitted for the re-serialized artifact (different sha256)",
      survival_evidence: "ocel.validated outcome=valid",
      failure_class: :ocel_validation_failure,
      rfc_sections: ["§14", "§16", "§100"],
      attempt_predicate: {:observed, "ocel.validated"},
      outcome_predicate: {:observed, "ocel.validated", %{"outcome" => "valid"}}
    )
  end

  defp overlapping_mappings_falsifier do
    Falsifier.new!(
      id: fid(21),
      court_id: @court_id,
      kind: :negative,
      invariant:
        "The independent observer's OCEL stays valid OCEL 2.0 when its admitted mapping set interprets one SUT telemetry event more than once (event ids unique, §17, §138)",
      stimulus:
        "real Observer with SutMappings plus a second admitted mapping for [:ash_a2a, :command_bus, :admission] records CommandBus refusing an unauthorised command; flush; Validator.validate_file/1",
      boundary:
        "AshA2A.Chicago.Observer artifact event identity, judged by AshA2A.Chicago.Ocel.Validator.validate_file/1",
      forbidden_outcome: "the observer-produced artifact is refused as invalid OCEL 2.0",
      attempt_evidence:
        "brce.admission observed and ocel.validated emitted for the observer artifact, attributed to this stimulus",
      survival_evidence:
        "ocel.validated outcome=invalid (duplicate_event_id) for the observer artifact",
      guard: "Observer.build_log/2 per-mapping event id disambiguation",
      failure_class: :ocel_validation_failure,
      rfc_sections: ["§16", "§17", "§138"],
      tags: [:observer],
      attempt_predicate: {:all, [{:observed, "brce.admission"}, {:observed, "ocel.validated"}]},
      outcome_predicate: {:observed, "ocel.validated", %{"outcome" => "invalid"}}
    )
  end

  # Corruption table: each derives ONE defect from the real artifact and names
  # the guard (error code + path prefix) whose diagnosis makes a refusal a kill.
  defp corruptions do
    [
      %{
        n: 2,
        invariant: "Every event-to-object relationship objectId resolves to an object",
        mutation: "retarget the first event relationship's objectId to a nonexistent object",
        guard: "Validator relationship resolution (dangling_object_reference)",
        expect: {"dangling_object_reference", "/events/"},
        corrupt: &dangling_e2o/1
      },
      %{
        n: 3,
        invariant: "Every event attribute used is declared on its event type",
        mutation: "add an attribute not declared on the first event's type",
        guard: "Validator attribute declaration lookup (undeclared_attribute)",
        expect: {"undeclared_attribute", "/events/"},
        corrupt: &undeclared_event_attribute/1
      },
      %{
        n: 4,
        invariant: "Every attribute value conforms to its declared OCEL type",
        mutation:
          "set an integer-declared event attribute (chicago_seq) to the near-miss string \"12x\"",
        guard: "Validator value conformance (attribute_value_type_mismatch)",
        expect: {"attribute_value_type_mismatch", "/events/"},
        corrupt: &type_mismatch/1
      },
      %{
        n: 5,
        invariant: "Every event time is a parseable ISO-8601 date-time",
        mutation:
          "set the first event's time to the ISO-shaped impossible \"2026-13-45T99:99:99Z\"",
        guard: "Validator event time parse (invalid_time)",
        expect: {"invalid_time", "/events/"},
        corrupt: &unparseable_event_time/1
      },
      %{
        n: 6,
        invariant: "Object ids are unique",
        mutation: "append an exact copy of the first object",
        guard: "Validator object id uniqueness (duplicate_object_id)",
        expect: {"duplicate_object_id", "/objects/"},
        corrupt: &duplicate_object_id/1
      },
      %{
        n: 7,
        invariant: "Event ids are unique",
        mutation: "give the second event the first event's id (event count unchanged)",
        guard: "Validator event id uniqueness (duplicate_event_id)",
        expect: {"duplicate_event_id", "/events/"},
        corrupt: &duplicate_event_id/1
      },
      %{
        n: 8,
        invariant: "The four OCEL 2.0 top-level keys are present",
        mutation: "remove the top-level eventTypes key",
        guard: "Validator top-level shape (missing_top_level_key)",
        expect: {"missing_top_level_key", "/eventTypes"},
        corrupt: &missing_top_level_key/1
      },
      %{
        n: 9,
        invariant: "The artifact is JSON",
        mutation: "truncate the real artifact's bytes by one byte (partial write)",
        guard: "Validator JSON decode (non_json)",
        expect: {"non_json", ""},
        corrupt: &truncated_bytes/1
      },
      %{
        n: 13,
        invariant: "Every object-to-object relationship objectId resolves to an object",
        mutation: "retarget the first object relationship's objectId to a nonexistent object",
        guard: "Validator relationship resolution on objects (dangling_object_reference)",
        expect: {"dangling_object_reference", "/objects/"},
        corrupt: &dangling_o2o/1
      },
      %{
        n: 14,
        invariant: "Every event type used is declared",
        mutation: "rename the first event's type to an undeclared type",
        guard: "Validator event type lookup (undeclared_event_type)",
        expect: {"undeclared_event_type", "/events/"},
        corrupt: &undeclared_event_type/1
      },
      %{
        n: 15,
        invariant: "Relationship qualifiers are strings",
        mutation: "set the first event relationship's qualifier to the integer 42",
        guard: "Validator qualifier typing (invalid_qualifier)",
        expect: {"invalid_qualifier", "/events/"},
        corrupt: &non_string_qualifier/1
      },
      %{
        n: 16,
        invariant: "Every object attribute time is a parseable ISO-8601 date-time",
        mutation: "set the first object attribute's time to \"yesterday\"",
        guard: "Validator object attribute time parse (invalid_time)",
        expect: {"invalid_time", "/objects/"},
        corrupt: &unparseable_object_attribute_time/1
      },
      %{
        n: 17,
        invariant:
          "Attribute declarations use an OCEL 2.0 type (string|integer|float|boolean|time)",
        mutation:
          "change the first event type's first attribute declaration type to \"datetime\"",
        guard: "Validator attribute type enumeration (invalid_attribute_type)",
        expect: {"invalid_attribute_type", "/eventTypes/"},
        corrupt: &non_ocel_attribute_type/1
      },
      %{
        n: 18,
        invariant: "Type names are unique",
        mutation: "append a second declaration of the first event type's name",
        guard: "Validator type name uniqueness (duplicate_type_name)",
        expect: {"duplicate_type_name", "/eventTypes/"},
        corrupt: &duplicate_type_name/1
      },
      %{
        n: 19,
        invariant: "Every object type used is declared",
        mutation: "rename the first object's type to an undeclared type",
        guard: "Validator object type lookup (undeclared_object_type)",
        expect: {"undeclared_object_type", "/objects/"},
        corrupt: &undeclared_object_type/1
      },
      %{
        n: 20,
        invariant: "Every object attribute used is declared on its object type",
        mutation: "add an attribute not declared on the first object's type",
        guard: "Validator attribute declaration lookup on objects (undeclared_attribute)",
        expect: {"undeclared_attribute", "/objects/"},
        corrupt: &undeclared_object_attribute/1
      }
    ]
  end

  # --- run ----------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    by_id = Map.new(falsifiers(), &{&1.id, &1})
    dir = Path.join(ctx.evidence_dir, "sa2a-ocel")
    File.mkdir_p!(dir)

    {base_result, base} = run_base_control(ctx, by_id[fid(1)], dir)

    dependent =
      case base do
        {:ok, base} ->
          Enum.map(corruptions(), &run_corruption(ctx, by_id[fid(&1.n)], &1, base, dir)) ++
            [
              run_incomplete(ctx, by_id[fid(10)], base, dir),
              run_completeness_control(ctx, by_id[fid(11)], base),
              run_reserialization_control(ctx, by_id[fid(12)], base, dir),
              run_overlapping_mappings(ctx, by_id[fid(21)], dir)
            ]

        # Without a validated single-mapping baseline no refusal below can be
        # attributed to its target (a validator refusing everything would
        # otherwise "kill" every corruption and "convict" the observer).
        {:error, reason} ->
          for n <- Enum.map(corruptions(), & &1.n) ++ [10, 11, 12, 21] do
            Result.unknown(
              by_id[fid(n)],
              "the real base artifact is not a valid OCEL 2.0 baseline (#{reason}); a refusal cannot be attributed to its target (§11)",
              :ocel_validation_failure
            )
          end
      end

    [base_result | dependent]
  end

  # --- base artifact ------------------------------------------------------------

  defp run_base_control(ctx, %Falsifier{} = f, dir) do
    label = "sa2a-ocel-#{System.unique_integer([:positive])}"

    outcome =
      Context.stimulus(ctx, f, fn ->
        with {:ok, flush} <-
               produce_real_artifact(
                 ctx,
                 f,
                 Path.join(dir, "base"),
                 SutMappings.mappings(),
                 label
               ) do
          {:ok, flush, Validator.validate_file(flush.path)}
        end
      end)

    case outcome do
      {:ok, flush, validation} ->
        bytes = File.read!(flush.path)
        {_status, report} = validation
        row_absent? = label not in Enum.map(Ash.read!(Record), & &1.label)
        centric = admission_object_types(bytes)
        centric? = Enum.all?(["command", "capability", "principal"], &(&1 in centric))
        valid? = match?({:ok, _}, validation)

        result =
          Result.positive(f,
            attempt_observed?: observed_for?(ctx, f, "ocel.validated", flush.sha256),
            expected_outcome_observed?:
              valid? and row_absent? and centric? and
                Context.observed?(ctx, f, "brce.admission") and
                observed_attr?(ctx, f, "ocel.validated", "outcome", "valid"),
            detail:
              "observer artifact #{String.slice(flush.sha256, 0, 12)} valid=#{valid?} row_absent=#{row_absent?} admission_object_types=#{Enum.join(centric, ",")}",
            evidence: %{
              "artifact_sha256" => flush.sha256,
              "artifact_bytes" => flush.bytes,
              "observer_events" => flush.events,
              "observer_objects" => flush.objects,
              "observer_dropped" => flush.dropped,
              "reply_code" => reply_code(flush.reply),
              "refused_row_absent" => row_absent?,
              "admission_object_types" => centric,
              "validation" => summarize(report)
            }
          )

        base =
          if valid? and flush.dropped == 0,
            do:
              {:ok,
               %{path: flush.path, sha256: flush.sha256, bytes: bytes, doc: JSON.decode!(bytes)}},
            else: {:error, "validator returned #{error_codes(report)}; dropped=#{flush.dropped}"}

        {result, base}

      {:error, reason} ->
        {Result.unknown(f, "observer could not flush the base artifact: #{inspect(reason)}"),
         {:error, inspect(reason)}}
    end
  end

  # A real observer over a real SUT stimulus. The inner stimulus carries its
  # own run id, so the run's outer observer keeps attributing the SUT events to
  # the outer falsifier while this observer writes its own durable artifact.
  defp produce_real_artifact(ctx, %Falsifier{} = f, dir, mappings, label) do
    run_id = "#{ctx.run_id}-sa2a-ocel-#{System.unique_integer([:positive])}"
    {:ok, observer} = Observer.start_link(run_id: run_id, mappings: mappings)

    try do
      inner = %{ctx | run_id: run_id, observer: observer}

      reply =
        Context.stimulus(inner, f, fn ->
          CommandBus.run(unauthorised_command(label), message(label), Record)
        end)

      with {:ok, flush} <- Observer.flush(observer, dir) do
        {:ok, Map.put(flush, :reply, reply)}
      end
    after
      if Process.alive?(observer), do: Observer.stop(observer)
    end
  end

  defp unauthorised_command(label) do
    Command.new(@capability,
      command_id: "sa2a-ocel-" <> label,
      agent_id: "sa2a-ocel-agent",
      principal_id: Identity.principal("sa2a-ocel-subject"),
      input: %{label: label}
    )
  end

  defp message(label), do: A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])

  defp reply_code({:error, %{code: code}}), do: inspect(code)
  defp reply_code({:ok, _}), do: "ok"
  defp reply_code(other), do: inspect(other, limit: 3)

  defp admission_object_types(bytes) do
    doc = JSON.decode!(bytes)
    types = Map.new(doc["objects"], &{&1["id"], &1["type"]})

    doc["events"]
    |> Enum.filter(&(&1["type"] == "brce.admission"))
    |> Enum.flat_map(&(&1["relationships"] || []))
    |> Enum.map(&types[&1["objectId"]])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # --- corruptions ----------------------------------------------------------------

  defp run_corruption(ctx, %Falsifier{} = f, spec, base, dir) do
    case spec.corrupt.(base) do
      {:ok, bytes} ->
        path = durable_write!(dir, f.id, bytes)
        sha = sha256(bytes)
        reply = Context.stimulus(ctx, f, fn -> Validator.validate_file(path) end)
        {code, prefix} = spec.expect

        forbidden? =
          match?({:ok, _}, reply) or observed_attr?(ctx, f, "ocel.validated", "outcome", "valid")

        {_status, report} = reply
        targeted? = targeted?(report, code, prefix)

        evidence = %{
          "base_sha256" => base.sha256,
          "corrupted_sha256" => sha,
          "corrupted_path" => path,
          "mutation" => spec.mutation,
          "expected_code" => code,
          "expected_path_prefix" => prefix,
          "validation" => summarize(report)
        }

        if forbidden? or targeted? do
          Result.negative(f,
            attempt_observed?: observed_for?(ctx, f, "ocel.validated", sha),
            forbidden_outcome_observed?: forbidden?,
            detail: "validator returned #{error_codes(report)}",
            evidence: evidence
          )
        else
          Result.unknown(
            f,
            "refused, but not by the targeted guard #{code}@#{prefix}* (got #{error_codes(report)}); the kill cannot be attributed (§11)",
            :ocel_validation_failure
          )
        end

      {:error, reason} ->
        Result.unknown(f, "corruption precondition not met by the real artifact: #{reason}")
    end
  end

  defp run_incomplete(ctx, %Falsifier{} = f, base, dir) do
    doc =
      Map.update!(base.doc, "events", fn events ->
        Enum.reject(events, &(&1["type"] == "brce.admission"))
      end)

    if length(doc["events"]) == length(base.doc["events"]) do
      Result.unknown(f, "the real artifact has no brce.admission event to remove")
    else
      bytes = JSON.encode!(doc)
      path = durable_write!(dir, f.id, bytes)
      sha = sha256(bytes)
      reply = Context.stimulus(ctx, f, fn -> Validator.supports?(path, @required_evidence) end)
      {_status, report} = reply

      forbidden? =
        match?({:ok, _}, reply) or
          observed_attr?(ctx, f, "ocel.completeness", "outcome", "supported")

      targeted? = Enum.any?(report["missing"], &(&1["activity"] == "brce.admission"))

      attempt? =
        observed_for?(ctx, f, "ocel.completeness", sha) and
          observed_attr?(ctx, f, "ocel.validated", "outcome", "valid")

      evidence = %{
        "base_sha256" => base.sha256,
        "incomplete_sha256" => sha,
        "outcome" => report["outcome"],
        "missing" => report["missing"],
        "validation" => summarize(report["validation"])
      }

      if forbidden? or targeted? do
        Result.negative(f,
          attempt_observed?: attempt?,
          forbidden_outcome_observed?: forbidden?,
          detail: "supports?/2 outcome=#{report["outcome"]}",
          evidence: evidence
        )
      else
        Result.unknown(
          f,
          "refused as #{report["outcome"]} without naming brce.admission missing; the kill cannot be attributed (§11)",
          :ocel_evidence_incomplete
        )
      end
    end
  end

  defp run_completeness_control(ctx, %Falsifier{} = f, base) do
    reply = Context.stimulus(ctx, f, fn -> Validator.supports?(base.path, @required_evidence) end)
    {_status, report} = reply

    Result.positive(f,
      attempt_observed?: observed_for?(ctx, f, "ocel.completeness", base.sha256),
      expected_outcome_observed?:
        match?({:ok, %{"missing" => []}}, reply) and
          observed_attr?(ctx, f, "ocel.completeness", "outcome", "supported"),
      detail: "supports?/2 outcome=#{report["outcome"]}",
      evidence: %{"matched" => report["matched"], "missing" => report["missing"]}
    )
  end

  defp run_reserialization_control(ctx, %Falsifier{} = f, base, dir) do
    bytes = base.doc |> reverse_arrays() |> :json.format() |> IO.iodata_to_binary()
    path = durable_write!(dir, f.id, bytes)
    sha = sha256(bytes)
    reply = Context.stimulus(ctx, f, fn -> Validator.validate_file(path) end)
    {_status, report} = reply

    Result.positive(f,
      attempt_observed?: sha != base.sha256 and observed_for?(ctx, f, "ocel.validated", sha),
      expected_outcome_observed?:
        match?({:ok, _}, reply) and observed_attr?(ctx, f, "ocel.validated", "outcome", "valid"),
      detail:
        "re-serialized #{String.slice(sha, 0, 12)} (base #{String.slice(base.sha256, 0, 12)})",
      evidence: %{
        "base_sha256" => base.sha256,
        "reserialized_sha256" => sha,
        "validation" => summarize(report)
      }
    )
  end

  # --- observer with overlapping admitted mappings ---------------------------------

  defp run_overlapping_mappings(ctx, %Falsifier{} = f, dir) do
    event = [:ash_a2a, :command_bus, :admission]
    sut = Enum.find(SutMappings.mappings(), &(&1.event == event))

    second =
      Mapping.new!(
        event: event,
        activity: "brce.admission.decision",
        source: __MODULE__,
        objects: sut.objects,
        attributes: sut.attributes
      )

    label = "sa2a-ocel-overlap-#{System.unique_integer([:positive])}"

    outcome =
      Context.stimulus(ctx, f, fn ->
        with {:ok, flush} <-
               produce_real_artifact(
                 ctx,
                 f,
                 Path.join(dir, "overlapping-mappings"),
                 SutMappings.mappings() ++ [second],
                 label
               ) do
          {:ok, flush, Validator.validate_file(flush.path)}
        end
      end)

    case outcome do
      {:ok, flush, {_status, report} = validation} ->
        forbidden? =
          match?({:error, _}, validation) or
            observed_attr?(ctx, f, "ocel.validated", "outcome", "invalid")

        Result.negative(f,
          attempt_observed?:
            Context.observed?(ctx, f, "brce.admission") and
              observed_for?(ctx, f, "ocel.validated", flush.sha256),
          forbidden_outcome_observed?: forbidden?,
          detail: "observer artifact validator returned #{error_codes(report)}",
          evidence: %{
            "artifact_sha256" => flush.sha256,
            "observer_events" => flush.events,
            "validation" => summarize(report)
          }
        )

      {:error, reason} ->
        Result.unknown(f, "observer could not flush: #{inspect(reason)}")
    end
  end

  # --- corruption functions (pure JSON-map edits over the real artifact) ------------

  defp dangling_e2o(%{doc: doc}) do
    update_first(doc, "events", &match?([_ | _], &1["relationships"]), fn event ->
      update_in(event, ["relationships", Access.at(0), "objectId"], fn _ ->
        "sa2a-ocel:dangling-#{System.unique_integer([:positive])}"
      end)
    end)
  end

  defp dangling_o2o(%{doc: doc}) do
    update_first(doc, "objects", &match?([_ | _], &1["relationships"]), fn object ->
      update_in(object, ["relationships", Access.at(0), "objectId"], fn _ ->
        "sa2a-ocel:dangling-#{System.unique_integer([:positive])}"
      end)
    end)
  end

  defp undeclared_event_attribute(%{doc: doc}) do
    update_first(doc, "events", &is_map/1, fn event ->
      Map.update(
        event,
        "attributes",
        [undeclared_attr()],
        &(&1 ++ [undeclared_attr()])
      )
    end)
  end

  defp undeclared_object_attribute(%{doc: doc}) do
    update_first(doc, "objects", &is_map/1, fn object ->
      attr = Map.put(undeclared_attr(), "time", "2026-09-16T00:00:00Z")
      Map.update(object, "attributes", [attr], &(&1 ++ [attr]))
    end)
  end

  defp undeclared_attr, do: %{"name" => "sa2a_ocel_undeclared_attribute", "value" => "x"}

  defp type_mismatch(%{doc: doc}) do
    has_seq = fn event -> Enum.any?(event["attributes"] || [], &(&1["name"] == "chicago_seq")) end

    update_first(doc, "events", has_seq, fn event ->
      Map.update!(event, "attributes", fn attrs ->
        Enum.map(attrs, fn
          %{"name" => "chicago_seq"} = a -> %{a | "value" => "12x"}
          a -> a
        end)
      end)
    end)
  end

  defp unparseable_event_time(%{doc: doc}) do
    update_first(doc, "events", &is_map/1, &Map.put(&1, "time", "2026-13-45T99:99:99Z"))
  end

  defp unparseable_object_attribute_time(%{doc: doc}) do
    update_first(doc, "objects", &match?([_ | _], &1["attributes"]), fn object ->
      update_in(object, ["attributes", Access.at(0), "time"], fn _ -> "yesterday" end)
    end)
  end

  defp duplicate_object_id(%{doc: doc}) do
    case doc["objects"] do
      [first | _] = objects -> encode(%{doc | "objects" => objects ++ [first]})
      _ -> {:error, "no objects"}
    end
  end

  defp duplicate_event_id(%{doc: doc}) do
    case doc["events"] do
      [first, second | rest] ->
        encode(%{doc | "events" => [first, %{second | "id" => first["id"]} | rest]})

      _ ->
        {:error, "fewer than two events"}
    end
  end

  defp missing_top_level_key(%{doc: doc}) do
    if Map.has_key?(doc, "eventTypes"),
      do: encode(Map.delete(doc, "eventTypes")),
      else: {:error, "no eventTypes key"}
  end

  defp truncated_bytes(%{bytes: bytes}) when byte_size(bytes) > 1,
    do: {:ok, binary_part(bytes, 0, byte_size(bytes) - 1)}

  defp truncated_bytes(_), do: {:error, "artifact too small to truncate"}

  defp undeclared_event_type(%{doc: doc}) do
    update_first(
      doc,
      "events",
      &is_map/1,
      &Map.put(&1, "type", "sa2a.ocel.undeclared_event_type")
    )
  end

  defp undeclared_object_type(%{doc: doc}) do
    update_first(
      doc,
      "objects",
      &is_map/1,
      &Map.put(&1, "type", "sa2a_ocel_undeclared_object_type")
    )
  end

  defp non_string_qualifier(%{doc: doc}) do
    update_first(doc, "events", &match?([_ | _], &1["relationships"]), fn event ->
      update_in(event, ["relationships", Access.at(0), "qualifier"], fn _ -> 42 end)
    end)
  end

  defp non_ocel_attribute_type(%{doc: doc}) do
    update_first(doc, "eventTypes", &match?([_ | _], &1["attributes"]), fn decl ->
      update_in(decl, ["attributes", Access.at(0), "type"], fn _ -> "datetime" end)
    end)
  end

  defp duplicate_type_name(%{doc: doc}) do
    case doc["eventTypes"] do
      [first | _] = decls ->
        encode(%{doc | "eventTypes" => decls ++ [%{"name" => first["name"], "attributes" => []}]})

      _ ->
        {:error, "no eventTypes"}
    end
  end

  defp update_first(doc, key, pred, fun) do
    case Enum.find_index(doc[key] || [], pred) do
      nil -> {:error, "no #{key} entry satisfies the corruption precondition"}
      i -> encode(%{doc | key => List.update_at(doc[key], i, fun)})
    end
  end

  defp encode(doc), do: {:ok, JSON.encode!(doc)}

  defp reverse_arrays(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, reverse_arrays(v)} end)

  defp reverse_arrays(list) when is_list(list),
    do: list |> Enum.map(&reverse_arrays/1) |> Enum.reverse()

  # :json.format/1 spells JSON null as the atom `null`, not Elixir's `nil`.
  defp reverse_arrays(nil), do: :null
  defp reverse_arrays(other), do: other

  # --- evidence helpers --------------------------------------------------------------

  defp durable_write!(dir, name, bytes) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name <> ".ocel.json")
    {:ok, io} = File.open(path, [:write, :binary, :raw])

    try do
      :ok = :file.write(io, bytes)
      :ok = :file.sync(io)
    after
      File.close(io)
    end

    path
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp observed_for?(ctx, f, activity, sha) do
    Enum.any?(
      Context.observed(ctx, f),
      &(&1.activity == activity and &1.attributes["artifact_sha256"] == sha)
    )
  end

  defp observed_attr?(ctx, f, activity, attr, value) do
    Enum.any?(
      Context.observed(ctx, f),
      &(&1.activity == activity and &1.attributes[attr] == value)
    )
  end

  defp targeted?(report, code, prefix) do
    Enum.any?(
      report["errors"] || [],
      &(&1["code"] == code and String.starts_with?(&1["path"], prefix))
    )
  end

  defp error_codes(%{"valid" => true}), do: "valid"

  defp error_codes(report) do
    codes = (report["errors"] || []) |> Enum.map(& &1["code"]) |> Enum.uniq() |> Enum.sort()
    "invalid(#{report["error_count"]}: #{Enum.join(codes, ",")})"
  end

  defp summarize(nil), do: nil

  defp summarize(report) do
    %{
      "valid" => report["valid"],
      "artifact_sha256" => report["artifact_sha256"],
      "error_count" => report["error_count"],
      "errors" => Enum.take(report["errors"] || [], 5),
      "counts" => report["counts"],
      "validator" => report["validator"]
    }
  end
end
