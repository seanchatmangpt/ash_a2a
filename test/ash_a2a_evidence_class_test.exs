defmodule AshA2A.EvidenceClassTest do
  @moduledoc """
  RFC-SA2A-001 S70 evidence boundaries.

  Chicago-style throughout: real class values, real promotion calls, real
  returned structs asserted on by type and value. No doubles -- there is
  nothing external here to double.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Evidence.Class

  alias AshA2A.Evidence.{
    HostedCI,
    LocalTest,
    Merge,
    Production,
    Publication,
    RuntimeAlive
  }

  doctest AshA2A.Evidence.Class

  test "the chain is exactly the six S70 classes in RFC order" do
    assert Class.chain() == [LocalTest, HostedCI, Production, RuntimeAlive, Publication, Merge]

    assert Enum.map(Class.chain(), & &1.label()) ==
             [:local_test, :hosted_ci, :production, :runtime_alive, :publication, :merge]

    assert Enum.map(Class.chain(), & &1.rank()) == [1, 2, 3, 4, 5, 6]
  end

  test "each class is a genuinely distinct struct type, not a tagged atom" do
    values = Enum.map(Class.chain(), & &1.new(%{note: "same basis for all six"}))

    # Six distinct struct modules. If these were atoms or tagged tuples
    # sharing one struct, this set would collapse.
    assert values |> Enum.map(& &1.__struct__) |> Enum.uniq() |> length() == 6

    # A function head bound to one class does not match another. This is the
    # non-coercibility S70 asks for, demonstrated rather than asserted.
    local = LocalTest.new(%{})
    production = Production.new(%{})

    assert requires_production(production) == :ok
    assert requires_production(local) == :wrong_class
  end

  defp requires_production(%Production{}), do: :ok
  defp requires_production(_), do: :wrong_class

  test "promotion one step up with genuinely new evidence succeeds" do
    local = LocalTest.new(%{suite: "mix test", commit: "abc123"})

    assert {:ok, %HostedCI{} = ci} = Class.promote(local, HostedCI, %{job_url: "ci://run/42"})
    assert ci.basis == %{job_url: "ci://run/42"}
    assert ci.evidence_digest != local.evidence_digest
    assert Class.rank(ci) == 2

    assert {:ok, %Production{} = prod} = Class.promote(ci, Production, %{deploy: "d-7"})
    assert Class.rank(prod) == 3
  end

  test "promotion without new evidence is refused -- the core S70 rule" do
    basis = %{suite: "mix test", commit: "abc123"}
    local = LocalTest.new(basis)

    # Re-presenting the identical evidence that justified `local` does not buy
    # a stronger class.
    assert {:error, %{code: :promotion_without_new_evidence, detail: detail}} =
             Class.promote(local, HostedCI, basis)

    assert detail =~ "hosted_ci requires evidence distinct from the local_test evidence"

    # And the same rule holds further up the chain.
    ci_basis = %{job_url: "ci://run/42"}
    {:ok, ci} = Class.promote(local, HostedCI, ci_basis)

    assert {:error, %{code: :promotion_without_new_evidence}} =
             Class.promote(ci, Production, ci_basis)
  end

  test "skipping a class is refused, and so is going backwards" do
    local = LocalTest.new(%{a: 1})

    assert {:error, %{code: :non_adjacent_evidence_promotion, detail: detail}} =
             Class.promote(local, Production, %{b: 2})

    assert detail =~ "local_test cannot reach production without hosted_ci"

    assert {:error, %{code: :non_adjacent_evidence_promotion}} =
             Class.promote(local, RuntimeAlive, %{b: 2})

    {:ok, ci} = Class.promote(local, HostedCI, %{b: 2})

    assert {:error, %{code: :non_adjacent_evidence_promotion}} =
             Class.promote(ci, LocalTest, %{c: 3})

    # Self-promotion is not a promotion either.
    assert {:error, %{code: :non_adjacent_evidence_promotion}} =
             Class.promote(ci, HostedCI, %{c: 3})
  end

  test "Merge is the top of the chain and has nothing above it" do
    assert Class.next(Publication) == {:ok, Merge}
    assert Class.next(Merge) == :error

    merge = Merge.new(%{pr: 1})

    assert {:error, %{code: :non_adjacent_evidence_promotion}} =
             Class.promote(merge, Merge, %{x: 1})
  end

  test "non-class modules and values are refused rather than silently coerced" do
    local = LocalTest.new(%{})

    assert {:error, %{code: :not_an_evidence_class}} = Class.promote(local, NotAClass, %{a: 1})
    assert {:error, %{code: :not_an_evidence_class}} = Class.promote(%{fake: true}, HostedCI, %{})
    assert {:error, %{code: :not_an_evidence_class}} = Class.promote(:local_test, HostedCI, %{})

    refute Class.class?(NotAClass)
    refute Class.class?(:local_test)
    refute Class.value?(%{__struct__: NotAClass})
    assert Class.class?(Production)
    assert Class.value?(local)
  end

  test "assert_at_least reads the lattice without ever upgrading anything" do
    # A HostedCI that was genuinely EARNED -- `HostedCI.new/1` builds an
    # unlinked root, which `assert_at_least/2` now refuses (see the forged
    # class test below). A rank-2 claim requires a rank-1 predecessor.
    local = LocalTest.new(%{suite: "mix test", commit: "abc123"})
    {:ok, ci} = Class.promote(local, HostedCI, %{job: 1})

    assert :ok = Class.assert_at_least(ci, LocalTest)
    assert :ok = Class.assert_at_least(ci, HostedCI)

    assert {:error, %{code: :insufficient_evidence_class, detail: detail}} =
             Class.assert_at_least(ci, Production)

    assert detail =~ "have hosted_ci (2), require production (3)"

    # The value is unchanged: no read-side upgrade happened.
    assert ci.__struct__ == HostedCI
  end

  test "the default class is the weakest one, not the strongest" do
    assert Class.default() == LocalTest
    assert Class.rank(Class.default()) == 1
  end

  # ------------------------------------------------------------------
  # DEFECT 2 regression (RFC S70): silent evidence promotion.
  #
  # Before the fix, `promote/3` refused exactly one thing -- a basis
  # byte-identical to the IMMEDIATELY PRECEDING basis. It did not require
  # the basis to be non-empty, had no memory of evidence consumed earlier
  # in the chain, and discarded the current class entirely, so the
  # successor held no link to its predecessor and a forged class rode all
  # the way into a real verify/2-passing attestation.
  #
  # The three inputs below are the verifier's minimal reproductions.
  # ------------------------------------------------------------------

  test "S70 regression: an EMPTY basis is not new evidence and does not promote" do
    local = LocalTest.new(%{suite: "mix test", run: 1})

    assert {:error, %{code: :promotion_without_new_evidence, detail: detail}} =
             Class.promote(local, HostedCI, %{})

    assert detail =~ "an empty basis is not an observation"

    # The empty keyword list is the same input in a different skin.
    assert {:error, %{code: :promotion_without_new_evidence}} = Class.promote(local, HostedCI, [])

    # And the value really did not move.
    assert Class.rank(local) == 1
  end

  test "S70 regression: evidence spent EARLIER in the chain cannot be replayed to climb it" do
    local_basis = %{suite: "mix test", run: 1}
    local = LocalTest.new(local_basis)
    {:ok, ci} = Class.promote(local, HostedCI, %{job: "ci-42"})

    # The exact repro: the LocalTest basis is not the IMMEDIATELY preceding
    # basis any more, so the old byte-comparison let it through.
    assert {:error, %{code: :evidence_replayed, detail: detail}} =
             Class.promote(ci, Production, local_basis)

    assert detail =~ "already consumed earlier in this chain"

    # Genuinely new evidence still works, so this is a replay guard and not
    # a blanket refusal.
    assert {:ok, %Production{} = prod} = Class.promote(ci, Production, %{deploy: "d-7"})

    # And the chain remembers all three spends, oldest included.
    assert Class.digest(local_basis) in prod.consumed_evidence
    assert Class.digest(%{job: "ci-42"}) in prod.consumed_evidence
    assert Class.digest(%{deploy: "d-7"}) in prod.consumed_evidence
    assert length(prod.consumed_evidence) == 3

    # Replay is refused at every later step too, not just the first.
    assert {:error, %{code: :evidence_replayed}} =
             Class.promote(prod, RuntimeAlive, %{job: "ci-42"})
  end

  test "S70 regression: every class is linked to its predecessor, and a forged class is refused" do
    local = LocalTest.new(%{suite: "mix test", run: 1})
    {:ok, ci} = Class.promote(local, HostedCI, %{job: "ci-42"})
    {:ok, prod} = Class.promote(ci, Production, %{deploy: "d-7"})

    # Real links, all the way down.
    assert local.prior_digest == nil
    assert ci.prior_digest == local.chain_digest
    assert prod.prior_digest == ci.chain_digest
    assert :ok = Class.verify_chain(local)
    assert :ok = Class.verify_chain(ci)
    assert :ok = Class.verify_chain(prod)

    # A forged Merge with a made-up link: refused, not accepted.
    forged =
      struct!(Merge,
        evidence_digest: Class.digest(%{forged: true}),
        observed_at: DateTime.utc_now(),
        chain_digest: "sha256:looks-real",
        basis: %{forged: true}
      )

    assert {:error, %{code: :evidence_chain_broken}} = Class.verify_chain(forged)
    assert {:error, %{code: :evidence_chain_broken}} = Class.assert_at_least(forged, Merge)
    assert {:error, %{code: :evidence_chain_broken}} = Class.assert_at_least(forged, LocalTest)

    # The harder forgery: a self-CONSISTENT link that was still never
    # earned. Internal consistency is not a promotion history.
    digest = Class.digest(%{forged: true})

    self_consistent =
      struct!(Merge,
        evidence_digest: digest,
        observed_at: DateTime.utc_now(),
        consumed_evidence: [digest],
        chain_digest: Class.link_digest(Merge, digest, nil, [digest]),
        basis: %{forged: true}
      )

    assert {:error, %{code: :evidence_class_not_earned, detail: detail}} =
             Class.verify_chain(self_consistent)

    assert detail =~ "reached by promotion, never constructed"

    assert {:error, %{code: :evidence_class_not_earned}} =
             Class.assert_at_least(self_consistent, Merge)

    # A value that claims a rank it has not paid for in distinct evidence
    # is refused on the count, even with a real predecessor link.
    understated = %{prod | consumed_evidence: [prod.evidence_digest]}

    understated = %{
      understated
      | chain_digest:
          Class.link_digest(Production, prod.evidence_digest, prod.prior_digest, [
            prod.evidence_digest
          ])
    }

    assert {:error, %{code: :evidence_class_not_earned, detail: count_detail}} =
             Class.verify_chain(understated)

    assert count_detail =~ "one per step is required"
  end

  test "S70 regression: a broken-link predecessor cannot promote at all" do
    local = LocalTest.new(%{suite: "mix test", run: 1})
    tampered = %{local | evidence_digest: Class.digest(%{something: "else"})}

    assert {:error, %{code: :evidence_chain_broken}} =
             Class.promote(tampered, HostedCI, %{job: "ci-42"})
  end

  test "evidence digests are content-addressed and stable across processes" do
    basis = %{run: "r-1", host: "builder-3"}
    here = Class.digest(basis)

    there = Task.await(Task.async(fn -> Class.digest(basis) end))

    assert here == there
    assert String.starts_with?(here, "sha256:")
    assert Class.digest(%{run: "r-2"}) != here
  end
end
