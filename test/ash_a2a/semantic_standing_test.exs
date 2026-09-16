defmodule AshA2A.SemanticStandingTest.LaunderingStruct do
  @moduledoc """
  A real struct carrying a field named after one of the S6 forbidden inference
  sources. Not a mock of anything -- it is a plain struct, used to prove that
  the recursive scan descends into struct fields instead of raising on them.
  """
  defstruct [:label, :hook_fired]
end

defmodule AshA2A.SemanticStandingTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.Semantic.Standing` (RFC-SA2A-001 S6/S41).

  Every test drives the real `transition/3` over a real
  `AshA2A.Semantic.Envelope` struct and asserts on the real returned
  envelope or the real returned `AshA2A.Semantic.Refusal` struct. Nothing
  is mocked and nothing is stubbed -- the whole lifecycle is pure Elixir
  and runnable in-process, so a double would only test this file's own
  model of it.

  The `@evidence` table below is real evidence in the shape each step
  demands; the "full walk" test drives all sixteen transitions end to end
  and asserts on the resulting standing and history, not on call counts.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Envelope, Refusal, Standing}

  @evidence %{
    received: %{transport: "a2a/https", received_at: "2026-09-16T00:00:00Z"},
    parsed: %{media_type: "text/turtle", triple_count: 42},
    identified: %{
      graph_digest: "9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d",
      digest_algorithm: "rdfc-1.0/blake3"
    },
    structurally_valid: %{shex_result: %{conformant: true, shape_map: "<s>@<Shape>"}},
    semantically_valid: %{shacl_report: %{conforms: true, results: []}},
    closed: %{closure: %{rule_count: 7, entailed_triple_count: 51}},
    falsifier_clean: %{falsifiers: ["urn:sa2a:falsifier:no-orphan-subject"], violations: []},
    admitted: %{admission_receipt_id: "urn:receipt:admission:1"},
    plannable: %{planning_fingerprint: "sha256:abc", goal_count: 1},
    selected: %{plan_id: "urn:plan:1", step_count: 3},
    constructed: %{command_id: "command:c1", capability_id: "MyApp.Facility.advance"},
    authorized: %{authority_id: "authority:a1", scope: "facility:advance"},
    prepared: %{receipt_anchor_id: "urn:receipt:anchor:1"},
    executed: %{execution_id: "execution:e1", consequence: :change},
    receipted: %{receipt_id: "urn:receipt:1", status: :ok},
    attested: %{receipt_id: "urn:receipt:1", attestation: "sha256:attest"}
  }

  defp candidate do
    {:ok, envelope} =
      Envelope.new(%{envelope_id: "urn:uuid:standing-test", kind: "sa2a:Request"})

    envelope
  end

  # Walks the real chain from :candidate up to (and including) `target`.
  #
  # Every test that needs an envelope *at* some standing goes through here
  # rather than poking `%{envelope | standing: x}`: since the anti-forgery
  # ledger landed, a struct-poked standing is refused
  # (`:standing_ledger_absent`), which is the point -- so the only way to be
  # at a standing in a test is the same way as in production, by earning it.
  defp at(:candidate), do: candidate()
  defp at(target), do: walk_to(target)

  # A real envelope at a terminal standing, reached by a real terminal
  # transition carrying a refusal of a class that terminal actually admits.
  defp at_terminal(terminal) do
    class =
      case terminal do
        :refused -> hd(Refusal.refused_classes())
        :blocked -> hd(Refusal.blocked_classes())
        :unknown -> :blocked_unknown
        :unsupported -> hd(Refusal.unsupported_classes())
        :failed -> :blocked_resource
      end

    {:ok, envelope} =
      Standing.transition(candidate(), terminal, %{
        refusal: Refusal.new(class, :terminal_fixture, :terminal_fixture)
      })

    envelope
  end

  defp walk_to(target) do
    Standing.states()
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 != target))
    |> Kernel.++([target])
    |> Enum.reduce(candidate(), fn step, envelope ->
      {:ok, next} = Standing.transition(envelope, step, Map.fetch!(@evidence, step))
      next
    end)
  end

  describe "the S41 chain" do
    test "is exactly the RFC order, with :candidate as genesis" do
      assert Standing.states() == [
               :candidate,
               :received,
               :parsed,
               :identified,
               :structurally_valid,
               :semantically_valid,
               :closed,
               :falsifier_clean,
               :admitted,
               :plannable,
               :selected,
               :constructed,
               :authorized,
               :prepared,
               :executed,
               :receipted,
               :attested
             ]
    end

    test "terminal states are the RFC five and are all absorbing" do
      assert Standing.terminal_states() == [:refused, :blocked, :unknown, :unsupported, :failed]

      for state <- Standing.terminal_states() do
        assert Standing.terminal?(state)
        assert Standing.rank(state) == nil
      end

      for state <- Standing.states() do
        refute Standing.terminal?(state)
        assert is_integer(Standing.rank(state))
      end
    end

    test "predecessor/1 is the REQUIRED predecessor of every chain state" do
      assert Standing.predecessor(:candidate) == nil
      assert Standing.predecessor(:received) == :candidate
      assert Standing.predecessor(:admitted) == :falsifier_clean
      assert Standing.predecessor(:attested) == :receipted

      Standing.states()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [previous, next] ->
        assert Standing.predecessor(next) == previous
      end)
    end
  end

  describe "the full evidenced walk" do
    test "every step is reachable with real evidence, in order, ending at :attested" do
      final = walk_to(:attested)

      assert final.standing == :attested
      assert length(final.standing_history) == 16

      assert Enum.map(final.standing_history, & &1.to) == Enum.drop(Standing.states(), 1)
      assert Enum.map(final.standing_history, & &1.from) == Enum.drop(Standing.states(), -1)
    end

    test "each history entry carries the real evidence digest for that step" do
      final = walk_to(:attested)

      for entry <- final.standing_history do
        assert entry.evidence_digest == Envelope.evidence_digest(Map.fetch!(@evidence, entry.to))
      end
    end

    test "reaching :admitted takes eight evidenced transitions -- received is not admitted" do
      received = walk_to(:received)
      assert received.standing == :received
      refute received.standing == :admitted

      admitted = walk_to(:admitted)
      assert admitted.standing == :admitted
      assert length(admitted.standing_history) == 8
    end
  end

  describe "no transition may skip a REQUIRED predecessor" do
    test "candidate -> admitted is refused and names the required predecessor" do
      assert {:error, %Refusal{} = refusal} =
               Standing.transition(candidate(), :admitted, @evidence.admitted)

      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_predecessor_skipped
      assert refusal.stage == :admitted
      assert refusal.detail == %{from: :candidate, to: :admitted, required: :falsifier_clean}
      assert refusal.lawful? == true
    end

    test "EVERY non-adjacent forward jump in the whole chain is refused" do
      chain = Standing.states()

      for {from, from_index} <- Enum.with_index(chain),
          {to, to_index} <- Enum.with_index(chain),
          to_index != from_index + 1,
          to != :candidate do
        envelope = at(from)

        assert {:error, %Refusal{code: :standing_predecessor_skipped}} =
                 Standing.transition(envelope, to, Map.get(@evidence, to, %{})),
               "#{from} -> #{to} was not refused"
      end
    end

    test "a backward transition is refused (standing never falls silently)" do
      admitted = walk_to(:admitted)

      assert {:error, %Refusal{code: :standing_predecessor_skipped} = refusal} =
               Standing.transition(admitted, :parsed, @evidence.parsed)

      assert refusal.detail == %{from: :admitted, to: :parsed, required: :received}
    end

    test "a state that is not in the chain at all is REFUSED_STRUCTURE" do
      assert {:error, %Refusal{class: :refused_structure, code: :standing_state_unknown}} =
               Standing.transition(candidate(), :sovereign, %{})
    end
  end

  describe "S6: standing MUST NOT be inferred" do
    test "all 11 forbidden inference sources have a reserved evidence key" do
      assert length(Standing.forbidden_inference_keys()) == 11
      assert Enum.uniq(Standing.forbidden_inference_keys()) == Standing.forbidden_inference_keys()
    end

    test "every forbidden key is refused as evidence, atom-keyed or string-keyed" do
      for key <- Standing.forbidden_inference_keys() do
        atom_keyed = Map.put(@evidence.received, key, "whatever")
        string_keyed = Map.put(@evidence.received, Atom.to_string(key), "whatever")

        for evidence <- [atom_keyed, string_keyed] do
          assert {:error, %Refusal{} = refusal} =
                   Standing.transition(candidate(), :received, evidence),
                 "#{key} was accepted as evidence"

          assert refusal.class == :refused_meta_rigor
          assert refusal.code == :standing_inferred
          assert refusal.detail.forbidden_inference_sources == [key]
        end
      end
    end

    test "a forbidden key cannot be laundered by bundling it with otherwise-valid evidence" do
      # This is the whole point: the evidence below is genuinely sufficient
      # for :received. It is still refused, because :llm_output rode along.
      evidence = Map.put(@evidence.received, :llm_output, "the model says this is fine")

      assert {:error, %Refusal{code: :standing_inferred}} =
               Standing.transition(candidate(), :received, evidence)

      # Remove the forbidden key and the exact same evidence is admitted.
      assert {:ok, envelope} = Standing.transition(candidate(), :received, @evidence.received)
      assert envelope.standing == :received
    end

    test "several forbidden keys at once are all named in the refusal detail" do
      evidence =
        @evidence.received
        |> Map.put(:confidence, 0.99)
        |> Map.put(:no_error, true)
        |> Map.put(:hook_fired, "before_admit")

      assert {:error, %Refusal{code: :standing_inferred} = refusal} =
               Standing.transition(candidate(), :received, evidence)

      assert Enum.sort(refusal.detail.forbidden_inference_sources) ==
               [:confidence, :hook_fired, :no_error]
    end
  end

  describe "evidence appropriate to each step is REQUIRED" do
    test "no step is reachable with empty evidence" do
      for step <- Enum.drop(Standing.states(), 1) do
        envelope = at(Standing.predecessor(step))

        assert {:error, %Refusal{code: :standing_evidence_missing} = refusal} =
                 Standing.transition(envelope, step, %{}),
               "#{step} was reachable with no evidence at all"

        assert refusal.class == Standing.evidence_class(step)
        assert refusal.stage == step
      end
    end

    test "each step's missing keys are named specifically" do
      envelope = at(:falsifier_clean)

      assert {:error, %Refusal{} = refusal} = Standing.transition(envelope, :admitted, %{})
      assert refusal.class == :refused_receipt
      assert refusal.detail.missing == [:admission_receipt_id]
      assert refusal.detail.required == [:admission_receipt_id]
    end

    test ":structurally_valid requires a real ShEx result that actually conformed" do
      envelope = at(:identified)

      # No ShEx result at all.
      assert {:error, %Refusal{class: :refused_structure, code: :standing_evidence_missing}} =
               Standing.transition(envelope, :structurally_valid, %{})

      # A ShEx result that did NOT conform.
      assert {:error, %Refusal{class: :refused_structure, code: :standing_evidence_invalid}} =
               Standing.transition(envelope, :structurally_valid, %{
                 shex_result: %{conformant: false}
               })

      # A real conformant result admits.
      assert {:ok, next} =
               Standing.transition(envelope, :structurally_valid, @evidence.structurally_valid)

      assert next.standing == :structurally_valid
    end

    test ":semantically_valid requires a conformant SHACL report and refuses as REFUSED_SHACL" do
      envelope = at(:structurally_valid)

      assert {:error, %Refusal{class: :refused_shacl, code: :standing_evidence_missing}} =
               Standing.transition(envelope, :semantically_valid, %{})

      assert {:error, %Refusal{class: :refused_shacl, code: :standing_evidence_invalid}} =
               Standing.transition(envelope, :semantically_valid, %{
                 shacl_report: %{conforms: false, results: [%{path: "ex:p"}]}
               })

      assert {:ok, next} =
               Standing.transition(envelope, :semantically_valid, @evidence.semantically_valid)

      assert next.standing == :semantically_valid
    end

    test ":falsifier_clean refuses a claim with no declared falsifiers" do
      envelope = at(:closed)

      assert {:error, %Refusal{class: :refused_falsifier, code: :standing_evidence_invalid}} =
               Standing.transition(envelope, :falsifier_clean, %{falsifiers: [], violations: []})
    end

    test ":falsifier_clean refuses when a declared falsifier actually fired" do
      envelope = at(:closed)

      assert {:error, %Refusal{class: :refused_falsifier} = refusal} =
               Standing.transition(envelope, :falsifier_clean, %{
                 falsifiers: ["urn:sa2a:falsifier:f1"],
                 violations: [%{falsifier: "urn:sa2a:falsifier:f1", at: "ex:s"}]
               })

      assert refusal.detail.violations == [%{falsifier: "urn:sa2a:falsifier:f1", at: "ex:s"}]
    end

    test ":closed requires a real closure result with an entailed triple count" do
      envelope = at(:semantically_valid)

      assert {:error, %Refusal{class: :refused_rule, code: :standing_evidence_invalid}} =
               Standing.transition(envelope, :closed, %{closure: %{rule_count: 3}})

      assert {:error, %Refusal{class: :refused_rule}} =
               Standing.transition(envelope, :closed, %{closure: "done"})
    end

    test ":plannable and :selected require positive counts, not merely present ones" do
      plannable_from = at(:admitted)

      assert {:error, %Refusal{class: :refused_plan, code: :standing_evidence_invalid}} =
               Standing.transition(plannable_from, :plannable, %{
                 planning_fingerprint: "sha256:abc",
                 goal_count: 0
               })

      selected_from = at(:plannable)

      assert {:error, %Refusal{class: :refused_plan, code: :standing_evidence_invalid}} =
               Standing.transition(selected_from, :selected, %{plan_id: "p", step_count: 0})
    end

    test ":parsed requires a non-negative integer triple count" do
      assert {:error, %Refusal{code: :standing_evidence_invalid}} =
               Standing.transition(walk_to(:received), :parsed, %{
                 media_type: "text/turtle",
                 triple_count: "lots"
               })
    end

    test "string-keyed evidence is accepted (it is the real wire shape)" do
      assert {:ok, envelope} =
               Standing.transition(candidate(), :received, %{
                 "transport" => "a2a/https",
                 "received_at" => "2026-09-16T00:00:00Z"
               })

      assert envelope.standing == :received
    end

    test "each step's evidence-failure class matches the class that owns that step" do
      expected = %{
        received: :refused_structure,
        parsed: :refused_structure,
        identified: :refused_identity,
        structurally_valid: :refused_structure,
        semantically_valid: :refused_shacl,
        closed: :refused_rule,
        falsifier_clean: :refused_falsifier,
        admitted: :refused_receipt,
        plannable: :refused_plan,
        selected: :refused_plan,
        constructed: :refused_capability,
        authorized: :refused_authority,
        prepared: :refused_receipt,
        executed: :refused_consequence,
        receipted: :refused_receipt,
        attested: :refused_provenance
      }

      for {step, class} <- expected do
        assert Standing.evidence_class(step) == class
        assert Refusal.class?(class)
      end
    end
  end

  describe "envelope bounds are honoured at :parsed (REFUSED_BOUNDS)" do
    test "a triple count over the declared maxTriples bound is refused" do
      {:ok, bounded} =
        Envelope.new(%{
          envelope_id: "urn:uuid:bounded",
          kind: "sa2a:Request",
          bounds: %{"maxTriples" => 10}
        })

      {:ok, received} = Standing.transition(bounded, :received, @evidence.received)

      assert {:error, %Refusal{} = refusal} =
               Standing.transition(received, :parsed, %{
                 media_type: "text/turtle",
                 triple_count: 11
               })

      assert refusal.class == :refused_bounds
      assert refusal.code == :standing_bounds_exceeded
      assert refusal.detail == %{bound: :maxTriples, limit: 10, observed: 11}
    end

    test "a triple count at the bound is admitted" do
      {:ok, bounded} =
        Envelope.new(%{
          envelope_id: "urn:uuid:bounded-ok",
          kind: "sa2a:Request",
          bounds: %{"maxTriples" => 10}
        })

      {:ok, received} = Standing.transition(bounded, :received, @evidence.received)

      assert {:ok, parsed} =
               Standing.transition(received, :parsed, %{
                 media_type: "text/turtle",
                 triple_count: 10
               })

      assert parsed.standing == :parsed
    end
  end

  describe "terminal transitions (a refusal is a lawful outcome)" do
    test "any non-terminal state may transition to :refused with a real refusal" do
      refusal = Refusal.new(:refused_shacl, :shacl_nonconformant, :semantically_valid, %{n: 2})

      for state <- Standing.states() do
        envelope = at(state)

        assert {:ok, refused} = Standing.transition(envelope, :refused, %{refusal: refusal})
        assert refused.standing == :refused
        assert %{from: ^state, to: :refused} = List.last(refused.standing_history)
      end
    end

    test "the terminal history entry records the refusal class/code/stage" do
      refusal = Refusal.new(:refused_authority, :authority_required, :authorize)

      {:ok, refused} = Standing.transition(walk_to(:constructed), :refused, %{refusal: refusal})

      entry = List.last(refused.standing_history)
      assert entry.to == :refused
      assert entry.evidence_keys == ["refusal_class", "refusal_code", "refusal_stage"]
    end

    test "terminal class families are enforced: a REFUSED_* class cannot land in :blocked" do
      refusal = Refusal.new(:refused_authority, :authority_required, :authorize)

      assert {:error, %Refusal{code: :standing_terminal_evidence_invalid} = error} =
               Standing.transition(candidate(), :blocked, %{refusal: refusal})

      assert error.detail.refusal_class == :refused_authority
      assert error.detail.admissible_classes == Refusal.blocked_classes()
    end

    test "BLOCKED_RESOURCE lands in :blocked, BLOCKED_UNKNOWN in :unknown" do
      assert {:ok, blocked} =
               Standing.transition(candidate(), :blocked, %{
                 refusal: Refusal.new(:blocked_resource, :hddl_cli_not_built, :plan)
               })

      assert blocked.standing == :blocked

      assert {:ok, unknown} =
               Standing.transition(candidate(), :unknown, %{
                 refusal: Refusal.new(:blocked_unknown, :unclassified_error, :parse)
               })

      assert unknown.standing == :unknown
    end

    test "UNSUPPORTED_PROFILE lands in :unsupported and nothing else does" do
      assert {:ok, unsupported} =
               Standing.transition(candidate(), :unsupported, %{
                 refusal: Refusal.new(:unsupported_profile, :unknown_profile, :envelope)
               })

      assert unsupported.standing == :unsupported

      assert {:error, %Refusal{code: :standing_terminal_evidence_invalid}} =
               Standing.transition(candidate(), :unsupported, %{
                 refusal: Refusal.new(:blocked_resource, :enoent, :parse)
               })
    end

    test ":failed accepts any refusal class" do
      for class <- Refusal.classes() do
        assert {:ok, failed} =
                 Standing.transition(candidate(), :failed, %{
                   refusal: Refusal.new(class, :some_code, :some_stage)
                 })

        assert failed.standing == :failed
      end
    end

    test "a terminal transition without a real Refusal struct is refused" do
      assert {:error, %Refusal{} = refusal} =
               Standing.transition(candidate(), :refused, %{reason: "because"})

      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_terminal_evidence_invalid
      assert refusal.detail.evidence_keys == ["reason"]

      assert {:error, %Refusal{code: :standing_terminal_evidence_invalid}} =
               Standing.transition(candidate(), :refused, %{})
    end
  end

  describe "terminal states are absorbing" do
    test "nothing transitions out of a terminal state, forward or terminal" do
      for terminal <- Standing.terminal_states() do
        envelope = at_terminal(terminal)

        assert {:error, %Refusal{code: :standing_terminal} = refusal} =
                 Standing.transition(envelope, :received, @evidence.received)

        assert refusal.class == :refused_meta_rigor
        assert refusal.detail.from == terminal

        assert {:error, %Refusal{code: :standing_terminal}} =
                 Standing.transition(envelope, :failed, %{
                   refusal: Refusal.new(:blocked_unknown, :c, :s)
                 })
      end
    end
  end

  describe "DEFECT 3 regression: standing carried on the struct cannot be forged" do
    test "the verifier's minimal 3-line repro -- a struct built directly with standing: :admitted" do
      # Measured before the fix: this returned {:ok, envelope} at :plannable,
      # because transition/3 read :standing straight off the struct.
      forged = %Envelope{
        envelope_id: "urn:uuid:forged",
        kind: "sa2a:Request",
        standing: :admitted
      }

      assert {:error, %Refusal{} = refusal} =
               Standing.transition(forged, :plannable, @evidence.plannable)

      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_ledger_absent
      assert refusal.detail.claimed_standing == :admitted
    end

    test "EVERY non-genesis standing is unreachable by struct forgery" do
      for state <- Standing.states() ++ Standing.terminal_states(), state != :candidate do
        forged = %Envelope{envelope_id: "urn:uuid:f", kind: "sa2a:Request", standing: state}

        assert {:error, %Refusal{code: :standing_ledger_absent}} =
                 Standing.transition(forged, :received, @evidence.received),
               "forging standing #{state} was not refused"
      end
    end

    test "a hand-fabricated standing history is refused: the seal does not verify" do
      fabricated = [
        %{
          from: :candidate,
          to: :admitted,
          at: "2026-01-01T00:00:00Z",
          evidence_keys: ["admission_receipt_id"],
          evidence_digest: "sha256:deadbeef"
        }
      ]

      forged = %Envelope{
        envelope_id: "urn:uuid:f",
        kind: "sa2a:Request",
        standing: :admitted,
        standing_history: fabricated,
        standing_seal:
          "hmac-sha256:0000000000000000000000000000000000000000000000000000000000000000"
      }

      assert {:error, %Refusal{code: :standing_ledger_unsealed}} =
               Standing.transition(forged, :plannable, @evidence.plannable)
    end

    test "a genuinely-earned ledger whose entries are then tampered with is refused" do
      admitted = at(:admitted)
      [first | rest] = admitted.standing_history

      tampered = %{admitted | standing_history: [%{first | to: :admitted} | rest]}

      assert {:error, %Refusal{code: :standing_ledger_discontinuous}} =
               Standing.transition(tampered, :plannable, @evidence.plannable)
    end

    test "a real ledger whose standing runs ahead of its own evidence is refused" do
      parsed = at(:parsed)
      ahead = %{parsed | standing: :admitted}

      assert {:error, %Refusal{code: :standing_ledger_inconsistent} = refusal} =
               Standing.transition(ahead, :plannable, @evidence.plannable)

      assert refusal.detail.claimed_standing == :admitted
      assert refusal.detail.evidenced_standing == :parsed
    end

    test "the lawful 8-step walk to :admitted still works and produces a verifying seal" do
      admitted = at(:admitted)

      assert admitted.standing == :admitted
      assert length(admitted.standing_history) == 8
      assert String.starts_with?(admitted.standing_seal, "hmac-sha256:")

      # And it keeps going lawfully from there.
      assert {:ok, plannable} = Standing.transition(admitted, :plannable, @evidence.plannable)
      assert plannable.standing == :plannable
      assert length(plannable.standing_history) == 9
    end

    test "skip-prevention is preserved on top of the ledger, not replaced by it" do
      # The ledger check runs FIRST, so this envelope is genuinely at :parsed
      # -- the refusal below is the original predecessor rule still firing.
      parsed = at(:parsed)

      assert {:error, %Refusal{code: :standing_predecessor_skipped} = refusal} =
               Standing.transition(parsed, :admitted, @evidence.admitted)

      assert refusal.detail == %{from: :parsed, to: :admitted, required: :falsifier_clean}
    end
  end

  describe "DEFECT 4 regression: an inference cannot be laundered by nesting it" do
    test "the verifier's minimal repro -- a forbidden key one level down" do
      # Measured before the fix: {:ok, envelope} at :received, because
      # reject_inference/2 only scanned top-level keys with Map.has_key?/2.
      evidence =
        Map.merge(@evidence.received, %{bundle: %{llm_output: "the model says it is fine"}})

      assert {:error, %Refusal{} = refusal} =
               Standing.transition(candidate(), :received, evidence)

      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_inferred
      assert refusal.detail.forbidden_inference_sources == [:llm_output]
      assert refusal.detail.forbidden_inference_paths == [["bundle", "llm_output"]]
    end

    test "every forbidden key is caught at depth, atom-keyed and string-keyed alike" do
      for key <- Standing.forbidden_inference_keys(),
          nested <- [%{key => true}, %{Atom.to_string(key) => true}] do
        evidence = Map.merge(@evidence.received, %{wrapper: %{inner: nested}})

        assert {:error, %Refusal{code: :standing_inferred} = refusal} =
                 Standing.transition(candidate(), :received, evidence),
               "nested #{key} was not refused"

        assert refusal.detail.forbidden_inference_sources == [key]
        assert refusal.detail.forbidden_inference_paths == [["wrapper", "inner", key_name(key)]]
      end
    end

    test "a forbidden key buried inside a list is caught, with its index in the path" do
      evidence =
        Map.merge(@evidence.received, %{
          results: [%{ok: true}, %{meta: %{"confidence" => 0.99}}]
        })

      assert {:error, %Refusal{code: :standing_inferred} = refusal} =
               Standing.transition(candidate(), :received, evidence)

      assert refusal.detail.forbidden_inference_sources == [:confidence]
      assert refusal.detail.forbidden_inference_paths == [["results", 1, "meta", "confidence"]]
    end

    test "a struct value does not raise Protocol.UndefinedError, it is scanned" do
      # is_map/1 is true for a struct but a struct is not Enumerable, so the
      # naive recursive walk raises here. A plain struct carrying no forbidden
      # field must simply pass.
      evidence = Map.merge(@evidence.received, %{observed_at: ~U[2026-09-16 00:00:00Z]})

      assert {:ok, received} = Standing.transition(candidate(), :received, evidence)
      assert received.standing == :received
    end

    test "a struct CARRYING a forbidden field is refused, not skipped" do
      evidence =
        Map.merge(@evidence.received, %{
          probe: %AshA2A.SemanticStandingTest.LaunderingStruct{label: "x", hook_fired: true}
        })

      assert {:error, %Refusal{code: :standing_inferred} = refusal} =
               Standing.transition(candidate(), :received, evidence)

      assert refusal.detail.forbidden_inference_sources == [:hook_fired]
      assert refusal.detail.forbidden_inference_paths == [["probe", "hook_fired"]]
    end

    test "a struct nested inside a list inside a map is still scanned" do
      evidence =
        Map.merge(@evidence.received, %{
          audit: [
            %{step: 1},
            %{
              trace: %AshA2A.SemanticStandingTest.LaunderingStruct{
                label: "y",
                hook_fired: false
              }
            }
          ]
        })

      assert {:error, %Refusal{code: :standing_inferred} = refusal} =
               Standing.transition(candidate(), :received, evidence)

      assert refusal.detail.forbidden_inference_paths == [["audit", 1, "trace", "hook_fired"]]
    end

    test "evidence nested past the scan depth is refused, never scanned partially" do
      deep =
        Enum.reduce(1..(Standing.max_evidence_depth() + 5), %{leaf: true}, fn _i, acc ->
          %{nested: acc}
        end)

      assert {:error, %Refusal{code: :standing_evidence_too_deep} = refusal} =
               Standing.transition(candidate(), :received, Map.merge(@evidence.received, deep))

      assert refusal.class == :refused_meta_rigor
      assert refusal.detail.max_depth == Standing.max_evidence_depth()
    end

    test "clean nested evidence still passes -- the scan bans keys, not nesting" do
      evidence =
        Map.merge(@evidence.received, %{
          transport_detail: %{tls: %{version: "1.3", cipher: "TLS_AES_256_GCM_SHA384"}},
          hops: [%{host: "a"}, %{host: "b"}]
        })

      assert {:ok, received} = Standing.transition(candidate(), :received, evidence)
      assert received.standing == :received
    end
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)

  describe "transition/3 never raises on malformed input" do
    test "non-map evidence is a refusal, not an exception" do
      assert {:error, %Refusal{code: :standing_evidence_invalid}} =
               Standing.transition(candidate(), :received, "not a map")

      assert {:error, %Refusal{code: :standing_evidence_invalid}} =
               Standing.transition(candidate(), :received, nil)
    end
  end
end
