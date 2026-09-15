defmodule AshA2A.Planning.RequestRouter do
  @moduledoc """
  New default-routing entry point (impossible-item #2 of the design plan):
  a second, brand-new caller-opt-in metadata gate, sharing nothing with the
  existing `:semantic_request` surface (`AshA2A.Agent.__dispatch__`'s own
  inline design comment, `agent.ex:180-192`, is an explicit standing
  invariant this router is built to respect: "never a content sniff of
  unstructured text, never a fallback for an unrecognized skill name").

  ## Scope of this task (fourth task; do not extend without a design update)

  Task 1 added the core tier-detection heuristic plus a `route/3` skeleton
  whose text tier deliberately returned a typed "not wired" error. Task 2
  wired that text tier to its real backend. Task 3 added the dedicated
  "LLM never called" structural proof. This task (4) adds real telemetry
  at `route/3`'s two real branch points, plus a real counter instrument
  (`AshA2A.Telemetry.RouterCounters`) built on that telemetry.

  Both tiers `route/3` can detect are real, wired, production behavior
  (neither is a placeholder):

    * **Facts tier** -> `AshA2A.Planning.HddlDeterministicSynthesis.synthesize/3`
      (zero-LLM deterministic solver path). Unchanged since task 1.
    * **Text tier** -> `AshA2A.Semantic.Compiler.compile_source/3` (the
      real LLM-driven semantic-compilation pipeline), called the same way
      `Compiler.compile/3` calls it internally: a real `%Source{}` is
      built from the text first (`AshA2A.Semantic.Source.new/2`), then
      passed to `compile_source/3` unchanged. Neither `Compiler` nor
      `HddlDeterministicSynthesis` is modified by this task -- both are
      called exactly as they already exist.

  At each of those two branch points, `route/3` now emits a real
  `[:ash_a2a, :router, :tier_selected]` event
  (`:telemetry.execute/3`, matching the plain-execute style
  `AshA2A.Agent.__cancel__/2` and `AshA2A.CommandBus.run/4` already use for
  a point-in-time event, rather than a `:telemetry.span/3`) with metadata
  `%{resource_or_domain:, tier: :facts | :text}`, emitted right before
  delegating to the real downstream function -- this is the real,
  buildable answer to impossible-item #6: this codebase cannot know a real
  Fortune-5 deployment's actual deterministic-vs-LLM request split, but it
  can, and here does, build the instrument that would measure it in one.
  `AshA2A.Telemetry.RouterCounters` is a real, in-process `:counters`-backed
  aggregator a caller attaches to that same event to answer exactly that
  question for a real running deployment; see its own moduledoc.

  Still explicitly NOT wired in, left to a later task:

    * The phrasing parser -- `AshA2A.Planning.PhraseParser` does not exist
      yet, so there is no phrase-tier disambiguation between a templated
      short phrase and genuinely free text: every detected `:text` tier
      request goes straight to the LLM tier. This is a real, coarser
      two-tier router (facts vs. text), not the design plan's eventual
      tri-modal (facts / phrase / LLM) split.
    * No telemetry is emitted on the `:error` (no-input, fail-closed)
      branch -- only the two real tier-dispatch branch points this task
      was scoped to. A refusal counter is a natural, separate follow-on,
      not attempted here.

  ## Detection heuristic

  Given a real `A2A.Message.t()`, `detect_tier/1` classifies it, cheapest
  and most-specific check first:

    1. **Facts tier.** The message's real input data part
       (`AshA2A.Dispatcher.fetch_input/1`) carries a `:goal_facts`/
       `"goal_facts"` key (`AshA2A.MetadataKey.fetch/2`'s existing
       atom-then-string convention, the same one `:skill`/
       `:semantic_request`/`:continuation_fingerprint` metadata already
       use) whose value is itself a map. Returns `{:facts, envelope}`.
    2. **Text tier.** No `goal_facts` map, but the message carries real
       text (`A2A.Message.text/1` returns a non-nil, non-empty string).
       Returns `{:text, text}`.
    3. **No input.** Neither of the above. Returns `:error`.

  This is exactly the design plan's inner 3-way split's first
  discriminator (facts vs. "has text"); it deliberately stops one level
  short of splitting "has text" further into phrase-tier vs. LLM-tier,
  which is the `AshA2A.Planning.PhraseParser`-dependent part of the split
  a later task adds.

  Detection never raises and never calls the solver, a phrase parser, or
  an LLM -- it only inspects the message.
  """

  alias AshA2A.Dispatcher
  alias AshA2A.MetadataKey
  alias AshA2A.Planning.HddlDeterministicSynthesis
  alias AshA2A.Semantic.Compiler
  alias AshA2A.Semantic.Source

  @type tier_detection :: {:facts, map()} | {:text, String.t()} | :error

  @doc """
  Classifies a real inbound `A2A.Message.t()` into a routing tier. See the
  moduledoc for the exact heuristic.
  """
  @spec detect_tier(A2A.Message.t()) :: tier_detection()
  def detect_tier(%A2A.Message{} = message) do
    {:ok, input} = Dispatcher.fetch_input(message)

    case MetadataKey.fetch(input, :goal_facts) do
      {:ok, envelope} when is_map(envelope) ->
        {:facts, envelope}

      _no_facts_envelope ->
        case A2A.Message.text(message) do
          text when is_binary(text) and text != "" -> {:text, text}
          _no_text -> :error
        end
    end
  end

  @doc """
  Two-tier router: facts tier -> the real deterministic solver, text tier
  -> the real LLM-driven semantic compiler. `opts`:

    * `:solver_opts` -- facts tier only. Forwarded verbatim to
      `HddlDeterministicSynthesis.synthesize/3`. Default `[]`.
    * `:source_opts` -- text tier only. Forwarded verbatim to
      `AshA2A.Semantic.Source.new/2` when building the `%Source{}` for the
      detected text. Default `[]`.
    * Everything else (e.g. `:generate_object`, `:plan_generate_object`,
      `:role`, `:planning_role`, `:persona_context`) -- text tier only.
      Forwarded verbatim to `Compiler.compile_source/3`, which is where
      each of those opts is actually documented and consumed; `route/3`
      does not inspect or default any of them itself.

  Neither downstream function is modified by this router: the facts tier
  calls the real, unchanged `HddlDeterministicSynthesis.synthesize/3`; the
  text tier calls the real, unchanged `Compiler.compile_source/3` (via a
  real `%Source{}` built the same way `Compiler.compile/3` builds one
  internally). A message with neither typed facts nor text fails closed
  with a typed error rather than guessing at a tier.
  """
  @spec route(module(), A2A.Message.t(), keyword()) ::
          {:ok, AshA2A.Semantic.ExecutionPackage.t()} | {:error, map()}
  def route(resource_or_domain, %A2A.Message{} = message, opts \\ []) do
    case detect_tier(message) do
      {:facts, envelope} ->
        emit_tier_selected(resource_or_domain, :facts)

        HddlDeterministicSynthesis.synthesize(
          resource_or_domain,
          envelope,
          solver_opts: Keyword.get(opts, :solver_opts, [])
        )

      {:text, text} ->
        emit_tier_selected(resource_or_domain, :text)

        source = Source.new(text, Keyword.get(opts, :source_opts, []))
        Compiler.compile_source(resource_or_domain, source, opts)

      :error ->
        {:error, %{code: :request_router_missing_input}}
    end
  end

  # Real point-in-time `:telemetry.execute/3` at each of the two real
  # branch points above, emitted before delegating to the real downstream
  # function so a handler observes the routing decision itself even if the
  # downstream call later fails. `:tier_selected` is the sole event this
  # module emits; `AshA2A.Telemetry.RouterCounters` is the reference
  # consumer.
  @spec emit_tier_selected(module(), :facts | :text) :: :ok
  defp emit_tier_selected(resource_or_domain, tier) when tier in [:facts, :text] do
    :telemetry.execute(
      [:ash_a2a, :router, :tier_selected],
      %{},
      %{resource_or_domain: resource_or_domain, tier: tier}
    )
  end
end
