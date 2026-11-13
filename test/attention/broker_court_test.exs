defmodule AshA2A.Attention.BrokerCourtTest do
  @moduledoc """
  Article-14 attention broker court. Clock injection only — zero
  `Process.sleep`. Exercises window expiry, supervised override
  semantics, override short-circuit, founder escalation, and the
  GPM-floor signature invariant on cards built from the landed
  Vince/Tony stack.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Attention.Broker

  @window 5_000

  defp card(opts \\ []) do
    %{
      options: [
        %{
          option_id: :accept,
          summary: "accept",
          consequence: "trade executes",
          requires_signature: Keyword.get(opts, :requires_signature, false)
        }
      ],
      source: :manual,
      gpm_floor_breach: false
    }
  end

  defp gpm_card do
    %{
      options: [
        %{
          option_id: :accept,
          summary: "accept below floor",
          consequence: "margin breach",
          requires_signature: false
        }
      ],
      source: :gpm_floor,
      gpm_floor_breach: true
    }
  end

  describe "consent by silence" do
    test "executes after the injected clock passes the window at :consent_by_silence" do
      {:ok, p} = Broker.propose(:co_1, card(), level: :consent_by_silence, now: 1_000)

      assert {:awaiting, :window_open} = Broker.consent_by_silence(p, @window, 1_000 + @window - 1)
      assert {:executed, :silence_consent} = Broker.consent_by_silence(p, @window, 1_000 + @window)
      assert {:executed, :silence_consent} = Broker.consent_by_silence(p, @window, 9_999_999)
    end

    test "executes at :autonomous after window expiry" do
      {:ok, p} = Broker.propose(:co_1, card(), level: :autonomous, now: 0)
      assert {:executed, :silence_consent} = Broker.consent_by_silence(p, @window, @window)
    end

    test ":supervised NEVER auto-executes, regardless of elapsed window" do
      {:ok, p} = Broker.propose(:co_1, card(), level: :supervised, now: 0)
      assert {:awaiting, :supervisor} = Broker.consent_by_silence(p, @window, 10_000_000)
    end

    test "window boundary is exact: expiry at exactly window_ms" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)
      assert {:awaiting, :window_open} = Broker.consent_by_silence(p, @window, @window - 1)
      assert {:executed, :silence_consent} = Broker.consent_by_silence(p, @window, @window)
    end
  end

  describe "override" do
    test "records a human decision in the ledger and short-circuits silence" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)

      {:ok, ledger, entry} = Broker.override(p, "sig-founder", :reject)

      assert entry.proposal_id == p.id
      assert entry.decision == :reject
      assert {:refused, :already_decided} = Broker.consent_by_silence(p, @window, 10_000_000, ledger)
    end

    test "override with approval also blocks silence execution" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)
      {:ok, ledger, _} = Broker.override(p, "sig-op", :approve)

      assert {:refused, :already_decided} =
               Broker.consent_by_silence(p, @window, 10_000_000, ledger)
    end

    test "second decision on one proposal is refused (no approve+reject)" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)
      {:ok, ledger, _} = Broker.override(p, "sig-a", :approve)

      assert {:refused, :already_decided} = Broker.override(p, "sig-b", :reject, ledger)
      assert {:refused, :already_decided} = Broker.override(p, "sig-b", :approve, ledger)
      assert length(ledger[p.id]) == 1
    end

    test "decided ledger beats :supervised in consent_by_silence" do
      {:ok, p} = Broker.propose(:co_1, card(), level: :supervised, now: 0)
      {:ok, ledger, _} = Broker.override(p, "sig", :approve)
      assert {:refused, :already_decided} = Broker.consent_by_silence(p, @window, 0, ledger)
    end

    test "registered undecided proposal is not 'decided' and is seen by escalation" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)
      ledger = Broker.register(%{}, p)
      assert {:executed, :silence_consent} = Broker.consent_by_silence(p, @window, @window, ledger)
      assert {:page, :founder} = Broker.escalation_path(ledger, unresolved_threshold: 1)
    end

    test "GPM-floor card refuses unsigned override; signed override accepted" do
      {:ok, p} = Broker.propose(:co_1, gpm_card(), now: 0)
      assert {:refused, :signature_required} = Broker.override(p, nil, :approve)
      assert {:refused, :signature_required} = Broker.override(p, "", :reject)
      assert {:ok, _, _} = Broker.override(p, "sig", :approve)
    end

    test "override accepts injected :now" do
      {:ok, p} = Broker.propose(:co_1, card(), now: 0)
      {:ok, _ledger, entry} = Broker.override(p, "sig", :approve, %{}, now: 4242)
      assert entry.recorded_at == 4242
    end
  end

  describe "propose level guard" do
    test "invalid level is a typed error; valid proposal carries at_least_one_signed" do
      assert {:error, {:invalid_level, :bogus}} = Broker.propose(:co_1, card(), level: :bogus)
      {:ok, p} = Broker.propose(:co_1, card())
      assert p.at_least_one_signed == false
    end
  end

  describe "escalation path" do
    test "pages founder when unresolved proposals reach the threshold" do
      ledger =
        1..3
        |> Enum.map(fn _ ->
          {:ok, p} = Broker.propose(:co_1, card(), now: 0)
          {p.id, []}
        end)
        |> Map.new()

      assert {:page, :founder} = Broker.escalation_path(ledger)
    end

    test "no escalation below threshold or when decisions are recorded" do
      {:ok, p1} = Broker.propose(:co_1, card(), now: 0)
      {:ok, p2} = Broker.propose(:co_1, card(), now: 0)
      {:ok, ledger, _} = Broker.override(p1, "sig", :approve)

      assert :no_escalation = Broker.escalation_path(%{p1.id => ledger[p1.id], p2.id => []})
      assert :no_escalation = Broker.escalation_path(%{p2.id => []})

      # Threshold is configurable.
      assert {:page, :founder} = Broker.escalation_path(%{p2.id => []}, unresolved_threshold: 1)
    end
  end

  describe "GPM-floor signature invariant" do
    test "propose forces requires_signature on all options of a GPM-floor card" do
      raw = gpm_card()

      assert Enum.any?(raw.options, &(&1.requires_signature == false))

      {:ok, p} = Broker.propose(:co_1, raw)
      assert Enum.all?(p.card.options, &(&1.requires_signature == true))
    end

    test "build_card/3 from a Tony triage escalation edge forces signatures" do
      triage = {[], [%{ticket: %{id: "t1", warranty_status: :expired}}]}

      built = Broker.build_card(nil, triage)
      assert built.gpm_floor_breach == true
      assert Enum.all?(built.options, &(&1.requires_signature == true))

      {:ok, p} = Broker.propose(:co_1, built)
      assert Enum.all?(p.card.options, &(&1.requires_signature == true))
    end

    test "build_card/3 from a routine triage does NOT force signatures" do
      built = Broker.build_card(nil, {[%{ticket: %{id: "t1"}}], []})
      assert built.gpm_floor_breach == false
      assert Enum.all?(built.options, &(&1.requires_signature == false))
    end

    test "build_card/3 from a GPM-floor vince challenge forces signatures" do
      challenge = %{code: :monkey_math, demanded_evidence: :cost_breakdown}
      built = Broker.build_card(challenge, nil)
      assert built.gpm_floor_breach == true
      assert Enum.all?(built.options, &(&1.requires_signature == true))
    end
  end

  describe "build_card integration with the landed stack (real collaborators)" do
    test "vince GPM-floor breach challenge produces a signature-required card" do
      vince = AshA2A.Twin.Vince.new()
      # offer 9000 on nte 10000 -> gpm 0.1 < floor 0.22 -> :gpm_floor challenge.
      nte = 10_000
      offer = 9_000

      assert AshA2A.Twin.Vince.gpm_breach?(nte, offer, 0.22)

      {_, {:challenge, challenge}} =
        AshA2A.Twin.Vince.evaluate_intent(vince, %{trade: "T1", nte: nte, offer: offer})

      assert challenge.code == :gpm_floor
      assert challenge.demanded_evidence != []

      built = Broker.build_card(challenge, nil)
      assert built.source == :vince_challenge
      assert built.gpm_floor_breach == true

      {:ok, p} = Broker.propose(:co_1, built)
      assert Enum.all?(p.card.options, &(&1.requires_signature == true))
    end

    test "tony escalation-edge triage output produces a signature-required card" do
      now = ~U[2026-11-07 12:00:00Z]

      bad_ticket = %{
        id: "t9",
        warranty_status: :expired,
        operating_hours: 100,
        sla_window: :open,
        contractor_coi_valid: true
      }

      good_ticket = %{
        id: "t1",
        warranty_status: :active,
        operating_hours: 100,
        sla_window: :open,
        contractor_coi_valid: true
      }

      {routine, edges} = AshA2A.Twin.Tony.triage([bad_ticket, good_ticket], now: now)

      assert length(routine) == 1
      assert length(edges) == 1

      built = Broker.build_card(nil, {routine, edges})
      assert built.gpm_floor_breach == true
      assert Enum.all?(built.options, &(&1.requires_signature == true))
    end
  end
end
