# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DurableConformance.StrictC1ChecksTest do
  @moduledoc """
  The verifier's `c1.security_profile_strict`, `c1.durable_claim_store` and
  `c1.keyed_journal` checks are PASSABLE by real configuration and still
  refuse weak configuration (anti-vacuity: each weakening flips its check).

  In-process: a real `:strict` profile module compiled from the real template,
  the real durable claim store, a real keyed journal directory and a real HMAC
  key custody provider. The full subprocess run under `MIX_ENV=conformance`
  is opt-in (`ASH_A2A_STRICT_CONFORMANCE_COURT=1`) because it compiles a whole
  build environment; see docs/reference/conformance-profiles.md.
  """
  use ExUnit.Case, async: false

  alias AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile
  alias AshA2A.ConsequenceKernel.KeyCustody.HmacSha256
  alias AshA2A.SA2A.Conformance.Checks.C1

  @key String.duplicate("s", 32)

  defmodule StrictProfile do
    use AshA2A.SecurityProfile.Template, env: :prod, requested: :strict
  end

  defmodule DevProfile do
    use AshA2A.SecurityProfile.Template, env: :test, requested: :dev_bypass
  end

  defp dir do
    d =
      Path.join([
        Mix.Project.build_path(),
        "durable_courts",
        "conf_#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf!(d) end)
    d
  end

  defp ctx(over \\ %{}) do
    Map.merge(
      %{
        security_profile_module: StrictProfile,
        claim_store: DurableFile,
        journal_dir: dir(),
        journal_key_provider: {HmacSha256, [key: @key]}
      },
      over
    )
  end

  test "all three checks pass under real strict configuration" do
    c = ctx()
    assert {:pass, _} = C1.security_profile_strict(c)
    assert {:pass, _} = C1.durable_claim_store(c)
    assert {:pass, _} = C1.keyed_journal(c)
  end

  test "the keyed journal check passes against a journal the real Journal module wrote" do
    d = dir()

    {:ok, h} =
      AshA2A.ConsequenceKernel.PreparedEffectStore.Journal.open(d, {HmacSha256, [key: @key]})

    :ok =
      AshA2A.ConsequenceKernel.PreparedEffectStore.Journal.put(h, %{
        digest: "x",
        bytes: "b",
        tag: "t",
        state: :prepared
      })

    assert {:pass, _} = C1.keyed_journal(ctx(%{journal_dir: d}))
  end

  test "anti-vacuity: weakening each input flips its check to fail" do
    assert {:fail, _} = C1.security_profile_strict(ctx(%{security_profile_module: DevProfile}))
    assert {:fail, _} = C1.durable_claim_store(ctx(%{claim_store: AshA2A.C2.MemoryClaimStore}))
    assert {:fail, _} = C1.durable_claim_store(ctx(%{claim_store: AshA2A.C2.ClaimStoreETS}))
    assert {:fail, _} = C1.durable_claim_store(ctx(%{claim_store: nil}))
    tmp = Path.join(System.tmp_dir!(), "j_#{System.unique_integer([:positive])}")
    assert {:fail, _} = C1.keyed_journal(ctx(%{journal_dir: tmp}))
    assert {:fail, _} = C1.keyed_journal(ctx(%{journal_key_provider: nil}))

    assert {:fail, _} =
             C1.keyed_journal(ctx(%{journal_key_provider: {HmacSha256, [key: "short"]}}))
  end

  test "the profile cannot be selected by task options or request data" do
    # current/0 takes no arguments and the check reads only the compiled module.
    refute function_exported?(StrictProfile, :current, 1)

    assert {:fail, _} =
             C1.security_profile_strict(
               ctx(%{security_profile_module: DevProfile, profile: :strict})
             )
  end

  @tag skip:
         System.get_env("ASH_A2A_STRICT_CONFORMANCE_COURT") != "1" &&
           "opt-in: set ASH_A2A_STRICT_CONFORMANCE_COURT=1 (compiles the conformance build env)"
  test "MIX_ENV=conformance mix ash_a2a.verify_conformance --profile c1 passes the three checks" do
    data = dir()
    File.mkdir_p!(data)

    {out, _status} =
      System.cmd("mix", ["ash_a2a.verify_conformance", "--profile", "c1", "--report"],
        env: [
          {"MIX_ENV", "conformance"},
          {"ASH_A2A_DATA_DIR", data},
          {"ASH_A2A_OUTBOX_KEY_B64", Base.encode64(@key)}
        ],
        stderr_to_stdout: true
      )

    for id <- ~w(c1.security_profile_strict c1.durable_claim_store c1.keyed_journal) do
      assert out =~ ~r/PASS\s+#{Regex.escape(id)}/, "#{id} did not PASS:\n#{out}"
    end
  end
end
