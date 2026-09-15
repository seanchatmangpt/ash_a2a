defmodule AshA2A.Planning.RequestRouter do
  @moduledoc """
  New default-routing entry point (impossible-item #2 of the design plan):
  a second, brand-new caller-opt-in metadata gate, sharing nothing with the
  existing `:semantic_request` surface (`AshA2A.Agent.__dispatch__`'s own
  inline design comment, `agent.ex:180-192`, is an explicit standing
  invariant this router is built to respect: "never a content sniff of
  unstructured text, never a fallback for an unrecognized skill name").

  ## Scope of this task (fifth task; do not extend without a design update)

  Task 1 added the core tier-detection heuristic plus a `route/3` skeleton
  whose text tier deliberately returned a typed "not wired" error. Task 2
  wired that text tier to its real backend. Task 3 added the dedicated
  "LLM never called" structural proof. Task 4 added real telemetry at
  `route/3`'s two real branch points, plus a real counter instrument
  (`AshA2A.Telemetry.RouterCounters`) built on that telemetry. This task
  (5) adds the design plan's tri-modal split's remaining middle tier: a
  bounded, deterministic, caller-registered structured-phrase parser
  (`AshA2A.Planning.PhraseParser`), wired in as `route/3`'s new second
  detection step -- it never replaces the facts tier or the LLM tier, both
  of which are unchanged, byte-for-byte, since task 4.

  All three tiers `route/3` can now reach are real, wired, production
  behavior (none is a placeholder):

    * **Facts tier** -> `AshA2A.Planning.HddlDeterministicSynthesis.synthesize/3`
      (zero-LLM deterministic solver path). Unchanged since task 1.
    * **Phrase tier** (new this task) -> a caller-registered
      `AshA2A.Planning.PhraseParser` template list matches the message's
      real text and deterministically turns it into a goal-facts envelope,
      fed into the exact same `HddlDeterministicSynthesis.synthesize/3`
      the facts tier already uses -- zero new solver logic, zero LLM call.
      The router ships zero built-in templates (`opts[:phrase_templates]`
      defaults to `[]`), so this tier is a strict no-op, unreachable by
      construction, for every existing caller that does not pass one.
    * **LLM (text) tier** -> `AshA2A.Semantic.Compiler.compile_source/3`
      (the real LLM-driven semantic-compilation pipeline), reached only
      when the phrase tier's own `PhraseParser.parse/2` returns `:no_match`
      (zero templates registered, zero templates matched, or two-or-more
      templates ambiguously matched) -- called exactly the same way task 2
      already wired it: a real `%Source{}` built from the text
      (`AshA2A.Semantic.Source.new/2`), then `compile_source/3` unchanged.

  Neither `Compiler`, `HddlDeterministicSynthesis`, nor `PhraseParser` is
  modified by this task's wiring -- each is called exactly as it already
  exists (`PhraseParser` is a brand-new module this same task adds, but
  `route/3` only ever calls its public `parse/2`, never reaches into its
  internals).

  At each of the three real branch points, `route/3` emits a real
  `[:ash_a2a, :router, :tier_selected]` event (`:telemetry.execute/3`,
  unchanged mechanism since task 4) with metadata
  `%{resource_or_domain:, tier: :facts | :phrase | :text}`, emitted right
  before delegating to the real downstream function. A phrase-tier match
  whose `to_envelope.(captures)` produced an invalid result (a raise, or a
  non-map) is a caller template bug, not a routing decision -- `route/3`
  returns that typed `{:error, %{code: :invalid_phrase_template}}`
  directly and emits no `:tier_selected` event for it, the same fail-closed
  treatment the pre-existing no-input branch already gets.

  `AshA2A.Telemetry.RouterCounters` (task 4) is unmodified by this task: it
  already ignores any `tier:` value other than `:facts`/`:text` rather than
  crashing (its own `handle_event/4`'s documented catch-all clause), so a
  `:phrase` event is safely, silently uncounted by that specific instrument
  today -- extending it to also count the phrase tier under the
  `:deterministic` slot is a natural, separate follow-on, not attempted
  here to keep this task's diff scoped to the router + parser wiring.

  Still explicitly NOT attempted here:

    * No telemetry is emitted on the `:error` (no-input or
      invalid-phrase-template, fail-closed) branches -- only the three real
      tier-dispatch branch points. A refusal counter remains a natural,
      separate follow-on (unchanged scope note from task 4).
    * This router ships zero built-in phrase templates. Every template
      exercised by this task's own tests is test-local, registered via
      `opts[:phrase_templates]` the same way a real host application would.

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

  `detect_tier/1` itself is unchanged since task 1 -- it still only
  discriminates facts vs. "has text" vs. neither. The phrase-vs-LLM split
  inside "has text" is a second, later step `route/3` performs itself
  (via `PhraseParser.parse/2`), not part of `detect_tier/1`'s own
  classification, so `detect_tier/1`'s return type and existing callers
  (including its own test suite) are unaffected by this task.

  Detection never raises and never calls the solver, the phrase parser, or
  an LLM -- it only inspects the message.
  """

  alias AshA2A.Dispatcher
  alias AshA2A.MetadataKey
  alias AshA2A.Planning.HddlDeterministicSynthesis
  alias AshA2A.Planning.PhraseParser
  alias AshA2A.Semantic.Compiler
  alias AshA2A.Semantic.Source

  @type tier_detection :: {:facts, map()} | {:text, String.t()} | :error | :invalid_goal_facts

  @doc """
  Classifies a real inbound `A2A.Message.t()` into a routing tier. See the
  moduledoc for the exact heuristic.

  A `goal_facts` key that is genuinely *absent* falls through to text
  detection, same as always. A `goal_facts` key that is *present* but not
  a map (a real, adversarially-found robustness gap: a caller sending
  `"goal_facts" => "not an object"` alongside real text was previously
  silently downgraded to the LLM tier instead of refused) now fails
  closed with `:invalid_goal_facts` instead -- a malformed structured
  payload is a caller error to surface, never a silent excuse to fall
  back to a different, less strict admission model.
  """
  @spec detect_tier(A2A.Message.t()) :: tier_detection()
  def detect_tier(%A2A.Message{} = message) do
    {:ok, input} = Dispatcher.fetch_input(message)

    case MetadataKey.fetch(input, :goal_facts) do
      {:ok, envelope} when is_map(envelope) ->
        {:facts, envelope}

      {:ok, _not_a_map} ->
        :invalid_goal_facts

      :error ->
        case A2A.Message.text(message) do
          text when is_binary(text) and text != "" -> {:text, text}
          _no_text -> :error
        end
    end
  end

  @doc """
  Tri-modal router: facts tier -> the real deterministic solver, phrase
  tier -> the same real deterministic solver (via a caller-registered
  `AshA2A.Planning.PhraseParser` template match), text tier -> the real
  LLM-driven semantic compiler. `opts`:

    * `:solver_opts` -- facts tier and phrase tier. Forwarded verbatim to
      `HddlDeterministicSynthesis.synthesize/3`. Default `[]`.
    * `:phrase_templates` -- phrase tier only. A list of
      `AshA2A.Planning.PhraseParser.template()`s tried, in order, against
      the message's real text before falling through to the LLM tier.
      Default `[]` -- this router ships zero built-in templates, so the
      phrase tier is unreachable unless a caller explicitly registers at
      least one.
    * `:source_opts` -- text (LLM) tier only. Forwarded verbatim to
      `AshA2A.Semantic.Source.new/2` when building the `%Source{}` for the
      detected text. Default `[]`.
    * Everything else (e.g. `:generate_object`, `:plan_generate_object`,
      `:role`, `:planning_role`, `:persona_context`) -- text (LLM) tier
      only. Forwarded verbatim to `Compiler.compile_source/3`, which is
      where each of those opts is actually documented and consumed;
      `route/3` does not inspect or default any of them itself.

  Detection order, per message:

    1. **Facts tier.** `detect_tier/1` finds a real `goal_facts` envelope
       -> `HddlDeterministicSynthesis.synthesize/3` directly. Unchanged
       since task 1.
    2. **Phrase tier.** `detect_tier/1` finds real text, and
       `PhraseParser.parse(opts[:phrase_templates] || [], text)` returns
       `{:ok, envelope}` (exactly one caller-registered template matched)
       -> that envelope is fed into the exact same
       `HddlDeterministicSynthesis.synthesize/3` the facts tier uses. A
       template match whose `to_envelope` was itself invalid
       (`{:error, %{code: :invalid_phrase_template}}`) is returned
       directly -- a caller's own template bug fails closed, it is never
       silently retried against the LLM tier.
    3. **LLM (text) tier.** `PhraseParser.parse/2` returned `:no_match`
       (no templates registered, no template matched, or two-or-more
       templates ambiguously matched) -> the real, unchanged
       `Compiler.compile_source/3` pipeline, via a real `%Source{}` built
       the same way `Compiler.compile/3` builds one internally.
    4. **No input.** `detect_tier/1` found neither facts nor text -> fails
       closed with a typed error rather than guessing at a tier.

  None of `HddlDeterministicSynthesis`, `PhraseParser`, or `Compiler` is
  modified by this router -- each is called exactly as it already exists.
  """
  @spec route(module(), A2A.Message.t(), keyword()) ::
          {:ok, AshA2A.Semantic.ExecutionPackage.t()} | {:error, map()}
  def route(resource_or_domain, %A2A.Message{} = message, opts \\ []) do
    case detect_tier(message) do
      {:facts, envelope} ->
        emit_tier_selected(resource_or_domain, :facts)
        synthesize(resource_or_domain, envelope, opts)

      {:text, text} ->
        route_text(resource_or_domain, text, opts)

      :invalid_goal_facts ->
        {:error, %{code: :invalid_goal_facts}}

      :error ->
        {:error, %{code: :request_router_missing_input}}
    end
  end

  # Tier 2 (phrase) vs. tier 3 (LLM) split for a message real `detect_tier/1`
  # already classified as "has text": tried in that order, never both, and
  # a template-authoring bug on the sole matching template fails closed
  # rather than silently retrying against the LLM.
  @spec route_text(module(), String.t(), keyword()) ::
          {:ok, AshA2A.Semantic.ExecutionPackage.t()} | {:error, map()}
  defp route_text(resource_or_domain, text, opts) do
    templates = Keyword.get(opts, :phrase_templates, [])

    case PhraseParser.parse(templates, text) do
      {:ok, envelope} ->
        emit_tier_selected(resource_or_domain, :phrase)
        synthesize(resource_or_domain, envelope, opts)

      :no_match ->
        emit_tier_selected(resource_or_domain, :text)

        source = Source.new(text, Keyword.get(opts, :source_opts, []))
        Compiler.compile_source(resource_or_domain, source, opts)

      {:error, %{code: :invalid_phrase_template}} = error ->
        error
    end
  end

  @spec synthesize(module(), map(), keyword()) ::
          {:ok, AshA2A.Semantic.ExecutionPackage.t()} | {:error, map()}
  defp synthesize(resource_or_domain, envelope, opts) do
    HddlDeterministicSynthesis.synthesize(
      resource_or_domain,
      envelope,
      solver_opts: Keyword.get(opts, :solver_opts, [])
    )
  end

  # Real point-in-time `:telemetry.execute/3` at each of the three real
  # branch points above, emitted before delegating to the real downstream
  # function so a handler observes the routing decision itself even if the
  # downstream call later fails. `:tier_selected` is the sole event this
  # module emits; `AshA2A.Telemetry.RouterCounters` is the reference
  # consumer (it counts `:facts` as deterministic, `:text` as llm, and
  # safely ignores `:phrase` today -- see this module's own moduledoc).
  @spec emit_tier_selected(module(), :facts | :phrase | :text) :: :ok
  defp emit_tier_selected(resource_or_domain, tier) when tier in [:facts, :phrase, :text] do
    :telemetry.execute(
      [:ash_a2a, :router, :tier_selected],
      %{},
      %{resource_or_domain: resource_or_domain, tier: tier}
    )
  end
end
