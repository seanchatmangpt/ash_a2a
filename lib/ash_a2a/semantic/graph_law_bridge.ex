defmodule AshA2A.Semantic.GraphLawBridge do
  @moduledoc """
  Real invocation of the real praxis-graphlaw WebAssembly engine from Elixir.

  This module is a **transport**, not an engine. It owns zero RDF logic: every
  parse, hash, validation and entailment happens inside the real
  `praxis_graphlaw_wasm_bg.wasm` build of the Rust `praxis-graphlaw` crate
  (native N3, Datalog, SPARQL 1.1, SHACL, ShEx). Elixir's job at this boundary
  is bytes in, bytes out -- per RFC-SA2A-001's separation of the A2A/standing
  layer from the semantic engine.

  ## Host resolution order

    1. `AshA2A.GraphLaw.Wasm` -- if that module is loaded (an in-BEAM wasm host,
       e.g. via `wasmex`), its `graph_hash/1` is used directly. This bridge
       defers to it rather than competing with it.
    2. A real `node` subprocess over `priv/graphlaw/graphlaw_invoke.mjs`,
       following exactly the real-subprocess pattern this repo already uses for
       the native solver in `AshA2A.Planning.HddlSolver` -- write a real request
       file, run a real OS process, decode its real stdout JSON.

  Nothing here simulates a result. Every `{:ok, _}` this module returns came
  out of the real wasm module's linear memory.

  ## Configuration

      config :ash_a2a,
        graphlaw_wasm_path: "/abs/path/praxis_graphlaw_wasm_bg.wasm",
        graphlaw_node_path: "node"

  `graphlaw_wasm_path` also honours the `ASH_A2A_GRAPHLAW_WASM` environment
  variable, falling back to the checkout-relative praxis path. Like
  `AshA2A.Planning.HddlSolver`'s `cli_path/1`, the default only resolves on a
  machine that has the praxis workspace -- `available?/0` reports that
  honestly instead of raising.
  """

  alias AshA2A.Semantic.Serialize

  @default_wasm_path "/Users/sac/praxis/crates/praxis-graphlaw-wasm/pkg/praxis_graphlaw_wasm_bg.wasm"

  @doc "Absolute path of the real praxis-graphlaw wasm module."
  @spec wasm_path(keyword()) :: String.t()
  def wasm_path(opts \\ []) do
    Keyword.get(opts, :wasm_path) ||
      Application.get_env(:ash_a2a, :graphlaw_wasm_path) ||
      System.get_env("ASH_A2A_GRAPHLAW_WASM") ||
      @default_wasm_path
  end

  @doc "Absolute path of the real Node host shim shipped in `priv/`."
  @spec shim_path() :: String.t()
  def shim_path do
    case :code.priv_dir(:ash_a2a) do
      {:error, _} -> Path.expand("../../../priv/graphlaw/graphlaw_invoke.mjs", __DIR__)
      dir -> Path.join([to_string(dir), "graphlaw", "graphlaw_invoke.mjs"])
    end
  end

  @doc "Executable used to run the host shim."
  @spec node_path(keyword()) :: String.t()
  def node_path(opts \\ []) do
    Keyword.get(opts, :node_path) || Application.get_env(:ash_a2a, :graphlaw_node_path) || "node"
  end

  @doc """
  True iff a real GraphLaw host is actually reachable on this machine: either
  an in-BEAM `AshA2A.GraphLaw.Wasm`, or a real `node` executable plus a real
  wasm file plus the shipped shim.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    in_beam_host?(opts) or
      (System.find_executable(node_path(opts)) != nil and File.exists?(wasm_path(opts)) and
         File.exists?(shim_path()))
  end

  @doc """
  Reports which host would actually serve a call -- `:in_beam`, `:node_shim`,
  or `{:unavailable, reason_map}`. Useful in receipts: the host identity is
  part of the SA2A conformance subject.
  """
  @spec host(keyword()) :: :in_beam | :node_shim | {:unavailable, map()}
  def host(opts \\ []) do
    cond do
      in_beam_host?(opts) ->
        :in_beam

      System.find_executable(node_path(opts)) == nil ->
        {:unavailable, %{code: :graphlaw_node_not_found, node_path: node_path(opts)}}

      not File.exists?(wasm_path(opts)) ->
        {:unavailable, %{code: :graphlaw_wasm_not_found, wasm_path: wasm_path(opts)}}

      not File.exists?(shim_path()) ->
        {:unavailable, %{code: :graphlaw_shim_not_found, shim_path: shim_path()}}

      true ->
        :node_shim
    end
  end

  @doc "Real `graphlaw_version()` string from the engine."
  @spec version(keyword()) :: {:ok, String.t()} | {:error, map()}
  def version(opts \\ []), do: call_one("graphlaw_version", [], opts)

  @doc """
  Real canonical graph hash of an RDF document (Turtle or N-Triples).

  Returns the hex digest, or a typed error. Note the measured engine
  behaviour documented in `AshA2A.Semantic.Serialize`: `graph_hash/1` does
  **not** report parse errors, so a caller that has not first gated on
  `Serialize.verify/3` cannot distinguish a digest of the intended graph from
  a digest of a silently truncated one.
  """
  @spec graph_hash(binary(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def graph_hash(document, opts \\ []) when is_binary(document) do
    if in_beam_host?(opts) do
      apply(AshA2A.GraphLaw.Wasm, :graph_hash, [document])
      |> normalize_in_beam()
    else
      call_one("graph_hash", [document], opts)
    end
  end

  @doc "Real `blake3_hex/1` of an arbitrary string, straight from the engine."
  @spec blake3_hex(binary(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def blake3_hex(value, opts \\ []) when is_binary(value),
    do: call_one("blake3_hex", [value], opts)

  @doc """
  Real `run_hooks(base_ttl, event_ttl)`, JSON-decoded via
  `AshA2A.Semantic.Serialize.from_json/1`.
  """
  @spec run_hooks(binary(), binary(), keyword()) :: {:ok, map()} | {:error, map()}
  def run_hooks(base, event, opts \\ []) when is_binary(base) and is_binary(event) do
    with {:ok, raw} <- call_one("run_hooks", [base, event], opts), do: Serialize.from_json(raw)
  end

  @doc """
  Real `validate_all(ttl, profile_ttl, shacl_shapes, shex_schema, shex_shape_map)`,
  JSON-decoded via `AshA2A.Semantic.Serialize.from_json/1`.

  All five arguments are RDF/schema *text*; pass `""` for the ones not in play.
  """
  @spec validate_all(binary(), binary(), binary(), binary(), binary(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def validate_all(ttl, profile \\ "", shacl \\ "", shex \\ "", shape_map \\ "", opts \\ []) do
    with {:ok, raw} <- call_one("validate_all", [ttl, profile, shacl, shex, shape_map], opts),
         do: Serialize.from_json(raw)
  end

  @doc """
  Batched call: `[{"graph_hash", [doc]}, {"blake3_hex", ["abc"]}]`. Returns
  `{:ok, [String.t()]}` in the same order.

  On the `:node_shim` host this is one real wasm instantiation. On the
  `:in_beam` host there is no atomic multi-call primitive, so each call is
  dispatched in order to the same real, already-loaded engine instance and
  the results collected -- N real, independent calls (every `graphlaw_*`
  export is pure and stateless), not one request faked as several.
  """
  @spec call_many([{String.t(), [binary()]}], keyword()) :: {:ok, [String.t()]} | {:error, map()}
  def call_many(calls, opts \\ []) when is_list(calls) do
    case host(opts) do
      {:unavailable, reason} ->
        {:error, reason}

      # `AshA2A.GraphLaw.Wasm` (admission-standing-fixes' subprocess host) has
      # no genuine ATOMIC multi-call primitive -- there is no single request
      # that runs several engine functions in one round trip the way the
      # node-shim's `run_shim/2` does. What every real caller of `call_many/2`
      # in this codebase actually needs, though, is N independent, pure
      # results (each real `graphlaw_*` export is stateless -- no call
      # observes another's effect), not atomicity: `CanonicalDigest`'s
      # turtle/n-triples double `graph_hash` comparison, for one. So each
      # call is dispatched in order through the same real in-BEAM host
      # `call_one/3`'s length-1 case already used, and the results collected
      # in the caller's order -- N real engine calls, honestly, not one
      # request faked as several.
      :in_beam ->
        in_beam_call_many(calls)

      :node_shim ->
        run_shim(calls, opts)
    end
  end

  defp in_beam_call_many(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      case in_beam_call(call) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  # Routes one call to the exact matching real `AshA2A.GraphLaw.Wasm`
  # function. `run_hooks`/`validate_all` there already return a DECODED map
  # (this module's own `run_hooks/3`/`validate_all/6` re-decode via
  # `Serialize.from_json/1` downstream of `call_one/3`), so their result is
  # re-encoded back to the same raw JSON string shape the node-shim path
  # returns -- the one real, minimal seam that lets every caller of
  # `call_one/3` stay host-agnostic.
  defp in_beam_call({"graphlaw_version", []}),
    do: AshA2A.GraphLaw.Wasm.version() |> normalize_in_beam()

  defp in_beam_call({"graph_hash", [ttl]}),
    do: AshA2A.GraphLaw.Wasm.graph_hash(ttl) |> normalize_in_beam()

  defp in_beam_call({"blake3_hex", [value]}),
    do: AshA2A.GraphLaw.Wasm.blake3_hex(value) |> normalize_in_beam()

  defp in_beam_call({"run_hooks", [base, event]}) do
    with {:ok, decoded} <- AshA2A.GraphLaw.Wasm.run_hooks(base, event),
         do: {:ok, JSON.encode!(decoded)}
  end

  defp in_beam_call({"validate_all", [ttl, profile, shacl, shex, shape_map]}) do
    with {:ok, decoded} <-
           AshA2A.GraphLaw.Wasm.validate_all(ttl, profile, shacl, shex, shape_map),
         do: {:ok, JSON.encode!(decoded)}
  end

  defp in_beam_call({fun, args}),
    do: {:error, %{code: :graphlaw_unknown_function, fn: fun, arity: length(args)}}

  defp call_one(fun, args, opts) do
    case call_many([{fun, args}], opts) do
      {:ok, [result]} -> {:ok, result}
      {:ok, other} -> {:error, %{code: :graphlaw_unexpected_result_arity, detail: other}}
      {:error, _} = error -> error
    end
  end

  defp run_shim(calls, opts) do
    payload =
      JSON.encode!(%{
        "calls" => Enum.map(calls, fn {fun, args} -> %{"fn" => fun, "args" => args} end)
      })

    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    unique = System.unique_integer([:positive, :monotonic])
    request_path = Path.join(tmp_dir, "ash_a2a_graphlaw_request_#{unique}.json")
    File.write!(request_path, payload)

    try do
      {stdout, exit_code} =
        System.cmd(node_path(opts), [shim_path(), wasm_path(opts), request_path],
          stderr_to_stdout: false
        )

      decode_shim(stdout, exit_code)
    after
      File.rm(request_path)
    end
  end

  defp decode_shim(stdout, exit_code) do
    case JSON.decode(stdout) do
      {:ok, %{"ok" => true, "results" => results}} when is_list(results) ->
        {:ok, results}

      {:ok, %{"ok" => false, "error" => detail}} ->
        {:error, %{code: :graphlaw_host_error, detail: detail}}

      {:ok, other} ->
        {:error, %{code: :graphlaw_unexpected_host_payload, detail: other}}

      {:error, reason} ->
        {:error,
         %{code: :graphlaw_non_json_stdout, reason: reason, stdout: stdout, exit_code: exit_code}}
    end
  end

  # An explicit `:wasm_path` opt means the caller cares WHICH wasm bytes
  # execute -- `AshA2A.GraphLaw.Wasm`'s in-BEAM host resolves its own
  # application-configured path independently and has no way to honour a
  # per-call override, so it is not a truthful answer to that request. Found
  # by a real test asserting a deliberately-wrong `wasm_path:` produces a
  # typed refusal rather than being silently ignored in favour of whatever
  # wasm the in-BEAM host happens to have loaded.
  defp in_beam_host?(opts) do
    not Keyword.has_key?(opts, :wasm_path) and
      Code.ensure_loaded?(AshA2A.GraphLaw.Wasm) and
      function_exported?(AshA2A.GraphLaw.Wasm, :graph_hash, 1)
  end

  defp normalize_in_beam({:ok, _} = ok), do: ok
  defp normalize_in_beam({:error, _} = error), do: error
  defp normalize_in_beam(hex) when is_binary(hex), do: {:ok, hex}

  defp normalize_in_beam(other),
    do: {:error, %{code: :graphlaw_unexpected_in_beam_result, detail: other}}
end
