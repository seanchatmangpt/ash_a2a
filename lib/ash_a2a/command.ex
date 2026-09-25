defmodule AshA2A.Command do
  @moduledoc """
  Consequence-bearing command envelope for the AshA2A boundary.

  A command binds distinct machine identities, a canonical capability id, the
  admitted input, optional exact semantic/manufacture subject, and optional
  verified authority. `fingerprint` is derived from semantic command content
  plus reserved identity-bearing metadata admitted at a consequence boundary.
  Transport-only metadata remains excluded, so ordinary retries may carry fresh
  transport context while preserving command identity.
  """

  alias AshA2A.{Authority, Identity, SemanticSubject, SpgIdentity}

  @enforce_keys [
    :command_id,
    :agent_id,
    :principal_id,
    :capability_id,
    :input,
    :submitted_at,
    :fingerprint
  ]
  defstruct [
    :command_id,
    :agent_id,
    :principal_id,
    :task_id,
    :capability_id,
    :input,
    :authority,
    :semantic_subject,
    :spg_identity,
    :submitted_at,
    :fingerprint,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          command_id: Identity.t(),
          agent_id: Identity.t(),
          principal_id: Identity.t(),
          task_id: Identity.t() | nil,
          capability_id: String.t(),
          input: term(),
          authority: Authority.t() | nil,
          semantic_subject: SemanticSubject.t() | nil,
          spg_identity: SpgIdentity.t() | nil,
          submitted_at: DateTime.t(),
          fingerprint: String.t(),
          metadata: map()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(capability_id, opts) when is_binary(capability_id) and is_list(opts) do
    command_id = ensure_identity(:command, Keyword.get(opts, :command_id, Ash.UUIDv7.generate()))
    agent_id = ensure_identity(:agent, Keyword.fetch!(opts, :agent_id))
    principal_id = ensure_identity(:principal, Keyword.fetch!(opts, :principal_id))
    task_id = optional_identity(:task, Keyword.get(opts, :task_id))
    input = Keyword.get(opts, :input, %{})
    authority = Keyword.get(opts, :authority)
    semantic_subject = Keyword.get(opts, :semantic_subject)
    spg_identity = Keyword.get(opts, :spg_identity)
    submitted_at = Keyword.get(opts, :submitted_at, DateTime.utc_now())
    metadata = Map.new(Keyword.get(opts, :metadata, %{}))

    command = %__MODULE__{
      command_id: command_id,
      agent_id: agent_id,
      principal_id: principal_id,
      task_id: task_id,
      capability_id: capability_id,
      input: input,
      authority: authority,
      semantic_subject: semantic_subject,
      spg_identity: spg_identity,
      submitted_at: submitted_at,
      fingerprint: "",
      metadata: metadata
    }

    %{command | fingerprint: fingerprint(command)}
  end

  @doc """
  Stable command-identity digest keyed only on semantic command content.

  Encoded with `[:deterministic]`: plain `:erlang.term_to_binary/1` writes
  atom-keyed map entries in the VM's atom-table order, so the same logical
  command (e.g. `input: %{effect_key: ...}` built with a different key
  insertion order) digested on another node -- or a fresh replay process --
  would otherwise fingerprint differently (RFC-SA2A-002 §41, CHI-REPLAY-001).
  `ReceiptStore.claim/2` keys its replay/conflict decision on this value, so a
  non-deterministic encoding here can either mask a genuine `:command_conflict`
  or spuriously refuse a legitimate retry. Same fix already applied at
  `AshA2A.Actuation.digest/1`.
  """
  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = command) do
    authority_token =
      case command.authority do
        %Authority{token_id: token_id} -> Identity.external(token_id)
        _ -> nil
      end

    {
      Identity.external(command.agent_id),
      Identity.external(command.principal_id),
      command.task_id && Identity.external(command.task_id),
      command.capability_id,
      command.input,
      authority_token,
      SemanticSubject.fingerprint_token(command.semantic_subject),
      SpgIdentity.fingerprint_token(command.spg_identity),
      gall_029_candidate_digest(command.metadata)
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # GALL-030: this one metadata field is semantic identity, not transport
  # decoration. Including it closes the replay hole where two different
  # admitted findings could otherwise share one command fingerprint.
  defp gall_029_candidate_digest(metadata) when is_map(metadata) do
    Map.get(metadata, :gall_029_candidate_digest) ||
      Map.get(metadata, "gall_029_candidate_digest")
  end

  defp gall_029_candidate_digest(_), do: nil

  defp ensure_identity(kind, %Identity{kind: kind} = identity), do: identity

  defp ensure_identity(kind, %Identity{} = identity),
    do: raise(ArgumentError, "expected #{kind} identity, got #{inspect(identity.kind)}")

  defp ensure_identity(kind, value), do: Identity.new(kind, value)

  defp optional_identity(_kind, nil), do: nil
  defp optional_identity(kind, value), do: ensure_identity(kind, value)
end
