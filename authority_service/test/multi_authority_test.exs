defmodule AuthorityService.MultiAuthorityTest do
  @moduledoc """
  Two independent authorities (two keys, two journals) issue the same effect; their
  certificates combine into one actuator certificate carrying both signatures. The second
  authority adopts the first one's validity window through the optional `"window"`, which can
  only narrow what its own policy would have granted.
  """
  use ExUnit.Case, async: true
  alias AuthorityService.{Issuer, Listener, TestKit}
  import TestKit

  defp setup_effect(a) do
    e = actuator_effect()
    bytes = effect_bytes(e)
    d = digest(bytes)
    apps = for n <- ~w(bob carol), do: approval(signer_named(a, n), d)
    {e, apps}
  end

  defp actuator_effect do
    %{
      "v" => 1,
      "principal" => "agent:alice",
      "subject" => "subject:orders/42",
      "capability" => "actuator.ledger.append",
      "consequence_class" => "internal_append",
      "effect_type" => "ledger_append",
      "effect_instance_id" => "ei:multi-1",
      "resource_bounds" => %{"max_bytes" => 256},
      "policy_epoch" => 3,
      "params" => %{"entry" => "x"}
    }
  end

  defp policy2,
    do:
      policy(
        classes: %{"internal_append" => [%{max_amount: :infinity, k: 2}]},
        approvers: ["alice", "bob", "carol"]
      )

  defp window_of(cert) do
    {:ok, ac} = Issuer.to_actuator_certificate(cert)
    %{"not_before" => ac["not_before"], "expires" => ac["expires"]}
  end

  test "a second authority adopting the first window yields combinable certificates" do
    a = start_issuer(%{policy: policy2()})
    b = start_issuer(%{approvers: a.approvers, policy: policy2(), svc: signer("svc-b", :i2)})
    {e, apps} = setup_effect(a)
    req = request(e, apps)

    assert {:ok, c1} = Issuer.issue(a.issuer, req, now: now())

    # the second authority's own clock is two seconds later: without the window the fields differ
    assert {:ok, c2_own} = Issuer.issue(b.issuer, req, now: now() + 2)

    assert {:error, :certificate_fields_differ} =
             Issuer.combine_actuator_certificates([c1, c2_own])

    # a fresh pair of authorities, now with the window carried over
    a2 = start_issuer(%{policy: policy2()})
    b2 = start_issuer(%{approvers: a2.approvers, policy: policy2(), svc: signer("svc-b", :i2)})
    {e2, apps2} = setup_effect(a2)
    req2 = request(e2, apps2)
    assert {:ok, d1} = Issuer.issue(a2.issuer, req2, now: now())
    windowed = Map.put(req2, "window", window_of(d1))
    assert {:ok, d2} = Issuer.issue(b2.issuer, windowed, now: now() + 2)

    assert {:ok, combined} = Issuer.combine_actuator_certificates([d1, d2])
    assert [%{"kid" => k1}, %{"kid" => k2}] = combined["signatures"]
    assert k1 == a2.config.service_key.kid and k2 == b2.config.service_key.kid
    assert combined["not_before"] == now() and combined["expires"] == window_of(d1)["expires"]
  end

  test "the same authority twice is a duplicate signer, never a quorum" do
    a = start_issuer(%{policy: policy2()})
    {e, apps} = setup_effect(a)
    assert {:ok, c} = Issuer.issue(a.issuer, request(e, apps), now: now())
    assert {:error, :duplicate_signer} = Issuer.combine_actuator_certificates([c, c])
    assert {:error, :malformed_certificate} = Issuer.combine_actuator_certificates([])
    assert {:error, :malformed_certificate} = Issuer.combine_actuator_certificates([%{}])
  end

  describe "window bounds, over the real unix-socket wire" do
    defp frame(term) do
      b = Jason.encode!(term)
      <<byte_size(b)::32, b::binary>>
    end

    defp call(path, payload) do
      {:ok, s} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw])
      :ok = :gen_tcp.send(s, payload)
      {:ok, <<len::32>>} = :gen_tcp.recv(s, 4, 2000)
      {:ok, body} = :gen_tcp.recv(s, len, 2000)
      :gen_tcp.close(s)
      Jason.decode!(body)
    end

    test "a window wider than policy, outside the skew, empty or malformed is refused" do
      ctx = start_issuer(%{policy: policy2()})
      sock = Path.join(ctx.dir, "w.sock")

      {:ok, _} =
        Listener.start_link(issuer: ctx.issuer, transport: {:unix, sock}, max_bytes: 65_536)

      {e, apps} = setup_effect(ctx)
      t = now()

      issue = fn win ->
        r = request(e, apps, %{"window" => win})
        call(sock, frame(Map.put(r, "op", "issue")))
      end

      # the listener uses the service clock (TestKit.now/0), the same one that dated the approvals
      for {win, code} <- [
            {%{"not_before" => t, "expires" => t + 100_000}, "window_invalid"},
            {%{"not_before" => t + 3_600, "expires" => t + 3_700}, "window_invalid"},
            {%{"not_before" => t, "expires" => t}, "window_invalid"},
            {%{"not_before" => "x", "expires" => t + 5}, "malformed_request"},
            {%{"not_before" => t}, "malformed_request"}
          ] do
        assert %{"ok" => false, "refusal" => ^code} = issue.(win)
      end

      # nothing was journaled by the refusals: the same approvals still issue, narrowed
      assert %{"ok" => true} = issue.(%{"not_before" => t, "expires" => t + 100})
    end
  end

  test "a window may not extend past the expiry the authority would itself choose" do
    ctx = start_issuer(%{policy: policy2()})
    {e, apps} = setup_effect(ctx)
    req = request(e, apps)

    # natural expiry is the earliest approval expiry (now + 200)
    wide = Map.put(req, "window", %{"not_before" => now(), "expires" => now() + 250})
    assert {:refused, :window_invalid, _} = Issuer.issue(ctx.issuer, wide, now: now())

    far = Map.put(req, "window", %{"not_before" => now() + 60, "expires" => now() + 100})
    assert {:refused, :window_invalid, _} = Issuer.issue(ctx.issuer, far, now: now())

    empty = Map.put(req, "window", %{"not_before" => now(), "expires" => now()})
    assert {:refused, :window_invalid, _} = Issuer.issue(ctx.issuer, empty, now: now())

    bad = Map.put(req, "window", %{"not_before" => now(), "expires" => now() + 100, "x" => 1})
    assert {:refused, :malformed_request, _} = Issuer.issue(ctx.issuer, bad, now: now())

    # refusals journal nothing: the same request with an acceptable (narrower) window issues
    ok = Map.put(req, "window", %{"not_before" => now() - 3, "expires" => now() + 100})
    assert {:ok, cert} = Issuer.issue(ctx.issuer, ok, now: now())
    assert %{"not_before" => nb, "expires" => ex} = window_of(cert)
    assert nb == now() - 3 and ex == now() + 100
  end
end
