defmodule AshA2A.Transformers.BuildCapabilityIndex do
  @moduledoc """
  Fills in the implicit `resource` on resource-level `skill` entities, then
  persists the compiled capability index as a bare list of
  `AshA2A.CapabilityIndex.skill()` maps.

  Mirrors `AshAi.Transformers.ResourceTools`'s resource-detection/fill-in
  shape (`~/xaas/deps/ash_ai/lib/ash_ai/transformers/resource_tools.ex:9-45`)
  and `AshR2RML.Resource.Persist`'s single-persisted-key pattern
  (`~/ash_r2rml/lib/ash_r2rml/resource.ex:241,243`) -- per ash_a2a PRD/ARD
  §3.2, `AshA2A.Info.agent_card/1` reads only this persisted key, never raw
  DSL entities.

  This is the **sole** transformer that persists `:ash_a2a_capability_index`
  (a bare list -- the exact shape `AshA2A.CapabilityIndex.validate/1` and
  `AshA2A.Info.capability_index_result/1` require via their `is_list/1`
  guards). Structural errors (a skill declared with the wrong arity for its
  DSL context) are raised here at transform time, the same way
  `AshR2RML.Resource.Persist.compile_subject/3` raises a structural
  `Spark.Error.DslError` for a missing required subject map
  (`~/ash_r2rml/lib/ash_r2rml/resource.ex:246-248`). The real business
  checks -- unique skill names, every skill's action actually existing --
  are deliberately **not** duplicated here: they run exactly once, in
  `AshA2A.Verify` (a `Spark.Dsl.Verifier` that runs after this transformer
  and delegates to `AshA2A.CapabilityIndex.validate/1`), matching
  `AshR2RML.Resource.Verify` delegating to `AshR2RML.Mapping.validate/1`
  (`~/ash_r2rml/lib/ash_r2rml/resource.ex:492-511`). By verifier time every
  resource this index names is fully compiled, so `Ash.Resource.Info.action/2`
  can be called against the real module -- unlike at transform time, when the
  module currently compiling is not yet loaded.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def after?(_), do: true

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    resource_dsl? = resource_dsl?(module)

    # For a resource-level skill, `module` is the resource currently
    # mid-compile: `Ash.Resource.Info.domain/1` calls `module.persisted/1`,
    # which does not exist yet on a module that has not finished compiling
    # (confirmed empirically -- it returns `nil` there, not the real domain).
    # The same `:domain` value is already available directly off `dsl_state`
    # though, persisted by `use Ash.Resource, domain: ...` itself
    # (`~/deps/ash/lib/ash/resource.ex:153`, `@persist {:domain, domain}`) --
    # long before any transformer, including this one, runs. Read it from
    # there instead of round-tripping through the not-yet-compiled module.
    own_domain = Transformer.get_persisted(dsl_state, :domain)

    dsl_state
    |> Transformer.get_entities([:a2a])
    |> Enum.reduce({:ok, dsl_state, []}, fn skill, {:ok, dsl, skills} ->
      case resolve_resource(skill, module, resource_dsl?, own_domain) do
        {:ok, resolved} ->
          new_dsl =
            Transformer.replace_entity(dsl, [:a2a], resolved, &(&1.name == skill.name))

          {:ok, new_dsl, [resolved | skills]}

        {:error, message} ->
          {:error,
           Spark.Error.DslError.exception(
             module: module,
             path: [:a2a, skill.name, :resource],
             message: message
           )}
      end
    end)
    |> case do
      {:ok, dsl, skills} ->
        {:ok, Transformer.persist(dsl, :ash_a2a_capability_index, Enum.reverse(skills))}

      {:error, error} ->
        {:error, error}
    end
  end

  defp resolve_resource(%{resource: nil} = skill, module, true, own_domain) do
    {:ok, %{skill | resource: module, domain: own_domain}}
  end

  defp resolve_resource(%{resource: nil}, _module, false, _own_domain) do
    {:error, "domain-level skills must declare a resource: `skill :name, Resource, :action`"}
  end

  defp resolve_resource(%{resource: resource} = skill, _module, true, _own_domain)
       when not is_nil(resource) do
    {:error,
     "resource-level skills cannot set `resource` (skill `#{skill.name}` set it explicitly)"}
  end

  defp resolve_resource(%{resource: resource} = skill, _module, _resource_dsl?, _own_domain) do
    # `resource` here is a foreign, already-fully-compiled module (a
    # domain-level `skill :name, Resource, :action` names a resource other
    # than the module currently compiling), so `Ash.Resource.Info.domain/1`
    # is safe to call directly -- unlike `own_domain` above, there is no
    # mid-compile chicken-and-egg problem for a module that finished
    # compiling before the domain referencing it started compiling.
    {:ok, %{skill | domain: Ash.Resource.Info.domain(resource)}}
  end

  defp resource_dsl?(module) do
    Module.get_attribute(module, :spark_is) == Ash.Resource
  end
end
