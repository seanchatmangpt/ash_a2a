defmodule AshA2A.Test.Fixture.FreedomGym.MeetingPlan do
  @moduledoc """
  Real HDDL-plan-backed phase sequencer for the FreedomGym facilitator
  fixture (`test/support/freedom_gym_fixture.ex`).

  Calls the real `hddl_cli` binary (`native/hddl_cli`, a small standalone
  Rust crate that path-depends on beam4pm's own `ferroplan` crate -- see
  `native/hddl_cli/Cargo.toml` for the full real-vs-mock disclosure) as a
  real OS subprocess over the real HDDL domain+problem at
  `test/support/hddl/freedom_gym_meeting/{domain,problem}.hddl`, parses the
  real solved FOND policy JSON it prints, and derives the real ordered
  phase sequence from the real `advance(<from>,<to>)` actions in that
  policy -- never a hardcoded `@phases` list.

  Plan-state tracking: a minimal, real, in-memory `Agent` holds the current
  position in the real plan (started lazily, one per test process via
  `start_link/1`). `next_phase/1` advances it for real; `reset/1` rewinds
  it to the start of the real plan. This is deliberately minimal (an
  index into a precomputed list) rather than a general HTN executor --
  proportionate to this fixture's scope.
  """

  @hddl_dir Path.expand("hddl/freedom_gym_meeting", __DIR__)
  @domain_path Path.join(@hddl_dir, "domain.hddl")
  @problem_path Path.join(@hddl_dir, "problem.hddl")
  @cli_path Path.expand("../../native/hddl_cli/target/release/hddl_cli", __DIR__)

  @doc """
  Runs the real `hddl_cli` binary over the real HDDL domain/problem for
  this fixture and returns the real ordered phase-atom sequence derived
  from the real solved FOND policy's `advance(<from>,<to>)` actions
  (e.g. `[:open, :trust_god, :clean_house, :help_others, :fellowship,
  :close]`). Raises on any real failure (missing binary, HDDL
  parse/ground/translate/solve error, unsolved plan) -- no fallback to a
  hardcoded list.
  """
  def real_plan_phases! do
    unless File.exists?(@cli_path) do
      raise """
      hddl_cli binary not built at #{@cli_path}.
      Run: cd #{Path.expand("../../native/hddl_cli", __DIR__)} && cargo build --release
      """
    end

    {stdout, exit_code} = System.cmd(@cli_path, [@domain_path, @problem_path])

    decoded =
      case JSON.decode(stdout) do
        {:ok, decoded} ->
          decoded

        {:error, reason} ->
          raise "hddl_cli produced non-JSON stdout: #{inspect(reason)}: #{stdout}"
      end

    if exit_code != 0 or Map.has_key?(decoded, "error") do
      raise "hddl_cli failed (exit #{exit_code}): #{inspect(decoded)}"
    end

    unless decoded["solved"] do
      raise "hddl_cli returned an unsolved plan: #{inspect(decoded)}"
    end

    transitions =
      decoded["policy"]
      |> Enum.map(& &1["action"])
      |> Enum.flat_map(&parse_advance_action/1)

    case transitions do
      [] ->
        raise "hddl_cli plan contained no advance(...) transitions: #{inspect(decoded)}"

      [{first_from, _first_to} | _] = pairs ->
        [phase_atom(first_from) | Enum.map(pairs, fn {_from, to} -> phase_atom(to) end)]
    end
  end

  defp parse_advance_action(action) when is_binary(action) do
    case Regex.run(~r/advance\(([a-z-]+),([a-z-]+)\)/, action) do
      [_, from, to] -> [{from, to}]
      nil -> []
    end
  end

  defp phase_atom(hyphenated) do
    hyphenated |> String.replace("-", "_") |> String.to_atom()
  end

  # -- Minimal, real, in-memory plan-position tracking (Agent) ----------

  @doc "Starts (or reuses) the real in-memory plan-position Agent for `name`."
  def start_link(name) do
    case Agent.start_link(fn -> %{phases: real_plan_phases!(), index: 0} end, name: name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Returns the real next phase in the real plan for the Agent `name`
  (starting it if needed) and advances its real in-memory position.
  Returns `{:ok, phase_atom}` or `{:error, :plan_exhausted}` once every
  real phase has been consumed.
  """
  def next_phase(name) do
    {:ok, _pid} = start_link(name)

    Agent.get_and_update(name, fn %{phases: phases, index: index} = state ->
      case Enum.at(phases, index) do
        nil -> {{:error, :plan_exhausted}, state}
        phase -> {{:ok, phase}, %{state | index: index + 1}}
      end
    end)
  end

  @doc "Rewinds the real in-memory plan position for `name` back to the start."
  def reset(name) do
    {:ok, _pid} = start_link(name)
    Agent.update(name, fn state -> %{state | index: 0} end)
    :ok
  end
end
