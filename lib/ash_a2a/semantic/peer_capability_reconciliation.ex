defmodule AshA2A.Semantic.PeerCapabilityReconciliation do
  @moduledoc """
  Wires cross-peer capability-label semantic identity reconciliation
  (`AshA2A.Semantic.MappingRegistry`, RFC-SA2A-001 S47) into a single peer's
  own admission decision (`AshA2A.Semantic.Peer`, PRD §14 / ARD §14).

  ## The gap this closes

  `AshA2A.Semantic.MappingRegistry.reconcile/3` already refuses
  `:semantic_label_collision_unmapped` when two peers claim the same
  capability *label* but reference different semantic *identities* with no
  admitted mapping between them -- S47's whole point: `label_A == label_B`
  does not imply `meaning_A == meaning_B`. That mechanism is real and
  independently exercised by `AshA2A.Chicago.Courts.MetaAdmission`,
  `ExecutableWorld` and `PublicSemanticsNamespace`.

  Separately, `AshA2A.Semantic.Peer.admit/2` already runs a real,
  independently tested admission pipeline (graph presence, semantic basis,
  provenance, authority requirement, receipt references, GraphLaw verdict).
  Neither half called the other: a single `Peer.admit/2` call never
  reconciled the capability label an inbound envelope claims against this
  peer's own capability identities, so two peers' matching labels could be
  silently treated as matching meaning inside one admission call.

  This module is the composition, not a third mechanism. Given the `{label,
  iri}` claim an envelope carries and this peer's own compiled capability
  index, it derives this peer's own `{label, iri}` for the same label (via
  the already-real `AshA2A.Semantic.AgentCard.from_skill/2` derivation --
  never a second, hand-authored capability model) and delegates the entire
  identity decision to `MappingRegistry.reconcile/3`.

  ## Where the claim travels

  `AshA2A.Semantic.Envelope` carries no dedicated capability-selector field
  (RFC S11's envelope is a graph payload; *which* capability is invoked is
  an A2A-message-level concern, not part of the envelope wire shape). The
  claim therefore travels in the envelope's existing free-form `provenance`
  map, under `capability_label` / `capability_iri` -- the same map RFC S11
  already uses for grounding data, and which already carries structured,
  non-"who sent this" keys elsewhere in this codebase (e.g.
  `AshA2A.Semantic.Iri`'s private-term provenance carries
  `:searched_sources` / `:public_absence_reason`). No new envelope field, no
  new wire shape.

  ## When it is a no-op

  Most envelopes are not capability claims at all -- an envelope whose
  `provenance` names no `capability_label`/`capability_iri` pair triggers no
  reconciliation (`:ok`). Likewise, a peer with no `:capabilities` module
  configured, or one that exposes no skill under the claimed label, has
  nothing of its own to collide with, so there is nothing to refuse. Only
  when BOTH sides resolve to an identity for the same label does S47 apply.
  """

  alias AshA2A.Semantic.{AgentCard, Envelope, MappingRegistry, Peer}

  @typedoc "A `{label, iri}` capability claim, `MappingRegistry.reconcile/3`-shaped."
  @type claim :: %{required(:label) => String.t(), required(:iri) => String.t()}

  @doc """
  The `{label, iri}` capability claim an envelope carries, if any.

  Reads `provenance["capability_label"]`/`provenance["capability_iri"]` (or
  the atom-keyed equivalents -- an envelope built in-process with
  `Envelope.new/1` may carry either). Returns `nil` when either half is
  missing or blank: a half-claim names no capability at all.
  """
  @spec claimed_capability(Envelope.t()) :: claim() | nil
  def claimed_capability(%Envelope{provenance: provenance}) when is_map(provenance) do
    label = provenance[:capability_label] || provenance["capability_label"]
    iri = provenance[:capability_iri] || provenance["capability_iri"]

    if is_binary(label) and label != "" and is_binary(iri) and iri != "" do
      %{label: label, iri: iri}
    end
  end

  def claimed_capability(%Envelope{}), do: nil

  @doc """
  Reconciles an envelope's claimed capability against this peer's own
  identity for the same label, if either side has one to claim.

    * `:ok` -- the envelope names no capability claim, or this peer exposes
      no capability under the claimed label (nothing of this peer's own to
      collide with).
    * `:ok` -- both sides resolve (`MappingRegistry.reconcile/3` returned
      `{:ok, _}`: same identity, or an admitted mapping relates them).
    * `{:error, refusal}` -- the exact `MappingRegistry.reconcile/3` refusal,
      unmodified, notably `:semantic_label_collision_unmapped` (S47).

  Reconciliation runs against `peer.mapping_registry` (an
  `AshA2A.Semantic.MappingRegistry.t()`), or a fresh, empty registry when the
  peer configures none -- matching that module's own stated default: with no
  admitted mappings, only identical identities reconcile.
  """
  @spec reconcile(Peer.t(), Envelope.t()) :: :ok | {:error, MappingRegistry.refusal()}
  def reconcile(%Peer{} = peer, %Envelope{} = envelope) do
    with %{label: label} = remote <- claimed_capability(envelope),
         %{} = own <- own_identity(peer, label) do
      registry = peer.mapping_registry || MappingRegistry.new()

      own_peer = Map.put(own, :peer_id, peer.name)
      remote_peer = Map.put(remote, :peer_id, envelope.envelope_id)

      case MappingRegistry.reconcile(registry, own_peer, remote_peer) do
        {:ok, _outcome} -> :ok
        {:error, refusal} -> {:error, refusal}
      end
    else
      _no_claim_or_nothing_of_our_own -> :ok
    end
  end

  # This peer's OWN `{label, iri}` for `label`, resolved through the real,
  # already-authoritative `AshA2A.Info.skill/2` selector lookup -- the exact
  # same "A2A id OR residual display/selector name" resolution
  # `AshA2A.Semantic.Peer.consequence_bearing?/2` already uses to resolve a
  # named capability, never a second, hand-rolled matching rule. Its
  # `capability_iri` comes from `AgentCard.from_skill/2`, the same derivation
  # `AshA2A.Info.agent_card/2` already projects onto this peer's own served
  # agent card, so a semantic capability identity and the A2A skill it names
  # can never drift apart by construction.
  defp own_identity(%Peer{capabilities: nil}, _label), do: nil

  defp own_identity(%Peer{capabilities: capabilities}, label) do
    case AshA2A.Info.skill(capabilities, label) do
      {:ok, skill} -> %{label: label, iri: AgentCard.from_skill(skill).capability_iri}
      {:error, :skill_not_found} -> nil
    end
  end
end
