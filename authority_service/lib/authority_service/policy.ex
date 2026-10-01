defmodule AuthorityService.Policy do
  @moduledoc """
  Static policy: `effect_class` -> required `k` distinct human custodians out of the `n`
  registered `approvers`; policy epoch; TTLs (300s human / 900s automated); clock skew
  allowance (5s). `k = 0` is the automated tier.

  The approval tier derives from the server-side policy class ONLY. A class's `k` is the
  maximum `k` among its configured tiers (most restrictive); any amount the requester put
  in the effect never lowers it (B3: tier confusion).
  """
  @tiers [:i1, :i2, :i3, :i4]

  @enforce_keys [:epoch, :approvers, :classes]
  defstruct [
    :epoch,
    :approvers,
    :classes,
    min_approver_tier: :i3,
    human_ttl: 300,
    automated_ttl: 900,
    skew: 5,
    max_approvals: 16
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts) do
    p = struct!(__MODULE__, opts)
    n = length(Enum.uniq(p.approvers))

    unless is_integer(p.epoch) and p.epoch >= 0, do: raise(ArgumentError, "bad policy epoch")
    unless p.min_approver_tier in @tiers, do: raise(ArgumentError, "bad min_approver_tier")

    for {class, tiers} <- p.classes, tier <- tiers do
      unless is_binary(class) and is_integer(tier.k) and tier.k >= 0 and tier.k <= n do
        raise ArgumentError, "policy tier unsatisfiable for #{inspect(class)}: k=#{tier.k} n=#{n}"
      end
    end

    %{p | approvers: Enum.uniq(p.approvers)}
  end

  @doc "Required distinct approvers for a policy class; fail closed on an unknown class."
  @spec required(t(), String.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def required(%__MODULE__{classes: classes}, class) when is_binary(class) do
    case Map.fetch(classes, class) do
      {:ok, [_ | _] = tiers} -> {:ok, tiers |> Enum.map(& &1.k) |> Enum.max()}
      _ -> {:error, :unknown_effect_class}
    end
  end

  def required(_, _), do: {:error, :malformed_effect}

  @doc "Ordering of custody tiers."
  def tier_rank(t), do: Enum.find_index(@tiers, &(&1 == t))

  @doc "Load from a JSON file (`epoch`, `approvers`, `min_approver_tier`, `classes`)."
  @spec from_json(binary()) :: {:ok, t()} | {:error, :policy_malformed}
  def from_json(json) do
    with {:ok, m} <- Sa2aCrypto.StrictJson.decode(json, canonical: false),
         classes <-
           Map.new(m["classes"], fn {c, tiers} ->
             {c,
              Enum.map(tiers, fn t ->
                %{max_amount: cap(t["max_amount"]), k: t["k"]}
              end)}
           end) do
      {:ok,
       new(
         epoch: m["epoch"],
         approvers: m["approvers"],
         min_approver_tier: String.to_existing_atom(m["min_approver_tier"] || "i3"),
         classes: classes
       )}
    end
  rescue
    _ -> {:error, :policy_malformed}
  end

  defp cap("infinity"), do: :infinity
  defp cap(n) when is_integer(n), do: n
end
