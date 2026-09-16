defmodule AshA2A.SA2A.Graphlaw do
  @moduledoc """
  Real subprocess invocation of the real praxis-graphlaw wasm over the real SA2A
  conformance corpus.

  Mirrors `AshA2A.Planning.HddlSolver`'s established pattern exactly: shell out
  to a real OS subprocess via `System.cmd/3`, decode its real stdout JSON with
  the built-in `JSON` module (this repo's convention, never `Jason` at a native
  boundary), and return `{:error, %{code: ...}}` for every real failure mode
  rather than raising. Nothing here simulates, stubs, or hand-constructs an
  engine result: every `{:ok, measured}` this returns came out of the real
  GraphLaw wasm executing.

  ## Why a Node subprocess and not an in-BEAM wasm runtime

  Measured, and the reason this is a subprocess rather than a NIF: the prebuilt
  `praxis_graphlaw_wasm_bg.wasm` ships with wasm-bindgen glue targeted at a
  BUNDLER, so its `.js` shim does not load under plain Node ESM, let alone from
  the BEAM. `priv/sa2a_graphlaw/verify.mjs` therefore instantiates the wasm
  directly and implements the wasm-bindgen ABI by hand. That driver is host
  agnostic -- an in-BEAM runtime (`wasmex`, which wraps Wasmtime) can implement
  the identical ABI against the identical artifact, and doing so is the natural
  next step. This module is the boundary that step would replace; the corpus and
  its expectations do not change when it does.

  ## Availability

  `available?/1` reports whether a real `node` binary and the real pinned wasm
  are both present. Callers degrade to a **named, visible skip**, never to a
  stubbed result: a fabricated engine answer would defeat the entire point of a
  portability corpus.
  """

  @wasm_env_var "SA2A_GRAPHLAW_WASM"
  @default_wasm "/Users/sac/praxis/crates/praxis-graphlaw-wasm/pkg/praxis_graphlaw_wasm_bg.wasm"

  @doc """
  Resolves the pinned wasm path: `opts[:wasm_path]`, else the
  `SA2A_GRAPHLAW_WASM` environment variable, else
  `Application.get_env(:ash_a2a, :sa2a_graphlaw_wasm)`, else a default pointing
  at the praxis checkout.

  Configurable rather than hardcoded because the wasm is a workspace artifact
  built from a sibling Rust crate -- it is not vendored into this repo, and the
  computed default only resolves on a machine that has that checkout.
  """
  @spec wasm_path(keyword()) :: String.t()
  def wasm_path(opts \\ []) do
    Keyword.get(opts, :wasm_path) ||
      System.get_env(@wasm_env_var) ||
      Application.get_env(:ash_a2a, :sa2a_graphlaw_wasm, @default_wasm)
  end

  @doc "Path to the committed Node driver that implements the wasm-bindgen ABI."
  @spec driver_path() :: String.t()
  def driver_path,
    do: Path.join([to_string(:code.priv_dir(:ash_a2a)), "sa2a_graphlaw", "verify.mjs"])

  @doc """
  Whether a real run is possible here: a real `node` on PATH, the real driver on
  disk, and the real pinned wasm on disk.

  Returns `:ok` or `{:unavailable, reason}` -- a reason, not a bare boolean, so a
  skip says which of the three is missing.
  """
  @spec available?(keyword()) :: :ok | {:unavailable, atom()}
  def available?(opts \\ []) do
    cond do
      System.find_executable("node") == nil -> {:unavailable, :node_not_installed}
      not File.exists?(driver_path()) -> {:unavailable, :driver_missing}
      not File.exists?(wasm_path(opts)) -> {:unavailable, :wasm_not_built}
      true -> :ok
    end
  end

  @doc """
  Really runs the real wasm over the real corpus directory and returns the
  decoded measurements.

  Returns `{:ok, map}` iff the subprocess exits `0`, its stdout decodes as JSON,
  and that JSON carries no `"error"` key. Every other real outcome is
  `{:error, map}` with a `:code`:

    * `:sa2a_graphlaw_unavailable` -- node, driver or wasm missing
    * `:sa2a_graphlaw_nonzero_exit`
    * `:sa2a_graphlaw_non_json_stdout`
    * `:sa2a_graphlaw_driver_error`
  """
  @spec measure(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def measure(corpus_dir, opts \\ []) when is_binary(corpus_dir) do
    case available?(opts) do
      {:unavailable, reason} ->
        {:error, %{code: :sa2a_graphlaw_unavailable, detail: reason}}

      :ok ->
        run(corpus_dir, opts)
    end
  end

  defp run(corpus_dir, opts) do
    {stdout, exit_code} =
      System.cmd("node", [driver_path(), corpus_dir, wasm_path(opts)], stderr_to_stdout: false)

    # Decode BEFORE consulting the exit code: the driver reports every fault it
    # can name as a JSON `{"error": ...}` on stdout AND a non-zero exit, and the
    # named message is strictly more useful than the number.
    case JSON.decode(stdout) do
      {:ok, %{"error" => message}} ->
        {:error, %{code: :sa2a_graphlaw_driver_error, detail: message, exit: exit_code}}

      {:ok, decoded} when is_map(decoded) and exit_code == 0 ->
        {:ok, decoded}

      {:ok, _decoded} ->
        {:error, %{code: :sa2a_graphlaw_nonzero_exit, detail: %{exit: exit_code}}}

      _ ->
        {:error,
         %{
           code: :sa2a_graphlaw_non_json_stdout,
           detail: %{exit: exit_code, stdout: String.slice(stdout, 0, 500)}
         }}
    end
  end
end
