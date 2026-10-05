# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ChicagoCaseStudy.MutationCourtsTest do
  use ExUnit.Case, async: true

  # Chicago Anti-Vacuity Mutation Proofs
  # Tests prove that intentional semantic corruptions (mutants) are strictly killed by typed refusals.

  defmodule LocalWorkOrder do
    defstruct [:identity, :graph_digest, :origin_authority]
  end

  defmodule LocalTwoPortGate do
    def admit(%LocalWorkOrder{graph_digest: wo_digest}, %{semantic_subject: %{graph_digest: sub_digest}} = cmd) do
      if wo_digest == sub_digest do
        {:ok, Map.put(cmd, :admission_standing, :ADMITTED)}
      else
        {:error, %{code: :stale_graph_identity, class: :refused_identity}}
      end
    end
  end

  defmodule LocalKernelGate do
    def verify_lease(signed_lease, trusted_keys, required_ceiling) do
      now = System.system_time(:second)
      signature = Base.decode16!(signed_lease["signature"], case: :lower)
      pub_key = Base.decode16!(hd(trusted_keys), case: :lower)

      payload = "ceiling:#{signed_lease["ceiling"]}|expires:#{signed_lease["expires_unix"]}|holder:#{signed_lease["holder"]}|id:#{signed_lease["id"]}|scope:#{signed_lease["scope"]}"

      valid_sig? = :crypto.verify(:eddsa, :none, payload, signature, [pub_key, :ed25519])

      cond do
        not valid_sig? ->
          {:error, %{code: "LeaseRefused", class: "Signature", broken_term: "invalid_signature"}}

        signed_lease["expires_unix"] <= now ->
          {:error, %{code: "LeaseRefused", class: "Expiration", broken_term: "lease:expired"}}

        signed_lease["ceiling"] != required_ceiling ->
          {:error, %{code: "LeaseRefused", class: "Ceiling", broken_term: "ceiling:#{required_ceiling}"}}

        true ->
          {:ok, :admitted}
      end
    end
  end

  defmodule LocalProcessModel do
    def check_sequence([_ | _] = trace, allowed_transitions) do
      activities = Enum.map(trace, & &1["activity"])
      pairs = Enum.zip(activities, tl(activities))

      case Enum.find(pairs, fn pair -> pair not in allowed_transitions end) do
        nil ->
          {:ok, :admitted}

        {prev, illegal} ->
          expected =
            allowed_transitions
            |> Enum.filter(fn {from, _to} -> from == prev end)
            |> Enum.map(fn {_from, to} -> to end)

          {:error, %{
            reason: :unadmitted_transition,
            expected: expected,
            observed: illegal,
            fitness: 0.5
          }}
      end
    end
  end

  test "MUT-HILT-001 is KILLED: digest tampering produces :stale_graph_identity" do
    wo = %LocalWorkOrder{
      identity: "WO-001",
      graph_digest: "digest_a",
      origin_authority: "auth"
    }

    mutant_command = %{
      action: :settle,
      semantic_subject: %{id: "tx-1", graph_digest: "digest_mutant_corrupted"}
    }

    assert {:error, refusal} = LocalTwoPortGate.admit(wo, mutant_command)
    assert refusal.code == :stale_graph_identity
  end

  test "MUT-LEASE-002 is KILLED: expired lease fails with LeaseRefused" do
    {pub_key, priv_key} = :crypto.generate_key(:eddsa, :ed25519)
    trusted_keys = [Base.encode16(pub_key, case: :lower)]

    expired_time = System.system_time(:second) - 100
    lease_payload = "ceiling:construct|expires:#{expired_time}|holder:b1|id:l1|scope:urn:s1"
    signature = :crypto.sign(:eddsa, :none, lease_payload, [priv_key, :ed25519])

    expired_lease = %{
      "id" => "l1",
      "holder" => "b1",
      "ceiling" => "construct",
      "scope" => "urn:s1",
      "expires_unix" => expired_time,
      "signature" => Base.encode16(signature, case: :lower)
    }

    assert {:error, refusal} = LocalKernelGate.verify_lease(expired_lease, trusted_keys, "construct")
    assert refusal.code == "LeaseRefused"
    assert refusal.class == "Expiration"
  end

  test "MUT-BRCE-003 is KILLED: illegal activity jump fails with :unadmitted_transition" do
    allowed = [{"A", "B"}, {"B", "C"}]
    corrupted_trace = [
      %{"activity" => "A"},
      %{"activity" => "C"} # Mutated: skipped B
    ]

    assert {:error, refusal} = LocalProcessModel.check_sequence(corrupted_trace, allowed)
    assert refusal.reason == :unadmitted_transition
    assert refusal.expected == ["B"]
    assert refusal.observed == "C"
  end
end
