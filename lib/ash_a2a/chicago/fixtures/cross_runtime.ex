defmodule AshA2A.Chicago.Fixtures.CrossRuntime do
  @moduledoc """
  Real fixtures for the SA2A-XRUNTIME court
  (`AshA2A.Chicago.Courts.CrossRuntimePortability`, RFC-SA2A-002 §76, §91,
  §125, §126).

  Nothing here computes a semantic answer. Every fixture is either real input
  on disk for the real `AshA2A.SA2A.Conformance` court, a real WebAssembly
  artifact the real hosts load and execute, or a real `AshA2A.GraphLaw.Runtime`
  whose every call reaches a real engine:

    * `corpus!/3` -- a real conformance corpus directory: vectors copied from
      the real corpus (`AshA2A.SA2A.Vector.corpus_dir/0`) plus, on request,
      negative fixtures written here (`x001_malformed_turtle`: a document that
      is not RDF 1.1 Turtle, which the GraphLaw engine nevertheless hashes and
      admits -- measured, see `negative_fixtures/0`).
    * `degenerate_wasm!/1` -- a real, valid wasm module implementing the
      `wasm-bindgen` string ABI every host speaks, whose every GraphLaw export
      returns the two-byte string `{}`. One content-addressed artifact that
      every real host executes identically and that computes nothing: the
      `{:ok, <degenerate result>}` environment fault.
    * `DecoyResourceRuntime`, `HiddenEngineRuntime` -- two masquerades of the
      in-BEAM Wasmtime engine (`AshA2A.GraphLaw.WasmexSession`) under
      different labels: one whose session also names an idle decoy process,
      one that executes every call inside an `Agent` so its session names no
      engine at all. Every call really executes in the real wasm engine.
  """

  alias AshA2A.SA2A.Vector

  @malformed_turtle """
  @prefix ex: <http://example.org/> .

  ex:alice ex:name "Alice" ;;; <<< this document is not RDF 1.1 Turtle {{{
  ex:bob ex:knows ex:alice
  """

  @doc """
  The negative fixtures `corpus!/3` can add, as `{id, files}`. Each must be
  REFUSED by every host with an equivalent refusal class (§76).
  """
  @spec negative_fixtures() :: %{atom() => {String.t(), %{String.t() => String.t()}}}
  def negative_fixtures do
    %{
      malformed_turtle:
        {"x001_malformed_turtle",
         %{
           "base.ttl" => @malformed_turtle,
           "vector.json" =>
             JSON.encode!(%{
               "id" => "x001_malformed_turtle",
               "title" => "Not RDF 1.1 Turtle (negative fixture)",
               "intent" =>
                 "A document that does not parse as Turtle. Measured against praxis-graphlaw " <>
                   "v26.7.5: graph_hash hashes it, validate_all and run_hooks ADMIT it. Both " <>
                   "hosts agreeing on that admission is agreement on a degenerate result, not " <>
                   "conformance; the fixture must be refused, equivalently, by every host.",
               "rfc_sections" => ["S12", "S41", "RFC-SA2A-002 S76"],
               "polarity" => "negative"
             })
         }}
    }
  end

  @doc "Id of a negative fixture (see `negative_fixtures/0`)."
  @spec negative_id(atom()) :: String.t()
  def negative_id(name), do: negative_fixtures() |> Map.fetch!(name) |> elem(0)

  @doc """
  Writes a real corpus directory under `dir`: the listed real vector ids
  (`:all` for every real vector) plus the named negative fixtures.
  """
  @spec corpus!(Path.t(), [String.t()] | :all, [atom()]) :: Path.t()
  def corpus!(dir, vector_ids, negatives \\ []) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    source = Vector.corpus_dir()

    ids =
      case vector_ids do
        :all ->
          source
          |> File.ls!()
          |> Enum.filter(&File.exists?(Path.join([source, &1, "base.ttl"])))

        ids ->
          ids
      end

    for id <- ids do
      File.cp_r!(Path.join(source, id), Path.join(dir, id))
    end

    for name <- negatives do
      {id, files} = Map.fetch!(negative_fixtures(), name)
      vector_dir = Path.join(dir, id)
      File.mkdir_p!(vector_dir)
      for {file, contents} <- files, do: File.write!(Path.join(vector_dir, file), contents)
    end

    dir
  end

  # --- the degenerate artifact ---------------------------------------------------

  @doc """
  Writes the degenerate GraphLaw artifact to `dir` and returns its path.

  A hand-assembled, valid WebAssembly 1.0 module with the export surface
  every GraphLaw host requires (`memory`, `__wbindgen_add_to_stack_pointer`,
  `__wbindgen_export2..4`, `graphlaw_version`, `validate_all`, `graph_hash`,
  `run_hooks`, `blake3_hex`): a real stack pointer, a real bump allocator, and
  string-returning exports that write `(ptr, len)` of the data segment `{}`
  at `retptr`. Every host that speaks the `wasm-bindgen` string ABI decodes
  exactly `{}` from every call.
  """
  @spec degenerate_wasm!(Path.t()) :: Path.t()
  def degenerate_wasm!(dir) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "degenerate_graphlaw.wasm")
    File.write!(path, degenerate_wasm_bytes())
    path
  end

  @i32 0x7F
  @data_offset 16
  @result "{}"
  # 64 pages; the shadow stack starts at the top of linear memory.
  @pages 64
  @stack_top @pages * 65_536
  @heap_base 4_096

  @doc false
  @spec degenerate_wasm_bytes() :: binary()
  def degenerate_wasm_bytes do
    types = [
      {[@i32], [@i32]},
      {[@i32, @i32], [@i32]},
      {[@i32, @i32, @i32, @i32], [@i32]},
      {[@i32, @i32, @i32], []},
      {[@i32], []},
      {List.duplicate(@i32, 5), []},
      {List.duplicate(@i32, 11), []}
    ]

    # {export name, type index, body}
    returns_result =
      <<0x20, 0x00, 0x41>> <>
        sleb(@data_offset) <>
        <<0x36, 0x02, 0x00, 0x20, 0x00, 0x41>> <>
        sleb(byte_size(@result)) <> <<0x36, 0x02, 0x04>>

    functions = [
      {"__wbindgen_add_to_stack_pointer", 0,
       <<0x23, 0x00, 0x20, 0x00, 0x6A, 0x24, 0x00, 0x23, 0x00>>},
      {"__wbindgen_export2", 1, <<0x23, 0x01, 0x23, 0x01, 0x20, 0x00, 0x6A, 0x24, 0x01>>},
      {"__wbindgen_export3", 2, <<0x23, 0x01, 0x23, 0x01, 0x20, 0x02, 0x6A, 0x24, 0x01>>},
      {"__wbindgen_export4", 3, <<>>},
      {"graphlaw_version", 4, returns_result},
      {"validate_all", 6, returns_result},
      {"graph_hash", 3, returns_result},
      {"run_hooks", 5, returns_result},
      {"blake3_hex", 3, returns_result}
    ]

    type_section =
      vec(
        Enum.map(types, fn {params, results} ->
          <<0x60>> <> vec(Enum.map(params, &<<&1>>)) <> vec(Enum.map(results, &<<&1>>))
        end)
      )

    function_section = vec(Enum.map(functions, fn {_, type, _} -> uleb(type) end))
    memory_section = vec([<<0x00>> <> uleb(@pages)])

    global_section =
      vec([
        <<@i32, 0x01, 0x41>> <> sleb(@stack_top) <> <<0x0B>>,
        <<@i32, 0x01, 0x41>> <> sleb(@heap_base) <> <<0x0B>>
      ])

    export_section =
      vec(
        [name("memory") <> <<0x02, 0x00>>] ++
          (functions
           |> Enum.with_index()
           |> Enum.map(fn {{export, _, _}, index} -> name(export) <> <<0x00>> <> uleb(index) end))
      )

    code_section =
      vec(
        Enum.map(functions, fn {_, _, body} ->
          func = vec([]) <> body <> <<0x0B>>
          uleb(byte_size(func)) <> func
        end)
      )

    data_section =
      vec([<<0x00, 0x41>> <> sleb(@data_offset) <> <<0x0B>> <> name(@result)])

    <<0x00, ?a, ?s, ?m, 0x01, 0x00, 0x00, 0x00>> <>
      section(1, type_section) <>
      section(3, function_section) <>
      section(5, memory_section) <>
      section(6, global_section) <>
      section(7, export_section) <>
      section(10, code_section) <>
      section(11, data_section)
  end

  defp section(id, body), do: <<id>> <> uleb(byte_size(body)) <> body
  defp vec(items), do: uleb(length(items)) <> IO.iodata_to_binary(items)
  defp name(text), do: uleb(byte_size(text)) <> text

  defp uleb(n) when n < 0x80, do: <<n>>

  defp uleb(n) do
    import Bitwise
    <<(n &&& 0x7F) ||| 0x80>> <> uleb(n >>> 7)
  end

  defp sleb(n) do
    import Bitwise
    byte = n &&& 0x7F
    rest = n >>> 7

    if (rest == 0 and (byte &&& 0x40) == 0) or (rest == -1 and (byte &&& 0x40) != 0),
      do: <<byte>>,
      else: <<byte ||| 0x80>> <> sleb(rest)
  end

  # --- masquerading runtimes -------------------------------------------------------

  defmodule DecoyResourceRuntime do
    @moduledoc """
    A real runtime that IS `AshA2A.GraphLaw.WasmexSession` -- every call
    reaches the real in-BEAM Wasmtime instance and returns the real string the
    wasm produced -- under different labels (`"WASI/DecoyHost"`, `"wamr"`),
    whose session term additionally names a real, idle decoy process. An
    identity read from the session term alone sees a different resource list
    than `WasmexSession`'s (RFC-SA2A-002 §126). Not a mock: it fakes no
    interaction and returns nothing canned.
    """

    @behaviour AshA2A.GraphLaw.Runtime

    alias AshA2A.GraphLaw.WasmexSession

    @impl true
    def host_id, do: "WASI/DecoyHost"

    @impl true
    def engine_id, do: "wamr"

    @impl true
    def available?(opts \\ []), do: WasmexSession.available?(opts)

    @impl true
    def open(opts \\ []) do
      with {:ok, %{session: inner, wasm_digest: digest}} <- WasmexSession.open(opts) do
        {:ok, decoy} = Agent.start(fn -> :decoy end)
        {:ok, %{session: %{inner: inner, decoy: decoy}, wasm_digest: digest}}
      end
    end

    @impl true
    def call(%{inner: inner}, fun, args), do: WasmexSession.call(inner, fun, args)

    @impl true
    def close(%{inner: inner, decoy: decoy}) do
      WasmexSession.close(inner)
      if Process.alive?(decoy), do: Agent.stop(decoy)
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  defmodule HiddenEngineRuntime do
    @moduledoc """
    A real runtime that IS `AshA2A.GraphLaw.WasmexSession`, executed one hop
    away: `open/1` starts an `Agent` that opens the real in-BEAM Wasmtime
    session in its own state, and every `call/3` runs inside that `Agent`.
    Its session term is `%{agent: pid}` -- it names no engine resource at all
    -- and its labels are `"WASI/IsolatedHost"` / `"wasmer"`. Every call really
    executes in the real wasm engine (RFC-SA2A-002 §126).
    """

    @behaviour AshA2A.GraphLaw.Runtime

    alias AshA2A.GraphLaw.WasmexSession

    @impl true
    def host_id, do: "WASI/IsolatedHost"

    @impl true
    def engine_id, do: "wasmer"

    @impl true
    def available?(opts \\ []), do: WasmexSession.available?(opts)

    @impl true
    def open(opts \\ []) do
      {:ok, agent} = Agent.start(fn -> WasmexSession.open(opts) end)

      case Agent.get(agent, & &1, :infinity) do
        {:ok, %{wasm_digest: digest}} ->
          {:ok, %{session: %{agent: agent}, wasm_digest: digest}}

        {:error, _} = error ->
          Agent.stop(agent)
          error
      end
    end

    @impl true
    def call(%{agent: agent}, fun, args) do
      Agent.get(
        agent,
        fn {:ok, %{session: session}} -> WasmexSession.call(session, fun, args) end,
        :infinity
      )
    end

    @impl true
    def close(%{agent: agent}) do
      if Process.alive?(agent) do
        Agent.get(agent, fn {:ok, %{session: session}} -> WasmexSession.close(session) end)
        Agent.stop(agent)
      end

      :ok
    catch
      :exit, _ -> :ok
    end
  end
end
