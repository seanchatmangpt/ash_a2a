defmodule AshA2A.Research.ERC do
  @moduledoc """
  Executable Research Claim (ERC) receipt emitter -- the concrete, minimal
  implementation of the `EDSResult` tuple from the Executable Design
  Science charter (Claim, Artifact, Experiment, Environment, Execution,
  Evidence, Falsifier, Analysis, Reproduction), scoped to what `ash_a2a`'s
  own test suite can actually assert about itself.

  This module does not decide whether a claim holds. It records, as a
  real machine-readable JSON receipt on disk, what a real test run
  actually observed -- git SHA, timestamp, the exact evidence file(s)
  produced, and the caller-supplied verdict -- so "PASS" is a receipted,
  reproducible fact rather than a transient exit code. Per the charter's
  \"IMPLEMENTED != VERIFIED\" and \"NamedExperiment != ExecutedExperiment
  != VerifiedResult\" invariants, `emit!/1` is only ever called from
  inside a real, already-executed test, after real assertions have
  already passed or failed -- it is a record of what happened, not a
  claim of what should happen.
  """

  @erc_dir Path.expand("../../../research/erc", __DIR__)

  @type evidence_state ::
          :proposed
          | :implemented
          | :executable
          | :observed
          | :verified
          | :reproducible
          | :reproduced
          | :falsified
          | :blocked
          | :unsupported
          | :unknown

  # The full evidence-state enum from the EDS charter (section 7 /
  # section 8 of the founding charter) -- deliberately not just the
  # states this repo happens to have used so far (:verified). A state
  # collapse (e.g. an emitter that only ever accepts :verified) would be
  # exactly the failure mode EDS exists to prevent.
  @valid_states ~w(proposed implemented executable observed verified reproducible reproduced falsified blocked unsupported unknown)a

  @doc """
  Emit one real ERC receipt to `research/erc/<id>-<unix_ts>.json`.

  Required fields:

    * `:id` -- stable claim identifier, e.g. "ERC-001"
    * `:claim` -- one-sentence hypothesis text
    * `:falsifier` -- one-sentence condition that would weaken/falsify the claim
    * `:state` -- one of `t:evidence_state/0`
    * `:evidence` -- map of evidence artifact paths/counts this run actually produced
                     (e.g. %{"ocel_events_posted" => 6, "capture_file" => "..."})

  Optional:

    * `:notes` -- free-text observation (e.g. what specifically was verified)
    * `:depends_on` -- list of other ERC ids this claim's standing depends on

  Raises `ArgumentError` for a `:state` outside `t:evidence_state/0` --
  emitting an unrecognized state silently would be the same collapse the
  charter's evidence-state model forbids.
  """
  @spec emit!(map()) :: {:ok, String.t()}
  def emit!(
        %{id: id, claim: claim, falsifier: falsifier, state: state, evidence: evidence} = attrs
      )
      when is_binary(id) and is_binary(claim) and is_binary(falsifier) and is_atom(state) do
    unless state in @valid_states do
      raise ArgumentError,
            "invalid ERC evidence state #{inspect(state)} -- must be one of #{inspect(@valid_states)}"
    end

    File.mkdir_p!(@erc_dir)

    receipt = %{
      "id" => id,
      "claim" => claim,
      "falsifier" => falsifier,
      "state" => Atom.to_string(state),
      "evidence" => evidence,
      "notes" => Map.get(attrs, :notes),
      "depends_on" => Map.get(attrs, :depends_on, []),
      "artifact" => %{
        "repo" => "ash_a2a",
        "git_sha" => git_sha(),
        "git_dirty?" => git_dirty?()
      },
      "environment" => %{
        "elixir" => System.version(),
        "otp" => :erlang.system_info(:otp_release) |> to_string(),
        "hostname" => :inet.gethostname() |> elem(1) |> to_string()
      },
      "execution" => %{
        "emitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    ts = System.system_time(:millisecond)
    path = Path.join(@erc_dir, "#{id}-#{ts}.json")
    File.write!(path, Jason.encode!(receipt, pretty: true))
    {:ok, path}
  end

  @doc """
  Read every real receipt file under `research/erc/` in this repo,
  decoded, newest-write-first. Returns `[]` (not an error) when the
  directory doesn't exist yet -- no receipts emitted is a real, valid
  state, not a failure.
  """
  @spec list_receipts() :: [map()]
  def list_receipts do
    case File.ls(@erc_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.join(@erc_dir, &1))
        |> Enum.sort_by(&File.stat!(&1).mtime, :desc)
        |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))

      {:error, :enoent} ->
        []
    end
  end

  @doc """
  The ledger: one entry per distinct ERC `id`, the *latest* real receipt
  for that id (a claim can be re-verified/re-falsified across runs; the
  ledger reports current standing, not history -- use `list_receipts/0`
  for the full history of a given id).
  """
  @spec ledger() :: [map()]
  def ledger do
    list_receipts()
    |> Enum.uniq_by(& &1["id"])
    |> Enum.sort_by(& &1["id"])
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp git_dirty? do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> false
      {_output, 0} -> true
      _ -> :unknown
    end
  end
end
