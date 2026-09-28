defmodule AshA2A.Authority do
  @moduledoc """
  Explicit authority evidence bound to a principal and one capability.

  This struct is not a bearer-token verifier and never manufactures trust.
  Construct it only after a transport or host authority broker has admitted
  the caller. `source: :transport_verified` is used by the A2A adapter for the
  identity already verified by `A2A.Plug.Auth`.

  ## `from_verified_identity/2` is NOT a grant decision

  `from_verified_identity/2` is a pure *constructor*: it synthesizes the
  authority struct that a caller who HAS been granted `capability_id` would
  hold. It performs no admission of its own -- hand it any capability id and
  it returns an authority for that capability id. It must therefore never be
  called with a caller-supplied capability id on a dispatch path without a
  real grant decision in front of it.

  That grant decision lives in `AshA2A.Authority.Grant`, which consults the
  configured `AshA2A.Authority.Broker` before calling this constructor. The
  real `AshA2A.Agent` dispatch path (`AshA2A.Agent.build_command/4`) goes
  through `AshA2A.Authority.Grant.authorize/3`, never through this function
  directly. See `AshA2A.Authority.Grant` for the policy modes and the
  RFC-SA2A-001 S29 escalation this separation closes.
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
    # RFC-SA2A-004 S10: the `{module, broker_opts}` whose `granted?/3` admitted
    # this standing authority (set only by `AshA2A.Authority.Grant`). Kept out
    # of `evidence` so `Receipt.authority_grant/1`'s evidence digest stays a
    # function of transport evidence alone; `AshA2A.CommandBus` revalidates
    # against this same broker immediately before DO.
    admitted_by: nil,
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
          admitted_by: {module(), keyword()} | nil,
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

  @spec from_verified_identity(term(), String.t(), DateTime.t() | nil) :: t() | nil
  def from_verified_identity(identity, capability_id, expires_at \\ nil)

  def from_verified_identity(nil, _capability_id, _expires_at), do: nil

  def from_verified_identity(identity, capability_id, expires_at) do
    subject = Identity.principal(identity)

    new(subject, capability_id,
      # The issuing grant's real time bound, when the broker can report one.
      # Defaults to `nil` (no bound), which is what every caller got before
      # time-bounded grants were enforceable -- so this is additive.
      expires_at: expires_at,
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
      token_id: grant_token_id(subject, capability_id),
      source: :transport_verified,
      evidence: %{transport_identity: identity}
    )
  end

  @doc """
  The deterministic token id identifying the standing grant of
  `capability_id` to `subject`.

  Public because it is the shared key three independent parties must agree
  on: `from_verified_identity/2` (which stamps it onto the synthesized
  authority, so `AshA2A.Command.fingerprint/1` stays stable across retries),
  `AshA2A.Authority.Grant.grant/3` (which issues a broker grant under exactly
  this token id), and every `AshA2A.Authority.Broker` implementation's
  `granted?/3` (which looks up its own issued/revoked state under it). A
  broker keying grants on anything else would silently never match a real
  dispatch.

      iex> subject = AshA2A.Identity.principal("user-1")
      iex> AshA2A.Authority.grant_token_id(subject, "create_item") ==
      ...>   AshA2A.Authority.grant_token_id(subject, "create_item")
      true
      iex> AshA2A.Authority.grant_token_id(subject, "create_item") ==
      ...>   AshA2A.Authority.grant_token_id(subject, "destroy_item")
      false
  """
  @spec grant_token_id(Identity.t(), String.t()) :: String.t()
  def grant_token_id(%Identity{} = subject, capability_id) when is_binary(capability_id) do
    {subject.value, capability_id}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec admits?(t() | nil, map()) :: boolean()
  def admits?(
        %__MODULE__{} = authority,
        %{principal_id: principal, capability_id: capability} = command
      ) do
    authority.subject == principal and
      authority.capability_id == capability and
      not expired?(authority) and
      constraints_satisfied?(authority, command)
  end

  def admits?(_authority, _command), do: false

  @doc """
  RFC-SA2A-004 S10: declared constraints bind the decision, not only
  principal/capability/expiry. Recognized constraint keys (atom or string):

    * `:input` -- a map; every entry must equal the command input's entry.
    * `:subject` -- must equal the command's semantic subject or its
      `AshA2A.SemanticSubject.fingerprint_token/1`.
    * `:effect_digest` -- must equal `AshA2A.Actuation.identity/1`'s
      `effect_digest` for the command.

  An absent constraint is unconstrained; a declared constraint the command
  does not satisfy (including a command lacking the constrained field) refuses.
  """
  @spec constraints_satisfied?(t(), map()) :: boolean()
  def constraints_satisfied?(%__MODULE__{constraints: constraints}, command)
      when is_map(constraints) do
    Enum.all?(constraints, fn {key, expected} ->
      constraint_ok?(normalize_key(key), expected, command)
    end)
  end

  def constraints_satisfied?(_authority, _command), do: true

  defp normalize_key(key) when is_binary(key) do
    case key do
      "input" -> :input
      "subject" -> :subject
      "effect_digest" -> :effect_digest
      other -> other
    end
  end

  defp normalize_key(key), do: key

  defp constraint_ok?(:input, expected, command) when is_map(expected) do
    input = Map.get(command, :input)

    is_map(input) and
      Enum.all?(expected, fn {k, v} -> input_value(input, k) == {:ok, v} end)
  end

  defp constraint_ok?(:input, _expected, _command), do: false

  defp constraint_ok?(:subject, expected, command) do
    subject = Map.get(command, :semantic_subject)

    not is_nil(subject) and
      (expected == subject or expected == AshA2A.SemanticSubject.fingerprint_token(subject))
  end

  defp constraint_ok?(:effect_digest, expected, %AshA2A.Command{} = command) do
    AshA2A.Actuation.identity(command).effect_digest == expected
  end

  defp constraint_ok?(:effect_digest, _expected, _command), do: false

  # Other keys (e.g. :external_idempotency_token) are carried evidence, not
  # command-matching constraints.
  defp constraint_ok?(_other, _expected, _command), do: true

  defp input_value(input, key) do
    cond do
      Map.has_key?(input, key) ->
        {:ok, Map.fetch!(input, key)}

      is_atom(key) and Map.has_key?(input, Atom.to_string(key)) ->
        {:ok, Map.fetch!(input, Atom.to_string(key))}

      is_binary(key) ->
        string_key_lookup(input, key)

      true ->
        :error
    end
  end

  defp string_key_lookup(input, key) do
    Enum.find_value(input, :error, fn
      {k, v} when is_atom(k) -> if Atom.to_string(k) == key, do: {:ok, v}
      _ -> nil
    end)
  end

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end
end
