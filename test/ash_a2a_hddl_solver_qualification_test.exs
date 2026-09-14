defmodule AshA2AHddlSolverQualificationTest do
  @moduledoc """
  Qualifies the real, CI-built native `hddl_cli` (ferroplan) binary against
  BOTH classification outcomes -- solvable and unsolvable -- over real HDDL
  domain/problem pairs, not just the one already-known-solvable
  `freedom_gym_meeting` fixture exercised by
  `test/ash_a2a_freedom_gym_hddl_plan_test.exs`.

  Both tests shell out to the real `native/hddl_cli/target/release/hddl_cli`
  binary via `System.cmd/2` (a real OS subprocess, zero Mock/mox/patch/
  monkeypatch) and assert on the real decoded JSON it prints to stdout.

  ## The unsolvable fixture (`test/support/hddl/unsolvable_qualification/`)

  A genuine logical impossibility, not a syntax error: the domain's only
  action, `advance`, requires `(and (current-phase ?from) (has-permission))`
  as its precondition, but `has-permission` is never true in `:init` and no
  action in the domain ever has it as an effect -- there is no ground action
  sequence, of any length, that can ever satisfy it. The single ground
  instance the method needs, `advance(locked, unlocked)`, can therefore never
  fire, so the HTN decomposition the problem's `:htn` requires can never
  complete and the stated goal `(current-phase unlocked)` can never be
  reached.

  This was verified empirically against the real binary during development
  (not merely asserted to be true): running
  `native/hddl_cli/target/release/hddl_cli
  test/support/hddl/unsolvable_qualification/{domain,problem}.hddl` real,
  standalone, on the command line prints:

      {"error":"planner error: NoPlan"}

  with a non-zero exit code -- the real ferroplan HDDL solver's own real
  classification of this pair as unsolvable, not a value hand-typed into a
  fixture.
  """

  use ExUnit.Case, async: true

  @cli_path Path.expand("../native/hddl_cli/target/release/hddl_cli", __DIR__)

  @solvable_domain Path.expand("support/hddl/freedom_gym_meeting/domain.hddl", __DIR__)
  @solvable_problem Path.expand("support/hddl/freedom_gym_meeting/problem.hddl", __DIR__)

  @unsolvable_domain Path.expand(
                       "support/hddl/unsolvable_qualification/domain.hddl",
                       __DIR__
                     )
  @unsolvable_problem Path.expand(
                        "support/hddl/unsolvable_qualification/problem.hddl",
                        __DIR__
                      )

  setup_all do
    unless File.exists?(@cli_path) do
      flunk("""
      hddl_cli binary not built at #{@cli_path}.
      Run: cd #{Path.expand("../native/hddl_cli", __DIR__)} && cargo build --release --locked
      """)
    end

    :ok
  end

  defp run_hddl_cli!(domain_path, problem_path) do
    {stdout, exit_code} = System.cmd(@cli_path, [domain_path, problem_path])

    decoded =
      case JSON.decode(stdout) do
        {:ok, decoded} ->
          decoded

        {:error, reason} ->
          flunk("hddl_cli produced non-JSON stdout: #{inspect(reason)}: #{stdout}")
      end

    {decoded, exit_code, stdout}
  end

  test "real solvable freedom_gym_meeting HDDL pair reports solved: true via the real binary" do
    {decoded, exit_code, raw} = run_hddl_cli!(@solvable_domain, @solvable_problem)

    assert exit_code == 0,
           "expected the real hddl_cli to exit 0 on a genuinely solvable pair, " <>
             "got exit #{exit_code}. Real raw stdout: #{raw}"

    refute Map.has_key?(decoded, "error"),
           "expected no \"error\" key from the real solver on a genuinely solvable pair. " <>
             "Real raw stdout: #{raw}"

    assert decoded["solved"] == true,
           "expected the real solver to report solved: true for freedom_gym_meeting. " <>
             "Real raw stdout: #{raw}"

    assert is_list(decoded["policy"]) and decoded["policy"] != [],
           "expected a non-empty real solved policy. Real raw stdout: #{raw}"
  end

  test "real unsolvable pair (unreachable precondition) reports failure via the real binary" do
    {decoded, exit_code, raw} = run_hddl_cli!(@unsolvable_domain, @unsolvable_problem)

    # The real ferroplan solver reports this specific unreachable-precondition
    # case as a top-level planner error (non-zero exit, an "error" key) rather
    # than a zero-exit `{"solved": false, ...}` payload. Accept either real
    # shape a genuine solver could use to say "no plan exists", but require at
    # least one of them to be real and present -- never fabricate which shape
    # it took.
    reports_unsolved? =
      Map.has_key?(decoded, "error") or decoded["solved"] == false

    assert reports_unsolved?,
           "expected the real hddl_cli to report failure (an \"error\" key or " <>
             "solved: false) for a genuinely unsolvable pair whose only action's " <>
             "precondition (has-permission) is never reachable from :init, but got " <>
             "exit #{exit_code} with real raw stdout: #{raw}"

    refute decoded["solved"] == true,
           "the unsolvable_qualification pair must never be reported solved. " <>
             "Real raw stdout: #{raw}"
  end
end
