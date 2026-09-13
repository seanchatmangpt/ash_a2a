defmodule AshA2A.Info do
  @moduledoc """
  Introspection for the `AshA2A` extension.

  v26.9.12 treats Ash as the canonical capability source. The extension
  persists only residual A2A overrides plus whether the attached subject is a
  resource or domain; every `capability_index*` call derives the current index
  from `Ash.Resource.Info.public_actions/1` through
  `AshA2A.CapabilityIndex.Compiler`.
  """

  alias AshA2A.CapabilityIndex.Compiler
  alias Spark.Dsl.Extension

  @type not_compiled :: :not_compiled

  @spec capability_index(module()) :: [AshA2A.CapabilityIndex.skill()] | nil
  def capability_index(resource_or_domain) do
    case capability_index_result(resource_or_domain) do
      {:ok, index} -> index
      {:error, :not_compiled} -> nil
    end
  end

  @spec capability_index_result(module()) ::
          {:ok, [AshA2A.CapabilityIndex.skill()]} | {:error, not_compiled()}
  def capability_index_result(resource_or_domain) do
    kind = Extension.get_persisted(resource_or_domain, :ash_a2a_subject_kind, nil)
    overrides = Extension.get_persisted(resource_or_domain, :ash_a2a_skill_overrides, nil)

    case {kind, overrides} do
      {kind, overrides} when kind in [:resource, :domain] and is_list(overrides) ->
        {:ok, Compiler.compile(resource_or_domain, kind, overrides)}

      _ ->
        {:error, :not_compiled}
    end
  end

  @spec capability_index!(module()) :: [AshA2A.CapabilityIndex.skill()]
  def capability_index!(resource_or_domain) do
    case capability_index_result(resource_or_domain) do
      {:ok, index} ->
        index

      {:error, :not_compiled} ->
        raise ArgumentError,
              "#{inspect(resource_or_domain)} has no compiled AshA2A capability index -- " <>
                "add the `AshA2A` extension and ensure the module has compiled"
    end
  end

  @spec capability_index?(module()) :: boolean()
  def capability_index?(resource_or_domain) do
    match?({:ok, _}, capability_index_result(resource_or_domain))
  end

  @doc "Looks up one projected skill by A2A id or residual display/selector name."
  @spec skill(module(), atom() | String.t()) ::
          {:ok, AshA2A.CapabilityIndex.skill()} | {:error, :skill_not_found}
  def skill(resource_or_domain, selector) do
    resource_or_domain
    |> capability_index()
    |> List.wrap()
    |> Enum.find(fn skill ->
      skill.id == selector || skill.name == selector ||
        to_string(skill.name) == to_string(selector)
    end)
    |> case do
      nil -> {:error, :skill_not_found}
      skill -> {:ok, skill}
    end
  end

  @spec agent_card(module(), keyword()) :: A2A.AgentCard.t()
  def agent_card(resource_or_domain, opts \\ []) do
    resource_or_domain
    |> capability_index()
    |> List.wrap()
    |> AshA2A.CapabilityIndex.build_agent_card(opts)
  end
end
