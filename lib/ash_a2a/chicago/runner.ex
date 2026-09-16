defmodule AshA2A.Chicago.Runner do
  @moduledoc """
  Executes a Chicago qualification run (RFC-SA2A-002 §103-§104).

  Order, per §104:

    1. capture the exact subject (`AshA2A.Chicago.Subject`)
    2. start the independent observer with the admitted, digested OCEL mappings
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
    Falsifier,
    Observer,
    Profile,
    Query,
    Result,
    StandingReceipt,
    Subject
  }

  alias AshA2A.Chicago.Ocel.SutMappings

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
    * `:ocel_validator` -- module exporting `validate_file/1`
      (default `AshA2A.Chicago.Ocel.Validator` when compiled; otherwise
      validation is recorded as not run and standing cannot be CONFORMANT)
    * `:court_timeout_ms` -- per court (default 600_000)
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
    mappings = SutMappings.mappings() ++ Enum.flat_map(courts, & &1.ocel_mappings())

    {:ok, observer} = Observer.start_link(run_id: run_id, mappings: mappings)

    # §32: a claimed subject is verified against the executed one before any
    # court runs; a mismatch is carried to the receipt as REFUSED standing.
    # Always recomputed here -- a caller cannot pass a verification in.
    opts =
      Keyword.put(
        opts,
        :subject_verification,
        Subject.verify_claim(Keyword.get(opts, :claimed_subject), subject)
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

      results = Enum.flat_map(courts, &run_court(&1, %{ctx | court: &1}, opts))

      with {:ok, ocel} <- Observer.flush(observer, evidence_dir) do
        finish(profile, courts, subject, results, ocel, evidence_dir, run_id, opts)
      end
    after
      if Process.alive?(observer), do: Observer.stop(observer)
    end
  end

  defp finish(profile, courts, subject, results, ocel, evidence_dir, run_id, opts) do
    validation = validate_ocel(ocel.path, Keyword.get(opts, :ocel_validator, @default_validator))
    falsifiers = courts |> Enum.flat_map(& &1.falsifiers()) |> Map.new(&{&1.id, &1})

    results =
      case Query.load(ocel.path, ocel.sha256) do
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
        subject_verification: Keyword.fetch!(opts, :subject_verification)
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

    :telemetry.execute([:ash_a2a, :chicago, :standing, :issued], %{}, %{
      run_id: run_id,
      standing: receipt["standing"],
      claimed_profile: receipt["subject"]["claimed_profile"],
      subject_identity: receipt["subject"]["identity"],
      subject_verification: receipt["subject"]["verification"]["outcome"],
      receipt_digest: receipt["receipt_digest"]
    })

    {:ok, run}
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
      case validator.validate_file(path) do
        {:ok, report} -> %{status: :valid, validator: inspect(validator), report: report}
        {:error, report} -> %{status: :invalid, validator: inspect(validator), report: report}
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
