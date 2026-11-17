# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sim.ParityV11Test do
  @moduledoc """
  A2A v1.1 parity of the simulation server's wire output against the upstream
  reference, byte for byte.

  The reference is independent of this library's codec: Python stubs generated
  from `v1.1.0-rc:specification/a2a.proto` and the official protobuf runtime
  (`scripts/a2a_v1_1_parity`). The test needs the virtual environment that
  `scripts/a2a_v1_1_parity/setup.sh` creates (`$A2A_PARITY_VENV`, default
  `/tmp/a2a_v1_1_parity/venv`); without it every test here is skipped with the
  reason.

      scripts/a2a_v1_1_parity/setup.sh
      mix test test/ash_a2a/sim/sim_parity_v1_1_test.exs
  """

  use ExUnit.Case, async: false

  alias AshA2A.Sim.{Parity, Server}

  @moduletag timeout: 240_000
  @moduletag capture_log: true
  @moduletag :a2a_parity

  case Parity.check() do
    {:ok, _python} -> :ok
    {:skip, reason} -> @moduletag skip: reason
  end

  @findings Path.expand("../../../docs/reference/a2a-v1-1-parity-findings.md", __DIR__)
  @vendored_proto Path.expand("../../../priv/a2a_v1_1_spec_corpus/a2a.proto", __DIR__)

  setup_all do
    case Parity.check() do
      {:skip, _reason} ->
        :ok

      {:ok, _python} ->
        {:ok, server} = Server.start_link()
        on_exit(fn -> if Process.alive?(server), do: Server.stop(server) end)
        {:ok, report} = Parity.run(Server.info())
        {:ok, report: report}
    end
  end

  test "the reference is the upstream v1.1.0-rc proto, the same bytes as the vendored copy", %{
    report: report
  } do
    vendored =
      @vendored_proto
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    pinned = Parity.script_dir() |> Path.join("a2a.proto.sha256") |> File.read!() |> String.trim()

    assert report["reference"]["sha256"] == pinned
    assert vendored == pinned
  end

  test "no row fails", %{report: report} do
    failed = Enum.filter(report["rows"], &(&1["status"] == "fail"))

    assert failed == [],
           "A2A v1.1 parity mismatches:\n" <>
             Enum.map_join(failed, "\n", fn row ->
               "  #{row["binding"]} | #{row["operation"]} | #{row["vector"]} | #{row["check"]}: #{row["detail"]}"
             end)
  end

  test "every response is byte-identical to the reference on every binding", %{report: report} do
    # `strict`, `wire` and `required` are the byte-level checks. A known defect
    # may be a wrong status or a missing event, never a wrong byte.
    for row <- report["rows"], row["check"] in ["strict", "wire", "required"] do
      assert row["status"] == "pass",
             "#{row["binding"]} | #{row["operation"]} | #{row["vector"]} | #{row["check"]}: #{row["detail"]}"
    end

    for binding <- ["grpc", "http+json", "jsonrpc"] do
      checked = Enum.count(report["rows"], &(&1["binding"] == binding and &1["check"] == "wire"))
      assert checked > 40, "only #{checked} wire comparisons over #{binding}"
    end
  end

  test "every RPC of the upstream service is exercised on each full binding", %{report: report} do
    rows = Enum.filter(report["rows"], &(&1["binding"] == "coverage"))
    assert length(rows) >= 5
    assert Enum.all?(rows, &(&1["status"] == "pass")), inspect(rows, pretty: true)
  end

  test "one task is the same message over gRPC, HTTP+JSON and JSON-RPC", %{report: report} do
    rows = Enum.filter(report["rows"], &(&1["binding"] == "cross-binding"))
    assert length(rows) >= 7
    assert Enum.all?(rows, &(&1["status"] == "pass")), inspect(rows, pretty: true)
  end

  test "every known defect is written up in the findings", %{report: report} do
    findings = File.read!(@findings)

    for id <- report["known_defects"] do
      assert findings =~ "### #{id}:", "#{id} has no section in #{@findings}"
    end

    assert report["summary"]["known"] ==
             Enum.count(report["rows"], &(&1["status"] == "known"))
  end

  test "the report states every normalisation it applies", %{report: report} do
    assert length(report["normalisations"]) >= 6

    for item <- report["normalisations"] do
      assert item["what"] != "" and item["how"] != "" and item["why"] != ""
    end
  end
end
