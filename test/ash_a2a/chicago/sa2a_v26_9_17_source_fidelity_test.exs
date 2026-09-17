defmodule AshA2A.Chicago.SA2AV269_17SourceFidelityTest do
  @moduledoc """
  Mechanically cross-checks the committed, reconciled
  `test/support/hddl/sa2a_v26_9_17_dogfood/domain.hddl` against the user's
  own original, byte-for-byte verbatim pasted HDDL/FOND write-up preserved
  in the sibling `test/support/hddl/sa2a_v26_9_17_dogfood/SOURCE.md`.

  ## What this test is, and is not

  This is a real, mechanical parse-and-compare over two real files on
  disk -- simple string/regex processing, zero Mock/mox/patch/monkeypatch,
  zero fuzzy/semantic judgement. It does NOT re-verify the domain solves
  or grounds (that is `sa2a_v26_9_17_fond_qualification_test.exs`'s job)
  and does NOT re-verify exhaustive reachability (that is
  `sa2a_v26_9_17_reachability_analysis_test.exs`'s job). Its only claim:
  for every `:action` whose exact `(:action <name>` header line still
  appears verbatim in the committed `domain.hddl`, that action's `oneof`
  outcome set (the alternative effect branches a non-deterministic action
  can produce) is IDENTICAL -- same outcome predicates, same set,
  comment text stripped from both sides first -- between the original
  pasted text and the committed fixture.

  ## Why this matters

  `domain.hddl`'s own comments already disclose real edits made on top of
  the original pasted domain: 6 mirrored Episode-2 actions
  (`admit-authority-replay`, `dispatch-replay-command`,
  `execute-replay-command`, `close-replay-receipt`, `verify-replay`,
  `observe-replay-process` -- entirely new, never in the original text),
  one disclosed rename (`admit-candidate`'s own primitive body renamed to
  `attempt-admit-candidate`, wrapped in a new task of the same name), and
  a disclosed grounding-gap reconciliation (`classify-episode` wrapping
  the two originally-declared-but-mis-wired actions `classify-problem` /
  `observe-classification`, reusing both unchanged). None of those are
  fidelity violations -- they are named, comment-disclosed, additive
  changes. What this test guards against is the OTHER, un-disclosed
  failure mode: an action kept under its exact original name silently
  having an outcome predicate added, removed, or swapped in its `oneof`
  effect, with no comment marking the change. `disclosed rename` and
  `disclosed addition` are excluded by construction (the renamed action's
  old header no longer matches; the new actions have no original-source
  counterpart to compare against at all) -- both are asserted explicitly
  in dedicated tests below, so this suite does not just skip them
  silently.

  ## Source of the original text

  `SOURCE.md` was recovered by grepping this session's own JSONL
  transcript for the real user turn, and reproduces it byte-for-byte
  (see `SOURCE.md`'s own header for the full recovery note and the one
  stripped `ultracode ` command-invocation prefix).
  """

  use ExUnit.Case, async: true

  @source_md Path.expand("../../support/hddl/sa2a_v26_9_17_dogfood/SOURCE.md", __DIR__)
  @domain_hddl Path.expand("../../support/hddl/sa2a_v26_9_17_dogfood/domain.hddl", __DIR__)

  @begin_marker "<!-- BEGIN VERBATIM SOURCE -->\n"
  @end_marker "\n<!-- END VERBATIM SOURCE -->\n"
  @problem_heading "sa2a-v26.9.17-problem.hddl"

  # The one disclosed rename: the original pasted domain's primitive
  # action `admit-candidate` was renamed to `attempt-admit-candidate`
  # (body unchanged) and `admit-candidate` became a wrapping :task of the
  # same name instead -- so its old `(:action admit-candidate` header no
  # longer appears verbatim in domain.hddl, and this suite must not
  # silently treat that absence as "nothing to check" without also
  # confirming the disclosed replacement is real.
  @disclosed_renamed_action "admit-candidate"
  @disclosed_renamed_replacement "attempt-admit-candidate"

  # The 6 disclosed, wholly-new Episode-2 mirror actions -- present only
  # in the committed domain.hddl, absent from the original pasted text.
  @disclosed_new_actions ~w(
    admit-authority-replay
    dispatch-replay-command
    execute-replay-command
    close-replay-receipt
    verify-replay
    observe-replay-process
  )

  setup_all do
    for path <- [@source_md, @domain_hddl] do
      unless File.exists?(path) do
        flunk("required fixture missing: #{path}")
      end
    end

    :ok
  end

  test "SOURCE.md's verbatim block is present, delimited, and starts where the recovery note says it does" do
    source_md = File.read!(@source_md)

    assert String.contains?(source_md, @begin_marker),
           "SOURCE.md is missing its <!-- BEGIN VERBATIM SOURCE --> delimiter"

    assert String.contains?(source_md, @end_marker),
           "SOURCE.md is missing its <!-- END VERBATIM SOURCE --> delimiter"

    verbatim = extract_verbatim(source_md)

    assert String.starts_with?(verbatim, "The clean representation is"),
           "verbatim block does not start with the expected recovered text"

    assert String.ends_with?(
             verbatim,
             "That is the FOND/HDDL form of the self-reinforcing SA2A loop.\n"
           )

    # A real paste, not an accidentally-truncated stub.
    assert byte_size(verbatim) > 20_000
  end

  test "every original :action header still present verbatim in domain.hddl has an IDENTICAL oneof outcome set" do
    source_md = File.read!(@source_md)
    domain_text = File.read!(@domain_hddl)

    verbatim = extract_verbatim(source_md)
    source_domain_text = extract_domain_lisp_fences(verbatim)

    source_actions = extract_actions(strip_comments(source_domain_text))
    committed_actions = extract_actions(strip_comments(domain_text))

    assert map_size(source_actions) > 0, "found zero :action blocks in the recovered source text"

    assert map_size(committed_actions) > 0,
           "found zero :action blocks in the committed domain.hddl"

    {checked, violations} =
      Enum.reduce(source_actions, {[], []}, fn {name, src_block}, {checked_acc, viol_acc} ->
        if action_header_present?(domain_text, name) do
          committed_block = Map.fetch!(committed_actions, name)
          src_oneof = extract_oneof_outcomes(src_block)
          committed_oneof = extract_oneof_outcomes(committed_block)

          checked_acc = [name | checked_acc]

          if src_oneof == committed_oneof do
            {checked_acc, viol_acc}
          else
            violation = %{
              action: name,
              source_oneof: src_oneof,
              committed_oneof: committed_oneof
            }

            {checked_acc, [violation | viol_acc]}
          end
        else
          {checked_acc, viol_acc}
        end
      end)

    # Sanity floor: this must be a real, nontrivial mechanical check, not
    # a vacuous pass because a bug in the extraction found nothing to
    # compare. The original pasted domain declares 27 actions; all but
    # the one disclosed rename (admit-candidate) keep their exact header.
    assert length(checked) >= 20,
           "expected at least 20 original actions to still be verbatim-headered " <>
             "in domain.hddl, found #{length(checked)}: #{inspect(Enum.sort(checked))}"

    assert violations == [],
           "fidelity violation(s): an action's original oneof outcome set was " <>
             "silently narrowed, widened, or altered with no disclosure comment: " <>
             inspect(Enum.reverse(violations), pretty: true, limit: :infinity)
  end

  test "the disclosed rename (admit-candidate -> attempt-admit-candidate) is real, and correctly excluded rather than silently passed" do
    domain_text = File.read!(@domain_hddl)

    refute action_header_present?(domain_text, @disclosed_renamed_action),
           "admit-candidate is expected to no longer be declared as an :action " <>
             "in domain.hddl (it became a :task) -- if this now fails, the " <>
             "domain changed and the disclosed-rename exclusion above needs " <>
             "re-auditing, not silent removal"

    assert action_header_present?(domain_text, @disclosed_renamed_replacement),
           "expected the disclosed replacement action attempt-admit-candidate " <>
             "to be declared in domain.hddl"
  end

  test "the 6 mirrored Episode-2 actions are real domain.hddl-only additions, absent from the original pasted source" do
    source_md = File.read!(@source_md)
    domain_text = File.read!(@domain_hddl)

    verbatim = extract_verbatim(source_md)
    source_domain_text = extract_domain_lisp_fences(verbatim)
    source_actions = extract_actions(strip_comments(source_domain_text))

    for name <- @disclosed_new_actions do
      refute Map.has_key?(source_actions, name),
             "#{name} unexpectedly found in the original pasted source -- it " <>
               "is supposed to be a disclosed, domain.hddl-only addition"

      assert action_header_present?(domain_text, name),
             "expected disclosed new action #{name} to be declared in domain.hddl"
    end
  end

  # -- helpers --------------------------------------------------------------

  defp extract_verbatim(source_md) do
    [_before, rest] = String.split(source_md, @begin_marker, parts: 2)
    [verbatim, _after] = String.split(rest, @end_marker, parts: 2)
    verbatim
  end

  # Concatenates every ```lisp fenced code block that appears before the
  # problem.hddl heading in the verbatim text -- the original pasted
  # message interleaves prose section headers between successive lisp
  # fences that together make up the full original domain.hddl (the
  # single large problem.hddl fence comes after that heading and is out
  # of scope for this action-level domain check).
  defp extract_domain_lisp_fences(verbatim) do
    domain_region =
      case :binary.match(verbatim, @problem_heading) do
        {idx, _len} -> binary_part(verbatim, 0, idx)
        :nomatch -> verbatim
      end

    ~r/```lisp\n(.*?)\n```/s
    |> Regex.scan(domain_region, capture: :all_but_first)
    |> Enum.map_join("\n", fn [block] -> block end)
  end

  defp strip_comments(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &Regex.replace(~r/;;.*/, &1, ""))
  end

  defp extract_actions(text) do
    ~r/\(:action\s+([\w-]+)/
    |> Regex.scan(text, return: :index)
    |> Enum.reduce(%{}, fn [{start, _len}, {name_start, name_len}], acc ->
      name = binary_part(text, name_start, name_len)
      block = extract_balanced_block(text, start)
      Map.put(acc, name, block)
    end)
  end

  defp extract_balanced_block(text, start), do: do_extract_balanced(text, start, 0, start)

  defp do_extract_balanced(text, pos, depth, start) when pos < byte_size(text) do
    case binary_part(text, pos, 1) do
      "(" ->
        do_extract_balanced(text, pos + 1, depth + 1, start)

      ")" ->
        case depth - 1 do
          0 -> binary_part(text, start, pos - start + 1)
          new_depth -> do_extract_balanced(text, pos + 1, new_depth, start)
        end

      _ ->
        do_extract_balanced(text, pos + 1, depth, start)
    end
  end

  defp do_extract_balanced(_text, _pos, _depth, _start), do: nil

  defp extract_oneof_outcomes(nil), do: nil

  defp extract_oneof_outcomes(block) do
    case :binary.match(block, "(oneof") do
      :nomatch ->
        nil

      {idx, len} ->
        oneof_end = find_matching_close(block, idx)
        body = binary_part(block, idx + len, oneof_end - (idx + len))

        body
        |> split_top_level_alternatives()
        |> Enum.map(&normalize_whitespace/1)
        |> Enum.sort()
    end
  end

  defp find_matching_close(text, open_idx), do: do_find_matching_close(text, open_idx, 0)

  defp do_find_matching_close(text, pos, depth) when pos < byte_size(text) do
    case binary_part(text, pos, 1) do
      "(" ->
        do_find_matching_close(text, pos + 1, depth + 1)

      ")" ->
        case depth - 1 do
          0 -> pos
          new_depth -> do_find_matching_close(text, pos + 1, new_depth)
        end

      _ ->
        do_find_matching_close(text, pos + 1, depth)
    end
  end

  defp split_top_level_alternatives(body), do: do_split(body, 0, 0, nil, [])

  defp do_split(body, pos, depth, start, acc) when pos < byte_size(body) do
    case binary_part(body, pos, 1) do
      "(" ->
        new_start = if depth == 0, do: pos, else: start
        do_split(body, pos + 1, depth + 1, new_start, acc)

      ")" ->
        case depth - 1 do
          0 ->
            alt = binary_part(body, start, pos - start + 1)
            do_split(body, pos + 1, 0, nil, [alt | acc])

          new_depth ->
            do_split(body, pos + 1, new_depth, start, acc)
        end

      _ ->
        do_split(body, pos + 1, depth, start, acc)
    end
  end

  defp do_split(_body, _pos, _depth, _start, acc), do: Enum.reverse(acc)

  defp normalize_whitespace(s) do
    s
    |> String.split()
    |> Enum.join(" ")
  end

  defp action_header_present?(domain_text, name) do
    escaped = Regex.escape(name)
    Regex.match?(~r/\(:action\s+#{escaped}(?=[\s)])/, domain_text)
  end
end
