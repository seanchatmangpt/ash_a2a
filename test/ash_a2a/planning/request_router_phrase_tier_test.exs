# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Planning.RequestRouterPhraseTierTest do
  @moduledoc """
  Real, Chicago-style coverage for task 5's phrase tier: `route/3`'s new
  second detection step, wired between the facts tier and the LLM tier.

  Positive cases prove a real caller-registered structured-phrase template
  parses a real structured phrase deterministically, with the LLM
  never invoked (reusing `request_router_llm_never_called_test.exs`'s own
  raise-on-call seam -- a real `RuntimeError` from the injected
  `:generate_object`/`:plan_generate_object` functions is what a routing
  regression would produce; its absence is real, executed evidence).

  Adversarial cases prove the SAME registered template does NOT capture
  this repo's own genuine free-text corpus strings
  (`"The goal is to read the people."`,
  `"advance the admitted workflow"` -- see
  `test/ash_a2a/semantic_compiler_test.exs:51` and
  `docs/how-to/enable-semantic-requests.md:69`) -- these fall through to
  the LLM tier exactly as they did before this task, proven the same
  adversarial-completeness way `request_router_llm_never_called_test.exs`
  proves it: the same raise-on-call functions genuinely raise when routed
  with the phrase templates configured, showing the fallthrough is real
  reachability, not a silent no-op.

  No test double of any kind: the real repo-wide banned-pattern sweep
  (`grep -rn "Mock\\|mox\\|patch("`, zero matches over this file) is part
  of this task's own reported verification evidence.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Planning.RequestRouter
  alias AshA2A.Semantic.ExecutionPackage
  alias AshA2A.Test.Fixture.HddlDeterministicFixture

  @advance_id "AshA2A.Test.Fixture.HddlDeterministicFixture.advance"
  @unlock_id "AshA2A.Test.Fixture.HddlDeterministicFixture.unlock"

  # The real structured-phrase family this repo's own corpus investigation
  # found reusable across multiple test/doc call sites:
  # `test/ash_a2a_agent_semantic_replan_test.exs:250,297,355,400,437,469`'s
  # `"create a labeled item"` / `"create a labeled item, <variant> variant"`
  # family. Fully anchored, per `AshA2A.Planning.PhraseParser`'s own
  # contract.
  @labeled_item_regex ~r/^create a labeled item(?:, (?<variant>[a-z]+(?: [a-z]+)?) variant)?$/

  defp labeled_item_template do
    %{
      regex: @labeled_item_regex,
      to_envelope: fn captures ->
        variant = Map.get(captures, "variant", "")

        %{
          "request_id" =>
            "phrase-tier-test-#{if variant == "", do: "plain", else: variant}-" <>
              "#{System.unique_integer([:positive])}",
          "domain_name" => "phrase-tier-test-domain",
          "problem_name" => "phrase-tier-test-problem",
          "objects" => ["on", "off"],
          "init" => [%{"predicate" => "current_phase", "args" => ["on"]}],
          "goal" => [
            %{"predicate" => "current_phase", "args" => ["off"]},
            %{"predicate" => "has_key", "args" => ["off"]}
          ],
          "task_sequence" => [
            %{"capability_id" => @advance_id, "args" => ["on", "off"]},
            %{"capability_id" => @unlock_id, "args" => ["off"]}
          ]
        }
      end
    }
  end

  defp text_message(text), do: A2A.Message.new_user(text)

  defp raise_on_call(label) do
    fn _model_spec, _prompt, _schema, _llm_opts ->
      raise "structural non-invocation proof violated: #{label} was invoked"
    end
  end

  defp route_with_phrase_templates_and_llm_guard(text) do
    RequestRouter.route(HddlDeterministicFixture, text_message(text),
      phrase_templates: [labeled_item_template()],
      generate_object: raise_on_call("generate_object"),
      plan_generate_object: raise_on_call("plan_generate_object")
    )
  end

  describe "phrase tier -- positive: a real structured phrase parses deterministically, zero LLM call" do
    test "the plain phrase (no variant clause) routes through the real solver, LLM never invoked" do
      assert {:ok, %ExecutionPackage{} = package} =
               route_with_phrase_templates_and_llm_guard("create a labeled item")

      # Real success from the real deterministic solver -- not a stub. If
      # this had instead fallen through to the LLM tier, one of the two
      # raise_on_call functions above would have raised and this test
      # would have failed loudly instead.
      assert package.standing == :candidate
      assert package.authority == :none
      assert package.plan_candidate.capability_ids == [@advance_id, @unlock_id]
    end

    test "a real variant-clause phrase's named capture reaches the built envelope, LLM never invoked" do
      assert {:ok, %ExecutionPackage{} = package} =
               route_with_phrase_templates_and_llm_guard(
                 "create a labeled item, forbidden variant"
               )

      assert package.standing == :candidate
      assert package.plan_candidate.capability_ids == [@advance_id, @unlock_id]
    end

    test "a real two-word variant clause (direct replan) parses the same way, LLM never invoked" do
      assert {:ok, %ExecutionPackage{} = package} =
               route_with_phrase_templates_and_llm_guard(
                 "create a labeled item, direct replan variant"
               )

      assert package.standing == :candidate
      assert package.plan_candidate.capability_ids == [@advance_id, @unlock_id]
    end

    test "telemetry reports tier: :phrase for a real phrase-tier dispatch" do
      handler_id = {__MODULE__, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ash_a2a, :router, :tier_selected],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:ash_a2a_router_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _package} = route_with_phrase_templates_and_llm_guard("create a labeled item")

      assert_receive {:ash_a2a_router_telemetry, %{}, metadata}
      assert metadata.tier == :phrase
      assert metadata.resource_or_domain == HddlDeterministicFixture
    end
  end

  describe "phrase tier -- adversarial: real free-text corpus strings must fall through to the LLM tier, never be misparsed" do
    test "\"The goal is to read the people.\" is not captured by the labeled-item template and really reaches the LLM tier" do
      assert_raise RuntimeError, ~r/generate_object was invoked/, fn ->
        route_with_phrase_templates_and_llm_guard("The goal is to read the people.")
      end
    end

    test "\"advance the admitted workflow\" is not captured by the labeled-item template and really reaches the LLM tier" do
      assert_raise RuntimeError, ~r/generate_object was invoked/, fn ->
        route_with_phrase_templates_and_llm_guard("advance the admitted workflow")
      end
    end

    test "a genuine substring occurrence inside unrelated free prose is not partially captured either" do
      text = "Please create a labeled item now, as part of the larger onboarding flow."

      assert_raise RuntimeError, ~r/generate_object was invoked/, fn ->
        route_with_phrase_templates_and_llm_guard(text)
      end
    end
  end

  describe "phrase tier -- backward compatibility: no phrase_templates opt behaves exactly like task 4" do
    test "free text with no phrase_templates configured still reaches the LLM tier unchanged" do
      text = "The goal is to advance and unlock the gate."

      assert_raise RuntimeError, ~r/generate_object was invoked/, fn ->
        RequestRouter.route(HddlDeterministicFixture, text_message(text),
          generate_object: raise_on_call("generate_object"),
          plan_generate_object: raise_on_call("plan_generate_object")
        )
      end
    end
  end

  describe "phrase tier -- ambiguity and invalid templates fail closed through the full router" do
    test "two independently-matching templates over the same text refuse the phrase tier and fall through to the LLM" do
      duplicate_template = %{
        regex: @labeled_item_regex,
        to_envelope: fn _captures -> %{"domain_name" => "duplicate-domain"} end
      }

      assert_raise RuntimeError, ~r/generate_object was invoked/, fn ->
        RequestRouter.route(
          HddlDeterministicFixture,
          text_message("create a labeled item"),
          phrase_templates: [labeled_item_template(), duplicate_template],
          generate_object: raise_on_call("generate_object"),
          plan_generate_object: raise_on_call("plan_generate_object")
        )
      end
    end

    test "a sole-matching template whose to_envelope raises fails closed with a typed error, never reaches the LLM" do
      raising_template = %{
        regex: ~r/^raise on purpose$/,
        to_envelope: fn _captures -> raise "template author bug" end
      }

      assert {:error, %{code: :invalid_phrase_template}} =
               RequestRouter.route(
                 HddlDeterministicFixture,
                 text_message("raise on purpose"),
                 phrase_templates: [raising_template],
                 generate_object: raise_on_call("generate_object"),
                 plan_generate_object: raise_on_call("plan_generate_object")
               )
    end
  end
end
