# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Planning.PhraseParser do
  @moduledoc """
  Bounded, narrow, deterministic phrasing parser -- the design plan's
  "structured-phrase" middle tier, sitting between the facts tier
  (`AshA2A.Planning.GoalFacts`/`HddlDeterministicSynthesis`) and the LLM
  tier (`AshA2A.Semantic.Compiler`) in `AshA2A.Planning.RequestRouter`.

  This module owns exactly one thing: matching free text against a
  **caller-registered** list of `{regex, to_envelope}` templates and, on
  exactly one unambiguous match, turning the match's named captures into a
  goal-facts envelope via the template's own `to_envelope` function. It
  ships **zero built-in templates** -- every template a caller registers is
  the caller's own, explicit, testable choice; this module never guesses
  at, generalizes, or verb-matches free text on its own.

  ## Why this is bounded, not a general parser

  A real corpus investigation over this repo's own free-text fixtures and
  docs (`test/ash_a2a_agent_semantic_replan_test.exs`'s `"create a labeled
  item[, ... variant]"` family, `docs/how-to/enable-semantic-requests.md`'s
  `"advance the admitted workflow"` example) found exactly one reusable
  literal phrase family, both test/doc-local -- hardcoding either into this
  library would bake a fixture's own phrasing into production code, so
  neither ships here. The same investigation found that naive
  verb-generalization (matching on `\\b(create|read|advance)\\b`-style
  patterns) produces real false positives against genuine free prose in
  this same repo -- `"The goal is to read the people."`
  (`test/ash_a2a/semantic_compiler_test.exs:51`) and `"advance the admitted
  workflow"` (`docs/how-to/enable-semantic-requests.md:69`) both contain a
  bare governing verb a naive matcher would seize on. This module never
  does that: matching is always against a caller's own, fully-anchored,
  caller-authored regex -- never a bare keyword/verb scan.

  ## Contract

    * Each `template()` is `%{regex: Regex.t(), to_envelope: (map() -> map())}`.
      The regex is expected to describe the *entire* structured phrase (the
      caller is expected to anchor it with `^`/`$`); `parse/2` independently
      enforces that a template only counts as a match when its regex's own
      full match spans the entire input string, so an unanchored caller
      regex that merely happens to appear as a substring of a longer,
      unrelated sentence can never silently count as a match.
    * Extraction is *only* ever `Regex.named_captures/2` -- no positional
      captures, no ad hoc string slicing.
    * Zero templates match -> `:no_match`. Ambiguity (two or more templates
      independently match the same full text) is refused the same way,
      `:no_match` -- this module never picks a "best" match; both cases are
      indistinguishable to a caller by design, and both mean "let the next
      tier (the LLM) handle this text instead."
    * Exactly one template matches, and its `to_envelope.(captures)` returns
      a map -> `{:ok, envelope}`.
    * Exactly one template matches, but its `to_envelope.(captures)` raises
      or returns anything other than a map -> `{:error, %{code:
      :invalid_phrase_template}}` -- a caller's own template bug fails
      closed here; it never silently falls through and masks itself as an
      LLM-tier request.

  This module never calls a solver, a compiler, or an LLM -- it only
  matches text and builds a plain map. `AshA2A.Planning.RequestRouter`
  is the sole caller that gives that map real, executable meaning.
  """

  @typedoc "A single caller-registered structured-phrase template."
  @type template :: %{regex: Regex.t(), to_envelope: (map() -> map())}

  @doc """
  Matches `text` against `templates`, in registration order. See the
  moduledoc for the exact contract. Never raises out of this call itself --
  a raising `to_envelope` is caught and turned into a typed `{:error, ...}`
  result.
  """
  @spec parse([template()], String.t()) :: {:ok, map()} | :no_match | {:error, map()}
  def parse(templates, text) when is_list(templates) and is_binary(text) do
    templates
    |> Enum.filter(&full_text_match?(&1.regex, text))
    |> case do
      [%{regex: regex, to_envelope: to_envelope}] ->
        build_envelope(regex, text, to_envelope)

      _zero_or_ambiguous ->
        :no_match
    end
  end

  # A template only counts as a match when its regex's own full match (the
  # 0th capture group `Regex.run/2` always returns first) spans the entire
  # input string -- this is what makes "fully anchored against the entire
  # text" a real, enforced invariant of this module rather than mere
  # documentation trusting every caller-authored regex remembered its own
  # `^`/`$`.
  @spec full_text_match?(Regex.t(), String.t()) :: boolean()
  defp full_text_match?(%Regex{} = regex, text) do
    case Regex.run(regex, text) do
      [^text | _rest] -> true
      _no_full_match -> false
    end
  end

  @spec build_envelope(Regex.t(), String.t(), (map() -> map())) :: {:ok, map()} | {:error, map()}
  defp build_envelope(regex, text, to_envelope) do
    captures = Regex.named_captures(regex, text) || %{}

    case to_envelope.(captures) do
      %{} = envelope -> {:ok, envelope}
      _non_map -> {:error, %{code: :invalid_phrase_template}}
    end
  rescue
    _error -> {:error, %{code: :invalid_phrase_template}}
  end
end
