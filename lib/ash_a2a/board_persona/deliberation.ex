defmodule AshA2A.BoardPersona.Deliberation do
  @moduledoc """
  Fans one real scenario text out across the 3 real board-persona archetypes
  (`AshA2A.BoardPersona.RiskAverseFiduciary`,
  `AshA2A.BoardPersona.GrowthFocusedFounderLed`,
  `AshA2A.BoardPersona.ActivistPressured`) and returns a real, per-persona
  compiled result plus a real, honestly-counted split of what was actually
  admitted -- never a fabricated consensus score.

  A plain module, not an Ash resource: it composes 3 existing real
  primitives (`AshA2A.Semantic.Compiler.compile/3` against each persona
  resource) rather than owning any state of its own. Each persona's compile
  call is real, independent, and admitted against that persona's OWN real,
  closed `AshA2A.Info.capability_index/1` -- there is no shared/merged
  capability set and no cross-persona leakage; a capability synthesized for
  one persona can never resolve against another persona's action set,
  because `AshA2A.Planning.SemanticSynthesis.synthesize/4` re-derives
  `capability_ids/1` from whatever `resource_or_domain` this module passes
  it, per-call.

  Concurrency reuses the exact real `Task.async_stream/3` pattern
  `AshA2A.Semantic.Compiler.compile_many/3` already establishes: `ordered:
  true` and `timeout: :infinity` (per-worker; any overall wall-clock budget
  is the caller's own concern, e.g. an `ExUnit` `@tag timeout:` on the
  calling test process), with each worker rescuing its own raised
  exception into a typed `{:error, %{code: :semantic_worker_exit, ...}}`
  result at its own slot so one persona's crash cannot take down the whole
  fan-out or its caller (`Task.async_stream/3` links each worker to the
  calling process by default).

  Receipting/standing: every result here stays candidate-standing
  (`authority: :none`), exactly like every other real use of
  `AshA2A.Semantic.Compiler` -- this module never auto-DOes anything. A real
  board decision, if one should actually execute, is a distinct, later,
  explicit dispatch a caller performs against the admitted `capability_ids`
  via `AshA2A.CommandBus`, same pattern the existing semantic-request
  surface already uses.
  """

  alias AshA2A.BoardPersona.{ActivistPressured, GrowthFocusedFounderLed, RiskAverseFiduciary}
  alias AshA2A.Semantic.Compiler

  @personas [RiskAverseFiduciary, GrowthFocusedFounderLed, ActivistPressured]

  # Each persona's real, cited decision-making lens -- see each resource's
  # own moduledoc for the full citation. Kept here (rather than as a
  # function on each persona resource) because no such per-persona callback
  # convention exists yet on `AshA2A.BoardPersona.RiskAverseFiduciary` (the
  # first, already-committed persona) -- this module is the one real,
  # additive place a lens-per-persona mapping was introduced, so all three
  # personas are treated identically rather than two of three gaining a new
  # convention the first one lacks.
  @persona_context %{
    RiskAverseFiduciary => """
    You are a risk-averse fiduciary board member, reasoning from agency
    theory (Jensen & Meckling, 1976) and the COSO Enterprise Risk Management
    framework's distinction between risk appetite and risk tolerance. You
    weigh downside/liability exposure heavily and prefer to gather more
    information, defer, reject, or approve only with explicit conditions --
    never an unconditional approval.
    """,
    GrowthFocusedFounderLed => """
    You are a growth-focused, founder-led board member, reasoning from
    Wasserman's "The Founder's Dilemmas" (2012) framing of founders'
    real, observed preference for growth and control retention over
    conservative risk minimization. You favor approving or conditionally
    approving proposals that advance growth, and only ask for more data
    rather than flatly refusing.
    """,
    ActivistPressured => """
    You are a board member under real activist-investor pressure, reasoning
    from Brav, Jiang, Partnoy & Thomas (2008, Journal of Finance) on how
    activist campaigns push boards toward decisive binary outcomes. You
    approve or reject decisively, and when the board and the pressure
    cannot converge internally, you escalate the matter to a shareholder
    vote rather than deferring indefinitely.
    """
  }

  @type persona_result :: {:ok, AshA2A.Semantic.ExecutionPackage.t()} | {:error, term()}
  @type split :: %{
          approve_shaped: non_neg_integer(),
          other: non_neg_integer(),
          errored: non_neg_integer()
        }

  @doc "The 3 real persona resource modules this module fans a scenario out across."
  @spec personas() :: [module()]
  def personas, do: @personas

  @doc """
  Compiles `scenario_text` through each of the 3 real persona resources'
  own closed capability sets, concurrently, and returns a real
  `%{persona_module => persona_result}` map plus a real, counted `split` of
  how many personas' synthesized `capability_ids` resolve to an
  approve-shaped action (an action whose own real name starts with
  `"approve"` -- covers both `:approve` and `:approve_with_conditions`, the
  only two real action-name shapes across all 3 personas' closed action
  sets that mean "some form of approval") vs not, vs errored outright.

  `opts` is forwarded to each real `AshA2A.Semantic.Compiler.compile/3`
  call (e.g. `:generate_object` / `:plan_generate_object` test seams,
  `:max_concurrency`) -- the same real options that pipeline already
  accepts; this module adds no new option shape of its own beyond
  `:max_concurrency` (defaulted to one worker per persona, matching the
  bounded, known-size fan-out here -- unlike `compile_many/3`'s
  caller-supplied-list case).
  """
  @spec deliberate(String.t(), keyword()) :: %{
          results: %{module() => persona_result()},
          split: split()
        }
  def deliberate(scenario_text, opts \\ []) when is_binary(scenario_text) do
    concurrency = Keyword.get(opts, :max_concurrency, length(@personas))

    stream_results =
      Task.async_stream(@personas, &compile_for_persona(&1, scenario_text, opts),
        max_concurrency: concurrency,
        ordered: true,
        timeout: :infinity
      )

    results =
      @personas
      |> Enum.zip(stream_results)
      |> Map.new(fn
        {persona, {:ok, result}} ->
          {persona, result}

        {persona, {:exit, reason}} ->
          {persona, {:error, %{code: :semantic_worker_exit, detail: reason}}}
      end)

    %{results: results, split: split(results)}
  end

  defp compile_for_persona(persona, scenario_text, opts) do
    persona_context = Map.fetch!(@persona_context, persona)
    compile_opts = Keyword.put(opts, :persona_context, persona_context)
    Compiler.compile(persona, scenario_text, compile_opts)
  rescue
    error ->
      {:error,
       %{code: :semantic_worker_exit, detail: Exception.format(:error, error, __STACKTRACE__)}}
  end

  defp split(results) do
    Enum.reduce(results, %{approve_shaped: 0, other: 0, errored: 0}, fn
      {_persona, {:ok, package}}, acc ->
        capability_ids = package.plan_candidate.capability_ids

        if Enum.any?(capability_ids, &approve_shaped?/1) do
          Map.update!(acc, :approve_shaped, &(&1 + 1))
        else
          Map.update!(acc, :other, &(&1 + 1))
        end

      {_persona, {:error, _}}, acc ->
        Map.update!(acc, :errored, &(&1 + 1))
    end)
  end

  # A capability id is a real, fully-qualified `<Resource>.<action>` identity
  # (`AshA2A.CapabilityIndex.Compiler`); action names never contain `.`, so
  # the segment after the final `.` is always the real action name.
  defp approve_shaped?(capability_id) when is_binary(capability_id) do
    capability_id
    |> String.split(".")
    |> List.last()
    |> String.starts_with?("approve")
  end
end
