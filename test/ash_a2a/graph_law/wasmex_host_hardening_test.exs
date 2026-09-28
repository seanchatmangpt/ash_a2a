defmodule AshA2A.GraphLaw.WasmexHostHardeningTest do
  @moduledoc """
  Chicago-school courts for the production hardening of the in-BEAM GraphLaw
  host (SC-04, PERF-02, PERF-04, PERF-05, PERF-06, PERF-07, PERF-08).

  Every assertion runs the REAL vendored `praxis_graphlaw.wasm` in REAL
  Wasmtime instances; substituted artifacts are real bytes written to a real
  tmp dir. Nothing is mocked. `async: false` because some cases change
  application env (`:graphlaw_max_queue`) or count engine telemetry events.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :tmp_dir

  alias AshA2A.GraphLaw.{EngineLoad, EngineTelemetry, WasmexHost, WasmexPool, WasmexSession}
  alias AshA2A.Semantic.{CanonicalDigest, GraphLaw, GraphLawBridge}

  @base_ttl "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:c .\n"
  @base_digest "9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d"

  defp vendored, do: AshA2A.GraphLaw.wasm_path()

  # A valid wasm module with the same code and imports as the pinned artifact,
  # but different bytes: one appended custom section (id 0, name "x",
  # payload "y"). Custom sections are ignored by the engine, so only the
  # digest pin can tell the two apart.
  defp substituted_wasm!(dir) do
    path = Path.join(dir, "substituted.wasm")
    File.write!(path, File.read!(vendored()) <> <<0, 3, 1, ?x, ?y>>)
    path
  end

  defp unique_name(tag),
    do: Module.concat(__MODULE__, "#{tag}#{System.unique_integer([:positive])}")

  defp start_host(opts) do
    name = unique_name("Host")
    pid = start_supervised!({WasmexHost, [name: name] ++ opts}, id: name)
    {name, pid}
  end

  defp big_ttl(n) do
    body = Enum.map_join(1..n, "\n", fn i -> "ex:s#{i} ex:p ex:o#{i + 1} ." end)
    "@prefix ex: <http://example.org/> .\n" <> body <> "\n"
  end

  describe "SC-04 digest pin" do
    test "a substituted artifact is refused by the pinned host, loads only when unpinned",
         %{tmp_dir: dir} do
      path = substituted_wasm!(dir)
      pinned = EngineLoad.pinned_sha256()

      {name, _pid} = start_host(wasm_path: path)

      assert {:error, %{code: :graphlaw_wasm_digest_mismatch, expected: ^pinned, actual: actual}} =
               GenServer.call(name, :status)

      assert actual != pinned

      assert WasmexHost.graph_hash(@base_ttl, name) |> elem(1) |> Map.get(:code) ==
               :graphlaw_wasm_digest_mismatch

      {open, _} = start_host(wasm_path: path, expected_sha256: :unpinned)
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, open)
    end

    test "the vendored artifact matches the MANIFEST pin and the pin is classified" do
      bytes = File.read!(vendored())

      assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) ==
               EngineLoad.pinned_sha256()

      assert {:ok, %{wasm_sha256: sha}} = EngineLoad.load("test", bytes)
      assert sha == EngineLoad.pinned_sha256()

      assert {:error, %{code: :graphlaw_wasm_digest_mismatch}} =
               EngineLoad.load("test", bytes <> <<0, 3, 1, ?x, ?y>>)

      assert AshA2A.Semantic.Refusal.classify(:graphlaw_wasm_digest_mismatch) ==
               :refused_identity
    end

    test "a session on the vendored path is pinned; a named foreign path is the caller's choice",
         %{tmp_dir: dir} do
      path = substituted_wasm!(dir)

      assert {:error, %{code: :graphlaw_wasm_digest_mismatch}} =
               WasmexSession.open(wasm_path: path, expected_sha256: EngineLoad.pinned_sha256())

      assert {:ok, %{session: session}} = WasmexSession.open(wasm_path: path)
      WasmexSession.close(session)
    end

    test "the peer (node) transport is pinned too, so a refused host cannot fall back to swapped bytes",
         %{tmp_dir: dir} do
      path = substituted_wasm!(dir)
      peer = AshA2A.Semantic.GraphLaw.Wasm
      previous = Application.get_env(:ash_a2a, peer)

      # Not named by the operator (an ambient GRAPHLAW_WASM, or the vendored
      # file itself swapped): held to the MANIFEST pin.
      assert {:error, %{code: :graphlaw_wasm_digest_mismatch}} = peer.check_pin(path)
      assert :ok = peer.check_pin(vendored())

      # The call path itself consults the pin (this module is async: false and
      # restores any value the developer had set).
      previous_env = System.get_env("GRAPHLAW_WASM")

      if is_binary(System.find_executable("node")) and is_nil((previous || [])[:wasm_path]) do
        try do
          System.put_env("GRAPHLAW_WASM", path)

          assert {:error, %{code: :graphlaw_wasm_digest_mismatch}} =
                   peer.graph_hash(@base_ttl)
        after
          if previous_env,
            do: System.put_env("GRAPHLAW_WASM", previous_env),
            else: System.delete_env("GRAPHLAW_WASM")
        end
      end

      try do
        # Named explicitly by the operator: the operator's choice of bytes.
        Application.put_env(:ash_a2a, peer, Keyword.put(previous || [], :wasm_path, path))
        assert :ok = peer.check_pin(path)

        if System.find_executable("node") do
          assert {:ok, @base_digest} = peer.graph_hash(@base_ttl)
        end
      after
        if previous,
          do: Application.put_env(:ash_a2a, peer, previous),
          else: Application.delete_env(:ash_a2a, peer)
      end

      assert AshA2A.Semantic.Refusal.classify(:graphlaw_wasm_digest_mismatch) == :refused_identity
    end

    test "a session path that arrived through configuration is pinned, not the caller's choice",
         %{tmp_dir: dir} do
      path = substituted_wasm!(dir)
      previous_path = Application.get_env(:ash_a2a, :graphlaw_wasm_path)
      previous_sha = Application.get_env(:ash_a2a, :graphlaw_wasm_sha256)

      restore = fn key, previous ->
        if previous,
          do: Application.put_env(:ash_a2a, key, previous),
          else: Application.delete_env(:ash_a2a, key)
      end

      try do
        Application.put_env(:ash_a2a, :graphlaw_wasm_path, path)
        Application.delete_env(:ash_a2a, :graphlaw_wasm_sha256)

        assert {:error, %{code: :graphlaw_wasm_digest_mismatch, path: ^path}} =
                 WasmexSession.open([])

        # The operator's explicit opt-out for a configured rebuild.
        Application.put_env(:ash_a2a, :graphlaw_wasm_sha256, :unpinned)
        assert {:ok, %{session: session}} = WasmexSession.open([])
        WasmexSession.close(session)
      after
        restore.(:graphlaw_wasm_path, previous_path)
        restore.(:graphlaw_wasm_sha256, previous_sha)
      end
    end
  end

  describe "PERF-02 compiled-module cache" do
    test "a warm open costs an instantiation, not a compile; sessions stay isolated" do
      {:ok, %{session: warm}} = WasmexSession.open(fuel: 1_000_000_000)
      WasmexSession.close(warm)
      assert EngineLoad.cached?(EngineLoad.pinned_sha256(), true)

      timings =
        for _ <- 1..3 do
          {us, {:ok, %{session: s}}} =
            :timer.tc(fn -> WasmexSession.open(fuel: 1_000_000_000) end)

          WasmexSession.close(s)
          us
        end

      # A Cranelift compile of this module measured 1.04-1.22 s per open.
      assert Enum.max(timings) < 300_000, "warm opens took #{inspect(timings)} us"

      {:ok, %{session: a}} = WasmexSession.open(fuel: 5_000_000_000)
      {:ok, %{session: b}} = WasmexSession.open(fuel: 5_000_000_000)

      try do
        assert a.store != b.store and a.pid != b.pid
        fuel_a = WasmexSession.fuel_remaining(a)
        fuel_b = WasmexSession.fuel_remaining(b)
        assert {:ok, @base_digest} = WasmexSession.call(a, :graph_hash, [@base_ttl])
        # Only a's own store paid for a's call.
        assert WasmexSession.fuel_remaining(a) < fuel_a
        assert WasmexSession.fuel_remaining(b) == fuel_b
      after
        WasmexSession.close(a)
        WasmexSession.close(b)
      end
    end
  end

  describe "PERF-04 a timed-out call never kills the host" do
    test "native interrupt returns a typed error, the host recycles in-process and keeps serving" do
      {name, pid} = start_host([])
      ref = Process.monitor(pid)
      ttl = big_ttl(3_000)

      assert {:error, %{code: code}} = WasmexHost.validate_all(ttl, "", "", "", "", name, 1)
      assert code in [:graphlaw_call_failed, :graphlaw_call_exited]
      refute_received {:DOWN, ^ref, _, _, _}
      assert Process.alive?(pid)

      assert {:ok, %{recycles: recycles}} = WasmexHost.info(name)
      assert recycles >= 1
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, name)
    end
  end

  describe "PERF-05 fuel and memory bounds" do
    test "a call that exhausts the per-transaction fuel budget is a typed error, not a hang" do
      {name, pid} = start_host(fuel: 10_000)
      assert {:error, %{code: :graphlaw_call_failed}} = WasmexHost.graph_hash(@base_ttl, name)
      assert Process.alive?(pid)
    end

    test "fuel is reset per transaction, so a sufficient budget serves repeated calls" do
      {name, _pid} = start_host(fuel: 2_000_000_000)

      for _ <- 1..5 do
        assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, name)
      end
    end

    test "crossing the memory high-water mark recycles the instance" do
      {name, _pid} = start_host(recycle_bytes: 1)
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, name)
      assert {:ok, %{recycles: 1}} = WasmexHost.info(name)
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, name)
      assert {:ok, %{recycles: 2}} = WasmexHost.info(name)
    end
  end

  describe "PERF-06 pool and load shedding" do
    test "a pool runs N independent hosts over one compiled module" do
      registry = unique_name("Registry")
      sup = unique_name("Pool")

      start_supervised!(
        {WasmexPool, name: sup, registry: registry, size: 3, host_name: nil},
        id: sup
      )

      members = WasmexPool.members(registry)
      assert length(Enum.uniq(members)) == 3
      assert WasmexPool.pick(registry) in members

      results =
        members
        |> Enum.flat_map(&List.duplicate(&1, 4))
        |> Task.async_stream(&WasmexHost.graph_hash(@base_ttl, &1), max_concurrency: 12)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.uniq(results) == [{:ok, @base_digest}]
    end

    test "a restarted registry gets every member back" do
      registry = unique_name("Registry")
      sup = unique_name("Pool")

      start_supervised!(
        {WasmexPool, name: sup, registry: registry, size: 3, host_name: nil},
        id: sup
      )

      assert length(WasmexPool.members(registry)) == 3
      old = Process.whereis(registry)
      ref = Process.monitor(old)
      Process.exit(old, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old, :killed}, 5_000

      members =
        Enum.reduce_while(1..100, [], fn _, _ ->
          case WasmexPool.members(registry) do
            list when length(list) == 3 ->
              {:halt, list}

            list ->
              Process.sleep(50)
              {:cont, list}
          end
        end)

      assert length(members) == 3,
             "after a registry restart only #{length(members)} of 3 members are routable"

      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, WasmexPool.pick(registry))
    end

    test "a target at the queue bound is shed with :graphlaw_saturated" do
      {name, _pid} = start_host([])
      previous = Application.get_env(:ash_a2a, :graphlaw_max_queue)
      Application.put_env(:ash_a2a, :graphlaw_max_queue, 0)

      try do
        assert {:error, %{code: :graphlaw_saturated, max_queue: 0}} =
                 WasmexHost.graph_hash(@base_ttl, name)
      after
        if previous,
          do: Application.put_env(:ash_a2a, :graphlaw_max_queue, previous),
          else: Application.delete_env(:ash_a2a, :graphlaw_max_queue)
      end

      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, name)
    end
  end

  describe "PERF-01/07/08 admission path on the warm host" do
    test "the default semantic engine is the in-BEAM host and agrees with the node runtime" do
      assert GraphLaw.impl() == AshA2A.Semantic.GraphLaw.WasmexHost
      assert GraphLawBridge.host() == :in_beam

      {us, {:ok, beam}} = :timer.tc(fn -> GraphLaw.graph_hash(@base_ttl) end)
      assert beam == @base_digest
      assert us < 50_000, "in-BEAM graph_hash took #{us} us"

      if AshA2A.Semantic.GraphLaw.Wasm.available?() do
        assert {:ok, ^beam} = AshA2A.Semantic.GraphLaw.Wasm.graph_hash(@base_ttl)
      end
    end

    test "validate_all's report graph_hash equals graph_hash over the conformance corpus" do
      {:ok, doc} = AshA2A.GraphLaw.ConformanceVectors.load()

      corpus =
        (doc["vectors"]
         |> Enum.filter(&(&1["fn"] in ["graph_hash", "validate_all"]))
         |> Enum.map(&hd(&1["args"]))) ++
          Enum.map(Path.wildcard("priv/graphlaw/fixtures/*.ttl"), &File.read!/1) ++
          [@base_ttl, big_ttl(50)]

      assert length(corpus) >= 5

      for ttl <- Enum.uniq(corpus) do
        {:ok, hash} = GraphLaw.graph_hash(ttl)
        {:ok, report} = GraphLaw.validate(ttl, "")
        assert report["graph_hash"] == hash
      end
    end

    test "validate_many returns the same reports as per-pair validate, in order" do
      shapes = """
      @prefix sh: <http://www.w3.org/ns/shacl#> .
      @prefix ex: <http://example.org/> .
      ex:S a sh:NodeShape ; sh:targetSubjectsOf ex:p ; sh:property [ sh:path ex:q ; sh:minCount 1 ] .
      """

      pairs = [{@base_ttl, ""}, {@base_ttl, shapes}, {big_ttl(5), ""}]
      assert {:ok, many} = GraphLaw.validate_many(pairs)

      singles =
        Enum.map(pairs, fn {t, s} ->
          {:ok, r} = GraphLaw.validate(t, s)
          r
        end)

      strip = fn r -> Map.drop(r, ["timing", "elapsed_us"]) end
      assert Enum.map(many, strip) == Enum.map(singles, strip)
      assert Enum.map(many, &GraphLaw.verdict/1) |> Enum.at(1) |> elem(0) == :refused
    end

    test "canonical digest spends one engine call for :ntriples and two for :turtle" do
      triples = [
        %{
          subject: "http://example.org/a",
          predicate: "http://example.org/p",
          object: {:iri, "http://example.org/b"}
        }
      ]

      {:ok, _} = CanonicalDigest.canonical_digest(triples)
      {:ok, _} = CanonicalDigest.canonical_digest(triples, format: :turtle)

      count = fn fun ->
        parent = self()
        handler = "perf08-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler,
          EngineTelemetry.event(),
          fn _e, _m, meta, _ -> if meta.host == "BEAM/WasmexHost", do: send(parent, :call) end,
          nil
        )

        try do
          {:ok, digest} = fun.()
          {digest, drain(0)}
        after
          :telemetry.detach(handler)
        end
      end

      {nt, nt_calls} = count.(fn -> CanonicalDigest.canonical_digest(triples) end)

      {tt, tt_calls} =
        count.(fn -> CanonicalDigest.canonical_digest(triples, format: :turtle) end)

      assert nt_calls == 1
      assert tt_calls == 2
      assert nt.digest == tt.digest
    end
  end

  defp drain(n) do
    receive do
      :call -> drain(n + 1)
    after
      50 -> n
    end
  end
end
