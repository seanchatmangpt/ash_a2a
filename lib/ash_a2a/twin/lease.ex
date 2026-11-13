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
  monotonic time and never sleep. A malformed injected clock (nil, wrong
  arity, non-integer result) is never fatal on the check path: `held?/3` and
  `expired?/3` read it as not-held; `grant/4` and `renew/4` return
  `{:error, :invalid_clock}`.

  A revoked lease has `holder: nil` and can never be renewed or held, by
  `nil` or anyone else.
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
  Grant a new lease to `holder` for `duration` (a positive number in the same
  time unit as the clock). Returns the lease.
  """
  @spec grant(term(), term(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, :invalid_duration | :invalid_clock}
  def grant(id, holder, duration, opts \\ [])

  def grant(id, holder, duration, opts) do
    with :ok <- check_duration(duration),
         {:ok, now} <- fetch_now(opts) do
      {:ok,
       %__MODULE__{
         id: id,
         holder: holder,
         granted_at: now,
         lease_until: now + duration,
         renewed_count: 0
       }}
    end
  end

  @doc """
  Renew a lease: compare-and-swap on holder. Only the current holder can
  extend the lease, and only while it is still held: a stale, foreign or
  `nil` claimant gets `:not_holder`; a lease past its expiry gets `:expired`
  (a zombie stays dead until re-granted).
  """
  @spec renew(t(), term(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, :not_holder | :expired | :invalid_duration | :invalid_clock}
  def renew(lease, claimant, duration, opts \\ [])

  def renew(%__MODULE__{holder: holder} = lease, claimant, duration, opts) do
    with :ok <- check_duration(duration),
         :ok <- check_claimant(holder, claimant),
         {:ok, now} <- fetch_now(opts),
         :ok <- check_unexpired(lease, now) do
      {:ok, %{lease | lease_until: now + duration, renewed_count: lease.renewed_count + 1}}
    end
  end

  @doc """
  Fail-closed expiry check: true unless the lease is held by `holder` at the
  given (or real) monotonic time. Malformed clock or nil holder read as expired.
  """
  @spec expired?(t(), term(), keyword()) :: boolean()
  def expired?(%__MODULE__{} = lease, holder, opts \\ []) do
    not held?(lease, holder, opts)
  end

  @doc "True when the lease is currently held by `holder` (fail-closed inverse of expired?/3)."
  @spec held?(t(), term(), keyword()) :: boolean()
  def held?(%__MODULE__{} = lease, holder, opts \\ []) do
    case fetch_now(opts) do
      {:ok, now} -> not is_nil(holder) and lease.holder == holder and lease.lease_until > now
      {:error, _} -> false
    end
  end

  @doc """
  Revoke a lease: only the current holder (or an explicit `:force` supervisor)
  may revoke. A nil holder (already revoked) cannot revoke.
  """
  @spec revoke(t(), term() | :force) :: {:ok, t()} | {:error, :not_holder}
  def revoke(%__MODULE__{} = lease, :force) do
    {:ok, %{lease | lease_until: lease.granted_at, holder: nil}}
  end

  def revoke(%__MODULE__{holder: h} = lease, h) when not is_nil(h) do
    {:ok, %{lease | lease_until: lease.granted_at, holder: nil}}
  end

  def revoke(%__MODULE__{}, _other), do: {:error, :not_holder}

  # -- clock injection seam --------------------------------------------------

  @doc """
  Clock-injection seam: resolve `clock: {:mono, fun}` to the injected
  monotonic fun; default is the real monotonic clock. Raises `ArgumentError`
  on a malformed injected clock; the lease API itself uses the non-raising
  path and returns typed results.
  """
  @spec clock_now(keyword()) :: integer()
  def clock_now(opts) do
    case fetch_now(opts) do
      {:ok, now} ->
        now

      {:error, :invalid_clock} ->
        raise ArgumentError, "invalid lease clock: #{inspect(opts[:clock])}"
    end
  end

  defp fetch_now(opts) do
    case Keyword.fetch(opts, :clock) do
      :error ->
        {:ok, now()}

      {:ok, {:mono, fun}} when is_function(fun, 0) ->
        case safe_call(fun) do
          n when is_integer(n) -> {:ok, n}
          _ -> {:error, :invalid_clock}
        end

      {:ok, _} ->
        {:error, :invalid_clock}
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp check_duration(d) when is_number(d) and d > 0, do: :ok
  defp check_duration(_), do: {:error, :invalid_duration}

  defp check_claimant(nil, _), do: {:error, :not_holder}
  defp check_claimant(_, nil), do: {:error, :not_holder}
  defp check_claimant(h, h), do: :ok
  defp check_claimant(_, _), do: {:error, :not_holder}

  defp check_unexpired(%{lease_until: until}, now) when until > now, do: :ok
  defp check_unexpired(_, _), do: {:error, :expired}
end
