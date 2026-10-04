defmodule AshA2A.Authority.Lease do
  @moduledoc """
  A signed authority lease: the bearer object evaluated by the algebraic
  two-port gate (`AshA2A.Authority.TwoPortGate`, loops-of-loops spec §1
  Loop 1). A lease binds one principal's authority over one command scope to
  one semantic root, for a bounded clock window, under an Ed25519 signature.

  ## The clock law (hybrid, precisely)

  A lease carries BOTH time systems, each with exactly one job:

    * **Persisted fields** (`not_before`, `expires_at` — wall-clock
      `DateTime`) give the lease its **cross-VM validity**: any VM can check
      them. This is the same wall-clock law the persisted grant already uses
      (`AshA2A.Authority.expired?/1`).

    * **The in-flight admission window** is monotonic. When the lease carries
      `issued_monotonic_ms` — a `System.monotonic_time(:millisecond)`
      snapshot captured on the issuing VM — the gate evaluates

          T_start = issued_monotonic_ms
          T_exp   = T_start + (expires_at - not_before)   # milliseconds
          Clock_mono ∈ [T_start, T_exp]

      with `Clock_mono = System.monotonic_time(:millisecond)` captured at
      gate entry. This satisfies the spec's `Clock_mono ∈ [T_start, T_exp]`
      on the same-VM path and structurally eliminates NTP time-travel,
      leap-second jitter, and wall-clock spoofing for in-flight evaluation.

    * **Cross-VM fallback**: a lease whose `issued_monotonic_ms` is `nil`
      (stripped by the transport when a lease crosses VMs — monotonic values
      are meaningless across VM boots) evaluates against the persisted
      wall-clock window `[not_before, expires_at]` only.

  Consequence of the hybrid, stated honestly: on the same-VM path the
  `not_before` bound does NOT gate the monotonic window — the window opens at
  issuance. A lease must therefore be constructed with `not_before <=` issue
  wall-clock time (the `for_command/2` default), or its monotonic window
  opens before its wall validity does. A future `not_before` only bites on
  the cross-VM (wall-clock) path.

  ## Carry law

  `issued_monotonic_ms` is VM-local and MUST be set by the transport to `nil`
  when a lease is serialized across VMs. A non-nil value on a receiving VM is
  a meaningless number compared against an unrelated boot's clock; the gate
  cannot detect a foreign-VM monotonic value, so the carry law puts the duty
  on the carrier. Within the issuing VM the field is authoritative for the
  in-flight window.

  ## Framing law

  `sign/2` signs the canonical sorted-key JSON of the lease's public map
  (every field except `:signature`), prefixed with a domain-separation tag.
  Encoding is `AshA2A.Json.canonical/1` — recursively sorted object
  keys — so signing and verification frame byte-identically on any VM. The
  signature is Ed25519 (`Sa2aCrypto.Native.verify("EdDSA", msg, sig, pub)`,
  which fails closed on `{:error, :bad_signature}` / `:bad_key` / malformed
  input — nothing raises).
  """

  alias AshA2A.{Actuation, Command, Identity}

  @domain_tag "ash_a2a.lease/v1:"
  @lease_id_prefix "lease-"

  @enforce_keys [:lease_id, :scope_digest, :root_digest, :not_before, :expires_at]
  defstruct [
    :lease_id,
    :scope_digest,
    :root_digest,
    :not_before,
    :expires_at,
    # VM-local monotonic snapshot at issuance. nil = cross-VM lease: the gate
    # falls back to the persisted wall-clock window. See the clock law above.
    :issued_monotonic_ms,
    :payload_map,
    :signature
  ]

  @type t :: %__MODULE__{
          lease_id: String.t(),
          scope_digest: String.t(),
          root_digest: String.t() | nil,
          not_before: DateTime.t(),
          expires_at: DateTime.t(),
          issued_monotonic_ms: integer() | nil,
          payload_map: map(),
          signature: binary() | nil
        }

  @doc """
  Builds a lease. Required keys: `:lease_id`, `:scope_digest`, `:root_digest`,
  `:not_before`, `:expires_at`. Optional: `:issued_monotonic_ms` (default
  `System.monotonic_time(:millisecond)` — same-VM by default; pass
  `issued_monotonic_ms: nil` explicitly for a cross-VM lease), `:payload_map`
  (default `%{}`), `:signature` (default `nil`).
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      lease_id: Keyword.fetch!(opts, :lease_id),
      scope_digest: Keyword.fetch!(opts, :scope_digest),
      root_digest: Keyword.fetch!(opts, :root_digest),
      not_before: Keyword.fetch!(opts, :not_before),
      expires_at: Keyword.fetch!(opts, :expires_at),
      issued_monotonic_ms:
        Keyword.get(opts, :issued_monotonic_ms, System.monotonic_time(:millisecond)),
      payload_map: Map.new(Keyword.get(opts, :payload_map, %{})),
      signature: Keyword.get(opts, :signature)
    }
  end

  @doc """
  Builds a lease bound to `command`: the scope digest is `Actuation.digest/1`
  over `scope_of/1`, the root digest defaults to the command's
  `semantic_subject.graph_digest` (the RDFC-1.0 root carried by the subject;
  an opaque `sha256:`-prefixed string), `not_before` is now (wall), and
  `expires_at` is now + `:ttl_ms` (default 60_000).

  Options: `:ttl_ms`, `:lease_id`, `:payload_map`, `:issued_monotonic_ms`
  (pass `nil` for a cross-VM lease), `:root_digest` (explicit override, e.g.
  an RDFC-1.0 bare-hex digest computed from Turtle).
  """
  @spec for_command(Command.t(), keyword()) :: t()
  def for_command(%Command{} = command, opts \\ []) do
    now = DateTime.utc_now()

    new(
      lease_id:
        Keyword.get(
          opts,
          :lease_id,
          @lease_id_prefix <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        ),
      scope_digest: scope_digest_for(command),
      root_digest: Keyword.get(opts, :root_digest, root_of(command)),
      not_before: now,
      expires_at: DateTime.add(now, Keyword.get(opts, :ttl_ms, 60_000), :millisecond),
      issued_monotonic_ms:
        Keyword.get(opts, :issued_monotonic_ms, System.monotonic_time(:millisecond)),
      payload_map: Keyword.get(opts, :payload_map, %{})
    )
  end

  @doc """
  The command's target/subject scope map: the stable primitive identity of
  what the lease is allowed to cover. Digesting this map with
  `AshA2A.Actuation.digest/1` (deterministic `term_to_binary` SHA-256 —
  chosen over `AshA2A.Semantic.CanonicalGraph` because a scope map is a plain
  term, not RDF) is conjunct (a) of the gate.
  """
  @spec scope_of(Command.t()) :: map()
  def scope_of(%Command{} = command) do
    %{
      "capability_id" => command.capability_id,
      "principal_id" => identity_value(command.principal_id),
      "task_id" => task_value(command.task_id)
    }
  end

  @doc """
  The command's root digest: the RDFC-1.0 root carried by its semantic
  subject (`semantic_subject.graph_digest`), or `nil` when the command has no
  semantic subject.
  """
  @spec root_of(Command.t()) :: String.t() | nil
  def root_of(%Command{semantic_subject: %AshA2A.SemanticSubject{graph_digest: digest}}),
    do: digest

  def root_of(%Command{}), do: nil

  @doc """
  The exact bytes signed: `@domain_tag <> canonical-JSON(public_map/1)`.
  Public so a verifier can re-frame the signature input independently.
  """
  @spec signing_input(t()) :: binary()
  def signing_input(%__MODULE__{} = lease) do
    @domain_tag <> AshA2A.Json.canonical(public_map(lease))
  end

  @doc """
  The lease's public map — every field the signature covers, minus the
  signature itself. Datetimes as ISO8601 strings, so the framing is stable
  across processes and VMs.
  """
  @spec public_map(t()) :: map()
  def public_map(%__MODULE__{} = lease) do
    %{
      "lease_id" => lease.lease_id,
      "scope_digest" => lease.scope_digest,
      "root_digest" => lease.root_digest,
      "not_before" => iso(lease.not_before),
      "expires_at" => iso(lease.expires_at),
      "issued_monotonic_ms" => lease.issued_monotonic_ms,
      "payload_map" => lease.payload_map
    }
  end

  @doc """
  Signs `lease` with an Ed25519 private key (raw 32 bytes). Returns the lease
  with `:signature` set. `{:error, :bad_key}` when `Sa2aCrypto.Native`
  refuses the key.
  """
  @spec sign(t(), binary()) :: {:ok, t()} | {:error, :bad_key}
  def sign(%__MODULE__{} = lease, private_key) when is_binary(private_key) do
    case Sa2aCrypto.Native.sign("EdDSA", signing_input(lease), private_key) do
      {:ok, signature} -> {:ok, %__MODULE__{lease | signature: signature}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Fail-closed Ed25519 verification of `signature` over the lease's public
  map. `:ok | {:error, :bad_signature | :bad_key | :malformed}`. Any
  unexpected shape is `{:error, :malformed}` — never a raise, never a pass.
  """
  @spec verify(t(), binary() | nil, binary() | nil) :: :ok | {:error, atom()}
  def verify(_lease, nil, _public_key), do: {:error, :bad_signature}
  def verify(_lease, _signature, nil), do: {:error, :bad_key}

  def verify(%__MODULE__{} = lease, signature, public_key) when is_binary(signature) do
    Sa2aCrypto.Native.verify("EdDSA", signing_input(lease), signature, public_key)
  end

  def verify(_lease, _signature, _public_key), do: {:error, :malformed}

  @doc """
  The scope digest the gate pins for `command` — the value conjunct (a)
  compares the lease's `scope_digest` against.
  """
  @spec scope_digest_for(Command.t()) :: String.t()
  def scope_digest_for(%Command{} = command), do: Actuation.digest(scope_of(command))

  @doc "True when the lease's wall-clock window excludes now."
  @spec wall_expired?(t()) :: boolean()
  def wall_expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  # --- helpers ---------------------------------------------------------------

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(other), do: other

  defp identity_value(%Identity{value: value}), do: value
  defp identity_value(other), do: other

  defp task_value(nil), do: nil
  defp task_value(%Identity{value: value}), do: value
  defp task_value(other), do: other
end
