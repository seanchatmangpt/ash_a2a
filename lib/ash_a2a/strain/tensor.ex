defmodule AshA2A.Strain.Tensor do
  @moduledoc """
  AHDCLT cognitive-load tensor: a named-dimension map of coordinator load.

  Each dimension is typed with a documented normalization to 0.0-1.0 so that
  `strain/2` yields comparable values across heterogeneous dimensions.

  ## Dimensions and normalization constants

  | dimension | raw unit | normalization | constant |
  |---|---|---|---|
  | `:shift_hours_continuous` | hours into current shift | circadian decay `1 - exp(-h / 4.0)`, monotonic within shift, resets at shift boundary (caller passes 0) | `@circadian_tau 4.0` |
  | `:active_leases` | count of held leases | `min(1, count / 12)` | `@lease_saturation 12` |
  | `:error_rate` | rolling-window ratio (0.0-1.0) | identity, clamped to 1.0 | `@error_rate_cap 1.0` |
  | `:heuristic_frequency` | flagged-event count in rolling window | `min(1, count / 10)` | `@heuristic_cap 10` |
  | `:attestation_age_sec` | seconds since last attestation | `min(1, age / 3600)` | `@attestation_max_age 3600` |
  | `:financial_risk_exposure` | dollars at risk | `min(1, exposure / 50_000)` | `@exposure_cap 50_000` |

  The tensor is a plain map; `update/3` is pure (observation in, tensor out).
  """

  @circadian_tau 4.0
  @lease_saturation 12
  @error_rate_cap 1.0
  @heuristic_cap 10
  @attestation_max_age 3600
  @exposure_cap 50_000

  @saturation_threshold 0.7

  @dimensions [
    :shift_hours_continuous,
    :active_leases,
    :error_rate,
    :heuristic_frequency,
    :attestation_age_sec,
    :financial_risk_exposure
  ]

  @type dimension :: unquote(Enum.reduce(@dimensions, &{:|, [], [&1, &2]}))

  @type t :: %{optional(dimension()) => number()}

  @doc "Known dimension keys."
  @spec dimensions() :: [dimension(), ...]
  def dimensions, do: @dimensions

  @doc """
  Build a tensor from an observation map. Unknown keys raise; missing keys
  default to zero-observation values.
  """
  @spec new(map()) :: t()
  def new(observation) when is_map(observation) do
    Enum.reduce(observation, defaults(), fn {k, v}, acc ->
      put_known(acc, k, v)
    end)
  end

  @doc """
  Pure update: observation in, tensor out. Shift-boundary reset is modelled by
  the caller passing `shift_hours_continuous: 0` — the tensor keeps no clock,
  so the curve is monotonic within a shift by construction.
  """
  @spec update(t(), map(), keyword()) :: t()
  def update(tensor, observation, _opts \\ []) when is_map(tensor) and is_map(observation) do
    Enum.reduce(observation, tensor, fn {k, v}, acc ->
      put_known(acc, k, v)
    end)
  end

  @doc """
  Normalized strain for a dimension key, 0.0-1.0. Per-dimension normalization
  is documented in the moduledoc table and asserted numerically in tests.
  """
  @spec strain(t(), dimension()) :: float()
  def strain(tensor, :shift_hours_continuous) do
    h = fetch_non_neg(tensor, :shift_hours_continuous)
    # circadian decay: monotonic within shift, saturates toward 1.0
    1 - :math.exp(-h / @circadian_tau)
  end

  def strain(tensor, :active_leases) do
    min(1, fetch_non_neg(tensor, :active_leases) / @lease_saturation) * 1.0
  end

  def strain(tensor, :error_rate) do
    min(@error_rate_cap, fetch_non_neg(tensor, :error_rate)) * 1.0
  end

  def strain(tensor, :heuristic_frequency) do
    min(1, fetch_non_neg(tensor, :heuristic_frequency) / @heuristic_cap) * 1.0
  end

  def strain(tensor, :attestation_age_sec) do
    min(1, fetch_non_neg(tensor, :attestation_age_sec) / @attestation_max_age) * 1.0
  end

  def strain(tensor, :financial_risk_exposure) do
    min(1, fetch_non_neg(tensor, :financial_risk_exposure) / @exposure_cap) * 1.0
  end

  @doc """
  Named boundary gates over the weighted sum of normalized strains.

  Returns `{:breach, {:saturation_gate, weighted_sum, threshold}}` when the
  weighted sum exceeds the threshold; `:ok` when no gate fires.
  """
  @spec hyperplane_check(t(), atom() | [atom()]) :: :ok | {:breach, term()}
  def hyperplane_check(tensor, gates \\ :saturation_gate)

  def hyperplane_check(tensor, :saturation_gate) do
    total =
      @dimensions
      |> Enum.map(fn dim -> weight(dim) * strain(tensor, dim) end)
      |> Enum.sum()

    if total > @saturation_threshold do
      {:breach, {:saturation_gate, total, @saturation_threshold}}
    else
      :ok
    end
  end

  def hyperplane_check(tensor, gates) when is_list(gates) do
    Enum.reduce_while(gates, :ok, fn gate, :ok ->
      case hyperplane_check(tensor, gate) do
        :ok -> {:cont, :ok}
        breach -> {:halt, breach}
      end
    end)
  end

  defp weight(:shift_hours_continuous), do: 0.30
  defp weight(:active_leases), do: 0.25
  defp weight(:error_rate), do: 0.20
  defp weight(:heuristic_frequency), do: 0.10
  defp weight(:attestation_age_sec), do: 0.05
  defp weight(:financial_risk_exposure), do: 0.10

  defp defaults do
    %{
      shift_hours_continuous: 0,
      active_leases: 0,
      error_rate: 0.0,
      heuristic_frequency: 0,
      attestation_age_sec: 0,
      financial_risk_exposure: 0
    }
  end

  defp put_known(acc, k, v) do
    case k in @dimensions do
      true -> Map.put(acc, k, v)
      false -> raise ArgumentError, "unknown strain dimension: #{inspect(k)}"
    end
  end

  defp fetch_non_neg(tensor, key) do
    v = Map.fetch!(tensor, key)

    if is_number(v) and v >= 0 do
      v
    else
      raise ArgumentError,
            "dimension #{inspect(key)} requires non-negative number, got: #{inspect(v)}"
    end
  end
end
