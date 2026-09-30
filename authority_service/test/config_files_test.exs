defmodule AuthorityService.ConfigFilesTest do
  use ExUnit.Case, async: true
  alias AuthorityService.{Config, Issuer, TestKit}
  import TestKit

  test "from_files builds a working service from policy + registry + 0600 key file" do
    dir = tmp_dir("cfg")
    svc = signer("authority-service", :i2)
    key = write_key(dir, svc.priv)
    alice = signer("alice")

    File.write!(Path.join(dir, "policy.json"), ~s({
      "epoch": 3, "approvers": ["alice"], "min_approver_tier": "i3",
      "classes": {"payment": [{"max_amount": 100000, "k": 1}, {"max_amount": "infinity", "k": 1}]}
    }))

    File.write!(
      Path.join(dir, "approvers.json"),
      Jason.encode!([
        %{
          "public_key" => Base.url_encode64(alice.pub, padding: false),
          "custodian_id" => "alice",
          "custody_tier" => "i3",
          "state" => "active",
          "revocation_epoch" => 4
        }
      ])
    )

    assert {:ok, cfg} =
             Config.from_files(
               key_path: key,
               policy_path: Path.join(dir, "policy.json"),
               registry_path: Path.join(dir, "approvers.json"),
               authority_audience: authority_audience(),
               actuator_audience: actuator(),
               journal_path: Path.join(dir, "j.log")
             )

    {:ok, pid} = Issuer.start_link(config: %{cfg | clock: &TestKit.now/0}, name: nil)
    e = effect()
    d = digest(effect_bytes(e))
    assert {:ok, _} = Issuer.issue(pid, request(e, [approval(alice, d)]))

    # a policy whose tier needs more approvers than registered is refused at load
    File.write!(Path.join(dir, "bad.json"), ~s({"epoch": 1, "approvers": ["a"],
      "classes": {"p": [{"max_amount": "infinity", "k": 2}]}}))

    assert {:error, :policy_malformed} =
             Config.from_files(
               key_path: key,
               policy_path: Path.join(dir, "bad.json"),
               registry_path: Path.join(dir, "approvers.json"),
               authority_audience: "x",
               actuator_audience: actuator(),
               journal_path: Path.join(dir, "j2.log")
             )
  end

  test "a config with no registered actuator audience is refused (fail closed)" do
    dir = tmp_dir("cfg-noact")
    key = write_key(dir, signer("authority-service", :i2).priv)
    File.write!(Path.join(dir, "policy.json"), ~s({"epoch": 1, "approvers": ["a"],
      "classes": {"p": [{"max_amount": "infinity", "k": 1}]}}))
    File.write!(Path.join(dir, "approvers.json"), "[]")

    assert {:error, :actuator_audience_missing} =
             Config.from_files(
               key_path: key,
               policy_path: Path.join(dir, "policy.json"),
               registry_path: Path.join(dir, "approvers.json"),
               authority_audience: "x",
               journal_path: Path.join(dir, "j.log")
             )
  end
end
