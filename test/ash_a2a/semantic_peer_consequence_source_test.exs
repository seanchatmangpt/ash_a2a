defmodule AshA2A.SemanticPeerConsequenceSourceTest do
  @moduledoc """
  Regression cover for RFC S76's anti-downgrade guard being controlled by the
  party it constrains.

  The defect, as reproduced before the fix: `Peer.receive_message/3` read
  `consequence_bearing?` out of `opts`, and the only caller filled that opt
  from `message.metadata["consequenceBearing"]` -- so the sender decided
  whether S76's typed refusal applied to the sender. Setting the flag to
  `false`, or simply omitting it, turned the check off from the outside.

  Every collaborator is real: a real `Ash.Resource` with a real `AshA2A`
  capability surface (`AshA2A.Test.SA2AConsequenceFixture.Ledger`, carrying a
  real `:observe` `:read` skill and a real `:change` `:create` skill), real
  `A2A.Message` structs, and the real `AshA2A.Semantic.Peer` boundary. The
  consequence class is read from the compiled DSL through the real
  `AshA2A.Info.skill/2`, exactly as `AshA2A.CommandBus` reads it.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Peer
  alias AshA2A.Test.SA2AConsequenceFixture.{Ledger, ObserveOnly}

  @change_skill :post_entry
  @observe_skill :read_entries

  defp strict(capabilities),
    do: Peer.new(name: "peer-b", mode: :strict, capabilities: capabilities)

  defp message(metadata),
    do: %{A2A.Message.new_user("do the thing") | metadata: metadata}

  describe "the real DSL is the only source of the consequence class" do
    test "the resource fixture really does carry both consequence classes" do
      assert {:ok, %AshA2A.Skill{consequence: :change}} =
               AshA2A.Info.skill(Ledger, @change_skill)

      assert {:ok, %AshA2A.Skill{consequence: :observe}} =
               AshA2A.Info.skill(Ledger, @observe_skill)
    end

    test "a requested :change capability is consequence-bearing" do
      assert Peer.consequence_bearing?(strict(Ledger), message(%{"skill" => "post_entry"}))
    end

    test "a requested :observe capability is not" do
      refute Peer.consequence_bearing?(strict(Ledger), message(%{"skill" => "read_entries"}))
    end
  end

  describe "the verifier's minimal reproducing input: metadata cannot move the boundary" do
    test "consequenceBearing=false does NOT disarm S76 for a :change capability" do
      outcome =
        Peer.receive_message(
          strict(Ledger),
          message(%{"skill" => "post_entry", "consequenceBearing" => false})
        )

      assert outcome.standing == :unsupported
      assert outcome.code == :unsupported_profile
      assert outcome.detail =~ "will not downgrade a consequence-bearing task"
    end

    test "omitting consequenceBearing entirely does NOT disarm S76 either" do
      outcome = Peer.receive_message(strict(Ledger), message(%{"skill" => "post_entry"}))

      assert outcome.code == :unsupported_profile
    end

    test "consequenceBearing=true does NOT arm S76 for an :observe capability" do
      outcome =
        Peer.receive_message(
          strict(Ledger),
          message(%{"skill" => "read_entries", "consequenceBearing" => true})
        )

      assert outcome.standing == :unsupported
      assert outcome.code == :profile_not_negotiated
    end

    test "the :consequence_bearing? opt is ignored in both directions" do
      change = message(%{"skill" => "post_entry"})
      observe = message(%{"skill" => "read_entries"})

      assert Peer.receive_message(strict(Ledger), change, consequence_bearing?: false).code ==
               :unsupported_profile

      assert Peer.receive_message(strict(Ledger), observe, consequence_bearing?: true).code ==
               :profile_not_negotiated
    end
  end

  describe "fail-closed resolution" do
    test "a skill name that resolves to no capability is treated as consequence-bearing" do
      outcome = Peer.receive_message(strict(Ledger), message(%{"skill" => "no_such_capability"}))

      assert outcome.code == :unsupported_profile
    end

    test "no named skill against an ambiguous surface is treated as consequence-bearing" do
      # Ledger exposes two capabilities, so "which one?" is unanswerable.
      assert Peer.consequence_bearing?(strict(Ledger), message(%{}))
    end

    test "no named skill against a single :observe capability is not consequence-bearing" do
      refute Peer.consequence_bearing?(strict(ObserveOnly), message(%{}))

      assert Peer.receive_message(strict(ObserveOnly), message(%{})).code ==
               :profile_not_negotiated
    end

    test "a peer fronting no capability surface has no consequence-bearing task to downgrade" do
      peer = Peer.new(name: "peer-b", mode: :strict)

      refute Peer.consequence_bearing?(peer, message(%{"consequenceBearing" => true}))
      assert Peer.receive_message(peer, message(%{})).code == :profile_not_negotiated
    end
  end

  describe "the safety envelope S76 sits inside is preserved" do
    test "standing is :unsupported on every unnegotiated path and never :admitted" do
      peers = [strict(Ledger), Peer.new(name: "p", mode: :permissive, capabilities: Ledger)]

      metadatas = [
        %{},
        %{"skill" => "post_entry"},
        %{"skill" => "read_entries"},
        %{"consequenceBearing" => true},
        %{"skill" => "post_entry", "consequenceBearing" => false},
        %{"standing" => "admitted"}
      ]

      for peer <- peers, metadata <- metadatas do
        outcome = Peer.receive_message(peer, message(metadata))

        assert outcome.standing == :unsupported,
               "#{peer.name}/#{inspect(metadata)} produced #{inspect(outcome.standing)}"

        refute outcome.standing == :admitted
      end
    end

    test "a permissive peer downgrades where a strict peer refuses, which is the whole mode split" do
      change = message(%{"skill" => "post_entry"})
      permissive = Peer.new(name: "p", mode: :permissive, capabilities: Ledger)

      assert Peer.receive_message(strict(Ledger), change).code == :unsupported_profile
      assert Peer.receive_message(permissive, change).code == :profile_not_negotiated
    end
  end
end
