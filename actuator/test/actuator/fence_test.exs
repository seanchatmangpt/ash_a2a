defmodule Actuator.FenceTest do
  @moduledoc """
  One court per fence check. For each of the 16 checks a case mutates exactly ONE field
  of an otherwise valid, really-signed request and asserts (a) the fence refuses at that
  check number with that code, and (b) NECESSITY: running the same request with only that
  check skipped passes the whole fence, so no other check catches the mutation. Real keys,
  real ECDSA P-256 signatures produced with :crypto (independent of the verifier).
  """
  use ExUnit.Case, async: true
  alias Actuator.{Fence, Kit}

  defp run(built, view \\ Kit.view(), opts \\ []) do
    Fence.run(built.ctx, Kit.request(built), view, opts)
  end

  defp view_for(nil, _built), do: Kit.view()

  defp view_for(rec, built) do
    req = Kit.request(built)

    Kit.view(
      Map.merge(
        %{instance_id: req.effect.effect_instance_id, effect_digest: req.cert.effect_digest},
        rec
      )
    )
  end

  test "baseline: a valid request passes all 16 checks" do
    assert :ok = run(Kit.build())
  end

  @cases [
    {1, :unsupported_protocol_version, [effect: %{"v" => 2}], nil},
    {2, :effect_digest_mismatch, [effect_after: %{"params" => %{"entry" => "tampered"}}], nil},
    {3, :principal_mismatch, [cert: %{"principal" => "agent:mallory"}], nil},
    {4, :subject_not_allowed, [effect: %{"subject" => "subject:orders/43"}], nil},
    {5, :capability_mismatch, [effect: %{"capability" => "actuator.shell.exec"}], nil},
    {6, :consequence_class_mismatch, [effect: %{"consequence_class" => "external_irreversible"}],
     nil},
    {7, :bad_effect_instance, [effect: %{"effect_instance_id" => "bad id!"}], nil},
    {8, :resource_bounds_exceeded, [effect: %{"resource_bounds" => %{"max_bytes" => 2}}], nil},
    {9, :policy_epoch_stale, [ctx: [policy_epoch: 4]], nil},
    {10, :bad_signature, [signers: 2, tamper_sig: 0], nil},
    {11, :quorum_not_met, [signers: 2, custodians: ["c1", "c1"], ctx: [quorum_default: 2]], nil},
    {12, :expired, [cert: %{"not_before" => 1_800_000_000 - 601, "expires" => 1_800_000_000 - 1}],
     nil},
    {13, :revocation_view_stale, [revocation: %{refreshed_at: 1_800_000_000 - 301}], nil},
    {14, :claim_held, [], %{state: :executing, generation: 1}},
    {15, :effect_already_completed, [], %{state: :completed, generation: 1}},
    {16, :generation_stale, [cert: %{"generation" => 2}], nil}
  ]

  for {n, code, opts, record} <- @cases do
    test "check #{n} refuses #{code} and is necessary (skip-only-#{n} passes)" do
      built = Kit.build(unquote(Macro.escape(opts)))
      view = view_for(unquote(Macro.escape(record)), built)

      assert {:error, unquote(n), unquote(code)} = run(built, view)
      assert :ok = run(built, view, skip: [unquote(n)])
    end
  end

  test "there are exactly 16 checks, numbered 1..16, each its own public function" do
    assert Enum.map(Fence.checks(), &elem(&1, 0)) == Enum.to_list(1..16)
    for {_, f} <- Fence.checks(), do: assert(function_exported?(Fence, f, 3))
  end
end
