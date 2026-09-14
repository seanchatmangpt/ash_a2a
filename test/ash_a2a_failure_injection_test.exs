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
      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
      %{store_opts: [name: name]}
    end

    test "authority issued for a different capability id is refused with :authority_mismatch, not admitted",
         %{
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
                 store_opts: store_opts
               )

      assert :error = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    end

    test "authority issued for the right capability but a different principal is refused with :authority_mismatch",
         %{
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
                 store_opts: store_opts
               )

      assert :error = ReceiptStore.Memory.fetch(command.command_id, store_opts)
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
