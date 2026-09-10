defmodule AshA2A.Agent do
  @moduledoc """
  Generates a real, runnable `A2A.Agent` GenServer for an `AshA2A`-extended
  resource or domain, so a compiled capability index has an actual supervised
  process a caller can send an `A2A.Message` to -- not just a synchronous
  `AshA2A.Dispatcher.dispatch/3` function call.

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
  `AshA2A.Dispatcher.dispatch/3` path (PRD §3.2/§3.5), so an agent process
  built with this macro can never diverge from what `AshA2A.Info.agent_card/2`
  advertises.
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
      def handle_message(message, _context) do
        AshA2A.Agent.__dispatch__(@ash_a2a_resource_or_domain, message)
      end

      defoverridable handle_message: 2
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
  @spec __dispatch__(module(), A2A.Message.t()) :: AshA2A.Dispatcher.reply()
  def __dispatch__(resource_or_domain, %A2A.Message{} = message) do
    case resolve_skill_name(resource_or_domain, message) do
      {:ok, skill_name} -> AshA2A.Dispatcher.dispatch(skill_name, message, resource_or_domain)
      {:error, reason} -> {:error, reason}
    end
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
