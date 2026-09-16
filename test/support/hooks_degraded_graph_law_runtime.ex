defmodule AshA2A.Test.HooksDegradedRuntimeA do
  @moduledoc """
  A **real** in-BEAM WebAssembly host whose one and only degradation is that
  `run_hooks/2` -- the call that decides ADMITTED -- really refuses.

  Every other call is delegated to `AshA2A.GraphLaw.Wasm`, so
  `graphlaw_version/0`, `validate_all/5`, `graph_hash/1` and `blake3_hex/1`
  return the real strings the real prebuilt `praxis-graphlaw` module produced.
  Nothing here is a mock: no interaction is recorded and no return value is
  canned. The refusal is real behaviour of the kind a host whose hook
  evaluation path was broken would actually exhibit.

  It exists to hold the court to its own central rule. Two hosts that both
  failed to compute admission are not two hosts that agreed on admission, and
  the court has to say so rather than projecting both failures into one
  comparable `ABSENT` graph and calling the match conformance.

  Paired with `AshA2A.Test.HooksDegradedRuntimeB`, which degrades the real
  out-of-BEAM JavaScript host the same way. The two report distinct
  `{host_id, engine_id}` pairs, so the court's identical-runtime refusal does
  not fire on the pair and the run really reaches judgement.
  """

  @behaviour AshA2A.GraphLaw.Runtime

  alias AshA2A.GraphLaw.Wasm

  @refusal %{
    code: :run_hooks_unavailable,
    message: "this host's hook evaluation path is deliberately unavailable"
  }

  @doc "The typed refusal this host really returns from `run_hooks/2`."
  @spec refusal() :: map()
  def refusal, do: @refusal

  @impl true
  def host_id, do: "BEAM/Wasmex(hooks-degraded)"

  @impl true
  def engine_id, do: "wasmtime-hooks-degraded"

  @impl true
  def available?(opts \\ []), do: Wasm.available?(opts)

  @impl true
  def open(opts \\ []), do: Wasm.open(opts)

  @impl true
  def call(_session, :run_hooks, _args), do: {:error, @refusal}
  def call(session, fun, args), do: Wasm.call(session, fun, args)

  @impl true
  def close(session), do: Wasm.close(session)
end

defmodule AshA2A.Test.HooksDegradedRuntimeB do
  @moduledoc """
  The out-of-BEAM twin of `AshA2A.Test.HooksDegradedRuntimeA`: a real OS
  subprocess running a real standalone JavaScript engine over the identical
  WASM module, degraded in exactly one place -- `run_hooks/2` really refuses.

  All other calls go to `AshA2A.GraphLaw.RuntimeB` and return the real strings
  the real engine produced.
  """

  @behaviour AshA2A.GraphLaw.Runtime

  alias AshA2A.GraphLaw.RuntimeB

  @refusal %{
    code: :run_hooks_unavailable,
    message: "this host's hook evaluation path is deliberately unavailable"
  }

  @doc "The typed refusal this host really returns from `run_hooks/2`."
  @spec refusal() :: map()
  def refusal, do: @refusal

  @impl true
  def host_id, do: "Node/StandaloneJS(hooks-degraded)"

  @impl true
  def engine_id, do: "standalone-js-hooks-degraded"

  @impl true
  def available?(opts \\ []), do: RuntimeB.available?(opts)

  @impl true
  def open(opts \\ []), do: RuntimeB.open(opts)

  @impl true
  def call(_session, :run_hooks, _args), do: {:error, @refusal}
  def call(session, fun, args), do: RuntimeB.call(session, fun, args)

  @impl true
  def close(session), do: RuntimeB.close(session)
end
