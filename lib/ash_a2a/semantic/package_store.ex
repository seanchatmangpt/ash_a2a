defmodule AshA2A.Semantic.PackageStore do
  @moduledoc """
  In-memory registry correlating an `AshA2A.Semantic.ExecutionPackage`'s own
  content-addressed `fingerprint` back to the real, full package struct that
  produced it (GAP B: receipt -> feedback -> replan closure).

  A caller only ever receives the `fingerprint` on the wire (`ExecutionPackage
  .to_reply/1`'s `"execution_package_fingerprint"` body field) -- the
  fingerprint is a SHA-256 digest of `{source.id, ontology.fingerprint,
  planning.fingerprint, candidate.fingerprint}`
  (`AshA2A.Semantic.ExecutionPackage.fingerprint/1`), a one-way hash, so it
  cannot be inverted back into the real `source`/`semantic_ir`/`ontology`/
  `planning_ir`/`plan_candidate` structs `AshA2A.Semantic.Compiler.replan/4`
  needs as its second argument. Something real has to keep the full struct
  addressable by that same fingerprint, or a continuation request naming only
  the fingerprint could never resolve to a real package to replan from.

  Deliberately a SEPARATE store from `AshA2A.ReceiptStore`, not a field bolted
  onto it: a `AshA2A.Receipt` records what a real DO attempt observed
  (`standing: :observed`), while an `ExecutionPackage` is candidate-only,
  `authority: :none` semantic-compiler output (`standing: :candidate`) --
  conflating the two stores would let a candidate be retrieved as if it were
  receipted evidence. `AshA2A.Agent.dispatch_semantic/2` is the only production
  writer (every real compile and every real replan stores its own resulting
  package here, keyed by that package's own `fingerprint`); `AshA2A.Agent`'s
  continuation-replan path is the only production reader.

  In-memory and best-effort, matching this codebase's own `AshA2A.
  ReceiptStore.Memory` default: losing pending candidate packages on a process
  restart is an acceptable real trade-off for a `standing: :candidate,
  authority: :none` value that was never receipted evidence and never granted
  any authority -- unlike a committed `AshA2A.Receipt`, nothing of consequence
  was ever true because a package merely existed here.
  """
  use GenServer

  alias AshA2A.Semantic.ExecutionPackage

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(state), do: {:ok, state}

  @doc "Stores `package`, keyed by its own real `fingerprint`."
  @spec put(ExecutionPackage.t(), keyword()) :: :ok
  def put(%ExecutionPackage{} = package, opts \\ []) do
    GenServer.call(server(opts), {:put, package})
  end

  @doc "Fetches the real `ExecutionPackage` previously stored under `fingerprint`."
  @spec fetch(String.t(), keyword()) :: {:ok, ExecutionPackage.t()} | :error
  def fetch(fingerprint, opts \\ []) when is_binary(fingerprint) do
    GenServer.call(server(opts), {:fetch, fingerprint})
  end

  @impl true
  def handle_call({:put, %ExecutionPackage{} = package}, _from, state) do
    {:reply, :ok, Map.put(state, package.fingerprint, package)}
  end

  def handle_call({:fetch, fingerprint}, _from, state) do
    case Map.get(state, fingerprint) do
      %ExecutionPackage{} = package -> {:reply, {:ok, package}, state}
      _ -> {:reply, :error, state}
    end
  end

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)
end
