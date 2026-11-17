# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MutationWave3CatalogTest do
  @moduledoc """
  Anti-vacuity proof for the wave-3 mutation catalog entries.

  Each guard added after the original §97 catalog is deleted in this VM by the
  real mutation engine (real BEAM `debug_info`, `:compile.forms/2`, hot code
  loading) and the reference court `CHI-MUTWAVE3` must go red on the exact
  falsifiers that attack it. The court drives the real functions, plugs and
  transports (real RSA/Ed25519 keys, a real `:ssl` listener, an EKV ledger,
  an ETS journal, `Plug.Test` connections): no mocks. A mutant that survives
  would mean a court that does not bite.

  `async: false`: a live mutant changes code for the whole node.
  """

  use ExUnit.Case, async: false

  # Tier tags are per describe: the exhaustive matrix carries ONLY
  # `:mutation_catalog_full` (ExUnit lets `--include`/`--only` win over
  # `--exclude`, so a module-level `:serial` would defeat the exclusion).
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  alias AshA2A.Chicago.{Mutation, Runner}
  alias AshA2A.Chicago.Mutation.{Catalog, Wave3Court}

  # mutant id => falsifiers that must be the ones that kill it
  @expected %{
    "email_webhook_auth_optional" => ~w(CHI-MUTWAVE3-001),
    "email_replay_ledger_optional" => ~w(CHI-MUTWAVE3-002),
    "email_webhook_auth_skipped" => ~w(CHI-MUTWAVE3-003),
    "email_depth_cap_ok" => ~w(CHI-MUTWAVE3-004),
    "email_node_cap_ok" => ~w(CHI-MUTWAVE3-005),
    "email_reply_cap_ok" => ~w(CHI-MUTWAVE3-006),
    "dkim_body_length_limit_ok" => ~w(CHI-MUTWAVE3-007),
    "dkim_multiple_from_ok" => ~w(CHI-MUTWAVE3-008),
    "dkim_from_alignment_ok" => ~w(CHI-MUTWAVE3-009),
    "dkim_expiry_ok" => ~w(CHI-MUTWAVE3-010),
    "dkim_weak_key_ok" => ~w(CHI-MUTWAVE3-011),
    "dkim_body_hash_ok" => ~w(CHI-MUTWAVE3-012),
    "token_ledger_put_unconditional" => ~w(CHI-MUTWAVE3-013),
    "error_bindings_table_corrupt" => ~w(CHI-MUTWAVE3-014),
    "error_bindings_a2a_scope_all" => ~w(CHI-MUTWAVE3-015),
    "admission_refusal_never" => ~w(CHI-MUTWAVE3-016),
    "admission_refusal_always" => ~w(CHI-MUTWAVE3-017),
    "json_guard_depth_ok" => ~w(CHI-MUTWAVE3-018),
    "json_decode_not_total" => ~w(CHI-MUTWAVE3-019),
    "journal_record_task_noop" => ~w(CHI-MUTWAVE3-020),
    "journal_append_unverified" => ~w(CHI-MUTWAVE3-021),
    "tls_verify_peer_off" => ~w(CHI-MUTWAVE3-022),
    "tls_downgrade_to_uds" => ~w(CHI-MUTWAVE3-023),
    "card_alg_allowlist_ok" => ~w(CHI-MUTWAVE3-024 CHI-MUTWAVE3-025),
    "card_key_alg_ok" => ~w(CHI-MUTWAVE3-026),
    "card_signature_verify_true" => ~w(CHI-MUTWAVE3-027),
    "brief_mac_drops_approver" => ~w(CHI-MUTWAVE3-029),
    "brief_mac_drops_expiry" => ~w(CHI-MUTWAVE3-030),
    "brief_missing_key_unkeyed_fallback" => ~w(CHI-MUTWAVE3-031),
    "task_owner_gate_open" => ~w(CHI-MUTWAVE3-028)
  }

  @touched @expected
           |> Map.keys()
           |> Enum.map(&Catalog.fetch!(&1).module)
           |> Enum.uniq()

  setup_all do
    on_exit(fn -> for module <- @touched, do: Mutation.restore!(module) end)
    :ok
  end

  setup do
    for module <- @touched do
      assert Mutation.pristine?(module), "#{inspect(module)} entered the test mutated"
    end

    on_exit(fn -> for module <- @touched, do: Mutation.restore!(module) end)
    :ok
  end

  @tag :serial
  @tag :serial_shard
  test "the catalog holds the wave-3 mutants, each resolvable with CHI-MUTWAVE3 as killer" do
    # At least the 19 original and the wave-3 mutants; other lanes may add more.
    assert length(Catalog.entries()) >= 19 + map_size(@expected)
    resolution = Map.new(Catalog.resolution(), &{&1.id, &1})

    for id <- Map.keys(@expected) do
      assert %{status: :resolvable, clauses_mutated: n} = resolution[id].target_status, id
      assert n >= 1
      assert resolution[id].killers.resolved == ["CHI-MUTWAVE3"], id
      assert resolution[id].killers.missing == [], id
    end

    assert Wave3Court in Catalog.reference_courts()
  end

  @tag :serial
  @tag :serial_shard
  test "the unmutated court is clean: every negative killed, every control passed", %{
    tmp_dir: dir
  } do
    assert {:ok, run} = Runner.run(courts: [Wave3Court], profile: :strict, evidence_dir: dir)
    assert length(run.results) == length(Wave3Court.falsifiers())

    for r <- run.results do
      assert r.verdict in [:falsifier_killed, :positive_control_passed],
             "#{r.falsifier_id}: #{inspect(r.verdict)} #{inspect(r.evidence)}"

      assert r.ocel_corroborated? == true, "#{r.falsifier_id}: #{r.ocel_detail}"
    end
  end

  # One representative per guard family in the default serial_shard tier; the
  # full 31-mutant matrix below is `:mutation_catalog_full` (`mix test.mutation`,
  # proofs.yml). Every subset id must be in @expected (checked at compile time).
  @subset ~w(email_depth_cap_ok dkim_expiry_ok token_ledger_put_unconditional
             tls_verify_peer_off card_signature_verify_true task_owner_gate_open)
  for id <- @subset,
      not Map.has_key?(@expected, id),
      do: raise("subset id #{id} is not in @expected")

  describe "representative wave-3 mutants are killed by the falsifiers that attack their guard" do
    @describetag :serial
    @describetag :serial_shard

    for {id, killed} <- Map.take(@expected, @subset) do
      test "#{id}", %{tmp_dir: dir} do
        assert_killed(unquote(id), unquote(killed), dir)
      end
    end
  end

  describe "full catalog: every wave-3 mutant is killed by the falsifiers that attack its guard" do
    @describetag :mutation_catalog_full

    for {id, killed} <- @expected do
      @tag mutant: id
      test "#{id}", %{tmp_dir: dir} do
        assert_killed(unquote(id), unquote(killed), dir)
      end
    end
  end

  defp assert_killed(id, killed, dir) do
    mutation = Catalog.fetch!(id)
    {:ok, courts, []} = Mutation.killer_courts(mutation)
    baseline = Mutation.baseline(courts, Path.join(dir, "baseline"))

    verdict =
      Mutation.qualify(mutation, evidence_dir: Path.join(dir, "mutant"), baseline: baseline)

    assert verdict.verdict == :mutant_killed, inspect(verdict.detail)
    assert verdict.mutant_calls > 0, "the mutated function was never executed"
    assert verdict.restored.pristine == true

    for falsifier <- killed do
      assert falsifier in verdict.killed_by,
             "#{falsifier} did not kill #{id}: killed_by #{inspect(verdict.killed_by)}"
    end

    assert Mutation.pristine?(mutation.module)
  end
end
