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
    ci = HostedCI.new(%{job: 1})

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

  test "evidence digests are content-addressed and stable across processes" do
    basis = %{run: "r-1", host: "builder-3"}
    here = Class.digest(basis)

    there = Task.await(Task.async(fn -> Class.digest(basis) end))

    assert here == there
    assert String.starts_with?(here, "sha256:")
    assert Class.digest(%{run: "r-2"}) != here
  end
end
