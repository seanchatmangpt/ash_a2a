defmodule AshA2A.Transformers.BuildCapabilityIndex do
  @moduledoc """
  Persists only residual A2A skill overrides and the subject kind.

  Despite the historical module name, v26.9.12 no longer manufactures or
  persists a second capability model here. The real capability index is
  derived later from `Ash.Resource.Info.public_actions/1` by
  `AshA2A.CapabilityIndex.Compiler`.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    resource_dsl? = resource_dsl?(module)
    own_domain = Transformer.get_persisted(dsl_state, :domain)
    subject_kind = if resource_dsl?, do: :resource, else: :domain

    dsl_state
    |> Transformer.get_entities([:a2a])
    |> Enum.reduce_while({:ok, dsl_state, []}, fn override, {:ok, dsl, overrides} ->
      case resolve_resource(override, module, resource_dsl?, own_domain) do
        {:ok, resolved} ->
          new_dsl =
            Transformer.replace_entity(dsl, [:a2a], resolved, &(&1.name == override.name))

          {:cont, {:ok, new_dsl, [resolved | overrides]}}

        {:error, message} ->
          {:halt,
           {:error,
            Spark.Error.DslError.exception(
              module: module,
              path: [:a2a, override.name, :resource],
              message: message,
              location: Spark.Dsl.Entity.anno(override)
            )}}
      end
    end)
    |> case do
      {:ok, dsl, overrides} ->
        semantic_requests? = Transformer.get_option(dsl, [:a2a], :semantic_requests, false)

        dsl =
          dsl
          |> Transformer.persist(:ash_a2a_skill_overrides, Enum.reverse(overrides))
          |> Transformer.persist(:ash_a2a_subject_kind, subject_kind)
          |> Transformer.persist(:ash_a2a_semantic_requests_enabled, semantic_requests?)

        {:ok, dsl}

      {:error, error} ->
        {:error, error}
    end
  end

  defp resolve_resource(%{resource: nil} = override, module, true, own_domain) do
    {:ok, %{override | resource: module, domain: own_domain}}
  end

  defp resolve_resource(%{resource: nil}, _module, false, _own_domain) do
    {:error,
     "domain-level skill overrides must declare a resource: `skill :name, Resource, :action`"}
  end

  defp resolve_resource(%{resource: resource} = override, _module, true, _own_domain)
       when not is_nil(resource) do
    {:error,
     "resource-level skill overrides cannot set `resource` (skill `#{override.name}` set it explicitly)"}
  end

  defp resolve_resource(%{resource: resource} = override, _module, _resource_dsl?, _own_domain) do
    {:ok, %{override | domain: Ash.Resource.Info.domain(resource)}}
  end

  defp resource_dsl?(module) do
    Module.get_attribute(module, :spark_is) == Ash.Resource
  end
end
