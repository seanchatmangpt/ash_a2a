defmodule Actuator.Effector.LedgerAppend do
  @moduledoc "Appends one entry to the actuator's own append-only hash-chained effect ledger."
  @behaviour Actuator.EffectorRegistry

  @impl true
  def validate_params(%{"entry" => e} = p) when map_size(p) == 1 and is_binary(e) do
    if String.valid?(e) and e != "", do: :ok, else: :error
  end

  def validate_params(_), do: :error

  @impl true
  def size(%{"entry" => e}), do: byte_size(e)

  @impl true
  def perform(%{ledger: ledger}, effect, digest) do
    Actuator.Ledger.append(ledger, %{
      "effect_instance_id" => effect.effect_instance_id,
      "effect_digest" => digest,
      "entry" => effect.params["entry"]
    })
  end
end
