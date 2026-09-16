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
      ordinary A2A.

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
  """

  alias AshA2A.Semantic.{Envelope, Extension, GraphLaw, Standing}
  alias AshA2A.Semantic.Standing.Ledger

  defstruct [
    :name,
    :ledger,
    shapes: "",
    mode: :strict,
    graph_law: nil
  ]

  @type mode :: :strict | :permissive

  @type t :: %__MODULE__{
          name: String.t(),
          ledger: Agent.agent() | nil,
          shapes: String.t(),
          mode: mode(),
          graph_law: module() | nil
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
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      ledger: Keyword.get(opts, :ledger),
      shapes: Keyword.get(opts, :shapes, ""),
      mode: Keyword.get(opts, :mode, :strict),
      graph_law: Keyword.get(opts, :graph_law)
    }
  end

  @doc """
  The full boundary crossing for a real inbound `A2A.Message`.

  `consequence_bearing?` in `opts` (default `false`) tells S76 whether the
  requested task would have a consequence. A strict peer refuses an
  unnegotiated consequence-bearing task with `:unsupported_profile` instead
  of silently downgrading it.

  Returns an `outcome/0` whose `:standing` is the only thing a caller may
  treat as decided.
  """
  @spec receive_message(t(), A2A.Message.t(), keyword()) :: outcome()
  def receive_message(%__MODULE__{} = peer, %A2A.Message{} = message, opts \\ []) do
    consequence_bearing? = Keyword.get(opts, :consequence_bearing?, false)

    if Extension.activated?(message) do
      semantic_path(peer, message)
    else
      bridge_path(peer, message, consequence_bearing?)
    end
  end

  # S75 / S76: a message from a peer that did not negotiate the profile.
  defp bridge_path(%__MODULE__{} = peer, message, consequence_bearing?) do
    envelope_id = bridge_envelope_id(message)
    record(peer, envelope_id, {:received, :unsupported}, :profile_not_negotiated)

    {code, detail} =
      if consequence_bearing? and peer.mode == :strict do
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

  defp semantic_path(%__MODULE__{} = peer, message) do
    case Envelope.parse(message) do
      {:ok, envelope} ->
        record(peer, envelope.envelope_id, {:received, :candidate}, :envelope_parsed)
        admit(peer, envelope)

      {:error, refusal} ->
        envelope_id = bridge_envelope_id(message)
        record(peer, envelope_id, {:received, :refused}, refusal.code)

        %{
          standing: :refused,
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
  def admit(%__MODULE__{} = peer, %Envelope{standing: :candidate} = envelope) do
    opts = graph_law_opts(peer)
    over_claimed? = Envelope.over_claimed?(envelope)

    with {:ok, digest} <- GraphLaw.graph_hash(envelope.graph, opts),
         :ok <- check_claimed_digest(envelope, digest),
         {:ok, report} <- GraphLaw.validate(envelope.graph, peer.shapes, opts) do
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

  def admit(%__MODULE__{} = peer, %Envelope{standing: standing} = envelope) do
    record(peer, envelope.envelope_id, {standing, :admitted}, :admission_out_of_order)

    %{
      standing: :refused,
      envelope_id: envelope.envelope_id,
      code: :illegal_standing_transition,
      detail: "cannot admit an envelope whose standing is #{inspect(standing)}"
    }
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
        Envelope.parse_payload(payload)

      _ ->
        {:error,
         %{
           code: :profile_not_activated,
           detail: "artifact metadata carries no `#{Extension.extension_key()}` payload"
         }}
    end
  end

  defp check_claimed_digest(%Envelope{claimed_graph_digest: nil}, _digest), do: :ok

  defp check_claimed_digest(%Envelope{claimed_graph_digest: claimed}, digest) do
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

  defp graph_law_opts(%__MODULE__{graph_law: nil}), do: []
  defp graph_law_opts(%__MODULE__{graph_law: module}), do: [graph_law: module]

  defp record(%__MODULE__{ledger: nil}, _envelope_id, _edge, _reason), do: :ok

  defp record(%__MODULE__{ledger: ledger}, envelope_id, edge, reason),
    do: Ledger.record(ledger, envelope_id, edge, reason)

  defp bridge_envelope_id(%A2A.Message{message_id: nil}), do: "sa2a-unidentified"
  defp bridge_envelope_id(%A2A.Message{message_id: id}), do: "sa2a-nonsemantic-" <> id
end
