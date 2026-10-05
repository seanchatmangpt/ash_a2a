# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.Report do
  @moduledoc """
  The court's machine-readable report (JSON): one row per attack (id, RFC s26 items,
  ATT&CK/CAPEC/ATLAS mapping, verdict, ledger diff, observed refusal codes, commit SHA),
  the mutation table, the key-material scan, the compat/handoff probes and the overall
  verdict. `overall` is `"PASS"` only when every attack passed, no protected key material
  was found in the control-plane environment (and the scan proved it can fire), every
  fence check except the declared-redundant check 10 was killed by its mutant, checks
  {10, 11} together were killed, and the unfenced always-allow actuator failed the court.
  """
  alias C2Harness.Fleet

  def hosting_scope do
    "separate-process, same-host: keymaster, actuator and authority are distinct OS processes " <>
      "(own MIX_BUILD_ROOT, own state dir mode 0700, no Erlang distribution, UDS/mTLS wire) run as " <>
      "the SAME OS uid as the test process that plays the control plane. A separate OS user or " <>
      "cluster is an operator/infra follow-up; an attacker that ignores the API and opens the " <>
      "state directories directly is outside what this court can constrain."
  end

  def build(ctx) do
    sha = git(["rev-parse", "HEAD"])
    results = Enum.map(ctx.results, &Map.put(&1, :commit_sha, sha))
    verdicts = Enum.frequencies_by(results, & &1.verdict)
    mutation = ctx.mutation

    overall_checks = %{
      all_attacks_pass: Enum.all?(results, &(&1.verdict == :pass)),
      no_key_material_in_control_plane: ctx.scan.leaks == [],
      key_scan_can_fire: ctx.scan.selftest_complete,
      mutation: mutation_ok(mutation)
    }

    %{
      "court" => "SA2A C2 compromise court (RFC-SA2A-006 s26)",
      "commit_sha" => sha,
      "working_tree_dirty" => git(["status", "--porcelain"]) != "",
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "hosting_scope" => hosting_scope(),
      "toolchain" => %{
        "elixir" => System.version(),
        "otp" => :erlang.system_info(:otp_release) |> List.to_string()
      },
      "fault_repetitions" => ctx.n,
      "mutant_repetitions" => ctx.mutant_n,
      "pass_rule" =>
        "zero new ledger entries, or only entries whose effect digest the issuance journal authorizes " <>
          "and at most one per issuance; an exception, crash or timeout is never evidence",
      "summary" => %{
        "attacks" => length(results),
        "verdicts" => jsonable(verdicts),
        "duration_ms" => ctx.duration_ms,
        "overall_checks" => jsonable(overall_checks),
        "overall" => if(overall(overall_checks), do: "PASS", else: "FAIL")
      },
      "attacks" => jsonable(results),
      "key_material_scan" => jsonable(ctx.scan),
      "compat" => jsonable(ctx.compat),
      "mutation" => jsonable(mutation),
      "tls_port_scope" => "loopback (127.0.0.1)"
    }
    |> put_fleet_hosts(ctx.info)
  end

  defp put_fleet_hosts(r, info),
    do:
      Map.put(r, "fleet_processes", %{
        "keymaster_os_pid" => info.hello["os_pid"],
        "log_dir" => info.procs_log
      })

  defp mutation_ok(%{skipped: true}), do: :skipped

  defp mutation_ok(m) do
    per = Enum.all?(m.per_check, &(&1.status == :killed))

    %{
      every_check_killed_by_its_mutant: per,
      checks_without_isolating_attack: [10],
      check_10_alone_survived: m.check_10_alone.status == :survived,
      checks_10_and_11_killed: m.check_10_and_11.status == :killed,
      allow_all_actuator_fails_court: m.allow_all.status == :killed
    }
  end

  defp overall(c) do
    c.all_attacks_pass and c.no_key_material_in_control_plane and c.key_scan_can_fire and
      case c.mutation do
        :skipped ->
          true

        m ->
          m.every_check_killed_by_its_mutant and m.checks_10_and_11_killed and
            m.allow_all_actuator_fails_court
      end
  end

  def write!(report, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true))
    path
  end

  defp git(args) do
    case System.cmd("git", args, cd: Fleet.repo_root(), stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, _} -> "unavailable: " <> String.trim(out)
    end
  end

  @doc "Recursively convert atoms, tuples, structs and pids into JSON-encodable terms."
  def jsonable(%{__struct__: _} = s), do: s |> Map.from_struct() |> jsonable()
  def jsonable(m) when is_map(m), do: Map.new(m, fn {k, v} -> {key(k), jsonable(v)} end)
  def jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  def jsonable(t) when is_tuple(t), do: t |> Tuple.to_list() |> jsonable()
  def jsonable(nil), do: nil
  def jsonable(b) when is_boolean(b), do: b
  def jsonable(a) when is_atom(a), do: Atom.to_string(a)
  def jsonable(n) when is_number(n), do: n
  def jsonable(b) when is_binary(b), do: if(String.valid?(b), do: b, else: Base.encode64(b))
  def jsonable(other), do: inspect(other)

  # map keys may be tuples/nil/atoms (frequency tables keyed by {first_ok, retry_ok}, etc.)
  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k) and not is_nil(k), do: Atom.to_string(k)
  defp key(k) when is_integer(k), do: Integer.to_string(k)
  defp key(k), do: inspect(k)
end
