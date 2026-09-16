defmodule AshA2A.Semantic.LlmBoundaryFalsifiersTest do
  @moduledoc """
  RFC S40's fundamental relation, one named falsifier per prohibited
  effect:

      LLMOutput => Candidate        and NEVER        LLMOutput => Standing

  Each of the seven tests below drives a real model-shaped payload that
  *attempts* one of the seven prohibited effects through the real
  `AshA2A.Semantic.LlmBoundary` and asserts on the real returned refusal
  -- never on "was something called".

  ## Why the paired positive test matters

  A suite of seven refusals could pass vacuously: if `candidate/3`
  refused *everything*, all seven would be green and the boundary would
  be useless rather than correct. The "a clean payload really does become
  a candidate" test is the adversarial-completeness companion (the same
  idiom `request_router_llm_never_called_test.exs` uses for its own
  raise-on-call proof): it proves the boundary admits real work, so the
  seven refusals are discriminating rather than blanket.

  The seventh effect (`:execute_consequential_do`) additionally gets a
  real end-to-end proof through the real `AshA2A.CommandBus` against a
  real `:change`-consequence Ash resource: a command built from an
  LLM-resolved payload carries no `AshA2A.Authority` (because the
  boundary refuses to produce one), and the real bus refuses it with
  `:authority_required` before any dispatch happens.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Command, CommandBus}
  alias AshA2A.Semantic.Allocator
  alias AshA2A.Semantic.LlmBoundary
  alias AshA2A.Semantic.Unknown
  alias AshA2A.Semantic.Unknown.Resolution
  alias AshA2A.Test.Fixture.Item

  defp unknown(class \\ "falsifier-class") do
    Unknown.declare(class, %{"subject" => "a real semantic subject"})
  end

  # --------------------------------------------------------------------
  # The seven named falsifiers (RFC S40)
  # --------------------------------------------------------------------

  test "falsifier 1/7 :admit_fact -- model output claiming admitted standing is refused" do
    payload = %{"claim" => "the invoice is reconciled", "standing" => "admitted"}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :admit_fact, key: "standing"}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    # And the direct effect gate, which has no success clause at all.
    assert {:error, %{code: :llm_effect_refused, effect: :admit_fact}} =
             LlmBoundary.attempt(:admit_fact, payload)
  end

  test "falsifier 2/7 :create_canonical_identity -- model output minting a graph digest is refused" do
    payload = %{
      "entities" => [%{"id" => "e1", "graph_digest" => String.duplicate("a", 64)}]
    }

    assert {:error, %{code: :llm_standing_claim_refused, effect: :create_canonical_identity}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :create_canonical_identity}} =
             LlmBoundary.attempt(:create_canonical_identity)
  end

  test "falsifier 3/7 :grant_authority -- model output granting itself authority is refused" do
    payload = %{"plan" => %{"authority" => %{"subject" => "agent-1", "scope" => "*"}}}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :grant_authority}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :grant_authority}} =
             LlmBoundary.attempt(:grant_authority)
  end

  test "falsifier 4/7 :alter_canonical_state -- model output committing canonical state is refused" do
    payload = %{"steps" => [%{"commit" => true, "target" => "ledger"}]}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :alter_canonical_state}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :alter_canonical_state}} =
             LlmBoundary.attempt(:alter_canonical_state)
  end

  test "falsifier 5/7 :promote_own_rule -- model output promoting its own rule is refused" do
    payload = %{"rule_promotion" => %{"rule" => "always reconcile", "into" => "admitted_set"}}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :promote_own_rule}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :promote_own_rule}} =
             LlmBoundary.attempt(:promote_own_rule)
  end

  test "falsifier 6/7 :modify_root_manifest -- model output editing a Root Manifest is refused" do
    payload = %{"root_manifest" => %{"version" => "26.9.16", "capabilities" => ["*"]}}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :modify_root_manifest}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :modify_root_manifest}} =
             LlmBoundary.attempt(:modify_root_manifest)
  end

  test "falsifier 7/7 :execute_consequential_do -- model output dispatching a DO is refused" do
    payload = %{"next" => %{"dispatch" => "AshA2A.Test.Fixture.Item.create"}}

    assert {:error, %{code: :llm_standing_claim_refused, effect: :execute_consequential_do}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    assert {:error, %{code: :llm_effect_refused, effect: :execute_consequential_do}} =
             LlmBoundary.attempt(:execute_consequential_do)
  end

  # --------------------------------------------------------------------
  # Adversarial completeness: the boundary is discriminating, not blanket
  # --------------------------------------------------------------------

  test "adversarial completeness: a clean model payload really does become a candidate" do
    payload = %{
      "goal" => "reconcile the invoice against the ledger",
      "capabilities" => ["AshA2A.Test.Fixture.Item.create"],
      # Deliberately present: `authorities` (plural) is the key a real
      # semantic IR carries and `AshA2A.Semantic.Admission` requires. The
      # claim scan matches EXACT keys, so this must NOT trip the
      # `:grant_authority` refusal -- if it did, this boundary would
      # break the existing compiler payload shape.
      "authorities" => [%{"id" => "a1", "mode" => "described"}]
    }

    assert {:ok, %Resolution{} = resolution} =
             LlmBoundary.candidate(unknown("clean-class"), :llm, payload)

    assert resolution.standing == :candidate
    assert resolution.authority == :none
    assert resolution.resolver == :llm
    assert resolution.class == "clean-class"
    assert resolution.payload == payload
    assert :ok = LlmBoundary.fence(resolution)
  end

  test "every one of the seven prohibited effects is refused; attempt/2 has no success clause" do
    # Exhaustive over the module's own declared list, so adding a new
    # effect without a refusal clause fails here rather than silently.
    assert length(LlmBoundary.prohibited_effects()) == 7

    for effect <- LlmBoundary.prohibited_effects() do
      assert {:error, %{code: :llm_effect_refused, effect: ^effect}} = LlmBoundary.attempt(effect)
    end

    # An effect nobody anticipated also fails closed.
    assert {:error, %{code: :unknown_llm_effect}} = LlmBoundary.attempt(:some_future_effect)
  end

  # --------------------------------------------------------------------
  # DEFECT 5 regression (RFC S40): scan_claim/1 raised on structs.
  #
  # The `is_map(value)` guard is TRUE for a struct, but a struct is not
  # Enumerable, so `Enum.find_value/2` raised Protocol.UndefinedError --
  # despite the docstring claiming the scan "never raises on arbitrary
  # decoded JSON". Worse, the crash PRE-EMPTED a real claim refusal
  # order-dependently: a payload carrying both a struct and a forged
  # `"authority"` key crashed instead of refusing whenever map iteration
  # reached the struct first.
  # --------------------------------------------------------------------

  test "S40 regression: a struct value does not raise, and does not pre-empt a real refusal" do
    # The verifier's exact minimal repro: a DateTime value. `"aaa_..."`
    # sorts before `"authority"`, so the struct is reached FIRST -- which
    # is precisely the ordering that used to crash.
    payload = %{"aaa_observed_at" => ~U[2026-01-01 00:00:00Z], "authority" => "admin"}

    assert {"authority", :grant_authority} = LlmBoundary.scan_claim(payload)

    assert {:error,
            %{code: :llm_standing_claim_refused, effect: :grant_authority, key: "authority"}} =
             LlmBoundary.candidate(unknown(), :llm, payload)

    # The refusal is now order-INdependent: the other key ordering agrees.
    reordered = %{"authority" => "admin", "zzz_observed_at" => ~U[2026-01-01 00:00:00Z]}
    assert {"authority", :grant_authority} = LlmBoundary.scan_claim(reordered)

    # A bare struct, and a struct nested at depth, are leaves -- not
    # containers, and never a raise.
    assert LlmBoundary.scan_claim(~U[2026-01-01 00:00:00Z]) == nil
    assert LlmBoundary.scan_claim(%{"at" => ~U[2026-01-01 00:00:00Z]}) == nil
    assert LlmBoundary.scan_claim(%{"a" => %{"b" => [~U[2026-01-01 00:00:00Z]]}}) == nil
    assert LlmBoundary.scan_claim(%{"a" => [%{"at" => Date.utc_today()}]}) == nil

    # Several other struct shapes the same guard used to crash on.
    for struct_value <- [
          ~U[2026-01-01 00:00:00Z],
          ~D[2026-01-01],
          ~T[10:00:00],
          ~N[2026-01-01 00:00:00],
          MapSet.new([1, 2]),
          %URI{},
          unknown()
        ] do
      assert LlmBoundary.scan_claim(struct_value) == nil
      assert LlmBoundary.scan_claim(%{"v" => struct_value}) == nil

      assert {"root_manifest", :modify_root_manifest} =
               LlmBoundary.scan_claim(%{"aaa" => struct_value, "root_manifest" => "edited"})
    end

    # A struct is not decoded model output at all, so it is not a payload.
    assert {:error, %{code: :llm_output_not_a_map}} =
             LlmBoundary.candidate(unknown(), :llm, ~U[2026-01-01 00:00:00Z])

    # And a clean payload carrying a struct still becomes a real candidate:
    # this is a leaf rule, not a blanket refusal.
    assert {:ok, %Resolution{standing: :candidate, authority: :none} = resolution} =
             LlmBoundary.candidate(unknown("clean-with-struct"), :llm, %{
               "answer" => "42",
               "at" => ~U[2026-01-01 00:00:00Z]
             })

    assert resolution.payload["at"] == ~U[2026-01-01 00:00:00Z]
    assert :ok = LlmBoundary.fence(resolution)
  end

  # --------------------------------------------------------------------
  # Effect 7, end to end, through the REAL CommandBus
  # --------------------------------------------------------------------

  test "effect 7 end-to-end: an LLM-resolved candidate reaches the real CommandBus with no authority and is refused before DO" do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    store_opts = [name: name]

    # A real UNKNOWN resolved by a real (injected, non-mock) resolver
    # function through the real allocator and the real boundary.
    budget = Allocator.new!([inference_calls: 1], issued_by: {:host, __MODULE__})

    resolver = fn %Unknown{} ->
      {:ok, %{"capability_id" => "AshA2A.Test.Fixture.Item.create", "input" => %{"label" => "w"}}}
    end

    assert {:ok, :resolved, %Resolution{} = resolution, _budget} =
             Unknown.route("create-an-item", %{"text" => "make a widget"},
               budget: budget,
               resolver: {:llm, resolver}
             )

    assert resolution.authority == :none

    # The ONLY thing the resolution can contribute is content. There is
    # no code path from a Resolution to an %AshA2A.Authority{} -- the
    # command below is built with `authority: nil` because the boundary
    # cannot produce one.
    command =
      Command.new(resolution.payload["capability_id"],
        command_id: "llm-derived-#{System.unique_integer([:positive])}",
        agent_id: "agent-1",
        principal_id: "subject-1",
        input: resolution.payload["input"]
      )

    assert is_nil(command.authority)

    # Real bus, real `:change`-consequence Ash resource, real refusal.
    assert {:error, %{code: :authority_required}} =
             CommandBus.run(command, data_message(%{"label" => "w"}), Item,
               store_opts: store_opts
             )

    # And no receipt was claimed: the refusal happened before DO.
    assert :error = AshA2A.ReceiptStore.Memory.fetch(command.command_id, store_opts)
  end
end
