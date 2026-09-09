defmodule AshA2A.Dispatcher do
  @moduledoc """
  Dispatches an inbound `A2A.Message.t()` to the real Ash action a persisted
  `AshA2A` skill maps to, and returns an `A2A.Agent` reply tuple.

  Per the ash_a2a PRD/ARD (`~/ggen-marketplace/docs/explanation/ash-a2a-prd-ard.md`
  §3.2, §3.5):

    * the skill is looked up in the persisted, verified capability index via
      `AshA2A.Info` — never by walking raw DSL entities directly, so dispatch
      can never diverge from the advertised `AgentCard` (PRD §3.2);
    * actor/tenant/context are resolved from the A2A message via
      `AshA2A.ContextResolver.from_a2a_message/2` — raw A2A metadata is never
      passed straight into an Ash call (PRD §3.5 trust-boundary requirement);
    * the real Ash action is invoked with the non-bang `{:ok, _} | {:error, _}`
      `Ash.Changeset.for_create/3` / `Ash.Query.for_read/3` /
      `Ash.ActionInput.for_action/3` APIs, per the PRD §3.5 deviation from
      `ash_ai`'s bang-then-rescue execution style
      (`~/xaas/deps/ash_ai/lib/ash_ai/tool/execution.ex:83-96`, which wraps
      `Ash.create!`/`Ash.bulk_update!`/`Ash.run_action!` in one outer
      `try/rescue/catch`) — this module builds the same `opts` shape
      (`~/xaas/deps/ash_ai/lib/ash_ai/tool/execution.ex:100-107`) but resolves
      each step through its non-bang counterpart instead.

  The reply shapes returned match `A2A.Agent`'s `reply()` type exactly
  (`~/xaas/deps/a2a/lib/a2a/agent.ex:160-164`):

      @type reply ::
              {:reply, [A2A.Part.t()]}
              | {:input_required, [A2A.Part.t()]}
              | {:stream, Enumerable.t()}
              | {:error, term()}

  `dispatch/3` never returns `{:stream, _}` (deferred to v1.1 per PRD §1.3/§3.7).
  """

  alias A2A.Message
  alias A2A.Part

  @type skill_name :: atom() | String.t()
  @type resource_or_domain :: module()

  @type reply ::
          {:reply, [Part.t()]}
          | {:input_required, [Part.t()]}
          | {:error, term()}

  @doc """
  Dispatches `a2a_message` to `skill_name` as declared on `resource_or_domain`.

  Looks the skill up in the persisted capability index (`AshA2A.Info`),
  resolves the Ash execution context from the message
  (`AshA2A.ContextResolver.from_a2a_message/2`), runs the real Ash action
  through the non-bang API matching the action's `type`, and maps the
  outcome to an `A2A.Agent` reply tuple.
  """
  @spec dispatch(skill_name(), Message.t(), resource_or_domain()) :: reply()
  def dispatch(skill_name, %Message{} = a2a_message, resource_or_domain) do
    with {:ok, skill} <- fetch_skill(resource_or_domain, skill_name),
         %AshA2A.ExecutionContext{} = exec_context <-
           AshA2A.ContextResolver.from_a2a_message(a2a_message, resource_or_domain),
         {:ok, input} <- fetch_input(a2a_message),
         {:ok, action} <- fetch_action(skill) do
      run_skill(skill, action, input, exec_context)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Skill lookup -----------------------------------------------------

  # Reads the skill from the persisted, verified capability index only
  # (`AshA2A.Info.agent_card/1`'s own source of truth, PRD §3.2) — never by
  # re-walking `Spark.Dsl.Extension.get_entities/2` directly, so a skill this
  # function can dispatch is guaranteed to be one the `AgentCard` advertises.
  defp fetch_skill(resource_or_domain, skill_name) do
    case AshA2A.Info.skill(resource_or_domain, to_skill_name(skill_name)) do
      {:ok, skill} -> {:ok, skill}
      :error -> {:error, {:unknown_skill, skill_name}}
      {:error, _} = error -> error
    end
  end

  defp to_skill_name(name) when is_atom(name), do: name
  defp to_skill_name(name) when is_binary(name), do: String.to_existing_atom(name)

  # -- Action resolution ---------------------------------------------------

  # The persisted capability-index skill (`AshA2A.CapabilityIndex.skill()`,
  # capability_index.ex:23-28; `AshA2A.Skill`, skill.ex:15-20) stores `action`
  # as a bare action-name atom, confirmed by `capability_index.ex:72,108`
  # passing it directly to `Ash.Resource.Info.action(resource, action)`. The
  # real `%Ash.Resource.Actions.*{}` struct (with `.type`/`.name`) must be
  # resolved from that atom before dispatch can branch on the action's type.
  defp fetch_action(%{resource: resource, action: action_name}) do
    case Ash.Resource.Info.action(resource, action_name) do
      nil -> {:error, {:unknown_action, resource, action_name}}
      %{} = action -> {:ok, action}
    end
  end

  # -- Input extraction ---------------------------------------------------

  # A2A carries the caller's structured arguments as a `A2A.Part.Data` part
  # (`~/xaas/deps/a2a/lib/a2a/part.ex:58-74`, `data: map()`). Text-only
  # messages (no data part) dispatch with an empty input map so actions that
  # accept no arguments still work.
  defp fetch_input(%Message{parts: parts}) do
    case Enum.find_value(parts, fn
           %Part.Data{data: data} -> {:ok, data}
           _ -> nil
         end) do
      {:ok, data} -> {:ok, data}
      nil -> {:ok, %{}}
    end
  end

  # -- Execution ------------------------------------------------------

  # `skill` is the persisted capability-index entry (PRD §3.2/§3.4): carries
  # `resource` and the bare action-name atom `action` (`AshA2A.Skill`,
  # skill.ex:15-20; `AshA2A.CapabilityIndex.skill()`, capability_index.ex:23-28)
  # -- there is no `:domain` field on this struct. `action` here is the real,
  # already-resolved `%Ash.Resource.Actions.*{}` struct (via `fetch_action/1`
  # -> `Ash.Resource.Info.action/2`), so `action.type`/`action.name` are
  # available exactly as ash_ai branches on them at
  # `~/xaas/deps/ash_ai/lib/ash_ai/tool/execution.ex:79`. `exec_context` is an
  # `%AshA2A.ExecutionContext{}` per PRD §3.5 carrying
  # `actor`/`tenant`/`context`/`domain` resolved from the message, with
  # `domain` being the `resource_or_domain` the dispatcher itself was called
  # with.
  defp run_skill(skill, action, input, exec_context) do
    opts = build_opts(exec_context)

    result =
      case action.type do
        :read -> run_read(skill, action, input, opts)
        :create -> run_create(skill, action, input, opts)
        :update -> run_update(skill, action, input, opts)
        :destroy -> run_destroy(skill, action, input, opts)
        :action -> run_generic(skill, action, input, opts)
      end

    to_reply(result)
  end

  # Same opts shape as `AshAi.Tool.Execution.build_opts/2`
  # (`~/xaas/deps/ash_ai/lib/ash_ai/tool/execution.ex:100-107`), sourced from
  # the resolved `AshA2A.ExecutionContext` rather than a raw context map.
  defp build_opts(%AshA2A.ExecutionContext{} = exec_context) do
    [
      domain: exec_context.domain,
      actor: exec_context.actor,
      tenant: exec_context.tenant,
      context: exec_context.context || %{}
    ]
  end

  defp run_read(skill, action, input, opts) do
    skill.resource
    |> Ash.Query.for_read(action.name, input, opts)
    |> Ash.read(opts)
  end

  defp run_create(skill, action, input, opts) do
    skill.resource
    |> Ash.Changeset.for_create(action.name, input, opts)
    |> Ash.create(opts)
  end

  defp run_update(skill, action, input, opts) do
    with {:ok, record} <- fetch_record_for_update(skill, input, opts) do
      record
      |> Ash.Changeset.for_update(action.name, input, opts)
      |> Ash.update(opts)
    end
  end

  defp fetch_record_for_update(skill, %{"id" => id}, opts) do
    Ash.get(skill.resource, id, opts)
  end

  defp fetch_record_for_update(skill, %{id: id}, opts) do
    Ash.get(skill.resource, id, opts)
  end

  defp fetch_record_for_update(_skill, _input, _opts) do
    {:error, {:missing_argument, :id}}
  end

  defp run_destroy(skill, action, input, opts) do
    with {:ok, record} <- fetch_record_for_update(skill, input, opts) do
      record
      |> Ash.Changeset.for_destroy(action.name, input, opts)
      |> Ash.destroy(opts)
    end
  end

  defp run_generic(skill, action, input, opts) do
    skill.resource
    |> Ash.ActionInput.for_action(action.name, input, opts)
    |> Ash.run_action(opts)
  end

  # -- Reply mapping -------------------------------------------------------

  # Maps every non-bang Ash outcome to the exact `A2A.Agent.reply()` shapes
  # (`~/xaas/deps/a2a/lib/a2a/agent.ex:160-164`). `{:input_required, _}` is
  # reserved for a caller-facing "you must supply more input" signal — an Ash
  # invalid/missing-argument error is the closest existing analogue (PRD §1.5
  # FR4), everything else Ash can fail with maps to `{:error, _}`.
  defp to_reply({:ok, result}) do
    {:reply, [Part.Data.new(encode_result(result))]}
  end

  defp to_reply(:ok) do
    {:reply, [Part.Data.new(%{})]}
  end

  defp to_reply({:error, {:missing_argument, _} = reason}) do
    {:input_required, [Part.Text.new(missing_argument_message(reason))]}
  end

  defp to_reply({:error, %{class: :invalid} = error}) do
    {:input_required, [Part.Text.new(Ash.Error.to_class(error) |> Exception.message())]}
  end

  defp to_reply({:error, %Ash.Error.Invalid{} = error}) do
    {:input_required, [Part.Text.new(Exception.message(error))]}
  end

  defp to_reply({:error, reason}) do
    {:error, reason}
  end

  defp missing_argument_message({:missing_argument, name}) do
    "missing required argument: #{name}"
  end

  defp encode_result(%_struct{} = record) do
    record
    |> Ash.Resource.Info.public_attributes()
    |> Enum.into(%{}, fn attr -> {attr.name, Map.get(record, attr.name)} end)
  end

  defp encode_result(list) when is_list(list) do
    Enum.map(list, &encode_result/1)
  end

  defp encode_result(other), do: other
end
