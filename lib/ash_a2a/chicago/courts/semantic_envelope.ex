defmodule AshA2A.Chicago.Courts.SemanticEnvelope do
  @moduledoc """
  RFC-SA2A-002 §54 Semantic Envelope Court (`SA2A-ENV`).

  Attacks the real receiving boundary -- `AshA2A.Semantic.Peer` inside a real
  `A2A.Agent` GenServer reached through a real `A2A.call/3` -- with inbound
  envelopes that are admissible in every respect except the one field under
  attack, so removing the guard for that field lets the envelope acquire
  `:admitted` standing (§11 last paragraph). Two positive controls prove the
  boundary discriminates (§100): the unmutated envelope is admitted, and an
  envelope referencing a genuine receipt from this peer's own receipt store is
  admitted.

  Attempt evidence is the peer's own boundary telemetry
  (`sa2a.env.receive` / `sa2a.env.admission.start`); survival evidence is the
  peer's `sa2a.env.decision` plus the peer's real `Standing.Ledger` read back
  independently (§73). The upstream participant never self-asserts a stronger
  standing than its receipts establish (§54 last paragraph): self-declared
  standing, a forged standing history and forged or tampered receipt
  references are all attacks here.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.SemanticBoundary, as: SB
  alias AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport, as: Fx
  alias AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.{Envelopes, Graphs, Ordering}
  alias AshA2A.Semantic.GraphLaw

  @court "SA2A-ENV"
  @receive "sa2a.env.receive"
  @admission "sa2a.env.admission.start"
  @decision "sa2a.env.decision"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Semantic Envelope Court"
  @impl true
  def gate, do: 2
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§54", "§11", "§12", "§100", "§101"]

  @impl true
  def ocel_mappings, do: SB.peer_mappings("sa2a.env", __MODULE__)

  @admitted {:observed, @decision, %{"standing" => "admitted"}}
  @activated {:observed, @receive, %{"activated" => "true"}}

  # {id suffix, field, attack, guard, failure class, attempt predicate}
  @attacks [
    {"001", "missing envelope identity", "payload without envelopeId",
     "Envelope.validate_envelope_id/1", :identity_failure, @activated},
    {"002", "invalid standing escalation (self-declared standing)",
     "payload declaring standing \"executed\"", "Envelope.reject_declared_standing/1",
     :admission_failure, @activated},
    {"003", "invalid standing escalation (forged standing history)",
     "payload carrying a fabricated candidate->admitted->executed standingHistory",
     "Envelope.decode_history/1", :admission_failure, @activated},
    {"004", "missing semantic basis", "payload with semanticBasis []",
     "Peer semantic-basis admission check", :admission_failure, {:observed, @admission}},
    {"005", "mismatched graph digest",
     "payload whose graph.digest is the real engine digest of a DIFFERENT graph",
     "Peer.check_claimed_digest/2", :identity_failure, {:observed, @admission}},
    {"006", "missing provenance", "payload with provenance {}", "Peer provenance admission check",
     :admission_failure, {:observed, @admission}},
    {"008", "invalid consequence class", "payload with consequenceClass \"irreversible_launch\"",
     "Envelope.validate_consequence_class/1", :admission_failure, @activated},
    {"009", "invalid authority requirement (unknown requirement)",
     "payload with authorityRequirement \"root\"", "Envelope.validate_authority_requirement/1",
     :authority_failure, @activated},
    {"010", "invalid authority requirement (consequence without authority requirement)",
     "payload with consequenceClass \"external_do\" and authorityRequirement \"none\"",
     "Peer consequence/authority-requirement admission check", :authority_failure,
     {:observed, @admission}},
    {"011", "forged receipt reference",
     "payload referencing a receipt this peer's receipt store never recorded",
     "Peer receipt-reference verification", :receipt_failure, {:observed, @admission}},
    {"012", "tampered receipt reference",
     "payload referencing a genuine receipt with a rewritten fingerprint and status",
     "Peer receipt-reference verification", :receipt_failure, {:observed, @admission}}
  ]

  @impl true
  def falsifiers do
    negatives =
      Enum.map(@attacks, fn {n, what, stimulus, guard, class, attempt} ->
        Falsifier.new!(
          id: "#{@court}-#{n}",
          court_id: @court,
          kind: :negative,
          invariant:
            "An inbound envelope with #{what} never acquires :admitted standing at the receiving peer",
          stimulus: "real A2A.call/3 of an SA2A-activated message: #{stimulus}",
          boundary: "AshA2A.Semantic.Peer.receive_message/3 in a real A2A.Agent",
          forbidden_outcome: "peer decision standing :admitted for the attacked envelope",
          attempt_evidence:
            "peer boundary telemetry #{inspect(attempt)} attributed to the stimulus",
          survival_evidence:
            "#{@decision} standing=admitted, or an :admitted edge in the peer's real Standing.Ledger",
          guard: guard,
          failure_class: class,
          rfc_sections: ["§54", "§12"],
          attempt_predicate: attempt,
          outcome_predicate: @admitted
        )
      end)

    unsupported =
      Falsifier.new!(
        id: "#{@court}-007",
        court_id: @court,
        kind: :unsupported_control,
        invariant:
          "An envelope declaring a profile this runtime does not implement surfaces as typed UNSUPPORTED_PROFILE, never admitted and never collapsed into REFUSED",
        stimulus:
          "real A2A.call/3 of an activated payload with profile urn:sa2a:profile:core:v99.0.0",
        boundary: "AshA2A.Semantic.Peer.receive_message/3 + Envelope.validate_profile/1",
        attempt_evidence: "#{@receive} activated=true",
        survival_evidence: "#{@decision} standing=unsupported class=unsupported_profile",
        rfc_sections: ["§54", "§101"],
        attempt_predicate: @activated,
        outcome_predicate:
          {:all,
           [
             {:observed, @decision,
              %{"standing" => "unsupported", "class" => "unsupported_profile"}},
             {:not_observed, @decision, %{"standing" => "admitted"}}
           ]}
      )

    controls = [
      Falsifier.new!(
        id: "#{@court}-013",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "A complete envelope (identity, known profile, semantic basis, true digest, provenance, lawful classes) IS admitted -- the boundary discriminates",
        stimulus: "real A2A.call/3 of the unmutated admissible payload",
        boundary: "AshA2A.Semantic.Peer + real praxis-graphlaw engine",
        attempt_evidence: "#{@admission} for the envelope",
        survival_evidence:
          "#{@decision} standing=admitted preceded by admission of the same envelope; ledger path received->candidate->admitted",
        rfc_sections: ["§54", "§100"],
        attempt_predicate: {:observed, @admission},
        outcome_predicate:
          {:all,
           [
             @admitted,
             {:precedes, @admission, @decision, "sa2a_envelope"}
           ]}
      ),
      Falsifier.new!(
        id: "#{@court}-014",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "An envelope whose receipt reference resolves to a genuine receipt in this peer's own store IS admitted -- receipt verification discriminates",
        stimulus:
          "real A2A.call/3 of the admissible payload referencing a receipt committed by the real CommandBus",
        boundary: "AshA2A.Semantic.Peer receipt-reference verification",
        attempt_evidence: "#{@admission} for the envelope",
        survival_evidence: "#{@decision} standing=admitted",
        rfc_sections: ["§54", "§100"],
        attempt_predicate: {:observed, @admission},
        outcome_predicate: @admitted
      )
    ]

    negatives ++ [unsupported] ++ controls
  end

  @impl true
  def run(%Context{} = ctx) do
    if Fx.engine_available?() do
      run_against_engine(ctx)
    else
      Enum.map(
        falsifiers(),
        &Result.blocked(&1, "the real praxis-graphlaw engine is unreachable from this runtime")
      )
    end
  end

  defp run_against_engine(ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    {:ok, digest} = GraphLaw.graph_hash(Graphs.conforming())
    {:ok, other_digest} = GraphLaw.graph_hash(Graphs.nonconforming())

    with_receipt_store(fn store, receipt ->
      SB.with_peer(
        "env",
        fn agent, ledger ->
          [
            name: "chicago-env-peer",
            ledger: ledger,
            shapes: Graphs.shapes(),
            mode: :strict,
            agent_card: SB.served_card!(agent, :compatible),
            receipt_store: {AshA2A.ReceiptStore.Memory, [name: store]}
          ]
        end,
        fn %{agent: agent, ledger: ledger} ->
          base = fn overrides -> Envelopes.admissible(Graphs.conforming(), digest, overrides) end
          genuine = receipt_reference(receipt)

          payloads = %{
            "001" => Map.delete(base.(%{}), "envelopeId"),
            "002" => base.(%{"standing" => "executed"}),
            "003" =>
              base.(%{
                "standingHistory" => [
                  %{"from" => "candidate", "to" => "admitted", "evidenceKeys" => ["graphlaw"]},
                  %{"from" => "admitted", "to" => "executed", "evidenceKeys" => ["receipt"]}
                ]
              }),
            "004" => base.(%{"semanticBasis" => []}),
            "005" => base.(%{"graph" => graph(Graphs.conforming(), other_digest)}),
            "006" => base.(%{"provenance" => %{}}),
            "007" => base.(%{"profile" => "urn:sa2a:profile:core:v99.0.0"}),
            "008" => base.(%{"consequenceClass" => "irreversible_launch"}),
            "009" => base.(%{"authorityRequirement" => "root"}),
            "010" =>
              base.(%{"consequenceClass" => "external_do", "authorityRequirement" => "none"}),
            "011" =>
              base.(%{
                "receipts" => [
                  %{
                    "receiptId" => "runtime:" <> Ash.UUIDv7.generate(),
                    "commandId" => "command:chicago-never-executed-#{System.unique_integer()}",
                    "fingerprint" => String.duplicate("a", 64),
                    "status" => "completed"
                  }
                ]
              }),
            "012" =>
              base.(%{
                "receipts" => [
                  genuine
                  |> Map.put("fingerprint", String.duplicate("b", 64))
                  |> Map.put("status", "completed_with_authority")
                ]
              }),
            "013" => base.(%{}),
            "014" => base.(%{"receipts" => [genuine]})
          }

          payloads
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {n, payload} ->
            f = Map.fetch!(fs, "#{@court}-#{n}")
            judge(ctx, f, agent, ledger, payload)
          end)
        end
      )
    end)
  end

  defp judge(ctx, %Falsifier{} = f, agent, ledger, payload) do
    before = AshA2A.Semantic.Standing.Ledger.entries(ledger)
    message = Envelopes.activated(payload)
    reply = Context.stimulus(ctx, f, fn -> SB.call(agent, message) end)
    appended = SB.new_entries(ledger, before)
    ledger_admitted? = Enum.any?(appended, &(&1.to == :admitted))

    evidence = %{
      "reply" => SB.evidence(reply),
      "ledger" => Enum.map(appended, &"#{&1.envelope_id}: #{&1.from}->#{&1.to} (#{&1.reason})")
    }

    admitted? = SB.observed?(ctx, f, @decision, %{"standing" => "admitted"}) or ledger_admitted?

    case f.kind do
      :negative ->
        {activity, attrs} = attempt_activity(f.attempt_predicate)

        Result.negative(f,
          attempt_observed?: SB.observed?(ctx, f, activity, attrs),
          forbidden_outcome_observed?: admitted?,
          evidence: evidence
        )

      :unsupported_control ->
        Result.positive(f,
          attempt_observed?: SB.observed?(ctx, f, @receive, %{"activated" => "true"}),
          expected_outcome_observed?:
            not admitted? and
              SB.observed?(ctx, f, @decision, %{
                "standing" => "unsupported",
                "class" => "unsupported_profile"
              }),
          evidence: evidence
        )

      :positive_control ->
        Result.positive(f,
          attempt_observed?: SB.observed?(ctx, f, @admission),
          expected_outcome_observed?: admitted? and ledger_admitted?,
          evidence: evidence
        )
    end
  end

  defp attempt_activity({:observed, activity}), do: {activity, %{}}
  defp attempt_activity({:observed, activity, attrs}), do: {activity, attrs}

  defp graph(content, digest),
    do: %{"mediaType" => "text/turtle", "digest" => digest, "content" => content}

  defp receipt_reference(receipt) do
    %{
      "receiptId" => Identity.external(receipt.receipt_id),
      "commandId" => Identity.external(receipt.command_id),
      "fingerprint" => receipt.fingerprint,
      "status" => Atom.to_string(receipt.status)
    }
  end

  # A genuine receipt committed by the real CommandBus over the real Ordering
  # resource into a real, court-owned Memory receipt store. Created outside
  # any stimulus: it is setup evidence, not an attack.
  defp with_receipt_store(fun) do
    store = :"chicago_env_receipts_#{System.unique_integer([:positive])}"
    {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: store)

    try do
      principal = Identity.principal("chicago-env-receipt-principal")
      label = Fx.unique("chicago-env-receipt")

      command =
        Command.new("place_order",
          command_id: label,
          agent_id: "chicago-env-agent",
          principal_id: principal,
          authority: Authority.new(principal, "place_order", token_id: "tok-" <> label),
          input: %{"item" => label, "quantity" => 1}
        )

      {:ok, receipt} =
        CommandBus.run(
          command,
          Envelopes.ordinary([A2A.Part.Data.new(%{"item" => label, "quantity" => 1})]),
          Ordering,
          store_opts: [name: store]
        )

      fun.(store, receipt)
    after
      SB.stop(pid)
    end
  end
end
