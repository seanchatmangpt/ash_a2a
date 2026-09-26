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
      `AshA2A.ContextResolver.from_a2a_message/4` — raw A2A metadata is never
      passed straight into an Ash call (PRD §3.5 trust-boundary requirement).
      `actor`/`tenant` specifically come from the transport-verified
      `auth_identity` argument threaded through `dispatch/5` (sourced by
      `AshA2A.Agent.__dispatch__` from `context.metadata["a2a.auth"][:identity]`,
      the field `A2A.Plug.Auth` populates only after real credential
      verification, `~/xaas/deps/a2a/lib/a2a/plug/auth.ex:6-16,175-176,226-242`
      and `~/xaas/deps/a2a/lib/a2a/plug.ex:159`) — **never** from
      `a2a_message.metadata`, which is unauthenticated wire input a remote
      caller fully controls (see `AshA2A.ContextResolver`'s moduledoc for the
      full trust-boundary writeup);
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

  ## Streaming `:read` skills (PRD §3.7)

  `run_read/4` returns `{:stream, Enumerable.t()}` instead of fully
  materializing the result set whenever the caller explicitly opts in with
  `"stream" => true` (or `%{stream: true}`) in the inbound `A2A.Part.Data`
  input map. This is deliberately a per-call caller choice, not a static
  property of the action: every default Ash `:read` action already carries a
  non-nil `%Ash.Resource.Actions.Read.Pagination{keyset?: true, offset?: true}`
  struct even with no `pagination do ... end` declared (confirmed against the
  real compiled `AshA2A.Test.Fixture.Echo` fixture's plain `defaults([:read])`
  action, `~/xaas/deps/ash/lib/ash/resource/actions/read.ex:168-186`), so
  branching on `action.pagination` alone cannot distinguish "this call wants
  streaming" from "this is an ordinary Ash read action" -- virtually every
  real `:read` action would match. The `stream` key is popped out of the
  input map before it reaches `Ash.Query.for_read/3` (it is a dispatch
  directive, not a real action argument).

  When streaming is requested, the query is driven through the real
  `Ash.stream!/2` API (`~/xaas/deps/ash/lib/ash.ex:2964`, the only public
  streaming entry point — there is no non-bang `Ash.stream/2`) instead of
  `Ash.read/2`, letting `Ash.stream!/2` pick its own best strategy (`:keyset`
  first, `:offset` or `:full_read` only if the action allows a worse one --
  this module passes `allow_stream_with: :full_read` so any read action can
  stream regardless of which pagination strategies it declares). Omitting the
  `stream` flag (the default) keeps calling `Ash.read/2` and returning
  `{:reply, _}` exactly as before this change.

  Because `Ash.stream!/2` is a bang API returning a lazy `Enumerable.t()`, any
  error raised while *building* the stream (an invalid query, a bad
  pagination option) is caught here and mapped to `{:error, _}` so `dispatch/5`
  stays fail-closed for that eager part of the call, matching this module's
  non-bang convention elsewhere. An error raised while the *caller* drains the
  returned stream (a query execution failure surfacing lazily on a later
  page) is not, and cannot be, intercepted here — the same limitation
  `A2A.Agent.Runtime.wrap_stream/3`
  (`~/xaas/deps/a2a/lib/a2a/agent/runtime.ex:51-61`) has: it observes emitted
  parts to finalize the task, it does not wrap enumeration in a rescue
  either.
  """

  alias A2A.Message
  alias A2A.Part

  @type skill_name :: atom() | String.t()
  @type resource_or_domain :: module()

  @type reply ::
          {:reply, [Part.t()]}
          | {:input_required, [Part.t()]}
          | {:stream, Enumerable.t()}
          | {:error, term()}

  @doc """
  Dispatches `a2a_message` to `skill_name` as declared on `resource_or_domain`.

  Looks the skill up in the persisted capability index (`AshA2A.Info`),
  resolves the Ash execution context from the message
  (`AshA2A.ContextResolver.from_a2a_message/4`), runs the real Ash action
  through the non-bang API matching the action's `type`, and maps the
  outcome to an `A2A.Agent` reply tuple.

  `history` is the prior-turn transcript from the caller's `A2A.Agent` task
  context (`A2A.Agent.context().history`,
  `~/xaas/deps/a2a/lib/a2a/agent.ex:130-135`) -- `[]` for a fresh task, the
  accumulated multi-turn history for a continued (`task_id:`) one. It is
  threaded into the resolved `AshA2A.ExecutionContext` and, from there, into
  the Ash `context:` opt as `:a2a_history` (`build_opts/2`), so a resource
  action can read prior turns via `changeset.context[:a2a_history]` /
  `query.context[:a2a_history]` / `input.context[:a2a_history]` -- it is
  never discarded.

  `auth_identity` is the transport-verified caller identity -- **never**
  anything read from `a2a_message.metadata`, which is unauthenticated wire
  input a remote caller fully controls end to end (PRD §3.5 trust boundary,
  see `AshA2A.ContextResolver`'s moduledoc). It defaults to `nil`
  (unauthenticated: both `actor` and `tenant` resolve to `nil`), so a caller
  that hasn't wired `A2A.Plug.Auth` -- or a direct unit-test call to this
  function -- fails closed instead of silently trusting the message. A
  correctly-wired `AshA2A.Agent`-generated agent sources this argument from
  `context.metadata["a2a.auth"][:identity]` for every real dispatch (see
  `AshA2A.Agent.__dispatch__`).
  """
  @spec dispatch(
          skill_name(),
          Message.t(),
          resource_or_domain(),
          [Message.t()],
          term(),
          keyword()
        ) :: reply()
  def dispatch(
        skill_name,
        %Message{} = a2a_message,
        resource_or_domain,
        history \\ [],
        auth_identity \\ nil,
        opts \\ []
      )
      when is_list(history) and is_list(opts) do
    start_meta = %{resource_or_domain: resource_or_domain, skill_name: skill_name}

    :telemetry.span([:ash_a2a, :dispatch], start_meta, fn ->
      {reply, object_id} =
        do_dispatch(skill_name, a2a_message, resource_or_domain, history, auth_identity, opts)

      stop = start_meta |> Map.merge(stop_meta(reply)) |> maybe_put_object_id(object_id)
      {reply, stop}
    end)
  end

  # `object_id`, when non-nil, is the real identity of the specific resource
  # instance (or, for a generic `:action` skill with no data-layer record at
  # all, the specific stateful non-Ash instance -- e.g. the FreedomGym
  # `AshA2A.Test.Fixture.FreedomGym.MeetingPlan` phase-tracking plan named by
  # a `plan_name` argument) the dispatch actually acted on. It threads
  # through to `AshA2A.Telemetry.OcelForwarder`'s `[:ash_a2a, :dispatch,
  # :stop]` handler as `metadata.object_id`, letting the forwarder emit a
  # real non-empty OCEL v2 `relationships` entry instead of every forwarded
  # event being relationship-less. `nil` (no real identity available for
  # this dispatch) means the forwarder emits `relationships: []`, never a
  # fabricated id.
  defp maybe_put_object_id(meta, nil), do: meta

  defp maybe_put_object_id(meta, object_id) when is_binary(object_id) do
    Map.put(meta, :object_id, object_id)
  end

  # Sole-DO fence (RFC-SA2A-002 §38/§68, `AshA2A.BrceAnchor`): the prepared
  # receipt anchor is taken first (single use), and a consequence-bearing
  # skill is refused before its Ash action runs unless `AshA2A.CommandBus`
  # handed over a pending anchor bound to this exact capability.
  defp do_dispatch(skill_name, a2a_message, resource_or_domain, history, auth_identity, opts) do
    anchor = AshA2A.BrceAnchor.take()

    with {:ok, skill} <-
           tag_stage(resolve_skill(resource_or_domain, skill_name, opts), :skill_lookup),
         :ok <-
           tag_stage(AshA2A.CapabilityRelease.guard(skill.id, opts), :release_gate),
         %AshA2A.ExecutionContext{} = exec_context <-
           AshA2A.ContextResolver.from_a2a_message(
             a2a_message,
             resource_or_domain,
             history,
             auth_identity
           ),
         {:ok, input} <- fetch_input(a2a_message),
         {:ok, action} <- tag_stage(fetch_action(skill), :action_resolution),
         {:ok, admitted_anchor} <-
           tag_stage(AshA2A.BrceAnchor.admit(skill, anchor), :brce_gate) do
      :ok = AshA2A.BrceAnchor.actuating(skill, admitted_anchor)
      {reply, object_id} = run_skill(skill, action, input, exec_context)
      {tag_stage(reply, :execution), object_id}
    else
      {:error, _reason} = error -> {error, nil}
    end
  end

  # `fetch_skill/2` and `fetch_action/1` already return `{:ok, _} | {:error, reason}`;
  # this only annotates which pipeline stage an `{:error, reason}` came from,
  # as `{:error, {stage, reason}}`, so `stop_meta/1` can surface it in the
  # `[:ash_a2a, :dispatch, :stop]` telemetry event without changing the
  # reason term any existing caller pattern-matches on.
  #
  # Also doubles as the stage-tagger for `run_skill/4`'s result: that
  # function returns an `A2A.Agent.reply()` tuple rather than
  # `{:ok, _} | {:error, _}`, but its `{:error, _}` shape matches the same
  # clause here, while `{:reply, _}`/`{:input_required, _}`/`{:stream, _}`
  # fall through to the catch-all below and pass through unchanged as the
  # final dispatch result.
  defp tag_stage({:ok, _} = ok, _stage), do: ok
  defp tag_stage({:error, reason}, stage), do: {:error, {stage, reason}}
  defp tag_stage(reply, _stage), do: reply

  defp stop_meta({:reply, _}), do: %{reply_type: :reply}
  defp stop_meta({:input_required, _}), do: %{reply_type: :input_required}
  defp stop_meta({:stream, _}), do: %{reply_type: :stream}

  defp stop_meta({:error, {stage, reason}})
       when stage in [:skill_lookup, :release_gate, :action_resolution, :brce_gate, :execution] do
    %{stage: stage, error: reason}
  end

  defp stop_meta({:error, reason}), do: %{stage: :execution, error: reason}

  # -- Skill lookup -----------------------------------------------------

  # Reads the skill from the persisted, verified capability index only
  # (`AshA2A.Info.agent_card/1`'s own source of truth, PRD §3.2) — never by
  # re-walking `Spark.Dsl.Extension.get_entities/2` directly, so a skill this
  # function can dispatch is guaranteed to be one the `AgentCard` advertises.
  #
  # Matches directly against the real compiled capability index rather than
  # converting `skill_name` to an atom first (`String.to_existing_atom/1`,
  # the prior approach): that conversion is fail-*open* to a real production
  # bug, not just theoretically -- `String.to_existing_atom/1` only succeeds
  # if some OTHER, unrelated code path has already interned that exact atom
  # somewhere in the running VM (e.g. a compile-time literal in some other
  # module, or a prior in-process atom-typed dispatch call). A skill name
  # that arrives as a string (the only real shape a remote A2A/JSON caller
  # can ever send -- JSON has no atoms) can therefore raise `ArgumentError`
  # nondeterministically, depending entirely on incidental VM atom-table
  # state, for a real, valid, currently-compiled skill. Reproduced for real:
  # a caller with an unqualified `metadata["skill"]` string naming a real
  # skill on a resource with 2+ skills (so default-skill-selection can't
  # apply) failed with `{:unknown_skill, _}` even though the skill was real
  # and currently compiled -- confirmed via `AshA2A.Info.skill/2` succeeding
  # for the identical atom moments later once something else happened to
  # intern it. Matching against `capability_index/1`'s real, already-loaded
  # skill list needs no atom conversion at all.
  # Matches on either the skill's canonical A2A wire `id`
  # (`AshA2A.CapabilityIndex.Compiler.capability_id/2`'s stable
  # `"#{inspect(resource)}.#{action}"` form -- the identifier
  # `~/xaas/deps/a2a/lib/a2a/agent_card.ex:16-21` documents as the real,
  # canonical per-skill wire identifier) or its residual display `name`, the
  # same two-field match `AshA2A.Info.skill/2` already performs
  # (`info.ex:65-68`). Before this fix, this function matched only `.name`,
  # so a spec-faithful caller selecting a `:read`/`:observe` skill by its
  # real `id` (rather than its display `name`) was refused with
  # `{:unknown_skill, _}` on this direct-dispatch path even though the
  # identical selector would have resolved correctly via `CommandBus.run/4`'s
  # `:change`/`:external_do` route (which calls `AshA2A.Info.skill/2`
  # directly) -- a real selector-matching inconsistency between the two
  # canonical lookup paths, not a security issue (it only ever fails closed,
  # never admits something it shouldn't), but a real usability/consistency
  # bug this fixes.
  # b4p-f5-10: `AshA2A.CommandBus` re-dispatches a consequence-bearing skill
  # it has ALREADY resolved (`inspect_target/2` -> `AshA2A.Info.skill/2`).
  # Re-matching that skill by bare display `name` here would index-first-match
  # a different resource's namesake on a multi-resource domain (every public
  # action is a skill, so `create` x N resources is the default surface) and
  # `AshA2A.BrceAnchor.admit/2` would then refuse the exact-skill anchor with
  # `:capability_mismatch`. The opt carries the exact resolved skill; the
  # selector-based lookup below stays authoritative for every other caller.
  defp resolve_skill(resource_or_domain, skill_name, opts) do
    case Keyword.get(opts, :resolved_skill) do
      %AshA2A.Skill{} = skill -> {:ok, skill}
      _ -> fetch_skill(resource_or_domain, skill_name)
    end
  end

  # An exact capability-id match is authoritative even when the display name
  # is shared across resources; a selector matching more than one skill is
  # refused typed (`{:ambiguous_skill, selector}`) instead of silently
  # resolving to the index-first namesake.
  defp fetch_skill(resource_or_domain, skill_name) do
    skills =
      resource_or_domain
      |> AshA2A.Info.capability_index()
      |> List.wrap()

    case Enum.filter(skills, &(&1.id == skill_name or skill_name_matches?(&1.name, skill_name))) do
      [] ->
        {:error, {:unknown_skill, skill_name}}

      [skill] ->
        {:ok, skill}

      matches ->
        case Enum.filter(matches, &(&1.id == skill_name)) do
          [skill] -> {:ok, skill}
          _ -> {:error, {:ambiguous_skill, skill_name}}
        end
    end
  end

  # `skill_name` originates from `AshA2A.Agent.resolve_skill_name/2`, which
  # reads it out of an unauthenticated, unschema'd remote-caller-controlled
  # `A2A.Message.metadata` map with no type check -- match the real compiled
  # atom directly, or its string form for the real over-the-wire shape, and
  # fail closed for anything else (integer, list, map, etc.) rather than
  # ever raising.
  defp skill_name_matches?(name, name) when is_atom(name), do: true

  defp skill_name_matches?(name, string) when is_atom(name) and is_binary(string) do
    Atom.to_string(name) == string
  end

  defp skill_name_matches?(_name, _other), do: false

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
  #
  # Public (not `defp`) so `AshA2A.Agent.__dispatch__` can extract the same
  # real input to carry as `AshA2A.Command.input` for fingerprinting when it
  # routes a dispatch through `AshA2A.CommandBus.run/4` -- reusing this exact
  # extraction keeps the command's fingerprinted input identical to what the
  # action actually receives, rather than duplicating this logic or passing
  # an empty placeholder that would collapse distinct requests onto the same
  # fingerprint.
  @doc false
  @spec fetch_input(Message.t()) :: {:ok, map()}
  def fetch_input(%Message{parts: parts}) do
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
  # `resource`, the statically-resolved `domain` (or `nil`), and the bare
  # action-name atom `action` (`AshA2A.Skill`, skill.ex:15-21;
  # `AshA2A.CapabilityIndex.skill()`, capability_index.ex:23-29). `action` here is the real,
  # already-resolved `%Ash.Resource.Actions.*{}` struct (via `fetch_action/1`
  # -> `Ash.Resource.Info.action/2`), so `action.type`/`action.name` are
  # available exactly as ash_ai branches on them at
  # `~/xaas/deps/ash_ai/lib/ash_ai/tool/execution.ex:79`. `exec_context` is an
  # `%AshA2A.ExecutionContext{}` per PRD §3.5 carrying
  # `actor`/`tenant`/`context`/`domain`/`history` resolved from the message,
  # with `domain` being the `resource_or_domain` the dispatcher itself was
  # called with.
  defp run_skill(skill, action, input, exec_context) do
    opts = build_opts(skill, exec_context)

    result =
      case action.type do
        :read -> run_read(skill, action, input, opts)
        :create -> run_create(skill, action, input, opts)
        :update -> run_update(skill, action, input, opts)
        :destroy -> run_destroy(skill, action, input, opts)
        :action -> run_generic(skill, action, input, opts)
      end

    {to_reply(result), object_id(result, input)}
  end

  # -- Real object identity for OCEL relationship forwarding ---------------
  #
  # Two real, non-fabricated sources, tried in order:
  #
  #   1. The already-persisted Ash record a `:create`/`:update`/`:read`
  #      (`get?`)/`:destroy` action actually produced or acted on --
  #      identified via the resource's own real `Ash.Resource.Info.
  #      primary_key/1`, the same identity `fetch_record_for_update/2`
  #      resolves *records* by. A composite key (2+ fields) is skipped --
  #      no single real id string represents it without inventing a
  #      delimiter convention nothing else in this codebase uses.
  #   2. For a generic `:action` skill with no Ash data-layer record at all
  #      (`AshA2A.Test.Fixture.FreedomGym.Facilitator`'s `:next_phase`/
  #      `:reset_plan`), the real `plan_name` argument the caller supplied
  #      -- it names a real, specific stateful instance
  #      (`AshA2A.Test.Fixture.FreedomGym.MeetingPlan`'s per-name Agent
  #      state), not a fabricated id. `AshA2A.MetadataKey.fetch/2` handles
  #      both the atom-key (in-process caller) and string-key (real A2A
  #      wire JSON) shapes the same way `fetch_record_for_update/2` already
  #      relies on for CRUD primary keys.
  #
  # Neither source is guaranteed present -- most skills (e.g. `:run_phase`,
  # a pure stateless echo) have no real object identity at all, and this
  # returns `nil` for them rather than inventing one.
  defp object_id({:ok, %resource{} = record}, _input) do
    case Ash.Resource.Info.primary_key(resource) do
      [field] ->
        case Map.get(record, field) do
          nil -> nil
          value -> to_string(value)
        end

      _other ->
        nil
    end
  end

  defp object_id(_result, input) when is_map(input) do
    case AshA2A.MetadataKey.fetch(input, :plan_name) do
      {:ok, value} -> to_string(value)
      :error -> nil
    end
  end

  defp object_id(_result, _input), do: nil

  # Same opts shape as `AshAi.Tool.Execution.build_opts/2`
  # (`~/xaas/deps/ash_ai/lib/ash_ai/tool/execution.ex:100-107`), sourced from
  # the resolved `AshA2A.ExecutionContext` rather than a raw context map.
  #
  # `domain` prefers the skill's own persisted `domain` field (populated by
  # `AshA2A.Transformers.BuildCapabilityIndex` via `Ash.Resource.Info.domain/1`
  # at compile time -- the domain that actually owns the resource), falling
  # back to `exec_context.domain` (the `resource_or_domain` the dispatcher was
  # called with) when the resource has no statically configured domain
  # (`Ash.Resource.Info.domain/1` returns `nil` for a domain-less resource).
  #
  # `exec_context.history` (the prior-turn `A2A.Agent` task transcript,
  # `~/xaas/deps/a2a/lib/a2a/agent.ex:130-135`) is folded into the Ash
  # `context:` opt under `:a2a_history` rather than dropped -- Ash threads
  # this opt straight through to `changeset.context`/`query.context`/
  # `input.context` (`Ash.Changeset.for_create/3`, `Ash.Query.for_read/3`,
  # `Ash.ActionInput.for_action/3` each accept `context:` in their opts and
  # merge it onto the built struct), so a resource action can read prior
  # turns via `context[:a2a_history]` in a change/preparation/calculation.
  defp build_opts(skill, %AshA2A.ExecutionContext{} = exec_context) do
    [
      domain: Map.get(skill, :domain) || exec_context.domain,
      actor: exec_context.actor,
      tenant: exec_context.tenant,
      context: Map.put(exec_context.context || %{}, :a2a_history, exec_context.history || [])
    ]
  end

  # `{"stream" => true}` / `%{stream: true}` in the inbound `A2A.Part.Data`
  # input map (`fetch_input/1`) is the caller's real, explicit opt-in signal
  # to stream this `:read` skill rather than fully materialize it (PRD §3.7).
  # This is deliberately a per-call caller choice, not a static property of
  # the action: every default Ash `:read` action already carries a non-nil
  # `%Ash.Resource.Actions.Read.Pagination{keyset?: true, offset?: true}`
  # struct even with no `pagination do ... end` declared (confirmed against
  # the real compiled `AshA2A.Test.Fixture.Echo` fixture -- its plain
  # `defaults([:read])` action already has `keyset?: true, offset?: true`),
  # so branching on `action.pagination` alone cannot distinguish "this skill
  # wants streaming" from "this is an ordinary Ash read action" -- virtually
  # every real `:read` action would match. The `stream` flag is popped out of
  # `input` before it reaches `Ash.Query.for_read/3` since it is a dispatch
  # directive, not a real action argument.
  defp run_read(skill, action, input, opts) do
    case pop_stream_flag(input) do
      {true, input} ->
        run_read_stream(skill, action, input, opts)

      {false, input} ->
        skill.resource
        |> Ash.Query.for_read(action.name, input, opts)
        |> Ash.read(opts)
    end
  end

  defp pop_stream_flag(input) when is_map(input) do
    {raw, input} =
      case Map.pop(input, "stream") do
        {nil, input_without_string_key} -> Map.pop(input_without_string_key, :stream)
        {value, input_without_string_key} -> {value, input_without_string_key}
      end

    {raw in [true, "true"], input}
  end

  defp pop_stream_flag(input), do: {false, input}

  # Drives the query through the real `Ash.stream!/2` API
  # (`~/xaas/deps/ash/lib/ash.ex:2964`) instead of `Ash.read/2` (PRD §3.7).
  # `Ash.stream!/2` is the only public streaming entry point Ash exposes --
  # there is no non-bang `Ash.stream/2` -- so building the stream is wrapped
  # in `try/rescue` here to keep this module's fail-closed, non-raising
  # dispatch contract for the eager part of the call (query validation,
  # domain/resource resolution); errors raised lazily while the caller drains
  # the returned `Enumerable.t()` are outside what a `{:stream, _}` reply can
  # intercept, matching `A2A.Agent.Runtime.wrap_stream/3`'s own scope
  # (`~/xaas/deps/a2a/lib/a2a/agent/runtime.ex:51-61`: it observes completed
  # parts, it does not rescue mid-stream failures either).
  #
  # `allow_stream_with: :full_read` is passed so an action that supports only
  # offset (not keyset) pagination still streams via `Ash.stream!/2`'s worse
  # strategies instead of raising `Ash.Error.Invalid.NonStreamableAction`.
  defp run_read_stream(skill, action, input, opts) do
    query = Ash.Query.for_read(skill.resource, action.name, input, opts)

    if query.valid? do
      stream_opts = Keyword.put(opts, :allow_stream_with, :full_read)

      try do
        {:stream_ok, Ash.stream!(query, stream_opts)}
      rescue
        error -> {:error, error}
      end
    else
      {:error, Ash.Error.to_error_class(query.errors)}
    end
  end

  defp run_create(skill, action, input, opts) do
    skill.resource
    |> Ash.Changeset.for_create(action.name, input, opts)
    |> Ash.create(opts)
  end

  # Real, pre-existing bug fixed here, same shape as `run_destroy/4`'s own
  # documented fix below: `input` (by construction) always carries at least
  # the resource's real primary-key field(s), since `fetch_record_for_update/2`
  # just read them out of this same map to resolve `record`. An update
  # action whose `accept` list does not also happen to include those pk
  # field(s) (e.g. a resource whose real primary key is `:id` but whose
  # update action only accepts `[:label]`, unlike `AshA2ADispatcherFetchRecordTest.
  # Ticket`'s update action, which happens to accept its own natural-key pk
  # `:ticket_ref` too) previously received the pk field(s) as
  # unrecognized attribute input straight through to
  # `Ash.Changeset.for_update/3`, raising a spurious
  # `Ash.Error.Invalid.NoSuchInput` -- unrelated to whether the record was
  # found -- mapped by `to_reply/1` to a misleading `{:input_required, _}`.
  # The record identity is already resolved; an update needs only the
  # remaining, real attribute changes.
  defp run_update(skill, action, input, opts) do
    with {:ok, record} <- fetch_record_for_update(skill, input, opts) do
      pk = Ash.Resource.Info.primary_key(skill.resource)
      update_input = drop_primary_key_fields(input, pk)

      record
      |> Ash.Changeset.for_update(action.name, update_input, opts)
      |> Ash.update(opts)
    end
  end

  defp drop_primary_key_fields(input, pk) when is_map(input) do
    Enum.reduce(pk, input, fn field, acc ->
      acc |> Map.delete(field) |> Map.delete(Atom.to_string(field))
    end)
  end

  # Resolves the record to update/destroy using the resource's *actual*
  # primary key (`Ash.Resource.Info.primary_key/1`) instead of a hardcoded
  # `"id"`/`:id` key. Real `Ash.get/3` (via `Ash.Filter.get_filter/2`,
  # `deps/ash/lib/ash/filter/filter.ex:480-510`) resolves identity generically:
  # a single primary-key field of any name, or a composite key supplied as a
  # map/keyword of all key fields — neither requires the field be named `id`.
  defp fetch_record_for_update(skill, input, opts) do
    pk = Ash.Resource.Info.primary_key(skill.resource)

    case fetch_primary_key_values(pk, input) do
      {:ok, id_or_composite} -> Ash.get(skill.resource, id_or_composite, opts)
      :error -> {:error, {:missing_argument, missing_argument_name(pk)}}
    end
  end

  # Single-attribute primary key: accept either string or atom key input.
  defp fetch_primary_key_values([field], input) when is_atom(field) do
    fetch_input_value(input, field)
  end

  # Composite primary key: every field must be present; pass through as a
  # map (an accepted `Ash.Filter.get_filter/2` composite-key shape) as-is.
  defp fetch_primary_key_values(fields, input) when is_list(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case fetch_input_value(input, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp fetch_input_value(input, field) when is_map(input) do
    AshA2A.MetadataKey.fetch(input, field)
  end

  defp fetch_input_value(_input, _field), do: :error

  defp missing_argument_name([field]), do: field
  defp missing_argument_name(fields), do: fields

  defp run_destroy(skill, action, input, opts) do
    with {:ok, record} <- fetch_record_for_update(skill, input, opts) do
      # A non-soft (hard) `:destroy` action never accepts attribute input --
      # `Ash.Resource.Transformers.DefaultAccept` forces `accept: []` for
      # every `%{type: :destroy, soft?: false}` action regardless of what a
      # resource author declares (`deps/ash/lib/ash/resource/transformers/
      # default_accept.ex`). Passing the raw dispatch `input` (which, by
      # construction, always carries at least the identity fields
      # `fetch_record_for_update/3` just used) straight into
      # `Ash.Changeset.for_destroy/4` therefore fails every real hard-destroy
      # dispatch with a spurious `Ash.Error.Invalid.NoSuchInput` -- unrelated
      # to whether the record was found. The record is already resolved
      # above; a destroy needs no further attribute params.
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

  # -- Reply mapping -------------------------------------------------------

  # Maps every non-bang Ash outcome to the exact `A2A.Agent.reply()` shapes
  # (`~/xaas/deps/a2a/lib/a2a/agent.ex:160-164`). `{:input_required, _}` is
  # reserved for a caller-facing "you must supply more input" signal — an Ash
  # invalid/missing-argument error is the closest existing analogue (PRD §1.5
  # FR4). Not every `class: :invalid` error qualifies, though:
  # `TenantRequired`/`NoPrimaryAction` are resource/action wiring problems,
  # not caller-fixable, and are carved out to `{:error, {:invalid_config, _}}`
  # below. Everything else Ash can fail with maps to `{:error, _}`.
  # `run_read_stream/4`'s success tag, distinct from the plain `{:ok, _}`
  # every other `run_*/4` returns so it can bypass the "materialize into one
  # `Part.Data`" path below and become `{:stream, _}` instead. Each record is
  # lazily mapped through the same `encode_result/1`/`wrap_for_part_data/1`
  # pipeline used for a single non-streamed record, then wrapped in
  # `Part.Data.new/1` -- so a client draining the stream sees the same
  # per-record shape it would see inside a materialized `{:reply, _}`'s
  # `results` list, one `A2A.Part.Data.t()` at a time.
  defp to_reply({:stream_ok, stream}) do
    {:stream,
     Stream.map(stream, fn record ->
       Part.Data.new(wrap_for_part_data(encode_result(record)))
     end)}
  end

  defp to_reply({:ok, result}) do
    {:reply, [Part.Data.new(wrap_for_part_data(encode_result(result)))]}
  end

  defp to_reply(:ok) do
    {:reply, [Part.Data.new(%{})]}
  end

  defp to_reply({:error, {:missing_argument, _} = reason}) do
    {:input_required, [Part.Text.new(missing_argument_message(reason))]}
  end

  # `Ash.Error.Invalid.TenantRequired` (`deps/ash/lib/ash/error/invalid/tenant_required.ex:8`)
  # and `Ash.Error.Invalid.NoPrimaryAction`
  # (`deps/ash/lib/ash/error/invalid/no_primary_action.ex:8`) both declare
  # `class: :invalid`, but neither describes a caller-supplied-argument
  # defect: they fire because the resource has no tenant context / no
  # primary action of the requested type wired up, and `dispatcher.ex`
  # never lets a caller supply tenant or action selection independently of
  # the already-resolved skill/action (see `run_*/4` above). Signaling
  # `:input_required` for these would tell the client "supply more input"
  # when no input the client could supply would fix it, so they're routed
  # to `{:error, {:invalid_config, _}}` instead, alongside the other
  # non-`:input_required` error classes below.
  #
  # That struct match alone only catches the read pipeline
  # (`deps/ash/lib/ash/actions/read/read.ex:2841-2848` raises the literal
  # `TenantRequired` struct). `:create`/`:update`/`:destroy` enforce
  # multitenancy differently: `Ash.Actions.Helpers.validate_changeset_multitenancy/1`
  # (`deps/ash/lib/ash/actions/helpers.ex:1057-1065`) returns a plain string
  # ("... changesets require a tenant to be specified"), which
  # `Ash.Changeset.add_error/3` wraps as a generic
  # `Ash.Error.Changes.InvalidChanges` (`class: :invalid`, not one of the two
  # modules above) and Ash's top-level `Splode.ErrorClass` then aggregates
  # into an `Ash.Error.Invalid{errors: [...]}` whose `errors` list holds that
  # `InvalidChanges` struct. `tenant_required_error?/1` below matches the
  # struct-level carve-out and also walks a `class: :invalid` error's nested
  # `errors:` list for a message that says the same "requires a tenant" thing,
  # so create/update/destroy's missing-tenant errors get the same
  # `{:invalid_config, _}` treatment as read's instead of falling through to
  # the generic `:input_required` clause below.
  defp to_reply({:error, %{class: :invalid} = error}) do
    if tenant_required_error?(error) do
      {:error, class_message(:invalid_config, Exception.message(error))}
    else
      {:input_required, [Part.Text.new(Exception.message(error))]}
    end
  end

  # `:forbidden`, `:framework`, and `:unknown` are distinct Splode error
  # classes (`Ash.Error.Forbidden`/`Framework`/`Unknown`, each declaring its
  # own `class:` per `Splode.ErrorClass`, parallel to `:invalid`) that stay
  # caller-actionable in a different way than `:invalid`: forbidden signals
  # "you don't have access" and framework/unknown signal a server-side
  # fault, none of which "supply more input" (`:input_required`) would fix.
  #
  # `A2A.Agent.Runtime.handle_reply/2` (the real A2A runtime this dispatcher
  # feeds) does not branch on the `{:error, reason}` tuple's shape at all --
  # it only ever does `Message.new_agent("Error: #{inspect(reason)}")`. A
  # tagged tuple like `{:forbidden, "msg"}` would therefore reach the wire
  # as literal Elixir tuple syntax (`{:forbidden, "msg"}`), which no real
  # A2A client can parse into a structured class. So the class label is
  # folded into a single human-readable string ("forbidden: msg") instead
  # of a tuple: `inspect/1` of a plain string still adds quotes, but the
  # class name and message are legible text on the wire rather than opaque
  # Elixir term syntax.
  defp to_reply({:error, %{class: :forbidden} = error}) do
    {:error, class_message(:forbidden, Ash.Error.to_class(error) |> Exception.message())}
  end

  defp to_reply({:error, %{class: :framework} = error}) do
    {:error, class_message(:framework, Ash.Error.to_class(error) |> Exception.message())}
  end

  defp to_reply({:error, %{class: :unknown} = error}) do
    {:error, class_message(:unknown, Ash.Error.to_class(error) |> Exception.message())}
  end

  defp to_reply({:error, reason}) do
    {:error, reason}
  end

  defp class_message(class, message) when is_atom(class) and is_binary(message) do
    "#{class}: #{message}"
  end

  # Struct-level carve-out (read's `TenantRequired`/`NoPrimaryAction`) or a
  # nested `errors:` list (create/update/destroy's aggregated
  # `Ash.Error.Invalid`) containing an error whose message says a tenant is
  # required. See the comment above the `to_reply/1` clause that calls this.
  @tenant_required_modules [Ash.Error.Invalid.TenantRequired, Ash.Error.Invalid.NoPrimaryAction]
  @tenant_required_text "require a tenant to be specified"

  defp tenant_required_error?(%module{}) when module in @tenant_required_modules do
    true
  end

  defp tenant_required_error?(%{errors: errors}) when is_list(errors) and errors != [] do
    Enum.any?(errors, &tenant_required_error?/1)
  end

  defp tenant_required_error?(error) do
    error
    |> Exception.message()
    |> String.contains?(@tenant_required_text)
  end

  defp missing_argument_message({:missing_argument, names}) when is_list(names) do
    "missing required argument(s): #{Enum.map_join(names, ", ", &to_string/1)}"
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

  # `A2A.Part.Data.new/2` (`~/xaas/deps/a2a/lib/a2a/part.ex:74`) requires a
  # map. `encode_result/1` returns a bare list for `:read` actions with no
  # `get?` (list results) and a scalar for `:action` results that return a
  # non-struct value (e.g. a plain integer/boolean) -- neither is a map, so
  # both must be wrapped before reaching `Part.Data.new/2`. A result that is
  # already a map (the common single-record case) passes through unchanged.
  defp wrap_for_part_data(%{} = map), do: map
  defp wrap_for_part_data(list) when is_list(list), do: %{results: list}
  defp wrap_for_part_data(other), do: %{result: other}
end
