# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ArchitectureVerifier.ChicagoRollupTest do
  @moduledoc """
  Direct ExUnit coverage of `AshA2A.ArchitectureVerifier.ChicagoRollup`, the
  new module that closes the ARD §23 single-entry-point gap: `mix
  ash_a2a.verify_architecture` previously ran only the checks in
  `test/ash_a2a_architecture_verifier_test.exs` (10, once merged alongside
  the RFC-SA2A-002 Gate 7 sole-DO fence check) and rolled up none of the
  real RFC-SA2A-002 Chicago falsifier-court evidence already committed under
  `lib/ash_a2a/chicago/courts/`.

  Real collaborators throughout, exactly the same pattern this repo's own
  `test/ash_a2a/chicago/*_test.exs` files already use (e.g.
  `brce_gate7_test.exs`, `envelope_negotiation_transport_test.exs`): the
  real `AshA2A.Chicago.Runner`, the real courts, real `CommandBus`/
  `Dispatcher`/`Authority.Broker.InMemory`/`ReceiptStore`, real telemetry,
  and a real durable OCEL artifact independently corroborated on disk. No
  Mock/Mox/:meck/patch/monkeypatch anywhere in this file -- this is the
  existing `test/ash_a2a_architecture_verifier_test.exs` untouched; only
  the new module gets a new test file.

  `async: false` -- Chicago runs attribute telemetry to a stimulus window,
  so concurrent runs driving the same boundaries would misattribute events
  (the same reason every Chicago court test file in this repo sets
  `async: false`).
  """

  use ExUnit.Case, async: false

  alias AshA2A.ArchitectureVerifier
  alias AshA2A.ArchitectureVerifier.ChicagoRollup
  alias AshA2A.Chicago.{Result, Runner}
  alias AshA2A.Chicago.Courts.OcelValidity

  @moduletag :tmp_dir

  @expected_courts [
    AshA2A.Chicago.Courts.SemanticEnvelope,
    AshA2A.Chicago.Courts.Brce,
    AshA2A.Chicago.Courts.AuthorityNonImplication,
    AshA2A.Chicago.Courts.ReceiptBinding,
    AshA2A.Chicago.Courts.OfflineReplay,
    AshA2A.Chicago.Courts.KnowledgeHooks,
    AshA2A.Chicago.Courts.OcelValidity
  ]

  @expected_court_ids [
    "SA2A-ENV",
    "CHI-BRCE",
    "SA2A-AUTH",
    "CHI-RECEIPT",
    "CHI-REPLAY",
    "SA2A-HOOK",
    "SA2A-OCEL"
  ]

  test "courts/0 names exactly the seven real, already-compiled Chicago courts, in report order" do
    assert ChicagoRollup.courts() == @expected_courts

    # Every named module is a real, compiled Chicago court right now -- not a
    # name that merely looks right.
    assert Enum.all?(ChicagoRollup.courts(), &AshA2A.Chicago.Court.court?/1)
    assert Enum.map(ChicagoRollup.courts(), & &1.id()) == @expected_court_ids
  end

  test "check_court/1 on a real court returns the same result shape ArchitectureVerifier.checks/0 uses" do
    result = ChicagoRollup.check_court(OcelValidity)

    assert %{name: name, status: status, detail: detail} = result
    assert is_binary(name)
    assert status in [:pass, :fail]
    assert is_binary(detail)
    assert name =~ "SA2A-OCEL"
  end

  test "check_court/1 real-runs the SA2A-OCEL court through AshA2A.Chicago.Runner and real-passes",
       %{
         tmp_dir: dir
       } do
    # The wrapped call under test.
    result = ChicagoRollup.check_court(OcelValidity)
    assert result.status == :pass
    assert result.detail =~ "real-corroborated-passed"

    # Independently re-derive the same real state the wrapper summarized,
    # via a direct, separate `Runner.run/1` call of our own (not a mock of
    # the collaborator -- the actual production API, called a second time)
    # into our own evidence dir, and assert on the real returned/persisted
    # state per the Chicago discipline: every falsifier this court declared
    # really killed/passed/measured AND was really OCEL-corroborated by the
    # independent consumer, and the durable artifact really exists on disk.
    assert {:ok, run} =
             Runner.run(
               courts: [OcelValidity],
               profile: OcelValidity.profile(),
               evidence_dir: dir
             )

    refute run.results == []
    assert Enum.all?(run.results, &Result.counts_as_pass?/1), inspect(run.results)
    assert File.exists?(Path.join(dir, "ocel.json"))
    assert run.receipt["standing"] in ["CONFORMANT", "PARTIAL_ALIVE"]
  end

  # Runs all seven full Chicago courts sequentially (plus the 9 fast checks)
  # -- the same courts this repo's own dedicated `test/ash_a2a/chicago/
  # *_test.exs` files each run individually within the default timeout, but
  # summed here in one test. Tagged generously, matching this repo's own
  # convention for its heavier Chicago tests (e.g.
  # `brce_gate7_test.exs`'s `@tag timeout: 300_000`).
  @tag timeout: 600_000
  test "ArchitectureVerifier.checks/0 rolls up all seven real Chicago courts alongside the original ten" do
    results = ArchitectureVerifier.checks()

    # 10 original checks (including the later-merged check 7b, the
    # RFC-SA2A-002 Gate 7 sole-DO fence) + 7 Chicago-court rollup checks,
    # additive per the brief -- `test/ash_a2a_architecture_verifier_test.exs`
    # asserts the original ten individually and is untouched by this file.
    assert length(results) == 17

    assert Enum.all?(
             results,
             &match?(
               %{name: n, status: s, detail: d}
               when is_binary(n) and s in [:pass, :fail] and is_binary(d),
               &1
             )
           )

    names = Enum.map(results, & &1.name)
    assert length(names) == length(Enum.uniq(names))

    rollup_names = Enum.take(names, -7)

    for court_id <- @expected_court_ids do
      assert Enum.any?(rollup_names, &(&1 =~ court_id)),
             "expected a rolled-up check naming #{court_id}, got: #{inspect(rollup_names)}"
    end

    # Every real court this rollup runs genuinely passes right now -- the
    # same claim each court's own dedicated test file already makes
    # separately (e.g. brce_gate7_test.exs, envelope_negotiation_transport_test.exs).
    assert Enum.all?(results, &(&1.status == :pass)), inspect(results)
  end
end
