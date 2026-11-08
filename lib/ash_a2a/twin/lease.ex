defmodule AshA2A.Twin.Lease do
  @moduledoc """
  Monotonic execution leases exchanged between twins.

  A lease is a time-bounded claim on a resource, stamped with
  `:erlang.monotonic_time/1` so wall-clock changes never extend or shorten a
  lease. Zombie semantics: a lease that reaches expiry without a renewal is a
  zombie — `expired?/3` is the fail-closed check (unknown lease, wrong holder,
  or past-due all read as not-held).

  Shape-compatible with ash_pplan's durable `renew_claim` seam (claimed_by /
  lease_until, fail-closed), but an independent module.

  Clock injection: pass `clock: {:mono, fun}` options so tests inject
  monotonic time and never sleep.
  """

  @enforce_keys [:id, :holder, :lease_until, :granted_at]
  defstruct [:id, :holder, :lease_until, :granted_at, renewed_count: 0]

  @type id :: term()
  @type t :: %__MODULE__{
          id: id(),
          holder: term(),
          lease_until: integer(),
          granted_at: integer(),
          renewed_count: non_neg_integer()
        }

  @doc "Current monotonic time in the lease's native unit."
  @spec now() :: integer()
  def now, do: :erlang.monotonic_time(:native)

  @doc """
  Grant a new lease to `holder` for `duration` (in the same time unit as the
  clock). Returns the lease. Duration must be positive.
  """
  @spec grant(term(), term(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, :invalid_duration}
  def grant(id, holder, duration, opts \\ [])

  def grant(_id, _holder, duration, _opts) when duration <= 0,
    do: {:error, :invalid_duration}

  def grant(id, holder, duration, opts) do
    now = clock_now(opts)

    {:ok,
     %__MODULE__{
       id: id,
       holder: holder,
       granted_at: now,
       lease_until: now + duration,
       renewed_count: 0
     }}
  end

  @doc """
  Renew a lease: compare-and-swap on holder. Only the current holder can
  extend the lease; a stale or foreign holder gets a typed refusal.
  """
  @spec renew(t(), term(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, :not_holder | :invalid_duration}
  def renew(lease, claimant, duration, opts \\ [])

  def renew(_lease, _claimant, duration, _opts) when duration <= 0,
    do: {:error, :invalid_duration}

  def renew(%__MODULE__{} = lease, claimant, duration, opts) do
    if lease.holder == claimant do
      now = clock_now(opts)
      {:ok, %{lease | lease_until: now + duration, renewed_count: lease.renewed_count + 1}}
    else
      {:error, :not_holder}
    end
  end

  @doc """
  Fail-closed expiry check: true only when the lease is NOT held by `holder`
  at the given (or real) monotonic time.
  """
  @spec expired?(t(), term(), keyword()) :: boolean()
  def expired?(%__MODULE__{} = lease, holder, opts \\ []) do
    not held?(lease, holder, opts)
  end

  @doc "True when the lease is currently held by `holder` (fail-closed inverse of expired?/3)."
  @spec held?(t(), term(), keyword()) :: boolean()
  def held?(%__MODULE__{} = lease, holder, opts \\ []) do
    now = clock_now(opts)
    lease.holder == holder and lease.lease_until > now
  end

  @doc "Revoke a lease: only the current holder (or an explicit `:force` supervisor) may revoke."
  @spec revoke(t(), term() | :force) :: {:ok, t()} | {:error, :not_holder}
  def revoke(%__MODULE__{} = lease, :force) do
    {:ok, %{lease | lease_until: lease.granted_at, holder: nil}}
  end

  def revoke(%__MODULE__{holder: h} = lease, h) do
    {:ok, %{lease | lease_until: lease.granted_at, holder: nil}}
  end

  def revoke(%__MODULE__{}, _other), do: {:error, :not_holder}

  # -- clock injection seam --------------------------------------------------

  @doc """
  Clock-injection seam: resolve `clock: {:mono, fun}` to the injected
  monotonic fun; default is the real monotonic clock. Any existing module
  wanting lease semantics can call this instead of re-implementing monotonic
  arithmetic.
  """
  @spec clock_now(keyword()) :: integer()
  def clock_now(opts) do
    case Keyword.fetch(opts, :clock) do
      {:ok, {:mono, fun}} when is_function(fun, 0) -> fun.()
      :error -> now()
    end
  end
end
