defmodule Actuator.EffectorRegistry do
  @moduledoc """
  CLOSED registry of typed effects. There is no shell, URL, path, MFA, SQL or module name
  anywhere in a request: an effect names one of these `effect_type`s and supplies params
  under that type's total schema. Adding an effector is a code change to this list.

  Each entry pins the capability id, the consequence class and the byte ceiling the
  actuator will honour regardless of what the request's `resource_bounds` claim.
  """
  @effectors %{
    "ledger_append" => %{
      capability: "actuator.ledger.append",
      consequence_class: "internal_append",
      max_bytes: 4096,
      module: Actuator.Effector.LedgerAppend
    },
    "noop_probe" => %{
      capability: "actuator.noop.probe",
      consequence_class: "none",
      max_bytes: 0,
      module: Actuator.Effector.NoopProbe
    }
  }

  @callback validate_params(map()) :: :ok | :error
  @callback size(map()) :: non_neg_integer()
  @callback perform(handles :: map(), Actuator.Effect.t(), digest :: String.t()) ::
              {:ok, map()} | {:error, term()}

  def types, do: Map.keys(@effectors)
  def fetch(type) when is_binary(type), do: Map.fetch(@effectors, type)
  def fetch(_), do: :error
end
