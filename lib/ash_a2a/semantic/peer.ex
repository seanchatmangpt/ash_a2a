defmodule AshA2A.Semantic.Peer do
  @moduledoc """
  RFC-SA2A-001 S8/S49/S50/S51/S75/S76 -- the receiving side of a Semantic A2A
  boundary.

  This module is the whole cross-peer claim in one function, `receive_message/2`:

      Message_A -> Candidate_B -> GraphLaw_B -> O*_B

  Peer B never reads peer A's graph as fact. It reads it as a candidate,
  hands it to its **own** GraphLaw engine with its **own** shapes, and only
  the engine's verdict produces standing. Peer A's opinion about its own
  graph -- including any `"standing": "admitted"` it wrote on the wire -- is
  recorded and discarded.

  ## The sections, and where each is enforced

    * **S9 (negotiation)** -- `receive_message/2` requires
      `AshA2A.Semantic.Extension.activated?/1`. Ordinary A2A traffic never
      enters the semantic path.
    * **S49 (a Task is not authority)** -- `authority_from_task/1` returns
      `:none` for every `A2A.Task`, in every state, including `:completed`.
      A completed task is a record that work happened, not a permit.
    * **S50 (an Artifact gains no standing from being an Artifact)** --
      `standing_from_artifact/1` returns `:received` for every `A2A.Artifact`.
      Artifact-ness is a container fact.
    * **S51 (received is not admitted)** -- every path through this module
      goes through `AshA2A.Semantic.Standing`, whose transition table has no
      `:received -> :admitted` edge.
    * **S75 (non-Semantic bridge)** -- `receive_message/2` on an
      unnegotiated message returns `{:unsupported, ...}` with standing
      `:unsupported`, never `:admitted`. The traffic is answerable; it
      inherits no standing.
    * **S76 (no silent downgrade)** -- a peer in `:strict` mode receiving a
      consequence-bearing task without the negotiated profile returns the
      typed refusal `:unsupported_profile` rather than quietly handling it as
      ordinary A2A. Whether the task is consequence-bearing is decided by
      *this* peer's own capability DSL (`consequence_bearing?/2`), never by
      the counterparty the rule constrains.

  ## What "its own engine" means operationally

  `admit/2` recomputes the graph digest with the receiving peer's engine and
  compares it to the digest the sender claimed. A mismatch is
  `:semantic_digest_mismatch`. It then runs the receiving peer's configured
  shapes. A peer with no shapes configured runs the engine anyway -- the
  engine's parse, Datalog materialization, N3 denial scan and replay check
  all still execute -- and the resulting report records which dialects were
  `UNSUPPORTED` so the receipt never implies a shape check that did not run.

  ## Fail-closed

  If the engine cannot be reached, admission returns standing `:unsupported`
  with code `:graphlaw_unavailable`. It does not return `:admitted`. A peer
  that cannot check does not get to agree.

  ## Boundary telemetry

  The decision points emit `[:ash_a2a, :semantic, :peer, ...]` events at the
  boundary itself (RFC-SA2A-002 §12, §18). Metadata always carries `:peer`
  and `:mode`.

    * `[:receive]` -- an inbound `A2A.Message` reached `receive_message/3`
      (+ `:activated`, `:message_id`)
    * `[:admission, :start]` -- a parsed envelope reached admission
      (+ `:envelope_id`, `:standing`, `:profile`, `:consequence_class`,
      `:authority_requirement`)
    * `[:decision]` -- the outcome this peer decided (+ `:path`
      `:semantic | :bridge | :admission`, `:envelope_id`, `:standing`,
      `:code`, `:class`, `:graph_digest`)
  """

  alias AshA2A.Semantic.{
    AdmissionPipeline,
    Envelope,
    Extension,
    GraphLaw,
    PeerCapabilityReconciliation,
    Refusal
  }

  alias AshA2A.Semantic.Standing
  alias AshA2A.Semantic.Standing.Ledger
  # `AshA2A.GraphLaw.Wasm.dialect/2` is a pure lookup over any decoded
  # `validate_all` report (`%{"dialects" => [...]}`) -- reused here across
  # the AshA2A.Semantic.GraphLaw seam this module actually speaks through,
  # not tied to that module's own wasm host instance. Aliased under a
  # distinguishing name since `GraphLaw` above already names the sibling
  # `AshA2A.Semantic.GraphLaw`.
  alias AshA2A.GraphLaw.Wasm, as: RawWasmReport

  defstruct [
    :name,
    :ledger,
    :capabilities,
    :agent_card,
    :receipt_store,
    shapes: "",
    mode: :strict,
    graph_law: nil,
    mapping_registry: nil
  ]

  @type mode :: :strict | :permissive

  @type t :: %__MODULE__{
          name: String.t(),
          ledger: Agent.agent() | nil,
          capabilities: module() | nil,
          agent_card: A2A.AgentCard.t() | map() | nil,
          receipt_store: {module(), keyword()} | nil,
          shapes: String.t(),
          mode: mode(),
          graph_law: module() | nil,
          mapping_registry: AshA2A.Semantic.MappingRegistry.t() | nil
        }

  @typedoc """
  The outcome of a boundary crossing. `standing` is authoritative; `report`
  carries the receiving peer's own engine output when one ran.
  """
  @type outcome :: %{
          required(:standing) => Standing.t(),
          required(:envelope_id) => String.t(),
          optional(:envelope) => Envelope.t(),
          optional(:graph_digest) => String.t(),
          optional(:report) => map(),
          optional(:unexercised) => [map()],
          # Always `false`: a self-declared standing/authority claim is now
          # refused at `Envelope.new/1`/`from_map/1`, before this outcome can
          # ever be built. See the moduledoc note at `admit/2`.
          optional(:over_claimed) => boolean(),
          optional(:code) => atom(),
          optional(:detail) => String.t()
        }

  @doc """
  Builds a peer configuration.

    * `:name` (required) -- this peer's identity, used in ledger entries.
    * `:ledger` -- a running `AshA2A.Semantic.Standing.Ledger`. Without one,
      transitions are still validated but not recorded.
    * `:shapes` -- this peer's **own** SHACL shapes, as Turtle. Never the
      sender's.
    * `:mode` -- `:strict` (default) or `:permissive`, governing S76.
    * `:graph_law` -- the `AshA2A.Semantic.GraphLaw` implementation module.
    * `:capabilities` -- this peer's **own** `Ash.Resource` or `Ash.Domain`
      carrying the real `AshA2A` capability surface. This is the only source
      S76's consequence classification is read from. See
      `consequence_bearing?/2`.
    * `:agent_card` -- the agent card THIS peer serves (struct or decoded
      JSON). Semantic standing crosses the boundary only when it advertises
      `AshA2A.Semantic.Extension.profile_id/0` at a compatible version; with
      no card, or a card that does not advertise, activated traffic is
      `:unsupported` / `:profile_not_advertised` (RFC-SA2A-002 §55).
    * `:receipt_store` -- `{store_module, store_opts}`, this peer's own
      `AshA2A.ReceiptStore`. An envelope's `receipts` references are admitted
      only when each resolves to a matching receipt there; without a store,
      any receipt reference is unverifiable and refused (RFC-SA2A-002 §54).
    * `:mapping_registry` -- this peer's own
      `AshA2A.Semantic.MappingRegistry`, holding whatever cross-peer semantic
      mappings it has admitted (RFC-SA2A-001 S47). Used by
      `AshA2A.Semantic.PeerCapabilityReconciliation` to reconcile an
      envelope's claimed capability label against this peer's own capability
      identity before admitting it. Without one, a fresh empty registry is
      used -- with no admitted mappings, only identical semantic identities
      reconcile.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      ledger: Keyword.get(opts, :ledger),
      capabilities: Keyword.get(opts, :capabilities),
      agent_card: Keyword.get(opts, :agent_card),
      receipt_store: Keyword.get(opts, :receipt_store),
      shapes: Keyword.get(opts, :shapes, ""),
      mode: Keyword.get(opts, :mode, :strict),
      graph_law: Keyword.get(opts, :graph_law),
      mapping_registry: Keyword.get(opts, :mapping_registry)
    }
  end

  @doc """
  The full boundary crossing for a real inbound `A2A.Message`.

  Whether the requested task is consequence-bearing -- the input S76 turns
  on -- is derived by `consequence_bearing?/2` from **this peer's own**
  capability DSL. It is never read from `opts` and never read from the
  message's metadata. See `consequence_bearing?/2` for why.

  `opts` is still accepted (and `:graph_law` still honoured through the
  struct) but carries no S76 input. A `:consequence_bearing?` key is ignored
  rather than obeyed; passing one cannot move the boundary in either
  direction.

  Returns an `outcome/0` whose `:standing` is the only thing a caller may
  treat as decided.
  """
  @spec receive_message(t(), A2A.Message.t(), keyword()) :: outcome()
  def receive_message(%__MODULE__{} = peer, %A2A.Message{} = message, _opts \\ []) do
    activated? = Extension.activated?(message)
    emit(peer, [:receive], %{activated: activated?, message_id: message.message_id})

    cond do
      not activated? ->
        peer |> bridge_path(message) |> emit_decision(peer, :bridge)

      not Extension.advertised?(peer.agent_card) ->
        peer |> unadvertised_path(message) |> emit_decision(peer, :semantic)

      true ->
        peer |> semantic_path(message) |> emit_decision(peer, :semantic)
    end
  end

  @doc """
  RFC S76's input: is the task this message requests consequence-bearing?

  ## Why the counterparty may not answer this

  S76 exists to constrain the *counterparty*: a peer that did not negotiate
  the profile must not get a consequence-bearing task quietly downgraded to
  ordinary A2A. A guard whose controlling input is supplied by the party it
  constrains is not a guard. An earlier revision read this from
  `message.metadata["consequenceBearing"]`, so the sender decided whether
  S76's typed refusal applied to the sender -- setting the flag to `false`
  (or simply omitting it) turned the check off from the outside.

  The classification is therefore read from exactly the source
  `AshA2A.CommandBus` already treats as authoritative: the receiving side's
  own `AshA2A` DSL, `skill.consequence`, resolved through
  `AshA2A.Info.skill/2`. The counterparty still says *which* capability it
  wants -- that is a request, and requests are what a message is for -- but
  the consequence class of that capability is local truth.

  ## Fail-closed resolution

    * no `:capabilities` module configured -- this peer fronts no capability
      surface, so there is no consequence-bearing task to downgrade:
      `false`.
    * a skill named in metadata that resolves, with an explicit
      `consequence` -- `true` for `:change`/`:external_do`, `false` for
      `:observe`.
    * no skill named and the surface has exactly one capability -- that
      capability's consequence.
    * skill named but not found, no skill named and the surface is
      ambiguous, or a capability whose `consequence` is `nil`/`:unknown` --
      **`true`**. The request cannot be shown to be harmless, and
      `AshA2A.CommandBus` already refuses an unclassified consequence
      (`:consequence_unclassified`) rather than assuming `:observe`. Here the
      matching fail-closed outcome is to treat it as consequence-bearing, so
      a strict peer issues S76's typed refusal instead of downgrading.

  Returns a boolean.
  """
  @spec consequence_bearing?(t(), A2A.Message.t()) :: boolean()
  def consequence_bearing?(%__MODULE__{capabilities: nil}, %A2A.Message{}), do: false

  def consequence_bearing?(%__MODULE__{capabilities: capabilities}, %A2A.Message{} = message) do
    case requested_consequence(capabilities, message) do
      :observe -> false
      consequence when consequence in [:change, :external_do] -> true
      _unresolved_or_unknown -> true
    end
  end

  defp requested_consequence(capabilities, %A2A.Message{metadata: metadata}) do
    case AshA2A.MetadataKey.get(metadata || %{}, :skill) do
      nil -> sole_capability_consequence(capabilities)
      name -> named_capability_consequence(capabilities, name)
    end
  end

  defp named_capability_consequence(capabilities, name) do
    case AshA2A.Info.skill(capabilities, name) do
      {:ok, %AshA2A.Skill{consequence: consequence}} when not is_nil(consequence) -> consequence
      _ -> :unknown
    end
  end

  defp sole_capability_consequence(capabilities) do
    case AshA2A.Info.capability_index(capabilities) do
      [%AshA2A.Skill{consequence: consequence}] when not is_nil(consequence) -> consequence
      _ -> :unknown
    end
  end

  # S75 / S76: a message from a peer that did not negotiate the profile.
  defp bridge_path(%__MODULE__{} = peer, message) do
    envelope_id = bridge_envelope_id(message)
    record(peer, envelope_id, {:received, :unsupported}, :profile_not_negotiated)

    {code, detail} =
      if consequence_bearing?(peer, message) and peer.mode == :strict do
        {:unsupported_profile,
         "peer #{peer.name} is strict and will not downgrade a consequence-bearing task to " <>
           "ordinary A2A; #{Extension.profile_id()} was not negotiated"}
      else
        {:profile_not_negotiated,
         "message carries no #{Extension.profile_id()} extension; it is answerable as ordinary " <>
           "A2A and inherits no semantic standing"}
      end

    %{
      standing: :unsupported,
      envelope_id: envelope_id,
      code: code,
      detail: detail
    }
  end

  # RFC-SA2A-002 §55: a peer that does not itself advertise a compatible
  # profile has negotiated nothing, so no semantic standing may cross its
  # boundary -- even for a perfectly admissible envelope (SA2A-NEG-005).
  defp unadvertised_path(%__MODULE__{} = peer, message) do
    envelope_id = bridge_envelope_id(message)
    record(peer, envelope_id, {:received, :unsupported}, :profile_not_advertised)

    %{
      standing: :unsupported,
      envelope_id: envelope_id,
      code: :profile_not_advertised,
      detail:
        "peer #{peer.name} does not advertise #{Extension.profile_id()} at " <>
          "#{Extension.profile_version()} on its own agent card; semantic standing " <>
          "cannot cross a boundary this peer never negotiated"
    }
  end

  # Reconciled against the round-2-fixed `AshA2A.Semantic.Envelope`, which
  # dropped its own `parse/1` (an `A2A.Message`-taking convenience) --
  # `Extension.payload/1` + `Envelope.from_map/1` is the same real two-step
  # pipeline `parse/1` used to wrap.
  defp semantic_path(%__MODULE__{} = peer, message) do
    with {:ok, payload} <- Extension.payload(message) do
      Envelope.from_map(payload)
    end
    |> case do
      {:ok, envelope} ->
        record(peer, envelope.envelope_id, {:received, :candidate}, :envelope_parsed)
        do_admit(peer, envelope)

      {:error, refusal} ->
        envelope_id = bridge_envelope_id(message)
        standing = parse_refusal_standing(refusal)
        record(peer, envelope_id, {:received, standing}, refusal.code)

        %{
          standing: standing,
          envelope_id: envelope_id,
          code: refusal.code,
          detail: refusal.detail
        }
    end
  end

  @doc """
  Runs the receiving peer's own admission over a candidate envelope.

  Refuses anything that is not already `:candidate`: admission is a
  `:candidate -> :admitted` edge and nothing else.
  """
  @spec admit(t(), Envelope.t()) :: outcome()
  def admit(%__MODULE__{} = peer, %Envelope{} = envelope) do
    peer |> do_admit(envelope) |> emit_decision(peer, :admission)
  end

  defp do_admit(%__MODULE__{} = peer, %Envelope{} = envelope) do
    emit(peer, [:admission, :start], %{
      envelope_id: envelope.envelope_id,
      standing: envelope.standing,
      profile: envelope.profile,
      consequence_class: envelope.consequence_class,
      authority_requirement: envelope.authority_requirement
    })

    admit_candidate(peer, envelope)
  end

  defp admit_candidate(%__MODULE__{} = peer, %Envelope{standing: :candidate} = envelope) do
    opts = graph_law_opts(peer)

    # Reconciled against the round-2-fixed `AshA2A.Semantic.Envelope`: the
    # old "record but ignore a self-declared standing/authority claim" policy
    # this field reported on no longer exists to report on. `Envelope.new/1`
    # and `from_map/1` now REFUSE a payload that declares any standing at all
    # (`:standing_self_declared`) before an envelope is ever constructed --
    # a strictly stronger guarantee than "admit anyway, on our own evidence,
    # but remember the sender over-claimed". By the time this function has a
    # `%Envelope{standing: :candidate}` in hand, an over-claim has already
    # been refused upstream and cannot be represented here; `false` is not a
    # missed detection, it is the true, structural answer.
    over_claimed? = false

    # Reconciled the same way: the old `Envelope.graph` field was a bare
    # Turtle string; the round-2-fixed struct carries the real RFC S11 shape
    # (`%{media_type:, digest:, content:}`), so the engine gets `.content`.
    with :ok <- check_graph_present(envelope),
         :ok <- check_semantic_basis(envelope),
         :ok <- PeerCapabilityReconciliation.reconcile(peer, envelope),
         :ok <- check_provenance(envelope),
         :ok <- check_authority_requirement(envelope),
         :ok <- check_receipt_references(peer, envelope),
         graph_ttl = envelope.graph.content,
         :ok <- check_parse_witness(graph_ttl, opts),
         {:ok, digest} <- GraphLaw.graph_hash(graph_ttl, opts),
         :ok <- check_claimed_digest(envelope, digest),
         {:ok, report} <- GraphLaw.validate(graph_ttl, peer.shapes, opts) do
      case GraphLaw.verdict(report) do
        {:admitted, engine_digest} ->
          record(peer, envelope.envelope_id, {:candidate, :admitted}, :graphlaw_admitted)

          %{
            standing: :admitted,
            envelope_id: envelope.envelope_id,
            envelope: %{envelope | standing: :candidate},
            graph_digest: engine_digest,
            report: report,
            unexercised: GraphLaw.unexercised(report),
            over_claimed: over_claimed?
          }

        {:refused, code, detail} ->
          record(peer, envelope.envelope_id, {:candidate, :refused}, code)

          %{
            standing: :refused,
            envelope_id: envelope.envelope_id,
            graph_digest: digest,
            report: report,
            unexercised: GraphLaw.unexercised(report),
            over_claimed: over_claimed?,
            code: code,
            detail: detail
          }
      end
    else
      {:error, %{code: :graphlaw_unavailable} = refusal} ->
        # Cannot check, therefore cannot agree. Not a refusal of the graph --
        # a statement that this peer did not evaluate it.
        record(peer, envelope.envelope_id, {:candidate, :unsupported}, refusal.code)

        %{
          standing: :unsupported,
          envelope_id: envelope.envelope_id,
          over_claimed: over_claimed?,
          code: refusal.code,
          detail: refusal.detail
        }

      {:error, refusal} ->
        record(peer, envelope.envelope_id, {:candidate, :refused}, refusal.code)

        %{
          standing: :refused,
          envelope_id: envelope.envelope_id,
          over_claimed: over_claimed?,
          code: refusal.code,
          detail: refusal.detail
        }
    end
  end

  defp admit_candidate(%__MODULE__{} = peer, %Envelope{standing: standing} = envelope) do
    record(peer, envelope.envelope_id, {standing, :admitted}, :admission_out_of_order)

    %{
      standing: :refused,
      envelope_id: envelope.envelope_id,
      code: :illegal_standing_transition,
      detail: "cannot admit an envelope whose standing is #{inspect(standing)}"
    }
  end

  # Real, engine-native triple-existence witness -- ported from
  # `AshA2A.Semantic.AdmissionPipeline`'s own Parse stage (see that module's
  # moduledoc, "Parse is a real witness, not an assumption"). Measured,
  # real gap this closed: without this check, `graph_hash/1` happily digests
  # non-Turtle garbage (returning the well-known empty-graph digest
  # `af1349b9...`, i.e. `blake3("")`), and `validate/2` against this peer's
  # own real shapes reports "0 violations" for it -- a vacuous pass, since a
  # graph with zero triples cannot violate a shape that targets a class no
  # triple declares membership in. A peer that only checked "engine agreed,
  # 0 violations" could be handed arbitrary non-RDF bytes over the real wire
  # and silently admit them. This appends the universal denial rule
  # `{ ?s ?p ?o } => false .` and requires the engine's `N3_DENIAL` dialect
  # to come back `REFUSED` with at least one violation -- which happens iff
  # the graph really contains at least one triple.
  defp check_parse_witness(graph_ttl, opts) do
    witness_ttl = graph_ttl <> AdmissionPipeline.parse_witness()

    with {:ok, witness_report} <- GraphLaw.validate(witness_ttl, "", opts),
         {:ok, entry} <- RawWasmReport.dialect(witness_report, "N3_DENIAL") do
      case entry do
        %{"status" => "REFUSED", "triples_out" => count} when count >= 1 ->
          :ok

        %{"status" => "ADMITTED"} = admitted_entry ->
          {:error,
           %{
             code: :parse_yielded_no_triples,
             detail:
               "candidate graph parsed to zero real triples (engine: #{inspect(admitted_entry)})"
           }}

        other ->
          {:error, %{code: :parse_witness_inconclusive, detail: "engine: #{inspect(other)}"}}
      end
    else
      {:error, %{code: :graphlaw_unavailable}} = error ->
        error

      {:error, refusal} when is_map(refusal) ->
        {:error,
         %{
           code: :parse_witness_missing,
           detail: "parse witness could not be evaluated: #{inspect(refusal)}"
         }}
    end
  end

  @doc """
  RFC S49 -- an A2A Task is not authority.

  Returns `:none` for every task in every state. A `:completed` task proves
  work happened; it grants nothing. Callers that want authority must go
  through `AshA2A.Authority` and `AshA2A.CommandBus`, neither of which reads
  a task's state.
  """
  @spec authority_from_task(A2A.Task.t() | map()) :: :none
  def authority_from_task(%A2A.Task{}), do: :none
  def authority_from_task(%{}), do: :none

  @doc """
  RFC S50 -- an A2A Artifact gains no standing from being an Artifact.

  Returns `:received` for every artifact. Content inside an artifact may of
  course be admitted, by being parsed into an envelope and run through this
  peer's own admission like anything else -- but the container contributes
  nothing.
  """
  @spec standing_from_artifact(A2A.Artifact.t() | map()) :: :received
  def standing_from_artifact(%A2A.Artifact{}), do: :received
  def standing_from_artifact(%{}), do: :received

  @doc """
  Extracts a Semantic A2A envelope carried inside an artifact's metadata.

  Returns a `:candidate` envelope exactly as a message would: an artifact is
  a different container, not a shortcut past admission.
  """
  @spec envelope_from_artifact(A2A.Artifact.t()) ::
          {:ok, Envelope.t()} | {:error, %{code: atom(), detail: String.t()}}
  def envelope_from_artifact(%A2A.Artifact{metadata: metadata}) do
    case Map.get(metadata, Extension.extension_key()) do
      %{} = payload ->
        Envelope.from_map(payload)

      _ ->
        {:error,
         %{
           code: :profile_not_activated,
           detail: "artifact metadata carries no `#{Extension.extension_key()}` payload"
         }}
    end
  end

  # Reconciled against the round-2-fixed `AshA2A.Semantic.Envelope` (which
  # dropped the earlier top-level `:claimed_graph_digest` field entirely --
  # RFC S11's real wire shape already carries the sender-claimed digest at
  # `graph.digest`, so there was never a need for a second field).
  defp check_claimed_digest(%Envelope{graph: %{digest: nil}}, _digest), do: :ok
  defp check_claimed_digest(%Envelope{graph: nil}, _digest), do: :ok

  defp check_claimed_digest(%Envelope{graph: %{digest: claimed}}, digest) do
    if claimed == digest do
      :ok
    else
      {:error,
       %{
         code: :semantic_digest_mismatch,
         detail: "sender claimed #{claimed}, this peer computed #{digest}"
       }}
    end
  end

  # A `%AshA2A.Semantic.Refusal{}` carries its own S42 class; its terminal
  # standing is that class's (UNSUPPORTED_PROFILE -> :unsupported, never
  # collapsed into :refused, RFC-SA2A-002 §101 / SA2A-ENV-007).
  defp parse_refusal_standing(%Refusal{} = refusal), do: Refusal.terminal_standing(refusal)
  defp parse_refusal_standing(_refusal), do: :refused

  # --- RFC-SA2A-001 S6 / RFC-SA2A-002 §54 admission pre-checks ---------------
  #
  # Standing(x) => Identity /\ Structure /\ Semantics /\ Provenance /\
  # AdmissionReceipt. These run before the engine: an envelope that cannot
  # say what it is to be read against, where it came from, what authority its
  # consequence needs, or whose receipt claims this peer cannot verify has no
  # standing to earn, however conforming its graph.

  defp check_graph_present(%Envelope{graph: %{content: content}}) when is_binary(content),
    do: :ok

  defp check_graph_present(%Envelope{}),
    do: {:error, %{code: :semantic_graph_missing, detail: "envelope carries no graph to admit"}}

  defp check_semantic_basis(%Envelope{semantic_basis: [_ | _] = basis}) do
    if Enum.all?(basis, &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else: semantic_basis_missing(basis)
  end

  defp check_semantic_basis(%Envelope{semantic_basis: basis}), do: semantic_basis_missing(basis)

  defp semantic_basis_missing(basis) do
    {:error,
     %{
       code: :semantic_basis_missing,
       detail:
         "semanticBasis #{inspect(basis)} names no semantic basis the graph is to be read against"
     }}
  end

  defp check_provenance(%Envelope{provenance: provenance}) when is_map(provenance) do
    grounded? =
      Enum.any?(provenance, fn
        {_key, value} when is_binary(value) -> String.trim(value) != ""
        {_key, value} when is_map(value) -> map_size(value) > 0
        {_key, value} when is_list(value) -> value != []
        _ -> false
      end)

    if grounded?,
      do: :ok,
      else:
        {:error,
         %{
           code: :provenance_missing,
           detail: "provenance #{inspect(provenance)} does not say where the envelope came from"
         }}
  end

  @consequence_bearing ["change", "external_do"]

  defp check_authority_requirement(%Envelope{
         consequence_class: class,
         authority_requirement: "none"
       })
       when class in @consequence_bearing do
    {:error,
     %{
       code: :consequence_without_authority_requirement,
       detail:
         "consequenceClass #{class} declares authorityRequirement none; a consequence " <>
           "never has no authority requirement"
     }}
  end

  defp check_authority_requirement(%Envelope{}), do: :ok

  defp check_receipt_references(_peer, %Envelope{receipts: []}), do: :ok

  defp check_receipt_references(%__MODULE__{receipt_store: nil} = peer, %Envelope{}) do
    {:error,
     %{
       code: :receipt_reference_unverified,
       detail:
         "peer #{peer.name} has no receipt store to verify the envelope's receipt " <>
           "references against; an unverifiable receipt establishes nothing"
     }}
  end

  defp check_receipt_references(%__MODULE__{receipt_store: {store, store_opts}}, envelope) do
    Enum.reduce_while(envelope.receipts, :ok, fn reference, :ok ->
      case verify_receipt_reference(store, store_opts, reference) do
        :ok ->
          {:cont, :ok}

        {:error, detail} ->
          {:halt, {:error, %{code: :receipt_reference_unverified, detail: detail}}}
      end
    end)
  end

  defp verify_receipt_reference(
         store,
         store_opts,
         %{"receiptId" => receipt_id, "commandId" => "command:" <> command, "fingerprint" => fp} =
           reference
       )
       when is_binary(receipt_id) and command != "" and is_binary(fp) do
    case store.fetch(AshA2A.Identity.command(command), store_opts) do
      {:ok, %AshA2A.Receipt{} = receipt} ->
        cond do
          AshA2A.Identity.external(receipt.receipt_id) != receipt_id ->
            {:error,
             "receipt #{receipt_id} is not the receipt this peer holds for command:#{command}"}

          receipt.fingerprint != fp ->
            {:error, "receipt #{receipt_id} fingerprint does not match this peer's receipt"}

          Map.has_key?(reference, "status") and
              reference["status"] != Atom.to_string(receipt.status) ->
            {:error,
             "receipt #{receipt_id} status #{inspect(reference["status"])} is not #{receipt.status}"}

          true ->
            :ok
        end

      _ ->
        {:error, "no receipt for command:#{command} in this peer's receipt store"}
    end
  catch
    kind, reason ->
      {:error, "receipt store unavailable (#{kind}: #{inspect(reason, limit: 5)})"}
  end

  defp verify_receipt_reference(_store, _store_opts, reference) do
    {:error,
     "receipt reference #{inspect(reference, limit: 5)} is not a verifiable " <>
       "{receiptId, commandId: \"command:...\", fingerprint} reference"}
  end

  @doc false
  def __sa2a_refusal_codes__ do
    %{
      semantic_graph_missing: :refused_structure,
      semantic_basis_missing: :refused_structure,
      provenance_missing: :refused_provenance,
      consequence_without_authority_requirement: :refused_authority,
      receipt_reference_unverified: :refused_receipt,
      profile_not_advertised: :unsupported_profile,
      profile_not_negotiated: :unsupported_profile,
      unsupported_profile: :unsupported_profile,
      semantic_digest_mismatch: :refused_identity,
      semantic_shape_violation: :refused_shacl,
      semantic_replay_divergence: :refused_identity,
      semantic_graph_unhashable: :refused_identity,
      illegal_standing_transition: :refused_meta_rigor,
      graphlaw_unavailable: :blocked_resource
    }
  end

  defp emit(%__MODULE__{} = peer, suffix, metadata) do
    :telemetry.execute(
      [:ash_a2a, :semantic, :peer | suffix],
      %{system_time: System.system_time()},
      Map.merge(%{peer: peer.name, mode: peer.mode}, metadata)
    )
  end

  defp emit_decision(outcome, %__MODULE__{} = peer, path) do
    code = Map.get(outcome, :code)

    emit(peer, [:decision], %{
      path: path,
      envelope_id: outcome.envelope_id,
      standing: outcome.standing,
      code: code,
      class: if(is_atom(code) and not is_nil(code), do: Refusal.classify(code)),
      graph_digest: Map.get(outcome, :graph_digest)
    })

    outcome
  end

  defp graph_law_opts(%__MODULE__{graph_law: nil}), do: []
  defp graph_law_opts(%__MODULE__{graph_law: module}), do: [graph_law: module]

  defp record(%__MODULE__{ledger: nil}, _envelope_id, _edge, _reason), do: :ok

  defp record(%__MODULE__{ledger: ledger}, envelope_id, edge, reason),
    do: Ledger.record(ledger, envelope_id, edge, reason)

  defp bridge_envelope_id(%A2A.Message{message_id: nil}), do: "sa2a-unidentified"
  defp bridge_envelope_id(%A2A.Message{message_id: id}), do: "sa2a-nonsemantic-" <> id
end
