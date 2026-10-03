defmodule AshA2A.AuthZEN.Projection do
  @moduledoc """
  Projects an `AshA2A.C2.PreparedEffect` into an AuthZEN request by `from_effect/2`,
  carrying principal and effect digest as policy inputs. A projection only asks the PDP
  a question; its answer is evidence, not authority.
  """

  alias AshA2A.AuthZEN.Types
  alias AshA2A.C2.PreparedEffect

  def from_effect(%PreparedEffect{} = effect, context \\ %{}) when is_map(context) do
    with {:ok, portable} <- PreparedEffect.portable_view(effect) do
      {:ok,
       %Types.Request{
         subject: %Types.Entity{type: "sa2a-principal", id: to_string(effect.principal)},
         action: %Types.Action{name: to_string(effect.capability)},
         resource: %Types.Entity{
           type: "sa2a-prepared-effect",
           id: effect.digest,
           properties: %{"effect_digest" => effect.digest, "subject" => portable["subject"]}
         },
         context:
           Map.merge(context, %{
             "sa2a" => %{
               "effect_digest" => effect.digest,
               "principal" => to_string(effect.principal),
               "prepared_effect_version" => effect.version
             }
           })
       }}
    end
  end
end
