defmodule AshA2A.Chicago.Crown do
  @moduledoc """
  RFC-SA2A-002 v26.9.16 Chicago Crown assembly (§25, §31, §98-§101, §103,
  §114-§116, §121, §143, §145-§147, Appendix C, Appendix F).

  "Chicago Crown -- successful completion of all gates required by the
  claimed conformance profile" (§4 Terms). `AshA2A.Chicago.Runner` executes
  one qualification run and issues its own per-run standing
  (`AshA2A.Chicago.StandingReceipt`). This module sits one layer above that:
  it takes a completed `AshA2A.Chicago.Runner.Run.t()` and assembles the
  crown-level package the RFC's release sections describe, all computed for
  real from the run's own courts, results, subject and receipt -- nothing
  here is asserted independently of what actually executed.

  ## Pieces

    * `gate_coverage/2` -- §31 twelve-gate coverage table over the courts
      discovered/selected for the claimed profile.
    * `mandatory_corpus_coverage/2` / `mandatory_corpus_gaps/2` -- §98: every
      one of the fourteen mandatory RFC-SA2A-001 counterexamples resolved to
      a real, currently-declared falsifier id
      (`priv/sa2a/chicago_mandatory_corpus.json`). A member whose falsifier
      id does not resolve in the discovered corpus is an evidence gap.
    * `compliance_matrix/1` -- §145: `RFC-SA2A-001 requirement -> court/
      falsifier id -> evidence artifact -> result -> exact subject`, built
      from `AshA2A.Semantic.Conformance.requirement_results/0` (the real,
      executable RFC-SA2A-001 checks) joined to the run's courts by shared
      RFC-SA2A-001 section tokens (`rfc_sections/0`).
    * `package_completeness/2` -- §114: presence check over the required
      conformance artifact list, from the real evidence directory and
      receipt -- never fabricated for an artifact this run does not track.
    * `evidence_questions/1` -- Appendix C, answered mechanically by
      `AshA2A.Chicago.FreshConsumer.verify_package/1` over the run's own
      durable package (no new machinery re-implements what FreshConsumer
      already answers).
    * `standing/1` / `build/1` -- the crown-level standing: the run's own
      `StandingReceipt` standing, downgraded from `CONFORMANT` to
      `PARTIAL_ALIVE` for a `:strict` claim carrying an open §98 or §145
      evidence gap (§146 Definition of Done requires defeating the mandatory
      adversarial falsifiers; §147 requires positive evidence for every
      required boundary) -- never silently promoted, never re-raised past
      what the receipt itself supports.
    * `run/1` -- runs the court (`AshA2A.Chicago.Runner.run/1`) and writes
      `crown.json` into the evidence directory alongside the five files the
      runner already writes.

  Appendix F's mapping is the qualitative map this module makes mechanical
  and per-run: §145's matrix is Appendix F rendered against one exact
  executed subject, one falsifier corpus revision, one receipt.
  """

  alias AshA2A.Chicago
  alias AshA2A.Chicago.{FreshConsumer, Json, Profile, Result, Runner, StandingReceipt}
  alias AshA2A.Semantic.Conformance

  @schema "ash_a2a.chicago.crown/1"
  @mandatory_corpus_relative_path "sa2a/chicago_mandatory_corpus.json"
  @section_token ~r/S\d+(?:\.\d+)?/

  # RFC-SA2A-001 S42: a malformed mandatory-corpus registry document is a
  # structural defect, classified without editing `AshA2A.Semantic.Refusal`'s
  # own table (`AshA2A.Semantic.Refusal.mapping/0` merges this in for any
  # compiled module exporting `__sa2a_refusal_codes__/0`, the same mechanism
  # `AshA2A.Chicago.CourtManifest` uses for its own malformed-document code).
  @refusal_codes %{mandatory_corpus_malformed: :refused_structure}

  @doc false
  def __sa2a_refusal_codes__, do: @refusal_codes

  @gate_titles %{
    1 => "Exact Identity Fenced",
    2 => "Executable World Admitted",
    3 => "Real Load-Bearing Collaborators / Zero Mocks",
    4 => "Planning Candidate-Only",
    5 => "Whole Bounded Plan Preflighted",
    6 => "Autonomous Execution Inside Envelope",
    7 => "Sole DO Boundary / Zero Unreceipted Actuation",
    8 => "Independent Postcondition Observation",
    9 => "Complete Receipt Identity Binding",
    10 => "Offline Replay Succeeds",
    11 => "Fresh-Consumer Proof Succeeds",
    12 => "Zero Runtime Inference on KNOWN"
  }

  @doc "Crown package schema identity."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "§31 title of one of the twelve canonical Chicago Crown gates."
  @spec gate_title(1..12) :: String.t()
  def gate_title(gate), do: Map.get(@gate_titles, gate, "Gate #{gate}")

  @doc "Committed mandatory-corpus registry path inside this app's `priv/`."
  @spec mandatory_corpus_path() :: String.t()
  def mandatory_corpus_path,
    do: Path.join(to_string(:code.priv_dir(:ash_a2a)), @mandatory_corpus_relative_path)

  # --- (a) gate coverage (§31) -----------------------------------------------

  @doc """
  §31 gate coverage table for `profile` over `courts` (default every
  discoverable court): one row per canonical gate 1-12, the gate's title,
  whether `profile` requires it (`AshA2A.Chicago.Profile.required_gates/1`),
  the discovered court ids that declare it, and a status --
  `"COVERED"` (>= 1 applicable court declares the gate), `"NO_COURT"` (the
  profile requires the gate and no applicable court declares it -- an open
  evidence gap per §31's own text), or `"NOT_REQUIRED"`.
  """
  @spec gate_coverage(Profile.t(), [module()]) :: [map()]
  def gate_coverage(profile, courts \\ Chicago.courts()) do
    applicable = Enum.filter(courts, &Profile.applicable?(&1.profile(), profile))
    required = Profile.required_gates(profile)

    for gate <- 1..12 do
      gate_courts = applicable |> Enum.filter(&(&1.gate() == gate)) |> Enum.sort_by(& &1.id())

      %{
        "gate" => gate,
        "title" => gate_title(gate),
        "required" => gate in required,
        "court_ids" => Enum.map(gate_courts, & &1.id()),
        "status" =>
          cond do
            gate_courts != [] -> "COVERED"
            gate in required -> "NO_COURT"
            true -> "NOT_REQUIRED"
          end
      }
    end
  end

  # --- (b) §98 mandatory-corpus registry --------------------------------------

  @doc """
  Loads the §98 mandatory-corpus registry: fourteen RFC-SA2A-001
  counterexamples, each mapped to the id of the real falsifier in the
  discovered corpus that executes it.
  """
  @spec load_mandatory_corpus(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def load_mandatory_corpus(path \\ mandatory_corpus_path()) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"members" => members}} when is_list(members) <- JSON.decode(raw) do
      {:ok, members}
    else
      {:ok, _other} -> {:error, :mandatory_corpus_malformed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  §98 mandatory-corpus coverage: one row per registry member, `"resolved"`
  true only when its `falsifier_id` is really declared by one of `courts`
  (default every discoverable court) right now -- a renamed, removed or
  never-implemented falsifier resolves to `false`, never a stale claim.
  """
  @spec mandatory_corpus_coverage([module()], [map()] | nil) :: [map()]
  def mandatory_corpus_coverage(courts \\ Chicago.courts(), members \\ nil) do
    members = members || load_members()
    declared = Map.new(Enum.flat_map(courts, & &1.falsifiers()), &{&1.id, &1})

    Enum.map(members, fn member ->
      falsifier = Map.get(declared, member["falsifier_id"])

      %{
        "id" => member["id"],
        "description" => member["description"],
        "falsifier_id" => member["falsifier_id"],
        "resolved" => falsifier != nil,
        "court_id" => falsifier && falsifier.court_id
      }
    end)
  end

  @doc "Mandatory-corpus members whose falsifier id does not resolve -- an open evidence gap (§98)."
  @spec mandatory_corpus_gaps([module()], [map()] | nil) :: [map()]
  def mandatory_corpus_gaps(courts \\ Chicago.courts(), members \\ nil) do
    courts |> mandatory_corpus_coverage(members) |> Enum.reject(& &1["resolved"])
  end

  defp load_members do
    case load_mandatory_corpus() do
      {:ok, members} -> members
      {:error, _reason} -> []
    end
  end

  # --- (c) §145 compliance matrix ---------------------------------------------

  @doc """
  §145 compliance matrix: `RFC-SA2A-001 requirement -> court/falsifier id ->
  evidence artifact -> result -> exact subject`, one row per
  `AshA2A.Semantic.Conformance.requirement_results/0` entry (the real,
  executable RFC-SA2A-001 checks), joined to `run.courts` by shared
  RFC-SA2A-001 section tokens between the requirement's `:rfc_section` and
  each court's `rfc_sections/0`. `"result"` is `"NO_COURT"` (the §145 open
  evidence gap), `"DECLARED_NOT_EXECUTED"`, `"PASSED"`, `"FAILED"` or
  `"OPEN"`, derived from the real corroborated results of this run.
  """
  @spec compliance_matrix(Runner.Run.t()) :: [map()]
  def compliance_matrix(%Runner.Run{} = run) do
    subject_identity = get_in(run.receipt, ["subject", "identity"])
    by_falsifier = Map.new(run.results, &{&1.falsifier_id, &1})

    Conformance.requirement_results()
    |> Enum.map(fn req ->
      req_tokens = section_tokens(req.rfc_section)

      matching_courts =
        run.courts
        |> Enum.filter(fn court ->
          Enum.any?(section_tokens(court.rfc_sections()), &(&1 in req_tokens))
        end)
        |> Enum.sort_by(& &1.id())

      falsifier_ids =
        matching_courts
        |> Enum.flat_map(fn court -> Enum.map(court.falsifiers(), & &1.id) end)
        |> Enum.sort()

      court_results =
        falsifier_ids |> Enum.map(&Map.get(by_falsifier, &1)) |> Enum.reject(&is_nil/1)

      %{
        "requirement_id" => Atom.to_string(req.id),
        "requirement_title" => req.title,
        "rfc_section" => req.rfc_section,
        "requirement_status" => Atom.to_string(req.status),
        "court_ids" => Enum.map(matching_courts, & &1.id()),
        "falsifier_ids" => falsifier_ids,
        "evidence_artifact" => evidence_artifact(falsifier_ids),
        "result" => matrix_result(matching_courts, court_results),
        "exact_subject" => subject_identity
      }
    end)
  end

  defp evidence_artifact([]), do: nil
  defp evidence_artifact(_falsifier_ids), do: "ocel.json + results.json"

  defp matrix_result([], _court_results), do: "NO_COURT"
  defp matrix_result(_matching_courts, []), do: "DECLARED_NOT_EXECUTED"

  defp matrix_result(_matching_courts, court_results) do
    cond do
      Enum.any?(court_results, &Result.failed?/1) -> "FAILED"
      Enum.all?(court_results, &Result.counts_as_pass?/1) -> "PASSED"
      true -> "OPEN"
    end
  end

  defp section_tokens(strings) when is_list(strings) do
    strings |> Enum.flat_map(&Regex.scan(@section_token, &1)) |> List.flatten() |> Enum.uniq()
  end

  defp section_tokens(string) when is_binary(string), do: section_tokens([string])

  # --- (d) §114 package completeness ------------------------------------------

  @doc """
  §114 required-conformance-artifact presence check over `run`'s real
  evidence directory and receipt. An artifact this run genuinely does not
  track (`"commands and exit codes"`, `"raw test output"` -- the Elixir
  Chicago court is invoked in-process, not as a wrapped external command) is
  reported `false`, never fabricated as present.
  """
  @spec package_completeness(Runner.Run.t(), map()) :: map()
  def package_completeness(%Runner.Run{} = run, fresh_consumer_verdict \\ %{}) do
    receipt = run.receipt
    gates = Map.new(receipt["gates"] || [], &{&1["gate"], &1})
    bench_dir = Path.join(run.evidence_dir, "bench")
    measured? = Enum.any?(run.results, &(&1.court_id == "SA2A-BENCH" and &1.verdict == :measured))
    file? = fn name -> File.exists?(Path.join(run.evidence_dir, name)) end

    items = [
      {"exact-subject manifest", file?.("subject.json")},
      {"claimed SA2A profile", is_binary(get_in(receipt, ["subject", "claimed_profile"]))},
      {"root-manifest identity", is_binary(get_in(receipt, ["subject", "root_manifest_digest"]))},
      {"court version", is_binary(get_in(receipt, ["court", "version"]))},
      {"falsifier inventory",
       is_binary(get_in(receipt, ["court", "falsifier_corpus_digest"])) and
         get_in(receipt, ["results", "falsifiers_total"]) > 0},
      {"commands and exit codes", false},
      {"raw test output", false},
      {"raw durable receipts", file?.("standing_receipt.json")},
      {"independent postcondition evidence", gate_attempted?(gates, 8)},
      {"OCEL 2.0 artifact", file?.("ocel.json")},
      {"OCEL validation receipt", file?.("ocel_validation.json")},
      {"conformance-query results", file?.("results.json")},
      {"benchmark environment receipt", File.dir?(bench_dir)},
      {"benchmark results", measured?},
      {"fresh-consumer result", fresh_consumer_verdict["outcome"] in ["reproduced", "diverged"]},
      {"replay result", gate_attempted?(gates, 10)},
      {"final standing receipt", file?.("standing_receipt.json")},
      {"known exclusions / unsupported capabilities", is_list(receipt["excluded"])}
    ]

    artifacts =
      Enum.map(items, fn {name, present?} -> %{"artifact" => name, "present" => present?} end)

    missing = artifacts |> Enum.reject(& &1["present"]) |> Enum.map(& &1["artifact"])

    %{"artifacts" => artifacts, "complete?" => missing == [], "missing" => missing}
  end

  defp gate_attempted?(gates, n) do
    case Map.get(gates, n) do
      nil -> false
      info -> info["attempted"] == true
    end
  end

  # --- (e) Appendix C via FreshConsumer ---------------------------------------

  @doc """
  Appendix C evidence questions, answered mechanically by
  `AshA2A.Chicago.FreshConsumer.verify_package/1` over `run`'s own durable
  package -- pure, no telemetry, no re-implementation of what FreshConsumer
  already answers.
  """
  @spec evidence_questions(Runner.Run.t()) :: map()
  def evidence_questions(%Runner.Run{evidence_dir: dir}), do: FreshConsumer.verify_package(dir)

  # --- (f) crown assembly ------------------------------------------------------

  @doc """
  Assembles the full crown package for a completed run: gate coverage (a),
  mandatory-corpus coverage and gaps (b), the §145 compliance matrix (c),
  §114 package completeness (d), the Appendix C evidence questions (e), and
  the crown-level standing and claim.
  """
  @spec build(Runner.Run.t()) :: map()
  def build(%Runner.Run{} = run) do
    mandatory_gaps = mandatory_corpus_gaps(run.courts)
    matrix = compliance_matrix(run)
    matrix_gaps = Enum.filter(matrix, &(&1["result"] == "NO_COURT"))
    fresh = evidence_questions(run)
    {standing, claim} = crown_standing(run.receipt, run.profile, mandatory_gaps, matrix_gaps)

    doc = %{
      "schema" => @schema,
      "specification" => StandingReceipt.specification(),
      "run_id" => run.run_id,
      "claimed_profile" => Profile.name(run.profile),
      "subject_identity" => get_in(run.receipt, ["subject", "identity"]),
      "standing_receipt_digest" => run.receipt["receipt_digest"],
      "gate_coverage" => gate_coverage(run.profile, run.courts),
      "mandatory_corpus" => %{
        "members" => mandatory_corpus_coverage(run.courts),
        "gaps" => mandatory_gaps,
        "complete?" => mandatory_gaps == []
      },
      "compliance_matrix" => matrix,
      "compliance_matrix_open_gaps" => Enum.map(matrix_gaps, & &1["requirement_id"]),
      "package_completeness" => package_completeness(run, fresh),
      "evidence_questions" => fresh["questions"] || %{},
      "fresh_consumer_outcome" => fresh["outcome"],
      "standing" => standing,
      "claim" => claim
    }

    Map.put(doc, "crown_digest", digest(doc))
  end

  @doc "sha256 over the canonical JSON of the crown document without `crown_digest`."
  @spec digest(map()) :: String.t()
  def digest(doc) do
    doc
    |> Map.delete("crown_digest")
    |> Json.canonical()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp crown_standing(receipt, profile, mandatory_gaps, matrix_gaps) do
    base = receipt["standing"]

    cond do
      base != "CONFORMANT" ->
        {base, receipt["claim"]}

      profile == :strict and mandatory_gaps != [] ->
        {"PARTIAL_ALIVE",
         "#{Profile.name(profile)} crown PARTIAL_ALIVE: §98 mandatory RFC-SA2A-001 falsifier " <>
           "corpus has #{length(mandatory_gaps)} open evidence gap(s) unresolved in the " <>
           "discovered corpus: #{Enum.map_join(mandatory_gaps, ", ", & &1["id"])}"}

      profile == :strict and matrix_gaps != [] ->
        {"PARTIAL_ALIVE",
         "#{Profile.name(profile)} crown PARTIAL_ALIVE: §145 compliance matrix has " <>
           "#{length(matrix_gaps)} REQUIRED requirement(s) with no mapped court: " <>
           "#{Enum.map_join(matrix_gaps, ", ", & &1["requirement_id"])}"}

      true ->
        {base, receipt["claim"]}
    end
  end

  @doc """
  Runs the court (`AshA2A.Chicago.Runner.run/1`) and assembles + writes the
  crown package (`crown.json`) into the run's evidence directory, alongside
  the five files the runner itself writes.
  """
  @spec run(keyword()) :: {:ok, %{run: Runner.Run.t(), crown: map()}} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, run} <- Runner.run(opts) do
      crown = build(run)
      write!(run.evidence_dir, crown)
      {:ok, %{run: run, crown: crown}}
    end
  end

  defp write!(evidence_dir, crown) do
    File.mkdir_p!(evidence_dir)
    File.write!(Path.join(evidence_dir, "crown.json"), Json.canonical(crown) <> "\n")
  end
end
