# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SA2A.Conformance.Profiles do
  @moduledoc """
  Computes the conformance claim for profile C0..C3 (RFC-SA2A-007 section 4).

  A profile's requirement set is cumulative: `Cn` requires every check of `C0..Cn`
  plus the claim-scope checks and (from C2) the supply-chain block. The claim
  line is emitted only when every check passed; `:dev_bypass` and
  `:legacy_compat` security profiles force `NOT CONFORMANT`. Nothing here is
  narrated: statuses come from probes (see `AshA2A.SA2A.Conformance.Check`).
  """

  alias AshA2A.SA2A.Conformance.{Check, Claim, Context}
  alias AshA2A.SA2A.Conformance.Checks.{C0, C1, C2, C3, Supply}

  @profiles [:c0, :c1, :c2, :c3]
  @tiers ~w(I1 I2 I3 I4)
  @scopes ~w(same-host-os-user namespace-or-cluster physical-host)
  @forced [:dev_bypass, :legacy_compat]

  def profiles, do: @profiles

  @spec parse(String.t()) :: {:ok, atom()} | :error
  def parse(value) when is_binary(value) do
    case value |> String.downcase() |> String.trim() do
      "c0" -> {:ok, :c0}
      "c1" -> {:ok, :c1}
      "c2" -> {:ok, :c2}
      "c3" -> {:ok, :c3}
      _ -> :error
    end
  end

  @spec evaluate(atom(), map() | keyword()) :: map()
  def evaluate(profile, opts) when profile in @profiles do
    ctx = Context.build(opts)
    sha = C0.subject_sha(ctx)
    security = C1.resolve_security_profile(ctx)

    checks =
      profile
      |> chain()
      |> Enum.flat_map(&checks_for(&1, ctx))
      |> Kernel.++(claim_scope_checks(profile, ctx))
      |> Enum.uniq_by(& &1.id)

    failing = Enum.filter(checks, &(&1.status == :fail))
    unverified = Enum.filter(checks, &(&1.status == :unverified))

    forced =
      if security in @forced,
        do: ["security profile #{inspect(security)} can never conform"],
        else: []

    conformant? = failing == [] and unverified == [] and forced == [] and is_binary(sha)

    claim =
      if conformant? do
        Claim.statement(profile, ctx, sha)
      else
        Claim.refusal(
          profile,
          forced ++
            listing(failing, "failing") ++ listing(unverified, "unverified") ++ no_sha(sha)
        )
      end

    %{
      profile: profile,
      version: ctx.version,
      tier: ctx.tier,
      scope: ctx.scope,
      subject_sha: sha,
      security_profile: security,
      checks: checks,
      failing: failing,
      unverified: unverified,
      conformant?: conformant?,
      claim: claim
    }
  end

  defp chain(profile), do: Enum.take(@profiles, Enum.find_index(@profiles, &(&1 == profile)) + 1)

  defp checks_for(:c0, ctx), do: C0.checks(ctx)
  defp checks_for(:c1, ctx), do: C1.checks(ctx)
  defp checks_for(:c2, ctx), do: C2.checks(ctx) ++ Supply.checks(ctx)
  defp checks_for(:c3, ctx), do: C3.checks(ctx)

  defp listing([], _), do: []
  defp listing(cs, word), do: ["#{length(cs)} #{word} (#{Enum.map_join(cs, ", ", & &1.id)})"]

  defp no_sha(sha) when is_binary(sha), do: []
  defp no_sha(_), do: ["no subject SHA"]

  # -- tier / scope (RFC-007 E-A, E-C): the claim may not exceed the evidence --

  defp claim_scope_checks(profile, ctx) do
    [
      Check.run(
        "claim.tier_supported",
        profile,
        "declared independence tier supported by evidence",
        fn ->
          cond do
            ctx.tier not in @tiers ->
              {:fail,
               "unknown tier #{inspect(ctx.tier)}; expected one of #{Enum.join(@tiers, ", ")}"}

            ctx.tier == "I1" ->
              {:pass, "I1 (key independence) needs no deployment evidence"}

            true ->
              {:unverified,
               "tier #{ctx.tier} needs deployment registry evidence (custody attestation) supplied by the operator"}
          end
        end
      ),
      Check.run(
        "claim.scope_supported",
        profile,
        "declared hosting scope supported by evidence",
        fn ->
          cond do
            ctx.scope not in @scopes ->
              {:fail,
               "unknown scope #{inspect(ctx.scope)}; expected one of #{Enum.join(@scopes, ", ")}"}

            ctx.scope == "same-host-os-user" ->
              {:pass, "same-host-os-user is the weakest scope; no deployment evidence needed"}

            true ->
              {:unverified,
               "scope #{ctx.scope} needs deployment topology evidence supplied by the operator"}
          end
        end
      )
    ]
  end

  @doc "JSON-encodable projection of a report."
  @spec to_json_map(map()) :: map()
  def to_json_map(report) do
    %{
      "profile" => Atom.to_string(report.profile),
      "version" => report.version,
      "tier" => report.tier,
      "scope" => report.scope,
      "subject_sha" => report.subject_sha,
      "security_profile" => Atom.to_string(report.security_profile),
      "conformant" => report.conformant?,
      "claim" => report.claim,
      "checks" =>
        Enum.map(report.checks, fn c ->
          %{
            "id" => c.id,
            "profile" => Atom.to_string(c.profile),
            "title" => c.title,
            "status" => Atom.to_string(c.status),
            "evidence" => c.evidence
          }
        end)
    }
  end
end
