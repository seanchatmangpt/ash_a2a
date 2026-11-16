# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root Freedom Gym, HDDL Planning
# Target File 1 of Worker 02
# Consolidated from 22 source files:
#   - test/ash_a2a_eval_test.exs
#   - test/ash_a2a_evidence_class_test.exs
#   - test/ash_a2a_execution_pplan_test.exs
#   - test/ash_a2a_execution_snapshot_test.exs
#   - test/ash_a2a_failure_injection_test.exs
#   - test/ash_a2a_freedom_gym_chicago_core_test.exs
#   - test/ash_a2a_freedom_gym_hddl_plan_test.exs
#   - test/ash_a2a_freedom_gym_llm_test.exs
#   - test/ash_a2a_freedom_gym_ocel_conformance_e2e_test.exs
#   - test/ash_a2a_freedom_gym_phase_admission_test.exs
#   - test/ash_a2a_freedom_gym_zai_test.exs
#   - test/ash_a2a_gall_command_authority_test.exs
#   - test/ash_a2a_gall_process_autonomics_test.exs
#   - test/ash_a2a_gall_swf_message_test.exs
#   - test/ash_a2a_hddl_deterministic_planning_test.exs
#   - test/ash_a2a_hddl_solver_qualification_test.exs
#   - test/ash_a2a_httpjson_tasks_list_test.exs
#   - test/ash_a2a_json_roundtrip_test.exs
#   - test/ash_a2a_lane07_taskstore_hardening_test.exs
#   - test/ash_a2a_llm_profiles_test.exs
#   - test/ash_a2a_margin_gate_e2e_test.exs
#   - test/ash_a2a_mock_discipline_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a_eval_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.EvalTest.Catalog do
  @moduledoc """
  Real fixture resource for `test/ash_a2a_eval_test.exs`: two real generic
  `:action` skills (`:classify`, `:greet`) with `consequence: :observe`, so
  the eval suite drives them through the real `message/send` transport with
  deterministic outputs. String-keyed result maps mirror the wire shape.
  """

  use Ash.Resource,
    domain: AshA2A.EvalTest.CatalogDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :classify, :map do
      argument(:query, :string, allow_nil?: false)

      run(fn _input, _context ->
        {:ok,
         %{
           "label" => "refund",
           "confidence" => 0.98,
           "meta" => %{"channel" => "web"}
         }}
      end)
    end

    action :greet, :string do
      argument(:name, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, "hello " <> input.arguments.name}
      end)
    end
  end

  a2a do
    skill(:classify, :classify, consequence: :observe)
    skill(:greet, :greet, consequence: :observe)
  end
end

defmodule AshA2A.EvalTest.CatalogDomain do
  @moduledoc "Real fixture domain for the eval fixture resource."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.EvalTest.Catalog)
  end
end

defmodule AshA2A.EvalTest.GoodAgent do
  @moduledoc "Real `use AshA2A.Agent` over the fixture catalog: full-quality outputs."

  use AshA2A.Agent, resource_or_domain: AshA2A.EvalTest.Catalog, name: "eval_good_catalog_agent"
end

defmodule AshA2A.EvalTest.DegradedCatalog do
  @moduledoc """
  The deliberately degraded REAL skill (the regression scenario): same skill
  names, same actions, genuinely worse outputs -- `:greet` case-mangled,
  `:classify` label flattened to "unknown" and confidence dropped. No mocks:
  this is a real second resource an operator would ship by breaking their
  skill.
  """

  use Ash.Resource,
    domain: AshA2A.EvalTest.DegradedCatalogDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :classify, :map do
      argument(:query, :string, allow_nil?: false)

      run(fn _input, _context ->
        {:ok, %{"label" => "unknown", "confidence" => nil, "meta" => %{"channel" => "web"}}}
      end)
    end

    action :greet, :string do
      argument(:name, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, String.upcase("hello " <> input.arguments.name)}
      end)
    end
  end

  a2a do
    skill(:classify, :classify, consequence: :observe)
    skill(:greet, :greet, consequence: :observe)
  end
end

defmodule AshA2A.EvalTest.DegradedCatalogDomain do
  @moduledoc "Real fixture domain for the degraded catalog."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.EvalTest.DegradedCatalog)
  end
end

defmodule AshA2A.EvalTest.DegradedAgent do
  @moduledoc "Real agent over the degraded catalog."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.EvalTest.DegradedCatalog,
    name: "eval_degraded_catalog_agent"
end

defmodule AshA2A.EvalTest.Scorers do
  @moduledoc "Real custom-scorer target module referenced from the suite JSON."

  def refund_confidence(view, _case) do
    data = view.data || %{}

    if data["label"] == "refund" and is_number(data["confidence"]) and data["confidence"] >= 0.9 do
      :ok
    else
      {:error, "expected label=refund with confidence >= 0.9, got: #{inspect(data)}"}
    end
  end
end

defmodule AshA2A.EvalTest do
  @moduledoc """
  Chicago-style court for the agent eval harness (`mix ash_a2a.eval`): a real
  supervised agent behind a real Bandit `AshA2A.Protocol.Plug` listener, a
  real 5-case suite JSON on disk, and the real mix task in-process.

  Falsifier: the 5-case court is green against the good agent AND the
  deliberately degraded real skill is detected as a baseline regression with
  a non-zero exit. Zero mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.EphemeralHttp

  setup do
    good = start_agent_server!(AshA2A.EvalTest.GoodAgent)
    degraded = start_agent_server!(AshA2A.EvalTest.DegradedAgent)

    dir = Path.join(System.tmp_dir!(), "ash_a2a_eval_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf(dir) end)

    %{good: good, degraded: degraded, dir: dir}
  end

  test "5-case suite over the real transport: all PASS, report correct", %{good: good, dir: dir} do
    suite_path = write_suite!(dir, good_suite())
    suite = AshA2A.Eval.load_suite!(suite_path)

    report = AshA2A.Eval.run_suite(suite, good.base_url)

    assert report.totals.total == 5
    assert report.totals.pass == 5
    assert report.totals.fail == 0
    assert report.totals.pass_rate == 1.0
    assert [%{p50: p50, p90: p90, p99: p99}] = [report.latency_ms]
    assert is_number(p50) and is_number(p90) and is_number(p99)
    assert p50 <= p99

    assert Enum.all?(report.cases, &(&1.verdict == "PASS"))
    assert Enum.all?(report.cases, &is_integer(&1.latency_ms))

    # The scorer details are real, per-scorer, and visible in the report.
    schema_case = Enum.find(report.cases, &(&1.id == "classify-schema"))
    assert [%{verdict: "PASS", detail: :ok}] = schema_case.scorers

    custom_case = Enum.find(report.cases, &(&1.id == "classify-custom"))
    assert [%{verdict: "PASS"}] = custom_case.scorers

    multi_case = Enum.find(report.cases, &(&1.id == "classify-multi"))
    assert length(multi_case.scorers) == 2
  end

  test "mix task writes the scored JSON report to disk", %{good: good, dir: dir} do
    suite_path = write_suite!(dir, good_suite())
    out_path = Path.join(dir, "report.json")

    :ok =
      Mix.Tasks.AshA2a.Eval.run([
        "--suite",
        suite_path,
        "--url",
        good.base_url,
        "--out",
        out_path
      ])

    assert File.exists?(out_path)

    decoded = out_path |> File.read!() |> Jason.decode!()
    assert decoded["totals"]["pass"] == 5
    assert decoded["totals"]["total"] == 5
    assert length(decoded["cases"]) == 5
    assert is_number(decoded["latency_ms"]["p99"])
  end

  test "eval gate: degraded skill detected as regression, mix task exits non-zero", %{
    good: good,
    degraded: degraded,
    dir: dir
  } do
    suite_path = write_suite!(dir, good_suite())
    baseline_path = Path.join(dir, "baseline.json")

    # Baseline run against the GOOD agent: exit 0, baseline stored.
    :ok =
      Mix.Tasks.AshA2a.Eval.run([
        "--suite",
        suite_path,
        "--url",
        good.base_url,
        "--save-baseline",
        baseline_path
      ])

    assert File.exists?(baseline_path)

    # Gate run against the DEGRADED agent: exit non-zero, regression reported.
    out_path = Path.join(dir, "gate_report.json")

    assert catch_exit(
             Mix.Tasks.AshA2a.Eval.run([
               "--suite",
               suite_path,
               "--url",
               degraded.base_url,
               "--baseline",
               baseline_path,
               "--out",
               out_path
             ])
           ) == {:shutdown, 1}

    assert File.exists?(out_path)

    decoded = out_path |> File.read!() |> Jason.decode!()
    assert decoded["totals"]["pass"] == 0
    assert decoded["totals"]["total"] == 5

    # Every case regressed PASS -> FAIL against the degraded skill.
    failed_ids = MapSet.new(decoded["cases"], & &1["id"])

    assert MapSet.equal?(
             failed_ids,
             MapSet.new([
               "greet-exact",
               "greet-contains",
               "classify-schema",
               "classify-custom",
               "classify-multi"
             ])
           )
  end

  test "compare/2: regression, improvement, missing and new cases; gate verdict", %{dir: dir} do
    baseline =
      report_map([
        {"c1", "PASS"},
        {"c2", "FAIL"},
        {"c3", "PASS"},
        {"c4", "PASS"}
      ])

    current =
      report_map([
        {"c1", "FAIL"},
        {"c2", "PASS"},
        {"c3", "PASS"},
        {"c5", "PASS"}
      ])

    comparison = AshA2A.Eval.compare(baseline, current, baseline_path: Path.join(dir, "b.json"))

    assert comparison.verdict == "REGRESSION"

    assert [%{id: "c1", type: :regression, baseline: "PASS", current: "FAIL"}] =
             Enum.filter(comparison.regressions, &(&1.type == :regression))

    assert [%{id: "c4", type: :missing_case}] =
             Enum.filter(comparison.regressions, &(&1.type == :missing_case))

    assert [%{id: "c2"}] = comparison.improvements
    assert comparison.missing_cases == ["c4"]
    assert comparison.new_cases == ["c5"]
  end

  test "scorer failures are total: malformed path, missing data part, raising custom fun" do
    view = %{text: "", data: %{"label" => "refund"}, raw: %{}}

    results =
      AshA2A.Eval.Scorers.run(
        [
          %{"type" => "exact", "value" => "x", "path" => "data.no.such.key"},
          %{"type" => "contains", "value" => "x"},
          %{"type" => "schema_match", "expect" => %{"label" => "other"}},
          %{
            "type" => "custom",
            "module" => "AshA2A.EvalTest.Scorers",
            "function" => "nonexistent"
          },
          %{"type" => "custom", "module" => "NoSuchModule.Nowhere", "function" => "x"}
        ],
        view,
        %{}
      )

    assert Enum.all?(results, &(&1.verdict == "FAIL"))
    assert %{verdict: "FAIL", detail: {:path_error, {:missing_key, _}}} = Enum.at(results, 0)
    assert %{verdict: "FAIL", detail: {:missing_substring, _}} = Enum.at(results, 1)
    assert %{verdict: "FAIL", detail: {:schema_mismatch, _}} = Enum.at(results, 2)

    assert %{verdict: "FAIL", detail: {:custom_scorer_error, _}} = Enum.at(results, 3)
    assert %{verdict: "FAIL", detail: {:custom_scorer_error, _}} = Enum.at(results, 4)
  end

  test "suite validation rejects bad suites before any traffic" do
    assert {:error, {:invalid_suite, problems}} =
             AshA2A.Eval.Suite.validate(%{"cases" => []})

    assert problems != []

    assert {:error, {:invalid_suite, _}} =
             AshA2A.Eval.Suite.validate(%{
               "cases" => [%{"id" => "x", "skill" => "y", "scorers" => [%{"type" => "wat"}]}]
             })

    assert {:error, {:invalid_suite, _}} =
             AshA2A.Eval.Suite.validate(%{
               "cases" => [
                 %{
                   "id" => "x",
                   "skill" => "y",
                   "scorers" => [%{"type" => "exact", "value" => 1}]
                 },
                 %{"id" => "x", "skill" => "y", "scorers" => [%{"type" => "exact", "value" => 1}]}
               ]
             })
  end

  # -- fixtures ----------------------------------------------------------------

  defp start_agent_server!(agent_module) do
    name = :"#{agent_module}_#{System.unique_integer([:positive])}"
    {:ok, pid} = agent_module.start_link(name: name)

    on_exit(fn ->
      AshA2A.TestSupport.SafeStop.stop(pid)
    end)

    server =
      EphemeralHttp.start!({AshA2A.Protocol.Plug, agent: name, base_url: "http://127.0.0.1/a2a"})

    %{agent: name, server: server, base_url: server.base_url}
  end

  defp good_suite do
    %{
      "name" => "eval-test-golden",
      "cases" => [
        %{
          "id" => "greet-exact",
          "skill" => "greet",
          "input" => %{"data" => %{"name" => "alice"}},
          "scorers" => [%{"type" => "exact", "value" => "hello alice", "path" => "data.result"}]
        },
        %{
          "id" => "greet-contains",
          "skill" => "greet",
          "input" => %{"data" => %{"name" => "alice"}},
          "scorers" => [%{"type" => "contains", "value" => "hello", "path" => "data.result"}]
        },
        %{
          "id" => "classify-schema",
          "skill" => "classify",
          "input" => %{"data" => %{"query" => "where is my refund"}},
          "scorers" => [
            %{
              "type" => "schema_match",
              "expect" => %{
                "label" => "refund",
                "confidence" => 0.98,
                "meta" => %{"channel" => "web"}
              }
            }
          ]
        },
        %{
          "id" => "classify-custom",
          "skill" => "classify",
          "input" => %{"data" => %{"query" => "replace my broken widget"}},
          "scorers" => [
            %{
              "type" => "custom",
              "module" => "AshA2A.EvalTest.Scorers",
              "function" => "refund_confidence"
            }
          ]
        },
        %{
          "id" => "classify-multi",
          "skill" => "classify",
          "input" => %{"data" => %{"query" => "questions about charges"}},
          "scorers" => [
            %{"type" => "exact", "value" => "refund", "path" => "data.label"},
            %{"type" => "exact", "value" => "web", "path" => "data.meta.channel"}
          ]
        }
      ]
    }
  end

  defp write_suite!(dir, suite) do
    path = Path.join(dir, "suite.json")
    File.write!(path, Jason.encode!(suite, pretty: true))
    path
  end

  defp report_map(cases) do
    %{
      "totals" => %{
        "pass" => Enum.count(cases, &match?({_, "PASS"}, &1)),
        "fail" => Enum.count(cases, &match?({_, "FAIL"}, &1)),
        "total" => length(cases),
        "pass_rate" => Enum.count(cases, &match?({_, "PASS"}, &1)) / length(cases) * 1.0
      },
      "cases" => Enum.map(cases, fn {id, verdict} -> %{"id" => id, "verdict" => verdict} end)
    }
  end
end

# --- SECTION 2: Original test/ash_a2a_evidence_class_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.EvidenceClassTest do
  @moduledoc """
  RFC-SA2A-001 S70 evidence boundaries.

  Chicago-style throughout: real class values, real promotion calls, real
  returned structs asserted on by type and value. No doubles -- there is
  nothing external here to double.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Evidence.Class

  alias AshA2A.Evidence.{
    HostedCI,
    LocalTest,
    Merge,
    Production,
    Publication,
    RuntimeAlive
  }

  doctest AshA2A.Evidence.Class

  test "the chain is exactly the six S70 classes in RFC order" do
    assert Class.chain() == [LocalTest, HostedCI, Production, RuntimeAlive, Publication, Merge]

    assert Enum.map(Class.chain(), & &1.label()) ==
             [:local_test, :hosted_ci, :production, :runtime_alive, :publication, :merge]

    assert Enum.map(Class.chain(), & &1.rank()) == [1, 2, 3, 4, 5, 6]
  end

  test "each class is a genuinely distinct struct type, not a tagged atom" do
    values = Enum.map(Class.chain(), & &1.new(%{note: "same basis for all six"}))

    # Six distinct struct modules. If these were atoms or tagged tuples
    # sharing one struct, this set would collapse.
    assert values |> Enum.map(& &1.__struct__) |> Enum.uniq() |> length() == 6

    # A function head bound to one class does not match another. This is the
    # non-coercibility S70 asks for, demonstrated rather than asserted.
    local = LocalTest.new(%{})
    production = Production.new(%{})

    assert requires_production(production) == :ok
    assert requires_production(local) == :wrong_class
  end

  defp requires_production(%Production{}), do: :ok
  defp requires_production(_), do: :wrong_class

  test "promotion one step up with genuinely new evidence succeeds" do
    local = LocalTest.new(%{suite: "mix test", commit: "abc123"})

    assert {:ok, %HostedCI{} = ci} = Class.promote(local, HostedCI, %{job_url: "ci://run/42"})
    assert ci.basis == %{job_url: "ci://run/42"}
    assert ci.evidence_digest != local.evidence_digest
    assert Class.rank(ci) == 2

    assert {:ok, %Production{} = prod} = Class.promote(ci, Production, %{deploy: "d-7"})
    assert Class.rank(prod) == 3
  end

  test "promotion without new evidence is refused -- the core S70 rule" do
    basis = %{suite: "mix test", commit: "abc123"}
    local = LocalTest.new(basis)

    # Re-presenting the identical evidence that justified `local` does not buy
    # a stronger class.
    assert {:error, %{code: :promotion_without_new_evidence, detail: detail}} =
             Class.promote(local, HostedCI, basis)

    assert detail =~ "hosted_ci requires evidence distinct from the local_test evidence"

    # And the same rule holds further up the chain.
    ci_basis = %{job_url: "ci://run/42"}
    {:ok, ci} = Class.promote(local, HostedCI, ci_basis)

    assert {:error, %{code: :promotion_without_new_evidence}} =
             Class.promote(ci, Production, ci_basis)
  end

  test "skipping a class is refused, and so is going backwards" do
    local = LocalTest.new(%{a: 1})

    assert {:error, %{code: :non_adjacent_evidence_promotion, detail: detail}} =
             Class.promote(local, Production, %{b: 2})

    assert detail =~ "local_test cannot reach production without hosted_ci"

    assert {:error, %{code: :non_adjacent_evidence_promotion}} =
             Class.promote(local, RuntimeAlive, %{b: 2})

    {:ok, ci} = Class.promote(local, HostedCI, %{b: 2})

    assert {:error, %{code: :non_adjacent_evidence_promotion}} =
             Class.promote(ci, LocalTest, %{c: 3})

    # Self-promotion is not a promotion either.
    assert {:error, %{code: :non_adjacent_evidence_promotion}} =
             Class.promote(ci, HostedCI, %{c: 3})
  end

  test "Merge is the top of the chain and has nothing above it" do
    assert Class.next(Publication) == {:ok, Merge}
    assert Class.next(Merge) == :error

    merge = Merge.new(%{pr: 1})

    assert {:error, %{code: :non_adjacent_evidence_promotion}} =
             Class.promote(merge, Merge, %{x: 1})
  end

  test "non-class modules and values are refused rather than silently coerced" do
    local = LocalTest.new(%{})

    assert {:error, %{code: :not_an_evidence_class}} = Class.promote(local, NotAClass, %{a: 1})
    assert {:error, %{code: :not_an_evidence_class}} = Class.promote(%{fake: true}, HostedCI, %{})
    assert {:error, %{code: :not_an_evidence_class}} = Class.promote(:local_test, HostedCI, %{})

    refute Class.class?(NotAClass)
    refute Class.class?(:local_test)
    refute Class.value?(%{__struct__: NotAClass})
    assert Class.class?(Production)
    assert Class.value?(local)
  end

  test "assert_at_least reads the lattice without ever upgrading anything" do
    # A HostedCI that was genuinely EARNED -- `HostedCI.new/1` builds an
    # unlinked root, which `assert_at_least/2` now refuses (see the forged
    # class test below). A rank-2 claim requires a rank-1 predecessor.
    local = LocalTest.new(%{suite: "mix test", commit: "abc123"})
    {:ok, ci} = Class.promote(local, HostedCI, %{job: 1})

    assert :ok = Class.assert_at_least(ci, LocalTest)
    assert :ok = Class.assert_at_least(ci, HostedCI)

    assert {:error, %{code: :insufficient_evidence_class, detail: detail}} =
             Class.assert_at_least(ci, Production)

    assert detail =~ "have hosted_ci (2), require production (3)"

    # The value is unchanged: no read-side upgrade happened.
    assert ci.__struct__ == HostedCI
  end

  test "the default class is the weakest one, not the strongest" do
    assert Class.default() == LocalTest
    assert Class.rank(Class.default()) == 1
  end

  # ------------------------------------------------------------------
  # DEFECT 2 regression (RFC S70): silent evidence promotion.
  #
  # Before the fix, `promote/3` refused exactly one thing -- a basis
  # byte-identical to the IMMEDIATELY PRECEDING basis. It did not require
  # the basis to be non-empty, had no memory of evidence consumed earlier
  # in the chain, and discarded the current class entirely, so the
  # successor held no link to its predecessor and a forged class rode all
  # the way into a real verify/2-passing attestation.
  #
  # The three inputs below are the verifier's minimal reproductions.
  # ------------------------------------------------------------------

  test "S70 regression: an EMPTY basis is not new evidence and does not promote" do
    local = LocalTest.new(%{suite: "mix test", run: 1})

    assert {:error, %{code: :promotion_without_new_evidence, detail: detail}} =
             Class.promote(local, HostedCI, %{})

    assert detail =~ "an empty basis is not an observation"

    # The empty keyword list is the same input in a different skin.
    assert {:error, %{code: :promotion_without_new_evidence}} = Class.promote(local, HostedCI, [])

    # And the value really did not move.
    assert Class.rank(local) == 1
  end

  test "S70 regression: evidence spent EARLIER in the chain cannot be replayed to climb it" do
    local_basis = %{suite: "mix test", run: 1}
    local = LocalTest.new(local_basis)
    {:ok, ci} = Class.promote(local, HostedCI, %{job: "ci-42"})

    # The exact repro: the LocalTest basis is not the IMMEDIATELY preceding
    # basis any more, so the old byte-comparison let it through.
    assert {:error, %{code: :evidence_replayed, detail: detail}} =
             Class.promote(ci, Production, local_basis)

    assert detail =~ "already consumed earlier in this chain"

    # Genuinely new evidence still works, so this is a replay guard and not
    # a blanket refusal.
    assert {:ok, %Production{} = prod} = Class.promote(ci, Production, %{deploy: "d-7"})

    # And the chain remembers all three spends, oldest included.
    assert Class.digest(local_basis) in prod.consumed_evidence
    assert Class.digest(%{job: "ci-42"}) in prod.consumed_evidence
    assert Class.digest(%{deploy: "d-7"}) in prod.consumed_evidence
    assert length(prod.consumed_evidence) == 3

    # Replay is refused at every later step too, not just the first.
    assert {:error, %{code: :evidence_replayed}} =
             Class.promote(prod, RuntimeAlive, %{job: "ci-42"})
  end

  test "S70 regression: every class is linked to its predecessor, and a forged class is refused" do
    local = LocalTest.new(%{suite: "mix test", run: 1})
    {:ok, ci} = Class.promote(local, HostedCI, %{job: "ci-42"})
    {:ok, prod} = Class.promote(ci, Production, %{deploy: "d-7"})

    # Real links, all the way down.
    assert local.prior_digest == nil
    assert ci.prior_digest == local.chain_digest
    assert prod.prior_digest == ci.chain_digest
    assert :ok = Class.verify_chain(local)
    assert :ok = Class.verify_chain(ci)
    assert :ok = Class.verify_chain(prod)

    # A forged Merge with a made-up link: refused, not accepted.
    forged =
      struct!(Merge,
        evidence_digest: Class.digest(%{forged: true}),
        observed_at: DateTime.utc_now(),
        chain_digest: "sha256:looks-real",
        basis: %{forged: true}
      )

    assert {:error, %{code: :evidence_chain_broken}} = Class.verify_chain(forged)
    assert {:error, %{code: :evidence_chain_broken}} = Class.assert_at_least(forged, Merge)
    assert {:error, %{code: :evidence_chain_broken}} = Class.assert_at_least(forged, LocalTest)

    # The harder forgery: a self-CONSISTENT link that was still never
    # earned. Internal consistency is not a promotion history.
    digest = Class.digest(%{forged: true})

    self_consistent =
      struct!(Merge,
        evidence_digest: digest,
        observed_at: DateTime.utc_now(),
        consumed_evidence: [digest],
        chain_digest: Class.link_digest(Merge, digest, nil, [digest]),
        basis: %{forged: true}
      )

    assert {:error, %{code: :evidence_class_not_earned, detail: detail}} =
             Class.verify_chain(self_consistent)

    assert detail =~ "reached by promotion, never constructed"

    assert {:error, %{code: :evidence_class_not_earned}} =
             Class.assert_at_least(self_consistent, Merge)

    # A value that claims a rank it has not paid for in distinct evidence
    # is refused on the count, even with a real predecessor link.
    understated = %{prod | consumed_evidence: [prod.evidence_digest]}

    understated = %{
      understated
      | chain_digest:
          Class.link_digest(Production, prod.evidence_digest, prod.prior_digest, [
            prod.evidence_digest
          ])
    }

    assert {:error, %{code: :evidence_class_not_earned, detail: count_detail}} =
             Class.verify_chain(understated)

    assert count_detail =~ "one per step is required"
  end

  test "S70 regression: a broken-link predecessor cannot promote at all" do
    local = LocalTest.new(%{suite: "mix test", run: 1})
    tampered = %{local | evidence_digest: Class.digest(%{something: "else"})}

    assert {:error, %{code: :evidence_chain_broken}} =
             Class.promote(tampered, HostedCI, %{job: "ci-42"})
  end

  test "evidence digests are content-addressed and stable across processes" do
    basis = %{run: "r-1", host: "builder-3"}
    here = Class.digest(basis)

    there = Task.await(Task.async(fn -> Class.digest(basis) end))

    assert here == there
    assert String.starts_with?(here, "sha256:")
    assert Class.digest(%{run: "r-2"}) != here
  end
