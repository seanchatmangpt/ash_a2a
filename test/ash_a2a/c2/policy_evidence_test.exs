defmodule AshA2A.C2.PolicyEvidenceTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{AuthorityRequest, PolicyEvidence, PreparedEffect}

  @pdp "https://pdp.example.com"
  @meta %{
    "policy_decision_point" => @pdp,
    "access_evaluation_endpoint" => "https://pdp.example.com/access/v1/evaluation",
    "x_vendor_extension" => %{"anything" => "ignored"}
  }

  defp request(overrides \\ %{}) do
    effect = PreparedEffect.new("alice", "wire.transfer", %{"acct" => "A1"}, %{"amount" => 5})

    ctx =
      Map.merge(
        %{policy_epoch: 3, revocation_epoch: 2, generation: 7, audience: "actuator://bank"},
        overrides
      )

    AuthorityRequest.new(effect, ctx)
  end

  test "allow becomes evidence bound to the exact effect, never DO authority" do
    r = request()
    assert {:ok, e} = PolicyEvidence.from_response(r, %{"decision" => true}, @pdp, @meta)
    assert e.decision == :allow
    assert PolicyEvidence.binds?(e, r)
    refute PolicyEvidence.grants_do_authority?(e)
  end

  test "evidence does not bind a different effect digest or stale fence" do
    {:ok, e} = PolicyEvidence.from_response(request(), %{"decision" => true}, @pdp, @meta)
    other = PreparedEffect.new("alice", "wire.transfer", %{"acct" => "A1"}, %{"amount" => 500})
    refute PolicyEvidence.binds?(e, %{request() | effect: other, effect_digest: other.digest})
    refute PolicyEvidence.binds?(e, request(%{generation: 8}))
    refute PolicyEvidence.binds?(e, request(%{policy_epoch: 4}))
  end

  test "PDP identifier mix-up is refused" do
    meta = Map.put(@meta, "policy_decision_point", "https://evil.example.com")

    assert {:error, :pdp_mismatch} =
             PolicyEvidence.from_response(request(), %{"decision" => true}, @pdp, meta)
  end

  test "non-HTTPS endpoint is refused; unknown metadata is ignored" do
    meta = Map.put(@meta, "access_evaluation_endpoint", "http://pdp.example.com/eval")

    assert {:error, :pdp_endpoint_not_https} =
             PolicyEvidence.from_response(request(), %{"decision" => true}, @pdp, meta)

    assert :ok = PolicyEvidence.validate_metadata(@meta, @pdp)
  end

  test "decision must be a JSON boolean" do
    for bad <- ["true", 1, nil] do
      assert {:error, :decision_malformed} =
               PolicyEvidence.from_response(request(), %{"decision" => bad}, @pdp, @meta)
    end

    assert {:ok, %{decision: :deny}} =
             PolicyEvidence.from_response(request(), %{"decision" => false}, @pdp, @meta)
  end

  test "SARC request carries digest, principal and fences" do
    r = request()
    assert {:ok, sarc} = PolicyEvidence.sarc_request(r)
    assert sarc["subject"]["id"] == "alice"
    assert sarc["action"]["name"] == "wire.transfer"
    assert sarc["resource"]["id"] == r.effect_digest
    assert sarc["context"]["generation"] == 7
  end
end

defmodule AshA2A.C2.PolicyEvidenceAdmissionTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{AuthorityRequest, AuthorityService, PolicyEvidence, PreparedEffect}
  alias AshA2A.C2.PolicyEvidence.PdpClient

  defmodule Policy do
    def admit(_r, _c), do: :ok
    def issue(_r, _c), do: {:ok, :cert}
  end

  @pdp "https://pdp.example.com"
  @ctx %{policy_epoch: 1, revocation_epoch: 1, generation: 1, audience: "a"}

  defp request do
    AuthorityRequest.new(PreparedEffect.new("alice", "cap", %{}, %{}), @ctx)
  end

  defp stub(name, decision) do
    Req.Test.stub(name, fn conn ->
      case conn.request_path do
        "/.well-known/authzen-configuration" ->
          Req.Test.json(conn, %{
            "policy_decision_point" => @pdp,
            "access_evaluation_endpoint" => @pdp <> "/access/v1/evaluation"
          })

        _ ->
          Req.Test.json(conn, %{"decision" => decision})
      end
    end)
  end

  test "allow without evidence is refused when evidence is required" do
    ctx = Map.put(@ctx, :policy_evidence_required, true)

    assert {:ok, %{decision: :refuse, reason: :policy_evidence_missing}} =
             AuthorityService.authorize(Policy, request(), ctx)
  end

  test "bound allow evidence admits only through the authority" do
    stub(:allow, true)
    {:ok, e} = PdpClient.evidence(request(), @pdp, plug: {Req.Test, :allow})
    ctx = Map.merge(@ctx, %{policy_evidence_required: true, policy_evidence: e})
    assert {:ok, %{decision: :admit}} = AuthorityService.authorize(Policy, request(), ctx)
    refute PolicyEvidence.grants_do_authority?(e)
  end

  test "deny evidence is refused" do
    stub(:deny, false)
    {:ok, e} = PdpClient.evidence(request(), @pdp, plug: {Req.Test, :deny})
    ctx = Map.merge(@ctx, %{policy_evidence_required: true, policy_evidence: e})
    assert {:ok, %{decision: :refuse}} = AuthorityService.authorize(Policy, request(), ctx)
  end

  test "non-HTTPS PDP is refused before any request" do
    assert {:error, :pdp_not_https} = PdpClient.evidence(request(), "http://pdp.example.com")
  end
end
