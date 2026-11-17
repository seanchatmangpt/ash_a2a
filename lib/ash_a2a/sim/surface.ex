# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Compiled only when Bandit is available, like the rest of the simulation
# server (see AshA2A.Sim.Server).
if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.Surface do
    @moduledoc """
    The inventory of what ash_a2a serves, derived from the library itself.

    `items/0` returns one map per served thing. `AshA2A.Sim.Prover` must hold at
    least one probe for every item, so adding a method, route or RPC to the
    library without a probe is caught by `uncovered/1`.

    | Kind | Derived from |
    |---|---|
    | `:jsonrpc_method` | the `dispatch` clauses of `AshA2A.Protocol.JSONRPC` (parsed from its source at compile time), plus the methods `AshA2A.A2ATransport.Plug` routes |
    | `:jsonrpc_alias` | the `@method_aliases` table of `AshA2A.Protocol.JSONRPC` (parsed from its source), plus the alias tables of `AshA2A.A2ATransport.Plug` |
    | `:grpc_rpc` | the `rpc` lines of the A2A proto file (`priv/a2a_v1_1_spec_corpus/a2a.proto`, else `priv/proto/a2a.proto`) |
    | `:http_route` | the `dispatch` clauses of `AshA2A.Transport.HTTPJSON` (parsed from its source), its agent card path and the schema endpoint paths |
    | `:skill` | `AshA2A.Info.capability_index/1` of `AshA2A.Sim.Note` |
    | `:consequence` | the `consequence` option of the `a2a` DSL (`AshA2A.Dsl.sections/0`) |
    | `:task_state` | the `TaskState` enum of the generated proto module |
    | `:security_scheme` | the security schemes on the agent card of `AshA2A.Sim.Agent` |
    | `:mount` | the mounts of the simulation server's router |
    | `:authority` | the authority operations and consequence outcomes `AshA2A.Sim.Authority` lists |
    | `:parity` | the bindings `AshA2A.Sim.Parity` checks against the upstream v1.1 reference |

    Each item is `%{id: String.t(), kind: atom(), name: String.t(), source: String.t()}`.
    The `id` is `"<kind>:<name>"`, for example `"jsonrpc_method:tasks/get"` or
    `"http_route:POST /tasks/{id}:cancel"`.
    """

    @jsonrpc_source Path.expand("../protocol/jsonrpc.ex", __DIR__)
    @http_json_source Path.expand("../transport/http_json.ex", __DIR__)
    @proto_candidates [
      Path.expand("../../../priv/a2a_v1_1_spec_corpus/a2a.proto", __DIR__),
      Path.expand("../../../priv/proto/a2a.proto", __DIR__)
    ]

    @external_resource @jsonrpc_source
    @external_resource @http_json_source
    for path <- @proto_candidates, do: @external_resource(path)

    # -- compile-time source parsing -------------------------------------------

    jsonrpc_ast = @jsonrpc_source |> File.read!() |> Code.string_to_quoted!()
    http_json_ast = @http_json_source |> File.read!() |> Code.string_to_quoted!()

    # Every `defp dispatch(%Request{method: "<literal>"} ...)` clause head.
    {_, dispatched} =
      Macro.prewalk(jsonrpc_ast, [], fn
        {:defp, _, [head | _]} = node, acc ->
          call =
            case head do
              {:when, _, [call | _]} -> call
              call -> call
            end

          case call do
            {:dispatch, _, [{:=, _, [{:%, _, [_, {:%{}, _, fields}]}, _]} | _]} ->
              case Keyword.get(fields, :method) do
                method when is_binary(method) -> {node, [method | acc]}
                _ -> {node, acc}
              end

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    @dispatched_methods dispatched |> Enum.uniq() |> Enum.sort()

    # The `@method_aliases %{"Pascal" => "slash/name", ...}` attribute.
    {_, aliases} =
      Macro.prewalk(jsonrpc_ast, %{}, fn
        {:@, _, [{:method_aliases, _, [{:%{}, _, pairs}]}]} = node, _acc ->
          {node, Map.new(pairs)}

        node, acc ->
          {node, acc}
      end)

    @dispatcher_aliases aliases

    # HTTP+JSON routes: every `defp dispatch(%{path_info: [...]} = conn, ...)`
    # clause that names a method (a literal, or a `method in [...]` guard) and
    # does not answer 405. Clauses with no method are either the 405 answers for
    # a served path or the push-config routes, whose verbs are the
    # `case conn.method` clauses of `push_collection/3` and `push_item/4`.
    segment = fn
      literal, _guard when is_binary(literal) -> literal
      {name, _, ctx}, guard when is_atom(name) and is_atom(ctx) -> {:var, name, guard}
      _other, _guard -> {:var, :_, nil}
    end

    guard_calls = fn guard ->
      {_, calls} =
        Macro.prewalk(guard, [], fn
          {:not, _, [_]} = node, acc ->
            {nil, [{:negated, node} | acc]}

          {name, _, [{var, _, ctx}]} = node, acc when is_atom(var) and is_atom(ctx) ->
            {node, [{name, var} | acc]}

          {:in, _, [{var, _, ctx}, list]} = node, acc
          when is_atom(var) and is_atom(ctx) and is_list(list) ->
            {node, [{:in, var, list} | acc]}

          node, acc ->
            {node, acc}
        end)

      calls
    end

    render = fn segments, calls ->
      "/" <>
        Enum.map_join(segments, "/", fn
          literal when is_binary(literal) ->
            literal

          {:var, name, _} ->
            suffix =
              cond do
                {:is_cancel_segment, name} in calls -> ":cancel"
                {:is_subscribe_segment, name} in calls -> ":subscribe"
                true -> ""
              end

            label = if name in [:config_id], do: "{configId}", else: "{id}"
            label <> suffix
        end)
    end

    verbs_of = fn fun_name ->
      {_, verbs} =
        Macro.prewalk(http_json_ast, [], fn
          {:defp, _, [{^fun_name, _, _args}, [do: body]]} = node, acc ->
            {_, found} =
              Macro.prewalk(body, [], fn
                {:case, _, [{{:., _, [{:conn, _, _}, :method]}, _, []}, [do: clauses]]} = n, a ->
                  {n, a ++ for({:->, _, [[verb], _]} <- clauses, is_binary(verb), do: verb)}

                n, a ->
                  {n, a}
              end)

            {node, acc ++ found}

          node, acc ->
            {node, acc}
        end)

      verbs
    end

    {_, routes} =
      Macro.prewalk(http_json_ast, [], fn
        {:defp, _, [head, [do: body]]} = node, acc ->
          {call, guard} =
            case head do
              {:when, _, [call, guard]} -> {call, guard}
              call -> {call, nil}
            end

          with {:dispatch, _, [{:=, _, [{:%{}, _, fields}, _]} | _]} <- call,
               path when is_list(path) <- Keyword.get(fields, :path_info),
               false <- match?({:method_not_allowed, _, _}, body) do
            calls = if guard, do: guard_calls.(guard), else: []
            path_label = render.(Enum.map(path, &segment.(&1, guard)), calls)

            methods =
              case Keyword.get(fields, :method) do
                method when is_binary(method) ->
                  [method]

                {var, _, ctx} when is_atom(var) and is_atom(ctx) ->
                  Enum.find_value(calls, [], fn
                    {:in, ^var, list} -> list
                    _ -> nil
                  end)

                nil ->
                  case body do
                    {helper, _, _args} when helper in [:push_collection, :push_item] ->
                      verbs_of.(helper)

                    _ ->
                      []
                  end
              end

            {node, acc ++ Enum.map(methods, &(&1 <> " " <> path_label))}
          else
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    @dispatched_routes Enum.uniq(routes)

    proto_path = Enum.find(@proto_candidates, &File.exists?/1)

    @proto_rpcs (if proto_path do
                   ~r/^\s*rpc\s+([A-Za-z0-9_]+)\s*\(/m
                   |> Regex.scan(File.read!(proto_path), capture: :all_but_first)
                   |> List.flatten()
                 else
                   []
                 end)
    @proto_source if proto_path,
                    do: Path.relative_to(proto_path, Path.expand("../../..", __DIR__))

    @type item :: %{id: String.t(), kind: atom(), name: String.t(), source: String.t()}

    @doc "Every served surface item."
    @spec items() :: [item()]
    def items do
      jsonrpc_methods() ++
        jsonrpc_aliases() ++
        grpc_rpcs() ++
        http_routes() ++
        skills() ++
        consequences() ++
        task_states() ++ security_schemes() ++ mounts() ++
          AshA2A.Sim.Authority.items() ++ AshA2A.Sim.Email.surface_items()
    end

    @doc """
    The A2A v1.1 parity surfaces: one per binding the parity script reports
    on (`AshA2A.Sim.Parity.bindings/0`), as `"parity:<binding>"`.

    They are not part of `items/0`: a parity surface is a comparison with the
    upstream reference, not something the library serves. `AshA2A.Sim.Prover`
    probes them after the served items.
    """
    @spec parity() :: [item()]
    def parity do
      Enum.map(
        AshA2A.Sim.Parity.bindings(),
        &item(:parity, &1, "scripts/a2a_v1_1_parity/parity.py")
      )
    end

    @doc "The ids of every served surface item."
    @spec ids() :: [String.t()]
    def ids, do: Enum.map(items(), & &1.id)

    @doc "The items of one kind."
    @spec items(atom()) :: [item()]
    def items(kind), do: Enum.filter(items(), &(&1.kind == kind))

    @doc """
    The items that none of `probes` names. `probes` is a list of maps with a
    `:surface` key holding an item id (`AshA2A.Sim.Prover.probes/0`).
    """
    @spec uncovered([%{required(:surface) => String.t()}]) :: [item()]
    def uncovered(probes) do
      covered = MapSet.new(probes, & &1.surface)
      Enum.reject(items(), &MapSet.member?(covered, &1.id))
    end

    @doc "Canonical JSON-RPC method names (`message/send`, `tasks/get`, ...)."
    @spec jsonrpc_methods() :: [item()]
    def jsonrpc_methods do
      transport = AshA2A.A2ATransport.Plug.canonical_methods()

      (@dispatched_methods ++ transport)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn method ->
        source =
          if method in @dispatched_methods,
            do: "AshA2A.Protocol.JSONRPC dispatch clause",
            else: "AshA2A.A2ATransport.Plug.canonical_methods/0"

        item(:jsonrpc_method, method, source)
      end)
    end

    @doc """
    Alternative JSON-RPC method spellings: the PascalCase names and
    `tasks/subscribe`. `alias_target/1` gives the canonical method of each.
    """
    @spec jsonrpc_aliases() :: [item()]
    def jsonrpc_aliases do
      alias_table()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&item(:jsonrpc_alias, &1, "JSON-RPC method alias tables"))
    end

    @doc "The canonical method an alias spelling routes to, or `nil`."
    @spec alias_target(String.t()) :: String.t() | nil
    def alias_target(spelling), do: Map.get(alias_table(), spelling)

    defp alias_table do
      @dispatcher_aliases
      |> Map.merge(AshA2A.A2ATransport.Plug.method_aliases())
      |> Map.merge(AshA2A.A2ATransport.Plug.extra_method_aliases())
    end

    @doc "The RPC names of the `lf.a2a.v1.A2AService` gRPC service."
    @spec grpc_rpcs() :: [item()]
    def grpc_rpcs do
      case @proto_rpcs do
        [] ->
          Lf.A2a.V1.A2AService.Service.__rpc_calls__()
          |> Enum.map(&(&1 |> elem(0) |> to_string()))
          |> Enum.map(&item(:grpc_rpc, &1, "Lf.A2a.V1.A2AService.Service"))

        rpcs ->
          Enum.map(rpcs, &item(:grpc_rpc, &1, @proto_source))
      end
    end

    @doc """
    The HTTP+JSON routes, as `"METHOD /path"` with `{id}` and `{configId}` for
    path parameters.
    """
    @spec http_routes() :: [item()]
    def http_routes do
      card_path =
        [agent: AshA2A.Sim.Agent]
        |> AshA2A.Transport.HTTPJSON.init()
        |> Map.fetch!(:agent_card_path)

      card = item(:http_route, "GET /" <> Enum.join(card_path, "/"), "HTTPJSON agent card path")

      schemas =
        Enum.map(AshA2A.Transport.SchemaEndpoints.paths(), fn path ->
          item(
            :http_route,
            "GET /" <> Enum.join(path, "/"),
            "AshA2A.Transport.SchemaEndpoints.paths/0"
          )
        end)

      dispatched =
        Enum.map(
          @dispatched_routes,
          &item(:http_route, &1, "AshA2A.Transport.HTTPJSON dispatch clause")
        )

      [card | dispatched] ++ schemas
    end

    @doc "The skills `AshA2A.Sim.Agent` serves, by capability id."
    @spec skills() :: [item()]
    def skills do
      AshA2A.Sim.Note
      |> AshA2A.Info.capability_index()
      |> Enum.map(&item(:skill, &1.id, "AshA2A.Info.capability_index(AshA2A.Sim.Note)"))
    end

    @doc "The consequence classes the `a2a` DSL accepts on a skill."
    @spec consequences() :: [item()]
    def consequences do
      a2a = Enum.find(AshA2A.Dsl.sections(), &(&1.name == :a2a))
      skill = Enum.find(a2a.entities, &(&1.name == :skill))
      {:one_of, classes} = skill.schema |> Keyword.fetch!(:consequence) |> Keyword.fetch!(:type)

      Enum.map(classes, &item(:consequence, Atom.to_string(&1), "AshA2A.Dsl skill consequence"))
    end

    @doc "The task states of the protocol, without the `UNSPECIFIED` placeholder."
    @spec task_states() :: [item()]
    def task_states do
      Lf.A2a.V1.TaskState.mapping()
      |> Enum.sort_by(fn {_name, number} -> number end)
      |> Enum.reject(fn {_name, number} -> number == 0 end)
      |> Enum.map(fn {name, _number} ->
        item(:task_state, Atom.to_string(name), "Lf.A2a.V1.TaskState")
      end)
    end

    @doc "The security schemes the agent card of `AshA2A.Sim.Agent` declares."
    @spec security_schemes() :: [item()]
    def security_schemes do
      AshA2A.Sim.Agent.agent_card().security_schemes
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&item(:security_scheme, &1, "AshA2A.Sim.Agent.agent_card/0"))
    end

    @doc "The transport mounts of the simulation server, by path or binding."
    @spec mounts() :: [item()]
    def mounts do
      Enum.map(mount_table(), fn {name, served_by} -> item(:mount, name, inspect(served_by)) end)
    end

    @doc "Each simulation server mount and the module that serves it."
    @spec mount_table() :: [{String.t(), module()}]
    def mount_table do
      [
        {"/", AshA2A.A2ATransport.Plug},
        {"/jsonrpc", AshA2A.Transport.Plug},
        {"/a2a", AshA2A.A2ATransport.Plug},
        {"/rest", AshA2A.Transport.HTTPJSON},
        {"grpc", AshA2A.Transport.GRPC.Server}
      ]
    end

    defp item(kind, name, source),
      do: %{id: "#{kind}:#{name}", kind: kind, name: name, source: source}
  end
end
