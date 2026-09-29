defmodule AuthorityServiceTest do
  use ExUnit.Case, async: true
  alias AuthorityService.{Issuer, TestKit}
  alias Sa2aCrypto.{Envelope, Registry.Static}
  import TestKit

  setup do
    {:ok, start_issuer()}
  end

  defp issue(ctx, req, opts \\ []), do: Issuer.issue(ctx.issuer, req, [now: now()] ++ opts)

  defp verify_cert(ctx, cert, opts \\ []) do
    {:ok, env} = Envelope.decode(Jason.encode!(cert["envelope"]))
    {:ok, bytes} = Base.url_decode64(cert["message"], padding: false)
    # public key only: the verifier registry holds no private material
    view =
      Static.view([
        %{
          ctx.svc.record
          | kid: ctx.config.service_key.kid,
            public_key: ctx.config.service_key.public_key
        }
      ])

    Sa2aCrypto.verify_envelope(
      env,
      bytes,
      view,
      Keyword.merge([now: now(), audience: actuator()], opts)
    )
  end

  defp two_approvals(ctx, digest) do
    for n <- ~w(alice bob), do: approval(signer_named(ctx, n), digest)
  end

  test "issues a certificate only for the exact digest; verifies with the public key only", ctx do
    e = effect(%{"amount" => 500_000})
    bytes = effect_bytes(e)
    req = request(e, two_approvals(ctx, digest(bytes)))
    assert {:ok, cert} = issue(ctx, req)
    assert {:valid, %{kid: kid}} = verify_cert(ctx, cert)
    assert kid == ctx.config.service_key.kid
    {:ok, msg_bytes} = Base.url_decode64(cert["message"], padding: false)
    {:ok, msg} = Sa2aCrypto.SignedMessage.parse(msg_bytes)
    assert msg["effect_digest"] == digest(bytes)
    assert msg["audience"] == actuator()
    assert msg["generation"] == 9
    assert msg["policy_epoch"] == 3
    # 2-of-n human tier: TTL bounded by the 300s human window
    assert msg["expires"] - msg["not_before"] <= 300
    # the certificate is not valid for any other actuator
    assert {:invalid, :wrong_audience} = verify_cert(ctx, cert, audience: "actuator:other")
  end

  test "digest that does not match the presented bytes is refused", ctx do
    e = effect(%{"amount" => 500_000})
    good = digest(effect_bytes(e))
    forged = request(e, two_approvals(ctx, good), %{"effect_digest" => digest("something else")})
    assert {:refused, :digest_mismatch, _} = issue(ctx, forged)
  end

  test "approvals signed over a different effect are not counted", ctx do
    other = digest(effect_bytes(effect(%{"amount" => 1})))
    e = effect(%{"amount" => 500_000})
    req = request(e, two_approvals(ctx, other))
    assert {:refused, :insufficient_approvals, detail} = issue(ctx, req)
    assert :approval_effect_mismatch in detail
  end

  test "approval from an expired policy epoch is refused", ctx do
    e = effect()
    d = digest(effect_bytes(e))
    req = request(e, [approval(signer_named(ctx, "alice"), d, %{"policy_epoch" => 2})])
    assert {:refused, :insufficient_approvals, detail} = issue(ctx, req)
    assert :stale_policy_epoch in detail
    req2 = request(e, [approval(signer_named(ctx, "alice"), d, %{"policy_epoch" => 4})])
    assert {:refused, :insufficient_approvals, d2} = issue(ctx, req2)
    assert :policy_epoch_mismatch in d2
  end

  test "insufficient approvals are refused", ctx do
    e = effect(%{"amount" => 500_000})
    d = digest(effect_bytes(e))
    req = request(e, [approval(signer_named(ctx, "alice"), d)])
    assert {:refused, :insufficient_approvals, []} = issue(ctx, req)
    assert {:refused, :insufficient_approvals, []} = issue(ctx, request(e, []))
  end

  test "a duplicate signer counts once", ctx do
    e = effect(%{"amount" => 500_000})
    d = digest(effect_bytes(e))
    alice = signer_named(ctx, "alice")
    req = request(e, [approval(alice, d), approval(alice, d)])
    assert {:refused, :insufficient_approvals, _} = issue(ctx, req)
  end

  test "two keys held by one custodian count once" do
    alice2 = signer("alice", :i3)
    base = start_issuer()
    ctx = start_issuer(%{approvers: [alice2 | base.approvers], dir: nil})
    e = effect(%{"amount" => 500_000})
    d = digest(effect_bytes(e))
    alice1 = Enum.find(base.approvers, &(&1.custodian == "alice"))
    req = request(e, [approval(alice1, d), approval(alice2, d)])
    assert {:refused, :insufficient_approvals, _} = issue(ctx, req)
  end

  test "approver below the minimum custody tier is not counted", _ do
    low = signer("alice", :i2)
    ctx = start_issuer(%{approvers: [low, signer("bob")]})
    e = effect()
    d = digest(effect_bytes(e))

    assert {:refused, :insufficient_approvals, detail} =
             issue(ctx, request(e, [approval(low, d)]))

    assert :approver_tier_too_low in detail
  end

  test "approval whose lifetime exceeds the 300s human TTL is not counted", ctx do
    e = effect()
    d = digest(effect_bytes(e))
    long = approval(signer_named(ctx, "alice"), d, %{"expires" => now() + 900})
    assert {:refused, :insufficient_approvals, detail} = issue(ctx, request(e, [long]))
    assert :approval_ttl_exceeded in detail
  end

  test "a forged approval signature is not counted", ctx do
    e = effect()
    d = digest(effect_bytes(e))
    a = approval(signer_named(ctx, "alice"), d)
    other = signer("alice")
    bad = approval(other, d, %{"kid" => signer_named(ctx, "alice").kid})
    assert {:refused, :insufficient_approvals, detail} = issue(ctx, request(e, [bad]))
    assert :approval_bad_signature in detail
    assert {:ok, _} = issue(ctx, request(e, [a]))
  end

  test "automated tier issues without approvals with the 900s automated TTL", ctx do
    e = effect(%{"amount" => 5_000, "idem" => "small"})
    assert {:ok, cert} = issue(ctx, request(e))
    {:ok, b} = Base.url_decode64(cert["message"], padding: false)
    {:ok, msg} = Sa2aCrypto.SignedMessage.parse(b)
    assert msg["expires"] - msg["not_before"] == 900
  end

  test "unknown effect class and malformed effect are refused", ctx do
    assert {:refused, :unknown_effect_class, _} =
             issue(ctx, request(effect(%{"effect_class" => "wire-everything"})))

    bytes = "not json"

    req =
      request(effect(), [], %{
        "effect" => Base.url_encode64(bytes, padding: false),
        "effect_digest" => digest(bytes)
      })

    assert {:refused, :malformed_effect, _} = issue(ctx, req)
    req = request(effect(%{"amount" => "lots"}))
    assert {:refused, :malformed_effect, _} = issue(ctx, req)
  end

  describe "actuator-shaped effects (one byte string for authority and actuator)" do
    defp actuator_effect(over \\ %{}) do
      Map.merge(
        %{
          "v" => 1,
          "principal" => "agent:alice",
          "subject" => "subject:orders/42",
          "capability" => "actuator.ledger.append",
          "consequence_class" => "internal_append",
          "effect_type" => "ledger_append",
          "effect_instance_id" => "ei:0001-abcdef",
          "resource_bounds" => %{"max_bytes" => 256},
          "policy_epoch" => 3,
          "params" => %{"entry" => "hello"}
        },
        over
      )
    end

    defp internal_append_policy(k) do
      policy(classes: %{"internal_append" => [%{max_amount: :infinity, k: k}]})
    end

    test "class comes from consequence_class; an automated-tier class certifies the exact bytes" do
      ctx = start_issuer(%{policy: internal_append_policy(0)})
      e = actuator_effect()
      bytes = effect_bytes(e)

      req =
        request(e, [], %{
          "effect_digest" => digest(bytes),
          "effect" => Base.url_encode64(bytes, padding: false)
        })

      assert {:ok, cert} = Issuer.issue(ctx.issuer, req, now: now())
      {:ok, msg_bytes} = Base.url_decode64(cert["message"], padding: false)
      {:ok, msg} = Sa2aCrypto.SignedMessage.parse(msg_bytes)
      assert msg["effect_digest"] == digest(bytes)
      assert msg["principal"] == "agent:alice"
    end

    test "a class the policy does not name is refused (fail closed), and k>0 still needs approvals" do
      ctx = start_issuer(%{policy: internal_append_policy(0)})
      e = actuator_effect(%{"consequence_class" => "external_payment"})

      assert {:refused, :unknown_effect_class, _} =
               Issuer.issue(ctx.issuer, request(e), now: now())

      ctx = start_issuer(%{policy: internal_append_policy(2)})

      assert {:refused, :insufficient_approvals, _} =
               Issuer.issue(ctx.issuer, request(actuator_effect()), now: now())
    end

    test "a partial actuator-shaped effect is malformed, never defaulted" do
      ctx = start_issuer(%{policy: internal_append_policy(0)})
      e = actuator_effect() |> Map.delete("params")
      assert {:refused, :malformed_effect, _} = Issuer.issue(ctx.issuer, request(e), now: now())
    end
  end

  test "the same (effect, generation) is issued once; an approval is consumed once", ctx do
    e = effect(%{"amount" => 500_000})
    d = digest(effect_bytes(e))
    approvals = two_approvals(ctx, d)
    assert {:ok, _} = issue(ctx, request(e, approvals))
    assert {:refused, :already_issued, _} = issue(ctx, request(e, approvals))

    # the same (kid, nonce) twice inside one request counts once
    e2 = effect(%{"amount" => 500_000, "idem" => "e-3"})
    d2 = digest(effect_bytes(e2))
    a = approval(signer_named(ctx, "alice"), d2)
    assert {:refused, :insufficient_approvals, detail} = issue(ctx, request(e2, [a, a]))
    assert :approval_replayed in detail
  end

  test "solicits registered approvers through the pluggable channel", _ do
    e = effect()
    d = digest(effect_bytes(e))
    alice = signer("alice")
    a = approval(alice, d)
    {:ok, env} = Envelope.decode(Jason.encode!(a["envelope"]))
    {:ok, msg} = Base.url_decode64(a["message"], padding: false)

    channel =
      {AuthorityService.ApproverChannel.InMemory, %{"alice" => %{envelope: env, message: msg}}}

    ctx = start_issuer(%{approvers: [alice, signer("bob")], channel: channel})
    assert {:ok, cert} = issue(ctx, request(e))
    assert {:valid, _} = verify_cert(ctx, cert)
  end

  test "restart keeps the nonce journal: nothing is reissued", ctx do
    e = effect(%{"amount" => 500_000})
    d = digest(effect_bytes(e))
    approvals = two_approvals(ctx, d)
    {:ok, cert} = issue(ctx, request(e, approvals))
    {:ok, b} = Base.url_decode64(cert["message"], padding: false)
    {:ok, msg} = Sa2aCrypto.SignedMessage.parse(b)

    GenServer.stop(ctx.issuer)
    {:ok, pid} = Issuer.start_link(config: ctx.config, name: nil)
    ctx2 = %{ctx | issuer: pid}

    assert File.read!(ctx.config.journal_path) =~ msg["nonce"]
    assert {:refused, :already_issued, _} = issue(ctx2, request(e, approvals))
    e2 = effect(%{"amount" => 500_000, "idem" => "e-2"})
    d2 = digest(effect_bytes(e2))
    assert {:ok, cert2} = issue(ctx2, request(e2, two_approvals(ctx2, d2)))
    {:ok, b2} = Base.url_decode64(cert2["message"], padding: false)
    {:ok, msg2} = Sa2aCrypto.SignedMessage.parse(b2)
    refute msg2["nonce"] == msg["nonce"]
  end

  test "a tampered journal refuses to start", ctx do
    e = effect(%{"amount" => 500_000})
    d = digest(effect_bytes(e))
    {:ok, _} = issue(ctx, request(e, two_approvals(ctx, d)))
    GenServer.stop(ctx.issuer)
    body = File.read!(ctx.config.journal_path)

    File.write!(
      ctx.config.journal_path,
      String.replace(body, "\"generation\":9", "\"generation\":8", global: false)
    )

    Process.flag(:trap_exit, true)
    assert {:error, {:journal_corrupt, _}} = Issuer.start_link(config: ctx.config, name: nil)
  end

  test "key file with group/world access is refused; env never supplies key material" do
    dir = tmp_dir("keyperm")
    s = signer("x")
    path = write_key(dir, s.priv, 0o644)
    assert {:error, :key_file_permissions} = AuthorityService.KeyFile.load(path)
    File.chmod!(path, 0o600)
    assert {:ok, %{kid: kid}} = AuthorityService.KeyFile.load(path)
    assert kid == s.kid
    assert {:error, :key_file_unreadable} = AuthorityService.KeyFile.load(Path.join(dir, "nope"))
    File.write!(path, "garbage")
    assert {:error, :key_file_malformed} = AuthorityService.KeyFile.load(path)
  end

  test "release config: no Erlang distribution" do
    env = File.read!(Path.expand("../rel/env.sh.eex", __DIR__))
    assert env =~ "RELEASE_DISTRIBUTION=none"
    vm = File.read!(Path.expand("../rel/vm.args.eex", __DIR__))
    refute vm =~ ~r/^\s*-s?name\b/m
    refute vm =~ "-setcookie"
  end
end
