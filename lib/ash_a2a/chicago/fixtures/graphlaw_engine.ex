defmodule AshA2A.Chicago.Fixtures.GraphlawEngine do
  @moduledoc """
  Real inputs, engine sessions, independent readers and OCEL mappings for the
  `SA2A-ENGINE` court (`AshA2A.Chicago.Courts.GraphlawEngine`).

  Every input is real Turtle / N3 text handed to the vendored
  `priv/graphlaw/praxis_graphlaw.wasm` through a real in-BEAM Wasmtime host.
  The same inputs are recorded, with the engine output each one produced, as
  minimal reproducers under `priv/graphlaw/defects/` (`reproducer/1`), so a
  defect report and the court that pins it can never drift apart.

  Independent readers never ask the engine: `event_asserts?/3` and `turtle?/1`
  parse with RDF.ex, and `rule_classification/1` classifies a rule document
  with `AshA2A.Semantic.LogicClosure.RuleDocument`.

  `foreign_surface_wasm!/1` is environment fault injection (§10): a real,
  valid wasm module declaring the exact host-import surface measured on the
  praxis HEAD build (`priv/graphlaw/defects/praxis-head-refresh.json`).
  """

  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.GraphLaw
  alias AshA2A.GraphLaw.{EngineLoad, EngineTelemetry, WasmexHost, WasmexSession}
  alias AshA2A.GraphLaw.Manifest
  alias AshA2A.Semantic.LogicClosure.RuleDocument

  @kh "@prefix kh: <http://seanchatmangpt.github.io/praxis/kh#> .\n"
  @ex "@prefix ex: <http://example.org/> .\n"
  @e "@prefix e: <http://example.org/e#> .\n"
  @math "@prefix math: <http://www.w3.org/2000/10/swap/math#> .\n"

  @status_iri "http://example.org/status"

  @doc "Fuel budget for bounded engine sessions (measured: a 3-edge transitive closure consumes ~9.1e6)."
  def fuel, do: 500_000_000

  @doc "The `kh:var` IRI the fixture hooks trigger on."
  def status_iri, do: @status_iri

  # --- inputs -------------------------------------------------------------------

  @doc "A delta hook (praxis-graphlaw-wasm's own `test_run_hooks_core_fires_expected_hook` shape)."
  def delta_hook_pack do
    @kh <>
      @ex <>
      ~s(ex:hook1 a kh:Hook ; kh:name "fire_hook" ; kh:kind "delta" ; kh:var "#{@status_iri}" ; kh:on "assert" ; kh:effect "emit-delta" .\n)
  end

  @doc "The same hook with IRI-valued properties (passes HookProps cleaning, fails the SHACL law pack)."
  def iri_hook_pack do
    @kh <>
      @ex <>
      "ex:hook1 a kh:Hook ; kh:name <fire_hook> ; kh:kind <delta> ; kh:var <#{@status_iri}> ; kh:on <assert> ; kh:effect <emit-delta> .\n"
  end

  @doc "An in-graph SPARQL hook over the same predicate."
  def sparql_hook_pack do
    @kh <>
      @ex <>
      ~s(ex:hook2 a kh:Hook ; kh:name "sparql_hook" ; kh:kind "sparql" ; kh:query "ASK { ?s <#{@status_iri}> ?o }" ; kh:effect "emit-delta" .\n)
  end

  @doc "An event asserting the hooked predicate."
  def matching_event, do: @ex <> ~s(ex:entity1 <#{@status_iri}> "active" .\n)

  @doc "An event asserting a different predicate."
  def non_matching_event, do: @ex <> ~s(ex:entity1 <http://example.org/normal> "safe" .\n)

  @doc "A well-formed base graph with no hooks."
  def hook_free_base, do: @ex <> ~s(ex:entity0 <http://example.org/normal> "baseline" .\n)

  @doc "Not Turtle."
  def malformed_base, do: "@prefix kh: <broken .\n this is not turtle {{{"

  @doc "Not Turtle either."
  def malformed_event, do: "also ] not turtle"

  @doc "The engine-native condition witness for `status_iri/0`: an N3 denial over the event."
  def condition_witness(event), do: event <> "{ ?s <#{@status_iri}> ?o } => false .\n"

  @doc "Non-range-restricted rule plus a denial that matches iff `e:a e:related ?w` was derived."
  def unsafe_rule_document do
    @e <> "e:a e:edge e:b .\n{ ?x e:edge ?y } => { ?x e:related ?w } .\n" <> related_denial()
  end

  @doc "The range-restricted control: `?y` is bound by the body."
  def safe_rule_document do
    @e <> "e:a e:edge e:b .\n{ ?x e:edge ?y } => { ?x e:related ?y } .\n" <> related_denial()
  end

  defp related_denial, do: "{ e:a e:related ?any } => false .\n"

  @doc "Recursion through a list term in the head."
  def list_head_document, do: @e <> "e:a e:edge e:b .\n{ ?x e:edge ?y } => { ?x e:edge (?y) } .\n"

  @doc "Recursion through math:sum."
  def sum_recursion_document do
    @e <> @math <> "e:counter e:n 1 .\n{ ?x e:n ?n . (?n 1) math:sum ?m } => { ?x e:n ?m } .\n"
  end

  @doc "A terminating recursive program (3 derived triples) under the same bound."
  def transitive_document do
    @e <>
      "e:a e:edge e:b . e:b e:edge e:c . e:c e:edge e:d .\n{ ?x e:edge ?y . ?y e:edge ?z } => { ?x e:edge ?z } .\n"
  end

  @doc """
  Reproducer cases by defect id: `{name, host, function, args}`. `host` is
  `:host` (the long-lived `WasmexHost`) or `:bounded` (a fresh fuel-bounded
  `WasmexSession`).
  """
  def cases("GL-DEFECT-001") do
    [
      {"hook_in_base_matching_event", :host, "run_hooks", [delta_hook_pack(), matching_event()]},
      {"hook_in_event_matching_event", :host, "run_hooks",
       [hook_free_base(), delta_hook_pack() <> matching_event()]},
      {"iri_valued_hook_matching_event", :host, "run_hooks", [iri_hook_pack(), matching_event()]},
      {"sparql_hook_matching_event", :host, "run_hooks", [sparql_hook_pack(), matching_event()]},
      {"control_hook_non_matching_event", :host, "run_hooks",
       [delta_hook_pack(), non_matching_event()]},
      {"control_condition_witness_matching", :host, "validate_all",
       [condition_witness(matching_event()), "", "", "", ""]},
      {"control_condition_witness_non_matching", :host, "validate_all",
       [condition_witness(non_matching_event()), "", "", "", ""]}
    ]
  end

  def cases("GL-DEFECT-002") do
    [
      {"malformed_base_and_event", :host, "run_hooks", [malformed_base(), malformed_event()]},
      {"control_wellformed_hook_free", :host, "run_hooks",
       [hook_free_base(), non_matching_event()]}
    ]
  end

  def cases("GL-DEFECT-003") do
    [
      {"unsafe_rule", :host, "validate_all", [unsafe_rule_document(), "", "", "", ""]},
      {"control_range_restricted_rule", :host, "validate_all",
       [safe_rule_document(), "", "", "", ""]}
    ]
  end

  def cases("GL-DEFECT-004") do
    [
      {"list_term_head_recursion", :bounded, "validate_all",
       [list_head_document(), "", "", "", ""]},
      {"math_sum_recursion", :bounded, "validate_all",
       [sum_recursion_document(), "", "", "", ""]},
      {"control_terminating_transitive_closure", :bounded, "validate_all",
       [transitive_document(), "", "", "", ""]}
    ]
  end

  @doc "Defect ids with reproducers."
  def defect_ids, do: ["GL-DEFECT-001", "GL-DEFECT-002", "GL-DEFECT-003", "GL-DEFECT-004"]

  @doc "Args of one named case."
  def args!(defect_id, name) do
    {_, _, _, args} = Enum.find(cases(defect_id), fn {n, _, _, _} -> n == name end)
    args
  end

  # --- engine identity and sessions ------------------------------------------------

  @doc "The vendored artifact path."
  def wasm_path, do: GraphLaw.wasm_path()

  @doc "sha256 pinned by `priv/graphlaw/MANIFEST.json`."
  def pinned_sha256 do
    {:ok, manifest} = Manifest.read()
    get_in(manifest, ["artifact", "sha256"])
  end

  @doc "Starts a court-owned `WasmexHost` over the vendored artifact; returns its name."
  def start_host do
    name = Module.concat(__MODULE__, "Host#{System.unique_integer([:positive])}")
    {:ok, _pid} = WasmexHost.start_link(name: name, wasm_path: wasm_path())
    name
  end

  @doc "Stops a host started by `start_host/0`."
  def stop_host(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 10_000)
    end
  end

  @doc """
  Runs one case against the vendored engine through the real public host API.
  Returns `{:ok, decoded_output}` or the host's `{:error, map}`.
  """
  def run_case(host, {_name, :host, "run_hooks", [base, event]}),
    do: WasmexHost.run_hooks(base, event, host)

  def run_case(host, {_name, :host, "validate_all", [ttl, profile, shacl, shex, map]}),
    do: WasmexHost.validate_all(ttl, profile, shacl, shex, map, host)

  def run_case(_host, {_name, :bounded, "validate_all", args}) do
    {:ok, %{session: session}} =
      WasmexSession.open(wasm_path: wasm_path(), fuel: fuel(), call_timeout_ms: 60_000)

    try do
      with {:ok, raw} <- WasmexSession.call(session, :validate_all, args),
           do: {:ok, JSON.decode!(raw)}
    after
      WasmexSession.close(session)
    end
  end

  @doc "JSON-safe observation of a case result (trap backtraces reduced to the trap kind)."
  def observation({:ok, decoded}), do: %{"returned" => decoded}

  def observation({:error, %{code: code} = error}) do
    trap =
      case Regex.run(~r/wasm trap: ([^)]+)\)/, to_string(Map.get(error, :reason, ""))) do
        [_, kind] -> kind
        _ -> nil
      end

    %{"error_code" => Atom.to_string(code), "trap" => trap}
  end

  # --- substituted artifacts ---------------------------------------------------------

  @glue "./praxis_graphlaw_wasm_bg.js"

  @doc "Host imports of the praxis HEAD `31f149d` build (measured, 6 functions)."
  def praxis_head_imports do
    [
      {"__wbg_new_227d7c05414eb861", "(result i32)"},
      {"__wbg_stack_3b0d974bbf31e44f", "(param i32 i32)"},
      {"__wbg_error_a6fa202b58aa1cd3", "(param i32 i32)"},
      {"__wbindgen_object_drop_ref", "(param i32)"},
      {"__wbg_getRandomValues_3f44b700395062e5", "(param i32 i32)"},
      {"__wbg___wbindgen_throw_344f42d3211c4765", "(param i32 i32)"}
    ]
  end

  @doc """
  Writes a real wasm module with the praxis HEAD import surface into `dir`
  and returns `{path, sha256}`.
  """
  def foreign_surface_wasm!(dir) do
    imports =
      Enum.map_join(praxis_head_imports(), "\n", fn {name, sig} ->
        ~s[  (import "#{@glue}" "#{name}" (func #{sig}))]
      end)

    {:ok, bytes} = Wasmex.Wat.to_wasm("(module\n#{imports}\n  (memory (export \"memory\") 1))")
    path = Path.join(dir, "substituted_praxis_head_surface.wasm")
    File.mkdir_p!(dir)
    File.write!(path, bytes)
    {path, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
  end

  @doc """
  Runs `fun` in an unlinked, monitored process so a host that kills its caller
  is observed as `{:crashed, reason}` instead of taking the court down.
  """
  def contained(fun, timeout \\ 60_000) do
    {pid, ref} = spawn_monitor(fn -> exit({:returned, fun.()}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:returned, value}} -> {:returned, value}
      {:DOWN, ^ref, :process, ^pid, reason} -> {:crashed, reason}
    after
      timeout ->
        Process.exit(pid, :kill)
        {:crashed, :timeout}
    end
  end

  # --- reproducers ---------------------------------------------------------------

  @doc "Path of a committed reproducer."
  def reproducer_path(defect_id), do: Path.join([GraphLaw.dir(), "defects", "#{defect_id}.json"])

  @doc "Reads a committed reproducer."
  def reproducer(defect_id), do: defect_id |> reproducer_path() |> File.read!() |> JSON.decode!()

  # --- independent readers ------------------------------------------------------------

  @doc "RDF.ex (not the engine): does `event` assert `predicate` for some subject?"
  def event_asserts?(event, predicate, prefixes \\ "") do
    case RDF.Turtle.read_string(prefixes <> event) do
      {:ok, graph} ->
        graph |> RDF.Graph.triples() |> Enum.any?(fn {_s, p, _o} -> to_string(p) == predicate end)

      {:error, _} ->
        false
    end
  end

  @doc "RDF.ex (not the engine): does `text` parse as Turtle at all?"
  def turtle?(text), do: match?({:ok, _}, RDF.Turtle.read_string(text))

  @doc "RuleDocument (not the engine): the rule-level classification of a rule document's rules."
  def rule_classification(document) do
    rules =
      document
      |> String.split("\n")
      |> Enum.filter(&(String.contains?(&1, "=>") and not String.contains?(&1, "=> false")))

    case RuleDocument.check(@e <> @math <> Enum.join(rules, "\n")) do
      {:ok, _} -> "admissible"
      {:error, %{code: code}} -> Atom.to_string(code)
    end
  end

  # --- OCEL --------------------------------------------------------------------------

  @attribute_keys [
    :host,
    :function,
    :wasm_sha256,
    :outcome,
    :code,
    :output_sha256,
    :output_bytes,
    :engine_status,
    :hooks_status,
    :verdict_count,
    :receipt_count,
    :schedule_count
  ]

  @load_keys [
    :host,
    :wasm_sha256,
    :bytes,
    :outcome,
    :code,
    :import_count,
    :unexpected_imports,
    :missing_imports
  ]

  @doc "OCEL mappings for the engine call and engine load boundary events."
  def mappings do
    {load_start, load_stop} = EngineLoad.events()

    load =
      for {event, activity} <- [
            {load_start, "graphlaw.engine.load.start"},
            {load_stop, "graphlaw.engine.load.stop"}
          ] do
        Mapping.new!(
          event: event,
          activity: activity,
          source: __MODULE__,
          objects: fn _m, meta -> [{"graphlaw_engine", meta[:wasm_sha256], "engine"}] end,
          attributes: fn _m, meta ->
            meta |> Map.take(@load_keys) |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
          end
        )
      end

    load ++
      [
        Mapping.new!(
          event: EngineTelemetry.event(),
          activity: "graphlaw.engine.call",
          source: __MODULE__,
          objects: fn _m, meta ->
            [
              {"graphlaw_engine", meta[:wasm_sha256], "engine"},
              {"engine_output", meta[:output_sha256], "output"}
            ]
          end,
          attributes: fn _m, meta ->
            dialect_keys = for {k, _} <- meta, is_binary(k), do: k

            meta
            |> Map.take(@attribute_keys ++ dialect_keys)
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Map.new()
          end
        )
      ]
  end
end
