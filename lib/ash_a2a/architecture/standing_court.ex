# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Architecture.StandingCourt do
  @moduledoc "Exact-subject, authority-free court for ABB/SBB selection evidence."

  # Embedded at compile time so the court does not depend on the source tree
  # layout at runtime (a release build has no ../../../priv relative to lib/).
  @policy_path Path.expand("../../../priv/architecture/standing.ttl", __DIR__)
  @external_resource @policy_path
  @policy_ttl File.read!(@policy_path)
  @required ~w(repository commit contract_digest candidate_digest qualification_digest observer_digest)
  @digest_fields ~w(contract_digest candidate_digest qualification_digest observer_digest)

  def policy do
    ttl = @policy_ttl

    states =
      Regex.scan(~r/arch:(UNKNOWN|REFUSED|ADMITTED)/, ttl, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    [authority] =
      Regex.run(~r/arch:authorityCeiling\s+"([^"]+)"/, ttl, capture: :all_but_first)

    %{states: states, authority: authority}
  end

  def judge(claim, evidence) when is_map(claim) and is_map(evidence) do
    policy = policy()
    reasons = reasons(claim, evidence)

    standing =
      cond do
        Enum.any?(reasons, &contradiction?/1) -> :refused
        reasons != [] -> :unknown
        true -> :admitted
      end

    ensure_policy!(policy, standing)

    receipt = %{
      version: 1,
      court: "ash_a2a.architecture.standing/v26.9.26",
      exact_subject: "#{get(claim, "repository") || "?"}@#{get(claim, "commit") || "?"}",
      claim_digest: digest(claim),
      evidence_digest: digest(evidence),
      standing: standing,
      authority: policy.authority,
      reasons: Enum.sort(reasons)
    }

    Map.put(receipt, :replay_digest, digest(receipt))
  end

  def replay(claim, evidence, receipt) do
    if judge(claim, evidence) == receipt, do: :ok, else: {:error, :replay_divergence}
  end

  defp reasons(claim, evidence) do
    missing =
      @required
      |> Enum.reject(&(present?(claim, &1) or present?(evidence, &1)))
      |> Enum.map(&{:missing_evidence, &1})

    mismatch =
      ~w(repository commit contract_digest candidate_digest)
      |> Enum.flat_map(fn field ->
        c = get(claim, field)
        e = get(evidence, field)

        if present_value?(c) and present_value?(e) and c != e,
          do: [{:exact_subject_mismatch, field}],
          else: []
      end)

    malformed =
      @digest_fields
      |> Enum.flat_map(fn field ->
        vals = [get(claim, field), get(evidence, field)] |> Enum.reject(&is_nil/1)
        if Enum.any?(vals, &(not digest64?(&1))), do: [{:malformed_digest, field}], else: []
      end)

    forged =
      if get(evidence, "self_attested_qualification") in [true, "true", 1] or
           get(evidence, "authority_granted_by_qualification") in [true, "true", 1],
         do: [{:forbidden_evidence, "authority_laundering"}],
         else: []

    observer =
      if present?(evidence, "observer_digest") and
           get(evidence, "observer_digest") == get(evidence, "qualification_digest"),
         do: [{:forbidden_evidence, "non_independent_observer"}],
         else: []

    Enum.uniq(missing ++ mismatch ++ malformed ++ forged ++ observer)
  end

  defp contradiction?({kind, _})
       when kind in [:exact_subject_mismatch, :malformed_digest, :forbidden_evidence], do: true

  defp contradiction?(_), do: false

  defp ensure_policy!(policy, standing) do
    token = standing |> Atom.to_string() |> String.upcase()
    unless MapSet.member?(policy.states, token), do: raise("standing not permitted by TTL policy")

    unless policy.authority == "NONE",
      do: raise("architecture qualification attempted authority escalation")
  end

  defp present?(map, key), do: present_value?(get(map, key))
  defp present_value?(v), do: is_binary(v) and byte_size(v) > 0
  defp get(map, key), do: Map.get(map, key) || Map.get(map, known_atom(key))

  defp known_atom("repository"), do: :repository
  defp known_atom("commit"), do: :commit
  defp known_atom("contract_digest"), do: :contract_digest
  defp known_atom("candidate_digest"), do: :candidate_digest
  defp known_atom("qualification_digest"), do: :qualification_digest
  defp known_atom("observer_digest"), do: :observer_digest
  defp known_atom("self_attested_qualification"), do: :self_attested_qualification
  defp known_atom("authority_granted_by_qualification"), do: :authority_granted_by_qualification

  defp digest64?(v) when is_binary(v), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, v)
  defp digest64?(_), do: false

  defp digest(term) do
    term
    |> canonical()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end)
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(v), do: v

  @doc false
  # S42 refusal totality: every typed refusal this module returns is classified
  # (merged into AshA2A.Semantic.Refusal.mapping/0 via AshA2A.Chicago.refusal_codes/0).
  def __sa2a_refusal_codes__ do
    %{
      replay_divergence: :refused_receipt
    }
  end
end
