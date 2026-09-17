defmodule AshA2A.Chicago.Runner do
  @moduledoc """
  Executes a Chicago qualification run (RFC-SA2A-002 §103-§104).

  Order, per §104:

    1. capture the exact subject (`AshA2A.Chicago.Subject`)
    2. start the independent observer with the admitted, digested OCEL mappings
       and a durable journal; a dead observer is replaced by a recovery
       incarnation that records the gap
    3. run every selected court, one at a time, capturing crashes/timeouts as
       `:unknown` and filling in any declared falsifier a court failed to
       report (§129-§130)
    4. flush the OCEL artifact durably and content-address it
    5. validate the OCEL serialization with an independent validator
    6. load the artifact from disk in the independent consumer
       (`AshA2A.Chicago.Query`) and corroborate or refute every result against
       its falsifier's predicates
    7. issue the standing receipt (`AshA2A.Chicago.StandingReceipt`) and write
       the conformance package to `evidence_dir`

  No standing verdict is issued before the evidence artifact is durably
  available to the verifier.
  """

  alias AshA2A.Chicago

  alias AshA2A.Chicago.{
    Context,
    Court,
    CourtManifest,
    Falsifier,
    Observer,
    Profile,
    Query,
    Result,
    StandingReceipt,
    Subject
  }

  alias AshA2A.Chicago.Ocel.{Mapping, SutEvents, SutMappings}

  defmodule Run do
    @moduledoc "A completed Chicago run: results, evidence and standing receipt."
    defstruct [
      :run_id,
      :profile,
      :subject,
      :courts,
      :results,
      :ocel,
      :ocel_validation,
      :receipt,
      :evidence_dir
    ]

    @type t :: %__MODULE__{}
  end

  @default_validator AshA2A.Chicago.Ocel.Validator

  @stop_event [:ash_a2a, :chicago, :run, :stop]

  @doc """
  The one boundary event a run emits after its standing receipt and package
  are written: `[:ash_a2a, :chicago, :run, :stop]`, measurement `system_time`,
  metadata `run_id`, `standing`, `ocel_sha256`, `ocel_dropped`, `ocel_gaps`,
  `ocel_corroborated`, `results`, `claimed_profile`, `subject_identity`,
  `subject_verification`, `court_admission` and `receipt_digest`.
  """
  @spec stop_event() :: [atom()]
  def stop_event, do: @stop_event

  @doc """
  The single admitted OCEL mapping of `stop_event/0` (activity
  `chicago.run.stop`). Every court whose falsifiers read the event declares
  this mapping in its `ocel_mappings/0`; the runner admits it once, so one
  emission is one OCEL event however many selected courts declare it.
  """
  @spec stop_mapping() :: Mapping.t()
  def stop_mapping do
    Mapping.new!(
      event: @stop_event,
      activity: "chicago.run.stop",
      source: __MODULE__,
      objects: fn _m, meta ->
        [
          {"qualification_run", meta[:run_id], "run"},
          {"subject", meta[:subject_identity], "subject"},
          {"standing_receipt", meta[:receipt_digest], "receipt"}
        ]
      end,
      attributes: fn _m, meta ->
        Map.take(meta, [
          :run_id,
          :standing,
          :ocel_dropped,
          :ocel_gaps,
          :ocel_corroborated,
          :results,
          :claimed_profile,
          :subject_verification,
          :court_admission
        ])
      end
    )
  end

  @doc """
  Runs the court.

  Options:

    * `:profile` -- claimed profile (default `:core`)
    * `:courts` -- explicit court modules (default: every discoverable court
      applicable to the profile)
    * `:court_ids` -- restrict to these court ids
    * `:evidence_dir` -- output directory (default a fresh tmp dir)
    * `:subject_opts` -- passed to `Subject.capture/1`
    * `:claimed_subject` -- the `AshA2A.Chicago.Subject` (or its JSON map)
      the standing is claimed for; verified against the captured subject
      before any court runs, and a mismatch issues `REFUSED` standing (§32)
    * `:court_manifest` -- the admitted court manifest (§137): a path or a
      decoded document (default `AshA2A.Chicago.CourtManifest.default_path/0`).
      The selected courts and OCEL validator are checked against it before any
      court runs; drift is bound into the receipt and bars `CONFORMANT`
    * `:ocel_validator` -- module exporting `validate_file/1`
      (default `AshA2A.Chicago.Ocel.Validator` when compiled; otherwise
      validation is recorded as not run and standing cannot be CONFORMANT)
    * `:court_timeout_ms` -- per court (default 600_000)
    * `:observer_watch_events` -- events the observer records without a
      mapping (default: discovered SUT events with no admitted mapping,
      `AshA2A.Chicago.Ocel.SutEvents.unmapped/1`)
    * `:observer_delivery_timeout_ms`, `:observer_journal_sync` -- passed to
      the observer (`AshA2A.Chicago.Observer.start/1`); the observer journal
      is written to `evidence_dir`
    * `:run_id`
    * any other option is carried in `Context.opts` for courts
  """
  @spec run(keyword()) :: {:ok, Run.t()} | {:error, term()}
  def run(opts \\ []) do
    profile = Keyword.get(opts, :profile, :core)

    with true <- Profile.profile?(profile) || {:error, {:unknown_profile, profile}},
         {:ok, courts} <- select_courts(profile, opts) do
      do_run(profile, courts, opts)
    end
  end

  defp select_courts(profile, opts) do
    courts = Keyword.get_lazy(opts, :courts, fn -> Chicago.courts_for(profile) end)

    courts =
      case Keyword.get(opts, :court_ids) do
        nil -> courts
        ids -> Enum.filter(courts, &(&1.id() in ids))
      end

    case Enum.reject(courts, &Court.court?/1) do
      [] -> {:ok, Enum.filter(courts, &Profile.applicable?(&1.profile(), profile))}
      bad -> {:error, {:not_a_court, bad}}
    end
  end

  defp do_run(profile, courts, opts) do
    run_id = Keyword.get_lazy(opts, :run_id, &new_run_id/0)

    evidence_dir =
      Keyword.get_lazy(opts, :evidence_dir, fn ->
        Path.join(System.tmp_dir!(), "ash_a2a-chicago-#{run_id}")
      end)

    subject = Subject.capture(Keyword.get(opts, :subject_opts, []))
    # Two courts that rely on the same SUT event each declare its mapping;
    # `ocel_mappings/1` admits a shared mapping once, so the observer records
    # one emission once however many selected courts declare it -- never two
    # records carrying the same sequence id.
    mappings = ocel_mappings(courts)

    observer_opts = observer_opts(run_id, mappings, evidence_dir, opts)

    # Unlinked and owner-monitored: an observer outage must degrade evidence
    # standing, never take the run down with it (§108, §138).
    {:ok, observer} = Observer.start(observer_opts)

    # §32: a claimed subject is verified against the executed one before any
    # court runs; a mismatch is carried to the receipt as REFUSED standing.
    # Always recomputed here -- a caller cannot pass a verification in.
    opts =
      opts
      |> Keyword.put(
        :subject_verification,
        Subject.verify_claim(Keyword.get(opts, :claimed_subject), subject)
      )
      # §137: the machinery about to run is checked against the admitted court
      # manifest before any court runs. Always recomputed here.
      |> Keyword.put(
        :court_admission,
        CourtManifest.admission(
          courts,
          [ocel_validator: Keyword.get(opts, :ocel_validator, @default_validator)],
          Keyword.get(opts, :court_manifest)
        )
      )

    try do
      ctx = %Context{
        run_id: run_id,
        profile: profile,
        subject: subject,
        evidence_dir: evidence_dir,
        observer: observer,
        opts: opts
      }

      # A dead observer is replaced by a recovery incarnation (journal restore
      # + recorded gap) before the next court and before the flush.
      {results, observer} =
        Enum.flat_map_reduce(courts, observer, fn court, observer ->
          observer = Observer.ensure_running(observer, observer_opts)
          {run_court(court, %{ctx | court: court, observer: observer}, opts), observer}
        end)

      observer = Observer.ensure_running(observer, observer_opts)

      with {:ok, ocel} <- Observer.flush(observer, evidence_dir) do
        finish(profile, courts, subject, results, ocel, evidence_dir, run_id, opts)
      end
    after
      Observer.stop_run(run_id)
    end
  end

  @doc """
  The admitted OCEL mapping set a run over `courts` observes with (§17): the
  SUT mappings plus every court's `ocel_mappings/0`. A mapping several courts
  share (same event, activity and source, e.g. `stop_mapping/0`, or a shared
  fixture's `mappings/0` such as `AshA2A.Chicago.Fixtures.HooksCascade`) is
  admitted once: one emission, one OCEL event. Mappings that differ in
  activity or source stay distinct and each yields its own record. Fresh consumers recompute the receipt's
  `ocel_mapping_digest` from this, so the dedup must live here.
  """
  @spec ocel_mappings([module()]) :: [AshA2A.Chicago.Ocel.Mapping.t()]
  def ocel_mappings(courts) do
    (SutMappings.mappings() ++ Enum.flat_map(courts, & &1.ocel_mappings()))
    |> Enum.uniq_by(&{&1.event, &1.activity, &1.source})
  end

  defp observer_opts(run_id, mappings, evidence_dir, opts) do
    [
      run_id: run_id,
      mappings: mappings,
      watch_events:
        Keyword.get_lazy(opts, :observer_watch_events, fn -> SutEvents.unmapped(mappings) end),
      journal: Observer.journal_path(evidence_dir, run_id),
      owner: self()
    ] ++
      Enum.flat_map(
        [
          observer_delivery_timeout_ms: :delivery_timeout_ms,
          observer_journal_sync: :journal_sync
        ],
        fn {from, to} ->
          case Keyword.fetch(opts, from) do
            {:ok, value} -> [{to, value}]
            :error -> []
          end
        end
      )
  end

  defp finish(profile, courts, subject, results, ocel, evidence_dir, run_id, opts) do
    validation = validate_ocel(ocel.path, Keyword.get(opts, :ocel_validator, @default_validator))
    falsifiers = courts |> Enum.flat_map(& &1.falsifiers()) |> Map.new(&{&1.id, &1})

    results = corroborate_all(results, falsifiers, ocel)

    receipt =
      StandingReceipt.build(%{
        profile: profile,
        subject: subject,
        courts: courts,
        falsifiers: Map.values(falsifiers),
        results: results,
        ocel: ocel,
        ocel_validation: validation,
        run_id: run_id,
        subject_verification: Keyword.fetch!(opts, :subject_verification),
        court_admission: Keyword.fetch!(opts, :court_admission)
      })

    run = %Run{
      run_id: run_id,
      profile: profile,
      subject: subject,
      courts: courts,
      results: results,
      ocel: ocel,
      ocel_validation: validation,
      receipt: receipt,
      evidence_dir: evidence_dir
    }

    write_package!(run)

    # One boundary event for the one decision -- the standing this run issued
    # -- carrying both the evidence accounting the observer court corroborates
    # and the subject verification the identity court corroborates.
    :telemetry.execute(@stop_event, %{system_time: System.system_time()}, %{
      run_id: run_id,
      standing: receipt["standing"],
      ocel_sha256: ocel.sha256,
      ocel_dropped: ocel.dropped,
      ocel_gaps: Map.get(ocel, :gaps, 0),
      ocel_corroborated: Enum.count(results, &(&1.ocel_corroborated? == true)),
      results: length(results),
      claimed_profile: receipt["subject"]["claimed_profile"],
      subject_identity: receipt["subject"]["identity"],
      subject_verification: receipt["subject"]["verification"]["outcome"],
      court_admission: receipt["court"]["manifest"]["verification"],
      receipt_digest: receipt["receipt_digest"]
    })

    {:ok, run}
  end

  @doc """
  Loads the durable OCEL artifact by its digest in the independent consumer
  and corroborates every result against its falsifier (§104). When the bytes
  cannot be loaded -- missing, corrupted, digest mismatch -- no result is
  corroborated.
  """
  @spec corroborate_all([Result.t()], %{String.t() => Falsifier.t()}, map()) :: [Result.t()]
  def corroborate_all(results, falsifiers, %{path: path, sha256: sha256}) do
    case Query.load(path, sha256) do
      {:ok, index} ->
        Enum.map(results, &corroborate(&1, Map.get(falsifiers, &1.falsifier_id), index))

      {:error, reason} ->
        Enum.map(results, fn r ->
          %{
            r
            | ocel_corroborated?: false,
              ocel_detail: "independent consumer could not load OCEL: #{inspect(reason)}"
          }
        end)
    end
  end

  # --- court execution ------------------------------------------------------

  @doc false
  @spec run_court(module(), Context.t(), keyword()) :: [Result.t()]
  def run_court(court, %Context{} = ctx, opts) do
    declared = court.falsifiers()
    timeout = Keyword.get(opts, :court_timeout_ms, 600_000)
    started = System.monotonic_time(:microsecond)

    outcome =
      try do
        task = Task.async(fn -> safe_run(court, ctx) end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, value} -> value
          nil -> {:crashed, "court #{court.id()} exceeded #{timeout}ms", :resource_blocked}
          {:exit, reason} -> {:crashed, "court #{court.id()} exited: #{inspect(reason)}", nil}
        end
      catch
        kind, reason -> {:crashed, "court #{court.id()} #{kind}: #{inspect(reason)}", nil}
      end

    elapsed = System.monotonic_time(:microsecond) - started
    reconcile_declared(court, declared, outcome, elapsed)
  end

  defp safe_run(court, ctx) do
    case court.run(ctx) do
      results when is_list(results) ->
        {:ok, results}

      other ->
        {:crashed,
         "court #{court.id()} run/1 returned #{inspect(other, limit: 5)}, not a result list", nil}
    end
  rescue
    exception ->
      {:crashed,
       "court #{court.id()} raised: " <> Exception.format(:error, exception, __STACKTRACE__), nil}
  catch
    kind, reason -> {:crashed, "court #{court.id()} #{kind}: #{inspect(reason)}", nil}
  end

  defp reconcile_declared(court, declared, {:crashed, detail, class}, _elapsed) do
    Enum.map(declared, &with_gate(Result.unknown(&1, detail, class), court))
  end

  defp reconcile_declared(court, declared, {:ok, results}, elapsed) do
    by_id = Enum.group_by(Enum.filter(results, &match?(%Result{}, &1)), & &1.falsifier_id)
    declared_ids = MapSet.new(declared, & &1.id)

    declared_results =
      Enum.map(declared, fn f ->
        case Map.get(by_id, f.id) do
          [%Result{kind: kind} = r] when kind == f.kind ->
            r

          [%Result{}] ->
            Result.unknown(f, "result kind does not match the declared falsifier kind")

          [_ | _] ->
            Result.unknown(
              f,
              "court #{court.id()} reported #{length(by_id[f.id])} results for one falsifier"
            )

          nil ->
            Result.unknown(
              f,
              "court #{court.id()} declared #{f.id} but produced no result (vacuity guard, §129)"
            )
        end
      end)

    stray =
      results
      |> Enum.reject(&(match?(%Result{}, &1) and MapSet.member?(declared_ids, &1.falsifier_id)))
      |> Enum.map(fn stray ->
        id = if match?(%Result{}, stray), do: stray.falsifier_id, else: "CHI-UNDECLARED-000"

        Result.unknown(
          %Falsifier{
            id: id,
            court_id: court.id(),
            kind: :negative,
            invariant: "-",
            stimulus: "-",
            boundary: "-"
          },
          "court #{court.id()} reported an undeclared result: #{inspect(stray, limit: 5)}"
        )
      end)

    per = if declared == [], do: 0, else: div(elapsed, length(declared))

    Enum.map(declared_results ++ stray, fn r ->
      with_gate(%{r | duration_us: r.duration_us || per}, court)
    end)
  end

  defp with_gate(%Result{} = r, court), do: %{r | gate: court.gate(), court_id: court.id()}

  # --- independent corroboration -------------------------------------------

  @doc false
  @spec corroborate(Result.t(), Falsifier.t() | nil, Query.index()) :: Result.t()
  def corroborate(%Result{} = r, nil, _index),
    do: %{r | ocel_corroborated?: false, ocel_detail: "no declared falsifier"}

  def corroborate(%Result{} = r, %Falsifier{} = f, index) do
    cond do
      not Result.passing_verdict?(r) and not Result.failed?(r) ->
        r

      f.attempt_predicate == nil ->
        %{
          r
          | ocel_corroborated?: false,
            ocel_detail:
              "falsifier declares no attempt predicate; attempt not independently corroborated"
        }

      true ->
        {attempted, attempt_detail} = Query.eval(index, f.id, f.attempt_predicate)
        corroborate_outcome(r, f, index, attempted, attempt_detail)
    end
  end

  defp corroborate_outcome(r, _f, _index, false, attempt_detail) do
    if Result.passing_verdict?(r) do
      %{
        r
        | verdict: :unknown,
          failure_class: :ocel_evidence_incomplete,
          ocel_corroborated?: false,
          ocel_detail:
            "court reported #{r.verdict} but the independent OCEL consumer did not observe the attempt: #{attempt_detail}"
      }
    else
      %{
        r
        | ocel_corroborated?: false,
          ocel_detail: "attempt not observed in OCEL: #{attempt_detail}"
      }
    end
  end

  defp corroborate_outcome(r, %Falsifier{kind: :measurement}, _index, true, attempt_detail),
    do: %{r | ocel_corroborated?: true, ocel_detail: attempt_detail}

  defp corroborate_outcome(r, %Falsifier{outcome_predicate: nil}, _index, true, attempt_detail),
    do: %{
      r
      | ocel_corroborated?: false,
        ocel_detail:
          "attempt observed (#{attempt_detail}) but falsifier declares no outcome predicate"
    }

  defp corroborate_outcome(r, %Falsifier{kind: :negative} = f, index, true, attempt_detail) do
    {forbidden, detail} = Query.eval(index, f.id, f.outcome_predicate)
    detail = "attempt: #{attempt_detail}; forbidden: #{detail}"

    if forbidden do
      %{
        r
        | verdict: :falsifier_survived,
          failure_class: r.failure_class || f.failure_class,
          ocel_corroborated?: true,
          ocel_detail: "independent OCEL consumer observed the forbidden outcome. " <> detail
      }
    else
      %{r | ocel_corroborated?: true, ocel_detail: detail}
    end
  end

  defp corroborate_outcome(r, %Falsifier{} = f, index, true, attempt_detail) do
    {expected, detail} = Query.eval(index, f.id, f.outcome_predicate)
    detail = "attempt: #{attempt_detail}; expected: #{detail}"

    cond do
      expected ->
        %{r | ocel_corroborated?: true, ocel_detail: detail}

      Result.passing_verdict?(r) ->
        %{
          r
          | verdict: :unknown,
            failure_class: :ocel_evidence_incomplete,
            ocel_corroborated?: false,
            ocel_detail: "court reported pass but OCEL lacks the expected outcome. " <> detail
        }

      true ->
        %{r | ocel_corroborated?: true, ocel_detail: detail}
    end
  end

  # --- OCEL validation ------------------------------------------------------

  defp validate_ocel(path, validator) do
    if Code.ensure_loaded?(validator) and function_exported?(validator, :validate_file, 1) do
      identity = validator_identity(validator)

      case validator.validate_file(path) do
        {:ok, report} ->
          %{status: :valid, validator: inspect(validator), report: report, identity: identity}

        {:error, report} ->
          %{status: :invalid, validator: inspect(validator), report: report, identity: identity}
      end
    else
      %{
        status: :not_run,
        validator: inspect(validator),
        report: "no independent OCEL 2.0 validator compiled"
      }
    end
  rescue
    exception ->
      %{
        status: :invalid,
        validator: inspect(validator),
        report: "validator raised: " <> Exception.message(exception)
      }
  end

  # §137: the validator identity bound into the receipt -- its declared
  # identity plus the BEAM md5 of the module that really ran.
  defp validator_identity(validator) do
    validator
    |> CourtManifest.validator_identity()
    |> Map.put("beam_md5", Base.encode16(validator.module_info(:md5), case: :lower))
  end

  # --- package ---------------------------------------------------------------

  defp write_package!(%Run{} = run) do
    File.mkdir_p!(run.evidence_dir)

    write_json!(
      Path.join(run.evidence_dir, "results.json"),
      Enum.map(run.results, &Result.to_map/1)
    )

    write_json!(Path.join(run.evidence_dir, "subject.json"), Subject.to_map(run.subject))

    write_json!(Path.join(run.evidence_dir, "ocel_validation.json"), %{
      "status" => Atom.to_string(run.ocel_validation.status),
      "validator" => run.ocel_validation.validator,
      "report" => AshA2A.Chicago.Json.safe(run.ocel_validation.report),
      "ocel_sha256" => run.ocel.sha256
    })

    write_json!(Path.join(run.evidence_dir, "standing_receipt.json"), run.receipt)
  end

  defp write_json!(path, term), do: File.write!(path, AshA2A.Chicago.Json.canonical(term))

  defp new_run_id do
    "run-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
