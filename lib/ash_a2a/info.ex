defmodule AshA2A.Info do
  @moduledoc """
  Introspection for the `AshA2A` extension. Per ash_a2a PRD/ARD §3.2, every
  function here reads the persisted, verified `:ash_a2a_capability_index`
  only -- never `Spark.Dsl.Extension.get_entities/2` on `:a2a` directly --
  so the advertised `AgentCard` and dispatch table can never diverge.

  The 4-form introspection API (`capability_index/1`, `capability_index_result/1`,
  `capability_index!/1`, `capability_index?/1`) mirrors `ash_r2rml`'s hybrid Info
  API precedent verbatim (`~/ash_r2rml/lib/ash_r2rml/resource.ex:514-545`,
  `AshR2RML.Resource.Info.mapping/1` / `mapping_result/1` / `mapping!/1` /
  `mapped?/1`): a nil-returning convenience form, a `{:ok, _} | {:error, _}`
  result form, a bang form that raises `ArgumentError` on failure, and a
  boolean predicate -- all delegating to the same single `_result/1` source of
  truth rather than duplicating the persisted-key read four times.
  """

  alias Spark.Dsl.Extension

  @typedoc "Why `capability_index_result/1` failed to return a compiled index."
  @type not_compiled :: :not_compiled

  @doc """
  Returns the compiled, persisted capability index (a list of
  `AshA2A.CapabilityIndex.skill()`-shaped skills), or `nil` if
  `resource_or_domain` has no compiled `AshA2A` capability index.

  ## Examples

      iex> [%AshA2A.Skill{name: name, action: action}] =
      ...>   AshA2A.Info.capability_index(AshA2A.Test.Fixture.Echo)
      iex> {name, action}
      {:echo, :read}

      iex> AshA2A.Info.capability_index(AshA2A.Test.Fixture.NoA2A)
      nil

  """
  @spec capability_index(module()) :: [AshA2A.CapabilityIndex.skill()] | nil
  def capability_index(resource_or_domain) do
    case capability_index_result(resource_or_domain) do
      {:ok, index} -> index
      {:error, :not_compiled} -> nil
    end
  end

  @doc """
  Returns the compiled, persisted capability index as `{:ok, index}`, or
  `{:error, :not_compiled}` when `resource_or_domain` has no persisted
  `:ash_a2a_capability_index` -- e.g. the `AshA2A` extension was never added,
  or the module has not finished compiling.

  ## Examples

      iex> {:ok, [%AshA2A.Skill{name: name}]} =
      ...>   AshA2A.Info.capability_index_result(AshA2A.Test.Fixture.Echo)
      iex> name
      :echo

      iex> AshA2A.Info.capability_index_result(AshA2A.Test.Fixture.NoA2A)
      {:error, :not_compiled}

  """
  @spec capability_index_result(module()) ::
          {:ok, [AshA2A.CapabilityIndex.skill()]} | {:error, not_compiled()}
  def capability_index_result(resource_or_domain) do
    case Extension.get_persisted(resource_or_domain, :ash_a2a_capability_index, nil) do
      nil -> {:error, :not_compiled}
      index when is_list(index) -> {:ok, index}
    end
  end

  @doc """
  Same as `capability_index/1`, but raises `ArgumentError` instead of
  returning `nil` when `resource_or_domain` has no compiled capability index.

  ## Examples

      iex> [%AshA2A.Skill{name: name}] =
      ...>   AshA2A.Info.capability_index!(AshA2A.Test.Fixture.Echo)
      iex> name
      :echo

      iex> AshA2A.Info.capability_index!(AshA2A.Test.Fixture.NoA2A)
      ** (ArgumentError) AshA2A.Test.Fixture.NoA2A has no compiled AshA2A capability index -- add `use AshA2A`/the `AshA2A` extension and ensure the module has compiled

  """
  @spec capability_index!(module()) :: [AshA2A.CapabilityIndex.skill()]
  def capability_index!(resource_or_domain) do
    case capability_index_result(resource_or_domain) do
      {:ok, index} ->
        index

      {:error, :not_compiled} ->
        raise ArgumentError,
              "#{inspect(resource_or_domain)} has no compiled AshA2A capability index -- " <>
                "add `use AshA2A`/the `AshA2A` extension and ensure the module has compiled"
    end
  end

  @doc """
  True if `resource_or_domain` has a compiled, verified `AshA2A` capability
  index (even an empty one).

  ## Examples

      iex> AshA2A.Info.capability_index?(AshA2A.Test.Fixture.Echo)
      true

      iex> AshA2A.Info.capability_index?(AshA2A.Test.Fixture.Domain)
      true

      iex> AshA2A.Info.capability_index?(AshA2A.Test.Fixture.NoA2A)
      false

  """
  @spec capability_index?(module()) :: boolean()
  def capability_index?(resource_or_domain) do
    match?({:ok, _}, capability_index_result(resource_or_domain))
  end

  @doc """
  Looks up one skill by name in the persisted capability index.

  ## Examples

      iex> {:ok, %AshA2A.Skill{name: name, action: action}} =
      ...>   AshA2A.Info.skill(AshA2A.Test.Fixture.Echo, :echo)
      iex> {name, action}
      {:echo, :read}

      iex> AshA2A.Info.skill(AshA2A.Test.Fixture.Echo, :no_such_skill)
      {:error, :skill_not_found}

  """
  @spec skill(module(), atom()) ::
          {:ok, AshA2A.CapabilityIndex.skill()} | {:error, :skill_not_found}
  def skill(resource_or_domain, name) do
    resource_or_domain
    |> capability_index()
    |> List.wrap()
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> {:error, :skill_not_found}
      skill -> {:ok, skill}
    end
  end

  @doc """
  Builds a real `A2A.AgentCard.t()` from `resource_or_domain`'s persisted
  capability index, delegating to `AshA2A.CapabilityIndex.build_agent_card/2`
  (ash_a2a PRD/ARD §3.2/FR3).

  ## Examples

      iex> card = AshA2A.Info.agent_card(AshA2A.Test.Fixture.Echo, name: "echo_agent")
      iex> {card.name, length(card.skills)}
      {"echo_agent", 1}

      iex> card = AshA2A.Info.agent_card(AshA2A.Test.Fixture.Domain)
      iex> card.skills
      []

  """
  @spec agent_card(module(), keyword()) :: A2A.AgentCard.t()
  def agent_card(resource_or_domain, opts \\ []) do
    resource_or_domain
    |> capability_index()
    |> List.wrap()
    |> AshA2A.CapabilityIndex.build_agent_card(opts)
  end
end
