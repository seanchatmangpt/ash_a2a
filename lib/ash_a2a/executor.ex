defmodule AshA2A.Executor do
  @moduledoc """
  Zach-Daniel-style ingress pipeline from a verified A2A transport call to a
  real, policy-authorized Ash action and a JSON-RPC-shaped result:

      verified auth identity → AshA2A.ExecutionContext → wire args →
      Ash.Changeset/Query/ActionInput → real Ash action →
      `AshA2A.ToA2AError` on failure

  Stage by stage:

    (a) **Context extraction** — the verified auth identity map (the exact
    shape stored at `conn.private[:a2a][:auth]` by `AshA2A.Protocol.Plug.Auth`
    and threaded as the `"a2a.auth"` metadata key by `AshA2A.Protocol.Plug`'s
    `call_opts/3`) is unwrapped to the bare identity and handed to
    `AshA2A.ContextResolver.from_a2a_message/4`, which builds the
    `AshA2A.ExecutionContext`. The identity is **never** read from
    `message.metadata` (PRD §3.5 trust boundary, see `AshA2A.ContextResolver`'s
    moduledoc). A `:tracer` claim on the identity map (atom key or string key)
    is threaded into the Ash `tracer:` opt; anything that is not a module
    atom is dropped.

    (b) **Argument coercion** — the `AshA2A.Protocol.Part.Data` payload is
    extracted with `AshA2A.Dispatcher.fetch_input/1` (reused, not duplicated)
    and the optional `argument_mapping` (string wire name → atom argument
    name, the same field `AshA2A.Skill.argument_mapping` carries from the
    compiled capability index) is applied as a pure key rename *before* the
    map reaches Ash. Type casting is never hand-rolled here: the renamed map
    is passed verbatim into `Ash.Changeset.for_create/for_update/for_destroy`,
    `Ash.Query.for_read`, or `Ash.ActionInput.for_action`, which cast and
    reject unknown/invalid inputs with the real Ash error structs that
    `AshA2A.ToA2AError` normalizes to `-32602`.

    (c) **Execution** — the real Ash action runs through the non-bang
    `{:ok, _} | {:error, _}` APIs (`Ash.read/2`, `Ash.create/2`,
    `Ash.update/2`, `Ash.destroy/2`, `Ash.run_action/2`), with
    `actor:`/`tenant:`/`tracer:`/`context:` opts sourced from the resolved
    execution context, so real Ash policies and multitenancy gate the run.

    (d) **Error normalization** — every failure is normalized through the
    `AshA2A.ToA2AError` protocol dispatch on the error's own struct/class:
    `NotFound` → -32001 (`TASK_NOT_FOUND`), `Forbidden`/policy denial → -32001 (`POLICY_FORBIDDEN`), validation →
    -32602, everything else → -32603 redacted under an opaque `ref`
    (`AshA2A.Transport.SafeError`). A `NotFound` nested inside an
    `Ash.Error.Invalid` class wrapper (the shape `Ash.get/3`'s not-found path
    produces for the update/destroy record fetch) is unwrapped and dispatched
    as the `NotFound` it is.

  ## Sole-DO fence (BRCE)

  `AshA2A.Dispatcher.dispatch/6` is documented as the one function that
  invokes a real Ash action for a skill, fenced by the sole-DO anchor
  (`AshA2A.BrceAnchor`, RFC-SA2A-001/002). This module is a second ingress
  and therefore crosses the same fence itself, reusing the identical public
  gate functions in the identical order — `BrceAnchor.take/0` first (single
  use, so a nested dispatch can never inherit an anchor), then
  `AshA2A.CapabilityRelease.guard/2`, `BrceAnchor.admit/2` (an anchored
  `:change`/`:external_do`/`:unknown` consequence skill without a durable
  `:pending` outbox anchor is refused `:brce_prepared_receipt_required`
  before any Ash call), and the W4 kernel fence
  (`AshA2A.ConsequenceKernel.W4.DispatcherFence.admitted?/0`) — so no
  consequence-bearing dispatch can enter Ash through this module without the
  same admission a `Dispatcher.dispatch/6` call needs.

  ## Skill verification

  The `AshA2A.Skill.t()` passed by the caller is untrusted input
  (RFC-SA2A-004 §11.4): it is admitted only when it is structurally identical
  to the compiled capability-index skill with the same `id`
  (`AshA2A.Info.capability_index/1`), else refused `:capability_mismatch`
  before the anchor is spent.

  ## Known seam

  `AshA2A.Dispatcher`'s private `run_read_stream/4` streaming path (PRD §3.7)
  and its telemetry spans are not duplicated here: this module has no
  `{:stream, _}` reply and no `[:ash_a2a, :dispatch]` telemetry. Callers who
  need either use `AshA2A.Dispatcher.dispatch/6`; this module exists for
  transports that want the JSON-RPC-shaped failure envelope directly.
  """

  alias AshA2A.{BrceAnchor, CapabilityRelease, ContextResolver, Dispatcher, MetadataKey}
  alias AshA2A.ConsequenceKernel.W4.DispatcherFence
  alias AshA2A.Protocol.JSONRPC.Request
  alias AshA2A.Protocol.{Message, Part}

  @type option ::
          {:auth_identity, map() | nil}
          | {:argument_mapping, %{optional(String.t()) => atom()}}
          | {:history, [Message.t()]}
          | {:domain, module()}
          | {:json_rpc_id, Request.id()}

  @type result ::
          {:ok, [Part.t()]}
          | {:error, map()}

  @doc """
  Executes the real Ash action behind `skill` for `message`.

  `skill` must be structurally identical to the compiled capability-index
  entry with the same `id` (`AshA2A.Info.capability_index/1`); anything else
  is refused `:capability_mismatch`. `opts`:

    * `:auth_identity` — the verified auth map in the `conn.private[:a2a][:auth]`
      shape (`%{identity: identity, ...}`) or a bare verified identity map;
      `nil` (the default) means unauthenticated — `actor`/`tenant` resolve to
      `nil` and fail closed. Never read from `message.metadata`.
    * `:argument_mapping` — string wire name → atom argument name; overrides
      the skill's own `argument_mapping` when present.
    * `:history` — prior-turn transcript threaded into the Ash context as
      `:a2a_history` (default `[]`).
    * `:domain` — domain override; defaults to the skill's persisted
      `domain`, then the resource's configured domain, then the resource
      itself.
    * `:json_rpc_id` — the JSON-RPC request id carried into the error
      envelope on failure (default `nil`).

  Returns `{:ok, parts}` with one `AshA2A.Protocol.Part.Data` part on
  success, or `{:error, envelope}` where `envelope` is the JSON-RPC 2.0
  error response map produced by `AshA2A.ToA2AError`.
  """
  @spec execute(AshA2A.Skill.t(), Message.t(), [option()]) :: result()
  def execute(%AshA2A.Skill{} = skill, %Message{} = message, opts \\ [])
      when is_list(opts) do
    # Single-use anchor take comes first, exactly as in
    # `AshA2A.Dispatcher.do_dispatch/6`: a nested or later dispatch in this
    # process must never inherit a prepared anchor.
    anchor = BrceAnchor.take()

    id = Keyword.get(opts, :json_rpc_id)

    with {:ok, skill} <- resolve_skill(skill),
         :ok <- CapabilityRelease.guard(skill.id, opts),
         {:ok, admitted_anchor} <- BrceAnchor.admit(skill, anchor),
         :ok <- kernel_fence(admitted_anchor),
         :ok = BrceAnchor.actuating(skill, admitted_anchor),
         {:ok, action} <- resolve_action(skill),
         {:ok, exec_context} <- extract_context(message, skill, opts),
         {:ok, args} <- coerce_arguments(skill, message, opts) do
      run_action(skill, action, args, exec_context, opts)
      |> normalize(id)
    else
      {:error, reason} -> {:error, AshA2A.ToA2AError.to_a2a_error(reason, id)}
    end
  end

  # -- Sole-DO fence -------------------------------------------------------

  # Same admission semantics as the dispatcher's: a `nil` anchor is fine for
  # an `:observe` skill (admit/2 returns {:ok, nil}); every consequence-bearing
  # skill needs a durable pending anchor bound to this exact capability.
  defp kernel_fence(nil), do: :ok

  defp kernel_fence(_anchor) do
    if DispatcherFence.admitted?(), do: :ok, else: {:error, :consequence_kernel_required}
  end

  # -- Skill verification (caller-supplied skill is untrusted) -------------

  defp resolve_skill(%AshA2A.Skill{id: id} = skill) do
    indexed =
      skill.resource
      |> AshA2A.Info.capability_index()
      |> List.wrap()
      |> Enum.find(&(&1.id == id))

    if indexed == skill, do: {:ok, skill}, else: {:error, capability_mismatch(id)}
  end

  defp capability_mismatch(id) do
    %{
      code: :capability_mismatch,
      reason: :resolved_skill_not_in_index,
      capability_id: id,
      detail:
        "caller-supplied skill is not structurally identical to the compiled " <>
          "capability-index skill"
    }
  end

  # -- (a) context extraction ----------------------------------------------

  defp extract_context(message, skill, opts) do
    identity = verified_identity(Keyword.get(opts, :auth_identity))
    history = Keyword.get(opts, :history, [])
    {:ok, ContextResolver.from_a2a_message(message, domain(skill, opts), history, identity)}
  end

  defp domain(skill, opts) do
    skill.domain || Keyword.get(opts, :domain) ||
      Ash.Resource.Info.domain(skill.resource) || skill.resource
  end

  # Accepts the `conn.private[:a2a][:auth]` map shape (`%{identity: ...}`,
  # populated only by real credential verification in
  # `AshA2A.Protocol.Plug.Auth`) or a bare verified identity map; anything
  # else fails closed to `nil` (unauthenticated).
  defp verified_identity(nil), do: nil
  defp verified_identity(%{identity: identity}), do: identity

  defp verified_identity(identity) when is_map(identity), do: identity
  defp verified_identity(_other), do: nil

  defp tracer(nil), do: nil

  defp tracer(identity) when is_map(identity) do
    case MetadataKey.fetch(identity, :tracer) do
      {:ok, tracer} when is_atom(tracer) -> tracer
      _other -> nil
    end
  end

  # Same opts shape as `AshA2A.Dispatcher.build_opts/2`, plus `tracer:`.
  defp ash_opts(%AshA2A.ExecutionContext{} = exec_context, identity) do
    base = [
      domain: exec_context.domain,
      actor: exec_context.actor,
      tenant: exec_context.tenant,
      # ExecutionContext types `context` as `map()` and `history` as a list
      # (both default non-nil), so the old `|| %{} / || []` fallbacks were dead.
      context: Map.put(exec_context.context, :a2a_history, exec_context.history)
    ]

    case tracer(identity) do
      nil -> base
      tracer -> Keyword.put(base, :tracer, tracer)
    end
  end

  # -- (b) argument coercion -------------------------------------------------

  # Input extraction is `AshA2A.Dispatcher.fetch_input/1` verbatim (the first
  # `Part.Data` payload, `%{}` for a text-only message). The optional
  # mapping renames string wire keys to atom argument keys; it never creates
  # atoms from wire input (the atom side comes from compiled skill config).
  defp coerce_arguments(skill, message, opts) do
    {:ok, input} = Dispatcher.fetch_input(message)
    mapping = Keyword.get(opts, :argument_mapping) || skill.argument_mapping || %{}
    {:ok, apply_argument_mapping(input, mapping)}
  end

  defp apply_argument_mapping(input, mapping) when mapping == %{}, do: input

  defp apply_argument_mapping(input, mapping) when is_map(input) do
    Enum.reduce(mapping, input, fn {wire, argument}, acc ->
      case Map.pop(acc, wire) do
        {nil, _acc} -> acc
        {value, rest} -> Map.put(rest, argument, value)
      end
    end)
  end

  # (the old non-map `apply_argument_mapping/2` catch-all was dead: every
  # caller passes a map `input`, the two live clauses cover the full type)

  # -- (c) execution ---------------------------------------------------------

  defp resolve_action(%{resource: resource, action: action_name}) do
    case Ash.Resource.Info.action(resource, action_name) do
      nil -> {:error, {:unknown_action, resource, action_name}}
      %{} = action -> {:ok, action}
    end
  end

  defp run_action(skill, action, args, exec_context, opts) do
    identity = verified_identity(Keyword.get(opts, :auth_identity))
    ash_opts = ash_opts(exec_context, identity)

    case action.type do
      :read -> run_read(skill, action, args, ash_opts)
      :create -> run_create(skill, action, args, ash_opts)
      :update -> run_update(skill, action, args, ash_opts)
      :destroy -> run_destroy(skill, action, args, ash_opts)
      :action -> run_generic(skill, action, args, ash_opts)
    end
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
    with {:ok, record} <- fetch_record(skill, input, opts) do
      pk = Ash.Resource.Info.primary_key(skill.resource)

      record
      |> Ash.Changeset.for_update(action.name, drop_primary_key_fields(input, pk), opts)
      |> Ash.update(opts)
    end
  end

  defp run_destroy(skill, action, input, opts) do
    with {:ok, record} <- fetch_record(skill, input, opts) do
      # A hard `:destroy` action's accept list is forced to `[]` by Ash's
      # `DefaultAccept` transformer, so the identity input used to resolve the
      # record is passed as `%{}` to `for_destroy` — same carve-out as
      # `AshA2A.Dispatcher.run_destroy/4`.
      record
      |> Ash.Changeset.for_destroy(action.name, %{}, opts)
      |> Ash.destroy(opts)
    end
  end

  defp run_generic(skill, action, input, opts) do
    skill.resource
    |> Ash.ActionInput.for_action(action.name, input, opts)
    |> Ash.run_action(opts)
  end

  # Resolves the record an update/destroy acts on by the resource's real
  # primary key (single field of any name, or composite as a map), accepting
  # atom- or string-keyed input, exactly like `AshA2A.Dispatcher`'s record
  # fetch.
  defp fetch_record(skill, input, opts) do
    pk = Ash.Resource.Info.primary_key(skill.resource)

    case primary_key_values(pk, input) do
      {:ok, id_or_composite} -> Ash.get(skill.resource, id_or_composite, opts)
      :error -> {:error, {:missing_argument, missing_argument_name(pk)}}
    end
  end

  defp primary_key_values([field], input) when is_atom(field) do
    MetadataKey.fetch(input, field)
  end

  defp primary_key_values(fields, input) when is_list(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case MetadataKey.fetch(input, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp drop_primary_key_fields(input, pk) when is_map(input) do
    Enum.reduce(pk, input, fn field, acc ->
      acc |> Map.delete(field) |> Map.delete(Atom.to_string(field))
    end)
  end

  defp missing_argument_name([field]), do: field
  defp missing_argument_name(fields), do: fields

  # -- (d) result / error normalization ---------------------------------------

  defp normalize({:ok, result}, _id), do: {:ok, [Part.Data.new(wrap(encode_result(result)))]}
  defp normalize(:ok, _id), do: {:ok, [Part.Data.new(%{})]}

  # Missing primary-key identity for an update/destroy is a caller-input
  # defect (the caller can fix it by naming the record), so it gets -32602
  # rather than the -32603 fallback.
  defp normalize({:error, {:missing_argument, names}}, id) do
    {:error, missing_argument_envelope(names, id)}
  end

  # A `NotFound` nested inside an `Ash.Error.Invalid` class wrapper (the
  # shape `Ash.get/3`'s not-found path produces) is dispatched as the
  # `NotFound` it is (-32001, TASK_NOT_FOUND per the v1.0 registry), not the wrapper's class (-32602).
  defp normalize({:error, reason}, id) do
    case find_not_found(reason) do
      %Ash.Error.Query.NotFound{} = not_found ->
        {:error, AshA2A.ToA2AError.to_a2a_error(not_found, id)}

      nil ->
        {:error, AshA2A.ToA2AError.to_a2a_error(reason, id)}
    end
  end

  defp find_not_found(%Ash.Error.Query.NotFound{} = error), do: error

  defp find_not_found(%{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &find_not_found/1)
  end

  defp find_not_found(_other), do: nil

  defp missing_argument_envelope(name, id) when is_atom(name) do
    AshA2A.ToA2AError.Wire.envelope(
      id,
      -32_602,
      "Invalid parameters",
      "missing required argument: #{name}"
    )
  end

  defp missing_argument_envelope(names, id) when is_list(names) do
    AshA2A.ToA2AError.Wire.envelope(
      id,
      -32_602,
      "Invalid parameters",
      "missing required argument(s): #{Enum.map_join(names, ", ", &to_string/1)}"
    )
  end

  defp wrap(%{} = map), do: map
  defp wrap(list) when is_list(list), do: %{results: list}
  defp wrap(other), do: %{result: other}

  defp encode_result(%_struct{} = record) do
    record
    |> Ash.Resource.Info.public_attributes()
    |> Enum.into(%{}, fn attr -> {attr.name, Map.get(record, attr.name)} end)
  end

  defp encode_result(list) when is_list(list), do: Enum.map(list, &encode_result/1)
  defp encode_result(other), do: other
end