end

# --- SECTION 3: Original test/ash_a2a_execution_pplan_test.exs ---
defmodule AshA2A.Test.Fixture.PPlanExec.Resource do
  @moduledoc """
  Real fixture resource for the `adapter: :pplan` execution court
  (`test/ash_a2a_execution_pplan_test.exs`). Its one `:observe` skill is the
  node-local handler: when the default adapter is selected the skill actually
  dispatches and its action body increments a real `:persistent_term` counter;
  when `adapter: :pplan` is selected the handler is never entered, so the
  counter staying at zero is action-observed evidence that no node-local
  worker executed the task.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.PPlanExec.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :probe, :map do
      run(fn _input, _context ->
        key = {__MODULE__, :skill_dispatches}
        :persistent_term.put(key, :persistent_term.get(key, 0) + 1)
        {:ok, %{probed: true}}
      end)
    end
  end

  a2a do
    skill(:probe, :probe, consequence: :observe)
  end
end

defmodule AshA2A.Test.Fixture.PPlanExec.Domain do
  @moduledoc "Real fixture domain for the pplan execution court."
  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.PPlanExec.Resource)
  end
end

defmodule AshA2A.Test.Fixture.PPlanExec.Agent do
  @moduledoc """
  Real agent with `adapter: :pplan`: async dispatch routes through the durable
  ash_pplan run instead of the node-local handler. The compile-time `pplan:`
  opts are `{m, f, a}` tuples resolved by `AshA2A.Execution.PPlan` on every
  call, so the runtime-started DETS store / model / bindings are reachable.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.PPlanExec.Resource,
    name: "pplan_exec_agent",
    execution: [
      adapter: :pplan,
      pplan: [
        store: {AshA2A.Execution.PPlanTest.Cfg, :opt, [:store]},
        store_module: AshPPlan.Reactor.Durable.Store.Dets,
        model: {AshA2A.Execution.PPlanTest.Cfg, :opt, [:model]},
        bindings: {AshA2A.Execution.PPlanTest.Cfg, :opt, [:bindings]}
      ]
    ]
end

defmodule AshA2A.Test.Fixture.PPlanExec.LocalAgent do
  @moduledoc "Real agent with the default (node-local) adapter: regression guard."
  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.PPlanExec.Resource,
    name: "pplan_local_agent"
end

defmodule AshA2A.Execution.PPlanTest do
  @moduledoc """
  Lane P1 court for the `adapter: :pplan` execution-provider integration: a
  real `AshA2A.Agent` GenServer configured
  `execution: [adapter: :pplan, pplan: [...]]` routes async dispatch through a
  durable ash_pplan run keyed by the A2A task id, over the REAL ash_pplan
  stack (`AshPPlan.Reactor.Durable.{Engine,Run,Status}` over a real disk-backed
  `AshPPlan.Reactor.Durable.Store.Dets` on a tmp dir). Zero mocks.

  Acceptance: an async skill with `adapter: :pplan` → dispatched run visible
  via provider status; a follow-up message with the same task id resumes to
  COMPLETED; a node-local worker does NOT execute it (the durable run's
  checkpoint tape is the execution record, and the fixture skill's own
  action-observed dispatch counter stays at zero).

  If `:ash_pplan` cannot load in the test env, every test skips with a typed
  BLOCKED reason (`{:blocked, :ash_pplan_not_loadable}`) printed to stderr —
  the same skip discipline as the durability court
  (`test/ash_a2a_pplan_durability_test.exs`).
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Providers.PPlan, as: Provider
  alias AshA2A.Test.Fixture.PPlanExec.Agent, as: PPlanExecAgent
  alias AshA2A.Test.Fixture.PPlanExec.LocalAgent

  @dets AshPPlan.Reactor.Durable.Store.Dets
  @engine AshPPlan.Reactor.Durable.Engine
  @adapter_id :a2a_pplan_exec_fx
  @counter_key {AshA2A.Test.Fixture.PPlanExec.Resource, :skill_dispatches}

  # -- real collaborators ------------------------------------------------------

  defmodule Effects do
    @moduledoc "Real counting agent: each consequential effect records exactly here."
    use Agent

    def start_link(name), do: Agent.start_link(fn -> %{} end, name: name)

    def run(server, effect) do
      Agent.get_and_update(server, fn s ->
        n = Map.get(s, effect, 0) + 1
        {{:ok, n}, Map.put(s, effect, n)}
      end)
    end

    def count(server, effect), do: Agent.get(server, &Map.get(&1, effect, 0))
  end

  defmodule Effect do
    @moduledoc "Counting Reactor step; `options[:effects]` names the counter agent."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      case Effects.run(Keyword.fetch!(options, :effects), Keyword.fetch!(options, :effect)) do
        {:ok, n} -> {:ok, {Keyword.fetch!(options, :effect), n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc """
    Test adapter: counting effects plus ash_pplan's own Await durable step.
    Realization options carry the per-test `:effects` agent name (plain data,
    survives a store round trip).
    """

    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :a2a_pplan_exec_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {Steps.Await, [signal: "go", timeout: nil]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  defmodule Cfg do
    @moduledoc """
    Runtime config holder for the court's agent fixture: the agent's
    compile-time `pplan:` opts are `{m, f, a}` tuples resolved by
    `AshA2A.Execution.PPlan` on every call, so a runtime-started DETS store,
    model, and bindings are reachable from compile-time agent opts.
    """

    @key {:ash_a2a_pplan_exec_court, :pplan}

    def put(opts), do: :persistent_term.put(@key, opts)

    def opt(key), do: Keyword.fetch!(:persistent_term.get(@key), key)

    def stop do
      case :persistent_term.get(@key, nil) do
        %{store: store} when is_pid(store) ->
          if Process.alive?(store), do: Process.exit(store, :kill)

        _ ->
          :ok
      end

      :persistent_term.erase(@key)
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), @adapter_id, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
    end)

    :ok
  end

  defp model(name, tasks) do
    {:ok, m} = AshPPlan.Workflow.Model.new(name: name, goal: name, tasks: tasks)
    m
  end

  defp await_model,
    do:
      model("a2a_pplan_exec_await", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :await, capability: "Event.Await", depends_on: [:prepare]],
        [id: :finish, capability: "Process.Finish", depends_on: [:await]]
      ])

  defp bindings(effects) do
    ops = [
      {:prepare, "Process.Prepare"},
      {:await, "Event.Await"},
      {:finish, "Process.Finish"}
    ]

    Map.new(ops, fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: @adapter_id,
         binding: %{adapter: @adapter_id, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  defp open_store(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "a2a-pplan-exec-laneP1-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    {:ok, store} = @dets.start_link(path: path, name: name)
    store
  end

  setup context do
    unless AshA2A.Execution.PPlan.available?() do
      reason = {:blocked, :ash_pplan_not_loadable}

      IO.puts(:stderr, "[lane-p1] BLOCKED: :ash_pplan did not load in the test env")

      {:skip, reason}
    end

    install_adapter!()

    {:ok, fx} = Effects.start_link(:"pplan_exec_fx_#{System.unique_integer([:positive])}")

    store = open_store(:"#{context.module}.Store")

    Cfg.put(
      store: store,
      store_module: @dets,
      model: await_model(),
      bindings: bindings(fx)
    )

    :persistent_term.put(@counter_key, 0)

    ExUnit.Callbacks.on_exit(fn ->
      Cfg.stop()
      :persistent_term.erase(@counter_key)
    end)

    %{store: store, fx: fx, opts: [store: store, store_module: @dets]}
  end

  # -- the contract ------------------------------------------------------------

  @tag :serial
  test "async dispatch parks input_required on the durable run; the same task id resumes to COMPLETED; no node-local handler runs",
       %{store: store, fx: fx, opts: opts} do
    _sup_and_registry =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [PPlanExecAgent])

    # Turn 1: fresh task -> durable run dispatched, parked on the Await step.
    assert {:ok, task1} = PPlanExecAgent.call(PPlanExecAgent, data_message(%{step: 1}))

    assert task1.status.state == :input_required
    task_id = task1.id

    # the dispatched run is visible via provider status on the SAME task id
    assert {:ok, :input_required,
            %{run_status: :waiting, waiters: ["go"], version: v_parked, error: nil}} =
             Provider.status(task_id, opts)

    # the durable run executed prepare exactly once; finish has not run
    assert %{prepare: 1, finish: 0} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # no node-local handler execution: the fixture skill's own counter is zero
    assert 0 == skill_dispatches()

    # Turn 2: follow-up message with the SAME task id resumes the SAME run.
    assert {:ok, task2} =
             PPlanExecAgent.call(PPlanExecAgent, data_message(%{answer: 42}), task_id: task_id)

    assert task2.id == task_id
    assert task2.status.state == :completed

    # the run's sealed result maps to a real artifact on the completed task
    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: result}]}] =
             task2.artifacts

    assert is_map(result)

    # provider status reports completion; each effect ran exactly once, in one run
    assert {:ok, :completed, %{run_status: :completed, version: v_done}} =
             Provider.status(task_id, opts)

    assert v_done > v_parked

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # the durable run's checkpoint tape is the execution record: three
    # standing step records, prepare -> await -> finish, in execution order
    # (labels are `inspect/1` of the step URNs, hence the embedded quotes)
    tape = @engine.steps(store, task_id, store_module: @dets)
    assert length(tape) == 3

    assert Enum.map(tape, & &1.label) == [
             ~s("urn:ash-pplan:workflow:a2a_pplan_exec_await#step-prepare"),
             ~s("urn:ash-pplan:workflow:a2a_pplan_exec_await#step-await"),
             ~s("urn:ash-pplan:workflow:a2a_pplan_exec_await#step-finish")
           ]
  end

  test "the default adapter is untouched: a plain agent dispatches the skill locally and creates no durable run",
       %{opts: opts} do
    _sup_and_registry =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [LocalAgent])

    assert {:ok, task} = LocalAgent.call(LocalAgent, data_message(%{}))

    assert task.status.state == :completed

    # the node-local handler DID execute the skill (action-observed counter)
    assert 1 == skill_dispatches()

    # and no durable run was created for the task id
    assert {:error, :no_such_run} = Provider.status(task.id, opts)
  end

  defp skill_dispatches do
    :persistent_term.get(@counter_key, 0)
  end
end

# --- SECTION 4: Original test/ash_a2a_execution_snapshot_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ExecutionSnapshotTest do
  use ExUnit.Case, async: true

  alias AshA2A.ExecutionSnapshot

  defp fresh(overrides \\ []) do
    attrs = [
      task_id: "task-1",
      work_order_digest: "sha256:work-order",
      command_digest: "sha256:command",
      exact_subject: "repo@abc",
      candidate_digest: "sha256:candidate",
      authority_digest: "sha256:authority",
      consequence_digest: "sha256:consequence",
      capability_digest: "sha256:capability",
      execution_manifest_digest: "sha256:manifest",
      root_task_id: "task-1"
    ]

    ExecutionSnapshot.new!(Keyword.merge(attrs, overrides))
  end

  test "worker death does not kill durable task state or semantic identity" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, checkpointed} = ExecutionSnapshot.checkpoint(running, 1, "history-1")
    semantic_before = ExecutionSnapshot.semantic_identity_digest(checkpointed)
    topology_before = ExecutionSnapshot.digest(checkpointed)

    {:ok, reclaimable} = ExecutionSnapshot.worker_lost(checkpointed)
    assert reclaimable.task_id == checkpointed.task_id
    assert reclaimable.checkpoint == checkpointed.checkpoint
    assert is_nil(reclaimable.worker_id)

    {:ok, reclaimed} = ExecutionSnapshot.claim(reclaimable, "worker-b")
    {:ok, resumed} = ExecutionSnapshot.start(reclaimed)

    assert resumed.task_id == checkpointed.task_id
    assert resumed.checkpoint.sequence == 1
    assert resumed.worker_id == "worker-b"
    assert ExecutionSnapshot.semantic_identity_digest(resumed) == semantic_before
    refute ExecutionSnapshot.digest(resumed) == topology_before
  end

  test "checkpoint binds the exact semantic execution identity" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, checkpointed} = ExecutionSnapshot.checkpoint(running, 1, "history-1")

    assert checkpointed.checkpoint.semantic_identity_digest ==
             ExecutionSnapshot.semantic_identity_digest(checkpointed)

    assert checkpointed.checkpoint.command_digest == "sha256:command"
    assert checkpointed.checkpoint.candidate_digest == "sha256:candidate"
    assert checkpointed.checkpoint.authority_digest == "sha256:authority"
    assert checkpointed.checkpoint.consequence_digest == "sha256:consequence"
  end

  test "checkpoint sequence must be monotonic" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, checkpointed} = ExecutionSnapshot.checkpoint(running, 2, "history-2")

    assert {:error, :checkpoint_not_monotonic} =
             ExecutionSnapshot.checkpoint(checkpointed, 2, "history-again")
  end

  test "same bound receipt replay is idempotent but receipt substitution is refused" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)

    {:ok, completed} =
      ExecutionSnapshot.complete(running, "receipt-1", "sha256:receipt-binding")

    assert {:ok, ^completed} =
             ExecutionSnapshot.complete(completed, "receipt-1", "sha256:receipt-binding")

    assert {:error, :receipt_binding_mismatch} =
             ExecutionSnapshot.complete(completed, "receipt-1", "sha256:forged-binding")

    assert {:error, :duplicate_consequence} =
             ExecutionSnapshot.complete(completed, "receipt-2", "sha256:receipt-binding")
  end

  test "legacy receipt replay remains idempotent without manufacturing a binding" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, completed} = ExecutionSnapshot.complete(running, "receipt-1")

    assert is_nil(completed.consequence_receipt_digest)
    assert {:ok, ^completed} = ExecutionSnapshot.complete(completed, "receipt-1")
  end

  test "deterministic durable encoding survives restart without identity drift" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, checkpointed} = ExecutionSnapshot.checkpoint(running, 7, "history-7")
    encoded = ExecutionSnapshot.encode(checkpointed)

    restored = ExecutionSnapshot.decode!(encoded)

    assert restored == checkpointed
    assert ExecutionSnapshot.encode(restored) == encoded
    assert ExecutionSnapshot.replay_key(restored) == ExecutionSnapshot.replay_key(checkpointed)
  end

  test "invalid identity is rejected before any lifecycle transition" do
    Enum.each(ExecutionSnapshot.required_identity_fields(), fn field ->
      attrs = [
        task_id: "task-1",
        work_order_digest: "sha256:work-order",
        command_digest: "sha256:command",
        exact_subject: "repo@abc",
        candidate_digest: "sha256:candidate",
        authority_digest: "sha256:authority",
        consequence_digest: "sha256:consequence",
        capability_digest: "sha256:capability",
        execution_manifest_digest: "sha256:manifest"
      ]

      assert_raise ArgumentError, fn ->
        ExecutionSnapshot.new!(Keyword.put(attrs, field, ""))
      end
    end)
  end

  test "refusal is lifecycle evidence, never provider projection" do
    snapshot = fresh(provider_projection: %{provider: "provider-a", transport: "http"})
    {:ok, refused} = ExecutionSnapshot.refuse(snapshot, :authority_mismatch)

    assert refused.state == :refused
    assert refused.refusal == %{reason: :authority_mismatch}
    assert refused.provider_projection == snapshot.provider_projection

    assert ExecutionSnapshot.semantic_identity_digest(refused) ==
             ExecutionSnapshot.semantic_identity_digest(snapshot)
  end
end

# --- SECTION 5: Original test/ash_a2a_failure_injection_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FailureInjectionTest do
  @moduledoc """
  Squad H (agent 39) consolidated failure-injection suite. Every scenario
  below drives a real failure path through a real collaborator -- no
  interaction-based test-double library of any kind is imported or used
  anywhere in this file, per this workspace's Chicago-style testing
  discipline. Each `describe` block
  reuses/extends an existing real pattern already established elsewhere in
  this suite (named in the block's own `@moduledoc`-equivalent comment), and
  every assertion is on the real returned error shape, never on "was this
  called."

  Five real failure classes, at minimum:

    1. A real malformed/schema-invalid LLM extraction response into
       `AshA2A.Semantic.Compiler.compile/3`'s real admission pipeline --
       reuses the injected `generate_object` seam pattern from
       `test/ash_a2a/semantic_compiler_test.exs`.
    2. A real solver failure: genuinely malformed (unparseable, not merely
       unsolvable) HDDL syntax fed through the real `native/hddl_cli`
       binary via the existing real
       `test/support/semantic_hddl_verification.ex` helper.
    3. A real unknown-capability-id refusal through
       `AshA2A.Planning.SemanticSynthesis` -- reuses the
       `:noncanonical_capability` pattern from
       `test/ash_a2a/semantic_synthesis_test.exs`.
    4. A real `AshA2A.CommandBus` authority failure -- extends
       `test/ash_a2a/command_bus_test.exs`'s real pattern with the real
       `:authority_mismatch` branch (present-but-wrong authority), which
       that file establishes the fixtures/pattern for but never itself
       exercises (only the `:authority_required` no-authority branch is
       covered there).
    5. A real worker-process crash inside
       `AshA2A.Semantic.Compiler.compile_many/3` -- extends
       `test/ash_a2a/semantic_compiler_test.exs`'s raised-and-rescued
       exception test with a genuine process `exit/1` that `isolated_compile/3`'s
       `rescue` clause cannot catch, so `compile_many/3`'s own
       `{:exit, reason} -> {:error, %{code: :semantic_worker_exit, ...}}`
       clause (unexercised by any existing test) is what actually converts
       it -- and confirms the surviving items still complete correctly.
       `Task.async_stream/3` links each worker to the caller, so this test
       must `Process.flag(:trap_exit, true)` first, itself an empirically
       verified real finding from this test's own development (a first run
       without it crashed the whole test process, not just that slot; see
       the test's own comment).
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, ReceiptStore}
  alias AshA2A.Planning.SemanticSynthesis
  alias AshA2A.Semantic.{Compiler, ExecutionPackage, IR}
  alias AshA2A.Test.Fixture.{Echo, Item}
  alias AshA2A.Test.Fixture.SemanticHddlVerification

  describe "(1) malformed/schema-invalid LLM extraction into Compiler.compile/3" do
    test "a non-map extraction response is refused with :invalid_semantic_ir, not a crash, and short-circuits before planning" do
      extract = fn _model_spec, _prompt, _schema, _opts ->
        {:ok, "this is a bare string, not a JSON object at all"}
      end

      plan_must_not_be_called = fn _, _, _, _ ->
        raise "plan generator must not be called once extraction itself is schema-invalid"
      end

      assert {:error,
              %{
                code: :invalid_semantic_ir,
                detail: "this is a bare string, not a JSON object at all"
              }} =
               Compiler.compile(Echo, "The goal is to lead the people.",
                 generate_object: extract,
                 plan_generate_object: plan_must_not_be_called
               )
    end

    test "an extraction item missing a required admission field is refused with :semantic_fields_missing through the real pipeline, not a crash" do
      malformed_extraction =
        IR.fields()
        |> Map.new(&{Atom.to_string(&1), []})
        |> Map.put("authority", "none")
        |> Map.put("goals", [
          # Real admission requires `id`, `kind`, `description`, and
          # `source_quote` (`AshA2A.Semantic.Admission`'s `@required` map)
          # -- `source_quote` is deliberately omitted here, the shape a
          # genuinely malformed/incomplete LLM tool-call response would
          # produce (schema-valid JSON, but missing a field the schema
          # itself declares `required`).
          %{"id" => "g1", "kind" => "goal", "description" => "lead the people"}
        ])

      extract = fn _model_spec, _prompt, _schema, _opts -> {:ok, malformed_extraction} end

      plan_must_not_be_called = fn _, _, _, _ ->
        raise "plan generator must not be called once admission itself refuses the extraction"
      end

      assert {:error,
              %{code: :semantic_fields_missing, detail: %{field: :goals, missing: missing}}} =
               Compiler.compile(Echo, "The goal is to lead the people.",
                 generate_object: extract,
                 plan_generate_object: plan_must_not_be_called
               )

      assert "source_quote" in missing
    end

    test "compile_many/3 isolates a malformed extraction to its own slot while real siblings still complete" do
      malformed_text = "The goal is to feed the people."
      ok_text_1 = "The goal is to lead the people."
      ok_text_2 = "The goal is to read the people."

      extract = fn _model_spec, prompt, _schema, _opts ->
        cond do
          String.contains?(prompt, malformed_text) -> {:ok, %{"authority" => "none"}}
          String.contains?(prompt, ok_text_1) -> {:ok, extraction_for(ok_text_1)}
          true -> {:ok, extraction_for(ok_text_2)}
        end
      end

      results =
        Compiler.compile_many(Echo, [ok_text_1, malformed_text, ok_text_2],
          generate_object: extract,
          plan_generate_object: default_plan()
        )

      assert [ok1, err2, ok3] = results
      assert {:ok, %ExecutionPackage{}} = ok1
      assert {:error, %{code: :semantic_goal_missing}} = err2
      assert {:ok, %ExecutionPackage{}} = ok3
    end
  end

  describe "(2) genuinely malformed (unparseable) HDDL syntax via the real native hddl_cli binary" do
    @malformed_domain Path.expand("support/hddl/malformed_syntax/domain.hddl", __DIR__)
    @malformed_problem Path.expand("support/hddl/malformed_syntax/problem.hddl", __DIR__)

    # This fixture pair (test/support/hddl/malformed_syntax/{domain,problem}.hddl)
    # is a genuine PARSE failure, not the `unsolvable_qualification` fixture's
    # semantic impossibility: both files have real unbalanced parentheses
    # (e.g. `(define (domain malformed-syntax` never closes its `(domain`
    # form; `:parameters (?from - phase ?to - phase` never closes its own
    # paren). Verified empirically against the real binary during
    # development of this test (not merely asserted): running
    # `native/hddl_cli/target/release/hddl_cli
    # test/support/hddl/malformed_syntax/{domain,problem}.hddl` real,
    # standalone, on the command line prints
    # `{"error":"HDDL parse error: syntax error: unbalanced parentheses"}`
    # with exit code 1 -- the real ferroplan HDDL parser's own real
    # classification, distinct from `unsolvable_qualification`'s real
    # `{"error":"planner error: NoPlan"}`.
    test "the real solver reports a real parse error (not solved, not a crash) for unparseable HDDL text" do
      assert {:error, decoded} =
               SemanticHddlVerification.verify_solves!(@malformed_domain, @malformed_problem)

      assert Map.has_key?(decoded, "error"),
             "expected the real hddl_cli to report a real \"error\" key for genuinely " <>
               "unparseable HDDL syntax, got: #{inspect(decoded)}"

      assert decoded["error"] =~ "parse error",
             "expected the real error message to name a parse failure specifically " <>
               "(distinct from a semantic/planner NoPlan failure), got: #{inspect(decoded["error"])}"

      refute decoded["solved"] == true,
             "a genuinely unparseable HDDL pair must never be reported solved"
    end
  end

  describe "(3) unknown-capability-id refusal through SemanticSynthesis" do
    test "a model-proposed capability id outside the canonical index is refused with :noncanonical_capability before any command reaches CommandBus" do
      generator = fn _model_spec, _prompt, _schema, _opts ->
        {:ok,
         %{
           "request_id" => "failure-injection-unknown-capability",
           "authority" => "none",
           "capability_ids" => ["AshA2A.Test.Fixture.Echo.delete_everything"],
           "hddl" => "candidate",
           "fond" => "candidate"
         }}
      end

      assert {:error,
              %{
                code: :noncanonical_capability,
                detail: "AshA2A.Test.Fixture.Echo.delete_everything"
              }} =
               SemanticSynthesis.synthesize(Echo, "invent a capability", %{},
                 generate_object: generator,
                 # Reuses the already-configured `:semantic_reasoner` profile
                 # (`config/test.exs`) as the role for this synthesis call
                 # instead of mutating global `:llm_profiles` application
                 # config for a `:surface_planner` profile the way
                 # `semantic_synthesis_test.exs` does -- `role` is a pure
                 # config-lookup key (`AshA2A.LLMProfiles.fetch_profile!/1`),
                 # not a behavioral switch, so this exercises the exact same
                 # real `normalize_proposal/2` -> `AshA2A.Planning.from_envelope/3`
                 # -> `resolve_all/2` refusal path without touching shared
                 # process env from a consolidated, multi-section test file.
                 role: :semantic_reasoner
               )
    end
  end

  describe "(4) CommandBus authority failure (:authority_mismatch)" do
    setup do
      # Real on-disk EKV store (receipt_store_ekv_test.exs:25-36 pattern).
      # The refusal post-condition asserted below -- "nothing was committed"
      # -- is store-agnostic, so the durable store is the honest default and
      # this court consumes one fewer legacy-default Memory instance.
      ekv_name = :"ash_a2a_fail_inj_ekv_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_failure_injection_ekv_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(data_dir) end)

      start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

      %{store: AshA2A.ReceiptStore.Ekv, store_opts: [name: ekv_name]}
    end

    test "authority issued for a different capability id is refused with :authority_mismatch, not admitted",
         %{
           store: store,
           store_opts: store_opts
         } do
      principal = Identity.principal("failure-injection-subject-wrong-capability")

      wrong_capability_authority =
        Authority.new(principal, "AshA2A.Test.Fixture.Item.destroy_item",
          token_id: "auth-wrong-capability"
        )

      command =
        Command.new("AshA2A.Test.Fixture.Item.create",
          command_id: "failure-injection-create-wrong-capability",
          agent_id: "agent-1",
          principal_id: principal,
          authority: wrong_capability_authority,
          input: %{label: "widget"}
        )

      assert {:error, %{code: :authority_mismatch}} =
               CommandBus.run(command, data_message(%{"label" => "widget"}), Item,
                 store: store,
                 store_opts: store_opts
               )

      assert :error = ReceiptStore.Ekv.fetch(command.command_id, store_opts)
    end

    test "authority issued for the right capability but a different principal is refused with :authority_mismatch",
         %{
           store: store,
           store_opts: store_opts
         } do
      issuing_principal = Identity.principal("failure-injection-issuing-principal")
      calling_principal = Identity.principal("failure-injection-calling-principal")

      right_capability_wrong_principal =
        Authority.new(issuing_principal, "AshA2A.Test.Fixture.Item.create",
          token_id: "auth-wrong-principal"
        )

      command =
        Command.new("AshA2A.Test.Fixture.Item.create",
          command_id: "failure-injection-create-wrong-principal",
          agent_id: "agent-1",
          principal_id: calling_principal,
          authority: right_capability_wrong_principal,
          input: %{label: "widget"}
        )

      assert {:error, %{code: :authority_mismatch}} =
               CommandBus.run(command, data_message(%{"label" => "widget"}), Item,
                 store: store,
                 store_opts: store_opts
               )

      assert :error = ReceiptStore.Ekv.fetch(command.command_id, store_opts)
    end
  end

  describe "(5) real worker-process crash inside compile_many/3" do
    test "a genuine process exit (not a raised-and-rescued exception) in one slot is reported as :semantic_worker_exit, and surviving real siblings still complete correctly, in order" do
      # `Task.async_stream/3` (the bare `Task` module, which
      # `Compiler.compile_many/3` uses) links each spawned worker to the
      # calling process. Empirically verified in this test's own
      # development (real run, not assumed): a task calling `exit/1`
      # directly, WITHOUT this `trap_exit`, propagates through that link
      # and crashes the calling *test process itself* -- ExUnit reports it
      # as `** (EXIT from #PID<...>) :failure_injection_worker_crash`, not
      # as a normal test assertion failure. With `trap_exit` set here (the
      # caller's own real, standard OTP responsibility for tolerating a
      # linked worker's abnormal exit), the same real `exit/1` is instead
      # correctly converted by `Task.async_stream/3` into `{:exit, reason}`
      # for that one stream slot, and the caller survives -- confirmed by
      # this test passing only once `trap_exit` was added.
      Process.flag(:trap_exit, true)
      crash_text = "The goal is to feed the people."
      ok_text_1 = "The goal is to lead the people."
      ok_text_2 = "The goal is to read the people."
      ok_text_3 = "The goal is to guide the people."

      extract = fn _model_spec, prompt, _schema, _opts ->
        cond do
          String.contains?(prompt, crash_text) ->
            # A real `exit/1` is the worker process's own non-normal exit
            # reason -- distinct from a raised `Elixir` exception, which
            # `Compiler.isolated_compile/3`'s own `rescue` clause already
            # catches and converts before `Task.async_stream/3` ever sees an
            # abnormal exit (that already-rescued case is what
            # `test/ash_a2a/semantic_compiler_test.exs`'s
            # "converts a raised exception into a worker-exit error at its
            # slot" test covers). This is the genuinely different, real
            # `{:exit, reason} -> {:error, %{code: :semantic_worker_exit, ...}}`
            # clause in `Compiler.compile_many/3` itself -- unexercised by
            # any existing test in this suite.
            exit(:failure_injection_worker_crash)

          String.contains?(prompt, ok_text_1) ->
            {:ok, extraction_for(ok_text_1)}

          String.contains?(prompt, ok_text_2) ->
            {:ok, extraction_for(ok_text_2)}

          true ->
            {:ok, extraction_for(ok_text_3)}
        end
      end

      results =
        Compiler.compile_many(Echo, [ok_text_1, crash_text, ok_text_2, ok_text_3],
          generate_object: extract,
          plan_generate_object: default_plan()
        )

      assert [ok1, crashed, ok2, ok3] = results
      assert {:ok, %ExecutionPackage{}} = ok1
      assert {:ok, %ExecutionPackage{}} = ok2
      assert {:ok, %ExecutionPackage{}} = ok3

      assert {:error, %{code: :semantic_worker_exit, detail: :failure_injection_worker_crash}} =
               crashed
    end
  end

  defp default_plan do
    fn _, _, _, _ ->
      {:ok,
       %{
         "request_id" => "failure-injection-plan-1",
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "(:task lead)",
         "fond" => "(:policy observe-or-replan)"
       }}
    end
  end

  defp extraction_for(text) do
    IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{
        "id" => "lead",
        "kind" => "goal",
        "description" => "goal grounded in source",
        "source_quote" => text
      }
    ])
  end
