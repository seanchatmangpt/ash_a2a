defmodule AshA2A.Authority do
  @moduledoc """
  Explicit authority evidence bound to a principal and one capability.

  This struct is not a bearer-token verifier and never manufactures trust.
  Construct it only after a transport or host authority broker has admitted
  the caller. `source: :transport_verified` is used by the A2A adapter for the
  identity already verified by `A2A.Plug.Auth`.
  """

  alias AshA2A.Identity

  @enforce_keys [:token_id, :subject, :capability_id, :source, :issued_at]
  defstruct [
    :token_id,
    :subject,
    :capability_id,
    :source,
    :issued_at,
    :expires_at,
    evidence: %{},
    constraints: %{}
  ]

  @type t :: %__MODULE__{
          token_id: Identity.t(),
          subject: Identity.t(),
          capability_id: String.t(),
          source: atom(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          evidence: term(),
          constraints: map()
        }

  @spec new(Identity.t(), String.t(), keyword()) :: t()
  def new(%Identity{kind: :principal} = subject, capability_id, opts \\ [])
      when is_binary(capability_id) do
    %__MODULE__{
      token_id: Identity.runtime(Keyword.get(opts, :token_id, Ash.UUIDv7.generate())),
      subject: subject,
      capability_id: capability_id,
      source: Keyword.get(opts, :source, :authority_broker),
      issued_at: Keyword.get(opts, :issued_at, DateTime.utc_now()),
      expires_at: Keyword.get(opts, :expires_at),
      evidence: Keyword.get(opts, :evidence, %{}),
      constraints: Map.new(Keyword.get(opts, :constraints, %{}))
    }
  end

  @spec from_verified_identity(term(), String.t()) :: t() | nil
  def from_verified_identity(nil, _capability_id), do: nil

  def from_verified_identity(identity, capability_id) do
    subject = Identity.principal(identity)

    new(subject, capability_id,
      # Deterministic, not a fresh `Ash.UUIDv7.generate()` per call (unlike
      # `new/3`'s own default): this authority is a synthesized STANDING
      # claim ("this already-verified principal may act with this
      # capability"), not a one-time-issued credential grant, so it must be
      # idempotent for the same (subject, capability_id) pair. A fresh
      # random `token_id` here would leak into `AshA2A.Command.fingerprint/1`
      # (which hashes `authority.token_id`) and make every retry of the
      # exact same command fingerprint differently from the last, defeating
      # `AshA2A.CommandBus`'s replay detection for every authenticated
      # caller -- confirmed as a real, reproduced regression this fix closes
      # (a genuine client retry through the default `AshA2A.Agent` dispatch
      # path was hitting `:command_conflict` instead of a real replay, even
      # with 100% identical semantic command content).
      token_id: deterministic_token_id(subject, capability_id),
      source: :transport_verified,
      evidence: %{transport_identity: identity}
    )
  end

  defp deterministic_token_id(%Identity{} = subject, capability_id) do
    {subject.value, capability_id}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec admits?(t() | nil, map()) :: boolean()
  def admits?(%__MODULE__{} = authority, %{principal_id: principal, capability_id: capability}) do
    authority.subject == principal and
      authority.capability_id == capability and
      not expired?(authority)
  end

  def admits?(_authority, _command), do: false

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end
end
