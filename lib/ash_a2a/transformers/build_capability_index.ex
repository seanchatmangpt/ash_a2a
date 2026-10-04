defmodule AshA2A.Transformers.BuildCapabilityIndex do
  @moduledoc """
  Persists only residual A2A skill overrides and the subject kind.

  Despite the historical module name, v26.9.12 no longer manufactures or
  persists a second capability model here. The real capability index is
  derived later from `Ash.Resource.Info.public_actions/1` by
  `AshA2A.CapabilityIndex.Compiler`.

  ## Consequence floor (SEC-04)

  An override may RAISE a mutating action's consequence (`:change` ->
  `:external_do`, or to the fail-closed `:unknown`) but may never LOWER a
  `:create`/`:update`/`:destroy` action to `consequence: :observe`. `:observe`
  skips `AshA2A.Authority.Grant`, `AshA2A.CommandBus` admission, receipts and
  the BRCE anchor, so lowering a mutating action to it would let a
  transport-authenticated caller mutate data with no authority and no
  receipt. Such a declaration is a compile-time `Spark.Error.DslError`
  (`:observe_on_mutating_action`, class `:refused_consequence`). `:read` and generic `:action`
  may be declared `:observe` (a generic action must opt in explicitly; its
  default stays `:unknown`).
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
      case resolve_and_check(override, dsl_state, module, resource_dsl?, own_domain) do
        {:ok, resolved} ->
          new_dsl =
            Transformer.replace_entity(dsl, [:a2a], resolved, &(&1.name == override.name))

          {:cont, {:ok, new_dsl, [resolved | overrides]}}

        {:error, message} ->
          {:halt,
           {:error,
            Spark.Error.DslError.exception(
              module: module,
              path: error_path(override, message),
              message: error_message(message),
              location: Spark.Dsl.Entity.anno(override)
            )}}
      end
    end)
    |> case do
      {:ok, dsl, overrides} ->
        semantic_requests? = Transformer.get_option(dsl, [:a2a], :semantic_requests, false)
        authority_gate = Transformer.get_option(dsl, [:authority], :gate, :two_port)
        lease_duration_ms = Transformer.get_option(dsl, [:authority], :lease_duration_ms, 60_000)
        pre_hooks = Transformer.get_option(dsl, [:hooks], :pre_dispatch, [])
        post_hooks = Transformer.get_option(dsl, [:hooks], :post_dispatch, [])

        dsl =
          dsl
          |> Transformer.persist(:ash_a2a_skill_overrides, Enum.reverse(overrides))
          |> Transformer.persist(:ash_a2a_subject_kind, subject_kind)
          |> Transformer.persist(:ash_a2a_semantic_requests_enabled, semantic_requests?)
          |> Transformer.persist(:ash_a2a_authority_gate, authority_gate)
          |> Transformer.persist(:ash_a2a_lease_duration_ms, lease_duration_ms)
          |> Transformer.persist(:ash_a2a_hooks, %{pre_dispatch: pre_hooks, post_dispatch: post_hooks})

        {:ok, dsl}

      {:error, error} ->
        {:error, error}
    end
  end

  @mutating_types [:create, :update, :destroy]

  @doc false
  def __sa2a_refusal_codes__, do: %{observe_on_mutating_action: :refused_consequence}

  defp resolve_and_check(override, dsl_state, module, resource_dsl?, own_domain) do
    with {:ok, resolved} <- resolve_resource(override, module, resource_dsl?, own_domain),
         :ok <- check_consequence_floor(resolved, dsl_state, resource_dsl?) do
      {:ok, resolved}
    end
  end

  defp error_path(override, {:consequence, _}), do: [:a2a, override.name, :consequence]
  defp error_path(override, _message), do: [:a2a, override.name, :resource]

  defp error_message({:consequence, message}), do: message
  defp error_message(message), do: message

  defp check_consequence_floor(%{consequence: :observe} = override, dsl_state, resource_dsl?) do
    case action_type(override, dsl_state, resource_dsl?) do
      type when type in @mutating_types ->
        {:error,
         {:consequence,
          "observe_on_mutating_action: skill `#{override.name}` declares " <>
            "`consequence: :observe` on #{inspect(type)} action `#{override.action}`. " <>
            "A mutating action may be raised to :external_do or :unknown but never " <>
            "lowered to :observe, which would skip authority, CommandBus admission, " <>
            "receipts and the BRCE anchor."}}

      _ ->
        :ok
    end
  end

  defp check_consequence_floor(_override, _dsl_state, _resource_dsl?), do: :ok

  # Resource-level: the resource is still compiling, so read its own
  # `actions` entities from `dsl_state`. `defaults [...]` actions may not be
  # materialized yet (Ash's SetPrimaryActions may run after this
  # transformer); a default action's name IS its type, so fall back to the
  # `defaults` option. Domain-level: the resource is already compiled.
  defp action_type(%{action: action}, dsl_state, true) do
    case Enum.find(Transformer.get_entities(dsl_state, [:actions]), &(&1.name == action)) do
      %{type: type} ->
        type

      nil ->
        defaults = Transformer.get_option(dsl_state, [:actions], :defaults, []) || []

        if Enum.any?(defaults, &default_named?(&1, action)), do: action, else: nil
    end
  end

  defp action_type(%{resource: resource, action: action}, _dsl_state, false) do
    case Ash.Resource.Info.action(resource, action) do
      %{type: type} -> type
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp default_named?(name, action) when is_atom(name), do: name == action
  defp default_named?({name, _accept}, action), do: name == action
  defp default_named?(_other, _action), do: false

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
