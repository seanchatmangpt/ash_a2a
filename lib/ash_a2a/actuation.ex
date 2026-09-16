defmodule AshA2A.Actuation do
  @moduledoc """
  RFC-SA2A-001 S55 stable actuation and idempotency identities.

  ## Why command identity is not enough

  `AshA2A.CommandBus` already deduplicates on `command_id` + fingerprint via
  `AshA2A.ReceiptStore.claim/2`. That protects against *the same command being
  submitted twice*. It does not protect against *the same effect being
  requested twice under two different command ids* -- a client that retries by
  minting a fresh `command_id` (the common accident) crosses the consequence
  boundary a second time with the old claim untouched.

  S55 closes that by keying on the intended *effect* instead of the request:

      actuation_id = H(capability_id, principal, semantic subject, input digest, external token)

  `command_id` is deliberately absent from that tuple, and `agent_id` is too --
  the same principal driving the same capability over the same semantic subject
  with the same input is one effect regardless of which agent process or which
  request id carried it.

  ## Binding to the external token

  The RFC says the actuation identity SHOULD bind to the external system's own
  idempotency token where one exists. `identity/2` looks for that token, in
  order, at:

    1. `opts[:idempotency_key]`
    2. `command.metadata[:idempotency_key]` (or the `"idempotency_key"` string key)
    3. `command.authority.constraints[:external_idempotency_token]`

  When found, it is used verbatim as `idempotency_key` *and* mixed into
  `actuation_id`, so the local dedup key and the remote dedup key name the same
  effect. When absent, the idempotency key is derived from the same effect
  tuple, so it is still stable across retries -- just not shared with the
  external system.

  Derivation is pure and total: the same command always yields the same pair,
  on any node, in any order.
  """

  alias AshA2A.{Authority, Command, Identity, SemanticSubject}

  defstruct [:actuation_id, :idempotency_key, :effect_digest, :input_digest, :external_token?]

  @type t :: %__MODULE__{
          actuation_id: Identity.t(),
          idempotency_key: Identity.t(),
          effect_digest: String.t(),
          input_digest: String.t(),
          external_token?: boolean()
        }

  @doc """
  Derives the stable actuation/idempotency pair for one command.

      iex> command =
      ...>   AshA2A.Command.new("Cap.act",
      ...>     command_id: "one",
      ...>     agent_id: "agent-a",
      ...>     principal_id: "p-1",
      ...>     input: %{amount: 10}
      ...>   )
      iex> other = AshA2A.Command.new("Cap.act",
      ...>   command_id: "two",
      ...>   agent_id: "agent-b",
      ...>   principal_id: "p-1",
      ...>   input: %{amount: 10}
      ...> )
      iex> AshA2A.Actuation.identity(command).actuation_id ==
      ...>   AshA2A.Actuation.identity(other).actuation_id
      true
  """
  @spec identity(Command.t(), keyword()) :: t()
  def identity(%Command{} = command, opts \\ []) do
    input_digest = digest(command.input)
    external = external_token(command, opts)

    effect_digest =
      digest({
        command.capability_id,
        Identity.external(command.principal_id),
        SemanticSubject.fingerprint_token(command.semantic_subject),
        input_digest,
        external
      })

    idempotency_value = external || effect_digest

    %__MODULE__{
      actuation_id: Identity.actuation(effect_digest),
      idempotency_key: Identity.idempotency(idempotency_value),
      effect_digest: effect_digest,
      input_digest: input_digest,
      external_token?: not is_nil(external)
    }
  end

  @doc "SHA-256 of any term, prefixed `sha256:` to match `AshA2A.SemanticSubject`."
  @spec digest(term()) :: String.t()
  def digest(term) do
    "sha256:" <>
      (term
       |> :erlang.term_to_binary()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower))
  end

  @doc "The external idempotency token this command carries, if any."
  @spec external_token(Command.t(), keyword()) :: String.t() | nil
  def external_token(%Command{} = command, opts \\ []) do
    Keyword.get(opts, :idempotency_key) ||
      metadata_token(command.metadata) ||
      authority_token(command.authority)
  end

  defp metadata_token(metadata) when is_map(metadata) do
    binary(Map.get(metadata, :idempotency_key)) || binary(Map.get(metadata, "idempotency_key"))
  end

  defp metadata_token(_), do: nil

  defp authority_token(%Authority{constraints: constraints}) when is_map(constraints) do
    binary(Map.get(constraints, :external_idempotency_token)) ||
      binary(Map.get(constraints, "external_idempotency_token"))
  end

  defp authority_token(_), do: nil

  defp binary(value) when is_binary(value) and value != "", do: value
  defp binary(_), do: nil
end
