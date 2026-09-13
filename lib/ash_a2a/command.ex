defmodule AshA2A.Command do
  @moduledoc """
  Consequence-bearing command envelope for the AshA2A boundary.

  A command binds distinct machine identities, a canonical capability id, the
  admitted input, and optional verified authority. `fingerprint` is derived
  only from semantic command content, so retries may carry a fresh transport
  timestamp while still proving they are the same command intent.
  """

  alias AshA2A.{Authority, Identity}

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
      submitted_at: submitted_at,
      fingerprint: "",
      metadata: metadata
    }

    %{command | fingerprint: fingerprint(command)}
  end

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
      authority_token
    }
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp ensure_identity(kind, %Identity{kind: kind} = identity), do: identity

  defp ensure_identity(kind, %Identity{} = identity),
    do: raise(ArgumentError, "expected #{kind} identity, got #{inspect(identity.kind)}")

  defp ensure_identity(kind, value), do: Identity.new(kind, value)

  defp optional_identity(_kind, nil), do: nil
  defp optional_identity(kind, value), do: ensure_identity(kind, value)
end
