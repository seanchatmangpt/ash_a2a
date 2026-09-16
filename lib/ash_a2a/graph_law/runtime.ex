defmodule AshA2A.GraphLaw.Runtime do
  @moduledoc """
  Behaviour for a **real** WebAssembly host that executes the prebuilt
  `praxis-graphlaw` WASM module.

  This is the portability boundary the SA2A conformance court
  (`AshA2A.SA2A.Conformance`) measures across. A conforming implementation
  loads the *identical* `praxis_graphlaw_wasm_bg.wasm` bytes and exposes the
  five GraphLaw entry points over them. Nothing in this behaviour, or in any
  implementation of it, is permitted to compute a semantic answer itself:
  every returned string must be the real string the WASM module produced.

  Elixir's job in this architecture is envelope, standing, refusal typing,
  authority, receipts, admission orchestration, and the A2A boundary --
  never SHACL/ShEx/Datalog/N3/SPARQL evaluation or RDF canonicalization.
  Those live in `praxis-graphlaw` and are reached only through this
  behaviour.

  ## Session model

  A session is opened per conformance vector, the six-call sequence is issued
  against that one session in order, and the session is closed. Both shipped
  implementations are genuinely different hosts:

    * `AshA2A.GraphLaw.Wasm` -- in-BEAM, `:wasmex` (Wasmtime engine via a
      Rustler NIF). Session = a real `Wasmex` GenServer instance.
    * `AshA2A.GraphLaw.RuntimeB` -- out-of-BEAM, a real OS subprocess running
      a real standalone JavaScript engine over `priv/graphlaw_host/`.
      Session = a real `Port`.

  ## The two host imports

  The WASM module imports exactly two host functions from the
  `"./praxis_graphlaw_wasm_bg.js"` module:

    * `__wbindgen_object_drop_ref/1` -- a no-op.
    * `__wbg_getRandomValues_3f44b700395062e5/2` -- fills `(ptr, len)` in
      linear memory with bytes.

  Every implementation MUST fill those bytes with the identical deterministic
  sequence `byte(i) = rem(i * 2_654_435_761, 256)` (see
  `deterministic_random_byte/1`). A host-supplied entropy source would make
  cross-runtime digest equality unmeasurable for reasons that have nothing to
  do with semantics; pinning it is what makes the court's falsifiers mean
  something.
  """

  @typedoc "An opaque, implementation-owned handle to one live WASM session."
  @type session :: term()

  @typedoc "The five GraphLaw entry points exported by the WASM module."
  @type fun_name :: :graphlaw_version | :validate_all | :graph_hash | :run_hooks | :blake3_hex

  @doc "Stable host identity, e.g. `\"BEAM/Wasmex\"`. Appears in the receipt."
  @callback host_id() :: String.t()

  @doc """
  Stable identity of the underlying WebAssembly *engine*, e.g. `"wasmtime"`.

  Distinct from `c:host_id/0`: two different hosts can embed the same engine.
  The court reports both and refuses a run whose two runtimes share a
  `{host_id, engine_id}` pair.
  """
  @callback engine_id() :: String.t()

  @doc """
  Real, executed availability probe. `:ok`, or a typed refusal explaining
  exactly which real precondition is absent (missing module, missing
  executable, missing wasm file).
  """
  @callback available?(opts :: keyword()) :: :ok | {:error, map()}

  @doc """
  Opens one real session over the WASM bytes at `opts[:wasm_path]`.

  On success the map carries `:session` plus `:wasm_digest` -- the SHA-256
  hex digest of the bytes this host actually loaded, computed by the host
  itself, not copied from a sibling runtime.
  """
  @callback open(opts :: keyword()) ::
              {:ok, %{session: session(), wasm_digest: String.t()}} | {:error, map()}

  @doc "Issues one real WASM call. Returns the real returned string, verbatim."
  @callback call(session(), fun_name(), args :: [String.t()]) ::
              {:ok, String.t()} | {:error, map()}

  @doc "Releases the real session resources (GenServer, Port, subprocess)."
  @callback close(session()) :: :ok

  @doc """
  The deterministic byte every implementation must supply for index `i` of a
  `getRandomValues` request.

      iex> AshA2A.GraphLaw.Runtime.deterministic_random_byte(0)
      0
      iex> AshA2A.GraphLaw.Runtime.deterministic_random_byte(1)
      177
  """
  @spec deterministic_random_byte(non_neg_integer()) :: byte()
  def deterministic_random_byte(i) when is_integer(i) and i >= 0,
    do: rem(i * 2_654_435_761, 256)

  @doc """
  The deterministic `len`-byte binary an implementation must write into
  linear memory for a `getRandomValues(ptr, len)` import call.
  """
  @spec deterministic_random_bytes(non_neg_integer()) :: binary()
  def deterministic_random_bytes(0), do: <<>>

  def deterministic_random_bytes(len) when is_integer(len) and len > 0 do
    for i <- 0..(len - 1), into: <<>>, do: <<deterministic_random_byte(i)>>
  end

  @doc """
  Default path to the prebuilt GraphLaw WASM module.

  Resolution order: `opts[:wasm_path]`, then
  `Application.get_env(:ash_a2a, :graphlaw_wasm_path)`, then the
  `PRAXIS_GRAPHLAW_WASM` environment variable, then the in-tree
  `praxis-graphlaw-wasm` build output. There is no vendored copy: the court
  is explicitly a statement about *the* module `praxis` builds, so pointing
  at a checkout is the honest default rather than a stale copy.
  """
  @spec wasm_path(keyword()) :: String.t()
  def wasm_path(opts \\ []) do
    Keyword.get(opts, :wasm_path) ||
      Application.get_env(:ash_a2a, :graphlaw_wasm_path) ||
      System.get_env("PRAXIS_GRAPHLAW_WASM") ||
      Path.expand("~/praxis/crates/praxis-graphlaw-wasm/pkg/praxis_graphlaw_wasm_bg.wasm")
  end

  @doc """
  SHA-256 hex digest of real bytes. Used by both hosts to report the identity
  of the module each of them actually loaded.
  """
  @spec bytes_digest(binary()) :: String.t()
  def bytes_digest(bytes) when is_binary(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "The digest algorithm `bytes_digest/1` uses, named in the receipt."
  @spec digest_algorithm() :: String.t()
  def digest_algorithm, do: "sha256"

  @doc """
  `{host_id, engine_id}` identity pair of an implementing module. The court
  refuses a run in which both configured runtimes return the same pair.
  """
  @spec identity(module()) :: {String.t(), String.t()}
  def identity(mod) when is_atom(mod), do: {mod.host_id(), mod.engine_id()}
end
