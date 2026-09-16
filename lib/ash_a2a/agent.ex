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

  ## Concurrency: one mailbox, not a worker pool

  A generated agent is a single `A2A.Agent` GenServer process, so every
  `:message`/`:cancel`/`:get_task`/`:list_tasks` call to one agent instance
  is serialized through that one mailbox -- a slow in-flight dispatch
  (a long-running Ash action) blocks every other in-flight call to the
  *same* agent instance until it completes. This is inherent to `A2A.Agent`'s
  design, not a bug introduced by `AshA2A.Agent`. If concurrent throughput
  across skills/resources matters, run multiple named agent instances (one
  per resource/domain, or sharded per tenant) behind `A2A.AgentSupervisor`
  rather than relying on one process to serve unrelated concurrent work.
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

  # `AshA2A.CommandBus.run/4` is the canonical receipted route to
  # `AshA2A.Dispatcher.dispatch/5` -- it calls `dispatch/5` internally with
  # this exact same `skill_name`/`message`/`resource_or_domain`/`history`/
  # `auth_identity` shape (`command_bus.ex:32-38`), so routing every real
  # dispatch through it here does not change what actually executes or how
  # its reply is shaped; it wraps that unchanged execution with admission
  # (capability/action resolution), a claim against the configured
  # `ReceiptStore` (real replay/conflict detection for a caller-supplied
  # stable `command_id`), and a committed `AshA2A.Receipt` for every real
  # outcome. Before this change, the default `A2A.Agent` path -- the only
  # path any deployed agent actually uses -- called `Dispatcher.dispatch/5`
  # directly and left `CommandBus` reachable only from the parallel,
  # opt-in `Reactor.ExecuteCommand`/`Delivery.Oban`/`Execution.FLAME` routes,
  # so no default-path invocation ever left a receipt and `CommandBus` was
  # not, in fact, the sole DO path its own moduledoc claims to be.
  #
  # `command_id` is the real, canonical, protocol-native
  # `A2A.Message.message_id` (see `build_command/4` below for the full
  # rationale), not a fresh id generated per call -- so a genuine client
  # retry (same `message_id`) engages `CommandBus`'s real replay/conflict
  # detection through this default path too, the same as it always did for
  # `Reactor.ExecuteCommand`/`Delivery.Oban` callers that already construct
  # a `Command` with a stable, caller-chosen id. The gains for every
  # default-path dispatch here are: (1) a persisted `AshA2A.Receipt` for
  # every consequence-bearing outcome, where none existed before; (2) a
  # real, fail-closed `AshA2A.Authority` admission gate ahead of `:change`/
  # `:external_do` consequences -- decided from the already-verified
  # `auth_identity` by `AshA2A.Authority.Grant.authorize/3` (`nil` for an
  # unauthenticated caller, AND `nil` for an authenticated caller holding no
  # real capability grant, so either is refused with `:authority_required`
  # before ever reaching the Ash action, matching this module's existing
  # fail-closed convention elsewhere). Authentication alone does NOT confer
  # this authority -- see `build_command/4` below and
  # `AshA2A.Authority.Grant` for the RFC-SA2A-001 S29 escalation that
  # behavior was. This gate does not replace or tighten Ash's own
  # actor/policy authorization, which still runs exactly as before inside
  # the wrapped `Dispatcher.dispatch/5` call; it only adds a receipted
  # admission gate ahead of it.
  #
  # Routing is by `skill.consequence` -- real capability truth computed once
  # at compile time (`AshA2A.CapabilityIndex.Compiler`, `AshA2A.Skill`'s
  # @moduledoc) -- never by re-deriving a binary "read or not" judgment from
  # `action.type` here. Four branches:
  #
  #   * `:observe` -- direct `Dispatcher.dispatch/5`, no `CommandBus`. This
  #     also covers a streaming `:read` (PRD §3.7,
  #     `Dispatcher.run_read_stream/4`) correctly: `AshA2A.Receipt.
  #     from_reply/4`'s `summarize/1` would otherwise collapse a real
  #     `{:stream, enumerable}` reply into the placeholder
  #     `{:stream, :enumerable}` before a caller could ever consume it.
  #   * `:change` / `:external_do` -- routed through `AshA2A.CommandBus.run/4`
  #     for real admission/authority/receipt.
  #   * `:unknown` -- an unclassified generic `:action` skill. Refused
  #     closed with a typed `:consequence_unclassified` code *before* any
  #     dispatch attempt at all -- never executed, on the theory that a
  #     capability nobody has yet declared safe must not be reachable
  #     through the default agent path merely because no one classified it.
  #     (`CommandBus.admit/2` also refuses `:unknown` independently, for any
  #     caller reaching it directly -- this is defense in depth, not the
  #     only enforcement point.)
  #   * A skill/action lookup failure resolves to `:observe` here (falls
  #     through to a direct `Dispatcher.dispatch/5` call) so an unknown or
  #     misconfigured skill still surfaces through `dispatch/5`'s own
  #     existing, tagged `{:error, {:skill_lookup, _}}`/
  #     `{:error, {:action_resolution, _}}` shapes unchanged, rather than
  #     this function inventing a second, differently shaped error for the
  #     same failure.
  # v26.9.14: the explicit semantic-compilation A2A surface. Two independent
  # gates, both real capability truth or real caller-supplied signal --
  # never a content sniff of unstructured text, never a fallback for an
  # unrecognized skill name: (1) the target resource/domain declared
  # `a2a do semantic_requests true end` (`AshA2A.Info.
  # semantic_requests_enabled?/1`, compiled DSL truth); (2) the caller's own
  # inbound message sets `:semantic_request`/`"semantic_request"` metadata
  # to `true` (`AshA2A.MetadataKey`'s existing atom-then-string convention,
  # the same one `:skill` metadata already uses). A message missing either
  # gate falls straight through to the ordinary skill-resolution path below
  # exactly as before this feature existed -- this branch adds a new,
  # explicit route, it does not change the meaning of any existing message.
  @doc false
  @spec __dispatch__(module(), A2A.Message.t(), A2A.Agent.context() | map()) ::
          AshA2A.Dispatcher.reply()
  def __dispatch__(resource_or_domain, %A2A.Message{} = message, context) do
    history = task_history(context)
    auth_identity = verified_auth_identity(context)

    if semantic_request?(resource_or_domain, message) do
      dispatch_semantic(resource_or_domain, message)
    else
      dispatch_skill(resource_or_domain, message, history, auth_identity)
    end
  end

  defp semantic_request?(resource_or_domain, %A2A.Message{metadata: metadata}) do
    AshA2A.Info.semantic_requests_enabled?(resource_or_domain) and
      AshA2A.MetadataKey.get(metadata || %{}, :semantic_request) == true
  end

  # GAP B: receipt -> feedback -> replan closure. A `:semantic_request`
  # message that ALSO carries `:continuation_fingerprint`/
  # `"continuation_fingerprint"` metadata (same `AshA2A.MetadataKey`
  # atom-then-string convention as `:skill`/`:semantic_request`) names a
  # PRIOR `AshA2A.Semantic.ExecutionPackage`'s own
  # `"execution_package_fingerprint"` (the fingerprint that package's own
  # `to_reply/1` handed back to whichever caller compiled or last replanned
  # it) that the caller wants a NEW candidate replanned from -- real
  # observation folded in, never a fresh, context-blind `Compiler.compile/3`.
  # Replanning is automatic ONLY for a fingerprint that resolves to BOTH a
  # real, previously-stored `ExecutionPackage` (`AshA2A.Semantic.
  # PackageStore.fetch/2`) AND a real, previously-committed `AshA2A.Receipt`
  # correlated to it (`build_command/4` below records exactly how a Command
  # continues a package) -- see `dispatch_semantic_replan/2`. A missing
  # `:continuation_fingerprint` no longer jumps straight to a fresh compile
  # -- as of v26.9.16 (`docs/jira/v26.9.16/PRFAQ.md` item 1) it falls
  # through to `dispatch_semantic_route/2` below, which decides for real,
  # per-message, whether a fresh compile is even the right tier. Every
  # existing caller's *behavior* is still unchanged: a message with no
  # `goal_facts` still ends up at the exact same `dispatch_semantic_compile/2`
  # call it always did (see that function's own routing below), just via
  # one extra real dispatch hop instead of a direct call.
  defp dispatch_semantic(resource_or_domain, %A2A.Message{metadata: metadata} = message) do
    case AshA2A.MetadataKey.get(metadata || %{}, :continuation_fingerprint) do
      nil ->
        dispatch_semantic_route(resource_or_domain, message)

      fingerprint when is_binary(fingerprint) and fingerprint != "" ->
        dispatch_semantic_replan(resource_or_domain, fingerprint)

      _invalid ->
        {:error, %{code: :continuation_fingerprint_invalid}}
    end
  end

  # NEW in v26.9.16 (`docs/jira/v26.9.16/PRFAQ.md` item 1): the real,
  # production call site for `AshA2A.Planning.RequestRouter` -- previously
  # a fully built, 39-test-covered, adversarially-verified module with zero
  # callers anywhere in this library's own real dispatch surface
  # (`git diff` against this module was empty before this release).
  # `RequestRouter.detect_tier/1` inspects the message's real input
  # (`AshA2A.Dispatcher.fetch_input/1` under the hood, so it sees a
  # `goal_facts` key on a `Data` part, not just top-level `metadata`) and
  # classifies it into exactly one of four real outcomes:
  #
  #   * `{:facts, _envelope}` -- a real, well-formed `goal_facts` map is
  #     present. Routed to the new `dispatch_semantic_goal_facts/2` below,
  #     which reaches the zero-LLM deterministic solver tier
  #     (`HddlDeterministicSynthesis.synthesize/3` via `RequestRouter.route/3`)
  #     instead of the LLM compiler.
  #   * `:invalid_goal_facts` -- a `goal_facts` key is present but its value
  #     is not a map (a real caller error: a malformed structured payload),
  #     fails closed immediately with a typed error rather than silently
  #     downgrading to the LLM tier.
  #   * `:ambiguous_goal_facts_shape` -- no top-level `goal_facts` key, but
  #     the real structured Data-part payload has one nested under some
  #     wrapper key (a real, adversarially-found caller-shape footgun: a
  #     caller sending `{"payload" => {"goal_facts" => ...}}` alongside
  #     real text was previously silently downgraded to the LLM tier
  #     instead of refused). Fails closed immediately, same treatment as
  #     `:invalid_goal_facts` above -- see `RequestRouter.detect_tier/1`'s
  #     own doc for the exact, bounded nested-scan condition.
  #   * `{:text, _text}` -- no `goal_facts` anywhere in the structured
  #     payload, but the message carries real text. Falls through to
  #     `dispatch_semantic_compile/2` UNCHANGED -- the exact same
  #     LLM-compilation call every text-only caller reached before this
  #     release existed.
  #   * `:error` -- neither a `goal_facts` map nor real text. Also falls
  #     through to `dispatch_semantic_compile/2` UNCHANGED, which is what
  #     produces the pre-existing, still-real
  #     `{:error, %{code: :semantic_request_missing_text}}` refusal for a
  #     flagged message with no usable input -- this router-wiring diff
  #     does not touch that refusal's code path or its typed reason.
  #
  # `detect_tier/1` itself is never modified by this wiring -- it is called
  # exactly as it already existed and is already tested.
  @spec dispatch_semantic_route(module(), A2A.Message.t()) :: AshA2A.Dispatcher.reply()
  defp dispatch_semantic_route(resource_or_domain, %A2A.Message{} = message) do
    case AshA2A.Planning.RequestRouter.detect_tier(message) do
      {:facts, _envelope} ->
        dispatch_semantic_goal_facts(resource_or_domain, message)

      :invalid_goal_facts ->
        {:error, %{code: :invalid_goal_facts}}

      :ambiguous_goal_facts_shape ->
        {:error, %{code: :ambiguous_goal_facts_shape}}

      {:text, _text} ->
        dispatch_semantic_compile(resource_or_domain, message)

      :error ->
        dispatch_semantic_compile(resource_or_domain, message)
    end
  end

  # NEW in v26.9.16, the deterministic-tier sibling of
  # `dispatch_semantic_compile/2` below: reached only when
  # `dispatch_semantic_route/2` above has already confirmed (via
  # `RequestRouter.detect_tier/1`) that this message carries a real,
  # well-formed `goal_facts` envelope. `RequestRouter.route/3` re-derives
  # the same tier internally (it is the router's own single real entry
  # point, never re-implemented here) and, for a facts-tier message,
  # dispatches straight to `HddlDeterministicSynthesis.synthesize/3` --
  # `AshA2A.Semantic.Compiler`/`ReqLLM.generate_object/4` is never on this
  # call path, structurally, not just by convention (see
  # `test/ash_a2a/planning/request_router_llm_never_called_test.exs` and
  # this task's own agent-level mirror of that same falsifier).
  #
  # On success, the resulting `AshA2A.Semantic.ExecutionPackage` is stored
  # in `AshA2A.Semantic.PackageStore` and replied via `to_reply/1` -- the
  # identical pattern `dispatch_semantic_compile/2` already uses for its
  # own freshly compiled packages, so a goal-facts-routed package is just
  # as replan-able later (`dispatch_semantic_replan/2` above) as an
  # LLM-compiled one; the two tiers converge on one real, shared package
  # lifecycle from this point on.
  @spec dispatch_semantic_goal_facts(module(), A2A.Message.t()) :: AshA2A.Dispatcher.reply()
  defp dispatch_semantic_goal_facts(resource_or_domain, %A2A.Message{} = message) do
    case AshA2A.Planning.RequestRouter.route(resource_or_domain, message) do
      {:ok, package} ->
        :ok = AshA2A.Semantic.PackageStore.put(package)
        AshA2A.Semantic.ExecutionPackage.to_reply(package)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `A2A.Message.text/1` returns the first real `A2A.Part.Text` part's
  # string, or `nil` if the message carries none (~/xaas/deps/a2a/lib/
  # a2a/message.ex) -- a caller opting into this explicit surface must
  # actually send text to compile; a flagged message with no text is a real
  # caller error, refused closed rather than compiling an empty string.
  #
  # Wrapped in `rescue`: `AshA2A.Semantic.Compiler.compile/3` calls
  # `AshA2A.LLMProfiles.model_spec!/1`, which genuinely `raise`s
  # `ArgumentError` when the required LLM role is unconfigured (a real,
  # deliberate fail-closed design in that module) -- every OTHER dispatch
  # path in this codebase (`AshA2A.Dispatcher`) is careful to never raise,
  # resolving each step through a non-bang API specifically so one caller's
  # malformed/misconfigured request can never crash the real, shared
  # `A2A.Agent` GenServer process (which would terminate every other
  # in-flight task that process happens to be managing, not just this
  # request). This branch is held to the identical contract: a
  # misconfigured LLM profile becomes a real, typed `{:error, ...}` reply,
  # never an uncaught exception reaching the caller's mailbox.
  #
  # A freshly compiled package is stored in `AshA2A.Semantic.PackageStore`,
  # keyed by its own real `fingerprint`, before its reply is returned -- the
  # same real store `dispatch_semantic_replan/2` below reads from, so a
  # caller that later presents this package's `"execution_package_fingerprint"`
  # back as a `:continuation_fingerprint` can resolve it for real.
  defp dispatch_semantic_compile(resource_or_domain, %A2A.Message{} = message) do
    case A2A.Message.text(message) do
      nil ->
        {:error, %{code: :semantic_request_missing_text}}

      text ->
        try do
          case AshA2A.Semantic.Compiler.compile(resource_or_domain, text) do
            {:ok, package} ->
              :ok = AshA2A.Semantic.PackageStore.put(package)
              AshA2A.Semantic.ExecutionPackage.to_reply(package)

            {:error, reason} ->
              {:error, reason}
          end
        rescue
          error ->
            {:error, %{code: :semantic_compilation_failed, detail: Exception.message(error)}}
        end
    end
  end

  # Real, concrete GAP B correlation mechanism: `AshA2A.ReceiptStore`
  # (`receipt_store.ex`) only supports lookup by `command_id`, not by an
  # arbitrary correlation field, so `build_command/4` below deliberately uses
  # the caller-supplied `continuation_fingerprint` itself AS the closing
  # command's `command_id` whenever one is present -- no second, parallel
  # index is invented; the EXISTING command_id-keyed `ReceiptStore.fetch/2`
  # does the whole job once the correlation key is chosen this way. Fetching
  # `AshA2A.Identity.command(fingerprint)` here is therefore the real,
  # already-existing lookup path every other receipt retrieval in this
  # codebase uses, not a new one.
  #
  # Two real, independent lookups gate replanning, both fail closed with a
  # distinct typed code rather than ever falling back to a fresh compile:
  # (1) a receipt must have actually been committed under this fingerprint
  # (a REFUSED closing dispatch -- `CommandBus.admit/2` failing -- never
  # reaches `store.claim`/`store.commit`, so no receipt exists to find, and
  # this real absence IS the refusal signal, not a special case); (2) the
  # real `ExecutionPackage` this fingerprint names must still be resolvable
  # in `AshA2A.Semantic.PackageStore`.
  defp dispatch_semantic_replan(resource_or_domain, fingerprint) do
    case fetch_continuation_receipt(fingerprint) do
      {:error, _reason} = error ->
        error

      {:ok, receipt} ->
        case AshA2A.Semantic.PackageStore.fetch(fingerprint) do
          :error ->
            {:error,
             %{code: :continuation_package_not_found, execution_package_fingerprint: fingerprint}}

          {:ok, package} ->
            replan(resource_or_domain, package, receipt)
        end
    end
  end

  defp fetch_continuation_receipt(fingerprint) do
    store = AshA2A.CommandBus.default_store()

    case store.fetch(AshA2A.Identity.command(fingerprint), []) do
      {:ok, receipt} ->
        {:ok, receipt}

      :error ->
        {:error,
         %{code: :continuation_receipt_not_found, execution_package_fingerprint: fingerprint}}
    end
  end

  # Real re-synthesis, never a fresh `Compiler.compile/3`: `Compiler.
  # replan/4` internally runs `Feedback.from_receipt/2` (projects the real
  # committed receipt into typed, authority-`:none` observation evidence)
  # -> `PlanningIR.with_observation/2` (folds that observation into the
  # PRIOR admitted planning IR, not a blank one) -> real re-synthesis against
  # the resource/domain's real canonical capability index. The resulting
  # `next` package is fenced by `ExecutionPackage.new/6` exactly like a fresh
  # compile's package -- `standing: :candidate, authority: :none` always,
  # structurally, never overridable via any opt this function passes -- so a
  # replanned candidate can no more auto-DO than a first-compile candidate
  # can. `next` is stored under its own fingerprint the same way a fresh
  # compile's package is, so a caller may chain a further real closing
  # dispatch -> receipt -> replan indefinitely.
  #
  # Held to the identical no-raise contract as `dispatch_semantic_compile/2`
  # above, for the identical reason (a misconfigured/failing LLM role must
  # become a typed reply, never crash the shared `A2A.Agent` process).
  defp replan(resource_or_domain, package, receipt) do
    try do
      case AshA2A.Semantic.Compiler.replan(resource_or_domain, package, receipt) do
        {:ok, next, _feedback} ->
          :ok = AshA2A.Semantic.PackageStore.put(next)
          AshA2A.Semantic.ExecutionPackage.to_reply(next)

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error ->
        {:error, %{code: :semantic_replan_failed, detail: Exception.message(error)}}
    end
  end

  defp dispatch_skill(resource_or_domain, message, history, auth_identity) do
    case resolve_skill_name(resource_or_domain, message) do
      {:ok, skill_name} ->
        case consequence(resource_or_domain, skill_name) do
          :observe ->
            AshA2A.Dispatcher.dispatch(
              skill_name,
              message,
              resource_or_domain,
              history,
              auth_identity
            )

          consequence when consequence in [:change, :external_do] ->
            command = build_command(resource_or_domain, skill_name, message, auth_identity)

            case AshA2A.CommandBus.run(command, message, resource_or_domain,
                   history: history,
                   auth_identity: auth_identity
                 ) do
              {:ok, %AshA2A.Receipt{reply: reply}} -> reply
              {:error, reason} -> {:error, reason}
            end

          :unknown ->
            {:error, %{code: :consequence_unclassified, capability_id: to_string(skill_name)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec consequence(module(), AshA2A.Dispatcher.skill_name()) :: AshA2A.Skill.consequence()
  defp consequence(resource_or_domain, skill_name) do
    case AshA2A.Info.skill(resource_or_domain, skill_name) do
      {:ok, %AshA2A.Skill{consequence: consequence}} when not is_nil(consequence) -> consequence
      _ -> :observe
    end
  end

  # Builds the real `AshA2A.Command` `CommandBus.run/4` admits. `principal`
  # is derived once and reused for both `principal_id` and the synthesized
  # `Authority`'s `subject`, since `Authority.admits?/2` requires
  # `authority.subject == command.principal_id` to match exactly --
  # `AshA2A.Identity.principal/1` normalizes any given value the same way on
  # every call, so two separate calls with the same `auth_identity` value
  # produce equal identities. An unauthenticated caller (`auth_identity` is
  # `nil`) still gets a `:principal` identity for the command (`"anonymous"`,
  # matching the literal value real `CommandBus` tests already use for an
  # unauthenticated `:read` command) but no `Authority` --
  # `Authority.Grant.authorize/3` returns `nil` for `nil`, which fails
  # `:change` admission closed as intended.
  #
  # AUTHORITY, NOT MERELY AUTHENTICATION (RFC-SA2A-001 S29). `capability_id`
  # below is CALLER-SUPPLIED -- it is `to_string(skill_name)`, taken off the
  # inbound message's own `skill` metadata. It is therefore routed through
  # `AshA2A.Authority.Grant.authorize/3`, which consults the configured
  # `AshA2A.Authority.Broker` for a real standing grant of THIS capability to
  # THIS principal, and NOT through `Authority.from_verified_identity/2`
  # directly. That function is a pure constructor: handed a caller-supplied
  # capability id it mints authority for exactly that capability, so
  # `CommandBus.admit/2`'s `Authority.admits?/2` check passed by
  # construction and every authenticated caller held authority for every
  # consequential skill on the agent card. `Grant.authorize/3` returns `nil`
  # when no grant stands, and `CommandBus.admit/2`'s existing
  # `:authority_required` refusal then fails the dispatch closed before any
  # actuation. `:observe` skills are unaffected (`admit/2` returns `:ok` for
  # them regardless of authority), and replay is unaffected: `authorize/3`
  # still builds the authority through `from_verified_identity/2`, whose
  # token id is the deterministic `Authority.grant_token_id/2` that
  # `Command.fingerprint/1` depends on.
  #
  # `command_id` is the real, canonical, protocol-native `A2A.Message.
  # message_id` (`~/xaas/deps/a2a/lib/a2a/message.ex:10-22,41,57` --
  # `A2A.ID.generate("msg")` when the caller supplies none, but a caller
  # retrying the same logical request after a dropped response is expected
  # to resend the SAME `message_id`, the same way any idempotency-key
  # convention works) rather than a fresh UUID generated here on every call.
  # This is what actually lets `CommandBus`'s existing replay/conflict
  # detection (`ReceiptStore.claim/2`, keyed on `command_id`, comparing
  # `command.fingerprint` against what a prior claim under that same id
  # recorded) engage for a real client retry arriving through the default
  # agent path: same `message_id` + same semantic command content (same
  # `capability_id`/`agent_id`/`principal_id`/`input`/authority token, all
  # of which `Command.fingerprint/1` hashes) replays the original receipt
  # instead of re-executing; same `message_id` with different semantic
  # content is a real `:command_conflict` refusal, never a silent
  # double-execution or a silently accepted divergent retry.
  #
  # GAP B real linkage: a caller may mark this dispatch as the real,
  # consequence-bearing "closing" command for a prior `AshA2A.Semantic.
  # ExecutionPackage` by ALSO setting `:continuation_fingerprint`/
  # `"continuation_fingerprint"` metadata (same `AshA2A.MetadataKey`
  # atom-then-string convention as `:skill`/`:semantic_request`) on this
  # ordinary skill-dispatch message, to that package's own
  # `"execution_package_fingerprint"`. When present, THAT fingerprint --
  # not `message.message_id` -- becomes this command's `command_id`, and is
  # also recorded in `Command.metadata["execution_package_fingerprint"]` for
  # auditability. This is the whole real correlation mechanism `AshA2A.Agent.
  # dispatch_semantic_replan/2` depends on: `AshA2A.ReceiptStore` only
  # supports lookup by `command_id` (`receipt_store.ex`), so choosing the
  # command_id to equal the fingerprint lets the EXISTING command_id-keyed
  # `store.fetch/2` resolve "the receipt for this execution package" with no
  # second, parallel index. `Command.fingerprint/1` (the real replay/conflict
  # digest) is computed from `agent_id`/`principal_id`/`task_id`/
  # `capability_id`/`input`/`authority_token` only -- never from
  # `command_id` -- so this override changes nothing about what counts as
  # "the same real command" for replay/conflict purposes; it only changes
  # WHERE that command's eventual receipt is filed. A real consequence falls
  # out of this for free, correctly: two genuinely different real closing
  # commands sent under the same `continuation_fingerprint` collide on this
  # same `command_id` and hit `CommandBus`'s existing same-id/different-
  # fingerprint `:command_conflict` refusal above -- only one real closing
  # dispatch may claim a given execution package this way, exactly the
  # single-writer semantics the correlation depends on.
  @spec build_command(module(), AshA2A.Dispatcher.skill_name(), A2A.Message.t(), term()) ::
          AshA2A.Command.t()
  defp build_command(resource_or_domain, skill_name, message, auth_identity) do
    capability_id = to_string(skill_name)
    principal = AshA2A.Identity.principal(auth_identity || "anonymous")
    {:ok, input} = AshA2A.Dispatcher.fetch_input(message)

    AshA2A.Command.new(capability_id,
      command_id: command_id(message),
      agent_id: to_string(resource_or_domain),
      principal_id: principal,
      authority: AshA2A.Authority.Grant.authorize(auth_identity, capability_id),
      input: input,
      metadata: command_metadata(message)
    )
  end

  defp command_id(%A2A.Message{metadata: metadata} = message) do
    case continuation_fingerprint(metadata) do
      nil -> message.message_id
      fingerprint -> fingerprint
    end
  end

  defp command_metadata(%A2A.Message{metadata: metadata}) do
    case continuation_fingerprint(metadata) do
      nil -> %{}
      fingerprint -> %{"execution_package_fingerprint" => fingerprint}
    end
  end

  defp continuation_fingerprint(metadata) do
    case AshA2A.MetadataKey.get(metadata || %{}, :continuation_fingerprint) do
      fingerprint when is_binary(fingerprint) and fingerprint != "" -> fingerprint
      _other -> nil
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

    case AshA2A.MetadataKey.get(metadata, :skill) do
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
