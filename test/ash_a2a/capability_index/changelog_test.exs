defmodule AshA2A.CapabilityIndex.ChangelogTest do
  @moduledoc """
  Real, Chicago-style coverage for `AshA2A.CapabilityIndex.Changelog`: no
  Mock/mox/patch/monkeypatch anywhere in this file. Every assertion is
  against the real `%AshA2A.CapabilityIndex.Changelog{}` struct returned by
  the module under test, over either real (if synthetic-content) id lists
  or a real, compiled `Ash.Resource`/`Ash.Domain` capability index -- never
  an interaction/call-count check.

  Three layers, per the task brief:

    1. `describe "build/2 -- diff correctness"` -- the four real id-set
       shapes (added-only, removed-only, both, no-change) produce the
       correct real `added`/`removed`/`unchanged` sets.
    2. `describe "fingerprint/1"` -- deterministic for identical diff
       content regardless of enumeration order (mirrors
       `AshA2A.Command.fingerprint/1`'s own
       "stable across transport retry identity" test in
       `test/ash_a2a/command_contract_test.exs`), and changes when the real
       diff content changes (mirrors that same file's
       "fingerprint changes when consequence-bearing semantic input
       changes" test).
    3. `describe "end-to-end against real compiled fixtures"` -- a real
       demo using two real compiled resource/domain fixtures
       (`test/support/fixture.ex`'s `CapabilityChangelogShared` and
       `CapabilityChangelogNewDomain`) to prove this works against
       genuinely real, compiled capability indices, not synthetic lists.
  """

  use ExUnit.Case, async: true

  alias AshA2A.CapabilityIndex.Changelog
  alias AshA2A.Test.Fixture.CapabilityChangelogNewDomain
  alias AshA2A.Test.Fixture.CapabilityChangelogShared

  describe "build/2 -- diff correctness" do
    test "added-only: new ids beyond the old set are all added, nothing removed" do
      entry = Changelog.build(["a"], ["a", "b"])

      assert entry.added == ["b"]
      assert entry.removed == []
      assert entry.unchanged == ["a"]
    end

    test "removed-only: old ids missing from the new set are all removed, nothing added" do
      entry = Changelog.build(["a", "b"], ["a"])

      assert entry.added == []
      assert entry.removed == ["b"]
      assert entry.unchanged == ["a"]
    end

    test "both: a real diff can carry additions and removals in the same entry" do
      entry = Changelog.build(["a", "b"], ["a", "c"])

      assert entry.added == ["c"]
      assert entry.removed == ["b"]
      assert entry.unchanged == ["a"]
    end

    test "no-change: an identical id set (in a different enumeration order) yields an empty diff" do
      entry = Changelog.build(["a", "b"], ["b", "a"])

      assert entry.added == []
      assert entry.removed == []
      assert entry.unchanged == ["a", "b"]
    end

    test "duplicate ids within one side collapse under real set semantics" do
      entry = Changelog.build(["a", "a", "b"], ["a", "b", "b", "c"])

      assert entry.added == ["c"]
      assert entry.removed == []
      assert entry.unchanged == ["a", "b"]
    end
  end

  describe "fingerprint/1" do
    test "is deterministic for identical diff content regardless of input enumeration order" do
      one = Changelog.build(["svc.a", "svc.b"], ["svc.a", "svc.b", "svc.c"])
      two = Changelog.build(["svc.b", "svc.a"], ["svc.c", "svc.b", "svc.a"])

      assert one.added == two.added
      assert one.removed == two.removed
      assert one.unchanged == two.unchanged
      assert one.fingerprint == two.fingerprint
      assert Changelog.fingerprint(one) == Changelog.fingerprint(two)
    end

    test "changes when the real added/removed content changes" do
      one = Changelog.build(["svc.a"], ["svc.a", "svc.b"])
      two = Changelog.build(["svc.a"], ["svc.a", "svc.c"])

      refute one.fingerprint == two.fingerprint
    end

    test "changes when a capability moves from unchanged to removed" do
      one = Changelog.build(["svc.a", "svc.b"], ["svc.a", "svc.b"])
      two = Changelog.build(["svc.a", "svc.b"], ["svc.a"])

      refute one.fingerprint == two.fingerprint
    end

    test "recomputing from the stored struct reproduces the same fingerprint stored at build time" do
      entry = Changelog.build(["svc.a"], ["svc.a", "svc.b"])

      assert Changelog.fingerprint(entry) == entry.fingerprint
    end

    test "is a real lowercase sha256 hex digest, the same shape AshA2A.Command.fingerprint/1 produces" do
      entry = Changelog.build(["svc.a"], ["svc.a", "svc.b"])

      assert String.length(entry.fingerprint) == 64
      assert entry.fingerprint == String.downcase(entry.fingerprint)
      assert entry.fingerprint =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "end-to-end against real compiled fixtures" do
    test "a real one-capability resource diffed against a real domain that adds one resource" do
      # "Old" revision: the real resource-level capability index for a
      # single, real compiled `Ash.Resource` fixture -- exactly the
      # `AshA2A.Info.capability_index/1` entry point production code calls.
      old_index = AshA2A.Info.capability_index(CapabilityChangelogShared)

      # "New" revision: the real domain-level capability index for a real
      # `Ash.Domain` fixture that aggregates the SAME shared resource
      # module PLUS one additional real resource
      # (`AshA2A.Test.Fixture.CapabilityChangelogExtra`) -- the "one
      # capability, plus an extra" shape from the task brief, built from
      # two genuinely independent compiled Ash modules, not a hand-typed
      # capability-id string.
      new_index = AshA2A.Info.capability_index(CapabilityChangelogNewDomain)

      assert length(old_index) == 1
      assert length(new_index) == 2

      shared_id = hd(old_index).id
      extra_id = new_index |> Enum.map(& &1.id) |> Enum.reject(&(&1 == shared_id)) |> hd()

      entry = Changelog.build_from_indices(old_index, new_index)

      assert entry.added == [extra_id]
      assert entry.removed == []
      assert entry.unchanged == [shared_id]

      # The overlapping id is a real, non-synthetic string: it is the
      # literal `AshA2A.Skill.id` the real compiler derived for the same
      # resource module in both the resource-level and domain-level compile.
      assert shared_id == "AshA2A.Test.Fixture.CapabilityChangelogShared.read"
      assert entry.fingerprint == Changelog.fingerprint(entry)
    end

    test "the same real fixtures compiled via build/2 directly (ids projected by hand) agree with build_from_indices/2" do
      old_index = AshA2A.Info.capability_index(CapabilityChangelogShared)
      new_index = AshA2A.Info.capability_index(CapabilityChangelogNewDomain)

      via_ids = Changelog.build(Enum.map(old_index, & &1.id), Enum.map(new_index, & &1.id))
      via_indices = Changelog.build_from_indices(old_index, new_index)

      assert via_ids == via_indices
    end
  end
end