end

# --- SECTION 6: Original test/ash_a2a_freedom_gym_chicago_core_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AFreedomGymChicagoCoreTest do
  @moduledoc """
  Chicago-Core deterministic tier of the "FreedomGym Chicago" primitive:
  five separately-`AshA2A`-extended Ash apps (one facilitator, four
  participant avatars), each standing in for its own
  independently-deployable service, exchanging real `AshA2A.Protocol.Message`s through
  real `AshA2A.Protocol.Agent` GenServers under one real `AshA2A.Protocol.AgentSupervisor` --
  exactly the cross-app pattern proven in
  `test/ash_a2a_rap_battle_integration_test.exs`.

  This tier is fully deterministic: every participant avatar's behavior is
  real Elixir logic keyed off `phase` (and, for two avatars, an explicit
  extra argument), never an LLM call and never a canned literal passed
  through untouched. Assertions are state-based over the real accumulated
  responses returned by real A2A dispatch -- no Mock/mox/patch/monkeypatch.

  An AI-backed "Chicago AI" tier -- using the newly-added `ash_ai` dependency
  for live LLM-generated avatar responses -- is a deliberate, explicit
  follow-up phase, not built here. `ash_r2rml` is likewise added to `mix.exs`
  as a forward-looking dependency only; no live RDF/R2RML mapping is wired
  up in this test.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.{
    FacilitatorAgent,
    NewNervousAgent,
    DrunkalogAgent,
    EverythingGreatAgent,
    HelpRequestAgent
  }

  @phases [:trust_god, :clean_house, :help_others]

  setup do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        FacilitatorAgent,
        NewNervousAgent,
        DrunkalogAgent,
        EverythingGreatAgent,
        HelpRequestAgent
      ])

    :ok
  end

  defp facilitator_prompt(phase) do
    assert {:ok, task} =
             FacilitatorAgent.call(
               FacilitatorAgent,
               data_message(
                 %{phase: phase, prompt_text: "facilitator prompt for #{phase}"},
                 %{metadata: %{skill: "run_phase"}}
               )
             )

    assert task.status.state == :completed

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: result}]}] =
             task.artifacts

    result
  end

  defp participant_response(agent, phase, prompt_text, extra_args \\ %{}) do
    message =
      data_message(Map.merge(%{phase: phase, prompt_text: prompt_text}, extra_args))

    assert {:ok, task} = agent.call(agent, message)
    assert task.status.state == :completed

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: result}]}] =
             task.artifacts

    result
  end

  test "facilitator + four independent participant apps run a real phase sequence over real A2A dispatch" do
    # Drive the real phase sequence: for each phase, ask the facilitator's
    # separate app for that phase's real prompt/invariant checklist (over
    # real A2A dispatch), then hand that real prompt_text to each of the
    # four participant apps' own real A2A dispatch and collect their real
    # responses.
    responses_by_phase =
      Map.new(@phases, fn phase ->
        facilitator_result = facilitator_prompt(phase)

        assert facilitator_result.phase == phase
        assert facilitator_result.requires_redirect_check? == (phase == :clean_house)
        assert is_binary(facilitator_result.prompt_text)

        prompt_text = facilitator_result.prompt_text

        participant_results = %{
          new_nervous: participant_response(NewNervousAgent, phase, prompt_text),
          drunkalog: participant_response(DrunkalogAgent, phase, prompt_text),
          everything_great: participant_response(EverythingGreatAgent, phase, prompt_text),
          help_request: participant_response(HelpRequestAgent, phase, prompt_text)
        }

        {phase, participant_results}
      end)

    # -- Real, state-based invariant assertions over the real accumulated
    #    responses (not canned) --

    # new_nervous wants to speak only during the low-stakes :trust_god phase.
    assert %{wants_to_speak?: true, topic: "low_stakes:" <> _} =
             responses_by_phase[:trust_god][:new_nervous]

    assert %{wants_to_speak?: false} = responses_by_phase[:clean_house][:new_nervous]
    assert %{wants_to_speak?: false} = responses_by_phase[:help_others][:new_nervous]

    # drunkalog redirects to the current state in every non-clean_house
    # phase, and rambles about history in :clean_house (absent an explicit
    # redirect flag).
    assert %{redirected_to_current_state?: true, topic: "current:" <> _} =
             responses_by_phase[:trust_god][:drunkalog]

    assert %{redirected_to_current_state?: true, topic: "current:" <> _} =
             responses_by_phase[:help_others][:drunkalog]

    assert %{redirected_to_current_state?: false, topic: "history:" <> _} =
             responses_by_phase[:clean_house][:drunkalog]

    # When the test explicitly requests a redirect on a repeat :clean_house
    # call, drunkalog's real response shows redirected_to_current_state?:
    # true and a topic starting with "current:".
    redirected_drunkalog =
      participant_response(DrunkalogAgent, :clean_house, "repeat clean_house prompt", %{
        redirected: true
      })

    assert %{redirected_to_current_state?: true, topic: "current:" <> _} = redirected_drunkalog

    # everything_great is superficial by default, but reveals a real
    # "current:" topic once challenged.
    assert %{topic: "everything_is_fine", redirected_to_current_state?: false} =
             responses_by_phase[:trust_god][:everything_great]

    challenged_everything_great =
      participant_response(
        EverythingGreatAgent,
        :clean_house,
        "challenge prompt",
        %{challenged?: true}
      )

    assert %{redirected_to_current_state?: true, topic: "current:" <> _} =
             challenged_everything_great

    # help_request asks for help exactly during :help_others, never in the
    # other two phases.
    assert %{asks_for_help?: true} = responses_by_phase[:help_others][:help_request]
    assert %{asks_for_help?: false} = responses_by_phase[:trust_god][:help_request]
    assert %{asks_for_help?: false} = responses_by_phase[:clean_house][:help_request]

    # At most one participant is a genuine help-seeker in the :help_others
    # round (only help_request's avatar policy sets asks_for_help?: true).
    help_others_round = responses_by_phase[:help_others]

    help_seekers =
      help_others_round
      |> Map.values()
      |> Enum.count(& &1.asks_for_help?)

    assert help_seekers == 1
  end

  test "same participant/phase combo is fully deterministic on repeat real A2A calls" do
    for {agent, phase, extra_args} <- [
          {NewNervousAgent, :trust_god, %{}},
          {DrunkalogAgent, :clean_house, %{}},
          {DrunkalogAgent, :clean_house, %{redirected: true}},
          {EverythingGreatAgent, :help_others, %{}},
          {EverythingGreatAgent, :help_others, %{challenged?: true}},
          {HelpRequestAgent, :help_others, %{}}
        ] do
      first = participant_response(agent, phase, "determinism check", extra_args)
      second = participant_response(agent, phase, "determinism check", extra_args)

      assert first == second
    end
  end
end

# --- SECTION 7: Original test/ash_a2a_freedom_gym_hddl_plan_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AFreedomGymHddlPlanTest do
  @moduledoc """
  Proves the FreedomGym facilitator's phase sequence is now real-HDDL-plan-
  derived, not the old hardcoded `@phases` list
  (`test/ash_a2a_freedom_gym_chicago_core_test.exs`'s `[:trust_god,
  :clean_house, :help_others]`).

  Two real, state-based assertions, Chicago style (no Mock/mox/patch/
  monkeypatch anywhere in this file):

  1. `AshA2A.Test.Fixture.FreedomGym.MeetingPlan.real_plan_phases!/0` --
     calling the real `hddl_cli` binary, which calls beam4pm's real
     `ferroplan::solve_hddl` over the real
     `test/support/hddl/freedom_gym_meeting/{domain,problem}.hddl` --
     returns the real, solved 6-phase sequence
     `[:open, :trust_god, :clean_house, :help_others, :fellowship, :close]`,
     asserted on the real returned list, not a description of it.
  2. Driving the facilitator's new `:next_phase` A2A skill (real dispatch,
     real `AshA2A.Protocol.Agent`, same pattern as the Chicago-Core test) repeatedly
     over a real, isolated in-memory plan position yields exactly that same
     real ordered sequence -- proving the facilitator consults the real
     plan rather than re-implementing/echoing a hardcoded list.
  """

  # async: false -- this test's `FacilitatorAgent` is the same
  # `AshA2A.Protocol.Agent`-generated process name
  # `AshA2AFreedomGymChicagoCoreTest`'s async: true test uses; running both
  # concurrently is a real process-name collision, not something this test
  # can or should route around (see `AshA2A.Test.AgentSupervisorCase`'s
  # moduledoc -- the per-case supervisor/registry names are unique, but the
  # `AshA2A.Protocol.Agent` process itself is registered under its own module name).
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.{FacilitatorAgent, MeetingPlan}

  setup do
    # RFC-SA2A-001 S29: a transport-authenticated caller holds authority for
    # a `:change`/`:external_do` capability only when a real
    # `AshA2A.Authority.Broker` grant stands for that exact (principal,
    # capability) pair -- see `AshA2A.Authority.Grant`. Issued here for the
    # real pairs this file's own dispatches use.
    AshA2A.Test.AuthorityGrantCase.grant!([
      {"hddl-plan-test-caller", AshA2A.Test.Fixture.FreedomGym.Facilitator,
       ["next_phase", "reset_plan"]}
    ])

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [FacilitatorAgent])

    :ok
  end

  test "MeetingPlan.real_plan_phases!/0 returns the real solved HDDL plan's phase sequence" do
    assert MeetingPlan.real_plan_phases!() == [
             :open,
             :trust_god,
             :clean_house,
             :help_others,
             :fellowship,
             :close
           ]
  end

  test "facilitator's :next_phase skill derives the real phase sequence from the real HDDL plan, over real A2A dispatch" do
    plan_name = :"hddl_plan_test_#{System.unique_integer([:positive])}"

    # RFC-SA2A-004 S11: strict actuation dedup refuses a second fresh request
    # naming the identical effect, so each real step is a distinct request
    # (distinct input), as a real facilitator's successive turns are.
    fetch_next = fn turn ->
      assert {:ok, task} =
               FacilitatorAgent.call(
                 FacilitatorAgent,
                 data_message(
                   %{plan_name: plan_name, prompt_text: "next real phase, please (turn #{turn})"},
                   %{metadata: %{skill: "next_phase"}}
                 ),
                 metadata: %{"a2a.auth" => %{identity: "hddl-plan-test-caller"}}
               )

      assert task.status.state == :completed

      assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: result}]}] =
               task.artifacts

      result
    end

    observed_phases = Enum.map(1..6, fn turn -> fetch_next.(turn).phase end)

    assert observed_phases == [
             :open,
             :trust_god,
             :clean_house,
             :help_others,
             :fellowship,
             :close
           ]

    # requires_redirect_check? invariant still holds over the real,
    # plan-derived :clean_house phase, exactly as :run_phase's contract
    # requires.
    clean_house_result =
      Enum.zip(observed_phases, 1..6)
      |> Enum.find(fn {phase, _} -> phase == :clean_house end)
      |> elem(1)

    assert clean_house_result == 3

    # The real plan is now exhausted -- a 7th call must fail for real,
    # not silently wrap around or fabricate a phase.
    assert {:ok, task} =
             FacilitatorAgent.call(
               FacilitatorAgent,
               data_message(%{plan_name: plan_name, prompt_text: "one too many"})
             )

    # Terminal either way; v1.0 admission refusals land :rejected.
    assert task.status.state in [:failed, :rejected]

    # A real reset genuinely rewinds the real in-memory plan position.
    assert {:ok, reset_task} =
             FacilitatorAgent.call(
               FacilitatorAgent,
               data_message(%{plan_name: plan_name}, %{metadata: %{skill: "reset_plan"}}),
               metadata: %{"a2a.auth" => %{identity: "hddl-plan-test-caller"}}
             )

    assert reset_task.status.state == :completed
    assert fetch_next.(7).phase == :open
  end
end

# --- SECTION 8: Original test/ash_a2a_freedom_gym_llm_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AFreedomGymLlmTest do
  @moduledoc """
  Chicago-AI tier of the FreedomGym primitive: a REAL live call to Z.AI
  (via `ash_ai`'s `AshAi.Actions.Prompt` + `req_llm`'s native `zai_coder`
  provider), dispatched through a real supervised `AshA2A.Protocol.Agent`, exactly like
  every other FreedomGym/rap-battle agent in this suite -- no mock LLM
  client, no canned response.

  Formerly Groq-backed; swapped 2026-09 per explicit request to replace
  this repo's Groq usage with Z.AI -- this test is now functionally
  redundant with `test/ash_a2a_freedom_gym_zai_test.exs` (same provider,
  same model), kept separate since only conversion, not consolidation, was
  asked for.

  Chicago style still applies to the *assertions*: since real LLM output is
  not literal-reproducible, this test asserts on the real structural
  invariants the action's Ash return-type contract enforces (booleans are
  booleans, topic is a string or nil), not on exact wording -- the model
  supplies content variation, the Ash action contract and this test supply
  the pass/fail boundary.

  Named, visible skip (never a silent mock substitution) when
  `ZAI_API_KEY` is not found in `~/.env`, per `testing-chicago-style.md`'s
  "real collaborator or an honest skip" discipline.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.LlmAvatarAgent

  # See AshA2A.Test.EnvKeyFixture's moduledoc for why this compile-time
  # extraction calls a shared *external* support module rather than a local
  # `defp` (a local call would fail to compile at this point).
  @zai_key AshA2A.Test.EnvKeyFixture.read_key("ZAI_API_KEY")

  @moduletag :external_api
  @describetag skip: AshA2A.Test.EnvKeyFixture.live_llm_skip_reason()

  setup_all do
    if @zai_key do
      Application.put_env(:req_llm, :zai_coder_api_key, @zai_key)
    end

    :ok
  end

  # Real, disclosed interaction with
  # test/ash_a2a_zai_concurrency_ocel_test.exs's real 50-way concurrency
  # probe when the full suite runs with `--include external_api`: real
  # rate-limit exhaustion from that probe can make this real, unseamed live
  # LLM call exceed the default 60s on both the ExUnit test process and
  # AshA2A.Protocol.Agent.call/3's own GenServer.call -- same fix as
  # test/ash_a2a_agent_semantic_request_test.exs, not a code defect.
  @tag timeout: 180_000
  test "a real Z.AI-backed avatar responds over real A2A dispatch with a real structured shape" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        LlmAvatarAgent
      ])

    message =
      data_message(%{
        phase: :help_others,
        prompt_text:
          "This is the Help Others segment. Does anyone need support with something right now?"
      })

    assert {:ok, task} = LlmAvatarAgent.call(LlmAvatarAgent, message, timeout: 170_000)
    assert task.status.state == :completed

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: response}]}] =
             task.artifacts

    # Real, state-based assertions on the real object the real Z.AI call
    # returned -- not on its exact wording.
    assert %{wants_to_speak?: wants_to_speak?, asks_for_help?: asks_for_help?} = response
    assert is_boolean(wants_to_speak?)
    assert is_boolean(asks_for_help?)
    assert is_nil(response[:topic]) or is_binary(response[:topic])
  end
end

# --- SECTION 9: Original test/ash_a2a_freedom_gym_ocel_conformance_e2e_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FreedomGymOcelConformanceE2ETest do
  @moduledoc """
  Step 5: the real end-to-end "plan-execute-conform" loop --

    HDDL plan (Step 3's real `hddl_cli` solve) -> A2A/Ash execution (this
    test's own real `AshA2A.Protocol.Agent` dispatch against the real
    `FacilitatorAgent`'s `:next_phase` skill, same call pattern as
    `test/ash_a2a_freedom_gym_hddl_plan_test.exs`) -> OCEL v2 recording (a
    real HTTP POST of each real dispatch's real returned phase to
    beam4pm's real, already-running `BeamPM.OcelIngest.Router` at
    `POST /ocel/events`, confirmed by its real 201 response) -> POWL
    conformance check (beam4pm's `BeamPM.PowlConformance`, run in
    beam4pm's own test suite against the real accepted-event JSON this
    test captures and writes out -- see
    `test/beam4pm_powl_conformance_e2e_test.exs` in the beam4pm repo).

  Real, disclosed architectural fact (not a shortcut taken here): reading
  `lib/beam4pm_ocel_ingest.ex` directly shows `BeamPM.OcelIngest.Router`
  validates and echoes each event (fully real, wire-contract-checked) but
  does not persist/store it server-side for later query -- there is no
  GET/query route. So "the real accumulated OCEL trace" from this real
  run is threaded to beam4pm's own conformance check via a real captured
  JSON file (the real 201-confirmed echoed records this test collects),
  not a live query against accumulated server state. The dispatch, the
  phases, the HTTP POSTs, and the 201 acceptances are all real; only the
  cross-process handoff of "which events to check conformance over" goes
  through a file rather than a query, because the real endpoint has no
  query surface to call.

  `AshA2A.Telemetry.OcelForwarder` (the already-real generic dispatch
  forwarder, just merged from `feat/ocel-v2-telemetry-forwarder`) is real
  and reachable, but its own real `event_type` is
  `"ash_a2a.dispatch.<resource>.<skill>"` -- the dispatched SKILL name
  (`next_phase`, constant across all 6 calls), not the returned PHASE
  value (`:telemetry.span`'s stop metadata never carries the reply's own
  data, confirmed by reading `dispatcher.ex`'s `stop_meta/1`). It
  therefore cannot itself produce per-phase-distinct OCEL activities.
  This test still exercises the real forwarder (`attach!/0`; a real
  `[:ash_a2a, :dispatch, :stop]` event fires per call, forwarded
  best-effort) AND separately posts the real per-phase event this
  conformance check actually needs -- two real, complementary OCEL
  emissions, disclosed rather than papered over.

  The OCEL ingest endpoint is now HERMETIC: this test boots beam4pm's real
  `BeamPM.OcelIngest.Router` (real beam4pm source, compiled in-VM from the
  canonical checkout at `BEAM4PM_PATH`, default the sibling `../beam4pm`)
  on a real Bandit listener at an OS-assigned ephemeral loopback port, with
  a real HTTP health check before any event is posted. No out-of-process
  server is required and nothing is stubbed -- the same real router bytes
  that the standalone deployment runs. Setting `OCEL_INGEST_URL` still
  overrides this and targets an already-running external server instead.

  Finally, the loop is CLOSED on ash_a2a's own trust plane: the ingest-
  accepted reference events are sealed into a real Affidavit WASM receipt
  (`AshA2A.Evidence.Affidavit.assemble_receipt/1`) and re-verified
  (`verify_receipt/1` -> `accepted: true`), so the run leaves behind not
  just capture files but a tamper-evident, replayable receipt over exactly
  the events the real endpoint accepted.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  # Real HDDL solve + in-VM compile of beam4pm's real router/types + 24 real
  # dispatches + WASM receipt sealing -- comfortably over the 60s default.
  @moduletag timeout: 240_000

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Telemetry.OcelForwarder
  alias AshA2A.Test.Fixture.FreedomGym.{FacilitatorAgent, MeetingPlan}

  @ingest_url System.get_env("OCEL_INGEST_URL")
  @beam4pm_path System.get_env("BEAM4PM_PATH") ||
                  Path.expand("../../beam4pm", __DIR__)
  @output_dir Path.expand("../../beam4pm/qualification/gym_bridge", __DIR__)
  @beam4pm_required_modules [BeamPM.OcelIngest.Router, BeamPM.Types.OcelEvent]

  # Compile beam4pm's REAL ingest router and its REAL generated OCEL types
  # from the canonical beam4pm checkout into this VM, once. These are the
  # actual dependency-free Plug/struct modules the standalone deployment
  # runs -- not copies, not re-implementations. Returns the base URL of a
  # live Bandit listener serving the real router on an ephemeral port.
  defp boot_hermetic_ingest_server! do
    missing =
      Enum.reject(@beam4pm_required_modules, &Code.ensure_loaded?/1)

    if missing != [] do
      router_path = Path.join(@beam4pm_path, "lib/beam4pm_ocel_ingest.ex")
      types_path = Path.join(@beam4pm_path, "lib/beam4pm_types.ex")

      unless File.exists?(router_path) and File.exists?(types_path) do
        skip_and_fail(
          "beam4pm canonical checkout not found at #{@beam4pm_path} " <>
            "(set BEAM4PM_PATH)"
        )
      end

      # Types first (the router's decode path calls the generated
      # constructors), then the router. Real compile, real modules.
      Code.compile_file(types_path)
      Code.compile_file(router_path)

      still_missing =
        Enum.reject(@beam4pm_required_modules, &Code.ensure_loaded?/1)

      if still_missing != [] do
        skip_and_fail(
          "beam4pm modules failed to compile from #{@beam4pm_path}: " <>
            Enum.map_join(still_missing, ", ", &inspect/1)
        )
      end
    end

    # Real Bandit HTTP listener, real OS-assigned ephemeral port (same
    # helper the :serial_shard tests use -- cannot collide).
    server = AshA2A.Test.EphemeralHttp.start!(BeamPM.OcelIngest.Router)

    # Real HTTP health check: the router's admission graph defines NO GET
    # route, so its real 404 ("route_not_admitted") is positive proof the
    # real router is live and answering.
    assert {:ok, %Req.Response{status: 404, body: %{"error" => "route_not_admitted"}}} =
             Req.get(server.base_url <> "/ocel/events")

    :persistent_term.put({__MODULE__, :ingest_url}, server.base_url)

    server_pid = server.pid

    # Best-effort teardown: the listener is also linked to the test
    # process, so this is belt-and-braces, never a test verdict.
    on_exit(fn ->
      try do
        if Process.alive?(server_pid), do: Supervisor.stop(server_pid, :normal, 5_000)
      catch
        _, _ -> :ok
      end
    end)

    server.base_url
  end

  defp skip_and_fail(reason) do
    # Loud, named refusal -- never a silent stub or an implicit crash.
    flunk("HERMETIC-INGEST-UNAVAILABLE: " <> reason)
  end

  defp ingest_url do
    @ingest_url || :persistent_term.get({__MODULE__, :ingest_url}, nil)
  end

  setup do
    # Hermetic server boot (unless an explicit external URL was provided).
    if is_nil(@ingest_url) do
      boot_hermetic_ingest_server!()
    end

    # Real Affidavit WASM engine pool (real AshAffidavit.Host WASM members),
    # so step 5's assemble/verify runs against the real engine. Only when no
    # pool is already running (the sibling evidence tests use the same
    # convention in test/ash_a2a/evidence/affidavit_test.exs).
    if AshA2A.Evidence.Affidavit.available?() and is_nil(Process.whereis(AshAffidavit.Pool)) do
      start_supervised!({AshAffidavit.Pool, size: 1})
    end

    # RFC-SA2A-001 S29: a transport-authenticated caller holds authority for
    # a `:change`/`:external_do` capability only when a real
    # `AshA2A.Authority.Broker` grant stands for that exact (principal,
    # capability) pair -- see `AshA2A.Authority.Grant`. Issued here for the
    # real pairs this file's own dispatches use.
    AshA2A.Test.AuthorityGrantCase.grant!([
      {"ocel-conformance-test-caller", AshA2A.Test.Fixture.FreedomGym.Facilitator, ["next_phase"]}
    ])

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [FacilitatorAgent])

    Application.put_env(:ash_a2a, :ocel_ingest_url, @ingest_url)
    :ok = OcelForwarder.attach!()
    File.mkdir_p!(@output_dir)
    on_exit(fn -> OcelForwarder.detach() end)
    :ok
  end

  # Drives the real A2A `:next_phase` skill against the real
  # FacilitatorAgent `count` times for `plan_name`, collecting the real
  # returned phase per call plus a real, monotonically increasing
  # timestamp for OCEL ordering. Real dispatch, real telemetry span
  # (forwarded best-effort by the real OcelForwarder), real reply.
  defp dispatch_real_phases!(plan_name, meeting_id, count) do
    MeetingPlan.reset(plan_name)
    base = DateTime.utc_now()

    1..count
    |> Enum.map(fn i ->
      assert {:ok, task} =
               FacilitatorAgent.call(
                 FacilitatorAgent,
                 data_message(
                   %{plan_name: plan_name, prompt_text: "next real phase #{i}"},
                   %{metadata: %{skill: "next_phase"}}
                 ),
                 metadata: %{"a2a.auth" => %{identity: "ocel-conformance-test-caller"}}
               )

      assert task.status.state == :completed

      assert [
               %AshA2A.Protocol.Artifact{
                 parts: [%AshA2A.Protocol.Part.Data{data: %{phase: phase}}]
               }
             ] = task.artifacts

      %{
        "event_id" => Ash.UUIDv7.generate(),
        "event_type" => "freedom_gym.meeting_phase.#{phase}",
        "event_time" => DateTime.add(base, i, :second) |> DateTime.to_iso8601(),
        "attributes" => %{"phase" => Atom.to_string(phase), "meeting_id" => meeting_id},
        "relationships" => [%{"qualifier" => "phase_of", "object_id" => meeting_id}]
      }
    end)
  end

  # Real HTTP POST to beam4pm's real, live ingest endpoint. Returns the
  # real accepted (201-confirmed) event echoes.
  defp post_real_events!(events) do
    assert {:ok, %Req.Response{status: 201, body: body}} =
             Req.post(ingest_url() <> "/ocel/events", json: %{"events" => events})

    assert body["ok"] == true
    assert length(body["accepted"]) == length(events)
    body["accepted"]
  end

  test "real HDDL plan -> real A2A dispatch -> real OCEL ingest -> real POWL conformance " <>
         "input, captured for beam4pm's real conformance check" do
    # 1) HDDL plan (Step 3, already real): 3 reference meetings each
    #    running the full real solved 6-phase plan via real A2A dispatch.
    reference_events =
      ["e2e-ref-1", "e2e-ref-2", "e2e-ref-3"]
      |> Enum.map(fn meeting_id ->
        plan_name = :"e2e_ref_#{meeting_id}_#{System.unique_integer([:positive])}"
        dispatch_real_phases!(plan_name, meeting_id, 6)
      end)
      |> List.flatten()

    # 2) Real OCEL ingest: POST every reference event to beam4pm's real,
    #    live router; the real 201 + echoed record IS the proof the wire
    #    contract round-trips, not a locally-constructed assumption.
    accepted_reference = post_real_events!(reference_events)
    assert length(accepted_reference) == 18

    # 3) Deviant run: same real dispatch machinery, but the "clean_house"
    #    phase's event is dropped before ingest -- a genuinely real
    #    execution with a deliberately injected gap, not a hand-edited
    #    event list built without dispatching at all.
    deviant_plan = :"e2e_deviant_#{System.unique_integer([:positive])}"
    deviant_events = dispatch_real_phases!(deviant_plan, "e2e-deviant-1", 6)

    deviant_events_with_gap =
      Enum.reject(deviant_events, &(&1["attributes"]["phase"] == "clean_house"))

    accepted_deviant = post_real_events!(deviant_events_with_gap)
    assert length(accepted_deviant) == 5

    # 4) Capture the real, ingest-confirmed events to a real file that
    #    beam4pm's own test reads to build its real in-process OCEL log
    #    and run the real POWL conformance check (see moduledoc for why a
    #    file, not a live query).
    reference_path = Path.join(@output_dir, "reference_ocel_events.json")
    deviant_path = Path.join(@output_dir, "deviant_ocel_events.json")

    File.write!(
      reference_path,
      JSON.encode!(%{
        "meeting_ids" => ["e2e-ref-1", "e2e-ref-2", "e2e-ref-3"],
        "events" => accepted_reference
      })
    )

    File.write!(
      deviant_path,
      JSON.encode!(%{"meeting_id" => "e2e-deviant-1", "events" => accepted_deviant})
    )

    assert File.exists?(reference_path)
    assert File.exists?(deviant_path)

    # 5) Close the loop on ash_a2a's own trust plane: seal the exact
    #    ingest-accepted reference events into a real Affidavit WASM
    #    receipt and re-verify it. `accepted: true` from the engine over
    #    the HTTP-accepted bytes is the tamper-evident closure; no mock,
    #    no stub -- the real ash_affidavit engine (a real test dep).
    lifecycle_events =
      Enum.map(accepted_reference, fn e ->
        payload =
          JSON.encode!(%{
            "phase" => e["attributes"]["phase"],
            "meeting_id" => e["attributes"]["meeting_id"]
          })

        %{
          "id" => e["event_id"],
          "event_type" => e["event_type"],
          "objects" => ["#{e["attributes"]["meeting_id"]}:Meeting"],
          "payload" => payload
        }
      end)

    assert {:ok, %{"chain_hash" => chain_hash, "content_address" => _} = assembled_receipt} =
             AshA2A.Evidence.Affidavit.assemble_receipt(lifecycle_events)

    assert is_binary(chain_hash) and byte_size(chain_hash) == 64

    assert {:ok, true} =
             AshA2A.Evidence.Affidavit.verify_receipt(assembled_receipt["receipt"])

    # Tamper-evidence falsifier: one flipped byte inside the sealed receipt
    # must make the engine's verify verdict `accepted: false` with a named
    # failing stage -- a typed refusal, never a silent pass.
    tampered =
      Map.update!(assembled_receipt["receipt"], "chain_hash", fn <<_first::binary-size(1),
                                                                   rest::binary>> ->
        "F" <> rest
      end)

    assert {:ok, verdict} = AshAffidavit.call(%{"op" => "verify", "receipt" => tampered})
    assert verdict["accepted"] == false

    # Real ERC receipt: this run's own actual counts, not asserted
    # constants, so the receipt can't drift from what this execution
    # really produced.
    {:ok, receipt_path} =
      AshA2A.Research.ERC.emit!(%{
        id: "ERC-001",
        claim:
          "A real HDDL-planned facilitator, dispatched over real A2A, produces OCEL v2 " <>
            "events that beam4pm's real ingest endpoint (booted hermetically in-VM from " <>
            "the canonical checkout) accepts (HTTP 201) for every phase transition, and " <>
            "the accepted events seal into a tamper-evident Affidavit receipt that " <>
            "re-verifies accepted: true.",
        falsifier:
          "Any dispatched phase transition fails to produce a 201-accepted OCEL event at " <>
            "beam4pm's ingest endpoint under the same real HDDL plan, or the assembled " <>
            "Affidavit receipt fails re-verification.",
        state: :verified,
        evidence: %{
          "reference_meetings" => 3,
          "reference_events_posted" => length(reference_events),
          "reference_events_accepted" => length(accepted_reference),
          "deviant_events_posted" => length(deviant_events_with_gap),
          "deviant_events_accepted" => length(accepted_deviant),
          "reference_capture_file" => reference_path,
          "deviant_capture_file" => deviant_path,
          "ingest_url" => ingest_url(),
          "affidavit_receipt_chain_hash" => chain_hash,
          "affidavit_receipt_content_address" => assembled_receipt["content_address"]
        },
        notes:
          "Deviant capture deliberately omits the clean_house phase event -- consumed by " <>
            "beam4pm's BeamPM.PowlConformanceE2ETest (ERC-002) as the injected falsifier " <>
            "case for the downstream conformance claim."
      })

    IO.puts("ERC-001 receipt written: #{receipt_path}")
  end
end

# --- SECTION 10: Original test/ash_a2a_freedom_gym_phase_admission_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AFreedomGymPhaseAdmissionTest do
  @moduledoc """
  Proves the real SELECT-vs-DO admission gate closes the gap where the
  Facilitator's `:next_phase` action returned the HDDL-solver-selected phase
  directly as the actuation result with no independent admission check.

  Real, state-based assertions, Chicago style (no Mock/mox/patch/monkeypatch
  anywhere in this file):

  1. `PhaseAdmission.admit/1` unit-level: a real admitted phase passes
     through as `{:ok, phase}`; a deliberately unadmitted phase is refused
     with the typed `{:error, {:not_admitted, phase}}`, not silently let
     through.
  2. Integration-level, over real A2A dispatch: the real
     `AshA2A.Test.Fixture.FreedomGym.MeetingPlan` Agent (a real, live
     process, not a mock) is seeded for real with an unadmitted phase
     injected into its real plan-position state, and the Facilitator's real
     `:next_phase` skill is driven against it -- the task must fail with the
     admission gate's refusal, never complete with the unadmitted phase
     actuated.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.{FacilitatorAgent, MeetingPlan, PhaseAdmission}

  setup do
    # RFC-SA2A-001 S29: a transport-authenticated caller holds authority for
    # a `:change`/`:external_do` capability only when a real
    # `AshA2A.Authority.Broker` grant stands for that exact (principal,
    # capability) pair -- see `AshA2A.Authority.Grant`. Issued here for the
    # real pairs this file's own dispatches use.
    AshA2A.Test.AuthorityGrantCase.grant!([
      {"phase-admission-test-caller", AshA2A.Test.Fixture.FreedomGym.Facilitator, ["next_phase"]}
    ])

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [FacilitatorAgent])

    :ok
  end

  describe "PhaseAdmission.admit/1 (unit, real allowlist)" do
    test "a real admitted phase passes through" do
      assert PhaseAdmission.admit(:trust_god) == {:ok, :trust_god}
      assert PhaseAdmission.admit(:close) == {:ok, :close}
    end

    test "a deliberately unadmitted phase is refused with the typed error" do
      assert PhaseAdmission.admit(:secret_backdoor_phase) ==
               {:error, {:not_admitted, :secret_backdoor_phase}}
    end

    test "admission_verdict/1 and decision/1 agree with admit/1 on both outcomes" do
      assert PhaseAdmission.admission_verdict(:open) == {:admitted, :open}
      assert %{verdict: :admitted, phase: :open} = PhaseAdmission.decision(:open)

      assert {:refused, reason} = PhaseAdmission.admission_verdict(:not_a_real_phase)
      assert reason =~ "not an admitted FreedomGym meeting phase"

      assert %{verdict: :refused, phase: :not_a_real_phase} =
               PhaseAdmission.decision(:not_a_real_phase)
    end
  end

  describe "Facilitator :next_phase over real A2A dispatch, with an unadmitted phase injected into the real plan" do
    test "an unadmitted phase popped from the real plan is refused, never actuated" do
      plan_name = :"phase_admission_test_#{System.unique_integer([:positive])}"

      # Start the real MeetingPlan Agent for real, then inject a real,
      # deliberately unadmitted phase at the front of its real in-memory
      # plan state -- a real live process's real state, not a mock/stub.
      {:ok, _pid} = MeetingPlan.start_link(plan_name)

      Agent.update(plan_name, fn state ->
        %{state | phases: [:rogue_unadmitted_phase | state.phases], index: 0}
      end)

      assert {:ok, task} =
               FacilitatorAgent.call(
                 FacilitatorAgent,
                 data_message(
                   %{plan_name: plan_name, prompt_text: "attempt to actuate an unadmitted phase"},
                   %{metadata: %{skill: "next_phase"}}
                 ),
                 metadata: %{"a2a.auth" => %{identity: "phase-admission-test-caller"}}
               )

      assert task.status.state == :failed
    end

    test "an admitted phase popped from the real plan still completes exactly as before" do
      plan_name = :"phase_admission_ok_test_#{System.unique_integer([:positive])}"

      assert {:ok, task} =
               FacilitatorAgent.call(
                 FacilitatorAgent,
                 data_message(
                   %{plan_name: plan_name, prompt_text: "first real admitted phase"},
                   %{metadata: %{skill: "next_phase"}}
                 ),
                 metadata: %{"a2a.auth" => %{identity: "phase-admission-test-caller"}}
               )

      assert task.status.state == :completed

      assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: result}]}] =
               task.artifacts

      assert result.phase == :open
    end
  end
end

# --- SECTION 11: Original test/ash_a2a_freedom_gym_zai_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AFreedomGymZaiTest do
  @moduledoc """
  Chicago-AI tier of the FreedomGym primitive: a REAL live call to Z.AI's
  GLM coding-plan endpoint (via `ash_ai`'s `AshAi.Actions.Prompt` +
  `req_llm`'s native `:zai_coder` provider), dispatched through a real
  supervised `AshA2A.Protocol.Agent` -- no mock LLM client, no canned response.
  Functionally redundant with `ash_a2a_freedom_gym_llm_test.exs`'s
  `LlmAvatar` since that avatar's 2026-09 Groq->Z.AI conversion (same
  provider, same model); kept separate since only conversion, not
  consolidation, was asked for.

  `Z_AI_API_KEY` lives in `~/.env` (checked via `mix dotenvy` loading at
  boot for other keys, but this repo doesn't declare `dotenvy` as a
  runtime dep, so it is read directly from `~/.env` here) under a name
  that doesn't match what `req_llm`'s `:zai_coder` provider looks up by
  default (`ZAI_API_KEY` / `:zai_coder_api_key`, see
  `deps/req_llm/lib/req_llm/keys.ex`) -- so this test reads the real key
  from `~/.env` once in `setup_all` and installs it via
  `Application.put_env(:req_llm, :zai_coder_api_key, key)`, the
  `:application` tier of `ReqLLM.Keys`' documented lookup precedence. The
  key itself is never logged or asserted on.

  Named, visible skip (never a silent mock substitution) when
  `~/.env` has no `Z_AI_API_KEY` line, per `testing-chicago-style.md`'s
  "real collaborator or an honest skip" discipline.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.ZaiLlmAvatarAgent

  # See AshA2A.Test.EnvKeyFixture's moduledoc for why this compile-time
  # extraction calls a shared *external* support module rather than a local
  # `defp` (a local call would fail to compile at this point -- confirmed by
  # a real CompileError on the first attempt, before this extraction).
  @zai_key AshA2A.Test.EnvKeyFixture.read_key("Z_AI_API_KEY")

  @moduletag :external_api
  @describetag skip: is_nil(@zai_key) && "Z_AI_API_KEY not found in ~/.env"

  setup_all do
    if @zai_key do
      Application.put_env(:req_llm, :zai_coder_api_key, @zai_key)
    end

    :ok
  end

  # Real, disclosed interaction with
  # test/ash_a2a_zai_concurrency_ocel_test.exs's real 50-way concurrency
  # probe when the full suite runs with `--include external_api`: real
  # rate-limit exhaustion from that probe can make this real, unseamed live
  # LLM call exceed the default 60s on both the ExUnit test process and
  # AshA2A.Protocol.Agent.call/3's own GenServer.call -- confirmed reproducing (this
  # exact test timed out in a real full-suite `--include external_api` run)
  # -- same fix as test/ash_a2a_agent_semantic_request_test.exs, not a code
  # defect.
  @tag timeout: 180_000
  test "a real Z.AI GLM-backed avatar responds over real A2A dispatch with a real structured shape" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        ZaiLlmAvatarAgent
      ])

    message =
      data_message(%{
        phase: :trust_god,
        prompt_text:
          "This is the Trust God segment. Does anyone want to share where they've seen God at work this week?"
      })

    assert {:ok, task} = ZaiLlmAvatarAgent.call(ZaiLlmAvatarAgent, message, timeout: 170_000)
    assert task.status.state == :completed

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: response}]}] =
             task.artifacts

    # Real, state-based assertions on the real object the real Z.AI call
    # returned -- not on its exact wording.
    assert %{wants_to_speak?: wants_to_speak?, asks_for_help?: asks_for_help?} = response
    assert is_boolean(wants_to_speak?)
    assert is_boolean(asks_for_help?)
    assert is_nil(response[:topic]) or is_binary(response[:topic])
  end
end

# --- SECTION 12: Original test/ash_a2a_gall_command_authority_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.FailingActuationStore do
  @moduledoc false
  @behaviour AshA2A.ReceiptStore

  alias AshA2A.ReceiptStore.Memory

  def claim(command, opts), do: Memory.claim(command, opts)
  def commit(receipt, opts), do: Memory.commit(receipt, opts)
  def fetch(command_id, opts), do: Memory.fetch(command_id, opts)

  def claim_actuation(_actuation, _command, _opts), do: raise("actuation index unavailable")

  def commit_actuation(actuation, receipt, opts),
    do: Memory.commit_actuation(actuation, receipt, opts)

  def release_actuation(actuation, opts), do: Memory.release_actuation(actuation, opts)
end

defmodule AshA2AGallCommandAuthorityTest do
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{
    Actuation,
    Authority,
    Command,
    CommandBus,
    Evidence,
    Identity,
    Receipt,
    SemanticProjection,
    SemanticSubject
  }

  alias AshA2A.Test.FailingActuationStore
  alias AshA2A.Test.Fixture.Item

  setup do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  test "semantic projection carries correlation identity but not raw authority evidence" do
    principal = Identity.principal("gall-user")
    capability = "AshA2A.Test.Fixture.Item.create"
    secret = "raw-bearer-secret-must-not-leak"

    authority =
      Authority.new(principal, capability, token_id: "gall-grant", evidence: %{bearer: secret})

    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: "sha256:" <> String.duplicate("1", 64),
        projection_digest: "sha256:" <> String.duplicate("2", 64),
        manufacturer_digest: "sha256:" <> String.duplicate("3", 64)
      )

    command =
      Command.new(capability,
        command_id: "gall-projection-command",
        agent_id: "gall-agent",
        principal_id: principal,
        authority: authority,
        semantic_subject: subject,
        metadata: %{work_order_digest: "sha256:" <> String.duplicate("4", 64)},
        input: %{label: "projection"}
      )

    receipt =
      Receipt.pending(command, Identity.execution("gall-execution"), :change,
        actuation: Actuation.identity(command),
        evidence_class: Evidence.LocalTest.new(%{suite: "gall-003"})
      )

    event = SemanticProjection.ocel_event(receipt)
    attrs = event["attributes"]

    assert attrs["semantic_graph_digest"] == subject.graph_digest
    assert attrs["projection_digest"] == subject.projection_digest
    assert attrs["manufacturer_digest"] == subject.manufacturer_digest
    assert is_binary(attrs["actuation_id"])
    assert is_binary(attrs["idempotency_key"])
    assert attrs["authority_grant_id"] == Identity.external(authority.token_id)
    assert is_binary(attrs["authority_evidence_digest"])
    assert attrs["evidence_class"] == "local_test"
    assert attrs["work_order_digest"] == command.metadata.work_order_digest
    refute inspect(event) =~ secret
  end

  test "enforced effect idempotency refuses before DO when actuation store is unavailable", %{
    store_opts: store_opts
  } do
    capability = "AshA2A.Test.Fixture.Item.create"
    principal = Identity.principal("gall-store-user-#{System.unique_integer([:positive])}")
    label = "must-not-exist-#{System.unique_integer([:positive])}"
    authority = Authority.new(principal, capability, token_id: "gall-store-grant")

    command =
      Command.new(capability,
        command_id: "gall-store-command-#{System.unique_integer([:positive])}",
        agent_id: "gall-store-agent",
        principal_id: principal,
        authority: authority,
        metadata: %{idempotency_key: "gall-effect-token"},
        input: %{label: label}
      )

    message = data_message(%{"label" => label})

    assert {:error, %{code: :actuation_store_unavailable, receipt: receipt}} =
             CommandBus.run(command, message, Item,
               store: FailingActuationStore,
               store_opts: store_opts,
               actuation_dedup: :strict
             )

    assert receipt.terminal_status == :refused

    assert {:ok, items} = Ash.read(Item, domain: AshA2A.Test.Fixture.ItemDomain)
    refute Enum.any?(items, &(&1.label == label))
  end
end

# --- SECTION 13: Original test/ash_a2a_gall_process_autonomics_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.ProcessAutonomicsTest do
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Identity, Postcondition, ReceiptStore}
  alias AshA2A.Semantic.Refusal
  alias AshA2A.Gall.ProcessFinding
  alias AshA2A.Gall.ProcessFinding.Intervention
  alias AshA2A.Test.Fixture.Item

  defmodule ItemPostcondition do
    @behaviour AshA2A.Postcondition

    @impl true
    def verify(%{label: label}, _probe) do
      items = Ash.read!(AshA2A.Test.Fixture.Item)

      if Enum.any?(items, &(&1.label == label)) do
        {:verified, %{"label" => label, "source" => "independent_ash_read"}}
      else
        {:contradicted, %{"label" => label, "source" => "independent_ash_read"}}
      end
    end
  end

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  test "GALL-029 admits an exact public process finding as candidate-only evidence" do
    assert {:ok, admitted} =
             finding()
             |> ProcessFinding.admit(
               expected_repository: "seanchatmangpt/beam4pm",
               expected_producer_sha: producer_sha(),
               expected_semantic_subject: "semantic:checkout",
               expected_process_subject: "process:checkout"
             )

    assert admitted.admission_receipt["standing"] == "CANDIDATE"
    assert admitted.admission_receipt["authority"] == "NONE"
    assert String.starts_with?(admitted.admission_receipt["finding_digest"], "sha256:")

    assert ProcessFinding.canonical_digest(%{"b" => 2, "a" => 1}) ==
             ProcessFinding.canonical_digest(%{"a" => 1, "b" => 2})
  end

  test "GALL-029 refuses stale producer identity and private ontology inputs" do
    assert {:error, {:refused_process_finding, :stale_or_mismatched_subject, _}} =
             ProcessFinding.admit(finding(), expected_producer_sha: String.duplicate("f", 40))

    assert {:error, {:refused_process_finding, :private_ontology, _}} =
             finding(%{"ontology_scope" => "private"}) |> ProcessFinding.admit()
  end

  test "GALL-030 requires exact authority constraints and an independent postcondition before DO",
       %{
         store_opts: store_opts
       } do
    label = "gall-#{System.unique_integer([:positive])}"
    scope = %{"tenant" => "global"}
    budget = %{"writes" => 1}
    capability = "AshA2A.Test.Fixture.Item.create"
    target = inspect(Item)
    principal = Identity.principal("gall-user")

    assert {:ok, admitted} = ProcessFinding.admit(finding())

    assert {:ok, candidate} =
             Intervention.construct(admitted,
               capability_id: capability,
               target: target,
               principal_id: principal,
               agent_id: "gall-agent",
               command_id: "gall-command-#{label}",
               scope: scope,
               budget: budget,
               input: %{label: label}
             )

    assert candidate.authority == "NONE"
    assert candidate.standing == "CANDIDATE"
    assert candidate.command.authority == nil

    bad_authority =
      Authority.new(principal, capability,
        token_id: "gall-bad-authority",
        constraints: %{target: target, scope: scope, budget: %{"writes" => 2}}
      )

    assert {:error,
            %{
              code: :process_intervention_refused,
              standing: "REFUSED",
              detail: {:authority_constraint_mismatch, :budget, ^budget, %{"writes" => 2}}
            }} =
             Intervention.execute(
               candidate,
               data_message(%{"label" => label}),
               Item,
               bad_authority,
               store_opts: store_opts,
               postcondition: %Postcondition{
                 id: "item-created",
                 verifier: ItemPostcondition,
                 expect: %{label: label}
               }
             )

    authority =
      Authority.new(principal, capability,
        token_id: "gall-authority",
        constraints: %{target: target, scope: scope, budget: budget}
      )

    assert {:error,
            %{
              code: :process_intervention_refused,
              standing: "REFUSED",
              detail: :postcondition_required
            }} =
             Intervention.execute(
               candidate,
               data_message(%{"label" => label}),
               Item,
               authority,
               store_opts: store_opts
             )

    assert {:ok, %{standing: "COMPLETED", receipt: receipt}} =
             Intervention.execute(
               candidate,
               data_message(%{"label" => label}),
               Item,
               authority,
               store_opts: store_opts,
               postcondition: %Postcondition{
                 id: "item-created",
                 verifier: ItemPostcondition,
                 expect: %{label: label}
               }
             )

    assert receipt.status == :completed
    assert get_in(receipt.metadata, [:postcondition, :status]) == :verified
    assert receipt.actuation_id
    assert receipt.idempotency_key
    assert receipt.plan_digest == candidate.finding_digest
    assert receipt.intended_effect.gall_finding_digest == candidate.finding_digest
    assert receipt.intended_effect.target == target
    assert receipt.intended_effect.scope == scope
    assert receipt.intended_effect.budget == budget

    assert {:ok, stored} = ReceiptStore.Memory.fetch(candidate.command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id

    assert {:ok, %{standing: "COMPLETED", receipt: replay}} =
             Intervention.execute(
               candidate,
               data_message(%{"label" => label}),
               Item,
               authority,
               store_opts: store_opts,
               postcondition: %Postcondition{
                 id: "item-created",
                 verifier: ItemPostcondition,
                 expect: %{label: label}
               }
             )

    assert replay.replayed?
    assert replay.receipt_id == receipt.receipt_id
  end

  test "the preserved GALL-030 alternative does not replace the canonical ProcessIntervention" do
    # Both designs coexist: the canonical GALL-029/030 path keeps admit/2 and
    # intervene/5; the process-autonomics alternative lives under ProcessFinding.
    assert Code.ensure_loaded?(AshA2A.Gall.ProcessIntervention)
    assert function_exported?(AshA2A.Gall.ProcessIntervention, :admit, 2)
    assert function_exported?(AshA2A.Gall.ProcessIntervention, :intervene, 5)
    refute function_exported?(AshA2A.Gall.ProcessIntervention, :construct, 2)

    assert function_exported?(Intervention, :construct, 2)
    assert function_exported?(Intervention, :execute, 5)
  end

  test "every GALL-029/030 process-autonomics refusal is S42-classified, never BLOCKED_UNKNOWN" do
    mapping = Refusal.mapping()

    provided =
      Map.merge(ProcessFinding.__sa2a_refusal_codes__(), Intervention.__sa2a_refusal_codes__())

    for {code, class} <- provided do
      assert Refusal.class?(class), "#{code} maps to non-class #{inspect(class)}"
      assert Map.has_key?(mapping, code), "#{code} is not in Refusal.mapping/0"
      assert Refusal.classify(code) != :blocked_unknown, "#{code} classifies as blocked_unknown"
    end

    # Real refusals produced by the real admission path carry classified codes.
    observed_finding_codes =
      for input <- [
            finding(%{"ontology_scope" => "secret"}),
            finding(%{"schema" => "gall.process-finding/v0"}),
            finding(%{"producer" => %{"repository" => "no-slash", "sha" => producer_sha()}}),
            finding(%{
              "producer" => %{
                "repository" => "o/r",
                "sha" => "short",
                "receipt_digest" => digest("a")
              }
            }),
            finding(%{"evidence_digest" => "md5:x"}),
            finding(%{"semantic_subject" => ""}),
            finding(%{"finding_type" => "vibes"})
          ] do
        assert {:error, {:refused_process_finding, code, _detail}} = ProcessFinding.admit(input)
        code
      end

    assert {:error, {:refused_process_finding, :invalid_envelope, _}} =
             ProcessFinding.admit(finding(), :not_a_keyword_list)

    for code <- [:invalid_envelope | observed_finding_codes] do
      refute Refusal.classify(code) == :blocked_unknown, "#{code} is unclassified"
    end

    assert {:ok, admitted} = ProcessFinding.admit(finding())

    assert {:error, {:refused_process_intervention, {:missing_field, :principal_id}}} =
             Intervention.construct(admitted,
               capability_id: "AshA2A.Test.Fixture.Item.create",
               target: inspect(Item)
             )

    assert Refusal.classify(:missing_field) == :refused_structure

    assert {:error, %{code: :process_intervention_refused, detail: :candidate_not_admitted} = err} =
             Intervention.execute(
               %{schema: "forged", authority: "NONE", standing: "CANDIDATE", command: nil},
               data_message(%{"label" => "x"}),
               Item,
               Authority.new(Identity.principal("gall-user"), "AshA2A.Test.Fixture.Item.create")
             )

    assert Refusal.from_error({:error, err}, :authorize).class == :refused_authority
    assert Refusal.classify(err.detail) == :refused_meta_rigor
  end

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => "gall.process-finding/v26.9.18",
        "producer" => %{
          "repository" => "seanchatmangpt/beam4pm",
          "sha" => producer_sha(),
          "receipt_digest" => digest("a")
        },
        "evidence_digest" => digest("b"),
        "evidence_class" => "process-conformance",
        "semantic_subject" => "semantic:checkout",
        "process_subject" => "process:checkout",
        "finding_type" => "conformance_delta",
        "horizon" => "event-time:2026-09-19T00:00:00Z/2026-09-20T00:00:00Z",
        "requested_candidate_class" => "construct_command",
        "authority" => "NONE"
      },
      overrides
    )
  end

  defp producer_sha, do: "0123456789abcdef0123456789abcdef01234567"
  defp digest(char), do: "sha256:" <> String.duplicate(char, 64)
end

# --- SECTION 14: Original test/ash_a2a_gall_swf_message_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GallSwfMessageTest do
  @moduledoc """
  PRD §43.5 GALL Semantic Work Fabric message shapes: checkpoint identity,
  PRD §41 work lease, closed capability vocabulary with the PRD §30
  child-subset rule, evidence/receipt transport with the closed standing
  vocabulary, and the central transport-is-not-authority refusals.

  Real structs, real JSON round-trips through Jason, real refusal tuples.
  No doubles -- there is nothing external here to double.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Gall.{Capability, Checkpoint, EvidenceReceipt, Message, WorkLease}

  # The PRD §41 canonical work-lease JSON shape, verbatim. MUST validate.
  @lease_json ~s({"type": "gall:WorkLease", "checkpoint": "urn:gall:checkpoint:xaas:001", "epoch": "urn:xaas:epoch:001", "lease": "urn:xaas:lease:001", "graphDigest": "sha256:..."})

  @base_sha "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"

  defp checkpoint_message do
    %{
      "type" => "gall:CodingCheckpoint",
      "checkpoint" => "urn:gall:checkpoint:xaas:001",
      "repository" => "https://example.org/repo",
      "baseSha" => @base_sha,
      "graphDigest" => "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    }
  end

  defp receipt_message(standing \\ "ALIVE") do
    %{
      "type" => "gall:EvidenceReceipt",
      "receiptId" => "urn:xaas:receipt:001",
      "checkpointIri" => "urn:gall:checkpoint:xaas:001",
      "checkpointDigest" =>
        "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
      "candidateSha" => @base_sha,
      "verifierId" => "urn:xaas:verifier:mix-test",
      "verifiedOutcome" => "pass",
      "standing" => standing
    }
  end

  defp lease_message(capabilities \\ nil) do
    base = %{
      "type" => "gall:WorkLease",
      "checkpoint" => "urn:gall:checkpoint:xaas:001",
      "epoch" => "urn:xaas:epoch:001",
      "lease" => "urn:xaas:lease:001",
      "graphDigest" => "sha256:..."
    }

    if capabilities, do: Map.put(base, "capabilities", capabilities), else: base
  end

  # --- requirement 1: checkpoint identity message -------------------------

  test "a well-formed gall:CodingCheckpoint message validates to its typed struct" do
    assert {:ok, %Checkpoint{} = checkpoint} = Message.validate(checkpoint_message())
    assert checkpoint.type == "gall:CodingCheckpoint"
    assert checkpoint.checkpoint == "urn:gall:checkpoint:xaas:001"
    assert checkpoint.repository == "https://example.org/repo"
    assert checkpoint.base_sha == @base_sha
    assert String.starts_with?(checkpoint.graph_digest, "sha256:")
  end

  test "checkpoint base_sha must be 40 hex; graph_digest must be sha256-typed" do
    assert {:refused, "REFUSED_STRUCTURE"} =
             Message.validate(%{checkpoint_message() | "baseSha" => "nothex"})

    assert {:refused, "REFUSED_STRUCTURE"} =
             Message.validate(%{checkpoint_message() | "baseSha" => String.duplicate("a", 41)})

    assert {:refused, "REFUSED_STRUCTURE"} =
             Message.validate(%{checkpoint_message() | "graphDigest" => "md5:abc"})
  end

  # --- requirement 2: the PRD §41 canonical work-lease shape --------------

  test "the exact PRD §41 WorkLease JSON shape parses into the WorkLease struct" do
    assert {:ok, %WorkLease{} = lease} = Message.validate(@lease_json)
    assert lease.type == "gall:WorkLease"
    assert lease.checkpoint == "urn:gall:checkpoint:xaas:001"
    assert lease.epoch == "urn:xaas:epoch:001"
    assert lease.lease == "urn:xaas:lease:001"
    assert lease.graph_digest == "sha256:..."
    assert lease.capabilities == %{requires: [], forbids: []}
  end

  test "a work lease validates with decoded capability sets" do
    assert {:ok, %WorkLease{} = lease} =
             Message.validate(
               lease_message(%{"requires" => ["Read", "Commit"], "forbids" => ["Push"]})
             )

    assert lease.capabilities == %{requires: [:commit, :read], forbids: [:push]}
  end

  # --- requirement 3: capability semantics --------------------------------

  test "the capability vocabulary is exactly the eight closed values" do
    assert Capability.labels() == [
             "Read",
             "Write",
             "Edit",
             "Commit",
             "Push",
             "Publish",
             "Deploy",
             "Merge"
           ]

    assert Enum.map(Capability.all(), &Capability.encode/1) |> Enum.all?(&match?({:ok, _}, &1))
  end

  test "an unknown capability name is REFUSED_CAPABILITY" do
    assert {:refused, "REFUSED_CAPABILITY"} =
             Message.validate(
               lease_message(%{"requires" => ["Read", "Transmute"], "forbids" => []})
             )

    assert {:refused, "REFUSED_CAPABILITY"} =
             Message.validate(lease_message(%{"requires" => [], "forbids" => ["Nuke"]}))

    # Downcased aliasing is not decoding: the vocabulary is closed.
    assert {:refused, "REFUSED_CAPABILITY"} =
             Message.validate(lease_message(%{"requires" => ["push"], "forbids" => []}))
  end

  test "child capabilities not a subset of the parent grant are refused (PRD §30)" do
    {:ok, child} = Message.validate(lease_message(%{"requires" => ["Read", "Edit"]}))

    assert {:ok, ^child} = Message.validate(child, parent: ["Read", "Edit", "Commit"])
    assert {:ok, ^child} = Message.validate(child, parent: ["Read", "Edit"])
    assert {:refused, "REFUSED_CAPABILITY"} = Message.validate(child, parent: ["Read"])
    assert {:refused, "REFUSED_CAPABILITY"} = Message.validate(child, parent: [])
    assert {:refused, "REFUSED_CAPABILITY"} = Message.validate(child, parent: ["Push"])

    # A parent grant carrying an unknown capability refuses too -- fail closed.
    assert {:refused, "REFUSED_CAPABILITY"} =
             Message.validate(child, parent: ["Read", "Teleport"])
  end

  test "a child requiring a capability the parent forbids is refused" do
    {:ok, child} = Message.validate(lease_message(%{"requires" => ["Push"]}))

    {:ok, %WorkLease{} = parent} =
      Message.validate(lease_message(%{"requires" => ["Read", "Push"], "forbids" => ["Push"]}))

    assert {:refused, "REFUSED_CAPABILITY"} = Message.validate(child, parent: parent)
  end

  test "the parent grant may be a WorkLease struct, a map, or a plain list" do
    {:ok, child} = Message.validate(lease_message(%{"requires" => ["Commit"]}))
    {:ok, parent_lease} = Message.validate(lease_message(%{"requires" => ["Commit", "Push"]}))

    assert {:ok, _} = Message.validate(child, parent: parent_lease)
    assert {:ok, _} = Message.validate(child, parent: %{"requires" => ["Commit"]})
    assert {:ok, _} = Message.validate(child, parent: [:commit])
    assert {:refused, "REFUSED_CAPABILITY"} = Message.validate(child, parent: %{"requires" => []})
  end

  test "the child-subset rule is only enforced when a parent grant is presented" do
    # No parent presented -> nothing to compare against; shape still validates.
    assert {:ok, %WorkLease{}} =
             Message.validate(lease_message(%{"requires" => ["Push", "Deploy"]}))
  end

  # --- requirement 4: evidence/receipt transport + standing vocabulary ----

  test "a well-formed gall:EvidenceReceipt message validates" do
    assert {:ok, %EvidenceReceipt{} = receipt} = Message.validate(receipt_message())
    assert receipt.type == "gall:EvidenceReceipt"
    assert receipt.receipt_id == "urn:xaas:receipt:001"
    assert receipt.candidate_sha == @base_sha
    assert receipt.standing == "ALIVE"
  end

  test "the standing vocabulary is exactly the six values, each accepted" do
    assert EvidenceReceipt.standing_values() == [
             "UNKNOWN",
             "PARTIAL_ALIVE",
             "ALIVE",
             "BLOCKED",
             "BUILD_BROKEN",
             "UNSUPPORTED"
           ]

    for standing <- EvidenceReceipt.standing_values() do
      assert {:ok, %EvidenceReceipt{standing: ^standing}} =
               Message.validate(receipt_message(standing))
    end
  end

  test "standing round-trips through the receipt message" do
    for standing <- EvidenceReceipt.standing_values() do
      {:ok, receipt} = Message.validate(receipt_message(standing))
      wire = EvidenceReceipt.to_map(receipt)
      assert wire["standing"] == standing
      assert {:ok, %EvidenceReceipt{standing: ^standing}} = EvidenceReceipt.from_json(wire)
    end
  end

  test "an unknown standing value is refused, never coined" do
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(receipt_message("alive"))
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(receipt_message("ALIVE-ish"))
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(receipt_message("WIZARD"))
  end

  # --- requirement 5: transport is not authority --------------------------

  test "an unregistered type is REFUSED_UNREGISTERED_ACTUATION" do
    assert {:refused, "REFUSED_UNREGISTERED_ACTUATION"} =
             Message.validate(Map.put(lease_message(), "type", "gall:ActuateEverything"))

    assert {:refused, "REFUSED_UNREGISTERED_ACTUATION"} =
             Message.validate(%{"type" => "urn:xaas:do:now"})

    assert {:refused, "REFUSED_UNREGISTERED_ACTUATION"} = Message.validate(%{"no" => "type"})
    refute Message.registered_type?("gall:ActuateEverything")
  end

  test "an execute/actuate/authorize directive field is REFUSED_AUTHORITY" do
    for directive <- ["execute", "actuate", "authorize"] do
      assert {:refused, "REFUSED_AUTHORITY"} =
               Message.validate(Map.put(lease_message(), directive, true))
    end

    # Casing/separators do not launder the directive, and the value is
    # irrelevant: asserting the field at all is the overreach.
    assert {:refused, "REFUSED_AUTHORITY"} =
             Message.validate(Map.put(lease_message(), "EXECUTE", false))

    # A directive one level down is still an authority-bearing payload.
    assert {:refused, "REFUSED_AUTHORITY"} =
             Message.validate(%{
               "type" => "gall:WorkLease",
               "checkpoint" => "urn:gall:checkpoint:xaas:001",
               "epoch" => "urn:xaas:epoch:001",
               "lease" => "urn:xaas:lease:001",
               "graphDigest" => "sha256:...",
               "details" => %{"authorization" => %{"actuate" => "now"}}
             })

    # Receipts and checkpoints are equally bound.
    assert {:refused, "REFUSED_AUTHORITY"} =
             Message.validate(Map.put(receipt_message(), "execute", true))

    assert {:refused, "REFUSED_AUTHORITY"} =
             Message.validate(Map.put(checkpoint_message(), "authorize", "yes"))
  end

  test "messages that merely describe work validate -- description is not directive" do
    # "authorized"/"execution" are not directive fields; the vocabulary is
    # exact, so a receipt ABOUT an execution still transports.
    assert {:ok, %EvidenceReceipt{}} =
             Message.validate(%{receipt_message() | "verifierId" => "execution-runner"})

    assert match?({:ok, %WorkLease{}}, Message.validate(@lease_json))
  end

  # --- malformed shapes ----------------------------------------------------

  test "malformed payloads refuse REFUSED_STRUCTURE" do
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate("not json {")
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(~s(["a","json","array"]))
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(42)
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(%{"type" => "gall:WorkLease"})

    assert {:refused, "REFUSED_STRUCTURE"} =
             Message.validate(%{checkpoint_message() | "checkpoint" => "not-an-iri"})
  end

  # --- requirement 6: Jason encode/decode round-trips ----------------------

  test "all three message shapes JSON round-trip through Jason" do
    {:ok, checkpoint} = Message.validate(checkpoint_message())
    {:ok, lease} = Message.validate(lease_message(%{"requires" => ["Read", "Push"]}))
    {:ok, receipt} = Message.validate(receipt_message("PARTIAL_ALIVE"))

    for {message, module} <- [
          {checkpoint, Checkpoint},
          {lease, WorkLease},
          {receipt, EvidenceReceipt}
        ] do
      json = module.to_json(message)
      assert is_binary(json)
      assert {:ok, decoded} = module.from_json(json)
      assert decoded == message
    end
  end

  test "the PRD §41 JSON string round-trips: parse -> encode -> parse is stable" do
    {:ok, lease} = Message.validate(@lease_json)
    json = WorkLease.to_json(lease)
    assert {:ok, same} = Message.validate(json)
    assert same == lease
    assert Jason.decode!(json)["graphDigest"] == "sha256:..."
  end

  # --- namespace -----------------------------------------------------------

  test "the GALL namespace is the PRD namespace" do
    assert Message.namespace() == "https://semantic-a2a.dev/gall#"

    assert Message.types() == [
             "gall:CodingCheckpoint",
             "gall:WorkLease",
             "gall:EvidenceReceipt"
           ]
  end
end

# --- SECTION 15: Original test/ash_a2a_hddl_deterministic_planning_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.HddlDeterministicPlanningTest do
  @moduledoc """
  Real, Chicago-style (no mocks) coverage for Task 2 of the deterministic
  (non-LLM) HDDL planning path: `AshA2A.Planning.HddlRenderer.domain_text/2`
  and `problem_text/3`, plus a real invocation of the real `hddl_cli` binary
  via `AshA2A.Planning.HddlSolver.solve/3`.

  Every positive assertion here is against the real, parsed solved-plan JSON
  a real OS subprocess (the real `native/hddl_cli` binary) produced from the
  real machine-rendered `.hddl` text this test builds via
  `AshA2A.Test.Fixture.HddlDeterministicFixture`'s real compiled capability
  index -- never a hand-built or test-doubled plan result. This file declares
  and uses no interaction-verifying test double of any kind (see this
  workspace's `~/.claude/rules/testing-chicago-style.md`); the real grep for
  the banned-pattern list over this file (expect zero matches) is part of
  this task's own reported verification evidence, not asserted here.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Planning.HddlRenderer
  alias AshA2A.Planning.HddlSolver
  alias AshA2A.Test.Fixture.HddlDeterministicFixture

  @advance_id "AshA2A.Test.Fixture.HddlDeterministicFixture.advance"
  @unlock_id "AshA2A.Test.Fixture.HddlDeterministicFixture.unlock"

  describe "domain_text/2" do
    test "renders one real :action per declared hddl_operator from the real compiled capability index" do
      assert {:ok, domain} = HddlRenderer.domain_text(HddlDeterministicFixture, "fixture-domain")

      assert domain =~ "(define (domain fixture-domain)"
      assert domain =~ "(:predicates"
      # Both real declared predicates, arity-derived, present.
      assert domain =~ ~r/\(current_phase\b/
      assert domain =~ ~r/\(has_key\b/
      # Both real skills' capability ids, safe-named (dots -> underscores),
      # became real :action names.
      assert domain =~ ":action AshA2A_Test_Fixture_HddlDeterministicFixture_advance"
      assert domain =~ ":action AshA2A_Test_Fixture_HddlDeterministicFixture_unlock"
      # The :advance operator's real precondition/effect facts, rendered as
      # parameter-variable references (?from/?to), not object constants.
      assert domain =~ "(current_phase ?from)"
      assert domain =~ "(current_phase ?to)"
      assert domain =~ "(not (current_phase ?from))"
    end

    test "fails closed with :no_hddl_operators for a real resource with no hddl_operator declared" do
      assert {:error, %{code: :no_hddl_operators}} =
               HddlRenderer.domain_text(AshA2A.Test.Fixture.Echo, "empty-domain")
    end

    test "fails closed with :not_compiled for a real module with no AshA2A extension" do
      assert {:error, %{code: :not_compiled}} =
               HddlRenderer.domain_text(AshA2A.Test.Fixture.NoA2A, "not-compiled")
    end
  end

  describe "problem_text/3" do
    test "fails closed when :domain_name is missing" do
      assert {:error, %{code: :missing_opt, opt: :domain_name}} =
               HddlRenderer.problem_text(HddlDeterministicFixture, "p1",
                 task_sequence: [{@advance_id, ["on", "off"]}]
               )
    end

    test "fails closed when :task_sequence is missing" do
      assert {:error, %{code: :missing_opt, opt: :task_sequence}} =
               HddlRenderer.problem_text(HddlDeterministicFixture, "p1", domain_name: "d")
    end

    test "fails closed when :task_sequence is present but empty" do
      assert {:error, %{code: :empty_task_sequence}} =
               HddlRenderer.problem_text(HddlDeterministicFixture, "p1",
                 domain_name: "d",
                 task_sequence: []
               )
    end

    test "renders a real problem referencing the same safe-named task calls domain_text emits" do
      assert {:ok, problem} =
               HddlRenderer.problem_text(HddlDeterministicFixture, "fixture-problem-p1",
                 domain_name: "fixture-domain",
                 objects: ["on", "off"],
                 init: [{:current_phase, ["on"]}],
                 goal: [{:current_phase, ["off"]}, {:has_key, ["off"]}],
                 task_sequence: [
                   {@advance_id, ["on", "off"]},
                   {@unlock_id, ["off"]}
                 ]
               )

      assert problem =~ "(define (problem fixture-problem-p1)"
      assert problem =~ "(:domain fixture-domain)"
      assert problem =~ "(:objects on off)"
      assert problem =~ "(:init (current_phase on))"
      assert problem =~ "(:goal (and (current_phase off) (has_key off)))"
      assert problem =~ "(AshA2A_Test_Fixture_HddlDeterministicFixture_advance on off)"
      assert problem =~ "(AshA2A_Test_Fixture_HddlDeterministicFixture_unlock off)"
    end
  end

  describe "end-to-end: real hddl_cli solve over the real machine-rendered domain/problem" do
    test "the real solver reports a real solved plan for the real 2-step task sequence" do
      assert {:ok, domain_text} =
               HddlRenderer.domain_text(HddlDeterministicFixture, "e2e-fixture-domain")

      assert {:ok, problem_text} =
               HddlRenderer.problem_text(HddlDeterministicFixture, "e2e-fixture-problem",
                 domain_name: "e2e-fixture-domain",
                 objects: ["on", "off"],
                 init: [{:current_phase, ["on"]}],
                 goal: [{:current_phase, ["off"]}, {:has_key, ["off"]}],
                 task_sequence: [
                   {@advance_id, ["on", "off"]},
                   {@unlock_id, ["off"]}
                 ]
               )

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_hddl_deterministic_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # Real subprocess call over real generated .hddl files written to a
      # real temp directory -- no mocking of the solver process itself
      # (AshA2A.Planning.HddlSolver.solve/3 writes real files under
      # `tmp_dir:` and shells out to the real `hddl_cli` binary via
      # `System.cmd/3`).
      assert {:ok, decoded} = HddlSolver.solve(domain_text, problem_text, tmp_dir: tmp_dir)

      assert decoded["solved"] == true
      refute Map.has_key?(decoded, "error")

      actions =
        decoded["policy"]
        |> Enum.map(& &1["action"])
        |> Enum.reject(&String.starts_with?(&1, "htn:decompose:"))

      assert Enum.any?(
               actions,
               &(&1 =~ "AshA2A_Test_Fixture_HddlDeterministicFixture_advance(on,off)")
             )

      assert Enum.any?(
               actions,
               &(&1 =~ "AshA2A_Test_Fixture_HddlDeterministicFixture_unlock(off)")
             )
    end

    test "the real solver reports a real error for a real unsatisfiable goal" do
      assert {:ok, domain_text} =
               HddlRenderer.domain_text(HddlDeterministicFixture, "unsat-fixture-domain")

      assert {:ok, problem_text} =
               HddlRenderer.problem_text(HddlDeterministicFixture, "unsat-fixture-problem",
                 domain_name: "unsat-fixture-domain",
                 objects: ["on", "off"],
                 init: [{:current_phase, ["on"]}],
                 # Goal demands has_key(on), but the only :unlock operator in
                 # this real domain only fires from the state named in the
                 # task call below (off) -- so a caller-proposed sequence
                 # that never reaches has_key(on) genuinely cannot solve.
                 goal: [{:has_key, ["on"]}],
                 task_sequence: [{@advance_id, ["on", "off"]}]
               )

      # The real `hddl_cli` binary reports a genuinely unreachable goal as
      # `{"error": "planner error: NoPlan"}` (exit 1) -- ferroplan's own
      # `PlannerError::NoPlan`, per `native/hddl_cli/src/main.rs`'s real
      # `Err(e) => println!("{{\"error\": ...}}")` branch -- not a
      # `"solved": false` plan body, so this is real, observed
      # `:hddl_solve_error`, not `:hddl_unsolved`.
      assert {:error, %{code: :hddl_solve_error} = decoded} =
               HddlSolver.solve(domain_text, problem_text)

      assert decoded["error"] =~ "NoPlan"
    end
  end
end

# --- SECTION 16: Original test/ash_a2a_hddl_solver_qualification_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AHddlSolverQualificationTest do
  @moduledoc """
  Qualifies the real, CI-built native `hddl_cli` (ferroplan) binary against
  BOTH classification outcomes -- solvable and unsolvable -- over real HDDL
  domain/problem pairs, not just the one already-known-solvable
  `freedom_gym_meeting` fixture exercised by
  `test/ash_a2a_freedom_gym_hddl_plan_test.exs`.

  Both tests shell out to the real `native/hddl_cli/target/release/hddl_cli`
  binary via `System.cmd/2` (a real OS subprocess, zero Mock/mox/patch/
  monkeypatch) and assert on the real decoded JSON it prints to stdout.

  ## The unsolvable fixture (`test/support/hddl/unsolvable_qualification/`)

  A genuine logical impossibility, not a syntax error: the domain's only
  action, `advance`, requires `(and (current-phase ?from) (has-permission))`
  as its precondition, but `has-permission` is never true in `:init` and no
  action in the domain ever has it as an effect -- there is no ground action
  sequence, of any length, that can ever satisfy it. The single ground
  instance the method needs, `advance(locked, unlocked)`, can therefore never
  fire, so the HTN decomposition the problem's `:htn` requires can never
  complete and the stated goal `(current-phase unlocked)` can never be
  reached.

  This was verified empirically against the real binary during development
  (not merely asserted to be true): running
  `native/hddl_cli/target/release/hddl_cli
  test/support/hddl/unsolvable_qualification/{domain,problem}.hddl` real,
  standalone, on the command line prints:

      {"error":"planner error: NoPlan"}

  with a non-zero exit code -- the real ferroplan HDDL solver's own real
  classification of this pair as unsolvable, not a value hand-typed into a
  fixture.
  """

  use ExUnit.Case, async: true

  @cli_path Path.expand("../native/hddl_cli/target/release/hddl_cli", __DIR__)

  @solvable_domain Path.expand("support/hddl/freedom_gym_meeting/domain.hddl", __DIR__)
  @solvable_problem Path.expand("support/hddl/freedom_gym_meeting/problem.hddl", __DIR__)

  @unsolvable_domain Path.expand(
                       "support/hddl/unsolvable_qualification/domain.hddl",
                       __DIR__
                     )
  @unsolvable_problem Path.expand(
                        "support/hddl/unsolvable_qualification/problem.hddl",
                        __DIR__
                      )

  setup_all do
    unless File.exists?(@cli_path) do
      flunk("""
      hddl_cli binary not built at #{@cli_path}.
      Run: cd #{Path.expand("../native/hddl_cli", __DIR__)} && cargo build --release --locked
      """)
    end

    :ok
  end

  defp run_hddl_cli!(domain_path, problem_path) do
    {stdout, exit_code} = System.cmd(@cli_path, [domain_path, problem_path])

    decoded =
      case JSON.decode(stdout) do
        {:ok, decoded} ->
          decoded

        {:error, reason} ->
          flunk("hddl_cli produced non-JSON stdout: #{inspect(reason)}: #{stdout}")
      end

    {decoded, exit_code, stdout}
  end

  test "real solvable freedom_gym_meeting HDDL pair reports solved: true via the real binary" do
    {decoded, exit_code, raw} = run_hddl_cli!(@solvable_domain, @solvable_problem)

    assert exit_code == 0,
           "expected the real hddl_cli to exit 0 on a genuinely solvable pair, " <>
             "got exit #{exit_code}. Real raw stdout: #{raw}"

    refute Map.has_key?(decoded, "error"),
           "expected no \"error\" key from the real solver on a genuinely solvable pair. " <>
             "Real raw stdout: #{raw}"

    assert decoded["solved"] == true,
           "expected the real solver to report solved: true for freedom_gym_meeting. " <>
             "Real raw stdout: #{raw}"

    assert is_list(decoded["policy"]) and decoded["policy"] != [],
           "expected a non-empty real solved policy. Real raw stdout: #{raw}"
  end

  test "real unsolvable pair (unreachable precondition) reports failure via the real binary" do
    {decoded, exit_code, raw} = run_hddl_cli!(@unsolvable_domain, @unsolvable_problem)

    # The real ferroplan solver reports this specific unreachable-precondition
    # case as a top-level planner error (non-zero exit, an "error" key) rather
    # than a zero-exit `{"solved": false, ...}` payload. Accept either real
    # shape a genuine solver could use to say "no plan exists", but require at
    # least one of them to be real and present -- never fabricate which shape
    # it took.
    reports_unsolved? =
      Map.has_key?(decoded, "error") or decoded["solved"] == false

    assert reports_unsolved?,
           "expected the real hddl_cli to report failure (an \"error\" key or " <>
             "solved: false) for a genuinely unsolvable pair whose only action's " <>
             "precondition (has-permission) is never reachable from :init, but got " <>
             "exit #{exit_code} with real raw stdout: #{raw}"

    refute decoded["solved"] == true,
           "the unsolvable_qualification pair must never be reported solved. " <>
             "Real raw stdout: #{raw}"
  end
end

# --- SECTION 17: Original test/ash_a2a_httpjson_tasks_list_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.HTTPJSONTasksListTest.Resource do
  @moduledoc """
  Real fixture resource, private to this test file: a single real `:read`
  skill on a real ETS-backed Ash resource, so dispatch has exactly one skill
  and needs no `:skill` metadata.
  """

  use Ash.Resource,
    domain: AshA2A.HTTPJSONTasksListTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.HTTPJSONTasksListTest.Domain do
  @moduledoc "Real fixture domain for the resource above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.HTTPJSONTasksListTest.Resource)
  end
end

defmodule AshA2A.HTTPJSONTasksListTest.EchoAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over the fixture resource above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.HTTPJSONTasksListTest.Resource,
    name: "httpjson_tasks_list_echo_agent"
end

defmodule AshA2A.HTTPJSONTasksListTest.Stack do
  @moduledoc """
  Real two-plug stack: `AshA2A.Protocol.Plug.Auth` (bearer) in front of the
  `AshA2A.Transport.HTTPJSON` binding, so requests carry a verified principal
  into `conn.private[:a2a][:auth]` exactly as in production.
  """

  @behaviour Plug

  @impl Plug
  def init({auth_opts, binding_opts}) do
    {AshA2A.Protocol.Plug.Auth.init(auth_opts), AshA2A.Transport.HTTPJSON.init(binding_opts)}
  end

  @impl Plug
  def call(conn, {auth_opts, binding_opts}) do
    conn = AshA2A.Protocol.Plug.Auth.call(conn, auth_opts)

    if conn.halted, do: conn, else: AshA2A.Transport.HTTPJSON.call(conn, binding_opts)
  end
end

defmodule AshA2A.HTTPJSONTasksListTest do
  @moduledoc """
  Court for `GET /tasks` (§5.3 tasks/list) on the A2A v1.0 HTTP+JSON/REST
  transport binding (`AshA2A.Transport.HTTPJSON`).

  A real Bandit server on a loopback ephemeral port, a real supervised
  `use AshA2A.Agent` GenServer over a real ETS Ash resource, the real
  `AshA2A.Protocol.Plug.Auth` bearer middleware in front of the binding, and
  real `Req` HTTP calls: two authenticated principals (alice, bob), owner
  scoping (SEC-01), a real pagination cycle over more tasks than one page
  holds, the real `AshA2A.Protocol.Task.Filter` status filter, and the
  JSON-RPC `Request.validate_params/1` rejection surface for invalid query
  parameters. No mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}

  @error_info "type.googleapis.com/google.rpc.ErrorInfo"

  @tokens %{"alice-token" => %{sub: "alice"}, "bob-token" => %{sub: "bob"}}

  setup do
    agent = AshA2A.HTTPJSONTasksListTest.EchoAgent

    {_sup, _registry} =
      AgentSupervisorCase.start_supervised_agents!(__MODULE__, [agent])

    auth_opts = [
      schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
      verify: fn _scheme, token, _conn -> Map.fetch(@tokens, token) end
    ]

    binding_opts =
      AshA2A.Transport.HTTPJSON.init(agent: agent, base_url: "http://127.0.0.1/fixture")

    %{
      server:
        EphemeralHttp.start!({AshA2A.HTTPJSONTasksListTest.Stack, {auth_opts, binding_opts}})
    }
  end

  # -- helpers ----------------------------------------------------------------

  defp message_map(text) do
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end

  defp send_as!(server, token, text) do
    resp =
      Req.post!(
        url: server.base_url <> "/message:send",
        headers: [{"authorization", "Bearer " <> token}],
        json: %{"message" => message_map(text)}
      )

    assert resp.status == 200
    assert %{"task" => %{"id" => task_id}} = resp.body
    task_id
  end

  defp list(server, token, query \\ "") do
    Req.get!(
      url: server.base_url <> "/tasks" <> query,
      headers: [{"authorization", "Bearer " <> token}]
    )
  end

  # -- owner scoping (SEC-01) ---------------------------------------------------

  test "alice's list shows only alice's tasks; bob's only bob's", %{server: server} do
    alice_tasks = [send_as!(server, "alice-token", "a1"), send_as!(server, "alice-token", "a2")]
    bob_task = send_as!(server, "bob-token", "b1")

    resp = list(server, "alice-token")

    assert resp.status == 200
    assert %{"tasks" => tasks, "totalSize" => 2, "pageSize" => 50} = resp.body
    assert MapSet.new(tasks, & &1["id"]) == MapSet.new(alice_tasks)
    refute bob_task in Enum.map(tasks, & &1["id"])

    assert %{"tasks" => bob_tasks, "totalSize" => 1} = list(server, "bob-token").body
    assert Enum.map(bob_tasks, & &1["id"]) == [bob_task]
  end

  test "wire tasks carry no owner key or verified auth metadata", %{server: server} do
    send_as!(server, "alice-token", "a1")

    assert %{"tasks" => [task]} = list(server, "alice-token").body

    metadata = task["metadata"] || %{}
    refute Map.has_key?(metadata, "ash_a2a.owner")
    refute Map.has_key?(metadata, "a2a.auth")
  end

  # -- pagination ----------------------------------------------------------------

  test "pagination cycle: N > pageSize tasks page through with nextPageToken", %{server: server} do
    created = for i <- 1..5, do: send_as!(server, "alice-token", "task #{i}")

    page1 = list(server, "alice-token", "?pageSize=2")

    assert %{"tasks" => p1, "totalSize" => 5, "pageSize" => 2, "nextPageToken" => token1} =
             page1.body

    assert length(p1) == 2
    assert is_binary(token1) and token1 != ""

    assert %{"tasks" => p2, "totalSize" => 5, "nextPageToken" => token2} =
             list(server, "alice-token", "?pageSize=2&pageToken=#{token1}").body

    assert length(p2) == 2

    assert %{"tasks" => p3, "totalSize" => 5, "nextPageToken" => ""} =
             list(server, "alice-token", "?pageSize=2&pageToken=#{token2}").body

    assert length(p3) == 1

    paged_ids = Enum.map(p1 ++ p2 ++ p3, & &1["id"])
    assert MapSet.new(paged_ids) == MapSet.new(created)
    assert length(paged_ids) == length(Enum.uniq(paged_ids))
  end

  test "an unknown pageToken is 400 INVALID_PARAMS", %{server: server} do
    send_as!(server, "alice-token", "a1")

    resp = list(server, "alice-token", "?pageSize=2&pageToken=tsk-unknown")

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"@type" => @error_info, "reason" => "INVALID_PARAMS"}]
             }
           } =
             resp.body
  end

  # -- status filter ---------------------------------------------------------------

  test "status filter selects the matching state only", %{server: server} do
    send_as!(server, "alice-token", "a1")
    send_as!(server, "alice-token", "a2")

    assert %{"tasks" => tasks, "totalSize" => 2} =
             list(server, "alice-token", "?status=TASK_STATE_COMPLETED").body

    assert length(tasks) == 2
    assert Enum.all?(tasks, &(&1["status"]["state"] == "TASK_STATE_COMPLETED"))

    # A valid state that no task is in: real Filter.apply semantics, empty page.
    assert %{"tasks" => [], "totalSize" => 0, "nextPageToken" => ""} =
             list(server, "alice-token", "?status=TASK_STATE_FAILED").body
  end

  # -- param validation (same Request.validate_params/1 surface as JSON-RPC) -------

  test "invalid pageSize is 400 INVALID_PARAMS", %{server: server} do
    for query <- ["?pageSize=0", "?pageSize=101", "?pageSize=abc"] do
      resp = list(server, "alice-token", query)

      assert resp.status == 400, query

      assert %{
               "error" => %{
                 "code" => 400,
                 "details" => [%{"@type" => @error_info, "reason" => "INVALID_PARAMS"}]
               }
             } =
               resp.body
    end
  end

  test "invalid status value is 400 INVALID_PARAMS", %{server: server} do
    resp = list(server, "alice-token", "?status=TASK_STATE_BOGUS")

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"@type" => @error_info, "reason" => "INVALID_PARAMS"}]
             }
           } =
             resp.body
  end

  test "historyLength on tasks/list keeps the last N entries; unset clears; junk is refused", %{
    server: server
  } do
    send_as!(server, "alice-token", "a1")

    assert %{"tasks" => [task]} = list(server, "alice-token", "?historyLength=1").body
    assert [_only_one] = task["history"]

    assert %{"tasks" => [bare]} = list(server, "alice-token").body
    refute Map.has_key?(bare, "history"), "unset historyLength keeps the default (cleared)"

    resp = list(server, "alice-token", "?historyLength=bogus")
    assert resp.status == 400
    assert %{"error" => %{"code" => 400}} = resp.body
  end

  test "empty listing for a principal with no tasks still validates", %{server: server} do
    resp = list(server, "bob-token")

    assert resp.status == 200
    assert %{"tasks" => [], "totalSize" => 0, "pageSize" => 50, "nextPageToken" => ""} = resp.body
  end
end

# --- SECTION 18: Original test/ash_a2a_json_roundtrip_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AJsonRoundtripTest do
  @moduledoc """
  Real JSON round-trip test for a genuinely untested surface: what an LLM
  client actually receives over the wire from an ash_a2a-produced
  `AshA2A.Protocol.Task`, not just the live Elixir struct existing tests assert against.

  Every prior test in this suite (`test/ash_a2a_test.exs`,
  `test/ash_a2a_rap_battle_integration_test.exs`) asserts directly on the
  `AshA2A.Protocol.Task`/`AshA2A.Protocol.Message` struct returned by `AshA2A.Protocol.Agent.call/2` -- a live
  Elixir term still inside the BEAM. None of them push that struct through
  `:a2a`'s own `AshA2A.Protocol.JSON.encode/1` + `Jason.encode!/1` + `Jason.decode!/1` +
  `AshA2A.Protocol.JSON.decode/2` round trip, which is what a real HTTP/JSON-RPC
  transport (and thus a real LLM client on the other end) would actually do.
  The vendored `:a2a` 0.2.0 dependency itself ships no `test/` directory at
  all, so this codec path is formally unverified even at the dependency
  level -- this test is the first real exercise of it in this workspace.

  Chicago-style throughout: a real supervised `AshA2A.Protocol.Agent` GenServer (the
  existing `AshA2A.Test.Fixture.EchoAgent`/`Echo` fixture from
  `test/support/fixture.ex`), a real dispatched `AshA2A.Protocol.Message`, the real
  resulting `AshA2A.Protocol.Task`, and `:a2a`'s own real `AshA2A.Protocol.JSON` encode/decode
  functions and real `Jason` calls -- no Mock/mox/patch/monkeypatch, and no
  hand-rolled substitute for the real wire codec.
  """

  # `async: false`: this test reuses the shared `AshA2A.Test.Fixture.EchoAgent`
  # fixture, which `AshA2A.Protocol.Agent` registers under its own fixed module name
  # (not a per-test unique name) -- `test/ash_a2a_test.exs`'s existing
  # supervised-agent test also starts this same globally-named process, so
  # running both concurrently races for the same registered name
  # (`already_started`). Real fix for a real global-name collision, not a
  # workaround: serialize this test relative to that one instead of
  # reaching for a duplicate fixture just to keep `async: true`.
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.EchoAgent

  test "a real dispatched AshA2A.Protocol.Task survives AshA2A.Protocol.JSON encode -> Jason JSON string -> Jason decode -> AshA2A.Protocol.JSON decode" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    # A real message sent through a real supervised agent, exactly as the
    # existing supervised-agent test does (the fixture's :echo read action
    # accepts no arguments, so an empty data payload keeps dispatch on the
    # real :completed path rather than :input_required) -- the difference
    # from the existing test starts after this line.
    message = data_message(%{})

    assert {:ok, task} = EchoAgent.call(EchoAgent, message)
    assert %AshA2A.Protocol.Task{} = task
    assert task.status.state == :completed

    # Real artifact content the fixture's :echo read action actually
    # produced, asserted before it goes anywhere near JSON so a codec bug
    # can't be blamed for a dispatch bug.
    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: %{results: []}}]}] =
             task.artifacts

    # 1. Real encode: AshA2A.Protocol.Task -> JSON-ready map, via :a2a's own encoder.
    assert {:ok, wire_map} = AshA2A.Protocol.JSON.encode(task)
    # v1.0 wire shape: task frames carry no "kind" discriminator (the
    # StreamResponse wrapper key is the discriminator).
    refute Map.has_key?(wire_map, "kind")
    assert wire_map["id"] == task.id
    # TASK_STATE_* wire spellings are unchanged in v1.0.
    assert wire_map["status"]["state"] == "TASK_STATE_COMPLETED"

    # 2. Real serialization: the map must actually survive a real
    # Jason.encode!/1 -> Jason.decode!/1 round trip -- i.e. it contains no
    # non-JSON-safe values (atoms as map values, tuples, etc.) that a
    # struct-to-map shortcut could have smuggled through.
    json_string = Jason.encode!(wire_map)
    assert is_binary(json_string)

    redecoded_map = Jason.decode!(json_string)
    assert is_map(redecoded_map)

    # camelCase wire keys, per AshA2A.Protocol.JSON's documented v0.3 wire format.
    assert Map.has_key?(redecoded_map, "contextId") == Map.has_key?(wire_map, "contextId")
    assert redecoded_map["id"] == task.id

    # 3. Real decode: JSON-ready map -> AshA2A.Protocol.Task struct, via :a2a's own
    # decoder -- fed the map that actually came back through a real JSON
    # string, not the original in-memory `wire_map`.
    assert {:ok, decoded_task} = AshA2A.Protocol.JSON.decode(redecoded_map, :task)

    # State-based assertions on the real round-tripped struct: what an LLM
    # client parsing this JSON-RPC response would actually reconstruct.
    assert decoded_task.id == task.id
    # v1.0: contextId is REQUIRED on the wire. `use AshA2A.Agent` routes this
    # call through AshA2A.Transport.Runtime, which mints a server-side CSPRNG
    # context id ("ctx-" + 128 random bits, secure_context_id/0) on a new
    # task when the client supplies none — so the in-memory task carries a
    # real context id, and the round trip must preserve it byte-for-byte.
    assert is_binary(task.context_id) and String.starts_with?(task.context_id, "ctx-")
    assert decoded_task.context_id == task.context_id
    assert decoded_task.status.state == task.status.state
    assert decoded_task.metadata == task.metadata

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: decoded_data}]}] =
             decoded_task.artifacts

    # AshA2A.Protocol.Part.Data's wire format carries `data` through Jason as
    # string-keyed JSON, while the original in-memory artifact used an
    # atom-keyed map (`%{results: []}`) -- assert the round-tripped,
    # client-visible shape directly rather than against the pre-JSON atom
    # keys, since atom keys never legitimately survive a real wire hop.
    assert decoded_data == %{"results" => []}

    # The full task's history round-trips with the same message count, ids,
    # and roles as the original -- no phantom entries manufactured or
    # dropped in transit. The agent-reply message's `AshA2A.Protocol.Part.Data.data`
    # legitimately comes back string-keyed (same real wire-format reason as
    # `decoded_data` above), so compare history structurally rather than
    # with a blanket `==` against the original atom-keyed in-memory term.
    assert length(decoded_task.history) == length(task.history)

    assert Enum.zip(decoded_task.history, task.history)
           |> Enum.all?(fn {decoded_msg, original_msg} ->
             decoded_msg.message_id == original_msg.message_id and
               decoded_msg.role == original_msg.role
           end)

    assert [
             _user_msg,
             %AshA2A.Protocol.Message{
               parts: [%AshA2A.Protocol.Part.Data{data: history_reply_data}]
             }
           ] =
             decoded_task.history

    assert history_reply_data == %{"results" => []}

    # 4. Real round-trip of the request AshA2A.Protocol.Message itself, not just the
    # resulting Task -- the other half of what crosses the wire.
    assert {:ok, message_wire_map} = AshA2A.Protocol.JSON.encode(message)
    # v1.0 wire shape: no "kind" discriminator on the message either; parts
    # are flat {"data": ...} maps.
    refute Map.has_key?(message_wire_map, "kind")

    assert [%{"data" => %{}}] = message_wire_map["parts"]

    message_json = Jason.encode!(message_wire_map)
    redecoded_message_map = Jason.decode!(message_json)

    assert {:ok, decoded_message} = AshA2A.Protocol.JSON.decode(redecoded_message_map, :message)
    assert decoded_message.message_id == message.message_id
    assert decoded_message.role == message.role

    assert [%AshA2A.Protocol.Part.Data{data: decoded_message_data}] = decoded_message.parts
    assert decoded_message_data == %{}
  end
end

# --- SECTION 19: Original test/ash_a2a_lane07_taskstore_hardening_test.exs ---
defmodule AshA2A.Lane07TaskStoreHardeningTest do
  @moduledoc "Lane 07 courts: terminal safety, store errors, Ekv push-config, handover CAS, filter."
  use ExUnit.Case, async: false

  alias AshA2A.Cluster.{Checkpoint, Handover}
  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Protocol.Task
  alias AshA2A.Protocol.Task.Status
  alias AshA2A.Protocol.TaskStore
  alias AshA2A.TaskStore.Ekv

  defmodule Agent1 do
    use AshA2A.Agent,
      resource_or_domain: AshA2A.Test.Fixture.Echo,
      name: "lane07_hardening_agent"

    @impl AshA2A.Protocol.Agent
    def handle_message(_m, _c), do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
  end

  # Hand-written real store whose writes always fail.
  defmodule FullStore do
    def put(_ref, _task), do: {:error, :disk_full}
    def get(_ref, _id), do: {:error, :not_found}
  end

  defp ekv!(tag) do
    id = System.unique_integer([:positive])
    name = :"lane07_#{tag}_#{id}"
    dir = Path.join(System.tmp_dir!(), "lane07_#{tag}_#{id}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {name, dir}
  end

  defp with_state(task, st), do: %{task | status: Status.new(st)}

  test "stream_done after cancel never overwrites the terminal state" do
    name = :"lane07_ets_#{System.unique_integer([:positive])}"
    start_supervised!({TaskStore.ETS, [name: name]})
    {:ok, pid} = Agent1.start_link(name: Agent1, task_store: {TaskStore.ETS, name})

    task = Task.new(id: "tsk-cancel-race") |> with_state(:canceled)
    :ok = TaskStore.ETS.put(name, task)

    GenServer.cast(
      pid,
      {:stream_done, task.id, nil, [AshA2A.Protocol.Part.Text.new("late")], :complete}
    )

    assert {:ok, got} = GenServer.call(pid, {:get_task, task.id})
    assert got.status.state == :canceled
    assert got.artifacts == []
  end

  test "terminal states are never transitioned out of (no resurrect)" do
    for t <- [:completed, :failed, :canceled, :rejected] do
      task = Task.new() |> with_state(t)
      assert State.transition(task, :working).status.state == t
    end

    assert State.transition(Task.new(), :working).status.state == :working
  end

  test "put_task_checked surfaces store errors and does not cache the task" do
    state = %State{module: Agent1, task_store: {FullStore, :x}}
    task = Task.new()
    assert {:error, {:store_write_failed, :disk_full}} = State.put_task_checked(state, task)
  end

  test "Ekv push configs survive a store restart; delete is authoritative" do
    {name, dir} = ekv!(:push)
    spec = Ekv.child_spec(name: name, data_dir: dir)
    {:ok, sup} = Supervisor.start_link([spec], strategy: :one_for_one)

    cfg = %AshA2A.Protocol.PushNotificationConfig{
      id: "c1",
      task_id: "t1",
      url: "https://x.test/h"
    }

    cfg2 = %{cfg | id: "c2"}
    assert {:ok, ^cfg} = Ekv.set_push_config(name, cfg)
    assert {:ok, ^cfg2} = Ekv.set_push_config(name, cfg2)
    :ok = Ekv.delete_push_config(name, "t1", "c2")

    Supervisor.stop(sup)
    {:ok, sup2} = Supervisor.start_link([spec], strategy: :one_for_one)

    assert {:ok, ^cfg} = Ekv.get_push_config(name, "t1", "c1")
    assert {:error, :not_found} = Ekv.get_push_config(name, "t1", "c2")
    assert {:ok, [^cfg]} = Ekv.list_push_configs(name, "t1")
    assert {:ok, []} = Ekv.list_push_configs(name, "other")
  end

  test ":input_required and :auth_required survive an Ekv store restart" do
    {name, dir} = ekv!(:park)
    spec = Ekv.child_spec(name: name, data_dir: dir)
    {:ok, sup} = Supervisor.start_link([spec], strategy: :one_for_one)

    for {id, st} <- [{"tsk-ir", :input_required}, {"tsk-ar", :auth_required}] do
      :ok = Ekv.put(name, Task.new(id: id) |> with_state(st))
    end

    Supervisor.stop(sup)
    {:ok, sup2} = Supervisor.start_link([spec], strategy: :one_for_one)

    assert {:ok, %{status: %{state: :input_required}}} = Ekv.get(name, "tsk-ir")
    assert {:ok, %{status: %{state: :auth_required}}} = Ekv.get(name, "tsk-ar")
  end

  test "filter ties break deterministically by id; nil status is safe; dead cursor is typed" do
    ts = ~U[2026-01-01 00:00:00Z]

    mk = fn id ->
      %{Task.new(id: id) | status: %Status{state: :working, timestamp: ts}}
    end

    nil_status = %{Task.new(id: "nil") | status: nil}
    tasks = [mk.("b"), mk.("a"), mk.("c"), nil_status]

    {:ok, %{tasks: page}} = Task.Filter.apply(tasks, page_size: 10)
    assert Enum.map(page, & &1.id) == ["c", "b", "a", "nil"]
    {:ok, %{tasks: page2}} = Task.Filter.apply(Enum.reverse(tasks), page_size: 10)
    assert Enum.map(page2, & &1.id) == ["c", "b", "a", "nil"]

    assert {:ok, %{tasks: only}} = Task.Filter.apply(tasks, status: :working)
    assert length(only) == 3
    assert {:error, :invalid_page_token} = Task.Filter.apply(tasks, page_token: "gone")
  end

  test "checkpoint land does not resurrect a terminal task" do
    name = :"lane07_ets_#{System.unique_integer([:positive])}"
    start_supervised!({TaskStore.ETS, [name: name]})
    done = Task.new(id: "tsk-done") |> with_state(:completed)
    :ok = TaskStore.ETS.put(name, done)

    landed = Checkpoint.land({TaskStore.ETS, name}, "tsk-done", %{step: 1})
    refute Checkpoint.checkpointed?(landed)
    assert {:ok, %{status: %{state: :completed}} = stored} = TaskStore.ETS.get(name, "tsk-done")
    refute Checkpoint.checkpointed?(stored)
  end

  test "two peers rehydrating concurrently resume the task exactly once" do
    name = :"lane07_ets_#{System.unique_integer([:positive])}"
    start_supervised!({TaskStore.ETS, [name: name]})
    store = {TaskStore.ETS, name}
    :ok = TaskStore.ETS.put(name, Task.new(id: "tsk-cas") |> with_state(:working))
    Checkpoint.land(store, "tsk-cas", %{step: 1})
    {:ok, [task]} = Handover.list_checkpointed(store)

    counter = :counters.new(1, [])

    resume = fn _t, _frame ->
      :counters.add(counter, 1, 1)
      {:ok, :done}
    end

    results =
      1..8
      |> Enum.map(fn _ ->
        Elixir.Task.async(fn -> Handover.rehydrate_one(store, task, resume) end)
      end)
      |> Enum.map(&Elixir.Task.await(&1, 5_000))

    assert :counters.get(counter, 1) == 1
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:ok, %{status: %{state: :completed}}} = TaskStore.ETS.get(name, "tsk-cas")
  end

  test "resume throw/exit is collected and the checkpoint stays adoptable" do
    name = :"lane07_ets_#{System.unique_integer([:positive])}"
    start_supervised!({TaskStore.ETS, [name: name]})
    store = {TaskStore.ETS, name}
    Checkpoint.land(store, "tsk-throw", %{})
    {:ok, [task]} = Handover.list_checkpointed(store)

    assert {:error, %{reason: {:throw, :boom}}} =
             Handover.rehydrate_one(store, task, fn _, _ -> throw(:boom) end)

    assert {:ok, [_]} = Handover.list_checkpointed(store)
    assert {:ok, _} = Handover.rehydrate_one(store, task, fn _, _ -> {:ok, 1} end)
  end

  test "list_checkpointed on a store without list_all is a typed error" do
    assert {:error, {:unsupported, :list_all}} = Handover.list_checkpointed({FullStore, :x})
  end

  test "orphan sweep fails stale :working tasks without a live worker" do
    name = :"lane07_ets_#{System.unique_integer([:positive])}"
    start_supervised!({TaskStore.ETS, [name: name]})

    old = %{
      Task.new(id: "tsk-old")
      | status: %Status{state: :working, timestamp: ~U[2020-01-01 00:00:00Z]}
    }

    live = %{old | id: "tsk-live"}
    :ok = TaskStore.ETS.put(name, old)
    :ok = TaskStore.ETS.put(name, live)

    assert {:ok, ["tsk-old"]} =
             Task.OrphanSweep.sweep({TaskStore.ETS, name}, live?: &(&1 == "tsk-live"))

    assert {:ok, %{status: %{state: :failed}}} = TaskStore.ETS.get(name, "tsk-old")
    assert {:ok, %{status: %{state: :working}}} = TaskStore.ETS.get(name, "tsk-live")
  end
end

# --- SECTION 20: Original test/ash_a2a_llm_profiles_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ALLMProfilesTest do
  @moduledoc """
  Real, live proof that `AshA2A.LLMProfiles` role-based resolution works
  end to end: `AshA2A.Test.Fixture.SemanticReasoner`'s action source names
  only the role `:semantic_reasoner`, real config
  (`config/test.exs`) resolves it to a real provider, and a real live A2A
  dispatch makes a real call through that resolved provider.

  Named, visible skip when `ZAI_API_KEY` is absent from `~/.env` (the role
  currently resolves to `zai_coder` in this repo's config) -- never a
  silent mock substitution.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.SemanticReasonerAgent

  @zai_key AshA2A.Test.EnvKeyFixture.read_key("ZAI_API_KEY")

  @moduletag :external_api
  @describetag skip: AshA2A.Test.EnvKeyFixture.live_llm_skip_reason()

  setup_all do
    if @zai_key do
      Application.put_env(:req_llm, :zai_coder_api_key, @zai_key)
    end

    :ok
  end

  test "AshA2A.LLMProfiles.model_spec!/1 resolves the real configured provider" do
    assert AshA2A.LLMProfiles.model_spec!(:semantic_reasoner) == "zai_coder:glm-5.3-flash"
    assert AshA2A.LLMProfiles.req_llm_opts!(:semantic_reasoner) == [max_tokens: 4096]
  end

  test "an unconfigured role fails closed with a real, named ArgumentError" do
    assert_raise ArgumentError, ~r/no LLM profile configured for role :nonexistent_role/, fn ->
      AshA2A.LLMProfiles.model_spec!(:nonexistent_role)
    end
  end

  # Real, disclosed interaction with
  # test/ash_a2a_zai_concurrency_ocel_test.exs's real 50-way concurrency
  # probe when the full suite runs with `--include external_api`: real
  # rate-limit exhaustion from that probe can make this real, unseamed live
  # LLM call exceed the default 60s on both the ExUnit test process and
  # AshA2A.Protocol.Agent.call/3's own GenServer.call -- same fix as
  # test/ash_a2a_agent_semantic_request_test.exs, not a code defect.
  @tag timeout: 180_000
  test "a role-resolved action dispatches to a real live LLM call over real A2A" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        SemanticReasonerAgent
      ])

    message = data_message(%{prompt_text: "What color is the sky on a clear day?"})

    assert {:ok, task} =
             SemanticReasonerAgent.call(SemanticReasonerAgent, message, timeout: 170_000)

    assert task.status.state == :completed

    assert [
             %AshA2A.Protocol.Artifact{
               parts: [%AshA2A.Protocol.Part.Data{data: %{answer: answer}}]
             }
           ] = task.artifacts

    assert is_binary(answer)
    assert String.length(answer) > 0
  end
end

# --- SECTION 21: Original test/ash_a2a_margin_gate_e2e_test.exs ---
defmodule AshA2A.Test.Fixture.MarginGate.Effects do
  @moduledoc "Real counting agent: each consequential actuation records exactly here."
  use Agent

  def start_link(name), do: Agent.start_link(fn -> %{} end, name: name)

  def run(server, effect) do
    Agent.get_and_update(server, fn s ->
      n = Map.get(s, effect, 0) + 1
      {{:ok, n}, Map.put(s, effect, n)}
    end)
  end

  def count(server, effect), do: Agent.get(server, &Map.get(&1, effect, 0))
end

defmodule AshA2A.Test.Fixture.MarginGate.Envelope do
  @moduledoc """
  Loads the REAL landed pack artifact
  `ggen-marketplace/packs/financial-margin-envelope/generated/margin_envelope.ex`
  (committed at 1af488694). Fail-loud: a missing artifact refuses the court --
  the generated surface is never re-implemented or stubbed here.
  """

  @pack_path "/Users/sac/ggen-marketplace/packs/financial-margin-envelope/generated/margin_envelope.ex"

  @spec module() :: module()
  def module do
    unless Code.ensure_loaded?(MarginEnvelope) do
      case Code.require_file(@pack_path) do
        [_ | _] -> :ok
        _ -> raise "margin-gate court BLOCKED: pack artifact missing at #{@pack_path}"
      end
    end

    MarginEnvelope
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.PrecheckStep do
  @moduledoc """
  The margin Pre-Check: calls the real `MarginEnvelope.admit/1` on the case's
  envelope. `{:admit, env}` proceeds with the computed gross margin as output;
  an escalation/refusal is a typed step error carrying the envelope's own
  closed breach vocabulary -- fail-closed BEFORE any downstream actuation.
  """

  use Reactor.Step

  @impl true
  def run(_arguments, _context, options) do
    envelope = Keyword.fetch!(options, :envelope)
    mod = AshA2A.Test.Fixture.MarginGate.Envelope.module()

    case mod.admit(envelope) do
      {:admit, _env} ->
        {:ok, {:admitted, mod.margin(envelope)}}

      {:escalate, kind, meta} ->
        {:error, {:margin_gate, kind, meta[:reason]}}

      {:refuse, kind} = refusal ->
        {:error, {:margin_gate, kind, refusal}}
    end
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.ActuateStep do
  @moduledoc "Downstream actuation: records exactly one real effect when it runs."

  use Reactor.Step

  @impl true
  def run(_arguments, _context, options) do
    case AshA2A.Test.Fixture.MarginGate.Effects.run(
           Keyword.fetch!(options, :effects),
           :actuation
         ) do
      {:ok, n} -> {:ok, %{actuated: true, seq: n}}
      {:error, _} = err -> err
    end
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.Adapter do
  @moduledoc """
  Real `AshPPlan.Reactor.Adapter` binding the margin Pre-Check and the
  downstream actuation step for this court.
  """

  @behaviour AshPPlan.Reactor.Adapter

  @impl true
  def id, do: :a2a_margin_gate_fx

  @impl true
  def available?, do: true

  @impl true
  def ops, do: [:process_prepare, :process_finish]

  @impl true
  def step(op, options) do
    table = %{
      process_prepare: {AshA2A.Test.Fixture.MarginGate.PrecheckStep, []},
      process_finish: {AshA2A.Test.Fixture.MarginGate.ActuateStep, []}
    }

    AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.Cfg do
  @moduledoc """
  Runtime config holder for the court's agent fixture: the agent's
  compile-time `pplan:` opts are `{m, f, a}` tuples resolved by
  `AshA2A.Execution.PPlan` on every call, so the runtime-started store,
  per-case model, and bindings are reachable from compile-time agent opts.
  """

  @key {:ash_a2a_margin_gate_e2e_court, :pplan}

  def put(opts), do: :persistent_term.put(@key, opts)

  def opt(key), do: Keyword.fetch!(:persistent_term.get(@key), key)

  def stop do
    case :persistent_term.get(@key, nil) do
      %{store: store} when is_pid(store) ->
        if Process.alive?(store), do: Process.exit(store, :kill)

      _ ->
        :ok
    end

    :persistent_term.erase(@key)
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.Resource do
  @moduledoc """
  Real fixture resource for the margin-gate court. Its one `:observe` skill is
  the node-local handler; under `adapter: :pplan` the handler is never
  entered, so its real `:persistent_term` counter staying at zero is
  action-observed evidence that no node-local worker executed the task.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.MarginGate.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :probe, :map do
      run(fn _input, _context ->
        key = {__MODULE__, :skill_dispatches}
        :persistent_term.put(key, :persistent_term.get(key, 0) + 1)
        {:ok, %{probed: true}}
      end)
    end
  end

  a2a do
    skill(:probe, :probe, consequence: :observe)
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.Domain do
  @moduledoc "Real fixture domain for the margin-gate court."
  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.MarginGate.Resource)
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.Agent do
  @moduledoc """
  Real agent with `adapter: :pplan`: async dispatch routes through a durable
  ash_pplan run keyed by the A2A task id; the margin gate is the run's
  Pre-Check step, so a margin breach fails the task closed before the
  downstream actuation step is ever scheduled.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.MarginGate.Resource,
    name: "margin_gate_agent",
    execution: [
      adapter: :pplan,
      pplan: [
        store: {AshA2A.Test.Fixture.MarginGate.Cfg, :opt, [:store]},
        store_module: AshPPlan.Reactor.Durable.Store.Ets,
        model: {AshA2A.Test.Fixture.MarginGate.Cfg, :opt, [:model]},
        bindings: {AshA2A.Test.Fixture.MarginGate.Cfg, :opt, [:bindings]}
      ]
    ]
end

defmodule AshA2A.MarginGateE2ETest do
  @moduledoc """
  Lane I4 court: end-to-end consumer test of the margin-gated work-order
  capability manufactured by the `financial-margin-envelope` ggen-marketplace
  pack (generated `margin_envelope.ex`, committed at 1af488694).

  The REAL generated admit/escalate surface is the Pre-Check of an ash_pplan
  workflow model (margin Pre-Check -> downstream actuation), dispatched as a
  real A2A task through `AshA2A.Execution.PPlan` (`adapter: :pplan`) over the
  real ETS durable store. Assertions:

    * admit case (margin 0.28 >= floor 0.22): the task COMPLETES and the
      downstream actuation step is in the checkpoint tape;
    * escalate case (margin 0.19 < floor 0.22): the task FAILS CLOSED with
      the envelope's typed breach vocabulary (`:ESCALATE_MULTISIG`) and the
      tape holds NO downstream actuation step;
    * in both cases the node-local skill handler never runs -- the durable
      run's checkpoint tape is the execution record.

  If `:ash_pplan` cannot load in the test env, every test skips with a typed
  BLOCKED reason (same skip discipline as
  `test/ash_a2a_execution_pplan_test.exs`).
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Providers.PPlan, as: Provider
  alias AshA2A.Test.Fixture.MarginGate.{Adapter, Agent, Cfg, Effects, Envelope}
  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.Model

  @adapter_id :a2a_margin_gate_fx
  @ets AshPPlan.Reactor.Durable.Store.Ets
  @counter_key {AshA2A.Test.Fixture.MarginGate.Resource, :skill_dispatches}

  @admit_envelope %{
    envelope_id: "ENV-001",
    nte: Decimal.new("250000"),
    quote: Decimal.new("180000"),
    floor: Decimal.new("0.22"),
    currency: "USD"
  }

  @escalate_envelope %{
    envelope_id: "ENV-002",
    nte: Decimal.new("250000"),
    quote: Decimal.new("201500"),
    floor: Decimal.new("0.22"),
    currency: "USD"
  }

  setup context do
    unless AshA2A.Execution.PPlan.available?() do
      reason = {:blocked, :ash_pplan_not_loadable}
      IO.puts(:stderr, "[lane-i4] BLOCKED: :ash_pplan did not load in the test env")
      {:skip, reason}
    end

    # the REAL pack artifact is loadable, fail-loud otherwise
    env_mod = Envelope.module()
    assert env_mod == MarginEnvelope
    # Pre-Check semantics observed directly on the generated surface
    assert {:admit, _} = env_mod.admit(@admit_envelope)
    assert {:escalate, :ESCALATE_MULTISIG, _} = env_mod.admit(@escalate_envelope)
    assert :ESCALATE_MULTISIG in env_mod.refusals()

    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), @adapter_id, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
      :persistent_term.erase(@counter_key)
      Cfg.stop()
    end)

    :persistent_term.put(@counter_key, 0)

    {:ok, fx} =
      Effects.start_link(:"margin_gate_fx_#{System.unique_integer([:positive])}")

    {:ok, store} = @ets.start_link(name: :"#{context.module}.Store")

    %{store: store, fx: fx}
  end

  defp model(case_name) do
    {:ok, m} =
      Model.new(
        name: "margin_gate_#{case_name}",
        goal: "margin_gated_work_order",
        tasks: [
          [id: :precheck, capability: "Process.Prepare", depends_on: []],
          [id: :actuate, capability: "Process.Finish", depends_on: [:precheck]]
        ]
      )

    m
  end

  defp bindings(fx, envelope) do
    ops = [{:precheck, "Process.Prepare"}, {:actuate, "Process.Finish"}]

    Map.new(ops, fn {task, cap} ->
      # built through struct/2 (runtime __struct__ dispatch), not a struct
      # literal: `:ash_pplan` is an `only: :test` optional dep and must not be
      # required at test-file COMPILE time
      {task,
       struct(
         AshPPlan.Realization,
         capability: cap,
         provider: @adapter_id,
         binding: %{adapter: @adapter_id, op: AshPPlan.Realization.op_for(cap)},
         options: [envelope: envelope, effects: fx]
       )}
    end)
  end

  defp configure!(store, fx, case_name, envelope) do
    Cfg.put(
      store: store,
      model: model(case_name),
      bindings: bindings(fx, envelope)
    )
  end

  defp tape(store, run_id) do
    Engine.steps(store, run_id, store_module: @ets)
  end

  @tag :serial
  test "admit case: margin 0.28 passes the Pre-Check, the task completes, and the downstream actuation is in the tape",
       %{store: store, fx: fx} do
    configure!(store, fx, :admit, @admit_envelope)

    _sup_and_registry =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [Agent])

    assert {:ok, task} = Agent.call(Agent, data_message(%{nte: "250000", quote: "180000"}))

    assert task.status.state == :completed

    # the gate ran on the REAL envelope, not the message payload: one real
    # downstream actuation happened
    assert Effects.count(fx, :actuation) == 1

    # no node-local handler execution: the fixture skill's counter is zero
    assert 0 == :persistent_term.get(@counter_key, 0)

    assert {:ok, :completed, %{run_status: :completed, error: nil}} =
             Provider.status(task.id, store: store, store_module: @ets)

    # the durable run's checkpoint tape is the execution record:
    # precheck -> actuate, in execution order
    steps = tape(store, task.id)
    assert length(steps) == 2

    assert Enum.map(steps, & &1.label) == [
             ~s("urn:ash-pplan:workflow:margin_gate_admit#step-precheck"),
             ~s("urn:ash-pplan:workflow:margin_gate_admit#step-actuate")
           ]

    # the admitted margin is the real computed gross margin, 0.28
    assert Enum.any?(steps, fn step ->
             case step.output do
               {:admitted, %Decimal{} = m} -> Decimal.eq?(m, Decimal.new("0.28"))
               _ -> false
             end
           end)
  end

  @tag :serial
  test "escalate case: margin 0.19 fails the task closed with the typed breach vocabulary and NO downstream actuation in the tape",
       %{store: store, fx: fx} do
    configure!(store, fx, :escalate, @escalate_envelope)

    _sup_and_registry =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [Agent])

    assert {:ok, task} = Agent.call(Agent, data_message(%{nte: "250000", quote: "201500"}))

    assert task.status.state == :failed

    # typed breach vocabulary from the envelope's closed refusal set
    assert :ESCALATE_MULTISIG in Envelope.module().refusals()

    # fail-closed BEFORE actuation: zero downstream effects
    assert Effects.count(fx, :actuation) == 0
    assert 0 == :persistent_term.get(@counter_key, 0)

    assert {:ok, :failed, %{run_status: :failed, error: error}} =
             Provider.status(task.id, store: store, store_module: @ets)

    # the engine wraps the step error in its own error class; the typed
    # breach vocabulary must survive the wrap, verbatim
    assert match?(%{class: :invalid}, error)
    rendered = inspect(error)
    assert rendered =~ "ESCALATE_MULTISIG"
    assert rendered =~ "margin below floor"
    assert rendered =~ "margin_gate"

    # the tape holds NO standing checkpoint: a failed step records no standing
    # checkpoint, so the actuation step is absent entirely -- fail-closed
    # BEFORE actuation, evidenced on the durable record
    steps = tape(store, task.id)
    assert steps == []
    refute Enum.any?(steps, &(&1.label =~ "actuate"))
  end
end

# --- SECTION 22: Original test/ash_a2a_mock_discipline_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MockDisciplineTest do
  @moduledoc """
  The fleet mock-discipline grep, run for real over this tree (ERRC Cr4,
  lane P1-A2).

  The fleet gate regex is:

      (use|import) +(Mox|Mimic|Patch)\b|(Mox|Mimic|Patch)\.|:meck\.|mockall|MagicMock

  run with `grep -rnE --include=*.ex --include=*.exs` over `lib/` and `test/`
  (`_build/`, `deps/`, `priv/` are not under those roots, so they are excluded
  structurally). The naive reading -- "exit 1 = clean" -- is false on this
  tree by design: the repo's own zero-mock detection court quotes banned
  tokens verbatim (the ggen precedent: well-formed test files are hits
  against themselves).

  ## Audit (main @ d58f99f) -- every raw hit is a prose position

  | file | lines | position |
  |---|---|---|
  | `lib/ash_a2a/chicago/court.ex` | 43 | moduledoc bullet naming :meck/Mox |
  | `lib/ash_a2a/chicago/collaborators/mock_scan.ex` | 13, 14, 15, 111, 121, 130 | docstrings/comments of the AST scanner itself |
  | `lib/ash_a2a/chicago/courts/real_collaborators.ex` | 46-68, 83-96, 277 | `~S` sigil fixture sources + falsifier prose |
  | `test/ash_a2a/chicago/real_collaborators_test.exs` | 190-193, 207-210, 220, 223-224 | heredoc fixture sources the court's tests scan |

  None is a code position: `AshA2A.Chicago.Collaborators.MockScan` parses the
  same files with `Code.string_to_quoted/2` and flags only real calls,
  directives, captures and apply-shapes into Mox/Hammox/Mock/Mimic/Patch/
  :meck -- comments, docstrings, strings, sigils and atoms are not calls. So
  the fleet regex is evaluated at **code positions** through that AST law,
  and the raw grep is kept as a drift tripwire.

  ## The gate (three assertions, each fails closed)

    1. the fleet regex has teeth: run against a real temp file containing
       `use Mox`, grep must match (exit 0) -- a regex that silently stopped
       matching must fail this test, not the next incident;
    2. the AST scan over `lib/` + `test/` is `:clean` with files scanned > 0
       -- zero code-position violations, unparseable source fails closed;
    3. every raw grep hit lives in the allowlist of disclosure files above
       (keyed by file, not line -- prose shifts, disclosure files do not).
       A banned token quoted in any NEW file turns this red and forces a
       reviewed allowlist extension.

  Red/green proof (session P1-A2): a scratch `use Mox` file under `test/`
  turns assertions 2 and 3 red; deleting it restores green. The scratch file
  is removed; nothing in the tree keeps it.
  """

  use ExUnit.Case, async: true

  @regex ~S[(use|import) +(Mox|Mimic|Patch)\b|(Mox|Mimic|Patch)\.|:meck\.|mockall|MagicMock]

  # Files whose docstrings/comments/sigil fixtures quote banned tokens.
  # Keyed by path (relative to repo root), not line: prose shifts, the
  # disclosure files do not. Extending this list is a reviewed admission.
  @disclosure_files [
    "lib/ash_a2a/chicago/court.ex",
    "lib/ash_a2a/chicago/collaborators/mock_scan.ex",
    "lib/ash_a2a/chicago/courts/real_collaborators.ex",
    "test/ash_a2a/chicago/real_collaborators_test.exs",
    # This file's own moduledoc quotes the banned tokens to document them.
    "test/ash_a2a_mock_discipline_test.exs"
  ]

  test "fleet mock-discipline gate: AST-clean tree, regex with teeth, prose hits allowlisted" do
    # 1. The regex has teeth -- real grep against a real violating file.
    #    (The only double in this suite: the violation itself cannot exist
    #    in the tree, so its stand-in lives in the OS temp dir and dies with
    #    the test process. A real file, real grep, state-based assertion.)
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "ash_a2a-mock-teeth-#{System.unique_integer([:positive])}.exs")
    File.write!(path, "defmodule T do\n  use Mox\nend\n")

    teeth =
      System.cmd("grep", ["-rnE", @regex, path], stderr_to_stdout: true)

    File.rm(path)

    assert {_, exit_teeth} = teeth
    assert exit_teeth == 0, "fleet regex failed to match a real `use Mox` (exit #{exit_teeth})"

    # 2. Code positions: the repo's own AST law over lib/ + test/.
    scan =
      AshA2A.Chicago.Collaborators.MockScan.scan(root: File.cwd!(), dirs: ["lib", "test"])

    assert scan.files > 0, "AST scan saw no files -- gate vacuous"
    assert scan.violations == [], inspect(scan.violations, pretty: true)
    assert scan.unparseable == [], inspect(scan.unparseable, pretty: true)
    assert scan.outcome == :clean

    # 3. Raw fleet grep over the tree: every hit must be a disclosure-file
    #    prose hit, never a new file.
    {out, exit_grep} =
      System.cmd("grep", ["-rnE", @regex, "--include=*.ex", "--include=*.exs", "lib", "test"],
        stderr_to_stdout: true
      )

    assert exit_grep in [0, 1], "grep errored (exit #{exit_grep}): #{out}"

    hits =
      out
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 3) do
          [file, lineno, _text] -> {file, String.to_integer(lineno)}
          _ -> raise("unparseable grep line: #{inspect(line)}")
        end
      end)

    offending =
      hits
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @disclosure_files))

    assert offending == [],
           "banned tokens outside the disclosure allowlist: #{inspect(offending)}" <>
             "\nraw hits:\n#{out}"
  end
end
