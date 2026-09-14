defmodule AshA2A.Semantic.CompilerTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Identity, Receipt}
  alias AshA2A.Semantic.{Compiler, ExecutionPackage, Feedback, IR}
  alias AshA2A.Test.Fixture.Echo

  test "compiles text through ontology and HDDL/FOND candidate without DO" do
    extract = fn _, _, _, _ -> {:ok, extraction()} end

    plan = fn _, _, _, _ ->
      {:ok,
       %{
         "request_id" => "semantic-plan-1",
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "(:task lead)",
         "fond" => "(:policy observe-or-replan)"
       }}
    end

    assert {:ok, package} =
             Compiler.compile(Echo, "The goal is to lead the people.",
               generate_object: extract,
               plan_generate_object: plan
             )

    assert package.semantic_ir.standing == :admitted
    assert package.ontology.standing == :admitted
    assert package.planning_ir.standing == :admitted
    assert package.plan_candidate.formalism == :hddl_fond
    assert package.authority == :none
  end

  defp default_plan do
    fn _, _, _, _ ->
      {:ok,
       %{
         "request_id" => "semantic-plan-1",
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "(:task lead)",
         "fond" => "(:policy observe-or-replan)"
       }}
    end
  end

  test "compile_many/3 preserves ordering and isolates one admission failure" do
    text1 = "The goal is to lead the people."
    text2 = "The goal is to feed the people."
    text3 = "The goal is to read the people."

    extract = fn _, prompt, _, _ ->
      cond do
        String.contains?(prompt, text2) ->
          {:ok,
           extraction()
           |> put_in(["goals"], [
             %{
               "id" => "lead",
               "kind" => "goal",
               "description" => "lead the people",
               "source_quote" => "this quote is not in the source text at all"
             }
           ])}

        String.contains?(prompt, text1) ->
          {:ok, extraction()}

        true ->
          {:ok, extraction_for(text3)}
      end
    end

    results =
      Compiler.compile_many(Echo, [text1, text2, text3],
        generate_object: extract,
        plan_generate_object: default_plan()
      )

    assert [ok1, err2, ok3] = results
    assert {:ok, %ExecutionPackage{}} = ok1
    assert {:error, %{code: :ungrounded_assertion}} = err2
    assert {:ok, %ExecutionPackage{}} = ok3
  end

  test "compile_many/3 converts a raised exception into a worker-exit error at its slot" do
    text1 = "The goal is to lead the people."
    text2 = "The goal is to feed the people."
    text3 = "The goal is to read the people."

    extract = fn _, prompt, _, _ ->
      cond do
        String.contains?(prompt, text2) -> raise "boom"
        String.contains?(prompt, text1) -> {:ok, extraction()}
        true -> {:ok, extraction_for(text3)}
      end
    end

    results =
      Compiler.compile_many(Echo, [text1, text2, text3],
        generate_object: extract,
        plan_generate_object: default_plan()
      )

    assert [ok1, {:error, %{code: :semantic_worker_exit, detail: _}}, ok3] = results
    assert {:ok, %ExecutionPackage{}} = ok1
    assert {:ok, %ExecutionPackage{}} = ok3
  end

  test "replan/4 folds a real receipt into a new candidate as an observation" do
    extract = fn _, _, _, _ -> {:ok, extraction()} end

    assert {:ok, package} =
             Compiler.compile(Echo, "The goal is to lead the people.",
               generate_object: extract,
               plan_generate_object: default_plan()
             )

    receipt = %Receipt{
      receipt_id: Identity.runtime("receipt-1"),
      command_id: Identity.command("command-1"),
      execution_id: Identity.execution("execution-1"),
      agent_id: Identity.agent("agent-1"),
      principal_id: Identity.principal("principal-1"),
      capability_id: "AshA2A.Test.Fixture.Echo.read",
      fingerprint: "command-fingerprint",
      consequence: :read,
      status: :completed,
      standing: :observed,
      recorded_at: ~U[2026-09-13 20:00:00Z]
    }

    assert {:ok, %ExecutionPackage{parent_fingerprint: parent_fp, feedback: [_ | _]} = next,
            %Feedback{}} =
             Compiler.replan(Echo, package, receipt, plan_generate_object: default_plan())

    assert parent_fp == package.fingerprint
    assert next.fingerprint != package.fingerprint
  end

  test "replan/4 passes through an error unchanged (no with-else wrapping)" do
    extract = fn _, _, _, _ -> {:ok, extraction()} end

    assert {:ok, package} =
             Compiler.compile(Echo, "The goal is to lead the people.",
               generate_object: extract,
               plan_generate_object: default_plan()
             )

    receipt = %Receipt{
      receipt_id: Identity.runtime("receipt-2"),
      command_id: Identity.command("command-2"),
      execution_id: Identity.execution("execution-2"),
      agent_id: Identity.agent("agent-2"),
      principal_id: Identity.principal("principal-2"),
      capability_id: "AshA2A.Test.Fixture.Echo.read",
      fingerprint: "command-fingerprint-2",
      consequence: :read,
      status: :completed,
      standing: :observed,
      recorded_at: ~U[2026-09-13 20:00:00Z]
    }

    failing_plan = fn _, _, _, _ -> {:error, %{code: :boom_test}} end

    assert {:error, %{code: :boom_test}} =
             Compiler.replan(Echo, package, receipt, plan_generate_object: failing_plan)
  end

  test "compile_source/3 wraps a non-code-map error reason as semantic_compilation_failed" do
    failing_fn = fn _, _, _, _ -> {:error, "some raw string reason"} end

    assert {:error, %{code: :semantic_compilation_failed, detail: "some raw string reason"}} =
             Compiler.compile(Echo, "some text", generate_object: failing_fn)
  end

  defp extraction do
    IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{
        "id" => "lead",
        "kind" => "goal",
        "description" => "lead the people",
        "source_quote" => "The goal is to lead the people."
      }
    ])
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
