defmodule AshA2A.Test.Fixture.SemanticHddlVerification do
  @moduledoc """
  Real solver-verification helper for HDDL/FOND text that has passed through
  the semantic compiler pipeline (`AshA2A.Semantic.Compiler`,
  `AshA2A.Planning.SemanticSynthesis`).

  Mirrors the real, non-mocked pattern in
  `test/support/freedom_gym_meeting_plan.ex`: it shells out to the real,
  CI-built `native/hddl_cli` (`ferroplan`) binary as a real OS subprocess
  over a real domain/problem file pair, decodes the real solved-plan JSON
  it prints via the built-in `JSON` module (this repo's convention for this
  call site, not `Jason`), and reports whether the real solver actually
  found a solution -- never a mocked or hand-simulated result.
  """

  @cli_path Path.expand("../../native/hddl_cli/target/release/hddl_cli", __DIR__)

  @doc """
  Runs the real `hddl_cli` binary over `domain_path`/`problem_path` and
  returns `{:ok, decoded}` when the real solver reports `"solved" => true`
  with no `"error"` key, or `{:error, decoded_or_reason}` otherwise.

  Raises with a `cargo build --release` hint if the real binary has not
  been built yet, exactly mirroring
  `AshA2A.Test.Fixture.FreedomGym.MeetingPlan.real_plan_phases!/0`'s check.
  """
  def verify_solves!(domain_path, problem_path)
      when is_binary(domain_path) and is_binary(problem_path) do
    unless File.exists?(@cli_path) do
      raise """
      hddl_cli binary not built at #{@cli_path}.
      Run: cd #{Path.expand("../../native/hddl_cli", __DIR__)} && cargo build --release
      """
    end

    {stdout, exit_code} = System.cmd(@cli_path, [domain_path, problem_path])

    case JSON.decode(stdout) do
      {:ok, decoded} ->
        if exit_code == 0 and decoded["solved"] == true and not Map.has_key?(decoded, "error") do
          {:ok, decoded}
        else
          {:error, decoded}
        end

      {:error, reason} ->
        {:error, {:non_json_stdout, reason, stdout}}
    end
  end
end
