defmodule AshA2A.Chicago.Courts.ObserverQualification do
  @moduledoc """
  Process observer qualification court (RFC-SA2A-002 §19, §20, §107, §108,
  §138, §139).

  "An observer that silently loses required evidence cannot confer a Chicago
  Crown even if the SUT behaved correctly" (§138). This court attacks the
  real `AshA2A.Chicago.Observer` -- the component that turns SUT telemetry
  into the durable OCEL artifact every other court's standing rests on -- with
  one falsifier per §138/§139/§108 failure mode plus positive controls:

  | id  | attack                                                               |
  |-----|----------------------------------------------------------------------|
  | 001 | observer killed / suspended mid-run (through Runner + StandingReceipt) |
  | 002 | duplicated delivery, twice-mapped events, duplicated serialization  |
  | 003 | malformed, colliding and forged object relationship identities       |
  | 004 | many concurrent emitters and an out-of-order delivery                |
  | 005 | observer crash, journal corruption and restart recovery              |
  | 006 | flipped byte in `ocel.json` (consumer and runner)                    |
  | 007 | unmapped telemetry and unknown object types                          |
  | 008 | §139 fresh OS process reads the artifact after producer and observer die |
  | 009 | §108 static non-authority proof + observer outage around a real DO   |
  | 010-014 | positive controls: steady run, well-formed refs, intact artifact, prover discrimination, fresh-reader discrimination |

  Each attack runs against a scratch observer (or an inner run's observer)
  that the court itself disturbs; the run's own observer stays healthy and
  records the scratch observer's real boundary telemetry
  (`[:ash_a2a, :chicago, :observer | _]`, `[:ash_a2a, :chicago, :ocel | _]`,
  `[:ash_a2a, :chicago, :run, :stop]`) as the attempt and outcome evidence
  the independent consumer corroborates.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Authority, Command, CommandBus, Identity}

  alias AshA2A.Chicago.{
    Context,
    Falsifier,
    Observer,
    Query,
    Result,
    Runner
  }

  alias AshA2A.Chicago.Fixtures.ObserverQualification, as: Fx
  alias AshA2A.Chicago.Observer.NonAuthority
  alias AshA2A.Chicago.Ocel.{FreshReader, Mapping, SutMappings}

  @court "SA2A-OCEL-OBSERVER"
  @unknown_type "quasar_ledger_entry"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Process observer qualification"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§19", "§20", "§107", "§108", "§138", "§139"]

  @doc """
  Refusal codes introduced by the observer-qualification modules
  (`Observer.Journal`, `Query.load/2` identity check, `AbstractCode`,
  `Ocel.FreshReader`), classified without editing the Refusal table.
  """
  @impl true
  def refusal_codes do
    %{
      corrupt: :refused_receipt,
      ocel_duplicate_event_identity: :refused_receipt,
      journal_run_mismatch: :refused_receipt,
      journal_unavailable: :blocked_resource,
      journal_unreadable: :blocked_resource,
      no_debug_info: :blocked_unknown,
      elixir_executable_not_found: :blocked_resource
    }
  end

  # --- OCEL mappings for the observer / consumer / runner boundaries ---------

  @impl true
  def ocel_mappings do
    boundary = [
      {[:observer, :dropped], "observer.dropped", [:reason, :event, :activity]},
      {[:observer, :ref_rejected], "observer.ref_rejected", [:reason, :object_type, :event]},
      {[:observer, :unmapped], "observer.unmapped", [:event]},
      {[:observer, :recovered], "observer.recovered",
       [
         :incarnation,
         :recovered_records,
         :gaps,
         :dropped,
         :dropped_while_down,
         :corrupt_lines,
         :duplicate_lines,
         :torn_tail
       ]},
      {[:observer, :flushed], "observer.flushed",
       [
         :events,
         :objects,
         :dropped,
         :gaps,
         :late,
         :unmapped,
         :rejected_refs,
         :incarnation,
         :ordered,
         :identity_unique
       ]},
      {[:observer, :non_authority], "observer.non_authority",
       [:outcome, :modules_scanned, :functions_scanned, :remote_calls, :violations, :unprovable]},
      {[:ocel, :load], "ocel.load",
       [:outcome, :code, :digest_verified, :identity_unique, :array_ordered, :events]},
      {[:ocel, :fresh_read], "ocel.fresh_read",
       [:outcome, :os_exit, :digest_match, :events_match, :objects_match, :ordered]}
    ]

    observer_boundary =
      for {suffix, activity, keys} <- boundary do
        Mapping.new!(
          event: [:ash_a2a, :chicago | suffix],
          activity: activity,
          source: __MODULE__,
          objects: fn _m, meta ->
            [
              {"observer", meta[:observer_run_id], "observer"},
              {"ocel_artifact", meta[:sha256], "artifact"},
              {"qualification_run", meta[:run_id], "run"}
            ]
          end,
          attributes: fn _m, meta -> Map.take(meta, keys) end
        )
      end

    # `chicago.run.stop` is the runner's one standing-issued event, shared
    # with the identity court (CHI-ID); the runner admits it once.
    observer_boundary ++ [Runner.stop_mapping()]
  end

  # --- declarations ----------------------------------------------------------

  @impl true
  def falsifiers do
    [
      negative(1,
        invariant:
          "An observer outage (killed or suspended mid-run) is recorded as dropped evidence and never yields CONFORMANT standing (§138, §108)",
        stimulus:
          "two real Runner.run/1 executions of inner courts that kill / :sys.suspend the run's observer process mid-run and keep emitting",
        boundary:
          "AshA2A.Chicago.Observer delivery + AshA2A.Chicago.Runner outage recovery + AshA2A.Chicago.StandingReceipt",
        forbidden_outcome:
          "no standing receipt issued, a receipt reporting zero dropped records, or CONFORMANT standing",
        attempt_evidence:
          "observer.dropped emitted by the observer's handler in the emitting process",
        survival_evidence:
          "chicago.run.stop missing or reporting ocel_dropped 0 / CONFORMANT; standing_receipt.json read back from disk",
        guard:
          "Observer.handle_event/4 drop counter, Runner observer outage recovery (Observer.ensure_running/2), StandingReceipt dropped/gaps clause",
        failure_class: :ocel_evidence_incomplete,
        attempt_predicate: {:observed, "observer.dropped"},
        outcome_predicate:
          {:any,
           [
             {:count, "chicago.run.stop", :lte, 1},
             {:observed, "chicago.run.stop", %{"standing" => "CONFORMANT"}},
             {:observed, "chicago.run.stop", %{"ocel_dropped" => 0}}
           ]}
      ),
      negative(2,
        invariant:
          "Every delivery is its own record: duplicated telemetry is neither collapsed nor allowed to share an identity, and duplicated serialized identities are refused (§138, §20)",
        stimulus:
          "identical telemetry emitted 4x from 3 processes; one event mapped by two admitted mappings; an artifact with a duplicated event; a duplicated journal line",
        boundary:
          "AshA2A.Chicago.Observer record identity + AshA2A.Chicago.Query.load/2 identity check + journal recovery",
        forbidden_outcome:
          "records collapsed or sharing chicago_seq / event id, a duplicated-identity artifact admitted, a journal duplicate restored twice",
        attempt_evidence: "observer.flushed and ocel.load events",
        survival_evidence:
          "raw artifact identity scan; Query.duplicates/1; ocel.load outcome; recovered record count",
        guard:
          "per-record System.unique_integer seq in Observer.mapped_record, Query identity check, Journal.recover seq dedupe",
        failure_class: :ocel_evidence_incomplete,
        attempt_predicate: {:all, [{:observed, "observer.flushed"}, {:observed, "ocel.load"}]},
        outcome_predicate:
          {:any,
           [
             {:observed, "observer.flushed", %{"identity_unique" => false}},
             {:observed, "ocel.load", %{"outcome" => "loaded", "identity_unique" => false}},
             {:not_observed, "ocel.load",
              %{"outcome" => "refused", "code" => "ocel_duplicate_event_identity"}}
           ]}
      ),
      negative(3,
        invariant:
          "Malformed, colliding or reserved object references are dropped and flagged, never fabricated into OCEL objects or falsifier attribution (§138, §107)",
        stimulus:
          "a mapping presenting map / invalid-UTF-8 / empty ids, a non-string type, a colon type colliding with command:a:b, reserved falsifier/court types and a malformed tuple",
        boundary: "AshA2A.Chicago.Ocel.Mapping.resolve_objects/3 in the observer handler",
        forbidden_outcome:
          "a fabricated or forged object in the artifact, an identity collision, or a silent (unflagged) drop",
        attempt_evidence: "observer.flushed of the scratch artifact",
        survival_evidence:
          "artifact objects/relationships read from disk; chicago_rejected_refs attribute; observer.ref_rejected events",
        guard:
          "Mapping.validate_ref/1 (type/id/qualifier/reserved checks) + observer.ref_rejected flagging",
        failure_class: :ocel_evidence_incomplete,
        attempt_predicate: {:observed, "observer.flushed"},
        outcome_predicate:
          {:any,
           [
             {:not_observed, "observer.ref_rejected"},
             {:observed, "observer.flushed", %{"rejected_refs" => 0}}
           ]}
      ),
      negative(4,
        invariant:
          "Under concurrent, out-of-order ingestion the artifact is ordered by chicago_seq, loses nothing, preserves per-emitter order, and attributes by sequence -- not by arrival (§20)",
        stimulus:
          "24 processes x 40 events inside a stimulus, plus one emitter whose sequence precedes the stimulus but whose delivery is released during it",
        boundary: "AshA2A.Chicago.Observer ingestion, attribution and flush",
        forbidden_outcome:
          "lost events, events array not strictly increasing in chicago_seq, per-emitter reordering, or the pre-stimulus event attributed to the stimulus",
        attempt_evidence: "observer.flushed of the scratch artifact",
        survival_evidence: "artifact events read from disk and Query.scope/2",
        guard: "seq-interval attribution in Observer.attribute/1 and seq-sorted flush",
        failure_class: :ocel_evidence_incomplete,
        attempt_predicate: {:observed, "observer.flushed"},
        outcome_predicate:
          {:any,
           [
             {:observed, "observer.flushed", %{"ordered" => false}},
             {:observed, "ocel.load", %{"array_ordered" => false}},
             {:observed, "observer.dropped"}
           ]}
      ),
      negative(5,
        invariant:
          "Evidence survives an observer crash through the durable journal, and recovery marks the gap (drops, corrupt lines) instead of pretending continuity (§19, §138)",
        stimulus:
          "kill a journaling observer mid-run, emit while it is down, flip a byte in and tear the tail of the real journal file, start a recovery incarnation",
        boundary: "AshA2A.Chicago.Observer.Journal + Observer recovery init",
        forbidden_outcome:
          "pre-crash evidence lost, a corrupted line restored, zero gaps, or drops while down unreported",
        attempt_evidence: "observer.dropped while down and observer.flushed after recovery",
        survival_evidence:
          "recovered artifact read from disk (pre-crash records, chicago.observer.gap event), flush gaps/dropped",
        guard: "Journal.append/2 per record, Journal.recover/1 hash check, Observer gap record",
        failure_class: :ocel_evidence_incomplete,
        attempt_predicate:
          {:all, [{:observed, "observer.dropped"}, {:observed, "observer.flushed"}]},
        outcome_predicate:
          {:any,
           [
             {:not_observed, "observer.recovered"},
             {:observed, "observer.recovered", %{"gaps" => 0}},
             {:observed, "observer.flushed", %{"gaps" => 0}}
           ]}
      ),
      negative(6,
        invariant:
          "A single flipped byte in the durable OCEL artifact is refused by digest in the independent consumer and by the runner (§16, §19)",
        stimulus:
          "flip one bit of a flushed ocel.json; corroborate through Runner.corroborate_all/3; a real Runner.run/1 whose post-flush validator step flips a byte",
        boundary:
          "AshA2A.Chicago.Query.load/2 digest check + AshA2A.Chicago.Runner corroboration",
        forbidden_outcome: "corrupted bytes loaded, or any result corroborated from them",
        attempt_evidence: "ocel.load refused",
        survival_evidence:
          "Query.load result, corroboration flags, inner standing receipt from disk",
        guard: "Query.check_digest/2 and Runner.corroborate_all/3 refusal branch",
        failure_class: :ocel_validation_failure,
        attempt_predicate: {:observed, "ocel.load", %{"outcome" => "refused"}},
        outcome_predicate:
          {:any,
           [
             {:observed, "ocel.load", %{"outcome" => "loaded"}},
             {:not, {:observed, "chicago.run.stop", %{"ocel_corroborated" => 0}}}
           ]}
      ),
      negative(7,
        invariant:
          "Unmapped telemetry is typed and preserved, never silently absorbed; unknown object types are preserved and declared (§138, §17)",
        stimulus:
          "an event the observer watches without an admitted mapping; a mapping producing never-seen string and atom object types",
        boundary:
          "AshA2A.Chicago.Observer unmapped handling + Mapping type coercion + Runner watch vocabulary",
        forbidden_outcome:
          "no chicago.unmapped event in the artifact, an unknown object type dropped or retyped, or the run observer blind to real SUT events with no mapping",
        attempt_evidence: "observer.flushed of the scratch artifact",
        survival_evidence:
          "artifact events/objects/objectTypes read from disk; run observer watch list",
        guard:
          "Observer unmapped record + observer.unmapped telemetry; Mapping.object_type/1; SutEvents discovery",
        failure_class: :ocel_evidence_incomplete,
        attempt_predicate: {:observed, "observer.flushed"},
        outcome_predicate:
          {:any,
           [
             {:not_observed, "observer.unmapped"},
             {:observed, "observer.flushed", %{"unmapped" => 0}}
           ]}
      ),
      negative(8,
        invariant:
          "After producer and observer terminate, a separate OS process reads the artifact and reproduces its digest and counts (§139, §19)",
        stimulus:
          "flush a scratch observer fed by a producer process, terminate both, read ocel.json in a fresh `elixir -e` OS process",
        boundary: "AshA2A.Chicago.Ocel.FreshReader.verify/2 over the flushed artifact",
        forbidden_outcome:
          "the fresh process cannot reproduce digest, event count or object count",
        attempt_evidence: "ocel.fresh_read after producer and observer processes are dead",
        survival_evidence: "fresh process report vs the observer flush result",
        guard: "Observer durable_write/2 (fsync) + content-addressed flush result",
        failure_class: :fresh_consumer_failure,
        attempt_predicate: {:observed, "ocel.fresh_read"},
        outcome_predicate: {:not, {:observed, "ocel.fresh_read", %{"outcome" => "reproduced"}}}
      ),
      negative(9,
        invariant:
          "Observe ⇏ DO: the observer's code closure cannot call a consequence boundary, and an observer outage never produces an execution (§108)",
        stimulus:
          "static abstract-code proof over the observer closure; kill an observer attached to CommandBus telemetry, then run a denied and an authorized command through the real CommandBus",
        boundary: "AshA2A.Chicago.Observer.NonAuthority.prove/1 + AshA2A.CommandBus admission",
        forbidden_outcome:
          "a reachable call into CommandBus/Dispatcher/Authority/Ash actions, an unprovable call, the denied row, or more than one execution",
        attempt_evidence: "observer.non_authority, brce.admission refused, observer.dropped",
        survival_evidence: "proof report; independent Ash.read!/1 of the Ledger fixture",
        guard:
          "observer modules hold no consequence call sites; CommandBus admission is independent of telemetry delivery",
        failure_class: :authority_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "observer.non_authority"},
             {:observed, "brce.admission", %{"outcome" => "refused"}},
             {:observed, "observer.dropped"}
           ]},
        outcome_predicate:
          {:any,
           [
             {:not, {:observed, "observer.non_authority", %{"outcome" => "proved"}}},
             {:not, {:count, "brce.actuate.start", :lte, 1}}
           ]}
      ),
      positive(10,
        invariant:
          "An uninterrupted run reports zero dropped records and zero gaps and corroborates its results: the drop/gap guard discriminates",
        stimulus: "real Runner.run/1 of an inner court with no disturbance",
        boundary: "AshA2A.Chicago.Observer + Runner + StandingReceipt",
        attempt_evidence: "chicago.run.stop",
        survival_evidence: "standing_receipt.json evidence block read from disk",
        attempt_predicate: {:observed, "chicago.run.stop"},
        outcome_predicate:
          {:observed, "chicago.run.stop", %{"ocel_dropped" => 0, "ocel_gaps" => 0}}
      ),
      positive(11,
        invariant:
          "Well-formed but unusual references (unicode, integer, atom, identity struct, colon-bearing ids) are preserved unflagged: the reference guard discriminates",
        stimulus: "a mapping presenting only well-formed references plus an absent (nil) id",
        boundary: "AshA2A.Chicago.Ocel.Mapping.resolve_objects/3 in the observer handler",
        attempt_evidence: "observer.flushed",
        survival_evidence: "artifact objects read from disk; zero rejected refs",
        attempt_predicate: {:observed, "observer.flushed"},
        outcome_predicate:
          {:all,
           [
             {:observed, "observer.flushed",
              %{"rejected_refs" => 0, "unmapped" => 0, "dropped" => 0}},
             {:not_observed, "observer.ref_rejected"}
           ]}
      ),
      positive(12,
        invariant:
          "An intact artifact loads by digest with unique identities, and a cleanly closed journal restores every record with zero corrupt or duplicate lines",
        stimulus: "flush + load an intact scratch artifact; recover its clean journal",
        boundary: "AshA2A.Chicago.Query.load/2 + Observer.Journal.recover/1",
        attempt_evidence: "ocel.load",
        survival_evidence: "load result; recovery statistics",
        attempt_predicate: {:observed, "ocel.load"},
        outcome_predicate:
          {:all,
           [
             {:observed, "ocel.load",
              %{"outcome" => "loaded", "digest_verified" => true, "identity_unique" => true}},
             {:observed, "observer.recovered", %{"corrupt_lines" => 0, "duplicate_lines" => 0}}
           ]}
      ),
      positive(13,
        invariant:
          "The non-authority prover refuses a mapping source that reaches AshA2A.CommandBus",
        stimulus: "prove over the LeakingMapping fixture's ocel_mappings/0 closure",
        boundary: "AshA2A.Chicago.Observer.NonAuthority.prove/1",
        attempt_evidence: "observer.non_authority",
        survival_evidence: "proof report violations",
        attempt_predicate: {:observed, "observer.non_authority"},
        outcome_predicate: {:observed, "observer.non_authority", %{"outcome" => "violated"}}
      ),
      positive(14,
        invariant:
          "The fresh-process reader reports divergence for bytes that differ from the claimed digest",
        stimulus: "fresh-process read of a byte-flipped copy of an intact artifact",
        boundary: "AshA2A.Chicago.Ocel.FreshReader.verify/2",
        attempt_evidence: "ocel.fresh_read",
        survival_evidence: "fresh process report",
        attempt_predicate: {:observed, "ocel.fresh_read"},
        outcome_predicate: {:observed, "ocel.fresh_read", %{"outcome" => "diverged"}}
      )
    ]
  end

  defp negative(n, fields),
    do:
      Falsifier.new!(
        [id: fid(n), court_id: @court, kind: :negative, rfc_sections: rfc()] ++ fields
      )

  defp positive(n, fields),
    do:
      Falsifier.new!(
        [id: fid(n), court_id: @court, kind: :positive_control, rfc_sections: rfc()] ++ fields
      )

  defp fid(n), do: @court <> "-" <> String.pad_leading(Integer.to_string(n), 3, "0")
  defp rfc, do: ["§138"]

  # --- run -------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    by_id = Map.new(falsifiers(), &{&1.id, &1})

    [
      {1, &dropped_events/2},
      {2, &duplicated_delivery/2},
      {3, &corrupted_identity/2},
      {4, &out_of_order/2},
      {5, &restart_recovery/2},
      {6, &serialization_corruption/2},
      {7, &unknown_types/2},
      {8, &fresh_process_read/2},
      {9, &non_authority/2},
      {10, &steady_control/2},
      {11, &well_formed_refs_control/2},
      {12, &intact_artifact_control/2},
      {13, &prover_control/2},
      {14, &fresh_reader_control/2}
    ]
    |> Enum.map(fn {n, fun} ->
      f = Map.fetch!(by_id, fid(n))

      try do
        fun.(ctx, f)
      rescue
        exception ->
          Result.unknown(
            f,
            "stimulus raised: " <> Exception.format(:error, exception, __STACKTRACE__)
          )
      catch
        kind, reason -> Result.unknown(f, "stimulus #{kind}: #{inspect(reason, limit: 20)}")
      end
    end)
  end

  # --- 001 dropped events ------------------------------------------------------

  defp dropped_events(ctx, f) do
    {killed, suspended} =
      Context.stimulus(ctx, f, fn ->
        killed =
          isolated(fn ->
            Runner.run(
              profile: :core,
              courts: [Fx.OutageCourt],
              evidence_dir: scratch_dir(ctx, "001-killed"),
              run_id: scratch_run_id("001-killed")
            )
          end)

        suspended =
          isolated(fn ->
            Runner.run(
              profile: :core,
              courts: [Fx.SuspendCourt],
              evidence_dir: scratch_dir(ctx, "001-suspended"),
              run_id: scratch_run_id("001-suspended"),
              observer_delivery_timeout_ms: 150
            )
          end)

        {killed, suspended}
      end)

    killed_view = inner_receipt_view(killed)
    suspended_view = inner_receipt_view(suspended)

    forbidden =
      Enum.any?([killed_view, suspended_view], fn view ->
        view.receipt? == false or view.standing == "CONFORMANT" or view.dropped in [0, nil]
      end) or killed_view.gaps in [0, nil]

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "observer.dropped"),
      forbidden_outcome_observed?: forbidden,
      evidence: %{"killed" => killed_view, "suspended" => suspended_view}
    )
  end

  # --- 002 duplicated delivery -------------------------------------------------

  defp duplicated_delivery(ctx, f) do
    run_id = scratch_run_id("002")
    dir = scratch_dir(ctx, "002")
    journal = journal_path(dir, run_id)

    opts = [
      run_id: run_id,
      mappings: [Fx.probe_mapping() | Fx.twin_mappings()],
      journal: journal
    ]

    view =
      Context.stimulus(ctx, f, fn ->
        {:ok, observer} = start_scratch(opts)

        try do
          meta = %{probe_id: "dup-1", label: "identical", i: 1}
          Fx.probe(meta)
          Fx.probe(meta)
          1..2 |> Enum.map(fn _ -> Task.async(fn -> Fx.probe(meta) end) end) |> Task.await_many()
          Fx.emit(:twin, %{}, %{twin_id: "twin-1"})

          {:ok, flush} = Observer.flush(observer, dir)
          stop_scratch(observer, run_id)

          doc = decode_file!(flush.path)
          probes = events_of(doc, "fixture.probe")
          twins = Enum.filter(doc["events"], &String.starts_with?(&1["type"], "fixture.twin."))

          detector =
            case Query.load(flush.path, flush.sha256) do
              {:ok, index} ->
                if function_exported?(Query, :duplicates, 1),
                  do:
                    index
                    |> Query.duplicates()
                    |> Enum.find(&(&1.type == "fixture.probe"))
                    |> then(&(&1 && &1.count)),
                  else: :absent

              {:error, reason} ->
                {:load_failed, inspect(reason)}
            end

          dup_path = Path.join(dir, "duplicated-event-ocel.json")
          File.write!(dup_path, duplicate_first_event(doc))
          dup_load = Query.load(dup_path)

          journal_dup = journal_duplicate_recovery(opts, journal)

          %{
            "probe_records" => length(probes),
            "probe_seqs_distinct" => distinct?(Enum.map(probes, &seq_of/1)),
            "event_ids_distinct" => distinct?(Enum.map(doc["events"], & &1["id"])),
            "seqs_distinct" => distinct?(Enum.map(doc["events"], &seq_of/1)),
            "twin_records" => length(twins),
            "detector_group_size" => json_safe(detector),
            "duplicated_artifact" => load_outcome(dup_load),
            "journal_duplicate" => journal_dup
          }
        after
          stop_scratch(observer, run_id)
        end
      end)

    forbidden =
      view["probe_records"] != 4 or not view["probe_seqs_distinct"] or
        not view["event_ids_distinct"] or not view["seqs_distinct"] or view["twin_records"] != 2 or
        view["duplicated_artifact"] == "loaded" or view["detector_group_size"] != 4 or
        view["journal_duplicate"]["restored_twice"] != false or
        view["journal_duplicate"]["duplicate_lines"] != 1

    Result.negative(f,
      attempt_observed?:
        Context.observed?(ctx, f, "observer.flushed") and Context.observed?(ctx, f, "ocel.load"),
      forbidden_outcome_observed?: forbidden,
      evidence: view
    )
  end

  defp journal_duplicate_recovery(opts, journal) do
    with true <- File.exists?(journal),
         {:ok, lines} <- File.read(journal),
         line when is_binary(line) <-
           lines |> String.split("\n", trim: true) |> Enum.find(&(&1 =~ ~s("kind":"record"))) do
      before = lines |> String.split("\n", trim: true) |> Enum.count(&(&1 =~ ~s("kind":"record")))
      File.write!(journal, line <> "\n", [:append])
      {:ok, recovered} = start_scratch(opts)

      try do
        stats = Observer.stats(recovered)

        restored =
          recovered |> Observer.records() |> Enum.count(&(&1.activity != "chicago.observer.gap"))

        %{
          "records_in_journal" => before,
          "restored" => restored,
          "restored_twice" => restored > before,
          "duplicate_lines" => stats.duplicate_journal_lines
        }
      after
        stop_scratch(recovered, Keyword.fetch!(opts, :run_id))
      end
    else
      _ -> %{"restored_twice" => :absent, "duplicate_lines" => :absent, "detail" => "no journal"}
    end
  rescue
    exception ->
      %{
        "restored_twice" => :absent,
        "duplicate_lines" => :absent,
        "detail" => Exception.message(exception)
      }
  end

  # --- 003 corrupted relationship identity -------------------------------------

  defp corrupted_identity(ctx, f) do
    run_id = scratch_run_id("003")
    dir = scratch_dir(ctx, "003")

    refs = [
      {"widget", "w-1", "subject"},
      {"widget", %{bad: 1}, "subject"},
      {"widget", <<0xFF, 0xFE>>, "subject"},
      {"widget", "", "subject"},
      {42, "x", "subject"},
      {"command:a", "b", "subject"},
      {"command", "a:b", "subject"},
      {"falsifier", f.id, "under_stimulus"},
      {"court", @court, "court"},
      {:only, :two},
      {"widget", nil, "subject"}
    ]

    view =
      Context.stimulus(ctx, f, fn ->
        {:ok, observer} = start_scratch(run_id: run_id, mappings: [Fx.refs_mapping(:refs)])

        try do
          Fx.emit(:refs, %{}, %{refs: refs, label: "corrupted"})
          {:ok, flush} = Observer.flush(observer, dir)
          doc = decode_file!(flush.path)
          [event] = events_of(doc, "fixture.refs")
          object_ids = Enum.map(doc["objects"], & &1["id"])
          rel_ids = Enum.map(event["relationships"], & &1["objectId"])
          attrs = attributes(event)
          {:ok, index} = Query.load(flush.path, flush.sha256)

          %{
            "objects" => object_ids,
            "widget_objects" => Enum.filter(object_ids, &String.starts_with?(&1, "widget:")),
            "forged_falsifier_object" => ("falsifier:" <> f.id) in object_ids,
            "forged_scope" => length(Query.scope(index, f.id)),
            "forged_court_object" =>
              Enum.any?(event["relationships"], &(&1["qualifier"] == "court")),
            "relationship_collision" => not distinct?(rel_ids),
            "command_object_types" =>
              doc["objects"]
              |> Enum.filter(&(&1["id"] == "command:a:b"))
              |> Enum.map(& &1["type"]),
            "rejected_attribute" => attrs["chicago_rejected_refs"],
            "flush_rejected_refs" => Map.get(flush, :rejected_refs, :absent)
          }
        after
          stop_scratch(observer, run_id)
        end
      end)

    forbidden =
      view["widget_objects"] != ["widget:w-1"] or view["forged_falsifier_object"] or
        view["forged_scope"] > 0 or view["forged_court_object"] or view["relationship_collision"] or
        view["command_object_types"] != ["command"] or view["rejected_attribute"] != 8 or
        view["flush_rejected_refs"] != 8

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "observer.flushed"),
      forbidden_outcome_observed?: forbidden,
      evidence: view
    )
  end

  # --- 004 out-of-order ingestion ---------------------------------------------

  @emitters 24
  @per_emitter 40

  defp out_of_order(ctx, f) do
    run_id = scratch_run_id("004")
    dir = scratch_dir(ctx, "004")

    opts = [
      run_id: run_id,
      mappings: [Fx.probe_mapping(), Fx.gated_mapping()],
      journal: journal_path(dir, run_id)
    ]

    view =
      Context.stimulus(ctx, f, fn ->
        {:ok, observer} = start_scratch(opts)
        scratch_ctx = %{ctx | run_id: run_id, observer: observer}

        try do
          owner = self()
          gate = make_ref()

          {delayed, delayed_ref} =
            spawn_monitor(fn ->
              Fx.emit(:gated, %{}, %{
                probe_id: "late-1",
                label: "pre-stimulus",
                gate_owner: owner,
                gate_ref: gate
              })
            end)

          # The delayed emitter has taken its sequence number and is blocked
          # before delivering the record.
          receive do
            {:gated_waiting, ^delayed, ^gate} -> :ok
          after
            10_000 -> raise "gated emitter never reached the observer handler"
          end

          Context.stimulus(scratch_ctx, f, fn ->
            tasks =
              for e <- 1..@emitters do
                Task.async(fn ->
                  for i <- 1..@per_emitter,
                      do:
                        Fx.probe(%{probe_id: "e#{e}-#{i}", emitter: e, i: i, label: "concurrent"})
                end)
              end

            send(delayed, {:release, gate})

            receive do
              {:DOWN, ^delayed_ref, :process, _, _} -> :ok
            after
              30_000 -> :ok
            end

            Task.await_many(tasks, 120_000)
          end)

          {:ok, flush} = Observer.flush(observer, dir)
          stop_scratch(observer, run_id)
          {:ok, index} = Query.load(flush.path, flush.sha256)
          doc = decode_file!(flush.path)
          seqs = Enum.map(doc["events"], &seq_of/1)
          probes = events_of(doc, "fixture.probe")
          scoped = index |> Query.scope(f.id) |> MapSet.new(& &1.id)
          [late] = events_of(doc, "fixture.gated")

          per_emitter_ordered =
            probes
            |> Enum.group_by(&attributes(&1)["emitter"])
            |> Enum.all?(fn {_e, events} ->
              is = Enum.map(events, &attributes(&1)["i"])
              is == Enum.sort(is)
            end)

          %{
            "probe_events" => length(probes),
            "expected_probe_events" => @emitters * @per_emitter,
            "strictly_ordered" => strictly_increasing?(seqs),
            "per_emitter_ordered" => per_emitter_ordered,
            "late_event_attributed" => MapSet.member?(scoped, late["id"]),
            "concurrent_unattributed" =>
              Enum.count(probes, &(not MapSet.member?(scoped, &1["id"]))),
            "dropped" => flush.dropped
          }
        after
          stop_scratch(observer, run_id)
        end
      end)

    forbidden =
      view["probe_events"] != view["expected_probe_events"] or not view["strictly_ordered"] or
        not view["per_emitter_ordered"] or view["late_event_attributed"] or
        view["concurrent_unattributed"] > 0 or view["dropped"] > 0

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "observer.flushed"),
      forbidden_outcome_observed?: forbidden,
      evidence: view
    )
  end

  # --- 005 restart recovery ---------------------------------------------------

  defp restart_recovery(ctx, f) do
    run_id = scratch_run_id("005")
    dir = scratch_dir(ctx, "005")
    journal = journal_path(dir, run_id)

    opts = [
      run_id: run_id,
      mappings: [Fx.probe_mapping()],
      journal: journal,
      delivery_timeout_ms: 500
    ]

    view =
      Context.stimulus(ctx, f, fn ->
        {:ok, first} = start_scratch(opts)

        try do
          for i <- 1..5, do: Fx.probe(%{probe_id: "pre-#{i}", i: i, label: "pre-crash"})
          kill!(first)
          for i <- 1..4, do: Fx.probe(%{probe_id: "down-#{i}", i: i, label: "while-down"})
          corruption = corrupt_journal(journal)

          {:ok, second} = start_scratch(opts)

          try do
            for i <- 1..3, do: Fx.probe(%{probe_id: "post-#{i}", i: i, label: "post-recovery"})
            {:ok, flush} = Observer.flush(second, dir)
            doc = decode_file!(flush.path)
            labels = doc |> events_of("fixture.probe") |> Enum.map(&attributes(&1)["label"])
            gaps = events_of(doc, "chicago.observer.gap")

            %{
              "journal_corruption" => corruption,
              "pre_crash_restored" => Enum.count(labels, &(&1 == "pre-crash")),
              "corrupted_line_restored" =>
                Enum.any?(labels, &(&1 not in ["pre-crash", "post-recovery"])),
              "post_recovery" => Enum.count(labels, &(&1 == "post-recovery")),
              "gap_events" => length(gaps),
              "gap_attributes" => gaps |> List.first() |> then(&(&1 && attributes(&1))),
              "flush_gaps" => Map.get(flush, :gaps, 0),
              "flush_dropped" => flush.dropped
            }
          after
            stop_scratch(second, run_id)
          end
        after
          stop_scratch(first, run_id)
        end
      end)

    forbidden =
      view["pre_crash_restored"] < 4 or view["corrupted_line_restored"] or
        view["post_recovery"] != 3 or view["gap_events"] < 1 or view["flush_gaps"] < 1 or
        view["flush_dropped"] < 4

    Result.negative(f,
      attempt_observed?:
        Context.observed?(ctx, f, "observer.dropped") and
          Context.observed?(ctx, f, "observer.flushed"),
      forbidden_outcome_observed?: forbidden,
      evidence: view
    )
  end

  # Environment fault on the real journal file: flip one bit inside the last
  # complete record line (keeps the line structure) and append a torn,
  # newline-less fragment.
  defp corrupt_journal(journal) do
    case File.read(journal) do
      {:ok, bytes} ->
        lines = String.split(bytes, "\n")

        record_idx =
          lines
          |> Enum.with_index()
          |> Enum.filter(fn {l, _} -> l =~ ~s("pre-crash") end)
          |> List.last()

        flipped =
          case record_idx do
            {line, idx} ->
              {pos, _} = :binary.match(line, "pre-crash")
              <<pre::binary-size(pos + 4), byte, post::binary>> = line
              List.replace_at(lines, idx, <<pre::binary, Bitwise.bxor(byte, 0x01), post::binary>>)

            nil ->
              lines
          end

        File.write!(journal, Enum.join(flipped, "\n") <> ~s({"kind":"record","seq":9))
        %{"flipped_record_line" => record_idx != nil, "torn_tail" => true}

      {:error, reason} ->
        %{"journal" => "absent: #{inspect(reason)}"}
    end
  end

  # --- 006 serialization corruption --------------------------------------------

  defp serialization_corruption(ctx, f) do
    run_id = scratch_run_id("006")
    dir = scratch_dir(ctx, "006")

    view =
      Context.stimulus(ctx, f, fn ->
        {:ok, observer} = start_scratch(run_id: run_id, mappings: [Fx.probe_mapping()])

        flush =
          try do
            for i <- 1..3, do: Fx.probe(%{probe_id: "s-#{i}", i: i, label: "serialized"})
            {:ok, flush} = Observer.flush(observer, dir)
            flush
          after
            stop_scratch(observer, run_id)
          end

        flip_middle_byte!(flush.path)
        direct = Query.load(flush.path, flush.sha256)

        probe_result =
          Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: false)

        corroborated = Runner.corroborate_all([probe_result], %{f.id => f}, flush)

        nested =
          isolated(fn ->
            Runner.run(
              profile: :core,
              courts: [Fx.SteadyCourt],
              evidence_dir: scratch_dir(ctx, "006-runner"),
              run_id: scratch_run_id("006-runner"),
              ocel_validator: Fx.CorruptingValidator
            )
          end)

        nested_corroborated =
          case nested do
            {:ok, {:ok, run}} -> Enum.count(run.results, &(&1.ocel_corroborated? == true))
            other -> {:no_run, inspect(other, limit: 10)}
          end

        %{
          "direct_load" => load_outcome(direct),
          "runner_corroborated" => Enum.count(corroborated, &(&1.ocel_corroborated? == true)),
          "nested_run" => inner_receipt_view(nested),
          "nested_corroborated" => json_safe(nested_corroborated)
        }
      end)

    forbidden =
      view["direct_load"] == "loaded" or view["runner_corroborated"] > 0 or
        view["nested_corroborated"] != 0 or view["nested_run"].standing == "CONFORMANT"

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "ocel.load"),
      forbidden_outcome_observed?: forbidden,
      evidence: view
    )
  end

  # --- 007 unknown event / object types ------------------------------------------

  defp unknown_types(ctx, f) do
    run_id = scratch_run_id("007")
    dir = scratch_dir(ctx, "007")
    unmapped_event = Fx.event(:unmapped)

    view =
      Context.stimulus(ctx, f, fn ->
        {:ok, observer} =
          start_scratch(
            run_id: run_id,
            mappings: [Fx.refs_mapping(:typed)],
            watch_events: [unmapped_event]
          )

        try do
          Fx.emit(unmapped_event, %{bytes: 12}, %{note: "no admitted mapping", code: "novel"})

          Fx.emit(:typed, %{}, %{
            refs: [{@unknown_type, "q-1", "subject"}, {:nebula_widget, "n-1", "subject"}],
            label: "typed"
          })

          {:ok, flush} = Observer.flush(observer, dir)
          doc = decode_file!(flush.path)
          dotted = Enum.map_join(unmapped_event, ".", &Atom.to_string/1)

          unmapped =
            doc
            |> events_of("chicago.unmapped")
            |> Enum.filter(&(attributes(&1)["telemetry_event"] == dotted))

          objects = Map.new(doc["objects"], &{&1["id"], &1["type"]})
          declared = MapSet.new(doc["objectTypes"], & &1["name"])

          run_watch =
            if is_pid(ctx.observer) and function_exported?(Observer, :watched_events, 1),
              do: [:ash_a2a, :ocel, :shed] in Observer.watched_events(ctx.observer),
              else: :absent

          %{
            "unmapped_events" => length(unmapped),
            "unmapped_attributes" => unmapped |> List.first() |> then(&(&1 && attributes(&1))),
            "unknown_string_type" => objects[@unknown_type <> ":q-1"],
            "unknown_atom_type" => objects["nebula_widget:n-1"],
            "types_declared" =>
              MapSet.member?(declared, @unknown_type) and
                MapSet.member?(declared, "nebula_widget"),
            "run_observer_watches_unmapped_sut_event" => run_watch
          }
        after
          stop_scratch(observer, run_id)
        end
      end)

    forbidden =
      view["unmapped_events"] != 1 or view["unknown_string_type"] != @unknown_type or
        view["unknown_atom_type"] != "nebula_widget" or not view["types_declared"] or
        view["run_observer_watches_unmapped_sut_event"] == false

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "observer.flushed"),
      forbidden_outcome_observed?: forbidden,
      evidence: view
    )
  end

  # --- 008 fresh-process read ----------------------------------------------------

  defp fresh_process_read(ctx, f) do
    run_id = scratch_run_id("008")
    dir = scratch_dir(ctx, "008")

    {both_dead, outcome, report} =
      Context.stimulus(ctx, f, fn ->
        {:ok, observer} = start_scratch(run_id: run_id, mappings: [Fx.probe_mapping()])

        {producer, producer_ref} =
          spawn_monitor(fn ->
            for i <- 1..10, do: Fx.probe(%{probe_id: "fresh-#{i}", i: i, label: "fresh"})
          end)

        receive do
          {:DOWN, ^producer_ref, :process, _, _} -> :ok
        after
          10_000 -> :ok
        end

        {:ok, flush} = Observer.flush(observer, dir)
        observer_ref = Process.monitor(observer)
        stop_scratch(observer, run_id)

        receive do
          {:DOWN, ^observer_ref, :process, _, _} -> :ok
        after
          10_000 -> :ok
        end

        both_dead = not Process.alive?(producer) and not Process.alive?(observer)

        if both_dead do
          {outcome, report} = FreshReader.verify(flush.path, flush)
          {true, outcome, report}
        else
          {false, :not_attempted, %{}}
        end
      end)

    forbidden =
      case outcome do
        :reproduced -> not (is_map(report) and "fixture.probe" in report["event_types"])
        :not_attempted -> :unknown
        _ -> true
      end

    Result.negative(f,
      attempt_observed?: both_dead and Context.observed?(ctx, f, "ocel.fresh_read"),
      forbidden_outcome_observed?: forbidden,
      evidence: %{
        "producer_and_observer_dead" => both_dead,
        "outcome" => outcome,
        "report" => json_safe(report)
      }
    )
  end

  # --- 009 non-authority ------------------------------------------------------------

  defp non_authority(ctx, f) do
    run_id = scratch_run_id("009")
    scope = NonAuthority.default_scope(SutMappings.mappings() ++ ocel_mappings())

    view =
      Context.stimulus(ctx, f, fn ->
        proof = NonAuthority.prove(scope)

        {:ok, observer} =
          start_scratch(
            run_id: run_id,
            mappings: SutMappings.mappings(),
            delivery_timeout_ms: 200
          )

        try do
          kill!(observer)
          {:ok, store} = AshA2A.ReceiptStore.Memory.start_link(name: nil)
          Process.unlink(store)
          store_opts = [name: store]

          suffix = Integer.to_string(System.unique_integer([:positive]))
          denied = "observer-outage-denied-" <> suffix
          allowed = "observer-outage-allowed-" <> suffix

          try do
            denied_reply =
              CommandBus.run(command(denied, false), message(denied), Fx.Ledger,
                store_opts: store_opts
              )

            allowed_reply =
              CommandBus.run(command(allowed, true), message(allowed), Fx.Ledger,
                store_opts: store_opts
              )

            labels = Fx.Ledger |> Ash.read!() |> Enum.map(& &1.label)

            %{
              "proof" =>
                json_safe(
                  Map.take(proof, [
                    :outcome,
                    :modules,
                    :modules_scanned,
                    :functions_scanned,
                    :remote_calls,
                    :closure_applications,
                    :violations,
                    :unprovable
                  ])
                ),
              "proof_outcome" => proof.outcome,
              "denied_reply" => reply_code(denied_reply),
              "allowed_reply" => reply_code(allowed_reply),
              "denied_rows" => Enum.count(labels, &(&1 == denied)),
              "allowed_rows" => Enum.count(labels, &(&1 == allowed))
            }
          after
            if Process.alive?(store), do: GenServer.stop(store)
          end
        after
          stop_scratch(observer, run_id)
        end
      end)

    forbidden =
      view["proof_outcome"] != :proved or view["denied_rows"] != 0 or view["allowed_rows"] != 1

    Result.negative(f,
      attempt_observed?:
        Context.observed?(ctx, f, "observer.non_authority") and
          Context.observed?(ctx, f, "brce.admission") and
          Context.observed?(ctx, f, "observer.dropped"),
      forbidden_outcome_observed?: forbidden,
      evidence: view
    )
  end

  defp command(label, authorized?) do
    principal = Identity.principal("observer-qualification-subject")
    capability = "#{inspect(Fx.Ledger)}.create"

    Command.new(capability,
      command_id: "observer-qualification-" <> label,
      agent_id: "observer-qualification-agent",
      principal_id: principal,
      authority: authorized? && Authority.new(principal, capability, token_id: "tok-" <> label),
      input: %{label: label}
    )
  end

  defp message(label), do: A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])

  defp reply_code({:ok, _receipt}), do: "ok"
  defp reply_code({:error, %{code: code}}), do: inspect(code)
  defp reply_code(other), do: inspect(other, limit: 5)

  # --- 010 positive: steady inner run ------------------------------------------------

  defp steady_control(ctx, f) do
    nested =
      Context.stimulus(ctx, f, fn ->
        isolated(fn ->
          Runner.run(
            profile: :core,
            courts: [Fx.SteadyCourt],
            evidence_dir: scratch_dir(ctx, "010"),
            run_id: scratch_run_id("010")
          )
        end)
      end)

    view = inner_receipt_view(nested)

    corroborated =
      case nested do
        {:ok, {:ok, run}} -> Enum.count(run.results, &(&1.ocel_corroborated? == true))
        _ -> 0
      end

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.run.stop"),
      expected_outcome_observed?:
        view.receipt? == true and view.dropped == 0 and view.gaps == 0 and corroborated > 0,
      evidence: %{"inner" => view, "corroborated" => corroborated}
    )
  end

  # --- 011 positive: well-formed references --------------------------------------------

  defp well_formed_refs_control(ctx, f) do
    run_id = scratch_run_id("011")
    dir = scratch_dir(ctx, "011")

    refs = [
      {"widget", "w-✓-unicode", "subject"},
      {"widget", 42, "subject"},
      {:ledger_entry, :atom_id, "subject"},
      {"principal", Identity.principal("observer-qualification-011"), "actor"},
      {"command", "a:b:c", "subject"},
      {"widget", nil, "subject"}
    ]

    expected = %{
      "widget:w-✓-unicode" => "widget",
      "widget:42" => "widget",
      "ledger_entry:atom_id" => "ledger_entry",
      "principal:observer-qualification-011" => "principal",
      "command:a:b:c" => "command"
    }

    view =
      Context.stimulus(ctx, f, fn ->
        {:ok, observer} =
          start_scratch(run_id: run_id, mappings: [Fx.refs_mapping(:refs), Fx.probe_mapping()])

        try do
          Fx.emit(:refs, %{}, %{refs: refs, label: "well-formed"})
          Fx.probe(%{probe_id: "mapped-1", i: 1, label: "mapped"})
          {:ok, flush} = Observer.flush(observer, dir)
          doc = decode_file!(flush.path)
          objects = Map.new(doc["objects"], &{&1["id"], &1["type"]})
          [event] = events_of(doc, "fixture.refs")

          %{
            "preserved" => Enum.all?(expected, fn {id, type} -> objects[id] == type end),
            "relationships" => length(event["relationships"]),
            "rejected_attribute" => attributes(event)["chicago_rejected_refs"],
            "flush_rejected_refs" => Map.get(flush, :rejected_refs, 0),
            "mapped_probe_events" => length(events_of(doc, "fixture.probe")),
            "unmapped_events" => length(events_of(doc, "chicago.unmapped")),
            "dropped" => flush.dropped
          }
        after
          stop_scratch(observer, run_id)
        end
      end)

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "observer.flushed"),
      expected_outcome_observed?:
        view["preserved"] and view["rejected_attribute"] == nil and
          view["flush_rejected_refs"] == 0 and
          view["mapped_probe_events"] == 1 and view["unmapped_events"] == 0 and
          view["dropped"] == 0,
      evidence: view
    )
  end

  # --- 012 positive: intact artifact + clean journal ------------------------------------

  defp intact_artifact_control(ctx, f) do
    run_id = scratch_run_id("012")
    dir = scratch_dir(ctx, "012")
    journal = journal_path(dir, run_id)
    opts = [run_id: run_id, mappings: [Fx.probe_mapping()], journal: journal]

    view =
      Context.stimulus(ctx, f, fn ->
        {:ok, observer} = start_scratch(opts)

        flush =
          try do
            for i <- 1..6, do: Fx.probe(%{probe_id: "intact-#{i}", i: i, label: "intact"})
            {:ok, flush} = Observer.flush(observer, dir)
            flush
          after
            stop_scratch(observer, run_id)
          end

        loaded = Query.load(flush.path, flush.sha256)
        {:ok, recovered} = start_scratch(opts)

        try do
          stats = Observer.stats(recovered)

          restored =
            recovered |> Observer.records() |> Enum.count(&(&1.activity == "fixture.probe"))

          %{
            "load" => load_outcome(loaded),
            "restored_probes" => restored,
            "corrupt_journal_lines" => stats.corrupt_journal_lines,
            "duplicate_journal_lines" => stats.duplicate_journal_lines
          }
        after
          stop_scratch(recovered, run_id)
        end
      end)

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "ocel.load"),
      expected_outcome_observed?:
        view["load"] == "loaded" and view["restored_probes"] == 6 and
          view["corrupt_journal_lines"] == 0 and view["duplicate_journal_lines"] == 0,
      evidence: view
    )
  end

  # --- 013 positive: prover discrimination ------------------------------------------------

  defp prover_control(ctx, f) do
    proof =
      Context.stimulus(ctx, f, fn ->
        NonAuthority.prove([{Fx.LeakingMapping, [ocel_mappings: 0]}])
      end)

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "observer.non_authority"),
      expected_outcome_observed?:
        proof.outcome == :violated and Enum.any?(proof.violations, &(&1 =~ "AshA2A.CommandBus")),
      evidence: json_safe(Map.take(proof, [:outcome, :violations, :functions_scanned]))
    )
  end

  # --- 014 positive: fresh-reader discrimination ------------------------------------------

  defp fresh_reader_control(ctx, f) do
    run_id = scratch_run_id("014")
    dir = scratch_dir(ctx, "014")

    {outcome, report} =
      Context.stimulus(ctx, f, fn ->
        {:ok, observer} = start_scratch(run_id: run_id, mappings: [Fx.probe_mapping()])

        flush =
          try do
            for i <- 1..4, do: Fx.probe(%{probe_id: "div-#{i}", i: i, label: "diverge"})
            {:ok, flush} = Observer.flush(observer, dir)
            flush
          after
            stop_scratch(observer, run_id)
          end

        copy = Path.join(dir, "diverged-ocel.json")
        File.cp!(flush.path, copy)
        flip_middle_byte!(copy)
        FreshReader.verify(copy, flush)
      end)

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "ocel.fresh_read"),
      expected_outcome_observed?: outcome == :diverged,
      evidence: %{"outcome" => outcome, "report" => json_safe(report)}
    )
  end

  # --- helpers ----------------------------------------------------------------------------

  defp start_scratch(opts), do: GenServer.start(Observer, opts)

  defp stop_scratch(observer, run_id) do
    if is_pid(observer) and Process.alive?(observer) do
      try do
        GenServer.stop(observer, :normal, 10_000)
      catch
        :exit, _ -> :ok
      end
    end

    detach_run(run_id)
  end

  # Detaches every telemetry handler an observer incarnation of `run_id` left
  # attached (a killed observer never runs terminate/2).
  defp detach_run(run_id) do
    []
    |> :telemetry.list_handlers()
    |> Enum.uniq_by(& &1.id)
    |> Enum.each(fn
      %{id: id} when is_tuple(id) and tuple_size(id) >= 3 ->
        if elem(id, 0) == Observer and elem(id, 1) == run_id, do: :telemetry.detach(id)

      _ ->
        :ok
    end)
  end

  defp kill!(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      5_000 -> raise "observer did not die"
    end
  end

  # Runs `fun` in an unlinked, monitored process so a crash (e.g. a runner
  # taken down by its own observer's death) is recorded, not propagated.
  defp isolated(fun, timeout \\ 120_000) do
    parent = self()
    tag = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {tag, fun.()})
      end)

    receive do
      {^tag, value} ->
        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          5_000 -> :ok
        end

        {:ok, value}

      {:DOWN, ^ref, :process, _, reason} ->
        {:crashed, reason}
    after
      timeout ->
        Process.exit(pid, :kill)
        {:crashed, :timeout}
    end
  end

  defp inner_receipt_view({:ok, {:ok, run}}) do
    path = Path.join(run.evidence_dir, "standing_receipt.json")

    case File.read(path) do
      {:ok, bytes} ->
        receipt = JSON.decode!(bytes)
        evidence = receipt["evidence"]

        %{
          receipt?: true,
          standing: receipt["standing"],
          dropped: evidence["ocel_dropped_records"],
          gaps: Map.get(evidence, "ocel_gaps", 0),
          late: Map.get(evidence, "ocel_late_records", 0),
          crashed: nil
        }

      {:error, reason} ->
        %{
          receipt?: false,
          standing: nil,
          dropped: nil,
          gaps: nil,
          late: nil,
          crashed: inspect(reason)
        }
    end
  end

  defp inner_receipt_view(other),
    do: %{
      receipt?: false,
      standing: nil,
      dropped: nil,
      gaps: nil,
      late: nil,
      crashed: inspect(other, limit: 10, printable_limit: 500)
    }

  defp scratch_dir(ctx, name) do
    Path.join([ctx.evidence_dir, "observer_qualification", name])
  end

  defp scratch_run_id(name),
    do: "oq-#{name}-#{System.unique_integer([:positive])}"

  defp journal_path(dir, run_id) do
    if function_exported?(Observer, :journal_path, 2),
      do: Observer.journal_path(dir, run_id),
      else: Path.join(dir, "ocel-journal.jsonl")
  end

  defp decode_file!(path), do: path |> File.read!() |> JSON.decode!()

  defp events_of(doc, type), do: Enum.filter(doc["events"], &(&1["type"] == type))

  defp attributes(event), do: Map.new(event["attributes"], &{&1["name"], &1["value"]})

  defp seq_of(event), do: attributes(event)["chicago_seq"]

  defp distinct?(list), do: length(Enum.uniq(list)) == length(list)

  defp strictly_increasing?(list) do
    list
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> is_integer(a) and is_integer(b) and a < b end)
  end

  defp duplicate_first_event(%{"events" => [first | _] = events} = doc),
    do: JSON.encode!(%{doc | "events" => events ++ [first]})

  defp flip_middle_byte!(path) do
    bytes = File.read!(path)
    offset = div(byte_size(bytes), 2)
    <<pre::binary-size(offset), byte, post::binary>> = bytes
    File.write!(path, <<pre::binary, Bitwise.bxor(byte, 0x01), post::binary>>)
  end

  defp load_outcome({:ok, _}), do: "loaded"
  defp load_outcome({:error, reason}), do: "refused: " <> inspect(reason, limit: 5)

  defp json_safe(term), do: AshA2A.Chicago.Json.safe(term)
end
