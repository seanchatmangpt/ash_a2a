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
    new(Identity.principal(identity), capability_id,
      source: :transport_verified,
      evidence: %{transport_identity: identity}
    )
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
