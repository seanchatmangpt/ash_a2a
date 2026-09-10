defmodule AshA2A.CapabilityIndex do
  @moduledoc """
  Fail-closed validation of a compiled A2A capability index.

  Per the ash_a2a ARD (`~/ggen-marketplace/docs/explanation/ash-a2a-prd-ard.md`
  §3.3), `DSL valid ⇏ Capability valid`: a transformer persists the compiled
  skill list as a canonical IR, and this module is the hand-written business
  check a generated `Spark.Dsl.Verifier` delegates to — mirroring
  `AshR2RML.Resource.Verify` delegating to `AshR2RML.Mapping.validate/1`
  (`~/ash_r2rml/lib/ash_r2rml/resource.ex:492-511`,
  `~/ash_r2rml/lib/ash_r2rml/mapping.ex:243-253`).

  Two checks, both fail-closed:

    * every skill name is unique across the compiled index;
    * every skill's `{resource, action}` pair names an action that actually
      exists on that resource, confirmed via the real
      `Ash.Resource.Info.action/2` introspection function
      (`~/xaas/deps/ash/lib/ash/resource/info.ex:716`,
      `def action(resource, name, type \\\\ nil)` — called here at arity 2).
  """

  @type skill :: %{
          required(:name) => atom(),
          required(:resource) => module(),
          optional(:domain) => module() | nil,
          required(:action) => atom(),
          optional(:arguments) => [term()]
        }
  @type refusal :: %{code: atom(), detail: String.t()}

  @doc """
  Builds a real `A2A.AgentCard.t()` from the persisted, verified capability
  index (a list of compiled skill maps, the same shape `validate/1` checks).

  Per the ARD (§3.2), `AshA2A.Info.agent_card/1` is expected to call this
  function against the persisted index only -- never raw DSL entities --
  so the advertised card and the dispatch table can never diverge.

  `A2A.AgentCard` struct fields/types are taken verbatim from
  `~/xaas/deps/a2a/lib/a2a/agent_card.ex:16-76`; this function builds no
  field that struct doesn't define. `:name`, `:description`, `:url`, and
  `:version` come from `opts` since the compiled index carries no
  agent-identity metadata -- only skill/action mappings.

  ## Options

    * `:name` -- agent card name (default: `"ash_a2a_agent"`)
    * `:description` -- agent card description (default derived from skill count)
    * `:url` -- agent's base URL (default: `"http://localhost:4000"`)
    * `:version` -- agent card version (default: `"0.1.0"`)
    * `:provider` -- `A2A.AgentCard.provider()` map, or `nil` (default: `nil`)

  """
  @spec build_agent_card([skill()], keyword()) :: A2A.AgentCard.t()
  def build_agent_card(skills, opts \\ []) when is_list(skills) do
    %A2A.AgentCard{
      name: Keyword.get(opts, :name, "ash_a2a_agent"),
      description:
        Keyword.get(
          opts,
          :description,
          "Ash-backed A2A agent exposing #{length(skills)} skill(s)."
        ),
      url: Keyword.get(opts, :url, "http://localhost:4000"),
      version: Keyword.get(opts, :version, "0.1.0"),
      skills: Enum.map(skills, &build_agent_card_skill/1),
      provider: Keyword.get(opts, :provider)
    }
  end

  @spec build_agent_card_skill(skill()) :: A2A.AgentCard.skill()
  defp build_agent_card_skill(%{name: name, resource: resource, action: action} = skill) do
    arguments = Map.get(skill, :arguments, [])

    %{
      id: to_string(name),
      name: to_string(name),
      description: "Dispatches to #{inspect(resource)}.#{action}/*",
      tags: Enum.map(arguments, &argument_tag/1)
    }
  end

  defp argument_tag(%{name: arg_name}), do: to_string(arg_name)
  defp argument_tag(other) when is_atom(other) or is_binary(other), do: to_string(other)

  @spec validate([skill()]) :: :ok | {:error, [refusal()]}
  def validate(skills) when is_list(skills) do
    refusals = validate_unique_names(skills) ++ validate_actions_exist(skills)

    if refusals == [], do: :ok, else: {:error, refusals}
  end

  defp validate_unique_names(skills) do
    skills
    |> Enum.frequencies_by(& &1.name)
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, count} ->
      %{
        code: :REFUSED_DUPLICATE_SKILL_NAME,
        detail:
          "skill name #{inspect(name)} is declared #{count} times; skill names must be unique"
      }
    end)
  end

  defp validate_actions_exist(skills) do
    Enum.flat_map(skills, fn %{name: name, resource: resource, action: action} ->
      case Ash.Resource.Info.action(resource, action) do
        nil ->
          [
            %{
              code: :REFUSED_ACTION_NOT_FOUND,
              detail:
                "skill #{inspect(name)} names action #{inspect(action)} on #{inspect(resource)}, " <>
                  "but no such action exists on that resource"
            }
          ]

        %{} ->
          []
      end
    end)
  end
end
