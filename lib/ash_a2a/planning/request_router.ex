defmodule AshA2A.Planning.RequestRouter do
  @moduledoc """
  New default-routing entry point (impossible-item #2 of the design plan):
  a second, brand-new caller-opt-in metadata gate, sharing nothing with the
  existing `:semantic_request` surface (`AshA2A.Agent.__dispatch__`'s own
  inline design comment, `agent.ex:180-192`, is an explicit standing
  invariant this router is built to respect: "never a content sniff of
  unstructured text, never a fallback for an unrecognized skill name").

  ## Scope of this task (first task; do not extend without a design update)

  This task implements only the **core tier-detection heuristic** plus a
  module skeleton for the eventual tri-modal `route/3`. Explicitly NOT
  wired in yet, both left to later tasks:

    * The phrasing parser -- `AshA2A.Planning.PhraseParser` does not exist
      yet. A detected `:text` tier request is not further parsed or routed
      to an LLM by this module.
    * Telemetry -- no `[:ash_a2a, :router, ...]` events are emitted here.

  `route/3`'s facts-tier branch below is real, wired, production behavior
  (not a placeholder): the facts tier already has a real, existing,
  zero-LLM deterministic backend
  (`AshA2A.Planning.HddlDeterministicSynthesis.synthesize/3`), so
  delegating to it is genuine functionality, unlike the text tier, which
  has no backend to delegate to yet.

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
  Module skeleton for the full tri-modal router (design plan's
  `RequestRouter` task). `opts`:

    * `:solver_opts` -- forwarded verbatim to
      `HddlDeterministicSynthesis.synthesize/3` for the facts tier.
      Default `[]`.

  Only the facts tier is wired to a real synthesis backend in this task.
  The text tier deliberately returns a typed
  `:request_router_text_tier_not_wired` error until a later task adds the
  phrase parser (checked first) and the LLM tier (checked second) --
  returning this now rather than guessing at either.
  """
  @spec route(module(), A2A.Message.t(), keyword()) ::
          {:ok, AshA2A.Semantic.ExecutionPackage.t()} | {:error, map()}
  def route(resource_or_domain, %A2A.Message{} = message, opts \\ []) do
    case detect_tier(message) do
      {:facts, envelope} ->
        HddlDeterministicSynthesis.synthesize(
          resource_or_domain,
          envelope,
          solver_opts: Keyword.get(opts, :solver_opts, [])
        )

      {:text, _text} ->
        {:error, %{code: :request_router_text_tier_not_wired}}

      :error ->
        {:error, %{code: :request_router_missing_input}}
    end
  end
end
