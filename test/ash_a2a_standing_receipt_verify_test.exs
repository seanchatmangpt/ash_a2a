defmodule AshA2a.StandingReceiptVerifyTest do
  use ExUnit.Case, async: false

  @repo "/Users/sac/ash_a2a"
  @receipt Path.join(@repo, "docs/sjira/v26.10.8/STANDING-RECEIPT.md")
  # Frozen pre-blake3 fixture, signed under the documented v26.10.8 mint key:
  # d3fcc7395405739f76d7570e0804e79d6a1e4e60b42b1b93642bf033e62d239b
  # (its seed is not retained, so the fixture cannot be re-minted under that
  # identity — the happy-path court re-mints under a fresh key instead).
  @attestation Path.join(@repo, "docs/sjira/v26.10.8/STANDING-RECEIPT.attestation.json")

  @tag :tmp_dir
  test "verifies a receipt attested by the CURRENT graphlaw-attest (exit 0, VERIFIED)", context do
    %{tmp_dir: tmp} = context
    out = tmp <> "/receipt.md"
    File.cp!(@receipt, out)
    att = Path.rootname(out) <> ".attestation.json"

    # The v26.10.8 fixture attestation is a FROZEN pre-blake3 artifact (signed
    # under the documented v26.10.8 key; its seed is not retained, so it cannot
    # be re-minted under that identity). It still passes stage 1 (payload_sha256)
    # and the tamper court below, but the blake3-era graphlaw-attest structurally
    # refuses it ("missing payload_blake3"). So this happy-path court re-mints a
    # LIVE attestation over the same receipt doc with the current CLI under a
    # fresh key, then verifies through the real mix task.
    attest_bin = "/Users/sac/graphlaw/target/debug/graphlaw-attest"
    seed = Base.encode16(:crypto.strong_rand_bytes(32))

    {_, 0} =
      System.cmd(attest_bin, ~w(sign --key-seed-hex #{seed} --in #{out} --out #{att}),
        stderr_to_stdout: true
      )

    pk =
      case System.cmd(attest_bin, ~w(pubkey --key-seed-hex #{seed}), stderr_to_stdout: true) do
        {pk, 0} -> String.trim(pk)
      end

    {stdout, 0} =
      System.cmd(
        "mix",
        ["ash_a2a.standing_receipt.verify", "--in", out, "--attestation", att, "--trusted-key", pk],
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
