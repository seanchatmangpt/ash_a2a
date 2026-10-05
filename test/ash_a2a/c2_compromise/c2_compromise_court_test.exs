# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2Compromise.CourtTest do
  @moduledoc """
  RFC-SA2A-006 s26 C2 compromise court, run for real: separate OS processes (keymaster,
  actuator, AuthorityService; own build roots and state dirs; distribution disabled; UDS and
  mTLS wire), an attacker playing the compromised control plane inside this VM, and the
  actuator's hash-chained effect ledger as the oracle. DB-free.

  Tagged `:c2_court` and `:serial`/`:serial_solo`: excluded from default `mix test`, included
  by `mix test.all` and by `mix ash_a2a.c2.court` (which also sets N, the report path and the
  build root through the `C2_COURT_*` environment variables read below).

  The whole court runs once in `setup_all`; each test asserts one claim from the JSON report.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  @moduletag :c2_court
  @moduletag timeout: 3_600_000

  alias C2Harness.{Court, Report}

  setup_all do
    only =
      case System.get_env("C2_COURT_ONLY") do
        nil -> nil
        "" -> nil
        csv -> String.split(csv, ",", trim: true)
      end

    report_path =
      System.get_env("C2_COURT_REPORT") ||
        Path.join([File.cwd!(), "tmp", "c2_court", "report.json"])

    report =
      Court.run(
        only: only,
        mutation: System.get_env("C2_COURT_MUTATION") != "0"
      )

    Report.write!(report, report_path)
    IO.puts("\nC2 court report: #{report_path}  overall=#{report["summary"]["overall"]}")
    {:ok, report: report, only: only}
  end

  test "every attack leaves the effect ledger with zero new entries or only journal-authorized ones",
       %{report: r} do
    bad = for a <- r["attacks"], a["verdict"] != "pass", do: {a["id"], a["verdict"], a["reasons"]}
    assert bad == [], "attacks not passing:\n#{inspect(bad, pretty: true, limit: :infinity)}"
  end

  test "every attack reached the refusal it targets (no vacuous pass)", %{report: r} do
    assert Enum.all?(r["attacks"], &(&1["verdict"] != "vacuous"))
    assert r["summary"]["verdicts"]["vacuous"] in [nil, 0]
  end

  test "at least 30 attacks ran and each row carries its mapping, ledger diff and refusal codes",
       %{report: r, only: only} do
    if is_nil(only), do: assert(length(r["attacks"]) >= 30)

    for a <- r["attacks"] do
      assert is_list(a["mapping"]["attck"]) and is_list(a["mapping"]["capec"]) and
               is_list(a["mapping"]["atlas"])

      assert is_list(a["ledger_diff"]) and is_list(a["refusal_codes"])
      assert is_integer(a["ledger_before"]) and is_integer(a["ledger_after"])
    end

    assert r["commit_sha"] =~ ~r/\A[0-9a-f]{40}\z/
    assert Enum.all?(r["attacks"], &(&1["commit_sha"] == r["commit_sha"]))
  end

  test "the production entrypoint refuses without config, serves one effect, has no crash points",
       %{report: r, only: only} do
    rows = Enum.filter(r["attacks"], &String.starts_with?(&1["id"], "C2C-E"))
    if is_nil(only), do: assert(Enum.map(rows, & &1["id"]) == ["C2C-E01", "C2C-E02", "C2C-E03"])
    assert Enum.all?(rows, &(&1["verdict"] == "pass"))
  end

  test "fault-injection attacks ran N times with a real SIGKILL", %{report: r, only: only} do
    n = r["fault_repetitions"]
    assert n in 1..50
    faults = Enum.filter(r["attacks"], &String.starts_with?(&1["id"], "C2C-F"))
    if is_nil(only), do: assert(length(faults) == 4)
    for f <- faults, do: assert(f["iterations"] == n, "#{f["id"]} ran #{f["iterations"]} of #{n}")
  end

  test "the control-plane environment holds no protected key material, and the scan can fire", %{
    report: r
  } do
    scan = r["key_material_scan"]
    assert scan["leaks"] == []

    assert scan["selftest_complete"],
           "scan self-test did not detect every planted needle: #{inspect(scan["selftest_detected"])}"

    assert "key:svc" in scan["selftest_detected"] and "path:act_dir" in scan["selftest_detected"]
    assert Enum.sort(scan["compromised_by_design"]) == ["A", "A2", "alice"]
  end

  test "authority, actuator and keymaster are separate processes with distribution disabled", %{
    report: r
  } do
    assert r["hosting_scope"] =~ "separate-process, same-host"
    assert is_binary(r["fleet_processes"]["keymaster_os_pid"])
  end

  test "mutation court: every fence check is necessary; check 10 is jointly necessary with 11", %{
    report: r
  } do
    m = r["mutation"]

    if m["skipped"] do
      flunk("mutation court skipped")
    else
      survivors = for e <- m["per_check"], e["status"] != "killed", do: e["check"]

      assert survivors == [],
             "fence checks whose removal no attack detected: #{inspect(survivors)}"

      assert m["check_10_and_11"]["status"] == "killed"

      assert m["check_10_alone"]["status"] == "survived",
             "check 10 alone is now isolated: give it a killer_for"

      assert Enum.sort(Enum.map(m["per_check"], & &1["check"])) == Enum.to_list(1..16) -- [10]
    end
  end

  test "the unfenced always-allow actuator fails the court", %{report: r} do
    m = r["mutation"]
    if m["skipped"], do: flunk("mutation court skipped")
    assert m["allow_all"]["status"] == "killed"
    assert length(m["allow_all"]["killed_by"]) >= 10
  end

  test "compat probes record the AuthorityService <-> Actuator schema gap explicitly", %{
    report: r
  } do
    probes = r["compat"]
    assert length(probes) == 2
    assert Enum.all?(probes, &(&1["observed"] != nil))
  end

  test "overall verdict", %{report: r, only: only} do
    if is_nil(only),
      do: assert(r["summary"]["overall"] == "PASS", inspect(r["summary"]["overall_checks"]))
  end
end
