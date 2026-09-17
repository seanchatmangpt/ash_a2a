defmodule AshA2A.Chicago.Courts.GraphlawEngine do
  @moduledoc """
  RFC-SA2A-002 §47 / §60 / §100 / §119 / §120 court over the vendored
  praxis-graphlaw engine itself (court id `SA2A-ENGINE`).

  `SA2A-HOOK`, `SA2A-CASCADE` and `SA2A-LOGIC` qualify the `ash_a2a`
  boundaries that route around this engine's measured defects
  (`HookReactor.Engine` evaluates conditions through N3_DENIAL, not
  `run_hooks/2`; `LogicClosure` refuses unsafe rules before the engine and
  bounds it with fuel). This court pins the engine's own behaviour against
  its exact identity -- the sha256 in `priv/graphlaw/MANIFEST.json` -- so that
  a re-vendored engine is requalified (§119) instead of inheriting standing
  from a newer version string (§120), and it pins the host load boundary a
  refresh goes through.

  Subject under qualification:

    * the vendored `priv/graphlaw/praxis_graphlaw.wasm`, executed by a real
      court-owned `AshA2A.GraphLaw.WasmexHost` (Wasmtime via wasmex) and by
      fuel-bounded `AshA2A.GraphLaw.WasmexSession`s;
    * the host load boundary `AshA2A.GraphLaw.EngineLoad`.

  Negative falsifiers 001-006 are engine defects that SURVIVE against the
  vendored engine and against a build of praxis HEAD `31f149d`; each has a
  minimal reproducer (inputs, call, observed output, responsible Rust source)
  under `priv/graphlaw/defects/` and is BLOCKED_ON_PRAXIS. Attempt evidence is
  the host's `[:ash_a2a, :graphlaw, :engine, :call]` event (emitted whenever
  the engine returns or traps, whatever it decided) bound to the pinned
  digest; independent readers (RDF.ex, `RuleDocument`) confirm each stimulus
  really is what it claims before a verdict is recorded.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.GraphlawEngine, as: F
  alias AshA2A.GraphLaw.{WasmexHost, WasmexSession}

  @court "SA2A-ENGINE"
  @call "graphlaw.engine.call"
  @load_start "graphlaw.engine.load.start"
  @load_stop "graphlaw.engine.load.stop"

  @impl true
  def id, do: @court
  @impl true
  def title,
    do:
      "Vendored GraphLaw engine identity: hook firing, range restriction, termination, load surface"

  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :logic
  @impl true
  def rfc_sections, do: ["§10", "§22", "§47", "§60", "§100", "§119", "§120"]

  @impl true
  def ocel_mappings, do: F.mappings()

  @impl true
  def falsifiers do
    pin = F.pinned_sha256()

    reached = fn function ->
      {:observed, @call, %{"function" => function, "wasm_sha256" => pin}}
    end

    hooks_not_evaluated =
      {:observed, @call,
       %{"function" => "run_hooks", "hooks_status" => "ADMITTED", "verdict_count" => "0"}}

    [
      neg(1,
        invariant:
          "A kh:Hook whose delta trigger matches the event yields a verdict; the engine never reports ADMITTED with zero verdicts for it",
        stimulus:
          "run_hooks(base = delta hook pack on ex:status, event = a triple on ex:status) on the pinned engine (GL-DEFECT-001 hook_in_base_matching_event)",
        boundary: "vendored praxis-graphlaw run_hooks export via AshA2A.GraphLaw.WasmexHost",
        forbidden_outcome: "run_hooks returns status ADMITTED with zero verdicts",
        attempt_evidence:
          "graphlaw.engine.call function=run_hooks wasm_sha256=<MANIFEST pin>, whatever the engine decided",
        survival_evidence:
          "graphlaw.engine.call hooks_status=ADMITTED verdict_count=0; the decoded reply; RDF.ex confirms the event asserts the hooked predicate",
        guard:
          "praxis-graphlaw TripleStore::from hook extraction (lib.rs:257-259, hooks/parsing.rs:78) + run_hooks_core_impl status (praxis-graphlaw-wasm core.rs:513)",
        failure_class: :validator_failure,
        rfc_sections: ["§60", "§119"],
        attempt_predicate: reached.("run_hooks"),
        outcome_predicate: hooks_not_evaluated,
        tags: [:hooks, :blocked_on_praxis]
      ),
      neg(2,
        invariant: "A matching kh:Hook carried in the event graph yields a verdict",
        stimulus:
          "run_hooks(base = hook-free graph, event = delta hook pack + matching triple) (GL-DEFECT-001 hook_in_event_matching_event)",
        boundary: "vendored praxis-graphlaw run_hooks export via AshA2A.GraphLaw.WasmexHost",
        forbidden_outcome: "run_hooks returns status ADMITTED with zero verdicts",
        attempt_evidence: "graphlaw.engine.call function=run_hooks wasm_sha256=<MANIFEST pin>",
        survival_evidence: "graphlaw.engine.call hooks_status=ADMITTED verdict_count=0",
        guard:
          "run_hooks_core_impl reads hooks from the post-event store (praxis-graphlaw-wasm core.rs:505)",
        failure_class: :validator_failure,
        rfc_sections: ["§60", "§119"],
        attempt_predicate: reached.("run_hooks"),
        outcome_predicate: hooks_not_evaluated,
        tags: [:hooks, :blocked_on_praxis]
      ),
      neg(3,
        invariant: "Input the engine cannot parse is never ADMITTED by run_hooks",
        stimulus:
          "run_hooks of a base and an event that are not Turtle (GL-DEFECT-002 malformed_base_and_event)",
        boundary: "vendored praxis-graphlaw run_hooks export via AshA2A.GraphLaw.WasmexHost",
        forbidden_outcome: "run_hooks returns status ADMITTED",
        attempt_evidence: "graphlaw.engine.call function=run_hooks wasm_sha256=<MANIFEST pin>",
        survival_evidence:
          "graphlaw.engine.call hooks_status=ADMITTED; RDF.ex refuses both inputs",
        guard:
          "a fallible parse in run_hooks_core_impl (absent: praxis-graphlaw lib.rs:219-243 falls back silently)",
        failure_class: :validator_failure,
        rfc_sections: ["§119"],
        attempt_predicate: reached.("run_hooks"),
        outcome_predicate:
          {:observed, @call, %{"function" => "run_hooks", "hooks_status" => "ADMITTED"}},
        tags: [:hooks, :blocked_on_praxis]
      ),
      neg(4,
        invariant:
          "Range restriction: a rule whose head variable is unbound by its body is refused and derives nothing",
        stimulus:
          "validate_all of `{ ?x e:edge ?y } => { ?x e:related ?w }` + a denial over e:a e:related ?any (GL-DEFECT-003 unsafe_rule)",
        boundary:
          "vendored praxis-graphlaw validate_all DATALOG dialect via AshA2A.GraphLaw.WasmexHost",
        forbidden_outcome:
          "DATALOG ADMITTED, or the denial over the derived triple matches (a triple with an unbound variable was materialised)",
        attempt_evidence: "graphlaw.engine.call function=validate_all wasm_sha256=<MANIFEST pin>",
        survival_evidence:
          "datalog_status=ADMITTED or n3_denial_status=REFUSED; RuleDocument classifies the rule rule_not_range_restricted",
        guard:
          "datalog::validate_rules safety check (its Err is discarded at praxis-graphlaw lib.rs:254-256)",
        failure_class: :validator_failure,
        rfc_sections: ["§47"],
        attempt_predicate: reached.("validate_all"),
        outcome_predicate:
          {:any,
           [
             {:observed, @call, %{"function" => "validate_all", "datalog_status" => "ADMITTED"}},
             {:observed, @call, %{"function" => "validate_all", "n3_denial_status" => "REFUSED"}}
           ]},
        tags: [:datalog, :range_restriction, :blocked_on_praxis]
      ),
      termination(
        5,
        "list_term_head_recursion",
        "`{ ?x e:edge ?y } => { ?x e:edge (?y) }` (list term in the head)",
        reached
      ),
      termination(
        6,
        "math_sum_recursion",
        "`{ ?x e:n ?n . (?n 1) math:sum ?m } => { ?x e:n ?m }` (arithmetic term creation)",
        reached
      ),
      pos(7,
        invariant:
          "The engine discriminates the hooked delta: its N3_DENIAL condition witness over the matching event is REFUSED (matched)",
        stimulus:
          "validate_all(matching event + `{ ?s ex:status ?o } => false`) (GL-DEFECT-001 control_condition_witness_matching)",
        attempt_evidence: "graphlaw.engine.call function=validate_all wasm_sha256=<MANIFEST pin>",
        survival_evidence: "n3_denial_status=REFUSED",
        rfc_sections: ["§60", "§100"],
        attempt_predicate: reached.("validate_all"),
        outcome_predicate:
          {:observed, @call, %{"function" => "validate_all", "n3_denial_status" => "REFUSED"}}
      ),
      pos(8,
        invariant: "The condition witness over a non-matching event is ADMITTED (no match)",
        stimulus:
          "validate_all(non-matching event + the same denial) (GL-DEFECT-001 control_condition_witness_non_matching)",
        attempt_evidence: "graphlaw.engine.call function=validate_all wasm_sha256=<MANIFEST pin>",
        survival_evidence: "n3_denial_status=ADMITTED",
        rfc_sections: ["§60", "§100"],
        attempt_predicate: reached.("validate_all"),
        outcome_predicate:
          {:observed, @call, %{"function" => "validate_all", "n3_denial_status" => "ADMITTED"}}
      ),
      pos(9,
        invariant:
          "Well-formed, hook-free input is ADMITTED by run_hooks with no verdicts (lawful admission)",
        stimulus:
          "run_hooks(hook-free Turtle base, non-matching Turtle event) (GL-DEFECT-002 control_wellformed_hook_free)",
        attempt_evidence: "graphlaw.engine.call function=run_hooks wasm_sha256=<MANIFEST pin>",
        survival_evidence: "hooks_status=ADMITTED verdict_count=0; RDF.ex parses both inputs",
        rfc_sections: ["§100"],
        attempt_predicate: reached.("run_hooks"),
        outcome_predicate: hooks_not_evaluated
      ),
      pos(10,
        invariant:
          "A range-restricted rule is DATALOG ADMITTED and derives exactly its one triple",
        stimulus:
          "validate_all of `{ ?x e:edge ?y } => { ?x e:related ?y }` + the same denial (GL-DEFECT-003 control_range_restricted_rule)",
        attempt_evidence: "graphlaw.engine.call function=validate_all wasm_sha256=<MANIFEST pin>",
        survival_evidence:
          "datalog_status=ADMITTED datalog_triples_out=1 n3_denial_status=REFUSED",
        rfc_sections: ["§47", "§100"],
        attempt_predicate: reached.("validate_all"),
        outcome_predicate:
          {:observed, @call,
           %{
             "function" => "validate_all",
             "datalog_status" => "ADMITTED",
             "datalog_triples_out" => "1",
             "n3_denial_status" => "REFUSED"
           }}
      ),
      pos(11,
        invariant: "A terminating recursive program closes under the same fuel bound",
        stimulus:
          "validate_all of a 3-edge transitive closure in a fuel-bounded WasmexSession (GL-DEFECT-004 control_terminating_transitive_closure)",
        attempt_evidence:
          "graphlaw.engine.call host=BEAM/Wasmex function=validate_all wasm_sha256=<MANIFEST pin>",
        survival_evidence: "outcome=returned datalog_status=ADMITTED datalog_triples_out=3",
        rfc_sections: ["§47", "§100"],
        attempt_predicate: reached.("validate_all"),
        outcome_predicate:
          {:observed, @call,
           %{
             "function" => "validate_all",
             "outcome" => "returned",
             "datalog_status" => "ADMITTED",
             "datalog_triples_out" => "3"
           }}
      ),
      load_surface(
        12,
        "BEAM/Wasmex",
        "AshA2A.GraphLaw.WasmexSession.open/1",
        "the session opened on the substituted engine, or the caller process crashed"
      ),
      load_surface(
        13,
        "BEAM/WasmexHost",
        "AshA2A.GraphLaw.WasmexHost.start_link/1",
        "the host loaded the substituted engine, or the host crashed its caller/supervisor"
      ),
      pos(14,
        invariant:
          "The pinned vendored engine loads through the same boundary and answers with its manifest version",
        stimulus:
          "WasmexHost.start_link over priv/graphlaw/praxis_graphlaw.wasm, then graphlaw_version",
        attempt_evidence: "graphlaw.engine.load.start host=BEAM/WasmexHost",
        survival_evidence:
          "graphlaw.engine.load.stop outcome=loaded wasm_sha256=<pin>; graphlaw_version returned on the pin",
        rfc_sections: ["§32", "§100", "§119"],
        attempt_predicate: {:observed, @load_start, %{"host" => "BEAM/WasmexHost"}},
        outcome_predicate:
          {:all,
           [
             {:observed, @load_stop,
              %{"host" => "BEAM/WasmexHost", "outcome" => "loaded", "wasm_sha256" => pin}},
             {:observed, @call,
              %{"function" => "graphlaw_version", "outcome" => "returned", "wasm_sha256" => pin}}
           ]}
      )
    ]
  end

  defp termination(n, name, rule, reached) do
    neg(n,
      invariant:
        "Finite least-fixpoint termination: recursion requiring unbounded term creation is refused by the engine, not run until the host bound is exhausted",
      stimulus: "validate_all of #{rule} in a fuel-bounded WasmexSession (GL-DEFECT-004 #{name})",
      boundary:
        "vendored praxis-graphlaw validate_all DATALOG dialect via AshA2A.GraphLaw.WasmexSession (fuel #{F.fuel()})",
      forbidden_outcome:
        "the engine call traps on the fuel bound (or exits), or DATALOG ADMITTED",
      attempt_evidence:
        "graphlaw.engine.call function=validate_all wasm_sha256=<MANIFEST pin>, returned or trapped",
      survival_evidence:
        "graphlaw.engine.call outcome=trapped|exited, or datalog_status=ADMITTED",
      guard:
        "a function-free / finite-closure check in datalog::validate_rules (absent: praxis-graphlaw datalog.rs:53-66)",
      failure_class: :bound_failure,
      rfc_sections: ["§47"],
      attempt_predicate: reached.("validate_all"),
      outcome_predicate:
        {:any,
         [
           {:observed, @call, %{"function" => "validate_all", "outcome" => "trapped"}},
           {:observed, @call, %{"function" => "validate_all", "outcome" => "exited"}},
           {:observed, @call, %{"function" => "validate_all", "datalog_status" => "ADMITTED"}}
         ]},
      tags: [:datalog, :termination, :blocked_on_praxis]
    )
  end

  defp load_surface(n, host, boundary, forbidden) do
    neg(n,
      invariant:
        "A substituted engine whose host-import surface is not the pinned one (the praxis HEAD build's 6 imports) is refused with a typed error at load; the host never crashes its caller",
      stimulus:
        "#{boundary} over a real wasm module declaring the praxis HEAD import surface (environment fault injection)",
      boundary: "AshA2A.GraphLaw.EngineLoad.admit/3 in #{boundary}",
      forbidden_outcome: forbidden,
      attempt_evidence:
        "graphlaw.engine.load.start host=#{host}: the substituted bytes reached the load boundary",
      survival_evidence:
        "graphlaw.engine.load.stop outcome=loaded, or chicago.stimulus.stop outcome=raised (caller crashed)",
      guard: "EngineLoad.check_surface/1 before Wasmex.start_link/1",
      failure_class: :identity_failure,
      rfc_sections: ["§32", "§119", "§120"],
      attempt_predicate: {:observed, @load_start, %{"host" => host}},
      outcome_predicate:
        {:any,
         [
           {:observed, @load_stop, %{"host" => host, "outcome" => "loaded"}},
           {:observed, "chicago.stimulus.stop", %{"outcome" => "raised"}}
         ]},
      tags: [:identity, :abi, :refresh]
    )
  end

  defp fid(n), do: "#{@court}-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp neg(n, fields), do: declare(n, :negative, fields)

  defp pos(n, fields) do
    declare(
      n,
      :positive_control,
      Keyword.put_new(
        fields,
        :boundary,
        "vendored praxis-graphlaw engine via the in-BEAM Wasmtime hosts"
      )
    )
  end

  defp declare(n, kind, fields) do
    Falsifier.new!([id: fid(n), court_id: @court, kind: kind] ++ fields)
  end

  # --- execution ------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = fn n -> Map.fetch!(fs, fid(n)) end
    host = F.start_host()

    try do
      [
        hook_fires(ctx, f.(1), host, "hook_in_base_matching_event"),
        hook_fires(ctx, f.(2), host, "hook_in_event_matching_event"),
        malformed(ctx, f.(3), host),
        range_restriction(ctx, f.(4), host),
        termination_run(ctx, f.(5), "list_term_head_recursion"),
        termination_run(ctx, f.(6), "math_sum_recursion"),
        witness(ctx, f.(7), host, "control_condition_witness_matching", "REFUSED", true),
        witness(ctx, f.(8), host, "control_condition_witness_non_matching", "ADMITTED", false),
        wellformed(ctx, f.(9), host),
        safe_rule(ctx, f.(10), host),
        terminating(ctx, f.(11)),
        foreign_session(ctx, f.(12)),
        foreign_host(ctx, f.(13)),
        pinned_load(ctx, f.(14))
      ]
    after
      F.stop_host(host)
    end
  end

  defp engine_case(ctx, falsifier, host, defect, name) do
    c = Enum.find(F.cases(defect), fn {n, _, _, _} -> n == name end)
    reply = Context.stimulus(ctx, falsifier, fn -> F.run_case(host, c) end)
    {elem(c, 3), reply}
  end

  defp hook_fires(ctx, falsifier, host, name) do
    {[_base, event], reply} = engine_case(ctx, falsifier, host, "GL-DEFECT-001", name)
    matches? = F.event_asserts?(event, F.status_iri())

    Result.negative(falsifier,
      attempt_observed?: reached?(ctx, falsifier, "run_hooks") and matches?,
      forbidden_outcome_observed?:
        match?({:ok, %{"status" => "ADMITTED", "verdicts" => []}}, reply),
      evidence: %{
        "defect" => "GL-DEFECT-001",
        "case" => name,
        "event_asserts_hooked_predicate_rdf_ex" => matches?,
        "observed" => F.observation(reply)
      }
    )
  end

  defp malformed(ctx, falsifier, host) do
    {[base, event], reply} =
      engine_case(ctx, falsifier, host, "GL-DEFECT-002", "malformed_base_and_event")

    not_turtle? = not F.turtle?(base) and not F.turtle?(event)

    Result.negative(falsifier,
      attempt_observed?: reached?(ctx, falsifier, "run_hooks") and not_turtle?,
      forbidden_outcome_observed?: match?({:ok, %{"status" => "ADMITTED"}}, reply),
      evidence: %{
        "defect" => "GL-DEFECT-002",
        "rdf_ex_refuses_both_inputs" => not_turtle?,
        "observed" => F.observation(reply)
      }
    )
  end

  defp range_restriction(ctx, falsifier, host) do
    {[document | _], reply} = engine_case(ctx, falsifier, host, "GL-DEFECT-003", "unsafe_rule")
    classification = F.rule_classification(document)

    Result.negative(falsifier,
      attempt_observed?:
        reached?(ctx, falsifier, "validate_all") and classification == "rule_not_range_restricted",
      forbidden_outcome_observed?:
        dialect(reply, "DATALOG") == "ADMITTED" or dialect(reply, "N3_DENIAL") == "REFUSED",
      evidence: %{
        "defect" => "GL-DEFECT-003",
        "rule_document_classification" => classification,
        "datalog" => dialect_detail(reply, "DATALOG"),
        "n3_denial" => dialect_detail(reply, "N3_DENIAL")
      }
    )
  end

  defp termination_run(ctx, falsifier, name) do
    {[document | _], reply} = engine_case(ctx, falsifier, nil, "GL-DEFECT-004", name)

    trapped? =
      match?(
        {:error, %{code: code}} when code in [:graphlaw_call_trapped, :graphlaw_call_exited],
        reply
      )

    Result.negative(falsifier,
      attempt_observed?:
        seen?(ctx, falsifier, @call, %{
          "function" => "validate_all",
          "host" => "BEAM/Wasmex",
          "wasm_sha256" => F.pinned_sha256()
        }),
      forbidden_outcome_observed?: trapped? or dialect(reply, "DATALOG") == "ADMITTED",
      evidence: %{
        "defect" => "GL-DEFECT-004",
        "rule_document_classification" => F.rule_classification(document),
        "fuel" => F.fuel(),
        "observed" => F.observation(reply)
      }
    )
  end

  defp witness(ctx, falsifier, host, name, expected, matches) do
    {[document | _], reply} = engine_case(ctx, falsifier, host, "GL-DEFECT-001", name)
    asserts? = F.event_asserts?(document |> String.split("{ ?s") |> hd(), F.status_iri())

    Result.positive(falsifier,
      attempt_observed?: reached?(ctx, falsifier, "validate_all") and asserts? == matches,
      expected_outcome_observed?: dialect(reply, "N3_DENIAL") == expected,
      evidence: %{
        "event_asserts_hooked_predicate_rdf_ex" => asserts?,
        "n3_denial" => dialect_detail(reply, "N3_DENIAL")
      }
    )
  end

  defp wellformed(ctx, falsifier, host) do
    {[base, event], reply} =
      engine_case(ctx, falsifier, host, "GL-DEFECT-002", "control_wellformed_hook_free")

    turtle? = F.turtle?(base) and F.turtle?(event)

    Result.positive(falsifier,
      attempt_observed?: reached?(ctx, falsifier, "run_hooks") and turtle?,
      expected_outcome_observed?:
        match?({:ok, %{"status" => "ADMITTED", "verdicts" => []}}, reply),
      evidence: %{"rdf_ex_parses_both_inputs" => turtle?, "observed" => F.observation(reply)}
    )
  end

  defp safe_rule(ctx, falsifier, host) do
    {[document | _], reply} =
      engine_case(ctx, falsifier, host, "GL-DEFECT-003", "control_range_restricted_rule")

    classification = F.rule_classification(document)

    Result.positive(falsifier,
      attempt_observed?:
        reached?(ctx, falsifier, "validate_all") and classification == "admissible",
      expected_outcome_observed?:
        dialect(reply, "DATALOG") == "ADMITTED" and triples_out(reply, "DATALOG") == 1 and
          dialect(reply, "N3_DENIAL") == "REFUSED",
      evidence: %{
        "rule_document_classification" => classification,
        "datalog" => dialect_detail(reply, "DATALOG")
      }
    )
  end

  defp terminating(ctx, falsifier) do
    {_args, reply} =
      engine_case(ctx, falsifier, nil, "GL-DEFECT-004", "control_terminating_transitive_closure")

    Result.positive(falsifier,
      attempt_observed?:
        seen?(ctx, falsifier, @call, %{"function" => "validate_all", "host" => "BEAM/Wasmex"}),
      expected_outcome_observed?:
        dialect(reply, "DATALOG") == "ADMITTED" and triples_out(reply, "DATALOG") == 3,
      evidence: %{"fuel" => F.fuel(), "datalog" => dialect_detail(reply, "DATALOG")}
    )
  end

  defp foreign_session(ctx, falsifier) do
    {path, sha} = F.foreign_surface_wasm!(Path.join(ctx.evidence_dir, "substituted"))

    outcome =
      contained_stimulus(ctx, falsifier, fn ->
        case WasmexSession.open(wasm_path: path) do
          {:ok, %{session: session}} ->
            WasmexSession.close(session)
            :opened

          {:error, error} ->
            {:refused, error.code}
        end
      end)

    load_result(
      ctx,
      falsifier,
      "BEAM/Wasmex",
      sha,
      outcome,
      match?({:returned, :opened}, outcome)
    )
  end

  defp foreign_host(ctx, falsifier) do
    {path, sha} = F.foreign_surface_wasm!(Path.join(ctx.evidence_dir, "substituted"))
    name = Module.concat(__MODULE__, "Substituted#{System.unique_integer([:positive])}")

    outcome =
      contained_stimulus(ctx, falsifier, fn ->
        {:ok, pid} = WasmexHost.start_link(name: name, wasm_path: path)
        available? = WasmexHost.available?(name)
        reply = WasmexHost.graph_hash("", name)
        GenServer.stop(pid, :normal, 10_000)
        {available?, reply}
      end)

    loaded? = match?({:returned, {true, _}}, outcome)
    load_result(ctx, falsifier, "BEAM/WasmexHost", sha, outcome, loaded?)
  end

  defp load_result(ctx, falsifier, host, sha, outcome, loaded?) do
    crashed? = match?({:crashed, _}, outcome)

    Result.negative(falsifier,
      attempt_observed?:
        seen?(ctx, falsifier, @load_start, %{"host" => host, "wasm_sha256" => sha}),
      forbidden_outcome_observed?: crashed? or loaded?,
      evidence: %{
        "substituted_wasm_sha256" => sha,
        "substituted_import_count" => length(F.praxis_head_imports()),
        "caller_crashed" => crashed?,
        "loaded" => loaded?,
        "outcome" => inspect(outcome, limit: 8, printable_limit: 300)
      }
    )
  end

  # The host call runs in an unlinked process; a crash is re-raised inside the
  # stimulus so the observer records `chicago.stimulus.stop outcome=raised`,
  # then contained here so the court keeps running.
  defp contained_stimulus(ctx, falsifier, fun) do
    Context.stimulus(ctx, falsifier, fn ->
      case F.contained(fun) do
        {:crashed, reason} ->
          raise "host crashed its caller: #{inspect(reason, limit: 5, printable_limit: 300)}"

        returned ->
          returned
      end
    end)
  rescue
    error -> {:crashed, Exception.message(error)}
  end

  defp pinned_load(ctx, falsifier) do
    name = Module.concat(__MODULE__, "Pinned#{System.unique_integer([:positive])}")

    version =
      Context.stimulus(ctx, falsifier, fn ->
        {:ok, pid} = WasmexHost.start_link(name: name, wasm_path: F.wasm_path())

        try do
          WasmexHost.version(name)
        after
          GenServer.stop(pid, :normal, 10_000)
        end
      end)

    {:ok, manifest} = AshA2A.GraphLaw.Manifest.read()

    Result.positive(falsifier,
      attempt_observed?: seen?(ctx, falsifier, @load_start, %{"host" => "BEAM/WasmexHost"}),
      expected_outcome_observed?:
        seen?(ctx, falsifier, @load_stop, %{
          "outcome" => "loaded",
          "wasm_sha256" => F.pinned_sha256()
        }) and
          version == {:ok, manifest["graphlaw_version"]},
      evidence: %{
        "version" => inspect(version),
        "manifest_version" => manifest["graphlaw_version"]
      }
    )
  end

  # --- readers ----------------------------------------------------------------------

  defp reached?(ctx, falsifier, function),
    do:
      seen?(ctx, falsifier, @call, %{"function" => function, "wasm_sha256" => F.pinned_sha256()})

  defp seen?(ctx, falsifier, activity, attrs) do
    ctx
    |> Context.observed(falsifier)
    |> Enum.any?(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(Map.get(record.attributes, k)) == to_string(v) end)
    end)
  end

  defp dialect_entry({:ok, %{"dialects" => dialects}}, name),
    do: Enum.find(dialects, &(&1["dialect"] == name))

  defp dialect_entry(_reply, _name), do: nil

  defp dialect(reply, name), do: reply |> dialect_entry(name) |> then(&(&1 && &1["status"]))

  defp triples_out(reply, name),
    do: reply |> dialect_entry(name) |> then(&(&1 && &1["triples_out"]))

  defp dialect_detail(reply, name) do
    case dialect_entry(reply, name) do
      nil -> F.observation(reply)
      entry -> entry
    end
  end
end
