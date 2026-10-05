# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SA2A.Conformance.MixProjectStackTest do
  # Not async: asserts on the process-global Mix project stack.
  use ExUnit.Case, async: false

  alias AshA2A.SA2A.Conformance.Checks.C2

  # `project_info/2` evaluates a sibling project's real mix.exs. `use
  # Mix.Project` pushes that module onto the global Mix project stack when it
  # compiles, and a stack that still holds the sibling makes every later
  # `Mix.Task.run("app.start")` in this VM compile the sibling project and
  # prune the code path (whole-suite `{:error, :bad_name}` / "module not
  # available" cascade). Evaluating a project must leave the stack as found.
  test "evaluating a sibling mix.exs leaves the Mix project stack unchanged" do
    root = Path.join(System.tmp_dir!(), "mps-#{System.unique_integer([:positive])}")
    dir = Path.join(root, "sibling")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule MixProjectStackTest.Sibling#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :mps_sibling, version: "0.0.1", deps: []]
    end
    """)

    on_exit(fn -> File.rm_rf!(root) end)

    before = Mix.Project.get()
    assert {:ok, %{app: :mps_sibling}} = C2.project_info(%{root: root}, "sibling")
    assert Mix.Project.get() == before
    assert Mix.Project.get() == AshA2A.MixProject
  end

  test "the real actuator/ and authority_service/ projects evaluate without leaking either" do
    root = File.cwd!()
    before = Mix.Project.get()
    assert {:ok, %{app: :actuator}} = C2.project_info(%{root: root}, "actuator")
    assert {:ok, %{app: :authority_service}} = C2.project_info(%{root: root}, "authority_service")
    assert Mix.Project.get() == before
  end
end
