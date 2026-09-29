defmodule AshA2A.SA2A.Conformance.Checks.C3 do
  @moduledoc """
  C3 check: a k-of-n signer quorum over registry-verified, custodian-distinct
  kids (RFC-007 E-C: independence is counted over `custodian_id`, never over
  `kid` or a label).

  ## Interface probed

      signer_set.quorum([standing], k) ::
        {:ok, %{custodians: [custodian_id], tier: :i1 | :i2 | :i3 | :i4}} | {:error, code}

  `standing` is what `AshA2A.CryptoStanding` returns per signature:
  `{:valid, %{kid, custodian_id, tier, epoch}} | {:invalid, refusal_code}`.
  Crypto standing certifies; the quorum function only counts distinct
  custodians among VALID standings and takes the minimum tier.

  Probes:

    * pure refusals (each MUST be refused at k = 2): two kids of one custodian,
      the same kid twice, one valid plus one invalid, a single valid, an empty
      list, a non-standing term;
    * end to end with real Ed25519 keys through
      `certificate_verifier.standings/3` (`Sa2aCrypto` registry): two
      custodian-distinct signers MUST yield a quorum; two keys held by one
      custodian MUST NOT.

  A module without `quorum/2` fails, with the legacy label-counting behavior of
  `threshold?/2` reported as evidence.
  """

  alias AshA2A.SA2A.Conformance.Checks.ProbeFixtures, as: Fx
  alias AshA2A.SA2A.Conformance.{Check, Context}

  @spec checks(map()) :: [Check.t()]
  def checks(ctx) do
    ctx = Context.build(ctx)

    [
      Check.run(
        "c3.signer_set_quorum",
        :c3,
        "SignerSet quorum over registry-verified custodian-distinct kids",
        fn ->
          signer_set_quorum(ctx)
        end
      )
    ]
  end

  def signer_set_quorum(ctx) do
    ctx = Context.build(ctx)
    mod = ctx.signer_set

    cond do
      not Code.ensure_loaded?(mod) ->
        {:fail, "#{inspect(mod)} does not exist"}

      not function_exported?(mod, :quorum, 2) ->
        {:fail,
         "#{inspect(mod)} has no quorum/2 (custodian-distinct quorum over standings); " <>
           legacy_evidence(mod)}

      true ->
        probe(mod, ctx)
    end
  end

  defp legacy_evidence(mod) do
    if function_exported?(mod, :threshold?, 2) do
      sigs = [%{signer: "label-a", custodian_id: "X"}, %{signer: "label-b", custodian_id: "X"}]

      if mod.threshold?(sigs, 2),
        do: "threshold?/2 counts labels: two labels under one custodian_id satisfy k=2",
        else: "threshold?/2 refused the same-custodian probe but consults no standing"
    else
      "no threshold?/2 either"
    end
  end

  defp valid(kid, cust, tier \\ :i2),
    do: {:valid, %{kid: kid, custodian_id: cust, tier: tier, epoch: 0}}

  defp probe(mod, ctx) do
    negatives = [
      {"two kids of one custodian", [valid("k1", "c1"), valid("k2", "c1")]},
      {"the same kid twice", [valid("k1", "c1"), valid("k1", "c1")]},
      {"one valid plus one invalid", [valid("k1", "c1"), {:invalid, :bad_signature}]},
      {"a single valid standing", [valid("k1", "c1")]},
      {"an empty list", []},
      {"non-standing terms", [:ok, :ok]}
    ]

    accepted =
      for {label, standings} <- negatives, accepts?(mod, standings), do: label

    positive_pure = safe(fn -> mod.quorum([valid("k1", "c1"), valid("k2", "c2", :i1)], 2) end)

    cond do
      accepted != [] ->
        {:fail, "quorum ACCEPTED an invalid set: #{Enum.join(accepted, ", ")}"}

      not match?({:ok, %{custodians: [_, _ | _], tier: :i1}}, positive_pure) ->
        {:fail,
         "custodian-distinct valid standings refused or tier not the minimum: #{inspect(positive_pure, limit: 5)}"}

      true ->
        end_to_end(mod, ctx)
    end
  end

  defp accepts?(mod, standings), do: match?({:ok, _}, safe(fn -> mod.quorum(standings, 2) end))

  defp safe(fun) do
    fun.()
  rescue
    e -> {:raised, Exception.message(e)}
  end

  defp end_to_end(mod, ctx) do
    verifier = ctx.certificate_verifier

    cond do
      not Fx.available?() ->
        {:fail, "Sa2aCrypto is not loadable: no registry-verified standing to count"}

      not (Code.ensure_loaded?(verifier) and function_exported?(verifier, :standings, 3)) ->
        {:unverified,
         "pure quorum probes passed but #{inspect(verifier)}.standings/3 is absent: no registry-verified end-to-end probe"}

      true ->
        distinct = [Fx.signer("cust-A"), Fx.signer("cust-B")]
        shared = [Fx.signer("cust-A"), Fx.signer("cust-A")]

        with {:ok, d} <- quorum_of(mod, verifier, distinct),
             :refused <- shared_result(mod, verifier, shared) do
          {:pass,
           "real Ed25519 signers verified through the registry: custodian-distinct quorum accepted (custodians #{Enum.join(d.custodians, ",")}, tier #{d.tier}); two keys of one custodian refused; #{6} pure invalid sets refused"}
        else
          {:error, why} ->
            {:fail,
             "custodian-distinct registry-verified signers did not form a quorum: #{inspect(why, limit: 5)}"}

          :accepted ->
            {:fail, "quorum ACCEPTED two real keys held by one custodian"}
        end
    end
  end

  defp quorum_of(mod, verifier, signers) do
    effect = Fx.effect()
    cert = Fx.certificate(effect, Enum.map(signers, &Fx.sign(effect, &1)))

    case verifier.standings(cert, effect, Fx.verify_ctx(signers)) do
      {:ok, results} -> mod.quorum(Enum.map(results, & &1.standing), 2)
      other -> {:error, other}
    end
  end

  defp shared_result(mod, verifier, signers) do
    case quorum_of(mod, verifier, signers) do
      {:ok, _} -> :accepted
      _ -> :refused
    end
  end
end
