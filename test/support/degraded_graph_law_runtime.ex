defmodule AshA2A.Test.DegradedGraphLawRuntime do
  @moduledoc """
  A **real** WebAssembly host that is genuinely degraded: it loads the real
  `praxis-graphlaw` module, really executes every GraphLaw call against it,
  and really refuses exactly one function.

  This is not a mock and verifies no interactions. It delegates to
  `AshA2A.GraphLaw.WasmexSession`, so `graphlaw_version/0`, `validate_all/5`,
  `run_hooks/2` and `blake3_hex/1` all return the real strings the real WASM
  module produced. The one difference is real behaviour, not a recorded
  expectation: `graph_hash/1` returns a typed `:graph_hash_unavailable`
  refusal, exactly as a host whose canonical-hash path was broken would.

  It exists because the conformance court's most important rule cannot be
  exercised any other way. `AshA2A.SA2A.Conformance` must treat an assertion
  it *could not compute* as a failure rather than a skip, and both healthy
  runtimes on this machine compute every assertion. Measured directly,
  malformed Turtle does not produce a failure either: GraphLaw parses
  `"this is not turtle at all {{{"` to a graph and hashes it rather than
  returning `{"error": ...}`, so a corrupt corpus cannot drive the absent
  path. A genuinely partially-broken host can.

  Its `host_id/0` and `engine_id/0` are distinct from both shipped runtimes,
  but it executes in the same in-BEAM Wasmtime engine as
  `AshA2A.GraphLaw.WasmexSession`, so the court refuses that pairing on
  observed runtime identity (RFC-SA2A-002 §126); pair it with the
  out-of-BEAM `AshA2A.GraphLaw.RuntimeB`.
  """

  @behaviour AshA2A.GraphLaw.Runtime

  alias AshA2A.GraphLaw.WasmexSession

  @impl true
  def host_id, do: "BEAM/Wasmex(degraded)"

  @impl true
  def engine_id, do: "wasmtime-degraded"

  @impl true
  def available?(opts \\ []), do: WasmexSession.available?(opts)

  @impl true
  def open(opts \\ []), do: WasmexSession.open(opts)

  @impl true
  def call(_session, :graph_hash, _args) do
    {:error,
     %{
       code: :graph_hash_unavailable,
       message: "this host's canonical graph hash path is deliberately unavailable"
     }}
  end

  def call(session, fun, args), do: WasmexSession.call(session, fun, args)

  @impl true
  def close(session), do: WasmexSession.close(session)
end
