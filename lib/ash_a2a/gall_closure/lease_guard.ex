defmodule AshA2A.GallClosure.LeaseGuard do
  @moduledoc """
  Bounded GALL-029/030 guard for `lease_epoch`.

  * `admit/1` (no expectation) is a PRESENCE check only: `lease_epoch` must be a
    non-negative integer. It does not prove the lease is current; callers that hold
    the authoritative lease must use `admit/2`.
  * `admit/2` VALUE-validates against an expected lease (a map with `:epoch`, and
    optionally `:holder`, `:scope`, `:expired`). Refusals are
    `{:refused_gall, :lease_guard, reason}` with reason one of `:stale_epoch`,
    `:epoch_ahead`, `:expired`, `:holder_mismatch`, `:scope_mismatch`,
    `:missing_lease`.
  """

  alias AshA2A.Gall.Fields

  def admit(%{lease_epoch: v} = s) when is_integer(v) and v >= 0,
    do: {:ok, Map.put(s, :gall_guard, :lease_guard)}

  def admit(_), do: {:error, :missing_lease}

  def admit(subject, nil), do: admit(subject)

  def admit(subject, expected) when is_map(expected) do
    with {:ok, %{lease_epoch: epoch} = s} <- presence(subject),
         :ok <- check_expired(expected),
         :ok <- check_epoch(epoch, Fields.get(expected, :epoch)),
         :ok <- check_eq(subject, expected, :holder, :holder_mismatch),
         :ok <- check_eq(subject, expected, :scope, :scope_mismatch) do
      {:ok, s}
    else
      {:refused, reason} -> {:refused_gall, :lease_guard, reason}
    end
  end

  defp presence(subject) do
    case admit(subject) do
      {:ok, s} -> {:ok, s}
      {:error, reason} -> {:refused, reason}
    end
  end

  defp check_expired(expected) do
    if Fields.get(expected, :expired) == true, do: {:refused, :expired}, else: :ok
  end

  defp check_epoch(epoch, exp) when is_integer(exp) and epoch == exp, do: :ok
  defp check_epoch(epoch, exp) when is_integer(exp) and epoch < exp, do: {:refused, :stale_epoch}
  defp check_epoch(_epoch, exp) when is_integer(exp), do: {:refused, :epoch_ahead}
  defp check_epoch(_epoch, _exp), do: {:refused, :missing_lease}

  defp check_eq(subject, expected, key, reason) do
    case Fields.fetch(expected, key) do
      {:ok, want} when not is_nil(want) ->
        case Fields.fetch(subject, key) do
          {:ok, ^want} -> :ok
          _ -> {:refused, reason}
        end

      _ ->
        :ok
    end
  end
end
