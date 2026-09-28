defmodule AshA2A.GraphLaw.EngineLoad do
  @moduledoc """
  The load boundary shared by the in-BEAM GraphLaw hosts
  (`AshA2A.GraphLaw.WasmexHost`, `AshA2A.GraphLaw.WasmexSession`): compile the
  engine bytes, read the module's real host-import surface, and admit it only
  when that surface is a subset of the pinned one the hosts supply (a module
  may import fewer of the two pinned host functions than it's offered --
  Wasmex accepts unused entries in the import map -- but never a foreign one).

  ## Why the surface is checked before instantiation (measured)

  A praxis-graphlaw-wasm build from praxis HEAD `31f149d` (see
  `priv/graphlaw/defects/praxis-head-refresh.json`) imports six host
  functions instead of two (`__wbg_new_*`, `__wbg_stack_*`, `__wbg_error_*`,
  `__wbg___wbindgen_throw_*` in addition to the pinned pair). Handed to
  `Wasmex.start_link/1`, instantiation fails inside the Wasmex GenServer's
  `init/1` with a `MatchError`, which reaches the linked caller as an exit
  signal: `WasmexSession.open/1` crashed its caller and `WasmexHost` crashed
  its supervisor instead of returning the typed error both document. Reading
  the surface from the compiled module first turns that into
  `{:error, %{code: :graphlaw_import_surface_mismatch}}`.

  ## Digest pin (SC-04)

  `load/3` compares the SHA-256 of the bytes against an expected digest before
  any instance is created (the import surface is judged first, so a foreign
  surface keeps its more specific code) -- `opts[:expected_sha256]`, which the hosts default to
  the package pin `pinned_sha256/0` (read from `priv/graphlaw/MANIFEST.json`
  at compile time). A swapped or corrupted `priv/graphlaw/praxis_graphlaw.wasm`
  is refused as `{:error, %{code: :graphlaw_wasm_digest_mismatch}}` instead of
  loading silently. `expected_sha256: :unpinned` is the explicit opt-out a
  caller must name to execute bytes it chose itself (a court's substituted
  artifact, a locally rebuilt engine).

  ## Compiled-module cache (PERF-02)

  Compiling the 3.2 MB module with Cranelift costs about one second. `load/3`
  compiles each `{sha256, fuel?}` pair once per BEAM node, admits its import
  surface once, and keeps `{engine, module, import_names}` in
  `:persistent_term`. Every later load only hashes the bytes (a few ms) and
  hands back the shared compiled module; the caller still builds its own
  `Wasmex.Store` (own fuel budget, own memory limit, own interrupt flag) and
  its own instance, so isolation is unchanged. A wasmtime `Module` is shareable
  across every `Store` built on the `Engine` it was compiled with, and wasmex's
  per-call timeout is a per-store interrupt flag, so sharing the engine does
  not couple the instances' deadlines.

  Telemetry: `[:ash_a2a, :graphlaw, :engine, :load, :start]` (the bytes
  reached the load boundary: `host`, `wasm_sha256`, `bytes`) and
  `[:ash_a2a, :graphlaw, :engine, :load, :stop]` (`host`, `wasm_sha256`,
  `outcome` `:loaded | :refused`, `code`, `import_count`, `unexpected_imports`,
  `missing_imports`).
  """

  @import_module "./praxis_graphlaw_wasm_bg.js"
  @pinned [
    "#{@import_module}::__wbg_getRandomValues_3f44b700395062e5",
    "#{@import_module}::__wbindgen_object_drop_ref"
  ]

  @manifest_path Path.expand("../../../priv/graphlaw/MANIFEST.json", __DIR__)
  @external_resource @manifest_path
  @pinned_sha256 @manifest_path
                 |> File.read!()
                 |> JSON.decode!()
                 |> get_in(["artifact", "sha256"])

  @start [:ash_a2a, :graphlaw, :engine, :load, :start]
  @stop [:ash_a2a, :graphlaw, :engine, :load, :stop]

  @doc false
  def __sa2a_refusal_codes__,
    do: %{
      graphlaw_import_surface_mismatch: :refused_identity,
      graphlaw_wasm_digest_mismatch: :refused_identity,
      graphlaw_wasm_invalid: :refused_structure
    }

  @doc """
  The SHA-256 of `priv/graphlaw/praxis_graphlaw.wasm` pinned by
  `priv/graphlaw/MANIFEST.json` (`artifact.sha256`), read at compile time.
  """
  @spec pinned_sha256() :: String.t()
  def pinned_sha256, do: @pinned_sha256

  @doc """
  `:ok` when `digest` equals `expected`; `:unpinned` (an explicit opt-out)
  admits any digest. Anything else is a typed identity refusal.
  """
  @spec check_digest(String.t(), String.t() | :unpinned) :: :ok | {:error, map()}
  def check_digest(_digest, :unpinned), do: :ok
  def check_digest(digest, digest) when is_binary(digest), do: :ok

  def check_digest(digest, expected) when is_binary(digest) do
    {:error, %{code: :graphlaw_wasm_digest_mismatch, expected: expected, actual: digest}}
  end

  @doc """
  The expected digest for a load: `opts[:expected_sha256]`, else
  `config :ash_a2a, :graphlaw_wasm_sha256`, else `pinned_sha256/0`.
  """
  @spec expected_sha256(keyword()) :: String.t() | :unpinned
  def expected_sha256(opts) do
    Keyword.get(opts, :expected_sha256) ||
      Application.get_env(:ash_a2a, :graphlaw_wasm_sha256) ||
      @pinned_sha256
  end

  @doc """
  Pins, compiles (once per `{sha256, fuel?}` per node) and admits `bytes`.

  Options: `:expected_sha256` (see `expected_sha256/1`; `:unpinned` opts
  out), `:fuel?` (compile for a fuel-metering engine, default `false`).

  Returns `{:ok, %{engine: engine, module: module, import_names: names,
  wasm_sha256: digest}}` or a typed `{:error, map}`; emits the same
  load start/stop telemetry as `admit/3` on cache hits and misses alike.
  """
  @spec load(String.t(), binary(), keyword()) :: {:ok, map()} | {:error, map()}
  def load(host, bytes, opts \\ []) when is_binary(bytes) do
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    base = %{host: host, wasm_sha256: digest}
    fuel? = Keyword.get(opts, :fuel?, false)

    :telemetry.execute(
      @start,
      %{system_time: System.system_time()},
      Map.put(base, :bytes, byte_size(bytes))
    )

    result = cached_compile(digest, bytes, fuel?, expected_sha256(opts))

    case result do
      {:ok, entry} ->
        emit_stop(base, {:ok, entry.module, entry.import_names})
        {:ok, Map.put(entry, :wasm_sha256, digest)}

      {:error, error} = err ->
        emit_stop(base, {:error, error})
        err
    end
  end

  @doc "Drops every cached compiled module (tests and re-vendor tooling)."
  @spec purge_cache() :: :ok
  def purge_cache do
    for {{__MODULE__, :compiled, _, _} = key, _} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    :ok
  end

  @doc "Whether a compiled module for `{sha256, fuel?}` is cached on this node."
  @spec cached?(String.t(), boolean()) :: boolean()
  def cached?(digest, fuel?),
    do: :persistent_term.get({__MODULE__, :compiled, digest, fuel?}, nil) != nil

  # The import surface is judged before the pin, so a substituted engine with
  # a foreign surface still reports `:graphlaw_import_surface_mismatch` (the
  # more specific diagnosis); only a pinned digest is ever cached, so bytes
  # that fail the pin are compiled at most once per attempt and never kept.
  defp cached_compile(digest, bytes, fuel?, expected) do
    key = {__MODULE__, :compiled, digest, fuel?}

    case :persistent_term.get(key, nil) do
      %{} = entry ->
        with :ok <- check_digest(digest, expected), do: {:ok, entry}

      nil ->
        with {:ok, entry} <- compile(bytes, fuel?),
             :ok <- check_digest(digest, expected) do
          :persistent_term.put(key, entry)
          {:ok, entry}
        end
    end
  end

  defp compile(bytes, fuel?) do
    config =
      if fuel?,
        do: Wasmex.EngineConfig.consume_fuel(%Wasmex.EngineConfig{}, true),
        else: %Wasmex.EngineConfig{}

    with {:ok, engine} <- engine_new(config),
         {:ok, store} <- Wasmex.Store.new(nil, engine),
         {:ok, module, names} <- compile_and_check(store, bytes) do
      {:ok, %{engine: engine, module: module, import_names: names}}
    end
  end

  defp engine_new(config) do
    case Wasmex.Engine.new(config) do
      {:ok, engine} -> {:ok, engine}
      {:error, reason} -> {:error, %{code: :graphlaw_wasm_invalid, reason: inspect(reason)}}
    end
  end

  defp compile_and_check(store, bytes) do
    case Wasmex.Module.compile(store, bytes) do
      {:ok, module} ->
        names = import_names(Wasmex.Module.imports(module))
        with :ok <- check_surface(names), do: {:ok, module, names}

      {:error, reason} ->
        {:error, %{code: :graphlaw_wasm_invalid, reason: inspect(reason, limit: 5)}}
    end
  end

  @doc "The two emitted event names."
  @spec events() :: {[atom()], [atom()]}
  def events, do: {@start, @stop}

  @doc "The pinned host-import surface, as sorted `\"module::name\"` strings."
  @spec pinned_imports() :: [String.t()]
  def pinned_imports, do: @pinned

  @doc """
  Compiles `bytes` in `store` and admits the module's import surface.

  Returns `{:ok, module}` or a typed `{:error, map}`; never raises for bad
  bytes or a foreign surface.
  """
  @spec admit(String.t(), binary(), Wasmex.StoreOrCaller.t()) ::
          {:ok, Wasmex.Module.t()} | {:error, map()}
  def admit(host, bytes, store) when is_binary(bytes) do
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    base = %{host: host, wasm_sha256: digest}

    :telemetry.execute(
      @start,
      %{system_time: System.system_time()},
      Map.put(base, :bytes, byte_size(bytes))
    )

    result = compile_and_check(store, bytes)

    emit_stop(base, result)

    case result do
      {:ok, module, _names} -> {:ok, module}
      {:error, _} = error -> error
    end
  end

  @doc """
  `:ok` when `names` is a subset of the pinned surface (a module may import
  fewer than both pinned host functions -- one that never calls into a
  degenerate host still instantiates), else a typed refusal naming every
  entry `names` has that the pinned surface doesn't.
  """
  @spec check_surface([String.t()]) :: :ok | {:error, map()}
  def check_surface(names) when is_list(names) do
    unexpected = names -- @pinned

    if unexpected == [] do
      :ok
    else
      {:error,
       %{
         code: :graphlaw_import_surface_mismatch,
         expected: @pinned,
         actual: names,
         unexpected: unexpected,
         missing: @pinned -- names
       }}
    end
  end

  @doc "`\"module::name\"` strings from `Wasmex.Module.imports/1`, sorted."
  @spec import_names(map()) :: [String.t()]
  def import_names(imports) when is_map(imports) do
    imports
    |> Enum.flat_map(fn {namespace, fns} ->
      fns |> Map.keys() |> Enum.map(&"#{namespace}::#{&1}")
    end)
    |> Enum.sort()
  end

  defp emit_stop(base, {:ok, _module, names}) do
    :telemetry.execute(
      @stop,
      %{system_time: System.system_time()},
      Map.merge(base, %{outcome: :loaded, import_count: length(names)})
    )
  end

  defp emit_stop(base, {:error, error}) do
    :telemetry.execute(
      @stop,
      %{system_time: System.system_time()},
      Map.merge(base, %{
        outcome: :refused,
        code: error.code,
        expected_sha256: Map.get(error, :expected),
        import_count: error |> Map.get(:actual) |> count_imports(),
        unexpected_imports: error |> Map.get(:unexpected, []) |> Enum.join(","),
        missing_imports: error |> Map.get(:missing, []) |> Enum.join(",")
      })
    )
  end

  defp count_imports(list) when is_list(list), do: length(list)
  defp count_imports(_other), do: 0
end
