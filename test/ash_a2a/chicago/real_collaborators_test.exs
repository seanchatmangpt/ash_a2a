defmodule AshA2A.Chicago.RealCollaboratorsTest do
  @moduledoc """
  Gate 3 (RFC-SA2A-002 §9, §10, §34) qualified Chicago style: the real
  `AshA2A.Chicago.Runner`, the real `AshA2A.Chicago.Courts.RealCollaborators`
  court, the real GraphLaw wasm executed by real `node` hosts, real receipt
  store processes really restarted, real EKV on disk, the real authority grant
  path, and a real OCEL artifact read back by the independent consumer.

  `async: false`: the court mutates application configuration for the length
  of one stimulus, and the observer attributes telemetry by stimulus window.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago.{Collaborators, Query, Runner}
  alias AshA2A.Chicago.Collaborators.{DurabilityProbe, MockScan}
  alias AshA2A.Chicago.Courts.RealCollaborators
  alias AshA2A.Chicago.Fixtures.RealCollaborators, as: Fixtures
  alias AshA2A.Semantic.Refusal

  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag timeout: 600_000

  describe "CHI-REAL court end to end through the runner" do
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} =
               Runner.run(courts: [RealCollaborators], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      expected = %{
        "CHI-REAL-001" => :falsifier_killed,
        "CHI-REAL-002" => :falsifier_killed,
        "CHI-REAL-003" => :falsifier_killed,
        "CHI-REAL-004" => :falsifier_killed,
        "CHI-REAL-005" => :falsifier_killed,
        "CHI-REAL-006" => :falsifier_killed,
        "CHI-REAL-007" => :falsifier_killed,
        "CHI-REAL-008" => :positive_control_passed,
        "CHI-REAL-009" => :positive_control_passed,
        "CHI-REAL-010" => :positive_control_passed,
        "CHI-REAL-011" => :falsifier_killed
      }

      assert Map.keys(by_id) |> Enum.sort() == Map.keys(expected) |> Enum.sort()

      for {id, verdict} <- expected do
        result = by_id[id]

        assert result.verdict == verdict,
               "#{id}: #{inspect(result.verdict)} -- #{result.detail} -- #{result.ocel_detail}"

        assert result.attempt_observed? == true, id
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      assert run.ocel.dropped == 0

      gate3 = Enum.find(run.receipt["gates"], &(&1["gate"] == 3))
      assert gate3["status"] == "PASSED"
      assert gate3["courts"] == ["CHI-REAL"]

      # The independent consumer re-derives the key facts from disk alone.
      {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-REAL-001",
                 {:observed, "chicago.collaborators.violation",
                  %{"code" => "authority_not_real_boundary"}}
               )

      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-REAL-004",
                 {:observed, "chicago.collaborators.durability_probe",
                  %{
                    "store" => inspect(Fixtures.LossyDurableStore),
                    "stage" => "read",
                    "outcome" => "missing"
                  }}
               )

      assert {false, _} =
               Query.eval(index, "CHI-REAL-008", {:observed, "chicago.collaborators.violation"})
    end
  end

  describe "inventory of the real running configuration" do
    test "identifies all nine roles with the real components and admits them", %{tmp_dir: dir} do
      inv = Collaborators.inventory(claim: :core, probe_dir: dir)

      assert inv.scope == :full
      assert Map.keys(inv.roles) |> Enum.sort() == Enum.sort(Collaborators.roles())
      assert inv.violations == [], inspect(inv.violations, pretty: true)
      assert inv.verdict == :admitted

      engine = inv.roles.semantic_engine
      assert engine.module == AshA2A.GraphLaw.Wasm
      assert engine.digest_bound?
      assert engine.wasm_sha256 == engine.manifest_sha256
      assert engine.version == engine.manifest_version
      assert engine.agrees_with_reference?
      assert engine.port.real?

      assert inv.roles.admission_pipeline.engine_calls |> Enum.member?("batch/2")
      assert inv.roles.authority_broker.policy == :broker
      assert inv.roles.authority_broker.module == AshA2A.Authority.Broker.InMemory
      assert inv.roles.authority_broker.fail_closed_proven?
      assert inv.roles.consequence_boundary.actuator_calls == ["dispatch/5"]
      assert inv.roles.receipt_store.module == AshA2A.CommandBus.default_store()
      assert inv.roles.independent_verifier.module == AshA2A.Chicago.Query
      assert inv.mock_scan.outcome == :clean
      assert inv.mock_scan.dirs == ["lib", "test"]
    end

    test "under a :do claim the default in-memory store is refused, not assumed durable", %{
      tmp_dir: dir
    } do
      inv =
        Collaborators.inventory(
          claim: :do,
          roles: [:receipt_store],
          scan: false,
          receipt_store: AshA2A.ReceiptStore.Memory,
          probe_dir: dir
        )

      assert inv.verdict == :refused
      assert Collaborators.violation?(inv, :receipt_store_not_durable)
      refute inv.roles.receipt_store.proven_durable?
    end

    test "its violation codes classify without editing the Refusal table" do
      for {code, class} <- Collaborators.__sa2a_refusal_codes__() do
        assert Refusal.classify(code) == class
      end
    end
  end

  describe "DurabilityProbe proves durability by real restart" do
    test "EKV keeps the write across a real restart and replays it", %{tmp_dir: dir} do
      result = DurabilityProbe.run(AshA2A.ReceiptStore.Ekv, probe_dir: dir)

      assert %{write: :committed, restarted?: true, read: :found, replay: :replay} = result
      assert result.proven?
    end

    test "the in-memory store loses the write across a real restart", %{tmp_dir: dir} do
      result = DurabilityProbe.run(AshA2A.ReceiptStore.Memory, probe_dir: dir)

      assert %{write: :committed, restarted?: true, read: :missing} = result
      refute result.proven?
    end

    test "a store that declares durable?() true but keeps writes in memory is not proven", %{
      tmp_dir: dir
    } do
      assert Fixtures.LossyDurableStore.durable?()
      result = DurabilityProbe.run(Fixtures.LossyDurableStore, probe_dir: dir)

      assert %{write: :committed, restarted?: true, read: :missing, proven?: false} = result
    end

    test "a store module with no startable process is UNKNOWN, never durable" do
      result = DurabilityProbe.run(AshA2A.Chicago.Query)

      assert result.lifecycle == :unsupported
      refute result.proven?
      assert result.detail =~ "child_spec/1"
    end
  end

  describe "MockScan reads the AST, not the text" do
    test "reports each real mocking call with its line" do
      source = """
      defmodule T do
        import Mox
        def a, do: Mox.expect(M, :f, fn -> 1 end)
        def b, do: :meck.new(M, [])
        def c, do: &:meck.unload/1
        def d, do: apply(Mox, :stub, [M, :f, 1])
        def e, do: patch(M, :f, 1)
        def f do
          with_mocks([{M, [], []}]) do
            :ok
          end
        end
      end
      """

      assert {:ok, found} = MockScan.scan_source(source, "t.ex")

      assert Enum.map(found, &{&1.line, &1.call}) == [
               {2, "import Mox"},
               {3, "Mox.expect/3"},
               {4, ":meck.new/2"},
               {5, "&:meck.unload/1"},
               {6, "apply(Mox, :stub, ...)"},
               {7, "patch/3"},
               {9, "with_mocks/2"}
             ]
    end

    test "comments, docs, strings, sigils, atoms and HTTP patch are not calls" do
      source = ~S'''
      defmodule T do
        @moduledoc "Mox.expect(M, :f, 1) and :meck.new(M)"
        # with_mock M, [] do end
        @libs [:meck, Mox, Mock]
        def a, do: "import Mox"
        def b, do: ~S[Mox.stub(M, :f, 1)]
        def c(conn), do: patch(conn, "/x", %{})
        def libs, do: @libs
      end
      '''

      assert {:ok, []} = MockScan.scan_source(source, "t.ex")
    end

    test "unparseable source fails closed with its location" do
      assert {:error, %{file: "bad.ex", line: line}} =
               MockScan.scan_source("defmodule Bad do\n  def x(, do: 1\nend\n", "bad.ex")

      assert line >= 1
    end

    test "this repository's own lib/ and test/ contain no mocking calls" do
      scan = MockScan.scan(root: File.cwd!())

      assert scan.dirs == ["lib", "test"]
      assert scan.files > 100
      assert scan.violations == [], inspect(scan.violations, pretty: true)
      assert scan.unparseable == [], inspect(scan.unparseable, pretty: true)
      assert scan.outcome == :clean
    end
  end

  describe "boundary telemetry added for gate 3" do
    test "Grant.authorize/3 reports the decision it made" do
      ref = make_ref()
      test_pid = self()
      handler = {__MODULE__, ref}

      :ok =
        :telemetry.attach(
          handler,
          [:ash_a2a, :authority, :decision],
          fn _event, _measurements, metadata, _ -> send(test_pid, {ref, metadata}) end,
          nil
        )

      try do
        nonce = System.unique_integer([:positive])
        assert AshA2A.Authority.Grant.authorize("nobody-#{nonce}", "cap-#{nonce}") == nil
        assert_receive {^ref, %{outcome: :refused, policy: :broker, capability_id: capability}}
        assert capability == "cap-#{nonce}"
      after
        :telemetry.detach(handler)
      end
    end
  end
end
