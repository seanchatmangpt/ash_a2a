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
