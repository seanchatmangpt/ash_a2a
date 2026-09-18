defmodule AshA2A.Test.HddlSolverCrossvmDispatch do
  @moduledoc """
  Real helper executed ON a real peer BEAM node via `:erpc.call/4` by
  `AshA2A.PlanningHddlSolverCrossvmTest`, driving the real, unmodified
  `AshA2A.Planning.HddlSolver.solve/3` (real temp files + real
  `native/hddl_cli` OS subprocess) `iterations` times against one fixed
  domain/problem text pair.

  Before the first solve it spins on the host wall clock until
  `start_ms` -- a real cross-node start barrier: every node in that test is
  a separate OS BEAM process on the SAME physical host, so
  `:os.system_time(:millisecond)/0` is one shared clock, and both peers
  enter their first `HddlSolver.solve/3` within milliseconds of each other.
  This is what forces the collision the test hunts: two fresh peer VMs'
  `System.unique_integer/1` monotonic counters both start at the same value,
  so same-sequence invocations on both nodes derive the SAME absolute temp
  paths under the shared `tmp_dir` unless the paths are unique across VMs,
  not just within one.

  Returns the list of real per-iteration outcomes (solved-ness only --
  `{:ok, true}` or `{:error, code}`) tagged with this process's own real
  `node()`, so the caller can prove each result genuinely computed on the
  remote peer, not on the primary.

  Lives under `test/support/` rather than inline in the test module for the
  same real reason `AshA2A.Test.MultinodeDispatch`'s own @moduledoc
  documents: only `lib/` + `test/support/` are compiled to on-disk `.beam`
  files a freshly-started `:peer` node can load from an extended code path
  (`:code.add_pathsz/1`); a closure captured by a `*_test.exs` module would
  fail on the peer with a real `{badfun, ...}`/undef.
  """

  @spec solve_barrier_until(
          non_neg_integer(),
          pos_integer(),
          String.t() | nil,
          String.t(),
          String.t()
        ) ::
          {node(), [{:ok, boolean()} | {:error, atom()}]}
  def solve_barrier_until(start_ms, iterations, tmp_dir, domain_text, problem_text)
      when is_integer(start_ms) and is_integer(iterations) and iterations >= 1 and
             is_binary(domain_text) and is_binary(problem_text) do
    wait_until(start_ms)

    opts = if tmp_dir, do: [tmp_dir: tmp_dir], else: []

    results =
      for _ <- 1..iterations do
        case AshA2A.Planning.HddlSolver.solve(domain_text, problem_text, opts) do
          {:ok, decoded} -> {:ok, decoded["solved"]}
          {:error, %{code: code}} -> {:error, code}
        end
      end

    {node(), results}
  end

  defp wait_until(deadline_ms) do
    if :os.system_time(:millisecond) < deadline_ms do
      Process.sleep(2)
      wait_until(deadline_ms)
    end
  end
end
