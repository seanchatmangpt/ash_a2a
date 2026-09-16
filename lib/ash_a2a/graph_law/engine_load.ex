defmodule AshA2A.GraphLaw.EngineLoad do
  @moduledoc """
  The load boundary shared by the in-BEAM GraphLaw hosts
  (`AshA2A.GraphLaw.WasmexHost`, `AshA2A.GraphLaw.WasmexSession`): compile the
  engine bytes, read the module's real host-import surface, and admit it only
  when that surface is exactly the pinned one the hosts supply.

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

  @start [:ash_a2a, :graphlaw, :engine, :load, :start]
  @stop [:ash_a2a, :graphlaw, :engine, :load, :stop]

  @doc false
  def __sa2a_refusal_codes__,
    do: %{
      graphlaw_import_surface_mismatch: :refused_identity,
      graphlaw_wasm_invalid: :refused_structure
    }

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

    result =
      case Wasmex.Module.compile(store, bytes) do
        {:ok, module} ->
          names = import_names(Wasmex.Module.imports(module))

          with :ok <- check_surface(names), do: {:ok, module, names}

        {:error, reason} ->
          {:error, %{code: :graphlaw_wasm_invalid, reason: inspect(reason, limit: 5)}}
      end

    emit_stop(base, result)

    case result do
      {:ok, module, _names} -> {:ok, module}
      {:error, _} = error -> error
    end
  end

  @doc "`:ok` when `names` is exactly the pinned surface, else a typed refusal."
  @spec check_surface([String.t()]) :: :ok | {:error, map()}
  def check_surface(names) when is_list(names) do
    if names == @pinned do
      :ok
    else
      {:error,
       %{
         code: :graphlaw_import_surface_mismatch,
         expected: @pinned,
         actual: names,
         unexpected: names -- @pinned,
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
        import_count: error |> Map.get(:actual, []) |> length(),
        unexpected_imports: error |> Map.get(:unexpected, []) |> Enum.join(","),
        missing_imports: error |> Map.get(:missing, []) |> Enum.join(",")
      })
    )
  end
end
