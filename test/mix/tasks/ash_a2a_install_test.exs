# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.InstallTest do
  @moduledoc """
  Chicago-style coverage for `mix ash_a2a.install`'s `--target` codemod: a real
  in-memory Igniter project (`Igniter.Test.test_project/1`), a real task run
  (`Igniter.compose_task/3`, the same machinery a real `mix ash_a2a.install`
  invocation uses to parse argv and dispatch to `Mix.Tasks.AshA2a.Install
  .igniter/1`), and assertions on the real persisted source content -- no
  Mock/mox/patch, no "was this function called" interaction check.

  Covers the detect-and-merge `extensions:` fix in
  `lib/mix/tasks/ash_a2a.install.ex`: merging `AshA2A` into an already-present
  `extensions:` list instead of inserting a second, separate `extensions:`
  option; the common case where the target has no prior `extensions:` option
  at all; and idempotency (running the task twice against the same module must
  not duplicate `AshA2A` in the list).
  """

  use ExUnit.Case, async: true

  import Igniter.Test

  @path "lib/test/resource.ex"

  describe "mix ash_a2a.install --target" do
    test "merges AshA2A into an existing extensions: list instead of duplicating the extensions: option" do
      igniter =
        test_project(
          files: %{
            @path => """
            defmodule Test.Resource do
              use Ash.Resource,
                domain: Test.Domain,
                data_layer: Ash.DataLayer.Ets,
                extensions: [SomeOtherExtension]

              attributes do
                uuid_primary_key(:id)
              end
            end
            """
          }
        )
        |> Igniter.compose_task("ash_a2a.install", ["--target", "Test.Resource"])

      content = source_content(igniter, @path)

      # Exactly one `extensions:` option on the module -- never two.
      assert count_occurrences(content, "extensions:") == 1
      # AshA2A merged in alongside the pre-existing extension, not replacing it.
      assert content =~ "extensions: [AshA2A, SomeOtherExtension]"
      assert content =~ "a2a do"
    end

    test "adds extensions: [AshA2A] when the target has no prior extensions: option (common case)" do
      igniter =
        test_project(
          files: %{
            @path => """
            defmodule Test.Resource do
              use Ash.Resource,
                domain: Test.Domain,
                data_layer: Ash.DataLayer.Ets

              attributes do
                uuid_primary_key(:id)
              end
            end
            """
          }
        )
        |> Igniter.compose_task("ash_a2a.install", ["--target", "Test.Resource"])

      content = source_content(igniter, @path)

      assert count_occurrences(content, "extensions:") == 1
      assert content =~ "extensions: [AshA2A]"
      assert content =~ "a2a do"
    end

    test "running install twice does not duplicate AshA2A in the extensions: list" do
      igniter =
        test_project(
          files: %{
            @path => """
            defmodule Test.Resource do
              use Ash.Resource,
                domain: Test.Domain,
                data_layer: Ash.DataLayer.Ets,
                extensions: [SomeOtherExtension]

              attributes do
                uuid_primary_key(:id)
              end
            end
            """
          }
        )
        |> Igniter.compose_task("ash_a2a.install", ["--target", "Test.Resource"])
        |> apply_igniter!()
        |> Igniter.compose_task("ash_a2a.install", ["--target", "Test.Resource"])

      content = source_content(igniter, @path)

      # Still exactly one `extensions:` option, and AshA2A appears exactly once
      # inside it -- a second install run must not duplicate the option or the
      # extension entry. (The starter `a2a do end` block's own duplication on a
      # second run is a separate, pre-existing concern outside this fix's scope
      # -- not asserted on here.)
      assert count_occurrences(content, "extensions:") == 1
      assert count_occurrences(content, "AshA2A") == 1
      assert content =~ "extensions: [AshA2A, SomeOtherExtension]"
    end
  end

  # ASH_A2A-26922-08: explicit skill consequences and the idempotent
  # `a2a do` block. ggen_igniter's semantic-jira-pack records, as an
  # UNSUPPORTED(generator-capability) ontology row, that `ash_a2a.install`
  # could not emit an explicit `a2a` skill `consequence: :external_do`
  # override; `--skill name:action:consequence` closes that row.
  describe "mix ash_a2a.install --skill" do
    test "emits the declared skill with an explicit consequence: :external_do inside the a2a do block" do
      igniter =
        test_project(
          files: %{
            @path => """
            defmodule Test.Resource do
              use Ash.Resource,
                domain: Test.Domain,
                data_layer: Ash.DataLayer.Ets

              attributes do
                uuid_primary_key(:id)
              end
            end
            """
          }
        )
        |> Igniter.compose_task("ash_a2a.install", [
          "--target",
          "Test.Resource",
          "--skill",
          "advance_item:advance:external_do"
        ])

      content = source_content(igniter, @path)

      assert count_occurrences(content, "a2a do") == 1
      # Igniter formats composed content, so the emitted declaration is in
      # parens form (same for every assertion below).
      assert content =~ "skill(:advance_item, :advance, consequence: :external_do)"
    end

    test "two runs yield exactly one a2a do block and exactly one consequence: :external_do" do
      igniter =
        test_project(
          files: %{
            @path => """
            defmodule Test.Resource do
              use Ash.Resource,
                domain: Test.Domain,
                data_layer: Ash.DataLayer.Ets

              attributes do
                uuid_primary_key(:id)
              end
            end
            """
          }
        )
        |> Igniter.compose_task("ash_a2a.install", [
          "--target",
          "Test.Resource",
          "--skill",
          "advance_item:advance:external_do"
        ])
        |> apply_igniter!()
        |> Igniter.compose_task("ash_a2a.install", [
          "--target",
          "Test.Resource",
          "--skill",
          "advance_item:advance:external_do"
        ])

      content = source_content(igniter, @path)

      # The block is written idempotently: never a second `a2a do` block,
      # never a duplicated declaration, never a duplicated extension entry.
      assert count_occurrences(content, "a2a do") == 1
      assert count_occurrences(content, "consequence: :external_do") == 1
      assert count_occurrences(content, "skill(:advance_item") == 1
      assert count_occurrences(content, "AshA2A") == 1
    end

    test "appends a new --skill into an existing a2a do block without duplicating the block" do
      igniter =
        test_project(
          files: %{
            @path => """
            defmodule Test.Resource do
              use Ash.Resource,
                domain: Test.Domain,
                data_layer: Ash.DataLayer.Ets

              attributes do
                uuid_primary_key(:id)
              end
            end
            """
          }
        )
        |> Igniter.compose_task("ash_a2a.install", [
          "--target",
          "Test.Resource",
          "--skill",
          "advance_item:advance:external_do"
        ])
        |> apply_igniter!()
        |> Igniter.compose_task("ash_a2a.install", [
          "--target",
          "Test.Resource",
          "--skill",
          "log_item:log"
        ])

      content = source_content(igniter, @path)

      assert count_occurrences(content, "a2a do") == 1
      # the previously-written declaration is preserved exactly once, the new
      # one appended without any consequence
      assert count_occurrences(
               content,
               "skill(:advance_item, :advance, consequence: :external_do)"
             ) == 1

      assert content =~ ~r/skill\(:log_item, :log\)\n/m
      refute content =~ "skill(:log_item, :log, consequence:"
    end

    test "an unparseable --skill spec is refused, not silently dropped" do
      assert_raise Mix.Error, ~r/Invalid --skill consequence/i, fn ->
        test_project(
          files: %{
            @path => """
            defmodule Test.Resource do
              use Ash.Resource,
                domain: Test.Domain,
                data_layer: Ash.DataLayer.Ets

              attributes do
                uuid_primary_key(:id)
              end
            end
            """
          }
        )
        |> Igniter.compose_task("ash_a2a.install", [
          "--target",
          "Test.Resource",
          "--skill",
          "advance_item:advance:not_a_consequence"
        ])
      end
    end
  end

  # ZD7: usage-rules.md emission. The ash-ecosystem convention
  # (deps/ash/usage-rules.md, deps/ash_ai/usage-rules.md, ...) is that packages
  # ship a rules file so AI tools and newcomers get correct-usage guidance.
  # The falsifier: a fresh install produces usage-rules.md.
  describe "mix ash_a2a.install emits usage-rules.md" do
    test "a fresh install creates usage-rules.md with the marker and the core rules" do
      igniter =
        test_project(files: %{@path => test_resource_source()})
        |> Igniter.compose_task("ash_a2a.install", ["--target", "Test.Resource"])

      content = source_content(igniter, "usage-rules.md")

      assert content =~ "<!-- ash_a2a:usage-rules:v1 -->"
      # The invariant do/don't pairs, all grounded in the real modules.
      assert content =~ "Ash is the source of truth"
      assert content =~ "`:observe`, `:change`, `:external_do`, `:unknown`"
      assert content =~ ":consequence_unclassified"
      assert content =~ ":authority_required"
      assert content =~ "observe_on_mutating_action"
      assert content =~ "REFUSED_ACTION_NOT_FOUND"
    end

    test "an existing usage-rules.md without the marker keeps its content; the section is appended" do
      igniter =
        test_project(
          files: %{
            @path => test_resource_source(),
            "usage-rules.md" => "# My project rules\n\nBe nice.\n"
          }
        )
        |> Igniter.compose_task("ash_a2a.install", [
          "--target",
          "Test.Resource"
        ])

      content = source_content(igniter, "usage-rules.md")

      assert content =~ "# My project rules"
      assert content =~ "Be nice."
      assert content =~ "<!-- ash_a2a:usage-rules:v1 -->"
    end

    test "re-running install never duplicates the marked section" do
      igniter =
        test_project(files: %{@path => test_resource_source()})
        |> Igniter.compose_task("ash_a2a.install", ["--target", "Test.Resource"])
        |> apply_igniter!()
        |> Igniter.compose_task("ash_a2a.install", ["--target", "Test.Resource"])

      content = source_content(igniter, "usage-rules.md")

      assert count_occurrences(content, "<!-- ash_a2a:usage-rules:v1 -->") == 1
      assert count_occurrences(content, "Ash is the source of truth") == 1
    end

    # The emitted section and the package's own usage-rules.md must not drift
    # apart: every invariant rule line asserted above must appear in the
    # package file too. This reads the REAL repo-root file (Chicago-style, no
    # mock), so editing one document without the other fails this court.
    test "the emitted section and the package usage-rules.md do not drift" do
      package_rules = File.read!(Path.expand("usage-rules.md", __DIR__ <> "/../../.."))

      emitted =
        test_project(files: %{@path => test_resource_source()})
        |> Igniter.compose_task("ash_a2a.install", ["--target", "Test.Resource"])
        |> then(&source_content(&1, "usage-rules.md"))

      invariants = [
        "`:observe`, `:change`, `:external_do`, `:unknown`",
        ":consequence_unclassified",
        ":authority_required",
        "observe_on_mutating_action",
        "REFUSED_ACTION_NOT_FOUND"
      ]

      Enum.each(invariants, fn line ->
        assert package_rules =~ line, "package usage-rules.md lost the invariant #{inspect(line)}"
        assert emitted =~ line, "emitted usage-rules.md lost the invariant #{inspect(line)}"
      end)
    end
  end

  defp test_resource_source do
    """
    defmodule Test.Resource do
      use Ash.Resource,
        domain: Test.Domain,
        data_layer: Ash.DataLayer.Ets

      attributes do
        uuid_primary_key(:id)
      end
    end
    """
  end

  defp source_content(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  defp count_occurrences(content, substring) do
    content
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
  end
end
