defmodule AshA2A.Agent do
  @moduledoc """
  Generates a real, runnable `A2A.Agent` GenServer for an `AshA2A`-extended
  resource or domain, so a compiled capability index has an actual supervised
  process a caller can send an `A2A.Message` to -- not just a synchronous
  `AshA2A.Dispatcher.dispatch/5` function call.

      defmodule MyApp.EchoAgent do
        use AshA2A.Agent, resource_or_domain: MyApp.Echo
      end

      # under a supervisor:
      children = [
        {A2A.AgentSupervisor, agents: [MyApp.EchoAgent]}
      ]

  The generated `agent_card/0` is built from the real, persisted, verified
  capability index (`AshA2A.Info.agent_card/2`, PRD §3.2) -- never
  hand-written -- so the agent process can never advertise a skill dispatch
  can't serve.

  `handle_message/2` reads the target skill name from the inbound
  `A2A.Message`'s `metadata[:skill]` (or `"skill"` string key, matching
  `AshA2A.ContextResolver`'s own atom-then-string metadata lookup
  convention). A resource/domain with exactly one compiled skill lets the
  caller omit `:skill` metadata entirely -- that single skill is dispatched
  by default. Either way, dispatch runs through the real
  `AshA2A.Dispatcher.dispatch/5` path (PRD §3.2/§3.5), so an agent process
  built with this macro can never diverge from what `AshA2A.Info.agent_card/2`
  advertises.

  The full `A2A.Agent.context()` (`task_id`, `context_id`, `history`,
  `metadata`) that `handle_message/2` receives is never discarded: `history`
  -- the accumulated multi-turn transcript `A2A.Agent.Runtime` builds for a
  continued (`task_id:`) task (`~/xaas/deps/a2a/lib/a2a/agent.ex:69-90,
  130-135`) -- is threaded straight through to
  `AshA2A.Dispatcher.dispatch/5`, which folds it into the Ash `context:` opt
  as `:a2a_history` (see `__dispatch__/3` and `task_history/1` below).
  """

  @doc false
  defmacro __using__(opts) do
    {resource_or_domain_ast, agent_opts_ast} = Keyword.pop!(opts, :resource_or_domain)

    # `use A2A.Agent, card_opts` (below) expands `A2A.Agent.__using__/1` at
    # *this* macro-expansion time, and that macro reads `card_opts` with
    # `Keyword.has_key?/2` directly on the AST it's given -- it cannot accept
    # a runtime function-call expression. `resource_or_domain` and the rest
    # of `opts` are always literal (a module alias, literal strings/atoms),
    # so both are resolved for real right here at compile time --
    # `Macro.expand/2` for the module alias, `Code.eval_quoted/3` for the
    # rest -- and the resulting card is embedded as a literal keyword list
    # via `bind_quoted`, exactly what `A2A.Agent.__using__/1` requires.
    resource_or_domain = Macro.expand(resource_or_domain_ast, __CALLER__)
    {agent_opts, _bindings} = Code.eval_quoted(agent_opts_ast, [], __CALLER__)
    card_opts = __card_opts__(resource_or_domain, agent_opts)

    # `unquote(Macro.escape(card_opts))` (not `bind_quoted`) splices the
    # already-computed literal keyword list directly into the AST this
    # macro returns -- so when the caller's `use A2A.Agent, <that literal>`
    # expands, `A2A.Agent.__using__/1` receives the real keyword list AST,
    # not a runtime variable reference it can't inspect at macro-expansion
    # time (which is what `bind_quoted` would produce here).
    quote do
      use A2A.Agent, unquote(Macro.escape(card_opts))

      @ash_a2a_resource_or_domain unquote(resource_or_domain)

      @impl A2A.Agent
      def handle_message(message, context) do
        AshA2A.Agent.__dispatch__(@ash_a2a_resource_or_domain, message, context)
      end

      defoverridable handle_message: 2

      # `A2A.Agent.__using__/1` (`~/xaas/deps/a2a/lib/a2a/agent.ex:192-195`)
      # already `defoverridable`s its own `handle_cancel(_context), do: :ok`
      # default, so this real override -- rather than the inherited no-op --
      # is what actually runs from `handle_call({:cancel, task_id}, ...)`
      # (`~/xaas/deps/a2a/lib/a2a/agent.ex:305-343`) once the state machine
      # has already confirmed the task is cancelable (not terminal).
      @impl A2A.Agent
      def handle_cancel(context) do
        AshA2A.Agent.__cancel__(@ash_a2a_resource_or_domain, context)
      end

      defoverridable handle_cancel: 1
    end
  end

  @doc false
  @spec __card_opts__(module(), keyword()) :: keyword()
  def __card_opts__(resource_or_domain, opts) do
    agent_card = AshA2A.Info.agent_card(resource_or_domain, opts)

    [
      name: agent_card.name,
      description: agent_card.description,
      version: agent_card.version,
      skills: agent_card.skills
    ]
  end

  @doc false
  @spec __dispatch__(module(), A2A.Message.t(), A2A.Agent.context() | map()) ::
          AshA2A.Dispatcher.reply()
  def __dispatch__(resource_or_domain, %A2A.Message{} = message, context) do
    history = task_history(context)
    auth_identity = verified_auth_identity(context)

    case resolve_skill_name(resource_or_domain, message) do
      {:ok, skill_name} ->
        AshA2A.Dispatcher.dispatch(skill_name, message, resource_or_domain, history, auth_identity)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Extracts the transport-verified caller identity from
  # `A2A.Agent.context().metadata["a2a.auth"]` -- the key `A2A.Plug` populates
  # exclusively from `A2A.Plug.Auth`'s real credential-verification result
  # (`~/xaas/deps/a2a/lib/a2a/plug.ex:159`,
  # `Map.put(metadata, "a2a.auth", auth)`, reached only after
  # `evaluate_alternatives/2` -> `opts.verify.(scheme, credential, conn)`
  # actually succeeds, `~/xaas/deps/a2a/lib/a2a/plug/auth.ex:175-176,226-242`)
  # -- and threads only its `:identity` field (the verified identity map a
  # resource author's own `verify` callback returned) into
  # `AshA2A.Dispatcher.dispatch/5` as `auth_identity`. This is the ONLY path
  # `actor`/`tenant` ever reach `AshA2A.ContextResolver.from_a2a_message/4`
  # from -- `message.metadata` (the inbound `A2A.Message`'s own,
  # unauthenticated, remote-caller-controlled field) is never consulted for
  # either, per the PRD §3.5 trust boundary documented on
  # `AshA2A.ContextResolver`.
  #
  # `context.metadata` is absent/`nil` for a direct unit-test call to
  # `handle_message/2` (bypassing `A2A.Plug` entirely) or for a deployment
  # that hasn't wired `A2A.Plug.Auth` at all -- both fall through to `nil`,
  # so dispatch fails closed (unauthenticated: no actor, no tenant) instead
  # of fabricating an identity out of unverified input.
  @spec verified_auth_identity(A2A.Agent.context() | map()) :: term()
  defp verified_auth_identity(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "a2a.auth") do
      %{identity: identity} -> identity
      %{"identity" => identity} -> identity
      _other -> nil
    end
  end

  defp verified_auth_identity(_context), do: nil

  # `A2A.Agent.context().history` (`~/xaas/deps/a2a/lib/a2a/agent.ex:130-135`)
  # is the accumulated multi-turn transcript the runtime builds when a caller
  # continues a paused (`:input_required`) task by passing `task_id:` on the
  # next call (`continue_task/4` -> `run_task/4`,
  # `~/xaas/deps/a2a/lib/a2a/agent/runtime.ex:34-44,62-79`). Before this
  # function existed, `handle_message/2` bound this second argument to
  # `_context` and never read it (ash_a2a task #8), so a resource action had
  # no way to see prior turns on a continued task -- the second dispatch of a
  # multi-turn conversation looked identical to a fresh one. Threaded here
  # into `AshA2A.Dispatcher.dispatch/5` -> `AshA2A.ContextResolver.
  # from_a2a_message/4` -> `AshA2A.ExecutionContext.history` -> the Ash
  # `context:` opt (`AshA2A.Dispatcher.build_opts/2`), so a resource action
  # can read it via `context[:a2a_history]`. `context` may be a plain map
  # lacking `:history` (a direct unit-test call, or a first turn with no
  # prior history) -- both fall back to `[]`.
  defp task_history(%{history: history}) when is_list(history), do: history
  defp task_history(_context), do: []

  # `handle_cancel/1` (`A2A.Agent.context()`,
  # `~/xaas/deps/a2a/lib/a2a/agent.ex:148-153`) is called by the real state
  # machine's `handle_call({:cancel, task_id}, ...)`
  # (`~/xaas/deps/a2a/lib/a2a/agent.ex:305-343`) only after it has already
  # confirmed the task is *not* terminal (`:completed`/`:canceled`/`:failed`
  # short-circuit to `{:error, :not_cancelable}` before this ever runs,
  # agent.ex:308-309) -- so the one real-world window this fires in is a task
  # parked in `:input_required` awaiting a follow-up message (ash_a2a task
  # #13). Unlike `handle_message/2`, the `context()` passed here
  # (`%{task_id, context_id, history, metadata}`) is not wrapped in an
  # `A2A.Message` -- a synthetic, never-dispatched `A2A.Message` is built
  # here purely to reuse `AshA2A.ContextResolver.from_a2a_message/4`'s
  # `:context` extraction (atom-or-string `metadata[:context]`) rather than
  # re-implementing it a second time. `actor`/`tenant` are NOT read from
  # this synthetic message's metadata either (same PRD §3.5 trust boundary
  # as `__dispatch__/3`) -- they come from the same
  # `metadata["a2a.auth"][:identity]` extraction via `verified_auth_identity/1`,
  # so a cancel telemetry event reports the real verified caller, never a
  # value an unauthenticated remote caller could spoof through cancel-request
  # metadata.
  #
  # There is no ash_a2a DSL hook (no `on_cancel` skill option) for a resource
  # author to run real Ash-side compensation here, and none is fabricated --
  # `AshA2A.Skill`/`AshA2A.Dsl` declare no such callback today (grep over
  # `lib/ash_a2a/{dsl,skill}.ex` confirms). What this function provides, for
  # real, is a `:telemetry.execute/3` event (`:telemetry` is a real
  # transitive dep already used the identical way by `A2A.Agent` itself for
  # `[:a2a, :agent, :cancel]`, `~/xaas/deps/a2a/lib/a2a/agent.ex:290-294`)
  # carrying the resolved `AshA2A.ExecutionContext` (actor/tenant/domain)
  # plus `task_id`/`context_id` -- a real, attachable hook a resource author
  # can subscribe to (`:telemetry.attach/4`) to run Ash-side cleanup on
  # cancellation, instead of the prior silent, unobservable inherited `:ok`
  # no-op.
  @doc false
  @spec __cancel__(module(), A2A.Agent.context()) :: :ok
  def __cancel__(resource_or_domain, %{metadata: metadata} = context) do
    exec_context =
      AshA2A.ContextResolver.from_a2a_message(
        %A2A.Message{role: :user, parts: [], metadata: metadata || %{}},
        resource_or_domain,
        [],
        verified_auth_identity(context)
      )

    :telemetry.execute(
      [:ash_a2a, :agent, :cancel],
      %{},
      %{
        resource_or_domain: resource_or_domain,
        task_id: Map.get(context, :task_id),
        context_id: Map.get(context, :context_id),
        actor: exec_context.actor,
        tenant: exec_context.tenant,
        context: exec_context.context,
        domain: exec_context.domain
      }
    )

    :ok
  end

  defp resolve_skill_name(resource_or_domain, %A2A.Message{metadata: metadata}) do
    metadata = metadata || %{}

    case Map.get(metadata, :skill) || Map.get(metadata, "skill") do
      nil -> default_skill_name(resource_or_domain)
      name -> {:ok, name}
    end
  end

  defp default_skill_name(resource_or_domain) do
    case AshA2A.Info.capability_index(resource_or_domain) do
      [%AshA2A.Skill{name: name}] -> {:ok, name}
      [] -> {:error, {:no_skill, resource_or_domain}}
      _many -> {:error, {:ambiguous_skill, resource_or_domain}}
    end
  end
end
