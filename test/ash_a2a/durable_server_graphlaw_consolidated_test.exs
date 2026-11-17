# NOTE: 2 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Durable Server & GraphLaw
# Contains 20 original test files:
#   - test/ash_a2a/command_contract_test.exs
#   - test/ash_a2a/consequence_class_test.exs
#   - test/ash_a2a/consequence_floor_test.exs
#   - test/ash_a2a/context_resolver_test.exs
#   - test/ash_a2a/distributed_node_loss_test.exs
#   - test/ash_a2a/docs_truth_test.exs
#   - test/ash_a2a/dsl_test.exs
#   - test/ash_a2a/dual_safe_map_update_test.exs
#   - test/ash_a2a/durable_server_continuity_real_test.exs
#   - test/ash_a2a/durable_server_continuity_test.exs
#   - test/ash_a2a/durable_server_provider_result_test.exs
#   - test/ash_a2a/durable_server_real_restart_test.exs
#   - test/ash_a2a/durable_server_test.exs
#   - test/ash_a2a/equilibrium_switchboard_test.exs
#   - test/ash_a2a/execution_context_test.exs
#   - test/ash_a2a/fibo_simulation_conformance_test.exs
#   - test/ash_a2a/flame_placement_test.exs
#   - test/ash_a2a/flame_real_placement_test.exs
#   - test/ash_a2a/graph_law_wasm_test.exs
#   - test/ash_a2a/graph_law_wasmex_host_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/command_contract_test.exs ---
defmodule AshA2A.CommandContractTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Command, Identity}

  test "machine identities remain typed and non-interchangeable" do
    agent = Identity.agent("worker-7")
    task = Identity.task("worker-7")

    assert agent.kind == :agent
    assert task.kind == :task
    refute agent == task
    assert Identity.external(agent) == "agent:worker-7"
    assert Identity.external(task) == "task:worker-7"
  end

  test "authority is bound to one admitted principal and capability" do
    principal = Identity.principal("subject-1")
    authority = Authority.new(principal, "Example.Resource.read", token_id: "auth-1")

    command =
      Command.new("Example.Resource.read",
        command_id: "command-1",
        agent_id: "agent-1",
        principal_id: principal,
        authority: authority,
        input: %{id: 1}
      )

    assert Authority.admits?(authority, command)

    other = %{command | capability_id: "Example.Resource.update"}
    refute Authority.admits?(authority, other)
  end

  test "semantic fingerprint is stable across transport retry identity and timestamp" do
    principal = Identity.principal("subject-1")
    authority = Authority.new(principal, "Example.Resource.read", token_id: "auth-1")
    common = [agent_id: "agent-1", principal_id: principal, authority: authority, input: %{id: 1}]

    one = Command.new("Example.Resource.read", Keyword.merge(common, command_id: "command-1"))
    two = Command.new("Example.Resource.read", Keyword.merge(common, command_id: "command-2"))

    assert one.command_id != two.command_id
    assert one.fingerprint == two.fingerprint
  end

  test "fingerprint changes when consequence-bearing semantic input changes" do
    principal = Identity.principal("subject-1")
    common = [agent_id: "agent-1", principal_id: principal]

    one = Command.new("Example.Resource.update", Keyword.merge(common, input: %{value: 1}))
    two = Command.new("Example.Resource.update", Keyword.merge(common, input: %{value: 2}))

    refute one.fingerprint == two.fingerprint
  end
end

# --- SECTION 2: Original test/ash_a2a/consequence_class_test.exs ---
defmodule AshA2A.ConsequenceClassTest do
  use ExUnit.Case, async: true

  test "unknown is fail closed" do
    assert {:ok, :unknown} = AshA2A.ConsequenceClass.classify(:custom)
    refute AshA2A.ConsequenceClass.admitted?(:unknown)
  end
end

# --- SECTION 3: Original test/ash_a2a/consequence_floor_test.exs ---
defmodule AshA2A.ConsequenceFloorTest do
  @moduledoc """
  SEC-04 court: `consequence: :observe` on a mutating (`:create`/`:update`/
  `:destroy`) action must be a compile-time `Spark.Error.DslError`, because
  `:observe` bypasses `AshA2A.Authority.Grant`, `AshA2A.CommandBus`
  admission, receipts and the BRCE anchor. Real `defmodule` compilation
  through the real `AshA2A.Transformers.BuildCapabilityIndex`; no doubles.
  """
  use ExUnit.Case

  test "resource-level :observe on a default :create action is refused at compile time" do
    error =
      assert_raise Spark.Error.DslError, fn ->
        defmodule Elixir.AshA2A.Test.ConsequenceFloor.ObserveCreate do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
            attribute(:label, :string, public?: true)
          end

          actions do
            defaults([:read, create: [:label]])
          end

          a2a do
            skill(:sneaky_create, :create, consequence: :observe)
          end
        end
      end

    assert error.message =~ "observe_on_mutating_action"
    assert error.path == [:a2a, :sneaky_create, :consequence]
  end

  for type <- [:update, :destroy] do
    test "resource-level :observe on an explicit #{type} action is refused" do
      type = unquote(type)
      mod = Module.concat(AshA2A.Test.ConsequenceFloor, "Explicit#{type}")

      error =
        assert_raise Spark.Error.DslError, fn ->
          Code.compile_quoted(
            quote do
              defmodule unquote(mod) do
                use Ash.Resource,
                  domain: nil,
                  validate_domain_inclusion?: false,
                  data_layer: Ash.DataLayer.Ets,
                  extensions: [AshA2A]

                attributes do
                  uuid_primary_key(:id)
                  attribute(:label, :string, public?: true)
                end

                actions do
                  defaults([:read])
                  unquote(type)(:mutate)
                end

                a2a do
                  skill(:mutate_skill, :mutate, consequence: :observe)
                end
              end
            end
          )
        end

      assert error.message =~ "#{inspect(type)} action `mutate`"
    end
  end

  test "domain-level :observe on a real resource's :destroy action is refused" do
    error =
      assert_raise Spark.Error.DslError, fn ->
        defmodule Elixir.AshA2A.Test.ConsequenceFloor.ObserveDestroyDomain do
          use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

          resources do
            resource(AshA2A.Test.Fixture.Item)
          end

          a2a do
            skill(:quiet_destroy, AshA2A.Test.Fixture.Item, :destroy, consequence: :observe)
          end
        end
      end

    assert error.message =~ "observe_on_mutating_action"
  end

  test "raising a mutating action and :observe on :read/generic actions still compile" do
    defmodule Elixir.AshA2A.Test.ConsequenceFloor.Allowed do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshA2A]

      attributes do
        uuid_primary_key(:id)
        attribute(:label, :string, public?: true)
      end

      actions do
        defaults([:read, create: [:label]])

        action :ping, :string do
          run(fn _input, _context -> {:ok, "pong"} end)
        end
      end

      a2a do
        skill(:loud_create, :create, consequence: :external_do)
        skill(:look, :read, consequence: :observe)
        skill(:ping, :ping, consequence: :observe)
      end
    end

    overrides =
      Spark.Dsl.Extension.get_persisted(
        AshA2A.Test.ConsequenceFloor.Allowed,
        :ash_a2a_skill_overrides
      )

    assert Enum.map(overrides, &{&1.name, &1.consequence}) == [
             loud_create: :external_do,
             look: :observe,
             ping: :observe
           ]
  end

  test "the refusal code is S42-classified" do
    assert AshA2A.Transformers.BuildCapabilityIndex.__sa2a_refusal_codes__() ==
             %{observe_on_mutating_action: :refused_consequence}
  end
end

# --- SECTION 4: Original test/ash_a2a/context_resolver_test.exs ---
defmodule AshA2A.ContextResolverTest do
  @moduledoc """
  Real-collaborator tests for `AshA2A.ContextResolver.fetch/2`'s string-keyed
  fallback branch: `Map.fetch(metadata, key)` misses (the caller supplied the
  key as a string, not an atom, since `AshA2A.Protocol.Message.metadata` is parsed
  straight from remote-caller JSON, per the moduledoc) and the private
  `fetch/2` helper falls back to `Map.get(metadata, Atom.to_string(key))`.

  The module's own doctest only exercises the atom-keyed happy path
  (`%{id: "user-1", tenant: "acme"}` for `auth_identity`, and implicit `%{}`
  for `metadata[:context]`); it documents the string-key fallback as
  symmetric but never actually reaches that branch. These tests reach it for
  real: `tenant_claim/1` calls `fetch(auth_identity, :tenant)`, so a
  string-keyed `auth_identity` map exercises the fallback in the `:tenant`
  path, and a string-keyed `"context"` key in `message.metadata` exercises it
  in the `:context` path.
  """

  use ExUnit.Case, async: true

  alias AshA2A.ContextResolver

  describe "from_a2a_message/4 string-keyed fallback branches" do
    test "auth_identity keyed by string \"tenant\" is read via the string-key fallback" do
      message = AshA2A.Protocol.Message.new_user("hi")

      auth_identity = %{"id" => "user-1", "tenant" => "acme"}

      ctx =
        ContextResolver.from_a2a_message(
          message,
          AshA2A.Test.Fixture.Domain,
          [],
          auth_identity
        )

      # actor is auth_identity verbatim, regardless of key type.
      assert ctx.actor == auth_identity

      # tenant_claim/1 -> fetch(auth_identity, :tenant): Map.fetch(auth_identity, :tenant)
      # misses because the key is the string "tenant", not the atom :tenant --
      # this assertion only passes if the string-key fallback
      # (Map.get(auth_identity, Atom.to_string(:tenant))) actually ran.
      assert ctx.tenant == "acme"
    end

    test "message metadata keyed by string \"context\" is read via the string-key fallback" do
      raw_context = %{foo: 1}

      %AshA2A.Protocol.Message{} = base_message = AshA2A.Protocol.Message.new_user("hi")
      message = %AshA2A.Protocol.Message{base_message | metadata: %{"context" => raw_context}}

      ctx =
        ContextResolver.from_a2a_message(
          message,
          AshA2A.Test.Fixture.Domain
        )

      # fetch(metadata, :context): Map.fetch(metadata, :context) misses because
      # the key is the string "context", not the atom :context -- this
      # assertion only passes if the string-key fallback
      # (Map.get(metadata, Atom.to_string(:context))) actually ran and
      # returned the real, non-default value (an empty map would also satisfy
      # a weaker assertion, so assert the exact raw_context contents).
      #
      # SEC-11: the caller-supplied map is namespaced under
      # `:a2a_client_context`, never merged at the top level.
      assert ctx.context == %{a2a_client_context: raw_context}
      assert ctx.context == %{a2a_client_context: %{foo: 1}}
      refute Map.has_key?(ctx.context, :foo)
    end

    test "a caller cannot place a top-level key into the Ash context (SEC-11)" do
      message = %{
        AshA2A.Protocol.Message.new_user("hi")
        | metadata: %{"context" => %{"authorize?" => false}}
      }

      ctx = ContextResolver.from_a2a_message(message, AshA2A.Test.Fixture.Domain)

      assert Map.keys(ctx.context) == [:a2a_client_context]
      assert ctx.context.a2a_client_context == %{"authorize?" => false}
    end

    test "non-map context or non-map metadata resolves to an empty context, never raises" do
      bad_ctx = %{AshA2A.Protocol.Message.new_user("hi") | metadata: %{"context" => "x"}}
      assert ContextResolver.from_a2a_message(bad_ctx, AshA2A.Test.Fixture.Domain).context == %{}

      bad_md = %{AshA2A.Protocol.Message.new_user("hi") | metadata: [1]}
      assert ContextResolver.from_a2a_message(bad_md, AshA2A.Test.Fixture.Domain).context == %{}
    end
  end
