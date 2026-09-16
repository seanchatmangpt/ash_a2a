defmodule AshA2A.Chicago.Collaborators.MockScan do
  @moduledoc """
  Zero-mock static scan (RFC-SA2A-002 §10, §34) over Elixir source trees.

  The scan reads every `.ex`/`.exs` file under the given directories and parses
  it with `Code.string_to_quoted/2`. It inspects the resulting AST, never the
  raw text, so a comment, a docstring, a string literal, or a bare atom that
  merely *names* a mocking library is not a violation, while a real call into
  one is -- with its file and line.

  ## What counts as a violation

    * a remote call into a mocking library: `Mox.expect(...)`,
      `Hammox.stub(...)`, `Mock.with_mock(...)`, `Mimic.copy(...)`,
      `Patch.patch(...)`, `:meck.new(...)` (also captures `&:meck.new/2`)
    * `use`/`import`/`require`/`alias` of one of those libraries
    * `apply(Mox, :expect, ...)` / `apply(:meck, :new, ...)`
    * the call macros those libraries inject: `with_mock`, `with_mocks`,
      `test_with_mock`, `setup_with_mocks`, `defmock`
    * the `Patch` library shape `patch(Module, :function, value)` -- a
      module/atom first argument and an atom second argument. A Phoenix-style
      `patch(conn, "/path")` is not that shape and is not flagged.

  A file that does not parse is reported as unparseable: an unreadable source
  cannot be certified mock-free, so it fails the scan closed.

  Hand-written, real implementations of a behaviour (a store, a broker) are
  not mocks under §10 and are not what this scan looks for.
  """

  @mock_alias_heads [:Mox, :Hammox, :Mock, :Mimic, :Patch]
  @mock_erlang_modules [:meck, :"Elixir.Mox", :"Elixir.Hammox", :"Elixir.Mock", :"Elixir.Mimic"]
  @directives [:use, :import, :require, :alias]
  @mock_macros [:with_mock, :with_mocks, :test_with_mock, :setup_with_mocks, :defmock]

  @type violation :: %{
          file: String.t(),
          line: non_neg_integer(),
          column: non_neg_integer() | nil,
          call: String.t()
        }

  @type unparseable :: %{file: String.t(), line: non_neg_integer(), detail: String.t()}

  @type result :: %{
          root: String.t(),
          dirs: [String.t()],
          missing_dirs: [String.t()],
          files: non_neg_integer(),
          violations: [violation()],
          unparseable: [unparseable()],
          outcome: :clean | :violations
        }

  @doc """
  Scans `dirs` (relative to `root`). Paths in the result are relative to
  `root`. Options: `:root` (default `File.cwd!()`), `:dirs` (default
  `["lib", "test"]`).
  """
  @spec scan(keyword()) :: result()
  def scan(opts \\ []) do
    root = opts |> Keyword.get_lazy(:root, &File.cwd!/0) |> Path.expand()
    dirs = Keyword.get(opts, :dirs, ["lib", "test"])
    {present, missing} = Enum.split_with(dirs, &File.dir?(Path.join(root, &1)))

    files =
      present
      |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**", "*.{ex,exs}"])))
      |> Enum.uniq()
      |> Enum.sort()

    {violations, unparseable} =
      Enum.reduce(files, {[], []}, fn path, {violations, unparseable} ->
        rel = Path.relative_to(path, root)

        case path |> File.read!() |> scan_source(rel) do
          {:ok, found} -> {violations ++ found, unparseable}
          {:error, bad} -> {violations, [bad | unparseable]}
        end
      end)

    unparseable = Enum.reverse(unparseable)

    %{
      root: root,
      dirs: present,
      missing_dirs: missing,
      files: length(files),
      violations: violations,
      unparseable: unparseable,
      outcome: if(violations == [] and unparseable == [], do: :clean, else: :violations)
    }
  end

  @doc """
  Scans one source string. Returns every mock call site in source order, or
  `{:error, unparseable}` when the source is not valid Elixir.
  """
  @spec scan_source(String.t(), String.t()) :: {:ok, [violation()]} | {:error, unparseable()}
  def scan_source(source, file) when is_binary(source) and is_binary(file) do
    case Code.string_to_quoted(source, file: file, columns: true, emit_warnings: false) do
      {:ok, ast} ->
        {_ast, found} = Macro.prewalk(ast, [], &collect(&1, &2, file))
        {:ok, found |> Enum.reverse() |> Enum.sort_by(&{&1.line, &1.column || 0})}

      {:error, {meta, message, token}} ->
        {:error, %{file: file, line: error_line(meta), detail: error_detail(message, token)}}
    end
  end

  # Capture: &:meck.new/2, &Mox.expect/3 -- reported once with its real arity;
  # the node is replaced so the walk does not count the inner call again.
  defp collect({:&, meta, [{:/, _, [{{:., _, [target, fun]}, _, []}, arity]}]} = node, acc, file)
       when is_atom(fun) and is_integer(arity) do
    case mock_module(target) do
      nil -> {node, acc}
      name -> {:captured, [violation(file, meta, "&#{name}.#{fun}/#{arity}") | acc]}
    end
  end

  # Remote call: Mox.expect(...), :meck.new(...)
  defp collect({{:., _, [target, fun]}, meta, args} = node, acc, file)
       when is_atom(fun) and is_list(args) do
    case mock_module(target) do
      nil -> {node, acc}
      name -> {node, [violation(file, meta, "#{name}.#{fun}/#{length(args)}") | acc]}
    end
  end

  # use Mox / import Mock / require Mimic / alias Hammox
  defp collect({directive, meta, [target | _]} = node, acc, file)
       when directive in @directives do
    case mock_module(target) do
      nil -> {node, acc}
      name -> {node, [violation(file, meta, "#{directive} #{name}") | acc]}
    end
  end

  # apply(Mox, :expect, [...])
  defp collect({:apply, meta, [target, fun, _args]} = node, acc, file) when is_atom(fun) do
    case mock_module(target) do
      nil -> {node, acc}
      name -> {node, [violation(file, meta, "apply(#{name}, #{inspect(fun)}, ...)") | acc]}
    end
  end

  # with_mock Clock, [...] do ... end ; defmock(ClockMock, for: Clock)
  defp collect({macro, meta, args} = node, acc, file)
       when macro in @mock_macros and is_list(args) do
    {node, [violation(file, meta, "#{macro}/#{length(args)}") | acc]}
  end

  # Patch library: patch(Module, :function, value)
  defp collect({:patch, meta, [target, fun, _value]} = node, acc, file) when is_atom(fun) do
    if module_ref?(target),
      do: {node, [violation(file, meta, "patch/3") | acc]},
      else: {node, acc}
  end

  defp collect(node, acc, _file), do: {node, acc}

  defp mock_module({:__aliases__, _, [head | _] = parts}) when head in @mock_alias_heads,
    do: Enum.map_join(parts, ".", &Atom.to_string/1)

  defp mock_module(atom) when atom in @mock_erlang_modules, do: inspect(atom)
  defp mock_module(_), do: nil

  defp module_ref?({:__aliases__, _, _}), do: true
  defp module_ref?(atom) when is_atom(atom) and atom not in [nil, true, false], do: true
  defp module_ref?(_), do: false

  defp violation(file, meta, call) do
    %{
      file: file,
      line: Keyword.get(meta, :line, 0),
      column: Keyword.get(meta, :column),
      call: call
    }
  end

  defp error_line(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp error_line(line) when is_integer(line), do: line
  defp error_line(_), do: 0

  defp error_detail(message, token) when is_binary(message) and is_binary(token),
    do: message <> token

  defp error_detail({prefix, suffix}, token) when is_binary(prefix) and is_binary(suffix),
    do: prefix <> suffix <> to_string(token)

  defp error_detail(message, token), do: inspect({message, token})
end
