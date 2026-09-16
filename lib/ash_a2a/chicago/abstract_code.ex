defmodule AshA2A.Chicago.AbstractCode do
  @moduledoc """
  Static reading of compiled BEAM abstract code (the `:debug_info` chunk) for
  Chicago courts that need proofs over what a module *can* call rather than
  what one run happened to do (RFC-SA2A-002 §108 observer non-authority, §17
  SUT event vocabulary).

  Reads the exact `.beam` the VM loaded (`:code.which/1`), so the proof is
  about the subject under qualification, not its source text. A module whose
  BEAM carries no debug info is reported `{:error, :no_debug_info}` -- never
  treated as "no calls".

  Call classification over Erlang abstract format:

    * `{:remote, m, f, arity}` -- `m:f(...)` with literal module and function
      (including literal `:erlang.apply(m, f, [..])` / `apply/3`)
    * `{:fun_ref, m, f, arity}` -- `&m.f/arity` (a remote function value)
    * `{:local, f, arity}` -- a call or `&f/arity` into the same module
    * `{:dynamic_remote, f, arity}` -- `expr:f(...)` with a non-literal module
    * `{:dynamic_apply, arity}` -- `apply/2,3` whose target is not literal
    * `{:closure_apply, arity}` -- `fun.(...)` on a variable/expression
    * `{:field_access, field}` -- Elixir `map.field` (`:elixir_erl_pass.no_parens_remote/2`)
  """

  @type call ::
          {:remote, module(), atom(), non_neg_integer()}
          | {:fun_ref, module(), atom(), non_neg_integer()}
          | {:local, atom(), non_neg_integer()}
          | {:dynamic_remote, atom() | nil, non_neg_integer()}
          | {:dynamic_apply, non_neg_integer()}
          | {:closure_apply, non_neg_integer()}
          | {:field_access, atom()}

  @doc "Erlang abstract forms of the loaded `module`'s BEAM."
  @spec forms(module()) :: {:ok, [tuple()]} | {:error, term()}
  def forms(module) when is_atom(module) do
    with {:ok, path} <- beam_path(module),
         {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(path, [:debug_info]),
         {:ok, forms} <- backend.debug_info(:erlang_v1, module, data, []) do
      {:ok, forms}
    else
      {:ok, {_, [debug_info: :none]}} -> {:error, :no_debug_info}
      {:error, :beam_lib, reason} -> {:error, {:beam_lib, reason}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_debug_info, other}}
    end
  rescue
    exception -> {:error, {:debug_info_raised, Exception.message(exception)}}
  end

  @doc "`%{{name, arity} => [call]}` for every function in `module`."
  @spec calls_by_function(module()) :: {:ok, %{{atom(), arity()} => [call()]}} | {:error, term()}
  def calls_by_function(module) do
    with {:ok, forms} <- forms(module) do
      {:ok,
       for {:function, _anno, name, arity, clauses} <- forms, into: %{} do
         {{name, arity}, clauses |> walk([]) |> Enum.reverse()}
       end}
    end
  end

  @doc """
  The functions of `module` reachable from `roots` through local calls and
  local function references (`:all` = every function), with their calls.
  """
  @spec reachable(module(), :all | [{atom(), arity()}]) ::
          {:ok, %{{atom(), arity()} => [call()]}} | {:error, term()}
  def reachable(module, roots) do
    with {:ok, by_fun} <- calls_by_function(module) do
      case roots do
        :all -> {:ok, by_fun}
        roots -> {:ok, Map.take(by_fun, closure(by_fun, roots, MapSet.new()) |> MapSet.to_list())}
      end
    end
  end

  defp closure(_by_fun, [], seen), do: seen

  defp closure(by_fun, [fa | rest], seen) do
    if MapSet.member?(seen, fa) or not Map.has_key?(by_fun, fa) do
      closure(by_fun, rest, seen)
    else
      locals = for {:local, f, a} <- Map.fetch!(by_fun, fa), do: {f, a}
      closure(by_fun, locals ++ rest, MapSet.put(seen, fa))
    end
  end

  @doc """
  Literal `:telemetry.execute/2,3` and `:telemetry.span/3` event names in
  `module`, plus the count of call sites whose event name is not a literal.
  `span` events expand to their `:start`, `:stop` and `:exception` events.
  """
  @spec telemetry_events(module()) ::
          {:ok, %{events: [[atom()]], dynamic_sites: non_neg_integer()}} | {:error, term()}
  def telemetry_events(module) do
    with {:ok, forms} <- forms(module) do
      {events, dynamic} =
        forms
        |> collect_telemetry([])
        |> Enum.reduce({[], 0}, fn
          {:literal, :span, event}, {acc, d} ->
            {Enum.map([:start, :stop, :exception], &(event ++ [&1])) ++ acc, d}

          {:literal, :execute, event}, {acc, d} ->
            {[event | acc], d}

          :dynamic, {acc, d} ->
            {acc, d + 1}
        end)

      {:ok, %{events: events |> Enum.uniq() |> Enum.sort(), dynamic_sites: dynamic}}
    end
  end

  defp collect_telemetry(
         {:call, _, {:remote, _, {:atom, _, :telemetry}, {:atom, _, fun}}, [event | _] = args},
         acc
       )
       when fun in [:execute, :span] do
    acc =
      case literal_atom_list(event) do
        {:ok, list} -> [{:literal, fun, list} | acc]
        :error -> [:dynamic | acc]
      end

    collect_telemetry(args, acc)
  end

  defp collect_telemetry(term, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> collect_telemetry(acc)

  defp collect_telemetry(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_telemetry/2)

  defp collect_telemetry(_term, acc), do: acc

  defp literal_atom_list(form) do
    value = :erl_parse.normalise(form)

    if is_list(value) and value != [] and Enum.all?(value, &is_atom/1),
      do: {:ok, value},
      else: :error
  rescue
    _ -> :error
  end

  # --- generic walk over abstract format -------------------------------------

  defp walk(
         {:call, _, {:remote, _, {:atom, _, :elixir_erl_pass}, {:atom, _, :no_parens_remote}},
          [subject, {:atom, _, field}]},
         acc
       ),
       do: walk(subject, [{:field_access, field} | acc])

  defp walk({:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :apply}}, args}, acc) do
    call =
      case args do
        [{:atom, _, m}, {:atom, _, f}, list] ->
          case list_length(list) do
            {:ok, n} -> {:remote, m, f, n}
            :error -> {:dynamic_apply, length(args)}
          end

        _ ->
          {:dynamic_apply, length(args)}
      end

    walk(args, [call | acc])
  end

  defp walk({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args}, acc),
    do: walk(args, [{:remote, m, f, length(args)} | acc])

  defp walk({:call, _, {:remote, _, module_expr, {:atom, _, f}}, args}, acc),
    do: walk([module_expr | args], [{:dynamic_remote, f, length(args)} | acc])

  defp walk({:call, _, {:remote, _, module_expr, fun_expr}, args}, acc),
    do: walk([module_expr, fun_expr | args], [{:dynamic_remote, nil, length(args)} | acc])

  defp walk({:call, _, {:atom, _, f}, args}, acc),
    do: walk(args, [{:local, f, length(args)} | acc])

  defp walk({:call, _, fun_expr, args}, acc),
    do: walk([fun_expr | args], [{:closure_apply, length(args)} | acc])

  defp walk({:fun, _, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}}, acc),
    do: [{:fun_ref, m, f, a} | acc]

  defp walk({:fun, _, {:function, f, a}}, acc) when is_atom(f) and is_integer(a),
    do: [{:local, f, a} | acc]

  defp walk(term, acc) when is_tuple(term), do: term |> Tuple.to_list() |> walk(acc)
  defp walk(list, acc) when is_list(list), do: Enum.reduce(list, acc, &walk/2)
  defp walk(_term, acc), do: acc

  defp list_length({nil, _}), do: {:ok, 0}

  defp list_length({:cons, _, _head, tail}) do
    with {:ok, n} <- list_length(tail), do: {:ok, n + 1}
  end

  defp list_length(_), do: :error

  # `:code.which/1` finds the object file on the code path without loading
  # the module, so reading abstract code never runs a module's `on_load`.
  defp beam_path(module) do
    case :code.which(module) do
      path when is_list(path) and path != [] -> {:ok, path}
      other -> {:error, {:no_beam_file, other}}
    end
  end
end