end

# --- SECTION 5: Original test/ash_a2a/distributed_node_loss_test.exs ---

# --- SECTION 6: Original test/ash_a2a/docs_truth_test.exs ---

# --- SECTION 7: Original test/ash_a2a/dsl_test.exs ---
defmodule AshA2A.DslTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Direct coverage of `AshA2A.Dsl.sections/0` -- the raw Spark schema/section
  definition. Existing tests (`test/ash_a2a_test.exs` and friends) only
  exercise the DSL indirectly, through resources/domains that `use AshA2A`
  and declare `a2a do skill ... end` blocks; none of them call
  `AshA2A.Dsl.sections/0` itself or assert on its real, compiled
  `Spark.Dsl.Section`/`Spark.Dsl.Entity` shape.
  """

  test "sections/0 returns the real :a2a section with a :skill entity taking name/resource/action args" do
    assert sections = AshA2A.Dsl.sections()
    assert %Spark.Dsl.Section{} = section = Enum.find(sections, &(&1.name == :a2a))
    assert [%Spark.Dsl.Entity{} = skill_entity] = section.entities
    assert skill_entity.name == :skill
    assert skill_entity.target == AshA2A.Skill
    assert skill_entity.args == [:name, {:optional, :resource}, :action]
    assert skill_entity.identifier == :name

    schema_keys = Keyword.keys(skill_entity.schema)
    assert :name in schema_keys
    assert :resource in schema_keys
    assert :action in schema_keys
  end
end

# --- SECTION 8: Original test/ash_a2a/dual_safe_map_update_test.exs ---
defmodule AshA2A.DualSafeMapUpdateTest do
  @moduledoc """
  Pins the dual-safe accumulator idiom (OS-20 / w525d): `Map.update/4` on the
  pinned toolchain (elixir 1.20.4-otp-29) deviates from documented semantics on
  the absent-key path — it inserts `default` WITHOUT applying `fun`. Every
  ABSENT-KEY-RELIANT site in `lib/` was rewritten to the explicit fetch/put
  form so the stored value is identical under BOTH the deviating and the
  documented behavior. These tests fail if a site regresses to `Map.update/4`
  semantics where the default's `fun`-application would double-insert
  (documented behavior) or if the explicit form's accumulator contract breaks.
  """

  use ExUnit.Case, async: true

  # Safe sites per the w525d census: fun is idempotent over the default, so
  # these Map.update/4 call sites are correct under both toolchain behaviors.
  @w525d_safe_files [
    "ash_a2a/chicago/closure/court.ex",
    "ash_a2a/chicago/observer/journal.ex",
    "ash_a2a/runtime_identity/execution.ex",
    "ash_a2a/telemetry/allocation_counters.ex",
    "ash_a2a/c2/memory_claim_store.ex"
  ]

  # The representative site pattern: cons-a-onto-list accumulator
  # (task_events.ex:142, state.ex:138, workload_watcher.ex, closure/court.ex:331).
  defp attempt_acc(attempts, task_id, attempt) do
    case Map.fetch(attempts, task_id) do
      :error -> Map.put(attempts, task_id, [attempt])
      {:ok, prior} -> Map.put(attempts, task_id, Enum.take([attempt | prior], 100))
    end
  end

  # Counter accumulator pattern (entropy.ex:26).
  defp count_acc(freqs, byte) do
    case Map.fetch(freqs, byte) do
      :error -> Map.put(freqs, byte, 1)
      {:ok, count} -> Map.put(freqs, byte, count + 1)
    end
  end

  describe "dual-safe cons accumulator (task_events/state/workload_watcher pattern)" do
    test "absent key stores the default verbatim — fun is NOT applied" do
      assert attempt_acc(%{}, "t1", :a1) == %{"t1" => [:a1]}
    end

    test "present key applies the fold — new element prepended, bounded at 100" do
      prior = List.duplicate(:x, 99)
      assert attempt_acc(%{"t1" => prior}, "t1", :a) == %{"t1" => [:a | prior]}
    end

    test "present key truncates to the 100-element cap" do
      prior = List.duplicate(:x, 100)
      result = attempt_acc(%{"t1" => prior}, "t1", :a)
      assert length(result["t1"]) == 100
      assert [h | _] = result["t1"]
      assert h == :a
    end

    test "absent-key insert followed by second insert does not duplicate the head" do
      acc = attempt_acc(%{}, "t1", :a1)
      acc = attempt_acc(acc, "t1", :a2)
      assert acc == %{"t1" => [:a2, :a1]}
    end

    test "other tasks' accumulators are untouched" do
      acc = attempt_acc(%{"t1" => [:a1]}, "t2", :a2)
      assert acc == %{"t1" => [:a1], "t2" => [:a2]}
    end
  end

  describe "dual-safe counter accumulator (entropy pattern)" do
    test "first occurrence stores 1, not 2" do
      assert count_acc(%{}, ?a) == %{?a => 1}
    end

    test "repeated occurrences increment" do
      acc = count_acc(%{}, ?a)
      assert count_acc(acc, ?a) == %{?a => 2}
    end

    test "counter stays correct under documented Map.update semantics too" do
      # Dual: simulate the documented behavior (apply fun to default) and
      # confirm the idiom's result is what the deviating toolchain produces —
      # i.e. first count is 1 either way, because fun is never applied to the
      # default by the idiom itself.
      documented_style = fn m, k, d, f ->
        case Map.fetch(m, k) do
          :error -> Map.put(m, k, f.(d))
          {:ok, v} -> Map.put(m, k, f.(v))
        end
      end

      refute documented_style.(%{}, ?a, 1, &(&1 + 1)) == count_acc(%{}, ?a)
      assert count_acc(%{}, ?a) == %{?a => 1}
    end
  end

  describe "real site: entropy.shannon_bits_per_char end-to-end" do
    test "uniform byte string has zero entropy" do
      assert AshA2A.Security.DLP.Entropy.shannon_bits_per_char("aaaa") == 0.0
    end

    test "high-entropy binary has high per-char entropy" do
      bits = AshA2A.Security.DLP.Entropy.shannon_bits_per_char("abcdefgh")
      assert bits > 2.5 and bits <= 8.0
    end

    test "empty binary is 0.0" do
      assert AshA2A.Security.DLP.Entropy.shannon_bits_per_char("") == 0.0
    end
  end

  describe "no reliance on Map.update/4 absent-key fun application remains in lib/" do
    test "all former reliant sites use the explicit fetch/put form" do
      lib = Path.join([File.cwd!(), "lib"])

      remaining =
        lib
        |> grep_map_update()
        |> Enum.reject(fn {file, _line, text} ->
          # Safe sites per w525d census: fun is idempotent over the default.
          safe_markers = [
            "MapSet.new([from])",
            "MapSet.put",
            "&max(",
            "Map.put(&1, resolver",
            "{0, {:completed"
          ]

          file_suffix = Path.relative_to(file, lib)
          file_suffix in @w525d_safe_files or Enum.any?(safe_markers, &String.contains?(text, &1))
        end)

      assert remaining == [],
             "reliant Map.update sites reintroduced: #{inspect(remaining, pretty: true)}"
    end
  end

  defp grep_map_update(dir) do
    dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} ->
        if String.contains?(line, "Map.update(") and not String.contains?(line, "Map.update!"),
          do: [{file, n, String.trim(line)}],
          else: []
      end)
    end)
  end
end

# --- SECTION 9: Original test/ash_a2a/durable_server_continuity_real_test.exs ---
defmodule AshA2A.DurableServerContinuityRealTest do
  @moduledoc """
  Mainline continuity assertions against the REAL `DurableServer.Supervisor`
  (Elixir sweep queue item 2).

  `test/ash_a2a/durable_server_continuity_test.exs` ported its mainline
  continuity cases to `AshA2A.Test.FakeDurableServerSupervisor`, a
  same-process `Agent`-backed simulation. Per the sweep's lawful split,
  the fake stays ONLY for fault injection (`simulate_restart/2` /
  `simulate_node_loss/2` -- behaviors the real supervisor does not
  expose); the mainline cases move here and run against the real
  supervisor + real EKV backend, using the same pattern already proven
  in-test by `AshA2A.DurableServerRealRestartTest` and
  `AshA2A.Test.RestartableDurableServerFixture`.

  What changed relative to the fake's mainline cases, stated precisely:

  - "restart preserves stable TaskID key and durable state": the fake's
    `simulate_restart/2` (a plain `generation + 1` map update -- no real
    process ever died) is replaced by a REAL untrappable
    `Process.exit(pid, :kill)` recovered by the REAL
    `DurableServer.LifecycleManager` discovery-and-restart sweep. Key
    stability is asserted through the real lookup surface; durable state
    is asserted by reading the recovered count back from the real
    EKV-backed storage via the restarted process -- never re-supplied by
    this test.
  - "node loss is observable and rehome is separately receipted": the
    fake's `simulate_node_loss/2` leg is fault injection and STAYS in the
    fake file. What moves here is the rehome mainline: `rehome_child/3`
    on the real supervisor terminates the running process and starts it
    on the best-available node (single-node here, so `Node.self()`),
    recovering durable state from real storage. This is the single-node
    analogue only -- real cross-node rehome remains BLOCKED here (would
    need a second real distributed BEAM node), same scope note as
    `AshA2A.DurableServerRealRestartTest`.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Durability.DurableServer, as: Durability
  alias AshA2A.Identity
  alias AshA2A.Test.RestartableDurableServerFixture, as: Fixture

  setup do
    sup_name =
      :"ash_a2a_test_continuity_real_sup_#{System.unique_integer([:positive])}"

    ekv_name = :"#{sup_name}_ekv"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_continuity_real_ekv_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    # Real EKV local durable-KV backend, same pattern as
    # AshA2A.DurableServerRealRestartTest (cluster_size: 1 -- a real
    # single-voter CAS quorum).
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

    start_supervised!({
      DurableServer.Supervisor,
      # Real, documented DurableServer.Supervisor options, tightened from
      # production cadence so the real LifecycleManager sweep is observable
      # inside a normal test timeout (same rationale as
      # AshA2A.DurableServerRealRestartTest).
      name: sup_name,
      prefix: "ash-a2a-continuity-real-test/",
      backend: {DurableServer.Backends.EKVStore, name: ekv_name},
      initial_discovery_delay_ms: 100,
      discovery_interval_ms: 300,
      discovery_burst_count: 5
    })

    %{sup: sup_name}
  end

  test "restart preserves stable TaskID key and durable state (real supervisor, real LifecycleManager restart)",
       %{sup: sup} do
    task_id = Identity.task("continuity-real-restart-#{System.unique_integer([:positive])}")
    task_key = Durability.key(task_id)

    assert {:ok, receipt} =
             Durability.ensure_task(sup, Fixture, task_id, %{count: 7})

    assert receipt.provider == :durable_server
    assert receipt.operation == :ensure_started_child
    assert receipt.status == :completed

    # Stable TaskID key: the adapter's key derivation resolves the running
    # real process through the real supervisor's own lookup surface.
    assert {pid_before, _meta_before} = DurableServer.Supervisor.lookup(sup, task_key)
    assert is_pid(pid_before)
    assert Process.alive?(pid_before)
    assert GenServer.call(pid_before, :get) == 7

    # Mutate and rely on the fixture's `sync: true` so the state genuinely
    # reaches real EKV-backed storage before the kill.
    assert GenServer.call(pid_before, :increment) == 8
    assert GenServer.call(pid_before, :increment) == 9

    # REAL, untrappable termination (terminate/2 does not run on :kill).
    # No simulate_restart -- the real LifecycleManager's own
    # discovery-and-restart sweep (tightened above) brings the process back.
    ref = Process.monitor(pid_before)
    Process.exit(pid_before, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid_before, :killed}, 5_000
    refute Process.alive?(pid_before)

    restarted_pid = wait_until_restarted(sup, task_key, pid_before)

    assert is_pid(restarted_pid)
    assert restarted_pid != pid_before
    assert Process.alive?(restarted_pid)

    # Same stable TaskID key resolves to the new process; durable state is
    # read back from real storage (9 -- the last synced count), never
    # re-supplied by this test.
    assert {pid_after, _meta_after} = DurableServer.Supervisor.lookup(sup, task_key)
    assert pid_after == restarted_pid
    assert GenServer.call(restarted_pid, :get) == 9

    # The adapter's real-provider lookup passes the real supervisor's
    # success shape through: the TaskID key still resolves post-restart.
    assert {pid_via_adapter, _meta} = Durability.lookup(sup, task_id)
    assert pid_via_adapter == restarted_pid
  end

  test "rehome is separately receipted and recovers durable state (real supervisor, single-node)",
       %{sup: sup} do
    task_id = Identity.task("continuity-real-rehome-#{System.unique_integer([:positive])}")
    task_key = Durability.key(task_id)

    assert {:ok, _ensure_receipt} =
             Durability.ensure_task(sup, Fixture, task_id, %{count: 11})

    {pid_before, _meta_before} = DurableServer.Supervisor.lookup(sup, task_key)
    assert GenServer.call(pid_before, :increment) == 12

    assert {:ok, rehome_receipt} =
             Durability.rehome_task(sup, Fixture, task_id, %{count: 0}, [])

    assert rehome_receipt.provider == :durable_server
    assert rehome_receipt.operation == :rehome_child
    assert rehome_receipt.status == :completed

    # Rehome terminated the original process and started a genuinely new
    # one (single-node: on this node), under the same stable TaskID key.
    assert {pid_after, _meta_after} = DurableServer.Supervisor.lookup(sup, task_key)
    assert is_pid(pid_after)
    assert pid_after != pid_before
    assert not Process.alive?(pid_before)
    assert Process.alive?(pid_after)

    # Durable state recovered from real storage (12), not re-supplied via
    # the rehome's initial_state (%{count: 0}).
    assert GenServer.call(pid_after, :get) == 12
    assert GenServer.call(pid_after, :increment) == 13
  end

  defp wait_until_restarted(sup, key, original_pid) do
    deadline_ms = System.monotonic_time(:millisecond) + 10_000

    do_wait_until_restarted(sup, key, original_pid, deadline_ms)
  end

  defp do_wait_until_restarted(sup, key, original_pid, deadline_ms) do
    case DurableServer.Supervisor.lookup(sup, key) do
      {pid, _meta} when is_pid(pid) and pid != original_pid ->
        pid

      _other ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk(
            "real DurableServer.LifecycleManager did not restart #{inspect(key)} under " <>
              "#{inspect(sup)} within the real polling deadline -- no genuinely new, live " <>
              "pid was observed via DurableServer.Supervisor.lookup/2"
          )
        end

        # Bounded poll on the real lookup observable.
        Process.sleep(50)
        do_wait_until_restarted(sup, key, original_pid, deadline_ms)
    end
  end
