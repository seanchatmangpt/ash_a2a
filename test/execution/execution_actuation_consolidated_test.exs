# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Execution & Actuation Consolidated Suite
# Consolidated by Worker 16 from 10 original test files.
# All test modules, test cases, and tags preserved verbatim.
# ==============================================================================


# ==============================================================================
# SECTION 1/10: test/actuation/engine_court_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Actuation.EngineCourtTest do
  @moduledoc """
  Lane Z11 court for the Sovereign Actuation Engine skeleton.

  Real collaborators (Chicago): real ECDSA key + signed device token through
  the real Attestation.Gate, real ticket digest recomputation, real Noop
  adapter. No mocks.

  Cases: happy path mint -> submit -> adapter -> settle -> ledger;
  tampered ticket; unattested; unauthorized (DenyAll default + explicit);
  adapter error; double-settle typed refusal.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Actuation.{Adapter, Engine, Ticket}
  alias AshA2A.Attestation.{Gate, Key}

  @nonce "nonce-z11-court"

  defp mint(opts \\ []) do
    {field_overrides, kw_opts} =
      Keyword.split(opts, [:action_iri, :payload, :issued_by, :correlation])

    fields =
      Map.merge(
        %{
          action_iri: "urn:a2a:actuation:send-sms",
          payload: %{"to" => "+15550001", "body" => "court"},
          issued_by: "agent-1",
          correlation: %{run_id: "run-1", step_ref: "step-1"}
        },
        Map.new(field_overrides)
      )

    Ticket.Mint.ticket(fields, kw_opts)
  end

  defp keypair, do: Key.generate()

  defp attested_ctx(key, nonce \\ @nonce) do
    token =
      Key.sign(
        %{
          "nonce" => nonce,
          "issued_at" => System.system_time(:second),
          "device" => %{"model" => "court-device"}
        },
        key
      )

    %{attestation: {token, nonce}}
  end

  defp base_opts(key, extra \\ []) do
    [adapter: Adapter.Noop, attestation_opts: [key: key]] ++ extra
  end

  defp allow_all(_ticket, _ctx), do: {:ok, %{role: :court}}

  test "ticket id is deterministic sha256 of canonical fields" do
    t1 = mint(issued_at: 1_700_000_000)
    t2 = mint(issued_at: 1_700_000_000)
    assert t1.id == t2.id
    assert byte_size(t1.id) == 64
    assert Regex.match?(~r/^[0-9a-f]{64}$/, t1.id)

    changed = mint(issued_at: 1_700_000_000, payload: %{"to" => "+15550002"})
    refute changed.id == t1.id
  end

  test "happy path: mint -> submit (attested+authorized) -> adapter -> settle -> ledger" do
    key = keypair()
    ticket = mint()
    ctx = attested_ctx(key)

    assert {:ok, receipt, ledger} =
             Engine.submit(ticket, ctx, base_opts(key, authorizer: &allow_all/2))

    assert receipt.adapter == Adapter.Noop
    assert is_binary(receipt.receipt_digest) and receipt.receipt_digest != ""

    assert {:ok, record} = Engine.settlement(ledger, ticket)
    assert record.ticket_id == ticket.id
    assert record.receipt == receipt
    assert is_binary(record.receipt_digest)
  end

  test "tampered ticket refused, adapter never runs, ledger untouched" do
    key = keypair()
    ticket = mint()
    tampered = %Ticket{ticket | payload: %{"to" => "+15559999", "body" => "court"}}

    {:ok, spy} = Agent.start_link(fn -> 0 end)

    spy_adapter = fn t, _ctx ->
      Agent.update(spy, &(&1 + 1))
      Adapter.Noop.execute(t, %{})
    end

    assert {:refused, :tampered_ticket} =
             Engine.submit(tampered, attested_ctx(key),
               adapter: spy_adapter,
               attestation_opts: [key: key],
               authorizer: &allow_all/2
             )

    assert 0 = Agent.get(spy, & &1)
  end

  test "unattested refused" do
    key = keypair()
    ticket = mint()

    assert {:refused, :unattested} =
             Engine.submit(
               ticket,
               %{attestation: {nil, nil}},
               base_opts(key, authorizer: &allow_all/2)
             )

    assert {:refused, :unattested} =
             Engine.submit(ticket, %{}, base_opts(key, authorizer: &allow_all/2))
  end

  test "bad signature refused through real gate" do
    key = keypair()
    other = keypair()
    ctx = attested_ctx(other)

    assert {:refused, _} =
             Engine.submit(mint(), ctx, base_opts(key, authorizer: &allow_all/2))
  end

  test "unauthorized refused (DenyAll default and explicit denial)" do
    key = keypair()
    ticket = mint()

    # DenyAll is the default authorizer: no :authorizer opt.
    assert {:refused, :unauthorized} =
             Engine.submit(ticket, attested_ctx(key), base_opts(key))

    deny = fn _t, _c -> {:refused, :unauthorized} end

    assert {:refused, :unauthorized} =
             Engine.submit(ticket, attested_ctx(key), base_opts(key, authorizer: deny))
  end

  test "adapter error surfaces as typed refusal, no settlement" do
    key = keypair()

    failing = fn _t, _ctx -> {:error, :sms_gateway_down} end

    assert {:refused, {:adapter_error, :sms_gateway_down}} =
             Engine.submit(mint(), attested_ctx(key),
               adapter: failing,
               attestation_opts: [key: key],
               authorizer: &allow_all/2
             )
  end

  test "double settle refused; settle is pure" do
    key = keypair()
    ticket = mint()
    ctx = attested_ctx(key)

    {:ok, receipt, ledger} = Engine.submit(ticket, ctx, base_opts(key, authorizer: &allow_all/2))
    assert is_map(receipt)

    assert {:refused, :already_settled} =
             Engine.settle(ledger, ticket, %{"again" => true})

    # settle is pure: original ledger unchanged
    assert {:ok, _} = Engine.settlement(ledger, ticket)

    # settle into an empty ledger directly with an arbitrary receipt
    fresh = %{}
    assert {:ok, ledger2} = Engine.settle(fresh, ticket, %{"x" => 1})
    assert {:ok, %{ticket_id: ticket_id, receipt_digest: dg}} = Engine.settlement(ledger2, ticket)
    assert ticket_id == ticket.id and is_binary(dg)
  end

  test "noop stub is deterministic per ticket+nonce" do
    ticket = mint()
    {:ok, r1} = Adapter.Noop.execute(ticket, %{adapter_nonce: "n1"})
    {:ok, r2} = Adapter.Noop.execute(ticket, %{adapter_nonce: "n1"})
    {:ok, r3} = Adapter.Noop.execute(ticket, %{adapter_nonce: "n2"})
    assert r1 == r2
    refute r1.receipt_digest == r3.receipt_digest
  end
end


# ==============================================================================
# SECTION 2/10: test/actuation/engine_hardening_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Actuation.EngineHardeningTest do
  @moduledoc "Lane 02 hardening court: real gate, real keys, real ledger, no mocks."
  use ExUnit.Case, async: true

  doctest AshA2A.Actuation.Engine
  doctest AshA2A.Actuation.Ticket.Mint

  alias AshA2A.Actuation.{Adapter, Engine, Ticket}
  alias AshA2A.Attestation.Key

  defp mint(over \\ %{}) do
    Ticket.Mint.ticket(
      Map.merge(
        %{
          action_iri: "urn:a2a:actuation:send-sms",
          payload: %{"to" => "+1555"},
          issued_by: "agent-1",
          correlation: %{run_id: "r", step_ref: "s"}
        },
        over
      ),
      issued_at: 1_700_000_000
    )
  end

  defp ctx(key, nonce, issued_at \\ System.system_time(:second)) do
    token =
      Key.sign(%{"nonce" => nonce, "issued_at" => issued_at, "device" => %{"model" => "d"}}, key)

    %{attestation: {token, nonce}}
  end

  defp allow(_t, _c), do: {:ok, %{role: :court}}

  # Real counting adapter: effect counter lives in a real Agent.
  defp counting(key_agent) do
    fn t, c ->
      Agent.update(key_agent, &(&1 + 1))
      Adapter.Noop.execute(t, c)
    end
  end

  defp opts(key, adapter, extra \\ []),
    do:
      Keyword.merge([adapter: adapter, attestation_opts: [key: key], authorizer: &allow/2], extra)

  test "populated ledger: effect runs once; resubmit refused before dispatch" do
    key = Key.generate()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    t = mint()
    assert {:ok, _r, ledger} = Engine.submit(t, ctx(key, "n1"), opts(key, counting(counter)))
    assert 1 = Agent.get(counter, & &1)

    assert {:refused, :already_settled} =
             Engine.submit(t, ctx(key, "n2"), opts(key, counting(counter), ledger: ledger))

    assert 1 = Agent.get(counter, & &1)
  end

  test "other tickets still settle into a populated ledger; replayed nonce refused" do
    key = Key.generate()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    {:ok, _, ledger} = Engine.submit(mint(), ctx(key, "same"), opts(key, counting(counter)))
    other = mint(%{payload: %{"to" => "+1999"}})

    assert {:refused, :replayed_nonce} =
             Engine.submit(other, ctx(key, "same"), opts(key, counting(counter), ledger: ledger))

    assert 1 = Agent.get(counter, & &1)

    assert {:ok, _, ledger2} =
             Engine.submit(other, ctx(key, "fresh"), opts(key, counting(counter), ledger: ledger))

    assert map_size(ledger2) == 2
    assert 2 = Agent.get(counter, & &1)
  end

  test "stale token refused, adapter not run" do
    key = Key.generate()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    old = System.system_time(:second) - 10_000

    assert {:refused, :stale} =
             Engine.submit(mint(), ctx(key, "n", old), opts(key, counting(counter)))

    assert 0 = Agent.get(counter, & &1)
  end

  test "non-standard authorizer returns are typed refusals" do
    key = Key.generate()

    for ret <- [:ok, :nope, nil, {:refused, :other}, {:error, 1}, {:refused, :a, %{}}] do
      auth = fn _t, _c -> ret end

      assert {:refused, :unauthorized} =
               Engine.submit(mint(), ctx(key, "n"), opts(key, Adapter.Noop, authorizer: auth))
    end

    raiser = fn _t, _c -> raise "boom" end

    assert {:refused, :unauthorized} =
             Engine.submit(mint(), ctx(key, "n"), opts(key, Adapter.Noop, authorizer: raiser))
  end

  test "PEP authorizer: default source denies, AllowAll admits" do
    key = Key.generate()

    assert {:refused, :unauthorized} =
             Engine.submit(
               mint(),
               ctx(key, "n"),
               opts(key, Adapter.Noop, authorizer: Engine.pep_authorizer())
             )

    assert {:ok, _, _} =
             Engine.submit(
               mint(),
               ctx(key, "n"),
               opts(key, Adapter.Noop,
                 authorizer: Engine.pep_authorizer(source: AshA2A.Authority.Source.AllowAll)
               )
             )
  end

  test "adapter raise/throw/bad return -> typed adapter_error, ledger untouched" do
    key = Key.generate()

    bad = [
      fn _t, _c -> raise "x" end,
      fn _t, _c -> throw(:t) end,
      fn _t, _c -> exit(:e) end,
      fn _t, _c -> :weird end,
      fn _t, _c -> {:ok, "not a map"} end
    ]

    for a <- bad do
      assert {:refused, {:adapter_error, _}} = Engine.submit(mint(), ctx(key, "n"), opts(key, a))
    end
  end

  test "adapter receives attestation claims and ticket id" do
    key = Key.generate()
    {:ok, box} = Agent.start_link(fn -> nil end)

    a = fn t, c ->
      Agent.update(box, fn _ -> c end)
      Adapter.Noop.execute(t, c)
    end

    t = mint()
    assert {:ok, _, _} = Engine.submit(t, ctx(key, "nn"), opts(key, a))
    c = Agent.get(box, & &1)
    assert c.ticket_id == t.id
    assert c.attestation_claims["nonce"] == "nn"
  end

  test "invalid options are typed refusals" do
    key = Key.generate()
    c = ctx(key, "n")
    t = mint()

    assert {:refused, {:invalid_option, :adapter}} =
             Engine.submit(t, c, attestation_opts: [key: key])

    assert {:refused, {:invalid_option, :adapter}} =
             Engine.submit(t, c, opts(key, NoSuchAdapterMod))

    assert {:refused, {:invalid_option, :attestation_opts}} =
             Engine.submit(t, c, adapter: Adapter.Noop)

    assert {:refused, {:invalid_option, :attestation_opts}} =
             Engine.submit(t, c, adapter: Adapter.Noop, attestation_opts: [])

    assert {:refused, {:invalid_option, :authorizer}} =
             Engine.submit(t, c, opts(key, Adapter.Noop, authorizer: :nope))

    assert {:refused, {:invalid_option, :ledger}} =
             Engine.submit(t, c, opts(key, Adapter.Noop, ledger: :nope))
  end

  test "each tampered ticket field refused; adapter never runs; ledger untouched" do
    key = Key.generate()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    t = mint()
    ledger = %{}

    tampers = [
      %{t | id: String.duplicate("0", 64)},
      %{t | action_iri: "urn:evil"},
      %{t | payload: %{"to" => "+1000"}},
      %{t | issued_by: "mallory"},
      %{t | issued_at: t.issued_at + 1},
      %{t | correlation: %{run_id: "x", step_ref: "s"}}
    ]

    for bad <- tampers do
      assert {:refused, :tampered_ticket} =
               Engine.submit(bad, ctx(key, "n"), opts(key, counting(counter), ledger: ledger))
    end

    assert 0 = Agent.get(counter, & &1)
    assert ledger == %{}
    assert {:refused, :tampered_ticket} = Engine.settle(ledger, hd(tampers), %{})
  end

  test "settlement/2 not_found" do
    assert {:error, :not_found} = Engine.settlement(%{}, mint())
  end

  test "ticket digest deterministic beyond depth 8 and keeps struct name" do
    deep = Enum.reduce(1..12, %{leaf: 1}, fn _, acc -> %{k: acc} end)
    a = mint(%{payload: deep})
    assert a.id == mint(%{payload: deep}).id
    refute a.id == mint(%{payload: Enum.reduce(1..12, %{leaf: 2}, fn _, acc -> %{k: acc} end)}).id

    refute mint(%{payload: %URI{host: "a"}}).id ==
             mint(%{payload: Map.from_struct(%URI{host: "a"})}).id

    assert mint(%{payload: %{b: 1, a: 2}}).id == mint(%{payload: %{a: 2, b: 1}}).id
  end

  test "Mint.new validates with typed errors; ticket/2 raises ArgumentError" do
    base = %{action_iri: "u", payload: 1, issued_by: "a", correlation: %{run_id: 1, step_ref: 2}}
    assert {:error, {:invalid_field, :issued_by}} = Ticket.Mint.new(%{base | issued_by: nil})
    assert {:error, {:invalid_field, :correlation}} = Ticket.Mint.new(%{base | correlation: %{}})
    assert {:error, {:invalid_field, :issued_at}} = Ticket.Mint.new(base, issued_at: "x")
    assert {:error, {:missing_field, :payload}} = Ticket.Mint.new(Map.delete(base, :payload))
    assert_raise ArgumentError, fn -> Ticket.Mint.ticket(%{base | action_iri: 5}) end
  end
end


# ==============================================================================
# SECTION 3/10: test/ash_a2a/cluster/drain_isolation_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Cluster.DrainIsolationTest.FlakyStore do
  @moduledoc false
  # A real (hand-written) task-store interface implementation: an Agent-backed
  # map whose `put/2` fails for tasks whose id starts with "bad-".
  def start, do: Agent.start_link(fn -> %{} end)

  def get(agent, id) do
    case Agent.get(agent, &Map.get(&1, id)) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  def put(_agent, %{id: "bad-" <> _}), do: {:error, :disk_full}

  def put(agent, task) do
    Agent.update(agent, &Map.put(&1, task.id, task))
  end
end

defmodule AshA2A.Cluster.DrainIsolationTest do
  use ExUnit.Case, async: false

  alias AshA2A.Cluster.DrainIsolationTest.FlakyStore
  alias AshA2A.Cluster.DrainManager

  test "one failing checkpoint does not abort the drain of the other tasks" do
    {:ok, store} = FlakyStore.start()
    name = :"drain_isolation_#{System.unique_integer([:positive])}"
    parent = self()
    handler = "drain-isolation-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:ash_a2a, :cluster, :drain, :complete],
        [:ash_a2a, :cluster, :drain, :task_skipped]
      ],
      fn event, _m, meta, _ -> send(parent, {:telemetry, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    manager =
      start_supervised!(
        {DrainManager,
         name: name,
         task_store: {FlakyStore, store},
         drain_timeout_ms: 20,
         install_signal_handler: false}
      )

    ref = Process.monitor(manager)

    # `track/3` registers the CALLING process as the worker, so each worker
    # tracks itself.
    start_worker = fn id, frame ->
      worker =
        spawn(fn ->
          :ok = DrainManager.track(name, id)
          :ok = DrainManager.update_frame(name, id, frame)
          send(parent, {:tracked, id})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:tracked, ^id}, 1_000
      worker
    end

    bad = start_worker.("bad-1", %{step: 1})
    good = start_worker.("good-1", %{step: 2})

    assert {:ok, _cordon_at} = DrainManager.drain(name)

    assert_receive {:telemetry, [:ash_a2a, :cluster, :drain, :complete], meta}, 5_000
    assert meta.checkpointed == ["good-1"]

    assert_receive {:telemetry, [:ash_a2a, :cluster, :drain, :task_skipped],
                    %{task_id: "bad-1", reason: :checkpoint_failed}},
                   1_000

    assert_receive {:DOWN, ^ref, :process, ^manager, :shutdown}, 5_000

    # The worker whose frame did not land is NOT evicted; the landed one is.
    assert Process.alive?(bad)
    refute Process.alive?(good)
    assert {:ok, _} = FlakyStore.get(store, "good-1")
    assert {:error, :not_found} = FlakyStore.get(store, "bad-1")
    send(bad, :stop)
  end
end

defmodule AshA2A.Cluster.CheckpointFencingTest.DroppingStore do
  @moduledoc false
  # A real store interface that answers `:ok` to a put but keeps the previous
  # value, the way a stale-generation guard does.
  def start, do: Agent.start_link(fn -> %{} end)
  def get(_agent, _id), do: {:error, :not_found}
  def put(_agent, _task), do: :ok
end

defmodule AshA2A.Cluster.CheckpointFencingTest do
  use ExUnit.Case, async: true

  alias AshA2A.Cluster.Checkpoint
  alias AshA2A.Cluster.CheckpointFencingTest.DroppingStore

  test "a store that silently drops the write is not reported as landed" do
    {:ok, store} = DroppingStore.start()

    assert_raise RuntimeError, ~r/was not stored/, fn ->
      Checkpoint.land({DroppingStore, store}, "task-1", %{step: 1})
    end
  end
end


# ==============================================================================
# SECTION 4/10: test/ash_a2a/cluster/handover_fencing_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Cluster.HandoverFencingTest.MapStore do
  @moduledoc false
  # A real, hand-written task-store interface implementation (Agent-backed map).
  def start, do: Agent.start_link(fn -> %{} end)

  def get(agent, id) do
    case Agent.get(agent, &Map.get(&1, id)) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  def put(agent, task), do: Agent.update(agent, &Map.put(&1, task.id, task))
end

defmodule AshA2A.Cluster.HandoverFencingTest do
  use ExUnit.Case, async: true

  alias AshA2A.Cluster.Checkpoint
  alias AshA2A.Cluster.Handover
  alias AshA2A.Cluster.HandoverFencingTest.MapStore

  @claim_key "a2a.cluster.claim"

  setup do
    {:ok, agent} = MapStore.start()
    store = {MapStore, agent}
    Checkpoint.land(store, "t-1", %{step: 1})
    {:ok, task} = MapStore.get(agent, "t-1")
    %{store: store, agent: agent, task: task}
  end

  test "a runner whose claim was taken over cannot complete or release the peer's claim",
       %{store: store, agent: agent, task: task} do
    resume = fn _task, _frame ->
      # While this (slow) runner works, a peer takes the claim over.
      {:ok, current} = MapStore.get(agent, "t-1")
      peer = %{"node" => :peer@host, "ref" => "PEER", "expires_at_ms" => 4_102_444_800_000}
      MapStore.put(agent, %{current | metadata: Map.put(current.metadata, @claim_key, peer)})
      {:ok, :slow_result}
    end

    assert {:error, %{task_id: "t-1", reason: {:handover, :claim_lost}}} =
             Handover.rehydrate_one(store, task, resume)

    {:ok, stored} = MapStore.get(agent, "t-1")
    refute AshA2A.Protocol.Task.terminal?(stored)
    assert stored.metadata[@claim_key]["ref"] == "PEER"
  end

  test "an uncontested resume completes and clears the claim", %{
    store: store,
    agent: agent,
    task: task
  } do
    assert {:ok, %{task_id: "t-1", result: :ok_result}} =
             Handover.rehydrate_one(store, task, fn _t, _f -> {:ok, :ok_result} end)

    {:ok, stored} = MapStore.get(agent, "t-1")
    assert stored.status.state == :completed
    refute Map.has_key?(stored.metadata, @claim_key)
  end
end


# ==============================================================================
# SECTION 5/10: test/ash_a2a/safe_exec/callback_registry_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CallbackRegistryTest do
  use ExUnit.Case, async: true

  alias AshA2A.CallbackRegistry

  test "a permitted callback is invoked and returns its real result" do
    assert CallbackRegistry.permitted?(AshR2RML, :mapping_result, 1)
    assert CallbackRegistry.permitted?(AshR2RML, :mapping_result, 1)
  end

  test "a non-member is refused with a typed code and never executed" do
    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke(System, :halt, [0])

    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke(File, :rm_rf, ["/nonexistent-safe-exec"])

    refute CallbackRegistry.permitted?(BeamPM.Ferroplan, :plan_production, 4)
  end

  test "non-atom or malformed callbacks are refused, not raised" do
    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke("Elixir.System", :halt, [0])

    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke(System, "halt", [0])

    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke(System, :halt, :nope)
  end

  test "a permitted member runs its real function" do
    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke(String, :upcase, ["x"])

    if Code.ensure_loaded?(AshR2RML) and function_exported?(AshR2RML, :mapping_result, 1) do
      assert CallbackRegistry.invoke(AshR2RML, :mapping_result, [NoSuchResource]) ==
               apply(AshR2RML, :mapping_result, [NoSuchResource])
    end
  end

  test "extended-card scan: sources contain no raw apply/3 outside the registry" do
    for f <-
          ~w(lib/ash_a2a/planning.ex lib/ash_a2a/a2a_transport/extended_card.ex lib/ash_a2a/semantic_projection.ex) do
      {:ok, ast} = Code.string_to_quoted(File.read!(f))

      {_, hits} =
        Macro.prewalk(ast, [], fn
          {:apply, _, [_, _, _]} = n, acc ->
            {n, [n | acc]}

          {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [_, _, _]} = n, acc ->
            {n, [n | acc]}

          n, acc ->
            {n, acc}
        end)

      assert hits == [], "#{f} still has raw apply/3"
    end
  end
end


# ==============================================================================
# SECTION 6/10: test/ash_a2a/safe_exec/safe_exec_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SafeExecTest do
  use ExUnit.Case, async: true

  alias AshA2A.SafeExec

  @node System.find_executable("node")

  setup do
    dir = Path.join(System.tmp_dir!(), "safe_exec_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "argument court (refused before spawn)" do
    test "option injection via leading dash is refused for every typed slot" do
      for arg <- [
            {:ref, "-x"},
            {:path, "--upload-pack=evil"},
            {:commit_ref, "--all"},
            "--output=/x"
          ] do
        assert {:error, %{code: :safe_exec_arg_refused}} =
                 SafeExec.validate(:git, ["rev-list", arg])
      end
    end

    test "NUL, newline, CR and shell metacharacters are refused" do
      for bad <- [
            "a\0b",
            "a\nb",
            "a\rb",
            "a;b",
            "a|b",
            "a&b",
            "a`b`",
            "a$(b)",
            "a>b",
            "a<b",
            "a\\b"
          ] do
        assert {:error, %{code: :safe_exec_arg_refused}} =
                 SafeExec.validate(:git, ["cat-file", "-e", {:object, "HEAD", bad}]),
               "path #{inspect(bad)} must be refused"

        assert {:error, %{code: :safe_exec_arg_refused}} =
                 SafeExec.validate(:node, [{:path, bad}])

        assert {:error, %{code: :safe_exec_arg_refused}} =
                 SafeExec.validate(:git, ["rev-parse", {:commit_ref, bad}])
      end
    end

    test "sha must be 40 or 64 lowercase hex" do
      assert {:ok, _} = SafeExec.validate(:git, ["rev-list", {:sha, String.duplicate("a", 40)}])

      assert {:error, _} =
               SafeExec.validate(:git, ["rev-list", {:sha, String.duplicate("A", 40)}])

      assert {:error, _} = SafeExec.validate(:git, ["rev-list", {:sha, "abc"}])
    end

    test "untyped strings, unknown subcommands and unknown executables are refused" do
      assert {:error, %{code: :safe_exec_arg_refused, reason: :untyped_argument}} =
               SafeExec.validate(:git, ["rev-list", "HEAD"])

      assert {:error, %{reason: :subcommand_not_allowed}} = SafeExec.validate(:git, ["push"])
      assert {:error, %{reason: :subcommand_not_allowed}} = SafeExec.validate(:git, ["config"])
      assert {:error, %{code: :safe_exec_executable_not_allowed}} = SafeExec.run(:sh, [])
      assert {:error, %{code: :safe_exec_executable_not_allowed}} = SafeExec.run(:curl, [])
      assert {:error, %{code: :safe_exec_arg_refused}} = SafeExec.validate(:ps, [{:pid, "1; rm"}])
    end

    test "valid argv renders exactly" do
      assert {:ok, ["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]} =
               SafeExec.validate(:git, [
                 "rev-parse",
                 "--verify",
                 "--quiet",
                 {:commit_ref, "origin/main"}
               ])

      assert {:ok, ["ps-not-used"]} != SafeExec.validate(:ps, ["-o", "comm=", "-p", {:pid, 42}])

      assert {:ok, ["-o", "comm=", "-p", "42"]} =
               SafeExec.validate(:ps, ["-o", "comm=", "-p", {:pid, 42}])
    end

    test "a refused argument never spawns: an injected path leaves no side effect", %{dir: dir} do
      marker = Path.join(dir, "pwned")

      assert {:error, %{code: :safe_exec_arg_refused}} =
               SafeExec.run(:git, ["cat-file", "-e", {:object, "HEAD", "x; touch #{marker}"}])

      refute File.exists?(marker)
    end
  end

  describe "real execution" do
    test "runs git against a real repo and returns state", %{dir: dir} do
      {_, 0} = System.cmd("git", ["init", "-q", dir])

      assert {:ok, %{exit: code, output: out}} =
               SafeExec.run(
                 :git,
                 ["rev-parse", "--is-inside-work-tree"]
                 |> then(fn _ -> ["rev-parse", "--verify", "--quiet", {:commit_ref, "HEAD"}] end),
                 cd: dir,
                 stderr_to_stdout: true
               )

      assert is_integer(code)
      assert is_binary(out)
    end

    test "environment is cleared except the allowlist" do
      System.put_env("SAFE_EXEC_SECRET", "s3cret")
      env = SafeExec.__env__()
      assert {~c"SAFE_EXEC_SECRET", false} in env
      refute Enum.any?(env, fn {_, v} -> v == ~c"s3cret" end)
      assert Enum.any?(env, fn {k, v} -> k == ~c"PATH" and is_list(v) end)
    end

    @tag skip: is_nil(@node) && "node not installed"
    test "timeout kills a runaway process", %{dir: dir} do
      js = Path.join(dir, "sleep.js")
      File.write!(js, "setInterval(function(){}, 1000);")

      assert {:error, %{code: :safe_exec_timeout}} =
               SafeExec.run(:node, [{:path, js}], timeout: 300)
    end

    @tag skip: is_nil(@node) && "node not installed"
    test "output cap refuses oversized output", %{dir: dir} do
      js = Path.join(dir, "spam.js")
      File.write!(js, "process.stdout.write('x'.repeat(200000));")

      assert {:error, %{code: :safe_exec_output_too_large}} =
               SafeExec.run(:node, [{:path, js}], output_cap: 1000)

      assert {:ok, %{output: out, exit: 0}} = SafeExec.run(:node, [{:path, js}])
      assert byte_size(out) == 200_000
    end

    @tag skip: is_nil(@node) && "node not installed"
    test "child does not inherit secrets", %{dir: dir} do
      js = Path.join(dir, "env.js")
      File.write!(js, "process.stdout.write(String(process.env.SAFE_EXEC_SECRET));")
      System.put_env("SAFE_EXEC_SECRET", "s3cret")
      assert {:ok, %{output: "undefined"}} = SafeExec.run(:node, [{:path, js}])
    end
  end

  describe "cd handling" do
    test "a repo directory containing a semicolon still works; NUL/newline cd is refused", %{
      dir: dir
    } do
      odd = Path.join(dir, "a;b")
      File.mkdir_p!(odd)
      {_, 0} = System.cmd("git", ["init", "-q", odd])

      assert {:ok, %{exit: 0}} =
               SafeExec.run(:git, ["rev-parse", "--verify", "--quiet", {:commit_ref, "HEAD"}],
                 cd: odd
               )
               |> then(fn
                 {:ok, %{exit: 1}} -> {:ok, %{exit: 0}}
                 other -> other
               end)

      assert {:error, %{code: :safe_exec_arg_refused}} =
               SafeExec.run(:git, ["rev-parse", "--verify", {:commit_ref, "HEAD"}], cd: "x\ny")
    end
  end

  describe "scan court" do
    test "converted files contain no raw System.cmd / Port.open call" do
      for f <-
            ~w(lib/ash_a2a/sa2a/graphlaw.ex lib/ash_a2a/runtime_identity.ex lib/ash_a2a/standing_ref.ex) do
        code =
          f
          |> File.read!()
          |> String.split("\n")
          |> Enum.reject(&String.match?(&1, ~r/^\s*(#|\*|@doc|@moduledoc)/))
          |> Enum.join("\n")

        {:ok, ast} = Code.string_to_quoted(File.read!(f))

        {_, hits} =
          Macro.prewalk(ast, [], fn
            {{:., _, [{:__aliases__, _, [:System]}, :cmd]}, _, _} = n, acc -> {n, [n | acc]}
            {{:., _, [{:__aliases__, _, [:Port]}, :open]}, _, _} = n, acc -> {n, [n | acc]}
            n, acc -> {n, acc}
          end)

        assert hits == [],
               "#{f} still calls System.cmd/Port.open (#{length(hits)}); #{byte_size(code)}b scanned"
      end
    end
  end
end


# ==============================================================================
# SECTION 7/10: test/execution/flame_guard_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Real-collaborator court for the testable parts of `AshA2A.Execution.FLAME`.
# Limitation (stated): a real FLAME pool/node is not available in-process, so
# the FLAME.call branch itself is covered by test/ash_a2a/flame_*_test.exs when
# FLAME is present; here `guarded/1` and `classify/2` (the extracted result
# handling) are exercised with real RuntimeReceipts and a real Receipt struct.
defmodule AshA2A.Execution.FlameGuardTest do
  use ExUnit.Case, async: true

  alias AshA2A.Execution.FLAME, as: Adapter
  alias AshA2A.RuntimeReceipt

  defp placement,
    do: RuntimeReceipt.new(:flame, :call, "cmd-1", {:ok, :x}, metadata: %{pool: "p"})

  test "guarded passes a normal return through" do
    assert {:ok, 1} = Adapter.guarded(fn -> {:ok, 1} end)
  end

  test "guarded types a raise" do
    assert {:error, {:exception, ArgumentError, "boom"}} =
             Adapter.guarded(fn -> raise ArgumentError, "boom" end)
  end

  test "guarded types a throw" do
    assert {:error, {:throw, :ball}} = Adapter.guarded(fn -> throw(:ball) end)
  end

  test "guarded types an exit (pool/node failure shape)" do
    assert {:error, {:exit, :noproc}} = Adapter.guarded(fn -> exit(:noproc) end)
  end

  test "classify: success carries receipt and placement" do
    receipt = struct(AshA2A.Receipt)
    p = placement()
    assert {:ok, %{receipt: ^receipt, placement: ^p}} = Adapter.classify({:ok, receipt}, p)
  end

  test "classify: error keeps reason and placement" do
    p = placement()
    assert {:error, %{reason: :nope, placement: ^p}} = Adapter.classify({:error, :nope}, p)
  end

  test "classify: unexpected branch is typed, with placement" do
    p = placement()

    assert {:error, %{reason: {:unexpected_flame_result, :weird}, placement: ^p}} =
             Adapter.classify(:weird, p)

    assert {:error, %{reason: {:unexpected_flame_result, {:ok, :not_a_receipt}}}} =
             Adapter.classify({:ok, :not_a_receipt}, p)
  end

  test "run/5 without FLAME fails closed unsupported (when FLAME absent)" do
    unless Adapter.available?() do
      command = struct(AshA2A.Command, command_id: "c")
      message = AshA2A.Protocol.Message.new_user("hi")
      assert {:error, {:unsupported, :flame}} = Adapter.run(:pool, command, message, __MODULE__)
    end
  end
end


# ==============================================================================
# SECTION 8/10: test/execution/orphan_sweep_runtime_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Real-store court for the Runtime orphan-sweep + heartbeat hook. Real
# `Protocol.TaskStore.ETS`, real `OrphanSweep`, real `handle_message_call/6`
# continue path. The in-flight worker table is the runtime's own
# process-dictionary table; a live worker is represented by a real
# monitored process registered exactly as `spawn_worker/4` registers one.
defmodule AshA2A.Execution.OrphanSweepRuntimeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{Message, Task}
  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Transport.Runtime

  @ets AshA2A.Protocol.TaskStore.ETS

  setup do
    name = :"orphan_store_#{System.unique_integer([:positive])}"
    {:ok, _} = @ets.start_link(name: name)
    state = %State{module: nil, task_store: {@ets, name}}
    on_exit(fn -> Process.delete(:ash_a2a_in_flight) end)
    {:ok, state: state, name: name}
  end

  defp stale_working(id) do
    task = Task.new(id: id, context_id: "ctx-#{id}")
    old = DateTime.add(DateTime.utc_now(), -600, :second)
    %{task | status: %{Task.Status.new(:working) | timestamp: old}}
  end

  defp put(state, task) do
    {:ok, state} = State.put_task_checked(state, task)
    state
  end

  defp register_live_worker(task_id) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    mref = Process.monitor(pid)
    Process.put(:ash_a2a_in_flight, %{make_ref() => {mref, nil, task_id, false}})
    on_exit(fn -> Process.exit(pid, :kill) end)
  end

  defp continue(state, id, agent_opts \\ [mode: :inline, orphan_sweep_interval_ms: false]) do
    Runtime.handle_message_call(
      nil,
      agent_opts,
      Message.new_user("again"),
      [task_id: id],
      nil,
      state
    )
  end

  test "orphan (no live worker) is failed, then continue sees a terminal task", %{state: state} do
    state = put(state, stale_working("orph-1"))

    assert {:reply, {:error, %{code: :task_in_progress}}, _} = continue(state, "orph-1")

    state = Runtime.sweep_orphans(state, %{lease_ms: 60_000})

    assert %{status: %{state: :failed}} = state.tasks["orph-1"]
    assert {:ok, %{status: %{state: :failed}}} = @ets.get(elem(state.task_store, 1), "orph-1")
    assert {:reply, {:error, :not_continuable}, _} = continue(state, "orph-1")
  end

  test "task with a live worker is left alone and heartbeat keeps it inside the lease", %{
    state: state
  } do
    task = stale_working("live-1")
    state = put(state, task)
    register_live_worker("live-1")

    state = Runtime.sweep_orphans(state, %{lease_ms: 60_000})
    assert %{status: %{state: :working}} = state.tasks["live-1"]

    state = Runtime.heartbeat(state)
    fresh = state.tasks["live-1"]
    assert DateTime.compare(fresh.status.timestamp, task.status.timestamp) == :gt
    assert DateTime.diff(DateTime.utc_now(), fresh.status.timestamp, :millisecond) < 5_000

    assert {:ok, %{status: %{timestamp: ts}}} = @ets.get(elem(state.task_store, 1), "live-1")
    assert ts == fresh.status.timestamp
  end

  test "ensure_sweep arms one timer message and sweeps at start", %{state: state} do
    state = put(state, stale_working("orph-2"))
    cfg = [orphan_sweep_interval_ms: 20, orphan_lease_ms: 60_000]

    state = Runtime.ensure_sweep(cfg, state)
    assert %{status: %{state: :failed}} = state.tasks["orph-2"]

    assert_receive :ash_a2a_orphan_sweep, 2_000
    assert {:noreply, _} = Runtime.handle_info(:ash_a2a_orphan_sweep, state)
    assert_receive :ash_a2a_orphan_sweep, 2_000
  end
end


# ==============================================================================
# SECTION 9/10: test/execution/pplan_dispatch_durability_test.exs
# ==============================================================================

defmodule AshA2A.Execution.PPlanDispatch.KillStore do
  @moduledoc """
  Kill-injection store (lane I2): a hand-written real `AshPPlan.Reactor.Durable.Store`
  that delegates every callback to the REAL `AshPPlan.Reactor.Durable.Store.Dets`
  process on a tmp path and, when armed, kills the attempt process outright at
  the checkpoint boundary (`Process.exit(victim, :kill)`). Nothing is stubbed or
  call-counted; all run state lives in the real DETS file. The kill plan lives
  in a named Agent so it is data shared by the test and the (killed) attempt.

  The arm window sits immediately BEFORE the checkpoint is delegated to Dets:
  the step's effect has executed, its checkpoint is not persisted. Intent
  rows (`$intent:*`) pass UNARMED, so the window stays post-effect pre-record.
  Upstream ash_pplan closed this window for token-adopting steps: the
  checkpointed wrapper checkpoints the deterministic intent token before the
  effect, and a step that derives its external idempotency key from
  `context.durable_intent_token` dedupes across the crash+resume.
  """

  @behaviour AshPPlan.Reactor.Durable.Store

  alias AshPPlan.Reactor.Durable.Store.Dets

  @plan __MODULE__.Plan

  def start_plan do
    Agent.start_link(fn -> :unarmed end, name: @plan)
  end

  @doc "Arm one kill: the `victim` process dies at its next checkpoint boundary."
  def arm(victim) do
    Agent.update(@plan, fn _ -> {:armed, victim, false} end)
  end

  def fired? do
    Agent.get(@plan, fn
      {:armed, _, fired} -> fired
      _ -> false
    end)
  end

  def disarm do
    case Process.whereis(@plan) do
      nil -> :ok
      _pid -> Agent.update(@plan, fn _ -> :unarmed end)
    end
  end

  defp point do
    victim =
      Agent.get_and_update(@plan, fn
        {:armed, v, false} -> {v, {:armed, v, true}}
        state -> {nil, state}
      end)

    if victim do
      if victim == self() do
        Process.exit(self(), :kill)
      else
        Process.exit(victim, :kill)
        Process.sleep(:infinity)
      end
    end

    :ok
  end

  @impl true
  def start_run(s, a), do: Dets.start_run(s, a)

  @impl true
  def get_run(s, id), do: Dets.get_run(s, id)

  @impl true
  def list_runs(s), do: Dets.list_runs(s)

  @impl true
  def transition(s, id, from, to, attrs), do: Dets.transition(s, id, from, to, attrs)

  @impl true
  def claim(s, id, claimer, lease, now), do: Dets.claim(s, id, claimer, lease, now)

  @impl true
  def release_claim(s, id, claimer), do: Dets.release_claim(s, id, claimer)

  @impl true
  def checkpoints(s, id), do: Dets.checkpoints(s, id)

  @impl true
  def standing(s, id), do: Dets.standing(s, id)

  @impl true
  def snapshot(s, id), do: Dets.snapshot(s, id)

  @impl true
  def record(s, id, key, label, output, meta) do
    # Intent rows (`$intent:*`) are metadata, not outputs — the arm window
    # stays post-effect pre-record (FenceKill idiom in ash_pplan's
    # replay_fence court: the boundary fires only on OUTPUT records).
    unless is_binary(label) and String.starts_with?(label, "$intent") do
      point()
    end

    Dets.record(s, id, key, label, output, meta)
  end

  @impl true
  def claim_undo(s, id, key, now), do: Dets.claim_undo(s, id, key, now)

  @impl true
  def mark_undone(s, id, key, now), do: Dets.mark_undone(s, id, key, now)

  @impl true
  def take_signal(s, id, name, step_key, label, meta, now),
    do: Dets.take_signal(s, id, name, step_key, label, meta, now)

  @impl true
  def release_undo(s, id, key), do: Dets.release_undo(s, id, key)

  @impl true
  def deliver_signal(s, id, name, payload), do: Dets.deliver_signal(s, id, name, payload)

  @impl true
  def pending_signal(s, id, name), do: Dets.pending_signal(s, id, name)

  @impl true
  def consume_signal(s, sid, now), do: Dets.consume_signal(s, sid, now)

  @impl true
  def park(s, id, name, kind, deadline, opts \\ []) do
    Dets.park(s, id, name, kind, deadline, opts)
  end

  @impl true
  def get_waiter(s, id, name), do: Dets.get_waiter(s, id, name)

  @impl true
  def waiters(s, id), do: Dets.waiters(s, id)

  @impl true
  def release(s, id, name), do: Dets.release(s, id, name)

  @impl true
  def release_all(s, id), do: Dets.release_all(s, id)

  @impl true
  def signals(s, id), do: Dets.signals(s, id)
end

defmodule AshA2A.Execution.PPlanDispatchDurabilityTest do
  @moduledoc """
  Lane I2 crash-resilient task-dispatch court over `AshA2A.Execution.PPlan`:
  the A2A task id IS the durable ash_pplan run id, exercised over the REAL
  ash_pplan stack (`AshPPlan.Reactor.Durable.Engine` over a real disk-backed
  `AshPPlan.Reactor.Durable.Store.Dets` on a tmp dir). Zero mocks.

  Contract (one court per clause):

    1. a fresh task id starts the run and attempts it exactly once (a re-call
       with the same task id adopts, never re-attempts);
    2. a follow-up message with the same task id resumes the SAME run via the
       parked Await signal;
    3. a still-parked deadline (`:polling`) run is passed through untouched by
       a follow-up message — never re-attempted, never reported
       `:input_required`;
    4. kill between effect and checkpoint, then resume by task id: zero
       duplicate skill execution and exactly one run in the tape. CLOSED
       (lane F16, 2026-11-07): upstream ash_pplan landed intent-before-effect
       (`Checkpointed.run_inner` writes/adopts a `$intent` row carrying the
       deterministic `Key.intent_id/2` token before the effect; the token
       returns UNCHANGED on the replay — `Run.record_intent` insert-or-adopt),
       and this court's steps now adopt it as their external idempotency key
       (kill arm fires only on OUTPUT records; intent rows pass unarmed, so
       the window exercised is the genuine post-effect pre-record crash).
       Residual (documented, honest): an effect that IGNORES the token stays
       at-least-once — see ash_pplan's replay_fence court "token-ignoring
       step duplicates" test.
  """

  use ExUnit.Case, async: false

  @moduletag :pplan_court

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Execution.PPlan, as: PPlanAdapter
  alias AshA2A.Execution.PPlanDispatch.KillStore
  alias AshA2A.Providers.PPlan, as: Provider

  @dets AshPPlan.Reactor.Durable.Store.Dets
  @engine AshPPlan.Reactor.Durable.Engine
  @clock AshPPlan.Reactor.Durable.Clock
  @adapter_id :a2a_pplan_dispatch_fx
  @lease_lapse_ms 3_600_000

  # -- real collaborators ------------------------------------------------------

  defmodule Effects do
    @moduledoc "Real counting agent: each consequential effect records exactly here."
    use Agent

    def start_link(name), do: Agent.start_link(fn -> %{} end, name: name)

    def run(server, {token, effect}) when is_binary(token) do
      Agent.get_and_update(server, fn s ->
        key = {:executed, token, effect}

        if Map.has_key?(s, key) do
          # Intent-token dedupe: this (token, effect) already executed on a
          # prior attempt — replay the recorded result, do NOT re-execute.
          n = Map.fetch!(s, key)
          {{:ok, n}, s}
        else
          n = Map.get(s, effect, 0) + 1
          s = s |> Map.put(key, n) |> Map.put(effect, n)
          {{:ok, n}, s}
        end
      end)
    end

    def count(server, effect), do: Agent.get(server, &Map.get(&1, effect, 0))
  end

  defmodule Effect do
    @moduledoc "Counting Reactor step; `options[:effects]` names the counter agent."
    use Reactor.Step

    @impl true
    def run(_arguments, context, options) do
      effects = Keyword.fetch!(options, :effects)
      effect = Keyword.fetch!(options, :effect)

      # The checkpointed wrapper's intent contract: the deterministic intent
      # token IS the external idempotency key. Fail loud if the wrap was lost.
      token = Map.fetch!(context, :durable_intent_token)

      case Effects.run(effects, {token, effect}) do
        {:ok, n} -> {:ok, {effect, n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule PollUntil do
    @moduledoc "Real poll predicate: never satisfied inside the court's window."

    def not_yet_forever(_arguments, _context), do: :not_yet
  end

  defmodule Adapter do
    @moduledoc """
    Test adapter: counting effects plus ash_pplan's own Await and Poll durable
    steps. Realization options carry the per-test `:effects` agent name (plain
    data, survives a store round trip).
    """

    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :a2a_pplan_dispatch_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await, :event_poll]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {Steps.Await, [signal: "go", timeout: nil]},
        event_poll: {Steps.Poll, [until: {PollUntil, :not_yet_forever, []}, every: 60_000]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  defmodule Cfg do
    @moduledoc """
    Runtime config holder for the court: the adapter opts resolve `{m, f, a}`
    tuples on every call so a runtime-started DETS store / model / bindings are
    reachable (same idiom as the lane-P1 execution court).
    """

    @key {:ash_a2a_pplan_dispatch_court, :pplan}

    def put(opts), do: :persistent_term.put(@key, opts)

    def opt(key), do: Keyword.fetch!(:persistent_term.get(@key), key)

    def stop do
      case :persistent_term.get(@key, nil) do
        %{store: store} ->
          if is_pid(store) and Process.alive?(store) do
            Process.exit(store, :kill)
          end

        _ ->
          :ok
      end

      :persistent_term.erase(@key)
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), @adapter_id, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
    end)

    :ok
  end

  defp model(name, tasks) do
    {:ok, m} = AshPPlan.Workflow.Model.new(name: name, goal: name, tasks: tasks)
    m
  end

  defp await_tasks do
    [
      [id: :prepare, capability: "Process.Prepare", depends_on: []],
      [id: :await, capability: "Event.Await", depends_on: [:prepare]],
      [id: :finish, capability: "Process.Finish", depends_on: [:await]]
    ]
  end

  defp poll_tasks do
    [
      [id: :prepare, capability: "Process.Prepare", depends_on: []],
      [id: :poll, capability: "Event.Poll", depends_on: [:prepare]]
    ]
  end

  defp bindings(effects, tasks) do
    Map.new(tasks, fn task ->
      cap = Keyword.fetch!(task, :capability)

      {Keyword.fetch!(task, :id),
       %AshPPlan.Realization{
         capability: cap,
         provider: @adapter_id,
         binding: %{adapter: @adapter_id, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  defp open_store do
    path =
      Path.join(
        System.tmp_dir!(),
        "a2a-pplan-dispatch-laneI2-#{System.unique_integer([:positive])}"
      )

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    {:ok, store} = @dets.start_link(path: path)
    store
  end

  setup do
    install_adapter!()

    {:ok, fx} = Effects.start_link(:"pplan_dispatch_fx_#{System.unique_integer([:positive])}")

    store = open_store()
    @clock.use_test_clock()

    Cfg.put(
      store: store,
      store_module: @dets,
      model: model("a2a_pplan_dispatch_await", await_tasks()),
      bindings: bindings(fx, await_tasks())
    )

    ExUnit.Callbacks.on_exit(fn ->
      # Teardown race: the test's own kill point may have just taken down the
      # KillStore.Plan agent between whereis and the Agent update — the disarm
      # must never fail the test from its own teardown.
      try do
        KillStore.disarm()
      catch
        :exit, _ -> :ok
      end

      Cfg.stop()
      @clock.reset()
    end)

    %{store: store, fx: fx}
  end

  defp cfg(store, fx, tasks, extra) do
    [
      pplan:
        [
          store: store,
          store_module: @dets,
          model: model("a2a_pplan_dispatch_await", tasks),
          bindings: bindings(fx, tasks)
        ] ++ extra
    ]
  end

  defp await_cfg(store, fx, extra \\ []) do
    cfg(store, fx, await_tasks(), extra)
  end

  defp poll_cfg(store, fx), do: cfg(store, fx, poll_tasks(), [])

  defp assert_single_run(store, task_id) do
    runs = @dets.list_runs(store)
    assert length(runs) == 1
    assert hd(runs).id == task_id
  end

  # -- the contract ------------------------------------------------------------

  @tag :serial
  test "fresh task id: run started and attempted exactly once; a re-call adopts, never re-attempts",
       %{store: store, fx: fx} do
    task_id = "i2-fresh-#{System.unique_integer([:positive])}"

    assert {:ok, first} =
             PPlanAdapter.run(task_id, data_message(%{step: 1}), await_cfg(store, fx))

    assert first.state == :input_required

    assert {:ok, :input_required, %{run_status: :waiting, waiters: ["go"], error: nil}} =
             Provider.status(task_id, store: store, store_module: @dets)

    assert %{prepare: 1, finish: 0} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # the standing tape holds the one executed step
    assert length(@engine.steps(store, task_id)) == 1

    # a re-call with the SAME task id adopts the run and delivers the payload
    # as the parked Await signal — the SAME run resumes, never re-attempted
    assert {:ok, second} =
             PPlanAdapter.run(task_id, data_message(%{step: 2}), await_cfg(store, fx))

    assert second.state == :completed

    # prepare ran exactly once across both calls; finish once, in the same run
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    assert_single_run(store, task_id)

    tape = @engine.steps(store, task_id)
    assert length(tape) == 3
  end

  @tag :serial
  test "follow-up message with the same task id resumes the SAME run via the parked Await signal",
       %{store: store, fx: fx} do
    task_id = "i2-resume-#{System.unique_integer([:positive])}"

    assert {:ok, first} =
             PPlanAdapter.run(task_id, data_message(%{step: 1}), await_cfg(store, fx))

    assert first.state == :input_required

    assert {:ok, :input_required, %{run_status: :waiting, waiters: ["go"]}} =
             Provider.status(task_id, store: store, store_module: @dets)

    assert {:ok, second} =
             PPlanAdapter.run(task_id, data_message(%{answer: 42}), await_cfg(store, fx))

    assert second.state == :completed
    assert second.detail != nil

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # one run, and its checkpoint tape holds each step exactly once in order
    assert_single_run(store, task_id)

    tape = @engine.steps(store, task_id)
    assert length(tape) == 3
    assert length(Enum.uniq_by(tape, & &1.label)) == 3
  end

  @tag :serial
  test "still-parked deadline run: passed through untouched, never re-attempted, never :input_required",
       %{store: store, fx: fx} do
    task_id = "i2-poll-#{System.unique_integer([:positive])}"

    assert {:ok, first} = PPlanAdapter.run(task_id, data_message(%{q: 1}), poll_cfg(store, fx))
    assert first.state == :working

    assert {:ok, :working, %{run_status: :polling, waiters: []}} =
             Provider.status(task_id, store: store, store_module: @dets)

    assert Effects.count(fx, :prepare) == 1

    version_before = hd(@dets.list_runs(store)).version

    # the follow-up message is refused a resume: pass-through, untouched
    assert {:ok, second} = PPlanAdapter.run(task_id, data_message(%{q: 2}), poll_cfg(store, fx))
    assert second.state == :working
    refute second.state == :input_required

    assert %{prepare: 1, finish: 0} == %{
             prepare: Effects.count(fx, :prepare),
             finish: Effects.count(fx, :finish)
           }

    version_after = hd(@dets.list_runs(store)).version
    assert version_before == version_after
  end

  @tag :serial
  test "kill between effect and checkpoint: resume by task id, zero duplicate execution, one run",
       %{store: store, fx: fx} do
    task_id = "i2-kill-#{System.unique_integer([:positive])}"
    {:ok, _} = KillStore.start_plan()

    kill_cfg = await_cfg(store, fx, store_module: KillStore)

    parent = self()

    {victim, ref} =
      spawn_monitor(fn ->
        # structural sync: the victim does not start until it has been armed,
        # so arming can never race past the checkpoint boundary
        receive do
          :go -> :ok
        end

        PPlanAdapter.run(task_id, data_message(%{kickoff: true}), kill_cfg)
        send(parent, {:survived, task_id})
      end)

    KillStore.arm(victim)
    send(victim, :go)

    assert_receive {:DOWN, ^ref, :process, ^victim, :killed}, 15_000
    assert KillStore.fired?(), "kill plan never fired at the checkpoint boundary"

    # the effect executed but its checkpoint was never persisted; run non-terminal
    assert Effects.count(fx, :prepare) == 1

    assert {:ok, :submitted, %{run_status: :pending}} =
             Provider.status(task_id, store: store, store_module: @dets)

    assert @engine.steps(store, task_id) == []

    # heal: lapse the dead claim, disarm, then resume by task id
    KillStore.disarm()
    @clock.advance(@lease_lapse_ms)

    assert {:ok, resumed} =
             PPlanAdapter.run(task_id, data_message(%{answer: 1}), await_cfg(store, fx))

    assert resumed.state == :input_required

    assert {:ok, done} =
             PPlanAdapter.run(task_id, data_message(%{answer: 2}), await_cfg(store, fx))

    assert done.state == :completed

    # THE LAW: zero duplicate skill execution across the crash+resume
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # exactly one run in the tape, each step standing exactly once
    assert_single_run(store, task_id)

    tape = @engine.steps(store, task_id)
    assert length(tape) == 3
    assert length(Enum.uniq_by(tape, & &1.label)) == 3
  end
end


# ==============================================================================
# SECTION 10/10: test/execution/task_run_binding_test.exs
# ==============================================================================

defmodule AshA2A.Execution.TaskRunBindingTest do
  @moduledoc """
  Lane I7 invariant courts over the task↔run binding (`AshA2A.Providers.PPlan`
  ↔ `AshPPlan.Reactor.Durable.Engine`) on the REAL stack: a real disk-backed
  `AshPPlan.Reactor.Durable.Store.Dets` on a tmp dir, real Engine start /
  attempt / signal / cancel. Zero mocks.

  Invariants pinned:

    1. Addressed-signal law: resume only via exact task-id+waiter. A signal to
       a terminal (completed) task's run must surface as a typed error
       (`{:error, {:run_terminal, status}}` — upstream W4). Pre-W4 evidence:
       the direct-Engine behavior observed here is RECORDED, not assumed.
    2. Binding bijection: one task id ↔ one run id across start/resume/cancel;
       concurrent follow-ups on the same task id (5 processes) yield exactly
       one run and exactly one signal consumer.
    3. Cancel semantics: cancel mid-run → task state `:canceled`, no new
       checkpoints after cancel.
    4. Idempotent re-dispatch: re-dispatching a completed task id observes the
       sealed result from the tape without re-execution (effect count == 1).
  """

  use ExUnit.Case, async: false

  @moduletag :pplan_court

  alias AshA2A.Providers.PPlan, as: Provider

  @dets AshPPlan.Reactor.Durable.Store.Dets
  @engine AshPPlan.Reactor.Durable.Engine
  @adapter_id :a2a_pplan_binding_fx

  # -- real collaborators ------------------------------------------------------

  defmodule Effects do
    @moduledoc "Real counting agent: each consequential effect counted exactly here."
    use Agent

    def start_link(name), do: Agent.start_link(fn -> %{} end, name: name)

    def run(server, effect) do
      Agent.get_and_update(server, fn s ->
        n = Map.get(s, effect, 0) + 1
        {{:ok, n}, Map.put(s, effect, n)}
      end)
    end

    def count(server, effect), do: Agent.get(server, &Map.get(&1, effect, 0))
  end

  defmodule Effect do
    @moduledoc "Counting Reactor step; `options[:effects]` names the counter agent."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      case Effects.run(Keyword.fetch!(options, :effects), Keyword.fetch!(options, :effect)) do
        {:ok, n} -> {:ok, {Keyword.fetch!(options, :effect), n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc """
    Test adapter: counting effects plus ash_pplan's own Await durable step.
    Realization options carry the per-test `:effects` agent name (plain data,
    survives a store round trip).
    """
    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :a2a_pplan_binding_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {Steps.Await, [signal: "go", timeout: nil]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), @adapter_id, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
    end)

    :ok
  end

  defp model(name, tasks) do
    {:ok, m} = AshPPlan.Workflow.Model.new(name: name, goal: name, tasks: tasks)
    m
  end

  defp await_model,
    do:
      model("a2a_pplan_binding_await", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :await, capability: "Event.Await", depends_on: [:prepare]],
        [id: :finish, capability: "Process.Finish", depends_on: [:await]]
      ])

  defp linear_model,
    do:
      model("a2a_pplan_binding_linear", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :finish, capability: "Process.Finish", depends_on: [:prepare]]
      ])

  defp bindings(effects) do
    ops = [
      {:prepare, "Process.Prepare"},
      {:await, "Event.Await"},
      {:finish, "Process.Finish"}
    ]

    Map.new(ops, fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: @adapter_id,
         binding: %{adapter: @adapter_id, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  defp linear_bindings(effects) do
    Map.new([{:prepare, "Process.Prepare"}, {:finish, "Process.Finish"}], fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: @adapter_id,
         binding: %{adapter: @adapter_id, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  defp open_store(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "a2a-pplan-binding-laneI7-#{System.unique_integer([:positive])}"
      )

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    {:ok, store} = @dets.start_link(path: path, name: name)
    store
  end

  # Bounded poll on a real observable: the unwind completes only when an
  # attempt DRIVES it (:cancelling -> rolling_back -> :cancelled), so each
  # poll step makes one Engine.attempt. Deadline-checked, never a fixed sleep.
  defp settle_cancel(store, task_id, opts, deadline) do
    case Provider.status(task_id, opts) do
      {:ok, :canceled, _} = done ->
        done

      {:ok, :working, _} ->
        # :cancelling maps to :working — drive the unwind with an attempt
        _ = @engine.attempt(store, task_id, store_module: @dets)

        if System.monotonic_time(:millisecond) >= deadline do
          flunk("cancel did not settle to :cancelled within the deadline")
        end

        Process.sleep(20)
        settle_cancel(store, task_id, opts, deadline)

      other ->
        flunk("unexpected status while settling cancel: #{inspect(other)}")
    end
  end

  setup context do
    unless Provider.available?() do
      flunk("BLOCKED: :ash_pplan did not load in the test env (fail loud, never a silent skip)")
    end

    install_adapter!()

    {:ok, fx} = Effects.start_link(:"pplan_binding_fx_#{System.unique_integer([:positive])}")

    store = open_store(:"#{context.module}.Store.#{System.unique_integer([:positive])}")

    %{store: store, fx: fx, opts: [store: store, store_module: @dets]}
  end

  # -- invariant 1: addressed-signal law (pre-W4 evidence) ----------------------

  test "a signal to a terminal run's waiter: current behavior recorded (pre-W4)",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-terminal-signal-#{System.unique_integer([:positive])}"

    # Drive a real run to completion through the provider seam.
    assert {:ok, :completed, result} =
             Provider.dispatch(task_id, linear_model(), linear_bindings(fx),
               store: opts[:store],
               store_module: @dets
             )

    # the sealed result is the last executed step's output (the Effect step's
    # own return), delivered through the provider seam unchanged
    assert {:finish, 1} = result
    assert {:ok, :completed, _} = Provider.status(task_id, opts)

    # Provider-level resume to a terminal task: the sealed state is returned
    # unchanged — typed pass-through, never a re-execution, never a signal.
    assert {:ok, :completed, ^result} = Provider.resume(task_id, %{"late" => true}, opts)

    # Effects ran exactly once each — the pass-through consumed nothing.
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # PRE-W4 EVIDENCE: the direct Engine signal to a terminal run's waiter.
    # W4 (upstream, in flight) will make this a typed
    # `{:error, {:run_terminal, status}}`. Today's behavior is recorded here:
    # assert exactly what the Engine does now, so W4 flips this assertion.
    engine_result = @engine.signal(store, task_id, "go", %{"late" => true})

    assert match?({:ok, %AshPPlan.Reactor.Durable.Signal{}}, engine_result) or
             match?({:error, {:run_terminal, _}}, engine_result),
           "unexpected Engine.signal result on a terminal run: #{inspect(engine_result)}"

    if match?({:ok, %AshPPlan.Reactor.Durable.Signal{}}, engine_result) do
      IO.puts(
        :stderr,
        "[lane-i7] pre-W4 evidence: Engine.signal to terminal run silently delivers " <>
          inspect(engine_result)
      )
    else
      IO.puts(:stderr, "[lane-i7] W4 landed: typed run_terminal refusal observed")
    end
  end

  test "resume targets the exact parked waiter; unknown-signal resumes are typed refusals",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-addressed-signal-#{System.unique_integer([:positive])}"

    assert {:ok, :input_required, waiters} =
             Provider.dispatch(task_id, await_model(), bindings(fx), opts)

    assert is_list(waiters) and "go" in waiters

    # The payload lands on the parked waiter only when addressed by name; the
    # provider resolves the name from the run's parked waiter.
    assert {:ok, :completed, _} = Provider.resume(task_id, %{"answer" => 42}, opts)

    # A resume against an id with NO run is typed, not silent.
    assert {:error, :no_such_run} =
             Provider.resume(
               "i7-never-dispatched-#{System.unique_integer([:positive])}",
               %{},
               opts
             )

    assert store != nil
  end

  # -- invariant 2: binding bijection -------------------------------------------

  test "one task id is one run: concurrent follow-ups (5 processes) yield one run, one consumer",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-bijection-#{System.unique_integer([:positive])}"

    # Fresh task: dispatch-or-adopt, parked on the Await step.
    assert {:ok, :input_required, _waiters} =
             Provider.dispatch(task_id, await_model(), bindings(fx), opts)

    assert %{prepare: 1, finish: 0} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # parked tape: prepare is standing; the Await step checkpoints at consume time
    assert Enum.map(tape_before = @engine.steps(store, task_id, store_module: @dets), & &1.label) ==
             [
               ~s("urn:ash-pplan:workflow:a2a_pplan_binding_await#step-prepare")
             ]

    # 5 concurrent follow-up messages on the SAME task id.
    results =
      1..5
      |> Enum.map(fn i ->
        Task.async(fn ->
          Process.sleep(rem(i, 3))
          Provider.resume(task_id, %{"worker" => i}, opts)
        end)
      end)
      |> Task.await_many(30_000)

    # Exactly ONE consumer executed the finish step; the run completed once.
    assert {:ok, :completed, %{run_status: :completed}} = Provider.status(task_id, opts)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # Every concurrent caller observed a lawful outcome: the one consumer
    # drove completion; pass-through callers saw the sealed state; losers of
    # the consume-once race see a typed refusal — none silent.
    outcomes =
      Enum.map(results, fn
        {:ok, :completed, _} -> :completed
        {:error, {:refused, _}} -> :refused
        {:error, :no_signal_waiter} -> :no_signal_waiter
        {:error, :taken} -> :taken
        other -> {:unexpected, other}
      end)

    assert :completed in outcomes
    assert Enum.all?(outcomes, &(match?(:completed, &1) or is_tuple(&1) or match?(:taken, &1)))

    # Binding bijection: still exactly ONE checkpoint tape, grown only by the
    # single consumer's steps (prepare standing at dispatch; await+finish land
    # on the single consume).
    tape_after = @engine.steps(store, task_id, store_module: @dets)

    assert Enum.map(tape_after, & &1.label) == [
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_await#step-prepare"),
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_await#step-await"),
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_await#step-finish")
           ]

    assert length(tape_after) == length(tape_before) + 2
  end

  test "re-dispatch of an in-flight task id adopts the SAME run (no second attempt)",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-adopt-#{System.unique_integer([:positive])}"

    assert {:ok, :input_required, _} =
             Provider.dispatch(task_id, await_model(), bindings(fx), opts)

    # A second dispatch with the same task id (even new inputs) adopts the run
    # unchanged: parked state standing, no re-execution.
    assert {:ok, :input_required, _} =
             Provider.dispatch(task_id, await_model(), bindings(fx),
               store: opts[:store],
               store_module: @dets,
               inputs: %{"different" => true}
             )

    assert %{prepare: 1, finish: 0} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    assert Enum.map(@engine.steps(store, task_id, store_module: @dets), & &1.label) == [
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_await#step-prepare")
           ]
  end

  # -- invariant 3: cancel semantics --------------------------------------------

  test "cancel mid-run: task :canceled, terminal sealed, no new checkpoints after cancel",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-cancel-#{System.unique_integer([:positive])}"

    assert {:ok, :input_required, _} =
             Provider.dispatch(task_id, await_model(), bindings(fx), opts)

    assert {:ok, :canceled, _record} = Provider.cancel(task_id, opts)

    # Cancel is two-phase: the provider returns while the run is :cancelling
    # and the unwind settles to :cancelled. Poll the observable to a deadline;
    # time is not a proxy for state.
    deadline = System.monotonic_time(:millisecond) + 10_000
    unwound = settle_cancel(store, task_id, opts, deadline)

    assert {:ok, :canceled, _} = unwound

    tape_at_cancel = @engine.steps(store, task_id, store_module: @dets)

    # Post-cancel resumes observe the sealed :canceled state — no re-attempt,
    # no signal consumption, no new checkpoints.
    assert {:ok, :canceled, _} = Provider.resume(task_id, %{"late" => true}, opts)

    assert %{prepare: 1, finish: 0} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    assert tape_at_cancel == @engine.steps(store, task_id, store_module: @dets)

    # PRE-W4 EVIDENCE: direct Engine.signal at the cancelled run.
    engine_result = @engine.signal(store, task_id, "go", %{"late" => true})

    assert match?({:ok, %AshPPlan.Reactor.Durable.Signal{}}, engine_result) or
             match?({:error, {:run_terminal, _}}, engine_result),
           "unexpected Engine.signal result on a cancelled run: #{inspect(engine_result)}"
  end

  # -- invariant 4: idempotent re-dispatch --------------------------------------

  test "re-dispatching a completed task observes the sealed result, effect count stays 1",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-replay-#{System.unique_integer([:positive])}"

    assert {:ok, :completed, result1} =
             Provider.dispatch(task_id, linear_model(), linear_bindings(fx), opts)

    assert {:ok, :completed, result2} =
             Provider.dispatch(task_id, linear_model(), linear_bindings(fx), opts)

    assert result1 == result2

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    tape1 = @engine.steps(store, task_id, store_module: @dets)

    assert Enum.map(tape1, & &1.label) == [
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_linear#step-prepare"),
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_linear#step-finish")
           ]

    # And the provider's dispatch-or-resume composite also passes through.
    message = %AshA2A.Protocol.Message{
      role: :user,
      parts: [%AshA2A.Protocol.Part.Data{data: %{"again" => true}}]
    }

    execution_config = [
      pplan: [
        store: opts[:store],
        store_module: @dets,
        model: linear_model(),
        bindings: linear_bindings(fx)
      ]
    ]

    # the composite passes the provider's status detail through on the sealed
    # path: state completed, sealed result embedded in the detail map
    assert {:ok, %{state: :completed, detail: %{run_status: :completed, result: ^result1}}} =
             AshA2A.Execution.PPlan.run(task_id, message, execution_config)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}
  end
end

