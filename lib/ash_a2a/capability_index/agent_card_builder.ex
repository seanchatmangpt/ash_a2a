defmodule AshA2A.CapabilityIndex.AgentCardBuilder do
  @moduledoc """
  Builds a real `A2A.AgentCard.t()` from a compiled A2A capability index.

  Extracted from `AshA2A.CapabilityIndex` (which remains the public facade
  and delegates `build_agent_card/2` here) to separate this module's concern
  -- wire-format AgentCard construction -- from `CapabilityIndex`'s other,
  unrelated concern (`Validator`'s business-rule checking).

  Per the ARD (§3.2), `AshA2A.Info.agent_card/1` is expected to call this
  function against the persisted index only -- never raw DSL entities -- so
  the advertised card and the dispatch table can never diverge.

  `A2A.AgentCard` struct fields/types are taken verbatim from
  `~/xaas/deps/a2a/lib/a2a/agent_card.ex:16-76`; this module builds no field
  that struct doesn't define. `:name`, `:description`, `:url`, and `:version`
  come from `opts` since the compiled index carries no agent-identity
  metadata -- only skill/action mappings.
  """

  @type skill :: AshA2A.Skill.t()

  @doc """
  Builds a real `A2A.AgentCard.t()` from the persisted, verified capability
  index (a list of compiled skill maps, the same shape `Validator.validate/1`
  checks).

  ## Options

    * `:name` -- agent card name (default: `"ash_a2a_agent"`)
    * `:description` -- agent card description (default derived from skill count)
    * `:url` -- agent's base URL (default: `"http://localhost:4000"`)
    * `:version` -- agent card version (default: `"0.1.0"`)
    * `:provider` -- `A2A.AgentCard.provider()` map, or `nil` (default: `nil`)
    * `:security_schemes` -- `%{String.t() => A2A.SecurityScheme.t()}` map of
      named security scheme definitions (default: `%{}`)
    * `:security` -- `[%{String.t() => [String.t()]}]` list of security
      requirement alternatives referencing the names in `:security_schemes`
      (default: `[]`)
    * `:supported_interfaces` -- `[A2A.AgentCard.supported_interface()]` list
      of `%{url:, protocol_binding:, protocol_version:}` maps (default: a
      single real entry derived from the `:url` option -- see below)

  ### Why `:supported_interfaces` defaults to a derived entry, not `[]`

  Unlike `:security_schemes` (no fabricated default, see above), the current
  proto marks `supported_interfaces` `[REQUIRED]`. Leaving it `[]` would mean
  every card this library builds is silently proto-nonconformant on a
  required field, when a real, non-fabricated value is directly derivable:
  the agent is already reachable at `:url` over JSON-RPC (this library's own
  dispatch, `AshA2A.Verify`/`AshA2A.Info`, is JSON-RPC-based), so the default
  is one real `A2A.AgentCard.supported_interface()` entry --
  `%{url: <the :url option>, protocol_binding: "JSONRPC", protocol_version:
  "0.3.0"}` -- not an invented endpoint. A caller that serves additional
  transports (gRPC, HTTP+JSON REST) should pass `:supported_interfaces`
  explicitly to describe them; this default only asserts the one real
  interface the library can already prove exists.

  ### Why `:security_schemes` defaults to `%{}` (no fabricated default scheme)

  `build_agent_card/2` deliberately does *not* synthesize a default
  `A2A.SecurityScheme.t()` (e.g. an assumed `%HTTPAuth{scheme: "bearer"}`) the
  way it synthesizes `:name`/`:url`/`:version`. Authentication enforcement for
  an A2A agent lives entirely outside this library, in a separately-configured
  `A2A.Plug.Auth` pipeline plug (`~/xaas/deps/a2a/lib/a2a/plug/auth.ex:6-32`):
  the embedding application chooses its own `schemes:` map and `verify:`
  callback there, independent of anything `ash_a2a` compiles. `AshA2A` has no
  introspectable signal for whether that plug is even in the pipeline, let
  alone which scheme(s) it enforces -- there is no real fact in the compiled
  capability index (skill/resource/action tuples only) to derive a security
  scheme from.

  Advertising a synthesized scheme here (e.g. defaulting to bearer auth) would
  therefore either (a) claim security that isn't actually enforced by any
  plug, if the author never wired `A2A.Plug.Auth`, or (b) claim the wrong
  scheme, if the author wired one with different scheme names -- both are
  worse than advertising no security requirement. `A2A.AgentCard.security` is
  public wire-format metadata a remote caller may rely on to decide how to
  authenticate; fabricating it here would be exactly the kind of unsourced
  fact this codebase's evidence-forcing discipline forbids.

  The real fix is opt-in, not a default: an application that *does* configure
  `A2A.Plug.Auth` should pass matching `:security_schemes`/`:security` opts to
  `build_agent_card/2` (the same scheme names/types used in its `schemes:`
  map), so the advertised card and the enforced pipeline agree by construction
  rather than by accident.

  ## Examples

      iex> skills = AshA2A.Info.capability_index(AshA2A.Test.Fixture.Echo)
      iex> card = AshA2A.CapabilityIndex.AgentCardBuilder.build_agent_card(skills, name: "echo_agent")
      iex> {card.name, card.version, card.url}
      {"echo_agent", "0.1.0", "http://localhost:4000"}
      iex> [%{id: "echo", name: "echo"}] = card.skills
      iex> card.skills
      [%{id: "echo", name: "echo", description: "read action :read on AshA2A.Test.Fixture.Echo (no arguments)", tags: ["read"]}]

      iex> AshA2A.CapabilityIndex.AgentCardBuilder.build_agent_card([]).description
      "Ash-backed A2A agent exposing 0 skill(s)."

  """
  @spec build_agent_card([skill()], keyword()) :: A2A.AgentCard.t()
  def build_agent_card(skills, opts \\ []) when is_list(skills) do
    url = Keyword.get(opts, :url, "http://localhost:4000")

    %A2A.AgentCard{
      name: Keyword.get(opts, :name, "ash_a2a_agent"),
      description:
        Keyword.get(
          opts,
          :description,
          "Ash-backed A2A agent exposing #{length(skills)} skill(s)."
        ),
      url: url,
      version: Keyword.get(opts, :version, "0.1.0"),
      skills: Enum.map(skills, &build_agent_card_skill/1),
      provider: Keyword.get(opts, :provider),
      security_schemes: Keyword.get(opts, :security_schemes, %{}),
      security: Keyword.get(opts, :security, []),
      supported_interfaces:
        Keyword.get(opts, :supported_interfaces, [default_supported_interface(url)])
    }
  end

  # A real, non-fabricated `A2A.AgentCard.supported_interface()` entry: the
  # agent's own `:url`, advertised over the JSON-RPC binding this library's
  # dispatch actually speaks -- see moduledoc for why this is derived rather
  # than left `[]`.
  @spec default_supported_interface(String.t()) :: A2A.AgentCard.supported_interface()
  defp default_supported_interface(url) do
    %{url: url, protocol_binding: "JSONRPC", protocol_version: "0.3.0"}
  end

  @spec build_agent_card_skill(skill()) :: A2A.AgentCard.skill()
  defp build_agent_card_skill(%{name: name, resource: resource, action: action}) do
    real_action = Ash.Resource.Info.action(resource, action)

    %{
      id: to_string(name),
      name: to_string(name),
      description: skill_description(resource, action, real_action),
      tags: skill_tags(action, real_action)
    }
  end

  # `real_action` is `nil` only when a skill names a resource/action pair
  # `AshA2A.CapabilityIndex.Validator.validate/1` has already flagged as
  # `:REFUSED_ACTION_NOT_FOUND` -- `AshA2A.Verify` runs `validate/1` before
  # any card is ever built from this index, so this clause exists only as a
  # defensive fallback, never as an expected path in a compiled resource.
  defp skill_tags(action, nil), do: [to_string(action)]

  defp skill_tags(_action, real_action) do
    [real_action.type |> to_string()]
    |> Kernel.++(Enum.map(input_names(real_action), &to_string/1))
    |> Enum.uniq()
  end

  defp skill_description(resource, action, nil) do
    "Dispatches to #{inspect(resource)}.#{action}/*"
  end

  defp skill_description(resource, _action, real_action) do
    inputs = input_names(real_action)

    inputs_clause =
      case inputs do
        [] -> "no arguments"
        names -> "arguments: #{Enum.map_join(names, ", ", &to_string/1)}"
      end

    base =
      case real_action.description do
        nil -> "#{real_action.type} action #{inspect(real_action.name)} on #{inspect(resource)}"
        description -> description
      end

    "#{base} (#{inputs_clause})"
  end

  # Real user-supplied inputs to the action: its declared `arguments`
  # (`Ash.Resource.Actions.Argument.t()`, present on every action type --
  # `~/xaas/deps/ash/lib/ash/resource/actions/argument.ex:5-17`) plus, for
  # create/update actions, the accepted attribute names
  # (`~/xaas/deps/ash/lib/ash/resource/actions/create.ex:13`,
  # `accept: nil | list(atom)` -- `nil` means "not yet compiled", which
  # `Ash.Resource.Info.action/2` never returns since it reads the fully
  # compiled DSL state).
  defp input_names(real_action) do
    argument_names = Enum.map(Map.get(real_action, :arguments, []), & &1.name)
    accept_names = real_action |> Map.get(:accept) |> List.wrap()

    argument_names ++ accept_names
  end
end
