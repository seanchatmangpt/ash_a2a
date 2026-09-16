defmodule AshA2A.Chicago.FreshConsumer do
  @moduledoc """
  RFC-SA2A-002 Gate 11 fresh consumer (§42, §74; evidence durability §19,
  observer freshness §139).

  A fresh consumer reconstructs a Chicago standing claim from the durable
  conformance package only -- the five files `AshA2A.Chicago.Runner` writes:

      standing_receipt.json  results.json  ocel.json  ocel_validation.json  subject.json

  It never reuses producer process memory, in-process caches, open object
  references, mutable singleton state, undocumented temporary files, or prior
  fixture state (§42). Its only other input is the exact subject's compiled
  code on the code path, whose identity the receipt itself binds
  (`court.revision`, §137) -- so a court whose declarations depend on hidden
  producer state fails to reproduce here instead of being trusted.

  ## Two halves

    * `verify_package/1` -- pure verification, no telemetry, no DO.
      1. *Admission* (`integrity` checks): every package file present and
         decodable; `receipt_digest`; `sha256(ocel.json)` equals the receipt's
         `ocel_digest` and `ocel_validation.json`'s `ocel_sha256`; the OCEL
         `chicago_run` object binds the receipt's `run_id` and OCEL mapping
         digest; `subject.json` hashes to the receipt's subject identity;
         every result decodes.
      2. *Reproduction* (`reproduction` checks): the courts named by the
         receipt resolve on the code path with the same ids and gates; court
         revision, falsifier-corpus, query-set and OCEL-mapping digests
         recompute to the receipt's; OCEL size/validation facts match; every
         declared falsifier has a result; every result re-corroborates against
         `ocel.json` via `AshA2A.Chicago.Runner.corroborate/3`; and
         `AshA2A.Chicago.StandingReceipt.recompute/1` reproduces the receipt's
         gates, tallies, standing, gate evidence and claim -- both from the
         results as recorded and from the re-corroborated results.
      3. The §74 evidence questions, answered mechanically from `ocel.json`
         and the reconstruction; `UNKNOWN` wherever the package cannot answer.

    * `verify/2` -- the local acceptance boundary. Runs `main/1` in a
      genuinely fresh OS process (`elixir -pa <_build/<env>/lib/*/ebin> -e
      ...`, no application started, code-path environment scrubbed), parses
      its verdict from stdout, refuses any verdict not provably produced by
      that exact OS process with `:ash_a2a` unstarted, and emits
      `[:ash_a2a, :chicago, :fresh_consumer, :verified]` with `:outcome`
      `:reproduced | :diverged | :refused`.

  ## Outcomes

    * `reproduced` -- admitted, and every reproduction check matched
    * `diverged` -- admitted, but standing (or an identity it depends on)
      could not be reproduced from the package
    * `refused` -- the package cannot be admitted, or the fresh process
      produced no acceptable verdict; no standing is inferred (§74)
  """

  alias AshA2A.Chicago.{
    Court,
    FailureClass,
    Falsifier,
    Json,
    Profile,
    Query,
    Result,
    Runner,
    StandingReceipt
  }

  alias AshA2A.Chicago.Ocel.Mapping

  @schema "ash_a2a.chicago.fresh_consumer/1"
  @marker "SA2A-FRESH-CONSUMER-VERDICT "
  @event [:ash_a2a, :chicago, :fresh_consumer, :verified]
  @files [
    "standing_receipt.json",
    "results.json",
    "ocel.json",
    "ocel_validation.json",
    "subject.json"
  ]
  @questions [
    "semantic_object",
    "standing_basis",
    "plan",
    "authority_grant",
    "prepared_before_actuation",
    "independent_consequence",
    "replayable_without_do"
  ]
  @gate_evidence_keys ["independent_postcondition", "receipt_binding", "replay", "fresh_consumer"]
  @do_boundary [AshA2A.CommandBus, AshA2A.Dispatcher]
  @scrubbed_env ~w(ERL_LIBS ERL_AFLAGS ERL_ZFLAGS ELIXIR_ERL_OPTIONS MIX_ENV MIX_BUILD_PATH MIX_EXS)
  @max_output 4_000_000

  @verdicts Map.new(Result.verdicts(), &{FailureClass.wire(&1), &1})
  @kinds Map.new(Falsifier.kinds(), &{Atom.to_string(&1), &1})
  @classes Map.new(FailureClass.classes(), &{FailureClass.wire(&1), &1})
  @validation_statuses %{"valid" => :valid, "invalid" => :invalid, "not_run" => :not_run}

  @spec package_files() :: [String.t()]
  def package_files, do: @files

  @spec questions() :: [String.t()]
  def questions, do: @questions

  @spec event() :: [atom()]
  def event, do: @event

  @spec schema() :: String.t()
  def schema, do: @schema

  # --- fresh OS process entry point ---------------------------------------

  @doc """
  Entry point of the fresh OS process: `main([package_dir])` verifies the
  package and prints exactly one marker line carrying the canonical JSON
  verdict. Never raises -- a crash is itself reported as a `refused` verdict.
  """
  @spec main([String.t()]) :: :ok
  def main(argv) do
    verdict =
      try do
        case argv do
          [dir] -> verify_package(dir)
          other -> crash_verdict("usage: main([package_dir]), got #{inspect(other)}")
        end
      rescue
        exception -> crash_verdict(Exception.format(:error, exception, __STACKTRACE__))
      catch
        kind, reason -> crash_verdict("#{kind}: #{inspect(reason)}")
      end

    IO.puts(@marker <> Json.canonical(verdict))
  end

  # --- local acceptance boundary -------------------------------------------

  @doc """
  Verifies `dir` in a genuinely fresh OS process and accepts (or refuses) its
  verdict. Always returns `{:ok, verdict}`; the verdict's `"outcome"` is the
  decision. Emits `[:ash_a2a, :chicago, :fresh_consumer, :verified]`.

  Options:

    * `:producer` -- pid (or pids) of the producer; recorded as
      `"producer_terminated"` when every one is dead at verification time
    * `:timeout_ms` -- fresh process deadline (default 180_000)
    * `:elixir` -- executable (default `System.find_executable("elixir")`)
    * `:code_paths` -- ebin directories (default every `lib/*/ebin` next to
      this module's own compiled ebin)
  """
  @spec verify(Path.t(), keyword()) :: {:ok, map()}
  def verify(dir, opts \\ []) when is_binary(dir) do
    dir = Path.expand(dir)
    started = System.monotonic_time(:microsecond)
    producer_terminated = producer_terminated(Keyword.get(opts, :producer))

    verdict =
      case spawn_fresh(dir, opts) do
        {:ok, child} -> accept(child, dir)
        {:error, reason, output} -> local_refusal(dir, [reason], output, nil)
      end
      |> Map.put("producer_terminated", producer_terminated)

    emit(verdict, dir, started)
    {:ok, verdict}
  end

  defp spawn_fresh(dir, opts) do
    with {:ok, elixir} <- elixir_executable(opts),
         {:ok, paths} <- code_paths(opts) do
      args =
        Enum.flat_map(paths, &["-pa", &1]) ++
          ["-e", "AshA2A.Chicago.FreshConsumer.main(System.argv())", "--", dir]

      port =
        Port.open({:spawn_executable, elixir}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          args: args,
          cd: System.tmp_dir!(),
          env: Enum.map(@scrubbed_env, &{String.to_charlist(&1), false})
        ])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 180_000)
      collect(port, os_pid, [], 0, deadline)
    end
  rescue
    exception -> {:error, "fresh_consumer_spawn_failed", Exception.message(exception)}
  end

  defp collect(port, os_pid, acc, size, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when size + byte_size(data) <= @max_output ->
        collect(port, os_pid, [acc, data], size + byte_size(data), deadline)

      {^port, {:data, _data}} ->
        collect(port, os_pid, acc, size, deadline)

      {^port, {:exit_status, status}} ->
        {:ok, %{output: IO.iodata_to_binary(acc), exit_status: status, os_pid: os_pid}}
    after
      remaining ->
        if os_pid, do: System.cmd("kill", ["-9", Integer.to_string(os_pid)])

        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end

        {:error, "fresh_consumer_timeout", IO.iodata_to_binary(acc)}
    end
  end

  defp elixir_executable(opts) do
    case Keyword.get_lazy(opts, :elixir, fn -> System.find_executable("elixir") end) do
      nil -> {:error, "fresh_process_unavailable:elixir_not_found", ""}
      path -> {:ok, path}
    end
  end

  defp code_paths(opts) do
    case Keyword.fetch(opts, :code_paths) do
      {:ok, paths} ->
        {:ok, paths}

      :error ->
        with path when is_list(path) <- :code.which(__MODULE__),
             lib = path |> List.to_string() |> Path.dirname() |> Path.dirname() |> Path.dirname(),
             [_ | _] = paths <- Path.wildcard(Path.join(lib, "*/ebin")) do
          {:ok, Enum.sort(paths)}
        else
          _ -> {:error, "fresh_process_unavailable:code_path", ""}
        end
    end
  end

  defp accept(%{output: output, exit_status: status, os_pid: os_pid}, dir) do
    with {:ok, json} <- marker_line(output),
         {:ok, %{"schema" => @schema, "outcome" => outcome} = verdict}
         when outcome in ["reproduced", "diverged", "refused"] <- JSON.decode(json) do
      child = %{"os_pid" => os_pid, "exit_status" => status}

      case local_acceptance(verdict, os_pid, status) do
        [] ->
          verdict
          |> Map.put("child", child)
          |> Map.put("fresh_process_accepted", true)

        reasons ->
          verdict
          |> Map.put("outcome", "refused")
          |> Map.put("reasons", reasons ++ List.wrap(verdict["reasons"]))
          |> Map.put("child", child)
          |> Map.put("fresh_process_accepted", false)
      end
    else
      _ ->
        local_refusal(dir, ["fresh_consumer_no_verdict"], output, %{
          "os_pid" => os_pid,
          "exit_status" => status
        })
    end
  end

  defp marker_line(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, @marker))
    |> List.last()
    |> case do
      nil -> :error
      line -> {:ok, String.replace_prefix(line, @marker, "")}
    end
  end

  # The verdict must provably come from the exact OS process spawned for it,
  # and that process must not have started the SUT application.
  defp local_acceptance(verdict, os_pid, status) do
    process = dig(verdict, ["fresh_process"])

    [
      status != 0 && "fresh_consumer_exit_status:#{status}",
      dig(process, ["os_pid"]) == System.pid() && "not_a_fresh_process:producer_os_pid",
      (os_pid == nil or dig(process, ["os_pid"]) != Integer.to_string(os_pid)) &&
        "not_a_fresh_process:os_pid_unbound",
      dig(process, ["ash_a2a_started"]) != false && "not_a_fresh_process:ash_a2a_started"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp local_refusal(dir, reasons, output, child) do
    %{
      "schema" => @schema,
      "outcome" => "refused",
      "reasons" => reasons,
      "checks" => [],
      "package" => %{"dir" => dir},
      "standing" => %{},
      "questions" => all_unknown("fresh consumer produced no acceptable verdict"),
      "child" => child,
      "fresh_process_accepted" => false,
      "output_tail" => output |> to_string() |> String.slice(-2_000, 2_000)
    }
  end

  defp producer_terminated(nil), do: nil
  defp producer_terminated(pid) when is_pid(pid), do: not Process.alive?(pid)

  defp producer_terminated(pids) when is_list(pids),
    do: Enum.all?(pids, &(not Process.alive?(&1)))

  defp emit(verdict, dir, started) do
    reasons = verdict |> Map.get("reasons") |> List.wrap() |> Enum.map(&to_string/1)

    outcome =
      case verdict["outcome"] do
        "reproduced" -> :reproduced
        "diverged" -> :diverged
        _ -> :refused
      end

    questions = if is_map(verdict["questions"]), do: verdict["questions"], else: %{}

    :telemetry.execute(
      @event,
      %{
        system_time: System.system_time(),
        duration_us: System.monotonic_time(:microsecond) - started,
        reason_count: length(reasons)
      },
      %{
        outcome: outcome,
        reasons: Enum.join(reasons, ";"),
        package_ref: package_ref(dir),
        package_run_id: dig(verdict, ["package", "run_id"]),
        receipt_digest: dig(verdict, ["package", "receipt_digest"]),
        claimed_standing: dig(verdict, ["standing", "claimed"]),
        recorded_standing: dig(verdict, ["standing", "recorded"]),
        reconstructed_standing: dig(verdict, ["standing", "reconstructed"]),
        child_os_pid: dig(verdict, ["child", "os_pid"]),
        fresh_process: verdict["fresh_process_accepted"] == true,
        producer_terminated: verdict["producer_terminated"],
        questions_unknown:
          Enum.count(questions, fn {_q, a} -> dig(a, ["status"]) != "ANSWERED" end)
      }
    )
  end

  @doc "Stable, location-derived reference for a package directory."
  @spec package_ref(Path.t()) :: String.t()
  def package_ref(dir),
    do: "pkg-" <> String.slice(sha256(Path.expand(dir)), 0, 16)

  # --- pure package verification --------------------------------------------

  @doc """
  Verifies the durable package in `dir` from its files alone and returns the
  JSON-safe verdict (see the moduledoc). Pure: emits no telemetry and
  performs no consequence.
  """
  @spec verify_package(Path.t()) :: map()
  def verify_package(dir) when is_binary(dir) do
    dir = Path.expand(dir)

    case load_files(dir) do
      {files, []} ->
        admit_and_reproduce(dir, files)

      {files, failures} ->
        checks =
          Enum.map(failures, fn {reason, detail} -> failed(reason, :integrity, reason, detail) end)

        receipt =
          case files["standing_receipt.json"] do
            %{doc: doc} -> safe_receipt(doc)
            nil -> %{}
          end

        finish(dir, Map.keys(files), checks, receipt, nil, nil, nil)
    end
  end

  defp load_files(dir) do
    Enum.reduce(@files, {%{}, []}, fn file, {files, failures} ->
      path = Path.join(dir, file)

      case File.read(path) do
        {:ok, bytes} ->
          case JSON.decode(bytes) do
            {:ok, doc} ->
              {Map.put(files, file, %{path: path, bytes: bytes, doc: doc}), failures}

            {:error, reason} ->
              {files, failures ++ [{"package_file_undecodable:" <> file, inspect(reason)}]}
          end

        # A POSIX file error, not an SA2A refusal code: absence is reported as
        # the package reason string `package_file_missing:<file>`.
        {:error, posix} ->
          failure =
            if posix == :enoent,
              do: {"package_file_missing:" <> file, "#{path} does not exist"},
              else: {"package_file_unreadable:" <> file, inspect(posix)}

          {files, failures ++ [failure]}
      end
    end)
  end

  defp admit_and_reproduce(dir, files) do
    receipt = files["standing_receipt.json"].doc
    present = Map.keys(files)

    case shape(files) do
      :ok ->
        do_admit_and_reproduce(dir, files, receipt, present)

      {:error, what} ->
        checks = [failed("package_shape", :integrity, "package_malformed:" <> what, what)]
        finish(dir, present, checks, safe_receipt(receipt), nil, nil, nil)
    end
  end

  defp do_admit_and_reproduce(dir, files, receipt, present) do
    ocel = files["ocel.json"]
    validation = files["ocel_validation.json"].doc
    subject = files["subject.json"].doc
    evidence = receipt["evidence"]
    ocel_sha = sha256(ocel.bytes)
    {results, decode_errors} = decode_results(files["results.json"].doc)

    integrity = [
      check(
        "receipt_digest",
        :integrity,
        StandingReceipt.verify_digest(receipt) == :ok,
        "receipt_digest_mismatch",
        "standing_receipt.json content does not hash to its receipt_digest #{receipt["receipt_digest"]}"
      ),
      check(
        "specification",
        :integrity,
        receipt["specification"] == StandingReceipt.specification(),
        "specification_mismatch",
        "receipt specification #{inspect(receipt["specification"])}"
      ),
      check(
        "ocel_digest",
        :integrity,
        ocel_sha == evidence["ocel_digest"],
        "ocel_digest_mismatch",
        "sha256(ocel.json)=#{ocel_sha}, receipt binds #{inspect(evidence["ocel_digest"])}"
      ),
      check(
        "ocel_validation_binding",
        :integrity,
        ocel_sha == validation["ocel_sha256"],
        "ocel_validation_digest_mismatch",
        "ocel_validation.json validated #{inspect(validation["ocel_sha256"])}, ocel.json is #{ocel_sha}"
      ),
      run_binding_check(ocel.doc, receipt),
      check(
        "subject_identity",
        :integrity,
        subject_identity(subject) == receipt["subject"]["identity"],
        "subject_identity_mismatch",
        "sha256(subject.json without repo)=#{subject_identity(subject)}, receipt binds #{inspect(receipt["subject"]["identity"])}"
      ),
      check(
        "results_decodable",
        :integrity,
        decode_errors == [],
        "results_undecodable",
        Enum.join(decode_errors, "; ")
      )
    ]

    if Enum.all?(integrity, & &1["ok"]) do
      reproduce(dir, present, files, receipt, results, integrity)
    else
      finish(dir, present, integrity, safe_receipt(receipt), nil, nil, nil)
    end
  end

  defp reproduce(dir, present, files, receipt, results, integrity) do
    ocel = files["ocel.json"]
    validation = files["ocel_validation.json"].doc
    subject = files["subject.json"].doc
    evidence = receipt["evidence"]
    court = receipt["court"]
    descriptors = Enum.map(court["courts"], &%{id: &1["id"], gate: &1["gate"]})

    {profile_check, profile} =
      case Profile.parse(to_string(receipt["subject"]["claimed_profile"])) do
        {:ok, profile} ->
          {passed("profile", :reproduction, Profile.name(profile)), profile}

        {:error, _} ->
          {failed(
             "profile",
             :reproduction,
             "profile_unrecognized",
             inspect(receipt["subject"]["claimed_profile"])
           ), nil}
      end

    {courts_check, modules, falsifiers} = resolve_courts(court["courts"])
    corpus_available? = courts_check["ok"]

    identity_checks =
      if corpus_available? do
        [
          check(
            "court_revision",
            :reproduction,
            StandingReceipt.court_revision(modules) == court["revision"],
            "court_revision_mismatch",
            "compiled courts do not hash to the receipt's court revision"
          ),
          check(
            "falsifier_corpus_digest",
            :reproduction,
            StandingReceipt.corpus_digest(falsifiers) == court["falsifier_corpus_digest"],
            "falsifier_corpus_digest_mismatch",
            "the falsifier corpus declared in a fresh process differs from the one the receipt binds (hidden producer state?)"
          ),
          check(
            "query_set_digest",
            :reproduction,
            StandingReceipt.query_set_digest(falsifiers) == court["query_set_digest"],
            "query_set_digest_mismatch",
            "the conformance query set declared in a fresh process differs from the one the receipt binds"
          ),
          check(
            "ocel_mapping_digest",
            :reproduction,
            Mapping.digest(Runner.ocel_mappings(modules)) == court["ocel_mapping_digest"],
            "ocel_mapping_digest_mismatch",
            "the admitted OCEL mapping set recomputed from compiled courts differs from the receipt's"
          )
        ]
      else
        []
      end

    validation_status = Map.get(@validation_statuses, validation["status"], validation["status"])

    fact_checks = [
      check(
        "ocel_evidence_counts",
        :reproduction,
        evidence["ocel_bytes"] == byte_size(ocel.bytes) and
          evidence["ocel_events"] == length(ocel.doc["events"]) and
          evidence["ocel_objects"] == length(ocel.doc["objects"]),
        "ocel_evidence_counts_mismatch",
        "ocel.json has #{byte_size(ocel.bytes)} bytes, #{length(ocel.doc["events"])} events, #{length(ocel.doc["objects"])} objects"
      ),
      validation_check(validation, evidence, ocel.path),
      check(
        "results_cover_corpus",
        :reproduction,
        corpus_available? and
          MapSet.subset?(
            MapSet.new(falsifiers, & &1.id),
            MapSet.new(results, & &1.falsifier_id)
          ),
        "results_do_not_cover_corpus",
        "every declared falsifier must have a recorded result"
      )
    ]

    facts = %{
      courts: descriptors,
      ocel_validation_status: validation_status,
      ocel_dropped: evidence["ocel_dropped_records"],
      ocel_gaps: Map.get(evidence, "ocel_gaps", 0),
      subject_verification:
        StandingReceipt.verification_from_map(receipt["subject"]["verification"]),
      source_revision: subject["source_revision"],
      court_revision: court["revision"]
    }

    claimed = receipt_projection(receipt)

    {recorded, recorded_check} =
      projection_check(profile, results, facts, claimed, "recorded_projection")

    {index, index_check} =
      case Query.load(ocel.path, sha256(ocel.bytes)) do
        {:ok, index} ->
          {index, passed("ocel_index", :reproduction, "#{length(index.events)} events")}

        {:error, reason} ->
          {nil, failed("ocel_index", :reproduction, "ocel_unloadable", inspect(reason))}
      end

    {recorroborated, recorroboration_check} =
      recorroborate(results, falsifiers, index, corpus_available?)

    {reconstructed, reconstructed_check} =
      case recorroborated do
        nil ->
          {nil,
           failed(
             "standing_reconstructed",
             :reproduction,
             "standing_not_reproduced:corroboration_unavailable",
             "results could not be re-corroborated"
           )}

        rs ->
          projection_check(profile, rs, facts, claimed, "standing_reconstructed")
      end

    checks =
      integrity ++
        [profile_check, courts_check] ++
        identity_checks ++
        fact_checks ++
        [recorded_check, index_check, recorroboration_check, reconstructed_check]

    finish(
      dir,
      present,
      checks,
      safe_receipt(receipt),
      recorded,
      reconstructed,
      {index, ocel.doc}
    )
  end

  defp projection_check(nil, _results, _facts, _claimed, name),
    do:
      {nil,
       failed(name, :reproduction, name_reason(name, ["profile"]), "claimed profile unrecognized")}

  defp projection_check(profile, results, facts, claimed, name) do
    computed =
      StandingReceipt.recompute(Map.merge(facts, %{profile: profile, results: results}))

    actual = projection(computed)
    differing = claimed |> Map.keys() |> Enum.filter(&(claimed[&1] != actual[&1])) |> Enum.sort()

    check =
      if differing == [] do
        passed(name, :reproduction, "standing #{actual["standing"]} reproduced")
      else
        failed(
          name,
          :reproduction,
          name_reason(name, differing),
          "receipt standing #{inspect(claimed["standing"])}, recomputed #{inspect(actual["standing"])}; differing: #{Enum.join(differing, ", ")}"
        )
      end

    {computed, check}
  end

  defp name_reason("recorded_projection", keys),
    do: "recorded_projection_mismatch:" <> Enum.join(keys, ",")

  defp name_reason("standing_reconstructed", keys),
    do: "standing_not_reproduced:" <> Enum.join(keys, ",")

  defp recorroborate(_results, _falsifiers, nil, _available?),
    do:
      {nil,
       failed(
         "results_recorroborated",
         :reproduction,
         "results_not_recorroborated:ocel_unloadable",
         "no OCEL index"
       )}

  defp recorroborate(_results, _falsifiers, _index, false),
    do:
      {nil,
       failed(
         "results_recorroborated",
         :reproduction,
         "results_not_recorroborated:court_corpus_unavailable",
         "the courts the receipt names could not be resolved in this process"
       )}

  defp recorroborate(results, falsifiers, index, true) do
    by_id = Map.new(falsifiers, &{&1.id, &1})

    recorroborated =
      Enum.map(results, &Runner.corroborate(&1, Map.get(by_id, &1.falsifier_id), index))

    mismatched =
      results
      |> Enum.zip(recorroborated)
      |> Enum.reject(fn {recorded, again} ->
        recorded.verdict == again.verdict and
          recorded.ocel_corroborated? == again.ocel_corroborated?
      end)
      |> Enum.map(fn {recorded, again} ->
        "#{recorded.falsifier_id} recorded #{FailureClass.wire(recorded.verdict)}/#{inspect(recorded.ocel_corroborated?)}, re-corroborated #{FailureClass.wire(again.verdict)}/#{inspect(again.ocel_corroborated?)}"
      end)

    check =
      if mismatched == [],
        do: passed("results_recorroborated", :reproduction, "#{length(results)} results"),
        else:
          failed(
            "results_recorroborated",
            :reproduction,
            "results_not_recorroborated:" <> Integer.to_string(length(mismatched)),
            Enum.join(mismatched, "; ")
          )

    {recorroborated, check}
  end

  defp finish(dir, present, checks, receipt, recorded, reconstructed, ocel) do
    failures = Enum.reject(checks, & &1["ok"])

    outcome =
      cond do
        Enum.any?(failures, &(&1["class"] == "integrity")) -> "refused"
        failures != [] -> "diverged"
        true -> "reproduced"
      end

    process = process_facts()

    questions =
      case {outcome, ocel} do
        {"refused", _} ->
          all_unknown(
            "package refused (#{Enum.map_join(failures, ", ", & &1["reason"])}); standing is not inferred"
          )

        {_, nil} ->
          all_unknown("OCEL evidence unavailable")

        {_, {index, doc}} ->
          answer_questions(index, doc, reconstructed, process)
      end

    %{
      "schema" => @schema,
      "outcome" => outcome,
      "reasons" => Enum.map(failures, & &1["reason"]),
      "checks" => checks,
      "package" => %{
        "dir" => dir,
        "files" => Enum.sort(present),
        "run_id" => receipt["run_id"],
        "receipt_digest" => receipt["receipt_digest"],
        "claimed_profile" => receipt["claimed_profile"]
      },
      "standing" => %{
        "claimed" => receipt["standing"],
        "recorded" => recorded && FailureClass.wire(recorded.standing),
        "reconstructed" => reconstructed && FailureClass.wire(reconstructed.standing)
      },
      "questions" => questions,
      "fresh_process" => process
    }
  end

  defp crash_verdict(detail) do
    %{
      "schema" => @schema,
      "outcome" => "refused",
      "reasons" => ["fresh_consumer_crashed"],
      "checks" => [failed("fresh_consumer", :integrity, "fresh_consumer_crashed", detail)],
      "package" => %{},
      "standing" => %{},
      "questions" => all_unknown("fresh consumer crashed"),
      "fresh_process" => process_facts()
    }
  end

  # --- admission helpers -------------------------------------------------------

  @receipt_paths [
    ["receipt_digest"],
    ["run_id"],
    ["standing"],
    ["claim"],
    ["results"],
    ["gates"],
    ["subject", "identity"],
    ["subject", "claimed_profile"],
    ["court", "revision"],
    ["court", "courts"],
    ["court", "falsifier_corpus_digest"],
    ["court", "query_set_digest"],
    ["court", "ocel_mapping_digest"],
    ["evidence", "ocel_digest"]
  ]

  defp shape(files) do
    receipt = files["standing_receipt.json"].doc
    ocel = files["ocel.json"].doc

    cond do
      not is_map(receipt) ->
        {:error, "standing_receipt.json is not an object"}

      missing = Enum.find(@receipt_paths, &(dig(receipt, &1) == nil)) ->
        {:error, "standing_receipt.json lacks " <> Enum.join(missing, ".")}

      not (is_list(receipt["court"]["courts"]) and
               Enum.all?(receipt["court"]["courts"], &is_map/1)) ->
        {:error, "standing_receipt.json court.courts is not a list of objects"}

      not is_map(receipt["evidence"]) ->
        {:error, "standing_receipt.json evidence is not an object"}

      not is_list(files["results.json"].doc) ->
        {:error, "results.json is not a list"}

      not (is_map(ocel) and is_list(ocel["events"]) and is_list(ocel["objects"])) ->
        {:error, "ocel.json lacks events/objects"}

      not is_map(files["ocel_validation.json"].doc) ->
        {:error, "ocel_validation.json is not an object"}

      not is_map(files["subject.json"].doc) ->
        {:error, "subject.json is not an object"}

      true ->
        :ok
    end
  end

  defp safe_receipt(receipt) when is_map(receipt) do
    %{
      "run_id" => receipt["run_id"],
      "receipt_digest" => receipt["receipt_digest"],
      "standing" => receipt["standing"],
      "claimed_profile" => dig(receipt, ["subject", "claimed_profile"])
    }
  end

  defp safe_receipt(_), do: %{}

  defp run_binding_check(ocel_doc, receipt) do
    runs =
      for %{"type" => "chicago_run"} = object <- ocel_doc["objects"] do
        object_attributes(object)
      end

    expected = {receipt["run_id"], receipt["court"]["ocel_mapping_digest"]}

    bound? =
      case runs do
        [attributes] -> {attributes["run_id"], attributes["mapping_digest"]} == expected
        _ -> false
      end

    check(
      "ocel_run_binding",
      :integrity,
      bound?,
      "ocel_run_mismatch",
      "ocel.json chicago_run objects #{inspect(Enum.map(runs, &Map.take(&1, ["run_id", "mapping_digest"])))}, receipt run #{inspect(elem(expected, 0))}"
    )
  end

  defp object_attributes(%{"attributes" => attributes}) when is_list(attributes) do
    for %{"name" => name} = attribute <- attributes, into: %{}, do: {name, attribute["value"]}
  end

  defp object_attributes(_), do: %{}

  defp subject_identity(subject) do
    subject |> Map.delete("repo") |> Json.canonical() |> sha256()
  end

  defp decode_results(docs) do
    docs
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {doc, i}, {results, errors} ->
      case decode_result(doc) do
        {:ok, result} -> {[result | results], errors}
        {:error, what} -> {results, ["results.json[#{i}] #{what}" | errors]}
      end
    end)
    |> then(fn {results, errors} -> {Enum.reverse(results), Enum.reverse(errors)} end)
  end

  defp decode_result(%{"falsifier_id" => id} = doc) when is_binary(id) do
    with {:ok, verdict} <- lookup(@verdicts, doc["verdict"], "verdict"),
         {:ok, kind} <- lookup(@kinds, doc["kind"], "kind"),
         {:ok, class} <- optional_lookup(@classes, doc["failure_class"], "failure_class") do
      {:ok,
       %Result{
         falsifier_id: id,
         court_id: doc["court_id"],
         gate: doc["gate"],
         kind: kind,
         verdict: verdict,
         attempt_observed?: tri(doc["attempt_observed"]),
         outcome_observed?: tri(doc["outcome_observed"]),
         failure_class: class,
         detail: doc["detail"],
         duration_us: doc["duration_us"],
         ocel_corroborated?: doc["ocel_corroborated"],
         ocel_detail: doc["ocel_detail"],
         evidence: doc["evidence"] || %{},
         measurements: doc["measurements"] || %{}
       }}
    end
  end

  defp decode_result(_), do: {:error, "is not a result object"}

  defp lookup(table, key, what) do
    case Map.fetch(table, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "unrecognized #{what} #{inspect(key)}"}
    end
  end

  defp optional_lookup(_table, nil, _what), do: {:ok, nil}
  defp optional_lookup(table, key, what), do: lookup(table, key, what)

  defp tri("unknown"), do: :unknown
  defp tri(value), do: value

  # --- reproduction helpers ----------------------------------------------------

  defp resolve_courts(entries) do
    resolved =
      Enum.map(entries, fn entry ->
        with {:ok, module} <- resolve_court(entry["module"]),
             true <-
               (module.id() == entry["id"] and module.gate() == entry["gate"]) ||
                 {:error,
                  "#{entry["module"]} declares id/gate #{module.id()}/#{inspect(module.gate())}"} do
          {:ok, module}
        end
      end)

    case Enum.filter(resolved, &match?({:error, _}, &1)) do
      [] ->
        modules = Enum.map(resolved, fn {:ok, m} -> m end)

        try do
          falsifiers =
            modules
            |> Enum.flat_map(& &1.falsifiers())
            |> Map.new(&{&1.id, &1})
            |> Map.values()

          {passed("courts_resolved", :reproduction, Enum.map_join(modules, ", ", &inspect/1)),
           modules, falsifiers}
        rescue
          exception ->
            {failed(
               "courts_resolved",
               :reproduction,
               "court_corpus_unavailable",
               "falsifiers/0 raised: " <> Exception.message(exception)
             ), [], []}
        end

      errors ->
        {failed(
           "courts_resolved",
           :reproduction,
           "court_corpus_unavailable",
           Enum.map_join(errors, "; ", fn {:error, e} -> e end)
         ), [], []}
    end
  end

  defp resolve_court(name) when is_binary(name) do
    full = "Elixir." <> name

    module =
      try do
        String.to_existing_atom(full)
      rescue
        ArgumentError ->
          if Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/, name) and
               :code.where_is_file(String.to_charlist(full <> ".beam")) != :non_existing,
             do: String.to_atom(full),
             else: nil
      end

    if module && Court.court?(module),
      do: {:ok, module},
      else: {:error, "court #{name} is not on this process's code path"}
  end

  defp resolve_court(other), do: {:error, "court module #{inspect(other)} is not a name"}

  defp validation_check(validation, evidence, ocel_path) do
    recorded? =
      validation["status"] == evidence["ocel_validation"] and
        validation["validator"] == evidence["ocel_validator"] and
        validation["status"] == "valid" == evidence["ocel_valid"]

    {rerun?, detail} = rerun_validator(validation, ocel_path)

    check(
      "ocel_validation",
      :reproduction,
      recorded? and rerun?,
      "ocel_validation_not_reproduced",
      "recorded #{inspect(validation["status"])} by #{inspect(validation["validator"])}; #{detail}"
    )
  end

  defp rerun_validator(%{"validator" => name, "status" => status}, path) when is_binary(name) do
    module =
      try do
        String.to_existing_atom("Elixir." <> name)
      rescue
        ArgumentError -> nil
      end

    if module && Code.ensure_loaded?(module) && function_exported?(module, :validate_file, 1) do
      rerun =
        case module.validate_file(path) do
          {:ok, _} -> "valid"
          {:error, _} -> "invalid"
        end

      {rerun == status, "re-validated in this process: #{rerun}"}
    else
      {true, "validator not on this process's code path; recorded status carried"}
    end
  rescue
    exception -> {false, "validator raised: " <> Exception.message(exception)}
  end

  defp rerun_validator(_validation, _path), do: {false, "validation receipt names no validator"}

  defp receipt_projection(receipt) do
    normalize(%{
      "results" => receipt["results"],
      "gates" => receipt["gates"],
      "standing" => receipt["standing"],
      "claim" => receipt["claim"],
      "gate_evidence" => Map.take(receipt["evidence"], @gate_evidence_keys)
    })
  end

  defp projection(computed) do
    normalize(%{
      "results" => computed.tallies,
      "gates" => computed.gate_rows,
      "standing" => FailureClass.wire(computed.standing),
      "claim" => computed.claim,
      "gate_evidence" => computed.gate_evidence
    })
  end

  defp normalize(term), do: term |> Json.canonical() |> JSON.decode!()

  # --- §74 evidence questions --------------------------------------------------

  defp answer_questions(index, doc, reconstructed, process) do
    %{
      "semantic_object" => semantic_object(index),
      "standing_basis" => standing_basis(reconstructed),
      "plan" =>
        typed_objects(
          doc,
          ~r/plan/,
          "no plan object in ocel.json; the package cannot say which plan selected the operation"
        ),
      "authority_grant" =>
        typed_objects(
          doc,
          ~r/grant|authority/,
          "no authority-grant object in ocel.json; admission outcomes alone do not identify the grant (§65)"
        ),
      "prepared_before_actuation" => prepared_before_actuation(index),
      "independent_consequence" => independent_consequence(index),
      "replayable_without_do" => replayable_without_do(reconstructed, process)
    }
  end

  defp semantic_object(index) do
    committed =
      Enum.filter(
        index.events,
        &(&1.type == "brce.commit" and to_string(&1.attributes["outcome"]) == "committed")
      )

    acted_on =
      index.events
      |> Enum.filter(&(&1.type == "dispatch.stop"))
      |> Enum.flat_map(& &1.objects)
      |> Enum.filter(&(elem(&1, 1) == "acted_on"))
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.sort()

    if committed == [] and acted_on == [] do
      unknown("no committed actuation and no acted-on record in ocel.json")
    else
      answered(
        %{
          "acted_on" => acted_on,
          "capabilities" => typed_ids(committed, index, "capability"),
          "commands" => typed_ids(committed, index, "command")
        },
        "brce.commit(outcome=committed) objects and dispatch.stop acted_on relationships in ocel.json"
      )
    end
  end

  defp standing_basis(nil), do: unknown("standing could not be reconstructed from the package")

  defp standing_basis(computed) do
    answered(
      %{
        "standing" => FailureClass.wire(computed.standing),
        "gates" =>
          Enum.map(computed.gate_rows, &Map.take(&1, ["gate", "required", "status", "courts"])),
        "falsifiers_killed" => computed.tallies["falsifiers_killed"],
        "positive_controls_passed" => computed.tallies["positive_controls_passed"],
        "survived" => computed.tallies["survived_ids"],
        "unresolved" => computed.tallies["unresolved_ids"]
      },
      "StandingReceipt.recompute/1 over results.json re-corroborated against ocel.json"
    )
  end

  defp typed_objects(doc, pattern, unknown_basis) do
    ids =
      for %{"type" => type, "id" => id} <- doc["objects"],
          is_binary(type) and Regex.match?(pattern, type),
          do: id

    case ids do
      [] -> unknown(unknown_basis)
      ids -> answered(Enum.sort(ids), "objects of matching type in ocel.json")
    end
  end

  defp prepared_before_actuation(index) do
    starts = Enum.filter(index.events, &(&1.type == "brce.actuate.start"))
    prepares = Enum.filter(index.events, &(&1.type == "brce.prepare"))

    case starts do
      [] ->
        unknown("no brce.actuate.start in ocel.json")

      starts ->
        linked =
          Enum.map(starts, fn start ->
            commands = typed_set(start, index, "command")

            expected =
              if to_string(start.attributes["consequence"]) in ["change", "external_do"],
                do: "prepared",
                else: "not_required"

            MapSet.size(commands) > 0 and
              Enum.any?(prepares, fn prepare ->
                prepare.seq < start.seq and
                  to_string(prepare.attributes["outcome"]) == expected and
                  not MapSet.disjoint?(commands, typed_set(prepare, index, "command"))
              end)
          end)

        answered(
          Enum.all?(linked),
          "#{length(starts)} brce.actuate.start; #{Enum.count(linked, & &1)} preceded (by chicago_seq, not wall clock) by a brce.prepare for the same command with the required outcome"
        )
    end
  end

  defp independent_consequence(index) do
    observations =
      Enum.filter(
        index.events,
        &(String.starts_with?(&1.type, "postcondition.") or
            String.starts_with?(&1.type, "post_state."))
      )

    case observations do
      [] ->
        unknown(
          "no independent post-state observation (postcondition.* / post_state.*) in ocel.json; actuator telemetry is not independent (§73)"
        )

      observations ->
        answered(
          Enum.map(observations, &%{"activity" => &1.type, "attributes" => &1.attributes}),
          "independent post-state observation events in ocel.json"
        )
    end
  end

  defp replayable_without_do(nil, _process),
    do: unknown("standing was not reconstructed, so no DO-free replay was demonstrated")

  defp replayable_without_do(_computed, process) do
    if process["ash_a2a_started"] == false and process["do_boundary_loaded"] == false do
      answered(
        true,
        "standing re-derived from durable files in OS process #{process["os_pid"]} where :ash_a2a was never started and no DO boundary module was loaded"
      )
    else
      unknown(
        "verification ran where :ash_a2a is started or a DO boundary is loaded; DO-free replay is not demonstrated by this process"
      )
    end
  end

  defp typed_ids(events, index, type) do
    events
    |> Enum.flat_map(&MapSet.to_list(typed_set(&1, index, type)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp typed_set(event, index, type) do
    event.objects
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&(Map.get(index.object_types, &1) == type))
    |> MapSet.new()
  end

  defp answered(answer, basis),
    do: %{"status" => "ANSWERED", "answer" => answer, "basis" => basis}

  defp unknown(basis), do: %{"status" => "UNKNOWN", "answer" => "UNKNOWN", "basis" => basis}

  defp all_unknown(basis), do: Map.new(@questions, &{&1, unknown(basis)})

  # --- shared helpers ----------------------------------------------------------

  defp process_facts do
    started =
      Application.started_applications()
      |> Enum.map(&Atom.to_string(elem(&1, 0)))
      |> Enum.sort()

    %{
      "os_pid" => System.pid(),
      "ash_a2a_started" => "ash_a2a" in started,
      "do_boundary_loaded" => Enum.any?(@do_boundary, &:erlang.module_loaded/1),
      "started_applications" => started
    }
  end

  defp check(name, class, true, _reason, detail), do: passed(name, class, detail)
  defp check(name, class, _false, reason, detail), do: failed(name, class, reason, detail)

  defp passed(name, class, detail),
    do: %{"check" => name, "class" => Atom.to_string(class), "ok" => true, "detail" => detail}

  defp failed(name, class, reason, detail),
    do: %{
      "check" => name,
      "class" => Atom.to_string(class),
      "ok" => false,
      "reason" => reason,
      "detail" => detail
    }

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: dig(Map.get(map, key), rest)
  defp dig(_value, _keys), do: nil

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
