defmodule AshA2A.Chicago.FiboHighValueFinanceTest do
  @moduledoc """
  v26.9.29 Chicago 80/20 court for high-value FIBO-shaped financial subjects.

  This court does not claim payment-rail conformance and never moves real money.
  It qualifies the SA2A invariants that a later FIBO transaction runtime depends on:

    * exact canonical transaction identity;
    * amount/currency/counterparty/agreement drift changes the prepared subject;
    * integer-only micro-unit accounting at and above the USD 10M boundary;
    * finite financial envelopes fail closed;
    * semantic evidence constrains identity but never manufactures authority.

  The transaction vocabulary is shaped from FIBO concepts already vendored by
  GraphLaw: MarketTransaction, MonetaryAmount, Currency, payment terms,
  contractual basis, counterparties and settlement.
  """

  use ExUnit.Case, async: true

  alias AshA2A.{EffectInstance, PreparedEffect}
  alias AshA2A.Chicago
  alias AshA2A.Identity.Canonical
  alias AshA2A.Semantic.Allocator

  @fibo_market_transaction "https://spec.edmcouncil.org/fibo/ontology/FND/TransactionsExt/MarketTransactions/MarketTransaction"
  @fibo_monetary_amount "https://spec.edmcouncil.org/fibo/ontology/FND/Accounting/CurrencyAmount/MonetaryAmount"
  @fibo_usd "https://spec.edmcouncil.org/fibo/ontology/FND/Accounting/ISO4217-CurrencyCodes/USDollar"

  @usd_10m_micros 10_000_000_000_000
  @usd_25m_micros 25_000_000_000_000

  defp transaction(overrides \\ %{}) do
    base = %{
      "id" => "urn:sa2a:fibo:transaction:tx-25m-usd-001",
      "type" => @fibo_market_transaction,
      "principal" => "urn:lei:principal-bank",
      "counterparty" => "urn:lei:counterparty-bank",
      "consideration" => %{
        "type" => @fibo_monetary_amount,
        "amount" => "25000000.000000",
        "currency" => @fibo_usd
      },
      "paymentTerms" => "urn:sa2a:fibo:payment-terms:pt-001",
      "settlement" => "urn:sa2a:fibo:settlement:set-001",
      "masterAgreement" => "urn:sa2a:fibo:master-agreement:ma-001"
    }

    deep_merge(base, overrides)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r ->
      if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
    end)
  end

  defp effect_instance(subject) do
    {:ok, instance} =
      EffectInstance.new(%{
        request: %{
          "request_id" => "urn:sa2a:fibo:request:settle-001",
          "purpose" => "settle admitted FIBO market transaction"
        },
        subject: subject,
        effect: %{
          "op" => "settle",
          "rail" => "synthetic-chicago-ledger"
        },
        generation: 29,
        policy_epoch: 29
      })

    instance
  end

  defp evidence_ref(graph_char \\ "b") do
    body = %{
      "schema" => "sa2a.semantic-evidence-envelope.v1",
      "contractVersion" => "v26.9.29",
      "canonicalization" => "RDFC-1.0",
      "authority" => "NONE",
      "consequence" => "EVIDENCE_ONLY",
      "subject" => "urn:sa2a:fibo:transaction:tx-25m-usd-001",
      "source" => %{
        "id" => "fibo-market-transaction",
        "uri" => "urn:source:fibo:market-transaction",
        "graph" => "urn:graph:fibo:market-transaction",
        "subjectTemplate" => "urn:sa2a:fibo:transaction:{id}",
        "version" => "v26.9.29",
        "digest" => "sha256:" <> String.duplicate("a", 64)
      },
      "graphDigest" => "sha256:" <> String.duplicate(graph_char, 64),
      "replayIdentity" => "replay:fibo:tx-25m-usd-001:v26.9.29",
      "receiptDigest" => nil,
      "provenance" => %{
        "producer" => "ash_r2rml",
        "producerVersion" => "v26.9.29",
        "graphlawContractCommit" => "48a7bbd801b8df1d7ffab879b10d58d7f14ef7bc",
        "sourceIdentityDigest" => "sha256:" <> String.duplicate("a", 64)
      }
    }

    {:ok, canonical} = Canonical.encode(body)

    envelope_digest =
      "sha256:" <>
        (:crypto.hash(:sha256, ["ashr2rml.vkg.canonical.v1\n", canonical])
         |> Base.encode16(case: :lower))

    Map.put(body, "envelopeDigest", envelope_digest)
  end

  defp prepared(subject, evidence \\ evidence_ref()) do
    instance = effect_instance(subject)

    {:ok, prepared} =
      PreparedEffect.new(
        instance,
        %{
          "op" => "settle",
          "transaction" => subject["id"],
          "amount_micros" => @usd_25m_micros
        },
        :external_do,
        semantic_evidence: evidence,
        authority_epoch: 29
      )

    prepared
  end

  test "FIBO-shaped transaction identity is canonical across map construction order" do
    tx = transaction()

    reordered =
      tx
      |> Enum.reverse()
      |> Map.new()
      |> Map.update!("consideration", fn amount ->
        amount |> Enum.reverse() |> Map.new()
      end)

    left = effect_instance(tx)
    right = effect_instance(reordered)

    assert left.subject_digest == right.subject_digest
    assert prepared(tx).prepared_digest == prepared(reordered).prepared_digest
  end

  test "behaviorally meaningful FIBO transaction mutations change prepared identity" do
    baseline = prepared(transaction()).prepared_digest

    mutations = [
      transaction(%{"counterparty" => "urn:lei:different-counterparty"}),
      transaction(%{"consideration" => %{"amount" => "25000000.000001"}}),
      transaction(%{"consideration" => %{"currency" => "urn:iso4217:EUR"}}),
      transaction(%{"masterAgreement" => "urn:sa2a:fibo:master-agreement:ma-002"}),
      transaction(%{"settlement" => "urn:sa2a:fibo:settlement:set-002"})
    ]

    for mutated <- mutations do
      refute prepared(mutated).prepared_digest == baseline
    end
  end

  test "USD 25M is represented exactly as integer money micros and can consume an exact envelope" do
    assert @usd_25m_micros == 25_000_000 * 1_000_000

    budget =
      Allocator.new!([money_micros: @usd_25m_micros],
        issued_by: {:host, __MODULE__}
      )

    assert {:ok, spent} =
             Allocator.allocate(budget, :money_micros, @usd_25m_micros)

    assert spent.consumed.money_micros == @usd_25m_micros
    assert Allocator.remaining(spent).money_micros == 0
  end

  test "a USD 25M consequence is refused by a USD 10M financial envelope" do
    budget =
      Allocator.new!([money_micros: @usd_10m_micros],
        issued_by: {:host, __MODULE__}
      )

    assert {:error,
            %{
              code: :budget_exhausted,
              dimension: :money_micros,
              limit: @usd_10m_micros,
              requested: @usd_25m_micros
            }} = Allocator.allocate(budget, :money_micros, @usd_25m_micros)
  end

  test "the USD 10M boundary is exact: the boundary fits and one micro above refuses" do
    exact =
      Allocator.new!([money_micros: @usd_10m_micros],
        issued_by: {:host, __MODULE__}
      )

    assert {:ok, exact_spent} =
             Allocator.allocate(exact, :money_micros, @usd_10m_micros)

    assert Allocator.remaining(exact_spent).money_micros == 0

    above =
      Allocator.new!([money_micros: @usd_10m_micros],
        issued_by: {:host, __MODULE__}
      )

    assert {:error, %{code: :budget_exhausted, requested: requested}} =
             Allocator.allocate(above, :money_micros, @usd_10m_micros + 1)

    assert requested == @usd_10m_micros + 1
  end

  test "financial budget never manufactures transaction authority" do
    budget =
      Allocator.new!(
        [
          money_micros: @usd_25m_micros,
          tokens: 1_000_000,
          external_requests: 16
        ],
        issued_by: {:host, __MODULE__}
      )

    refute :authority in Allocator.dimensions()

    assert {:error, %{code: :authority_not_allocatable}} =
             Allocator.allocate(budget, :authority, @usd_25m_micros)
  end

  test "FIBO semantic evidence changes prepared identity but remains authority NONE" do
    tx = transaction()

    a = prepared(tx, evidence_ref("b"))
    b = prepared(tx, evidence_ref("d"))

    refute a.prepared_digest == b.prepared_digest
    assert a.semantic_evidence["authority"] == "NONE"
    assert b.semantic_evidence["authority"] == "NONE"\n  end\n  test "v26.9.29 FIBO profile is backed by the canonical Chicago agent courts" do
    profile =
      "priv/sa2a/fibo_v26_9_29_chicago_profile.json"
      |> File.read!()
      |> JSON.decode!()

    discovered = Map.new(Chicago.courts(), &{&1.id(), &1})

    assert profile["schema"] == "sa2a.fibo-chicago-profile.v1"
    assert profile["version"] == "v26.9.29"
    assert profile["inherits"] == ["chicago.universal.v1"]
    assert profile["authority"] == "NONE"
    assert profile["consequence"] == "EVIDENCE_ONLY"
    assert profile["policyBoundary"]["currency"] == "USD"
    assert profile["policyBoundary"]["amountMicros"] == @usd_10m_micros

    for id <- profile["requiredCourtIds"] do
      assert Map.has_key?(discovered, id), "required Chicago court #{id} is not discoverable"
      court = Map.fetch!(discovered, id)
      assert court.falsifiers() != [], "required Chicago court #{id} has no falsifiers"
    end

    for mapping <- profile["researchMappings"] do
      assert mapping["precedent"] not in [nil, ""]
      assert mapping["courtIds"] != []

      for id <- mapping["courtIds"] do
        assert id in profile["requiredCourtIds"],
               "#{mapping["precedent"]} names court #{id} outside the FIBO profile"
      end
    end
  end

  test "the finance profile requires the full semantic-to-consequence chain, not money checks alone" do
    profile =
      "priv/sa2a/fibo_v26_9_29_chicago_profile.json"
      |> File.read!()
      |> JSON.decode!()

    required = MapSet.new(profile["requiredCourtIds"])

    for id <- [
          "SA2A-ENGINE",
          "SA2A-LOGIC",
          "SA2A-HOOK",
          "SA2A-CASCADE",
          "CHI-PLAN-AUTH",
          "CHI-PREFLIGHT",
          "SA2A-PLAN",
          "CHI-AUTO",
          "SA2A-BOUNDS",
          "SA2A-AUTH",
          "SA2A-AUTH-GRANT",
          "SA2A-FED",
          "CHI-BRCE",
          "CHI-POST",
          "CHI-RECEIPT",
          "CHI-REPLAY",
          "SA2A-CHAOS",
          "SA2A-ATTEST",
          "SA2A-OCEL",
          "CHI-FRESH"
        ] do
      assert MapSet.member?(required, id), "missing finance-chain court #{id}"
    end
  end

  test "high-value semantic evidence cannot smuggle DO authority into PreparedEffect" do
    tx = transaction()
    instance = effect_instance(tx)
    smuggled = Map.put(evidence_ref(), "authority", "DO")

    assert {:error, %{code: :refused_semantic_evidence, subject: :authority}} =
             PreparedEffect.new(
               instance,
               %{
                 "op" => "settle",
                 "transaction" => tx["id"],
                 "amount_micros" => @usd_25m_micros
               },
               :external_do,
               semantic_evidence: smuggled,
               authority_epoch: 29
             )
  end
end