end

# --- SECTION 10: Original test/ash_a2a/durable_server_continuity_test.exs ---
defmodule AshA2A.Test.FakeDurableServerSupervisor do
  # ensure_started_child/rehome_child return `{:ok, {pid, meta}}` -- the real
  # DurableServer.Supervisor success shape the adapter requires (R10).
  def start_link do
    Agent.start_link(fn -> %{active: %{}, persisted: %{}} end)
  end

  def ensure_started_child(supervisor, {_server_module, spec_opts}, opts) do
    key = Keyword.fetch!(spec_opts, :key)
    initial_state = Keyword.fetch!(spec_opts, :initial_state)
    node = Keyword.get(opts, :node, :node_a)

    Agent.get_and_update(supervisor, fn state ->
      case Map.fetch(state.persisted, key) do
        {:ok, runtime} ->
          {{:ok, {self(), runtime}}, put_in(state.active[key], runtime)}

        :error ->
          runtime = %{
            key: key,
            node: node,
            generation: 1,
            state: initial_state,
            cordoned?: false
          }

          next =
            state
            |> put_in([:active, key], runtime)
            |> put_in([:persisted, key], runtime)

          {{:ok, {self(), runtime}}, next}
      end
    end)
  end

  def lookup(supervisor, key) do
    Agent.get(supervisor, &Map.fetch(&1.active, key))
  end

  def rehome_child(supervisor, {_server_module, spec_opts}, opts) do
    key = Keyword.fetch!(spec_opts, :key)
    initial_state = Keyword.fetch!(spec_opts, :initial_state)
    node = Keyword.get(opts, :node, :node_b)

    Agent.get_and_update(supervisor, fn state ->
      previous = Map.get(state.persisted, key)

      runtime = %{
        key: key,
        node: node,
        generation: if(previous, do: previous.generation + 1, else: 1),
        state: if(previous, do: previous.state, else: initial_state),
        cordoned?: false
      }

      next =
        state
        |> put_in([:active, key], runtime)
        |> put_in([:persisted, key], runtime)

      {{:ok, {self(), runtime}}, next}
    end)
  end

  def terminate_and_cordon_child(supervisor, key, _opts) do
    Agent.get_and_update(supervisor, fn state ->
      case Map.fetch(state.persisted, key) do
        {:ok, runtime} ->
          cordoned = %{runtime | cordoned?: true}

          next =
            state
            |> update_in([:active], &Map.delete(&1, key))
            |> put_in([:persisted, key], cordoned)

          {:ok, next}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  def uncordon_child(supervisor, key) do
    Agent.get_and_update(supervisor, fn state ->
      case Map.fetch(state.persisted, key) do
        {:ok, runtime} ->
          active = %{runtime | cordoned?: false}

          next =
            state
            |> put_in([:active, key], active)
            |> put_in([:persisted, key], active)

          {:ok, next}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  def terminate_and_delete_child(supervisor, key, _timeout) do
    Agent.update(supervisor, fn state ->
      state
      |> update_in([:active], &Map.delete(&1, key))
      |> update_in([:persisted], &Map.delete(&1, key))
    end)

    :ok
  end

  def simulate_restart(supervisor, key) do
    Agent.get_and_update(supervisor, fn state ->
      runtime = Map.fetch!(state.persisted, key)
      restarted = %{runtime | generation: runtime.generation + 1}

      next =
        state
        |> put_in([:active, key], restarted)
        |> put_in([:persisted, key], restarted)

      {{:ok, restarted}, next}
    end)
  end

  def simulate_node_loss(supervisor, node) do
    Agent.update(supervisor, fn state ->
      active =
        Map.reject(state.active, fn {_key, runtime} ->
          runtime.node == node
        end)

      %{state | active: active}
    end)

    :ok
  end
end

defmodule AshA2A.DurableServerContinuityTest do
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Durability.DurableServer
  alias AshA2A.Identity
  alias AshA2A.Test.FakeDurableServerSupervisor, as: FakeProvider

  setup do
    previous = Application.get_env(:ash_a2a, :durable_server_provider)
    Application.put_env(:ash_a2a, :durable_server_provider, FakeProvider)
    {:ok, supervisor} = FakeProvider.start_link()

    on_exit(fn ->
      if Process.alive?(supervisor), do: Agent.stop(supervisor)

      if is_nil(previous) do
        Application.delete_env(:ash_a2a, :durable_server_provider)
      else
        Application.put_env(:ash_a2a, :durable_server_provider, previous)
      end
    end)

    %{supervisor: supervisor}
  end

  test "restart preserves stable TaskID key and durable state", %{supervisor: supervisor} do
    task_id = Identity.task("restart-fixture")
    task_key = DurableServer.key(task_id)

    assert {:ok, receipt} =
             DurableServer.ensure_task(
               supervisor,
               __MODULE__,
               task_id,
               %{counter: 7},
               node: :node_a
             )

    assert receipt.provider == :durable_server
    assert receipt.operation == :ensure_started_child
    assert receipt.status == :completed
    assert {:ok, before_restart} = DurableServer.lookup(supervisor, task_id)
    assert before_restart.key == task_key
    assert before_restart.generation == 1
    assert before_restart.state == %{counter: 7}

    assert {:ok, restarted} = FakeProvider.simulate_restart(supervisor, task_key)
    assert restarted.generation == 2

    assert {:ok, after_restart} = DurableServer.lookup(supervisor, task_id)
    assert after_restart.key == task_key
    assert after_restart.generation == 2
    assert after_restart.state == %{counter: 7}
  end

  test "node loss is observable and rehome is separately receipted", %{supervisor: supervisor} do
    task_id = Identity.task("node-loss-fixture")
    task_key = DurableServer.key(task_id)

    assert {:ok, _receipt} =
             DurableServer.ensure_task(
               supervisor,
               __MODULE__,
               task_id,
               %{counter: 11},
               node: :node_a
             )

    assert :ok = FakeProvider.simulate_node_loss(supervisor, :node_a)
    assert :error = DurableServer.lookup(supervisor, task_id)

    assert {:ok, rehome_receipt} =
             DurableServer.rehome_task(
               supervisor,
               __MODULE__,
               task_id,
               %{counter: 0},
               node: :node_b
             )

    assert rehome_receipt.provider == :durable_server
    assert rehome_receipt.operation == :rehome_child
    assert rehome_receipt.status == :completed

    assert {:ok, recovered} = DurableServer.lookup(supervisor, task_id)
    assert recovered.key == task_key
    assert recovered.node == :node_b
    assert recovered.generation == 2
    assert recovered.state == %{counter: 11}
  end
end

# --- SECTION 11: Original test/ash_a2a/durable_server_provider_result_test.exs ---
defmodule AshA2A.Test.MisbehavingDurableServerProvider do
  @moduledoc """
  API-compatible DurableServer provider whose every operation returns the
  shape stored in this module's `:persistent_term` slot -- a real
  implementation of the provider contract (`AshA2A.Durability.DurableServer`
  substitution seam), not an interaction-verifying mock. Used to drive the
  adapter's result typing through shapes the real `DurableServer.Supervisor`
  can produce (`{:error, ...}`, raises such as the `ArgumentError` from a bad
  child spec, and exits from timed requests) plus undocumented shapes a
  faulty provider could return.
  """

  @slot {__MODULE__, :behavior}

  def set(behavior), do: :persistent_term.put(@slot, behavior)
  def clear, do: :persistent_term.erase(@slot)

  def ensure_started_child(_sup, _spec, _opts), do: behave(:ensure_started_child)
  def rehome_child(_sup, _spec, _opts), do: behave(:rehome_child)
  def terminate_and_cordon_child(_sup, _key, _opts), do: behave(:terminate_and_cordon_child)
  def uncordon_child(_sup, _key), do: behave(:uncordon_child)
  def terminate_and_delete_child(_sup, _key, _timeout), do: behave(:terminate_and_delete_child)
  def lookup(_sup, _key), do: behave(:lookup)

  defp behave(function) do
    case :persistent_term.get(@slot) do
      {:return, value} -> value
      :raise -> raise ArgumentError, "bad child spec for #{function}"
      :exit -> exit({:timeout, {GenServer, :call, [function]}})
      :throw -> throw({:thrown_by, function})
    end
  end
end

defmodule AshA2A.DurableServerProviderResultTest do
  @moduledoc """
  R10: `AshA2A.Durability.DurableServer` must only receipt a provider's
  documented success shapes and must never let a provider raise/exit/throw
  crash the caller.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Durability.DurableServer
  alias AshA2A.{Identity, RuntimeReceipt}
  alias AshA2A.Test.MisbehavingDurableServerProvider, as: Provider

  setup do
    previous = Application.get_env(:ash_a2a, :durable_server_provider)
    Application.put_env(:ash_a2a, :durable_server_provider, Provider)

    on_exit(fn ->
      Provider.clear()

      if is_nil(previous) do
        Application.delete_env(:ash_a2a, :durable_server_provider)
      else
        Application.put_env(:ash_a2a, :durable_server_provider, previous)
      end
    end)

    %{task_id: Identity.task("provider-result-#{System.unique_integer([:positive])}")}
  end

  defp operations(task_id) do
    [
      {:ensure_started_child,
       fn -> DurableServer.ensure_task(:sup, __MODULE__, task_id, %{}) end},
      {:rehome_child, fn -> DurableServer.rehome_task(:sup, __MODULE__, task_id, %{}) end},
      {:terminate_and_cordon_child, fn -> DurableServer.cordon_task(:sup, task_id) end},
      {:uncordon_child, fn -> DurableServer.uncordon_task(:sup, task_id) end},
      {:terminate_and_delete_child, fn -> DurableServer.delete_task(:sup, task_id) end}
    ]
  end

  test "documented success shapes are receipted", %{task_id: task_id} do
    pid = self()

    for {function, call} <- operations(task_id) do
      success =
        if function in [:ensure_started_child, :rehome_child],
          do: {:ok, {pid, %{}}},
          else: :ok

      Provider.set({:return, success})
      assert {:ok, %RuntimeReceipt{operation: ^function}} = call.()
    end
  end

  test "undocumented provider returns are typed errors, never receipts", %{task_id: task_id} do
    for {function, call} <- operations(task_id),
        bad <- [
          :error,
          :ignore,
          nil,
          {:error, :a, :b},
          self(),
          {:ok, :wrong_op_shape},
          {:ok, nil},
          {:ok, {:not_a_pid, %{}}}
        ] do
      # `{:ok, {pid, meta}}` with a real pid is the only ensure/rehome success
      # shape; `{:ok, nil}` / `{:ok, :atom}` name no started process.
      Provider.set({:return, bad})

      assert {:error, {:unexpected_provider_result, ^function, ^bad}} = call.(),
             "#{function} receipted #{inspect(bad)}"
    end

    # The `:ok`-returning operations do not accept a bare `:ok` for ensure/rehome.
    Provider.set({:return, :ok})

    assert {:error, {:unexpected_provider_result, :ensure_started_child, :ok}} =
             DurableServer.ensure_task(:sup, __MODULE__, task_id, %{})
  end

  test "provider {:error, _} passes through unchanged", %{task_id: task_id} do
    Provider.set({:return, {:error, :not_found}})

    for {_function, call} <- operations(task_id) do
      assert {:error, :not_found} = call.()
    end
  end

  test "provider raise, exit and throw become typed errors instead of crashing the caller",
       %{task_id: task_id} do
    for {function, call} <- operations(task_id) do
      Provider.set(:raise)
      assert {:error, {:durable_server_raised, ^function, message}} = call.()
      assert message =~ "bad child spec"

      Provider.set(:exit)
      assert {:error, {:durable_server_exit, ^function, {:timeout, _}}} = call.()

      Provider.set(:throw)
      assert {:error, {:durable_server_throw, ^function, {:thrown_by, ^function}}} = call.()
    end

    Provider.set(:exit)
    assert {:error, {:durable_server_exit, :lookup, _}} = DurableServer.lookup(:sup, task_id)
  end
end

# --- SECTION 12: Original test/ash_a2a/durable_server_real_restart_test.exs ---
defmodule AshA2A.DurableServerRealRestartTest do
  @moduledoc """
  GAP C -- real DurableServer restart evidence (Squad E agent 22).

  `test/ash_a2a/durable_server_continuity_test.exs`'s "restart preserves
  stable TaskID key and durable state" / "node loss is observable..."
  tests drive `AshA2A.Test.FakeDurableServerSupervisor`, a same-process
  `Agent`-backed simulation confirmed (by re-reading that file for this
  unit) still accurate as of this session: `simulate_restart/2` is a
  plain `%{runtime | generation: runtime.generation + 1}` map update and
  `simulate_node_loss/2` is a plain `Map.reject/2` over the Agent's own
  state -- no real OTP process ever dies, no real distributed node is
  ever involved. That file is intentionally left unextended here.

  This module instead drives the REAL `durable_server` hex dependency --
  the same real `DurableServer.Supervisor` + real `EKV` local backend
  already exercised by `AshA2A.RuntimeProvidersIntegrationTest`'s
  `Durability` describe block -- genuinely kills the real child
  `GenServer` process with `Process.exit(pid, :kill)`, and proves the
  real `DurableServer.LifecycleManager`'s own discovery-and-restart sweep
  (never a hand-rolled re-ensure/re-claim call from this test) detects
  the dead process and restarts it under real supervision, recovering
  real durably-synced state.

  ## What was actually read in `deps/durable_server` to ground this test

  - `lib/durable_server/lifecycle_manager.ex`: automatic restart only
    considers servers with `meta.permanent == true` (default `false`);
    `check_server_health/2` uses `Group.lookup/3` (the real `:syn`-style
    fast path) for liveness, falling back to
    `fetch_orphaned_slow_path/1` when the registry entry is gone.
  - `lib/durable_server.ex`: `check_lock_status/1`, for a key whose
    recorded owner node is the CURRENT node, calls `__check_lock__/3`
    directly, which does a real local `Process.alive?(pid)` check --
    same-node restart eligibility is therefore detected immediately on
    the next discovery sweep, not gated behind the ~30s cross-node
    heartbeat-staleness window. `DurableServer.Supervisor`'s own
    moduledoc documents `discovery_interval_ms`/
    `initial_discovery_delay_ms`/`discovery_burst_count` as real,
    supported `start_link/1` options ("With custom intervals" example) --
    this test tightens them from their 60s/1-6s/3 production defaults
    purely to make the real sweep observable inside a normal test
    timeout, not to bypass any real mechanic.
  - `lib/durable_server.ex` `child_spec/1`: sets `restart: :temporary` on
    the underlying `DynamicSupervisor` child spec, confirming that a
    plain OTP supervisor restart is NOT what recovers a killed
    DurableServer -- the `LifecycleManager` discovery/restart-claim path
    is the actual, real, documented recovery mechanism this test
    exercises.

  ## Scope, stated precisely (do not conflate with cross-node rehome)

  This is single-node. `DurableServer.LifecycleManager`'s restart path
  has a real cross-node orphan-claim path too (a second BEAM node erpc's
  in and claims the key when the recorded owner node's heartbeat goes
  stale), but this test does not start a second real distributed node, so
  it cannot and does not exercise or claim that path.
  Real standing, precisely:
  - real single-node LifecycleManager-driven restart-after-kill: ALIVE
    (this test).
  - real cross-node rehome/orphan-claim-by-another-node: BLOCKED here
    (would need a second real distributed BEAM node) -- see
    `AshA2A.DurableServerContinuityTest`'s `rehome_task/5` receipt path
    for the (still only simulated) analogue, left to a real
    distributed-peer-node unit.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Durability.DurableServer, as: Durability
  alias AshA2A.Identity
  alias AshA2A.Test.RestartableDurableServerFixture, as: Fixture

  setup do
    sup_name = :"ash_a2a_test_real_restart_sup_#{System.unique_integer([:positive])}"
    ekv_name = :"#{sup_name}_ekv"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_real_restart_ekv_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    # Same real EKV local durable-KV backend pattern as
    # AshA2A.RuntimeProvidersIntegrationTest's Durability describe block
    # (cluster_size: 1 -- a real single-voter CAS quorum).
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

    start_supervised!({
      DurableServer.Supervisor,
      # Real, documented DurableServer.Supervisor options (see its own
      # moduledoc "With custom intervals" example), tightened from the
      # 60_000ms / {1_000, 6_000}ms / 3 production defaults so this
      # test observes a real LifecycleManager restart sweep well inside
      # a normal test timeout instead of waiting on production cadence.
      name: sup_name,
      prefix: "ash-a2a-real-restart-test/",
      backend: {DurableServer.Backends.EKVStore, name: ekv_name},
      initial_discovery_delay_ms: 100,
      discovery_interval_ms: 300,
      discovery_burst_count: 5
    })

    %{sup: sup_name}
  end

  test "a real killed DurableServer-managed process is restarted by the real LifecycleManager and recovers real synced state",
       %{sup: sup} do
    task_id = Identity.new(:task, "real-restart-#{System.unique_integer([:positive])}")

    assert {:ok,
            %AshA2A.RuntimeReceipt{provider: :durable_server, operation: :ensure_started_child}} =
             Durability.ensure_task(sup, Fixture, task_id, %{count: 0})

    key = Durability.key(task_id)

    {original_pid, _meta} = DurableServer.Supervisor.lookup(sup, key)
    assert is_pid(original_pid)

    assert GenServer.call(original_pid, :get) == 0
    assert GenServer.call(original_pid, :increment) == 1
    assert GenServer.call(original_pid, :increment) == 2
    assert GenServer.call(original_pid, :increment) == 3

    # Real, untrappable termination. `terminate/2` does NOT run on
    # `:kill`, so anything not already durably synced above would be
    # lost -- only the `sync: true` on each :increment call (see
    # RestartableDurableServerFixture) gives the post-restart read-back
    # below any real durability to actually recover.
    ref = Process.monitor(original_pid)
    Process.exit(original_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^original_pid, :killed}, 5_000
    refute Process.alive?(original_pid)

    # No hand-rolled restart call from this test. Only the real
    # DurableServer.LifecycleManager's own discovery-and-restart sweep
    # (tightened above to run fast) is permitted to bring the process
    # back. Poll the same real DurableServer.Supervisor.lookup/2 surface
    # AshA2A.Durability.DurableServer/RuntimeProvidersIntegrationTest
    # already use, for a genuinely different, genuinely live pid.
    restarted_pid =
      wait_until_restarted(
        sup,
        key,
        original_pid,
        System.monotonic_time(:millisecond) + 10_000
      )

    assert is_pid(restarted_pid)
    assert restarted_pid != original_pid
    assert Process.alive?(restarted_pid)

    # Real recovered state: the last durably-synced count (3), read back
    # by the real post-restart init/1 from the real EKV-backed storage --
    # not re-supplied by this test.
    assert GenServer.call(restarted_pid, :get) == 3
  end

  defp wait_until_restarted(sup, key, original_pid, deadline_ms) do
    case DurableServer.Supervisor.lookup(sup, key) do
      {pid, _meta} when is_pid(pid) and pid != original_pid ->
        pid

      _other ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk(
            "real DurableServer.LifecycleManager did not restart #{inspect(key)} under " <>
              "#{inspect(sup)} within the real polling deadline -- no genuinely new, live " <>
              "pid was observed via DurableServer.Supervisor.lookup/2"
          )
        else
          Process.sleep(50)
          wait_until_restarted(sup, key, original_pid, deadline_ms)
        end
    end
  end
end

# --- SECTION 13: Original test/ash_a2a/durable_server_test.exs ---
defmodule AshA2A.DurableServerTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Durability.DurableServer, Identity}

  test "A2A task identity is the stable durable runtime key" do
    task_id = Identity.task("task-42")
    assert DurableServer.key(task_id) == "task:task-42"
  end

  test "missing DurableServer provider returns typed unsupported without inventing durability" do
    unless DurableServer.available?() do
      assert {:error, {:unsupported, :durable_server, :lookup, 2}} =
               DurableServer.lookup(:missing_supervisor, Identity.task("task-42"))
    end
  end
end

# --- SECTION 14: Original test/ash_a2a/equilibrium_switchboard_test.exs ---
defmodule AshA2A.Equilibrium.SwitchboardTest do
  use ExUnit.Case, async: true
  alias AshA2A.Equilibrium.Switchboard, as: S
  alias S.{WorkOrder, Planner, Provider, Queue}

  defp w(extra \\ %{}),
    do:
      struct!(
        WorkOrder,
        Map.merge(
          %{
            id: "w",
            subject: "s",
            capability: :plan,
            role: :planner,
            policy: :bounded,
            authority: 0,
            epoch: 7,
            max_steps: 8
          },
          extra
        )
      )

  defp p(extra \\ %{}),
    do:
      struct!(
        Planner,
        Map.merge(
          %{
            id: :hddl,
            kind: :hddl,
            capabilities: [:plan],
            roles: [:planner],
            policies: [:bounded],
            authority_ceiling: 0,
            max_steps: 16,
            provider_ids: [:p1],
            priority: 1
          },
          extra
        )
      )

  defp v(extra \\ %{}),
    do:
      struct!(
        Provider,
        Map.merge(%{id: :p1, epoch: 7, capabilities: [:plan], alive: true}, extra)
      )

  defp ctx,
    do: %{
      subject: "s",
      epoch: 7,
      capabilities: [:plan],
      roles: [:planner],
      policies: [:bounded],
      authority_ceiling: 0
    }

  test "admission refuses identity, epoch and authority drift" do
    assert :ok = S.admit(w(), ctx())
    assert {:error, :subject_mismatch} = S.admit(w(%{subject: "x"}), ctx())
    assert {:error, :stale_epoch} = S.admit(w(%{epoch: 6}), ctx())
    assert {:error, :authority_increase} = S.admit(w(%{authority: 1}), ctx())
    assert {:error, :unbounded_plan} = S.admit(w(%{max_steps: 0}), ctx())
  end

  test "selection is deterministic, bounded and consequence-free" do
    assert {:ok, a} = S.select(w(), [p()], [v()])
    assert {:ok, b} = S.select(w(), [p()], [v()])
    assert a == b
    assert a.consequence == :none
    assert a.standing == :candidate
    assert {:error, :no_planner} = S.select(w(%{max_steps: 17}), [p()], [v()])
    assert {:error, :no_provider} = S.select(w(), [p()], [v(%{alive: false})])
  end

  test "queue refuses duplicates and stale completion then reclaims" do
    assert {:ok, q} = S.enqueue(%Queue{limit: 1}, w())
    assert {:error, :duplicate} = S.enqueue(q, w())
    assert {:ok, _, lease, q} = S.lease(q, :worker, 7, 1)
    assert {:error, :stale_lease} = S.complete(q, "w", "bad", 7)
    q = S.reclaim(q, 8)
    assert {:ok, _, lease2, q} = S.lease(q, :worker2, 8, 1)
    refute lease.token == lease2.token
    assert {:ok, _} = S.complete(q, "w", lease2.token, 8)
  end

  test "ontology participates in executable admission contract" do
    ttl = File.read!("priv/ontology/chatman_equilibrium_switchboard.ttl")
    assert :ok = S.validate_ontology(ttl)
    assert {:error, :ontology_contract_missing, missing} = S.validate_ontology("Planner Policy")
    assert :Standing in missing
  end
end

# --- SECTION 15: Original test/ash_a2a/execution_context_test.exs ---
defmodule AshA2A.ExecutionContextTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Direct coverage of the `AshA2A.ExecutionContext` struct itself. Every other
  test that touches this module builds one indirectly, via
  `AshA2A.ContextResolver.from_a2a_message/3`; none constructs and asserts on
  the struct's own real default values or field set.
  """

  test "struct defaults context to %{} and history to [], with actor/tenant/domain nil" do
    context = %AshA2A.ExecutionContext{}

    assert context.actor == nil
    assert context.tenant == nil
    assert context.domain == nil
    assert context.context == %{}
    assert context.history == []
  end

  test "struct holds real, independently-set field values" do
    message = %{role: :user}

    context = %AshA2A.ExecutionContext{
      actor: %{id: "user-1"},
      tenant: "tenant-a",
      domain: AshA2A.Test.Fixture.Domain,
      context: %{source: :test},
      history: [message]
    }

    assert context.actor == %{id: "user-1"}
    assert context.tenant == "tenant-a"
    assert context.domain == AshA2A.Test.Fixture.Domain
    assert context.context == %{source: :test}
    assert context.history == [message]
  end
end

# --- SECTION 16: Original test/ash_a2a/fibo_simulation_conformance_test.exs ---
defmodule AshA2A.FiboSimulationConformanceTest do
  use ExUnit.Case, async: true
  import RDF.Sigils

  @canonical_dir Path.expand("../../priv/sa2a/canonical", __DIR__)

  test "canonical FIBO-grade SA2A ontologies parse cleanly as valid Turtle" do
    files = [
      "MetadataSA2A.ttl",
      "AboutSA2AProd.ttl",
      "FND/Agents/Agents.ttl",
      "FND/Agreements/Leases.ttl",
      "FND/Law/OperatingDoctrine.ttl",
      "CAP/CoreCapabilities.ttl",
      "BP/ExecutionEnvelopes.ttl",
      "EVI/Receipts.ttl",
      "shapes/sa2a_core_shapes.shacl.ttl"
    ]

    for file <- files do
      path = Path.join(@canonical_dir, file)
      assert File.exists?(path), "Expected file #{path} to exist"

      content = File.read!(path)
      assert {:ok, graph} = RDF.Turtle.read_string(content)
      assert RDF.Graph.triple_count(graph) > 0, "Graph in #{file} must not be empty"
    end
  end

  test "AboutSA2AProd references all canonical module IRIs via owl:imports" do
    prod_path = Path.join(@canonical_dir, "AboutSA2AProd.ttl")
    {:ok, graph} = RDF.Turtle.read_file(prod_path)

    owl_imports = ~I<http://www.w3.org/2002/07/owl#imports>

    imported_iris =
      RDF.Graph.descriptions(graph)
      |> Enum.flat_map(fn desc -> RDF.Description.get(desc, owl_imports, []) end)
      |> Enum.map(&to_string/1)

    expected = [
      "https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Agents/Agents/",
      "https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Agreements/Leases/",
      "https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/",
      "https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/",
      "https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/",
      "https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/"
    ]

    for expected_iri <- expected do
      assert expected_iri in imported_iris,
             "Expected #{expected_iri} in owl:imports of AboutSA2AProd.ttl"
    end
  end

  test "OperatingDoctrine enforces fundamental explanation laws" do
    doc_path = Path.join(@canonical_dir, "FND/Law/OperatingDoctrine.ttl")
    {:ok, graph} = RDF.Turtle.read_file(doc_path)

    expected_laws = [
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/SelectNotConstruct>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/ConstructNotDo>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/IntentNotAuthority>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/ReceiptNotSuccess>
    ]

    law_class =
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/DoctrineLaw>

    rdf_type = RDF.type()

    for law <- expected_laws do
      assert RDF.Graph.include?(graph, {law, rdf_type, law_class})
    end
  end

  test "live AshA2A.Command and Receipt structs align with canonical SHACL shape contracts" do
    alias AshA2A.{Command, Receipt}

    # 1. Instantiate real runtime command
    cmd =
      Command.new("test:capability:001",
        agent_id: "agent:worker:1",
        principal_id: "principal:admin:1",
        input: %{"target" => "system_update"}
      )

    assert is_binary(cmd.capability_id)
    assert is_binary(cmd.principal_id.value)
    assert is_binary(cmd.fingerprint)

    # 2. Project to canonical RDF Triples matching sa2a-bp:CommandEnvelope
    cmd_subject = RDF.iri("urn:uuid:#{cmd.command_id.value}")

    cmd_envelope_class =
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/CommandEnvelope>

    p_capability_id =
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/capabilityId>

    p_principal_id =
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/principalId>

    p_payload_digest =
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/payloadDigest>

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add({cmd_subject, RDF.type(), cmd_envelope_class})
      |> RDF.Graph.add({cmd_subject, p_capability_id, RDF.literal(cmd.capability_id)})
      |> RDF.Graph.add({cmd_subject, p_principal_id, RDF.literal(cmd.principal_id.value)})
      |> RDF.Graph.add({cmd_subject, p_payload_digest, RDF.literal(cmd.fingerprint)})

    assert RDF.Graph.include?(graph, {cmd_subject, RDF.type(), cmd_envelope_class})

    assert RDF.Graph.include?(
             graph,
             {cmd_subject, p_capability_id, RDF.literal("test:capability:001")}
           )

    # 3. Instantiate real runtime receipt and project to sa2a-evi:ActuationReceipt
    authority =
      AshA2A.Authority.new(cmd.principal_id, cmd.capability_id, source: :transport_verified)

    cmd_with_auth = %{cmd | authority: authority}
    exec_id = AshA2A.Identity.execution("exec:001")

    receipt =
      Receipt.from_reply(
        cmd_with_auth,
        exec_id,
        :observe,
        {:reply, :ok}
      )

    assert receipt.receipt_id != nil
    assert receipt.fingerprint != nil
    assert receipt.status == :completed
    assert receipt.terminal_status == :executed
    assert receipt.standing == :observed
  end

  test "monolithic canonical AllSA2A.ttl contains the entire consolidated ontology suite" do
    all_path = Path.join(@canonical_dir, "AllSA2A.ttl")
    assert File.exists?(all_path)

    {:ok, graph} = RDF.Turtle.read_file(all_path)
    assert RDF.Graph.triple_count(graph) >= 50

    # 1. Check classes from all domains
    rdf_type = RDF.type()
    owl_class = ~I<http://www.w3.org/2002/07/owl#Class>
    sh_nodeshape = ~I<http://www.w3.org/ns/shacl#NodeShape>

    expected_classes = [
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Agents/Agents/AutonomousAgent>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Agreements/Leases/AuthorityCeiling>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Agreements/Leases/ActuationLease>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/DoctrineLaw>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/Capability>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/CommandEnvelope>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/ActuationReceipt>
    ]

    for cls <- expected_classes do
      assert RDF.Graph.include?(graph, {cls, rdf_type, owl_class})
    end

    # 2. Check SHACL shapes
    expected_shapes = [
      ~I<https://spec.seanchatmangpt.dev/sa2a/shapes/core#CommandEnvelopeShape>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/shapes/core#ActuationReceiptShape>
    ]

    for shape <- expected_shapes do
      assert RDF.Graph.include?(graph, {shape, rdf_type, sh_nodeshape})
    end

    # 3. Check OWL equivalence axioms
    owl_equivalent_class = ~I<http://www.w3.org/2002/07/owl#equivalentClass>
    a2a_urn_cmd = ~I<urn:ash-a2a:vocab:Command>

    sa2a_bp_cmd =
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/CommandEnvelope>

    assert RDF.Graph.include?(graph, {a2a_urn_cmd, owl_equivalent_class, sa2a_bp_cmd})
  end
end

# --- SECTION 17: Original test/ash_a2a/flame_placement_test.exs ---
defmodule AshA2A.FlamePlacementTest do
  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Command, Execution.FLAME, Identity, Receipt, ReceiptStore, RuntimeReceipt}
  alias AshA2A.Test.Fixture.Echo

  test "missing FLAME provider fails closed without bypassing CommandBus" do
    unless FLAME.available?() do
      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "flame-read-1",
          agent_id: "agent-1",
          principal_id: "anonymous"
        )

      message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

      assert {:error, {:unsupported, :flame}} =
               FLAME.run(:ash_a2a_pool, command, message, Echo)
    end
  end

  test "FLAME available: real local FLAME.Pool runner routes through CommandBus and receipts a real completed execution" do
    # This is the real happy-path counterpart to the test above. In this
    # environment FLAME.available?() is true (Code.ensure_loaded?(FLAME) and
    # function_exported?(FLAME, :call, 3) both hold), so the "unless
    # available?" branch above never executes its body here -- that test only
    # ever proves the fail-closed branch in THIS environment. This test
    # proves the other branch for real: a genuine FLAME.Pool (FLAME's own
    # documented FLAME.LocalBackend -- "A FLAME.Backend useful for
    # development and testing", deps/flame/lib/flame/local_backend.ex),
    # actually placing and running the closure that calls
    # AshA2A.CommandBus.run/4, with a real receipted reply asserted on the
    # real returned value -- no mocking of FLAME, CommandBus, or the
    # dispatcher.
    assert FLAME.available?()

    pool_name = Module.concat(__MODULE__, "Pool#{System.unique_integer([:positive])}")
    store_name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")

    # NB: `Elixir.FLAME.Pool`, not the bare `FLAME.Pool` -- this module's
    # `alias AshA2A.{..., Execution.FLAME, ...}` above binds the local name
    # `FLAME` to `AshA2A.Execution.FLAME`, so an unqualified `FLAME.Pool`
    # here would resolve to the nonexistent `AshA2A.Execution.FLAME.Pool`
    # instead of the real top-level `FLAME.Pool` GenServer this test needs
    # to start.
    start_supervised!({Elixir.FLAME.Pool, name: pool_name, min: 1, max: 1, max_concurrency: 5})
    start_supervised!({ReceiptStore.Memory, name: store_name})

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "flame-happy-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    message = data_message(%{})

    assert {:ok,
            %{
              receipt: %Receipt{} = receipt,
              placement: %RuntimeReceipt{} = placement
            }} =
             FLAME.run(pool_name, command, message, Echo,
               command_bus_opts: [store_opts: [name: store_name]]
             )

    # `receipt` is the real AshA2A.Receipt committed by AshA2A.CommandBus.run/4
    # inside the FLAME-placed closure -- a real completed execution, not a
    # placeholder or an echo of the input.
    assert receipt.command_id == command.command_id
    assert receipt.capability_id == "AshA2A.Test.Fixture.Echo.read"
    assert receipt.consequence == :observe
    assert receipt.status == :completed
    assert receipt.standing == :observed
    refute receipt.replayed?
    assert {:reply, _reply_payload} = receipt.reply

    # The same command_id, replayed a second time through the same store,
    # returns the identical committed receipt -- proving the first call
    # really executed and committed (a placeholder reply would not be
    # replayable in this way).
    assert {:ok, %{receipt: replay_receipt}} =
             FLAME.run(pool_name, command, message, Echo,
               command_bus_opts: [store_opts: [name: store_name]]
             )

    assert replay_receipt.replayed?
    assert replay_receipt.receipt_id == receipt.receipt_id

    # `placement` is the real AshA2A.RuntimeReceipt recorded by
    # AshA2A.Execution.FLAME.run/5 around the FLAME.call/3 placement itself
    # -- observed provider standing for the placement, distinct from (and
    # never conferring) the CommandBus execution receipt above.
    assert placement.provider == :flame
    assert placement.operation == :call
    assert placement.status == :completed
    assert placement.subject == Identity.external(command.command_id)
    assert placement.standing == :observed
    assert {:ok, %Receipt{}} = placement.result
  end
end

# --- SECTION 18: Original test/ash_a2a/flame_real_placement_test.exs ---
defmodule AshA2A.FlameRealPlacementTest do
  @moduledoc """
  Proves `AshA2A.Execution.FLAME.run/5` genuinely dispatches a real
  `AshA2A.CommandBus.run/4` call onto a real FLAME-placed process, closing
  the gap a prior audit found: `test/ash_a2a/flame_placement_test.exs` and
  `test/ash_a2a_runtime_providers_integration_test.exs` both only assert
  `FLAME.available?()`, and since the real `:flame` dependency is present
  `available?/0` is always `true` in this environment -- so the
  real-provider-guarded body of `FLAME.run/5` (the `if available?() do ...`
  branch) never actually executed in any prior test run in this repo.

  This test starts a real `FLAME.Pool` backed by `FLAME.LocalBackend` --
  the backend the `:flame` dependency itself ships and documents for this
  exact purpose:

      > By default, the `FLAME.LocalBackend` is used, which is great for
      > development and test environments, as you can have your code simply
      > execute locally in most cases and worry about scaling the operation
      > only in production.
      (deps/flame/lib/flame.ex, "Backends" section of the module doc)

  `FLAME.LocalBackend.remote_spawn_monitor/2`
  (deps/flame/lib/flame/local_backend.ex) implements FLAME's remote
  placement contract with a real `spawn_monitor/1` on this same BEAM node
  instead of a cloud machine -- no cloud credentials, no mocked backend, no
  substitute `FLAME.Backend` implementation written for this test. FLAME's
  own `FLAME.Runner.remote_call/5` (deps/flame/lib/flame/runner.ex) confirms
  the wrapped closure runs inside that spawned process ("# This runs on the
  remote node"), so the second test below captures the real executing pid
  via a synchronous `:telemetry` handler (telemetry handlers run in the
  caller's process, not a separate one) to prove the dispatch genuinely
  happened on a process distinct from the test process -- not merely that
  `CommandBus.run/4` was called inline.

  No `:flame, :backend` application config exists anywhere in this repo
  (`config/`), so `FLAME.Pool` would default to `FLAME.LocalBackend` even
  without the explicit `backend:` option below; it is passed explicitly here
  only so this test is not silently affected by a future default change.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Execution.FLAME, as: Placement
  alias AshA2A.{Command, Receipt, ReceiptStore, RuntimeReceipt}
  alias AshA2A.Test.Fixture.Echo

  setup do
    store_name = :"flame_real_placement_store_#{System.unique_integer([:positive])}"
    start_supervised!({ReceiptStore.Memory, name: store_name})

    pool_name = :"flame_real_placement_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {FLAME.Pool,
       name: pool_name,
       min: 0,
       max: 1,
       max_concurrency: 5,
       backend: FLAME.LocalBackend,
       timeout: 5_000,
       boot_timeout: 5_000,
       idle_shutdown_after: 5_000}
    )

    %{pool: pool_name, store_opts: [name: store_name]}
  end

  test "run/5 dispatches through a real local-backend FLAME pool and returns real receipts", %{
    pool: pool,
    store_opts: store_opts
  } do
    assert Placement.available?()

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "flame-real-read-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    message = data_message(%{})

    assert {:ok, %{receipt: receipt, placement: placement}} =
             Placement.run(pool, command, message, Echo,
               command_bus_opts: [store_opts: store_opts]
             )

    # The real AshA2A.CommandBus.run/4 outcome, produced on the FLAME-placed
    # process and returned back through FLAME.call/3 to this test process.
    assert %Receipt{status: :completed, consequence: :observe} = receipt
    refute receipt.replayed?

    # The real FLAME placement evidence AshA2A.Execution.FLAME.run/5 records
    # alongside the command receipt -- observed provider standing only.
    assert %RuntimeReceipt{provider: :flame, operation: :call, status: :completed} = placement
    assert placement.standing == :observed

    # Same command id replayed through the same real pool: the claim store
    # (not FLAME) is what makes this idempotent, proving FLAME placement
    # never bypasses CommandBus's own replay semantics.
    assert {:ok, %{receipt: replay_receipt}} =
             Placement.run(pool, command, message, Echo,
               command_bus_opts: [store_opts: store_opts]
             )

    assert replay_receipt.replayed?
    assert replay_receipt.receipt_id == receipt.receipt_id
  end

  test "the dispatched command genuinely executes on a distinct real FLAME-placed process", %{
    pool: pool,
    store_opts: store_opts
  } do
    test_pid = self()
    handler_id = "flame-real-placement-#{System.unique_integer([:positive])}"

    # :telemetry.execute/3 runs attached handlers synchronously in the
    # process that called it (AshA2A.CommandBus.emit_receipt/1, called from
    # inside AshA2A.CommandBus.run/4) -- so capturing self() inside this
    # handler captures the real pid CommandBus.run/4 actually executed in,
    # with no mock standing in for FLAME's own placement.
    :telemetry.attach(
      handler_id,
      [:ash_a2a, :receipt, :committed],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, {:executed_on, self()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "flame-real-read-2",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    message = data_message(%{})

    assert {:ok, %{receipt: %Receipt{status: :completed}}} =
             Placement.run(pool, command, message, Echo,
               command_bus_opts: [store_opts: store_opts]
             )

    assert_receive {:executed_on, executor_pid}, 1_000
    assert is_pid(executor_pid)
    refute executor_pid == test_pid
  end
end

# --- SECTION 19: Original test/ash_a2a/graph_law_wasm_test.exs ---
defmodule AshA2A.GraphLawWasmEngineTest do
  @moduledoc """
  Real invocation of the real `praxis-graphlaw` WebAssembly module through
  `AshA2A.GraphLaw.Wasm`.

  Every value asserted here came out of the real wasm's linear memory via a real
  `node` subprocess. Nothing is stubbed. When the artifact is absent the module
  is a named, visible skip carrying the real reason.
  """

  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.Wasm

  case AshA2A.GraphLaw.Wasm.availability() do
    :ok ->
      @moduletag :graphlaw

    {:error, detail} ->
      @moduletag skip:
                   "real GraphLaw wasm unavailable (#{inspect(detail)}) -- " <>
                     "these cases run the real engine and are never mocked"
  end

  @base """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:c .
  """

  @relabelled_reordered """
  @prefix zz: <http://example.org/> .
  zz:b zz:p zz:c .
  zz:a zz:p zz:b .
  """

  @different """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:zzz .
  """

  test "version/1 returns the real engine's own version string" do
    assert {:ok, version} = Wasm.version()
    assert version =~ "praxis-graphlaw"
  end

  test "blake3_hex/2 matches the published BLAKE3 test vector for \"abc\"" do
    assert {:ok, "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"} =
             Wasm.blake3_hex("abc")
  end

  test "graph_hash/2 is canonical: prefix labels and triple order do not change it" do
    assert {:ok, base} = Wasm.graph_hash(@base)
    assert {:ok, same} = Wasm.graph_hash(@relabelled_reordered)
    assert {:ok, other} = Wasm.graph_hash(@different)

    assert base == same
    refute base == other
    assert base =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "batch/2 runs several real calls in one real wasm instantiation, in order" do
    assert {:ok, [version, hash_a, hash_b]} =
             Wasm.batch([
               {:graphlaw_version, []},
               {:graph_hash, [@base]},
               {:graph_hash, [@different]}
             ])

    assert version =~ "praxis-graphlaw"
    refute hash_a == hash_b
  end

  test "validate_all/6 reports a real SHACL violation and a real conformance" do
    shapes = """
    @prefix sh: <http://www.w3.org/ns/shacl#> .
    @prefix ex: <http://example.org/> .
    ex:Shape a sh:NodeShape ;
      sh:targetClass ex:Thing ;
      sh:property [ sh:path ex:name ; sh:minCount 1 ] .
    """

    conforming = """
    @prefix ex: <http://example.org/> .
    ex:t a ex:Thing ; ex:name "n" .
    """

    violating = """
    @prefix ex: <http://example.org/> .
    ex:t a ex:Thing .
    """

    assert {:ok, ok_report} = Wasm.validate_all(conforming, "", shapes, "", "")
    assert {:ok, %{"status" => "ADMITTED"}} = Wasm.dialect(ok_report, "SHACL")

    assert {:ok, bad_report} = Wasm.validate_all(violating, "", shapes, "", "")

    assert {:ok, %{"status" => "REFUSED", "triples_out" => count}} =
             Wasm.dialect(bad_report, "SHACL")

    assert count >= 1
  end

  test "an absent dialect is an error, never a silent pass" do
    assert {:ok, report} = Wasm.validate_all(@base, "", "", "", "")
    assert {:error, %{code: :graphlaw_dialect_missing}} = Wasm.dialect(report, "NO_SUCH_DIALECT")
  end

  test "missing shapes come back UNSUPPORTED -- the engine's own 'nothing was checked'" do
    assert {:ok, report} = Wasm.validate_all(@base, "", "", "", "")
    assert {:ok, %{"status" => "UNSUPPORTED"}} = Wasm.dialect(report, "SHACL")
    assert {:ok, %{"status" => "PROFILE_NOT_ADMITTED"}} = Wasm.dialect(report, "OWL_RL")
  end

  test "run_hooks/3 returns the engine's real hook admission verdict" do
    event = """
    @prefix ex: <http://example.org/> .
    ex:ev a ex:Event .
    """

    assert {:ok, %{"status" => "ADMITTED"} = decoded} = Wasm.run_hooks(@base, event)
    assert Map.has_key?(decoded, "verdicts")
    assert Map.has_key?(decoded, "receipts")
  end

  test "the engine's replay block agrees with itself on a real graph" do
    assert {:ok, report} = Wasm.validate_all(@base, "", "", "", "")

    assert %{
             "replay" => %{"status" => "ADMITTED", "first_hash" => first, "second_hash" => second}
           } =
             report

    assert first == second
  end

  test "malformed input still yields a hash -- the measured leniency the pipeline guards against" do
    # This is a real falsifier for the naive reading "a hash means it parsed".
    assert {:ok, hash} = Wasm.graph_hash("this is not turtle at all <<< @@@ ;;;")
    assert hash =~ ~r/\A[0-9a-f]{64}\z/

    # The engine-native witness that actually distinguishes them: under the
    # universal denial rule, a real graph has denial violations and garbage
    # does not.
    witness = "\n{ ?s ?p ?o } => false .\n"

    assert {:ok, real_report} = Wasm.validate_all(@base <> witness, "", "", "", "")
    assert {:ok, %{"status" => "REFUSED"}} = Wasm.dialect(real_report, "N3_DENIAL")

    assert {:ok, junk_report} =
             Wasm.validate_all("this is not turtle at all <<<" <> witness, "", "", "", "")

    assert {:ok, %{"status" => "ADMITTED"}} = Wasm.dialect(junk_report, "N3_DENIAL")
  end
end

defmodule AshA2A.GraphLawWasmTest do
  @moduledoc """
  Engine-independent behaviour of `AshA2A.GraphLaw.Wasm`: path resolution and
  the typed errors it produces when the real engine is not reachable.
  """

  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.Wasm

  test "wasm_path/1 prefers an explicit option" do
    assert Wasm.wasm_path(wasm_path: "/custom/graphlaw.wasm") == "/custom/graphlaw.wasm"
  end

  test "availability/1 names a missing artifact instead of failing silently" do
    assert {:error, %{code: :graphlaw_wasm_not_found, path: "/nonexistent/graphlaw.wasm"}} =
             Wasm.availability(wasm_path: "/nonexistent/graphlaw.wasm")

    refute Wasm.available?(wasm_path: "/nonexistent/graphlaw.wasm")
  end

  test "batch/2 refuses rather than raising when the artifact is absent" do
    assert {:error, %{code: :graphlaw_wasm_not_found}} =
             Wasm.batch([{:graphlaw_version, []}], wasm_path: "/nonexistent/graphlaw.wasm")
  end

  test "decode_json/1 maps the engine's own error convention onto a typed error" do
    assert {:error, %{code: :graphlaw_engine_error, message: "boom"}} =
             Wasm.decode_json(~s({"error":"boom"}))

    assert {:error, %{code: :graphlaw_non_json_result}} = Wasm.decode_json("not json")
    assert {:ok, %{"a" => 1}} = Wasm.decode_json(~s({"a":1}))
  end

  test "dialect/2 refuses a malformed report" do
    assert {:error, %{code: :graphlaw_report_malformed}} = Wasm.dialect(%{}, "SHACL")
  end
end

# --- SECTION 20: Original test/ash_a2a/graph_law_wasmex_host_test.exs ---
defmodule AshA2A.GraphLawWasmexHostTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.GraphLaw.WasmexHost`.

  Every assertion below is state-based against the REAL vendored
  `praxis-graphlaw` WebAssembly artifact, executed by the REAL Wasmtime
  runtime through `wasmex`. No collaborator is mocked, stubbed, or faked:
  the wasm bytes are read from real disk, the instance is a real supervised
  GenServer holding a real Wasmtime store, and every digest asserted here
  was produced by real linear-memory marshaling into the real engine.

  ## Why the hard-coded digests are the strongest assertion available

  The digest constants asserted here were measured independently, under a
  DIFFERENT host runtime (V8 under Node, instantiating the same wasm bytes
  with a hand-written import shim), before this Elixir host existed. They
  are therefore not "whatever this implementation happens to produce" --
  they are a cross-runtime oracle. If this host's ABI marshaling were
  wrong, these tests fail.

  That is exactly the shape of the "SA2A Portable Semantic Execution
  Conformance" claim (`Runtime_A != Runtime_B`, `WASM_A = WASM_B`,
  `O*_input,A = O*_input,B` => same outputs), reduced to the two runtimes
  and handful of inputs actually measured so far. These tests are one
  bench in that court. They do NOT establish universal semantic
  equivalence, production ALIVE, or cross-implementation equivalence.

  `blake3_hex("abc")` additionally matches the PUBLISHED BLAKE3 test vector
  for `"abc"`, which is an external oracle independent of both runtimes.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.GraphLaw.WasmexHost

  # --- Measured constants (see moduledoc) ------------------------------
  @base_ttl "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:c .\n"

  # Same graph, DIFFERENT prefix label AND DIFFERENT triple order.
  @reordered_ttl "@prefix zz: <http://example.org/> .\nzz:b zz:p zz:c .\nzz:a zz:p zz:b .\n"

  # One triple's object changed.
  @changed_ttl "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:ZZZ .\n"

  @base_digest "9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d"
  @changed_digest "610ccbcd4ed4b23cf4179fde360625da286557d18a15403f76797e28c1c68f66"
  @blake3_abc "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
  # Published BLAKE3 digest of the empty input.
  @blake3_empty "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"

  @event_ttl "@prefix ex: <http://example.org/> .\nex:c ex:p ex:d .\n"

  @shacl_shapes """
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  @prefix ex: <http://example.org/> .
  ex:PShape a sh:NodeShape ;
    sh:targetSubjectsOf ex:p ;
    sh:property [ sh:path ex:p ; sh:minCount 1 ] .
  """

  setup_all do
    # A real, independently-named instance so these tests never depend on
    # (or disturb) the application-supervised singleton.
    {:ok, pid} = start_supervised({WasmexHost, name: :graphlaw_wasm_test})
    %{engine: pid}
  end

  describe "artifact vendoring" do
    test "the real .wasm artifact is present in priv and non-trivially sized" do
      path = WasmexHost.wasm_path()
      assert File.exists?(path), "vendored artifact missing at #{path}"
      assert %File.Stat{size: size} = File.stat!(path)
      assert size > 1_000_000, "artifact is #{size} bytes, far too small to be the law package"
    end

    test "WASMEX_HOST_MANIFEST.json records the artifact's REAL on-disk digests" do
      assert {:ok, manifest} = WasmexHost.manifest()

      real_bytes = File.read!(WasmexHost.wasm_path())
      real_sha256 = real_bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      assert manifest["sha256"] == real_sha256,
             "WASMEX_HOST_MANIFEST.json sha256 does not match the bytes actually on disk"

      assert manifest["size_bytes"] == byte_size(real_bytes)
    end

    test "WASMEX_HOST_MANIFEST.json's recorded blake3 is re-derivable by a real external BLAKE3 tool" do
      # The manifest's sha256 is already re-derived from the real bytes by
      # the test above using :crypto. BLAKE3 has no OTP implementation, so
      # this re-derives that field with the real external tool instead of
      # trusting the recorded value. Degrades to a NAMED, VISIBLE skip on a
      # machine without b3sum -- never to a silent pass.
      assert {:ok, manifest} = WasmexHost.manifest()
      assert manifest["blake3"] =~ ~r/\A[0-9a-f]{64}\z/

      case System.find_executable("b3sum") do
        nil ->
          IO.puts(
            "\n[SKIPPED ASSERTION] b3sum not on PATH; WASMEX_HOST_MANIFEST.json blake3 " <>
              "re-derivation not performed on this machine."
          )

        b3sum ->
          {out, 0} = System.cmd(b3sum, [WasmexHost.wasm_path()])
          [measured | _] = String.split(out, ~r/\s+/, trim: true)
          assert measured == manifest["blake3"]
      end
    end

    test "WASMEX_HOST_MANIFEST.json's recorded engine version is what the REAL engine reports" do
      assert {:ok, manifest} = WasmexHost.manifest()
      assert {:ok, reported} = WasmexHost.version(:graphlaw_wasm_test)
      assert manifest["engine_version_reported"] == reported
    end

    test "the engine's BLAKE3 agrees with the same external tool on real file bytes" do
      # Cross-implementation check of the engine's own BLAKE3 against b3sum
      # (a different BLAKE3 implementation entirely), over a real file on
      # real disk -- this is what makes `blake3_hex/3` usable as the single
      # receipt hash algorithm. UTF-8 content, because `blake3_hex` takes a
      # `&str`, not arbitrary bytes.
      case System.find_executable("b3sum") do
        nil ->
          IO.puts("\n[SKIPPED ASSERTION] b3sum not on PATH; engine-vs-b3sum cross-check skipped.")

        b3sum ->
          path =
            Path.join(
              System.tmp_dir!(),
              "graphlaw_blake3_xcheck_#{System.unique_integer([:positive])}.txt"
            )

          content = "SA2A conformance probe\n日本語\n" <> String.duplicate("x", 5000)
          File.write!(path, content)

          try do
            {out, 0} = System.cmd(b3sum, [path])
            [external | _] = String.split(out, ~r/\s+/, trim: true)
            assert {:ok, ^external} = WasmexHost.blake3_hex(content, :graphlaw_wasm_test)
          after
            File.rm(path)
          end
      end
    end
  end

  describe "version/1" do
    test "returns the engine's REAL self-reported version", %{engine: _} do
      assert {:ok, version} = WasmexHost.version(:graphlaw_wasm_test)
      assert version == "praxis-graphlaw v26.7.5"
    end
  end

  describe "graph_hash/3 -- RFC S12 canonical graph identity" do
    test "produces the digest measured independently under a different host runtime" do
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
    end

    test "is INVARIANT under prefix relabelling and triple reordering" do
      assert {:ok, base} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
      assert {:ok, reordered} = WasmexHost.graph_hash(@reordered_ttl, :graphlaw_wasm_test)

      assert base == reordered,
             "canonicalization failed: same graph, different serialization, different digest"

      assert reordered == @base_digest
    end

    test "DISTINGUISHES a graph whose content actually changed" do
      assert {:ok, changed} = WasmexHost.graph_hash(@changed_ttl, :graphlaw_wasm_test)
      assert changed == @changed_digest
      refute changed == @base_digest
    end

    test "is stable across repeated real calls on one reused instance" do
      digests =
        for _ <- 1..10 do
          {:ok, d} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
          d
        end

      assert Enum.uniq(digests) == [@base_digest]
    end

    test "round-trips non-ASCII literals through linear memory correctly" do
      unicode = "@prefix ex: <http://example.org/> .\nex:a ex:p \"日本語 ünïcode\" .\n"
      assert {:ok, digest} = WasmexHost.graph_hash(unicode, :graphlaw_wasm_test)
      assert digest =~ ~r/\A[0-9a-f]{64}\z/

      # Same bytes in, same digest out -- proves the UTF-8 length accounting
      # in the ABI marshaling (byte_size, not String.length) is right.
      assert {:ok, ^digest} = WasmexHost.graph_hash(unicode, :graphlaw_wasm_test)
      refute digest == @base_digest
    end
  end

  describe "blake3_hex/3" do
    test "matches the PUBLISHED BLAKE3 test vector for \"abc\"" do
      assert {:ok, @blake3_abc} = WasmexHost.blake3_hex("abc", :graphlaw_wasm_test)
    end

    test "matches the published BLAKE3 digest of the empty input" do
      assert {:ok, @blake3_empty} = WasmexHost.blake3_hex("", :graphlaw_wasm_test)
    end
  end

  describe "run_hooks/4" do
    test "returns a real decoded verdict map" do
      assert {:ok, result} = WasmexHost.run_hooks(@base_ttl, @event_ttl, :graphlaw_wasm_test)
      assert result["status"] == "ADMITTED"
      assert result["verdicts"] == []
      assert result["receipts"] == []
      assert result["schedule"] == []
    end
  end

  describe "validate_all/7" do
    test "runs every dialect and reports per-dialect status plus the graph hash" do
      assert {:ok, result} =
               WasmexHost.validate_all(@base_ttl, "", "", "", "", :graphlaw_wasm_test)

      assert result["graph_hash"] == @base_digest

      statuses =
        Map.new(result["dialects"], fn d -> {d["dialect"], d["status"]} end)

      assert statuses["DATALOG"] == "ADMITTED"
      assert statuses["N3_DENIAL"] == "ADMITTED"
      assert statuses["SHACL"] == "UNSUPPORTED"
      assert statuses["SHEX"] == "UNSUPPORTED"
      assert statuses["OWL_RL"] == "PROFILE_NOT_ADMITTED"

      # The engine's own self-replay check: hashing the same graph twice
      # inside one call must agree.
      assert result["replay"]["status"] == "ADMITTED"
      assert result["replay"]["first_hash"] == result["replay"]["second_hash"]
      assert result["hash_algorithms"] == %{"BLAKE3" => "1.0"}
    end

    test "ADMITS a graph that satisfies real SHACL shapes" do
      assert {:ok, result} =
               WasmexHost.validate_all(@base_ttl, "", @shacl_shapes, "", "", :graphlaw_wasm_test)

      shacl = Enum.find(result["dialects"], &(&1["dialect"] == "SHACL"))
      assert shacl["status"] == "ADMITTED"
      assert shacl["detail"] =~ "0 violations"
    end

    test "REFUSES an unparseable SHACL shapes graph, with a real parser diagnostic" do
      assert {:ok, result} =
               WasmexHost.validate_all(
                 @base_ttl,
                 "",
                 "!!!not shacl!!!",
                 "",
                 "",
                 :graphlaw_wasm_test
               )

      shacl = Enum.find(result["dialects"], &(&1["dialect"] == "SHACL"))

      # {:ok, _} means "the engine ran", not "everything validated" -- the
      # refusal is a per-dialect verdict INSIDE the result, by design.
      assert shacl["status"] == "REFUSED"
      assert shacl["detail"] =~ "Parsing error"

      # Other dialects are unaffected by one dialect's refusal.
      assert result["graph_hash"] == @base_digest
    end
  end

  describe "malformed input does not crash or poison the instance" do
    test "graph_hash/3 on garbage Turtle returns a value, and the instance still works" do
      # MEASURED REALITY, not an assumption: `graph_hash` is LENIENT.
      # `praxis-graphlaw-wasm/src/core.rs`'s `graph_hash_core_impl/1` has no
      # fallible parse step -- its only Err is an engine panic caught by its
      # own `catch_unwind`. So malformed Turtle silently degrades to the
      # subset that parsed (possibly the empty graph) rather than erroring.
      # This test asserts the behavior that actually exists; it does not
      # pretend an error path fires here.
      assert {:ok, garbage_digest} =
               WasmexHost.graph_hash("this is not turtle @@@ <<<", :graphlaw_wasm_test)

      assert garbage_digest =~ ~r/\A[0-9a-f]{64}\z/

      # A truncated statement drops to the EMPTY graph, whose canonical
      # digest is BLAKE3's published empty-input vector.
      assert {:ok, @blake3_empty} =
               WasmexHost.graph_hash("@prefix ex: <http://e/> .\nex:a ex:p", :graphlaw_wasm_test)

      # The instance is NOT poisoned: the same engine still produces the
      # exact cross-runtime digest afterwards.
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
      assert {:ok, "praxis-graphlaw v26.7.5"} = WasmexHost.version(:graphlaw_wasm_test)
    end

    test "run_hooks/4 survives garbage on both inputs and the instance stays usable" do
      assert {:ok, result} = WasmexHost.run_hooks("!!!", "!!!", :graphlaw_wasm_test)
      assert is_map(result)
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
    end

    test "a long sequence of mixed good/bad inputs leaves the instance correct" do
      inputs = [
        @base_ttl,
        "!!!!",
        @changed_ttl,
        "",
        @reordered_ttl,
        "<not a valid iri> <p> <o> .",
        @base_ttl
      ]

      results =
        Enum.map(inputs, fn ttl ->
          assert {:ok, digest} = WasmexHost.graph_hash(ttl, :graphlaw_wasm_test)
          digest
        end)

      assert List.first(results) == @base_digest
      assert List.last(results) == @base_digest
      assert Enum.at(results, 2) == @changed_digest
      assert Enum.at(results, 4) == @base_digest
    end
  end

  describe "concurrency -- one shared instance, many real BEAM processes" do
    test "concurrent callers each get the correct digest (serialized transactions)" do
      # If the multi-step wasm-bindgen ABI transaction were NOT serialized,
      # concurrent callers would interleave shadow-stack claims and read
      # each other's return slots. This asserts real state (every digest
      # correct), not "was a lock taken".
      cases = [
        {@base_ttl, @base_digest},
        {@reordered_ttl, @base_digest},
        {@changed_ttl, @changed_digest}
      ]

      results =
        1..40
        |> Task.async_stream(
          fn i ->
            {ttl, expected} = Enum.at(cases, rem(i, 3))
            {:ok, digest} = WasmexHost.graph_hash(ttl, :graphlaw_wasm_test)
            digest == expected
          end,
          max_concurrency: 20,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, ok?} -> ok? end)

      assert length(results) == 40
      assert Enum.all?(results), "concurrent ABI transactions corrupted each other"
    end
  end

  describe "encoding guard -- non-UTF-8 input never reaches the engine" do
    # CONFIRMED DEFECT, real repro (this session, before this fix):
    # `WasmexHost.graph_hash(<<0xFF>>)` committed 2,148,270,080 bytes of the
    # engine's linear memory in ONE call and PERMANENTLY POISONED the
    # instance -- a second call on the poisoned instance committed a
    # further 1,073,807,360 bytes. `ensure_utf8/1` must stop every public
    # function below before any wasm transaction, so memory must not grow
    # at all across these calls, and the instance must keep serving real
    # requests afterward.
    @invalid <<0xFF>>

    test "ensure_utf8/1 itself: valid input is :ok, invalid names the real first offset" do
      assert WasmexHost.ensure_utf8("ok") == :ok
      assert WasmexHost.ensure_utf8(@base_ttl) == :ok
      assert WasmexHost.ensure_utf8(@invalid) == {:error, {:invalid_encoding, 0}}
      assert WasmexHost.ensure_utf8(<<"ok", 0xFF>>) == {:error, {:invalid_encoding, 2}}
    end

    test "graph_hash/3 rejects non-UTF-8 input without committing any engine memory" do
      assert {:ok, before} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.graph_hash(@invalid, :graphlaw_wasm_test)

      assert {:ok, after_bytes} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert after_bytes == before,
             "engine memory grew from #{before} to #{after_bytes} bytes -- " <>
               "the guard let a non-UTF-8 call reach the wasm instance"

      # The instance is not poisoned: it still serves the real, previously
      # measured cross-runtime digest.
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
    end

    test "blake3_hex/3 rejects non-UTF-8 input without committing any engine memory" do
      assert {:ok, before} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.blake3_hex(@invalid, :graphlaw_wasm_test)

      assert {:ok, after_bytes} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert after_bytes == before,
             "engine memory grew from #{before} to #{after_bytes} bytes -- " <>
               "the guard let a non-UTF-8 call reach the wasm instance"

      assert {:ok, @blake3_abc} = WasmexHost.blake3_hex("abc", :graphlaw_wasm_test)
    end

    test "run_hooks/4 rejects non-UTF-8 input on either argument without committing any engine memory" do
      assert {:ok, before} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.run_hooks(@invalid, @event_ttl, :graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.run_hooks(@base_ttl, @invalid, :graphlaw_wasm_test)

      assert {:ok, after_bytes} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert after_bytes == before,
             "engine memory grew from #{before} to #{after_bytes} bytes -- " <>
               "the guard let a non-UTF-8 call reach the wasm instance"

      assert {:ok, result} = WasmexHost.run_hooks(@base_ttl, @event_ttl, :graphlaw_wasm_test)
      assert result["status"] == "ADMITTED"
    end

    test "validate_all/7 rejects non-UTF-8 input on any of its five arguments without committing any engine memory" do
      assert {:ok, before} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.validate_all(@invalid, "", "", "", "", :graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.validate_all(@base_ttl, "", "", "", @invalid, :graphlaw_wasm_test)

      assert {:ok, after_bytes} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert after_bytes == before,
             "engine memory grew from #{before} to #{after_bytes} bytes -- " <>
               "the guard let a non-UTF-8 call reach the wasm instance"

      assert {:ok, result} =
               WasmexHost.validate_all(@base_ttl, "", "", "", "", :graphlaw_wasm_test)

      assert result["graph_hash"] == @base_digest
    end
  end

  describe "graceful degradation when the artifact is absent" do
    test "starts anyway and returns a typed error on every call" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "definitely_not_a_wasm_#{System.unique_integer([:positive])}.wasm"
        )

      refute File.exists?(missing)

      {:ok, _pid} =
        start_supervised(
          {WasmexHost, name: :graphlaw_wasm_absent_test, wasm_path: missing},
          id: :graphlaw_absent
        )

      # The process is alive -- a missing native artifact does not take down
      # the supervision tree (same convention as HddlSolver's missing binary).
      assert Process.whereis(:graphlaw_wasm_absent_test) |> Process.alive?()
      refute WasmexHost.available?(:graphlaw_wasm_absent_test)

      assert {:error, %{code: :graphlaw_wasm_not_vendored, path: ^missing}} =
               WasmexHost.version(:graphlaw_wasm_absent_test)

      assert {:error, %{code: :graphlaw_wasm_not_vendored}} =
               WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_absent_test)

      assert {:error, %{code: :graphlaw_wasm_not_vendored}} =
               WasmexHost.validate_all(@base_ttl, "", "", "", "", :graphlaw_wasm_absent_test)
    end

    test "calling an unstarted instance is a typed error, not an exit" do
      assert {:error, %{code: :graphlaw_not_started}} =
               WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_definitely_not_started)
    end
  end

  describe "the loaded instance reports itself available" do
    test "available?/1 is true for the real loaded engine" do
      assert WasmexHost.available?(:graphlaw_wasm_test)
    end
  end
end
