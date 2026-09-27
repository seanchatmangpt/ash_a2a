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
  alias AshA2A.CapabilityRelease
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
    |> Enum.filter(fn skill ->
      skill.id == selector || skill.name == selector ||
        to_string(skill.name) == to_string(selector)
    end)
    |> case do
      [] ->
        {:error, :skill_not_found}

      [skill] ->
        {:ok, skill}

      matches ->
        # b4p-f5-10: an exact capability-id match wins even when the display
        # name is shared; otherwise a multi-match selector is ambiguous and
        # refused typed rather than resolving to the index-first namesake.
        case Enum.filter(matches, &(&1.id == selector)) do
          [skill] -> {:ok, skill}
          _ -> {:error, {:ambiguous_skill, selector}}
        end
    end
  end

  @doc """
  Build an AgentCard from the same release closure used by runtime dispatch.

  Legacy mode advertises the full derived capability index. Strict mode
  advertises only exact skill ids present in the frozen released closure.
  """
  @spec agent_card(module(), keyword()) :: A2A.AgentCard.t()
  def agent_card(resource_or_domain, opts \\ []) do
    case released_capability_index_result(resource_or_domain, opts) do
      {:ok, index} ->
        card_opts =
          Keyword.drop(opts, [:capability_release_closure, :capability_release_mode])

        AshA2A.CapabilityIndex.build_agent_card(index, card_opts)

      {:error, reason} ->
        raise ArgumentError, "cannot build released AgentCard: #{inspect(reason)}"
    end
  end

  @doc "Derived capability index filtered through the active release closure."
  @spec released_capability_index(module(), keyword()) ::
          [AshA2A.CapabilityIndex.skill()] | nil
  def released_capability_index(resource_or_domain, opts \\ []) do
    case released_capability_index_result(resource_or_domain, opts) do
      {:ok, index} -> index
      {:error, :not_compiled} -> nil
      {:error, reason} -> raise ArgumentError, "capability release refused: #{inspect(reason)}"
    end
  end

  @spec released_capability_index_result(module(), keyword()) ::
          {:ok, [AshA2A.CapabilityIndex.skill()]} | {:error, term()}
  def released_capability_index_result(resource_or_domain, opts \\ []) do
    with {:ok, index} <- capability_index_result(resource_or_domain),
         {:ok, released} <- CapabilityRelease.filter_skills(index, opts) do
      {:ok, released}
    end
  end

  @doc """
  Whether `resource_or_domain` has explicitly opted into the semantic-
  compilation A2A surface (`a2a do semantic_requests true end`).

  This is real capability truth, not a runtime message-content sniff --
  false for any resource/domain that never declares it, `AshA2A.Agent`'s
  default-path dispatch never even inspects message content to decide this.
  """
  @spec semantic_requests_enabled?(module()) :: boolean()
  def semantic_requests_enabled?(resource_or_domain) do
    Extension.get_persisted(resource_or_domain, :ash_a2a_semantic_requests_enabled, false) ==
      true
  end
end
