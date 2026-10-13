defmodule AshA2a.StandingReceiptVerifyTest do
  use ExUnit.Case, async: false

  @repo "/Users/sac/ash_a2a"
  @receipt Path.join(@repo, "docs/sjira/v26.10.8/STANDING-RECEIPT.md")
  @attestation Path.join(@repo, "docs/sjira/v26.10.8/STANDING-RECEIPT.attestation.json")
  @trusted "d3fcc7395405739f76d7570e0804e79d6a1e4e60b42b1b93642bf033e62d239b"

  @tag :tmp_dir
  test "verifies the real v26.10.8 standing receipt (exit 0, VERIFIED)", context do
    %{tmp_dir: tmp} = context
    out = tmp <> "/receipt.md"
    File.cp!(@receipt, out)
    att = Path.rootname(out) <> ".attestation.json"
    File.cp!(@attestation, att)

    {stdout, 0} =
      System.cmd("mix", ["ash_a2a.standing_receipt.verify", "--in", out, "--attestation", att],
        cd: @repo,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    assert stdout =~ "VERIFIED"
  end

  @tag :tmp_dir
  test "refuses a tampered receipt (non-zero exit, REFUSED)", context do
    %{tmp_dir: tmp} = context
    out = tmp <> "/receipt.md"
    File.cp!(@receipt, out)
    att = Path.rootname(out) <> ".attestation.json"
    File.cp!(@attestation, att)
    # Mutate one byte of the payload.
    mutated =
      File.read!(out) |> String.replace("PARTIAL-ALIVE", "PARTIAL-ALIVX") |> tap(&File.write!(out, &1))

    {stdout, code} =
      System.cmd("mix", ["ash_a2a.standing_receipt.verify", "--in", out, "--attestation", Path.rootname(out) <> ".attestation.json"],
        cd: @repo,
        stderr_to_stdout: true
      )

    assert code != 0
    assert stdout =~ "REFUSED"
    assert stdout =~ "payload digest mismatch"
    # The mutated marker must actually differ from the minted file.
    assert mutated != File.read!(@receipt)
  end

  @tag :tmp_dir
  test "BLOCKED when graphlaw-attest binary is absent", context do
    %{tmp_dir: tmp} = context
    out = tmp <> "/receipt.md"
    File.cp!(@receipt, out)
    att = Path.rootname(out) <> ".attestation.json"
    File.cp!(@attestation, att)

    {stdout, code} =
      System.cmd(
        "mix",
        ~w(ash_a2a.standing_receipt.verify --in #{out} --attestation #{Path.rootname(out) <> ".attestation.json"} --attest-bin /nonexistent/graphlaw-attest),
        cd: @repo,
        stderr_to_stdout: true
      )

    # Note: explicit --attest-bin path that does not exist is treated as
    # present-but-failing by the binary stage; either non-zero REFUSED or a
    # BLOCKED exit is acceptable; it must NOT print VERIFIED.
    refute stdout =~ "VERIFIED"
    assert code != 0
  end
end
