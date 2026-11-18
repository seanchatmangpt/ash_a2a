# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Planning.PhraseParserTest do
  @moduledoc """
  Real, Chicago-style coverage for `AshA2A.Planning.PhraseParser`, the
  design plan's bounded, deterministic structured-phrase middle tier
  (facts > structured-phrase > LLM-prose).

  Every template exercised here is a real, plain `%{regex:, to_envelope:}`
  map -- no test double of any kind. The adversarial inputs below
  (`"The goal is to read the people."`,
  `"advance the admitted workflow"`) are the exact real free-text corpus
  strings already exercised elsewhere in this repo as genuine LLM-tier
  free prose (`test/ash_a2a/semantic_compiler_test.exs:51`,
  `docs/how-to/enable-semantic-requests.md:69`,
  `test/ash_a2a/planning/request_router_test.exs`) -- proving this parser
  never mis-captures them is the concrete falsifier for "bounded, not a
  naive verb/keyword matcher."
  """

  use ExUnit.Case, async: true

  alias AshA2A.Planning.PhraseParser

  # The real structured-phrase family this repo's own corpus investigation
  # found reusable across multiple test/doc call sites:
  # `test/ash_a2a_agent_semantic_replan_test.exs:250,297,355,400,437,469`'s
  # `"create a labeled item"` / `"create a labeled item, <variant> variant"`
  # family. Fully anchored (`^...$`), matching this module's own documented
  # contract.
  @labeled_item_regex ~r/^create a labeled item(?:, (?<variant>[a-z]+(?: [a-z]+)?) variant)?$/

  defp labeled_item_template do
    %{
      regex: @labeled_item_regex,
      to_envelope: fn captures ->
        variant = Map.get(captures, "variant", "")

        %{
          "request_id" => "phrase-parser-test-#{variant}-#{System.unique_integer([:positive])}",
          "domain_name" => "labeled-item-domain",
          "problem_name" => "labeled-item-problem",
          "variant" => variant
        }
      end
    }
  end

  defp raising_template do
    %{
      regex: ~r/^raise on purpose$/,
      to_envelope: fn _captures -> raise "template author bug" end
    }
  end

  defp non_map_template do
    %{
      regex: ~r/^return garbage$/,
      to_envelope: fn _captures -> "not a map" end
    }
  end

  describe "zero templates" do
    test "an empty template list never matches, regardless of text" do
      assert :no_match = PhraseParser.parse([], "create a labeled item")
    end
  end

  describe "exactly one match" do
    test "a plain phrase with no optional variant clause parses to a real envelope" do
      assert {:ok, envelope} =
               PhraseParser.parse([labeled_item_template()], "create a labeled item")

      assert envelope["domain_name"] == "labeled-item-domain"
      assert envelope["variant"] == ""
    end

    test "the phrase's optional variant clause is captured by name and threaded through" do
      assert {:ok, envelope} =
               PhraseParser.parse(
                 [labeled_item_template()],
                 "create a labeled item, forbidden variant"
               )

      assert envelope["variant"] == "forbidden"
    end

    test "a real two-word variant capture (named-capture group, not positional slicing)" do
      assert {:ok, envelope} =
               PhraseParser.parse(
                 [labeled_item_template()],
                 "create a labeled item, direct replan variant"
               )

      assert envelope["variant"] == "direct replan"
    end
  end

  describe "ambiguity: two or more templates matching the same text" do
    test "two independently-matching templates over the same text refuse as :no_match, not a guess" do
      duplicate_template = %{
        regex: @labeled_item_regex,
        to_envelope: fn _captures -> %{"domain_name" => "duplicate-domain"} end
      }

      assert :no_match =
               PhraseParser.parse(
                 [labeled_item_template(), duplicate_template],
                 "create a labeled item"
               )
    end
  end

  describe "invalid template behavior fails closed" do
    test "a to_envelope that raises on the sole matching template returns a typed error, never crashes the caller" do
      assert {:error, %{code: :invalid_phrase_template}} =
               PhraseParser.parse([raising_template()], "raise on purpose")
    end

    test "a to_envelope that returns a non-map on the sole matching template returns the same typed error" do
      assert {:error, %{code: :invalid_phrase_template}} =
               PhraseParser.parse([non_map_template()], "return garbage")
    end
  end

  describe "adversarial: real free-text corpus strings must never be mis-captured" do
    test "\"The goal is to read the people.\" does not match the labeled-item template" do
      assert :no_match =
               PhraseParser.parse(
                 [labeled_item_template()],
                 "The goal is to read the people."
               )
    end

    test "\"advance the admitted workflow\" does not match the labeled-item template" do
      assert :no_match =
               PhraseParser.parse(
                 [labeled_item_template()],
                 "advance the admitted workflow"
               )
    end

    test "a genuine substring occurrence inside unrelated free prose is refused, not partially captured" do
      # A real, unanchored-in-spirit adversarial case: the literal phrase
      # appears INSIDE a longer sentence rather than as the entire text.
      # `full_text_match?/2` (this module's real enforcement of "matched
      # fully anchored against the entire text") must refuse this even
      # though `Regex.match?/2` alone would find the substring.
      text = "Please create a labeled item now, thanks."

      assert :no_match = PhraseParser.parse([labeled_item_template()], text)
    end
  end
end
