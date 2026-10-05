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
      if Process.alive?(pid), do: GenServer.stop(pid)
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
