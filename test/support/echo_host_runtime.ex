defmodule AshA2A.Test.EchoHostRuntime do
  @moduledoc """
  A **real** runtime that is a different module from `AshA2A.GraphLaw.WasmexSession`
  but is, in every way that matters to the conformance claim, the same host:
  it delegates every call to `AshA2A.GraphLaw.WasmexSession` and reports Wasm's own
  `host_id/0` and `engine_id/0`.

  It is not a mock. It records no interaction and returns no canned value --
  every call really reaches the real `:wasmex` instance and returns the real
  string the real WASM module produced.

  It exists to hold the court's degeneracy refusal to the property that
  actually matters. Refusing only on module equality would let one runtime be
  entered twice under two names and report five trivially-passing assertions
  about a single host. `AshA2A.SA2A.Conformance` therefore refuses on the
  `{host_id, engine_id}` identity pair as well, and this module is the real
  input that proves the second check is load-bearing rather than dead code.
  """

  @behaviour AshA2A.GraphLaw.Runtime

  alias AshA2A.GraphLaw.WasmexSession

  @impl true
  def host_id, do: WasmexSession.host_id()

  @impl true
  def engine_id, do: WasmexSession.engine_id()

  @impl true
  def available?(opts \\ []), do: WasmexSession.available?(opts)

  @impl true
  def open(opts \\ []), do: WasmexSession.open(opts)

  @impl true
  def call(session, fun, args), do: WasmexSession.call(session, fun, args)

  @impl true
  def close(session), do: WasmexSession.close(session)
end
