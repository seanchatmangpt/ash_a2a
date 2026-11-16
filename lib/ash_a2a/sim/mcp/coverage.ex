# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.MCP.Coverage do
    @moduledoc """
    Maps every item of `AshA2A.Sim.Surface` to the MCP tool calls that reach
    it. `plan/0` is data: a client runs it through `tools/call` and needs no
    knowledge of A2A to do so.

    One plan entry per surface item:

        %{
          "surface" => "jsonrpc_method:tasks/cancel",
          "kind" => "jsonrpc_method",
          "name" => "tasks/cancel",
          "tool" => "jsonrpc_tasks_cancel",
          "binding" => "jsonrpc",
          "steps" => [step, ...]
        }

    A step is one tool call:

    | Key | Meaning |
    |---|---|
    | `"label"` | what the step does |
    | `"tool"`, `"arguments"` | the `tools/call` to make |
    | `"tested"` | `true` on the step that reaches the surface item itself; the others set it up or confirm it |
    | `"capture"` | `%{variable => path}`: values to keep from the structured result |
    | `"expect"` | `[%{"path", "op", "value"}]`: what the structured result must hold |
    | `"retry_ms"` | repeat the call until the expectations hold, for at most this long |
    | `"always"` | run the step even when an earlier step failed (it restores state) |

    Strings may hold `{{variable}}` placeholders. A client fills them from
    the captures, from the members of the `sim_info` result (`{{push_url}}`),
    and from `{{uniq}}`, a random token it draws once per entry.

    A path is dot-separated; an integer segment indexes a list (`frames.0`,
    `deliveries.-1`). The operators are `eq`, `ne`, `in`, `contains` (a
    substring of the value, which is JSON-encoded first unless it is a
    string), `not_contains`, `exists`, `absent` and `gte`.

    `uncovered/0` lists the surface items with no plan, a plan that never
    marks a tested step, or a plan that names a tool the catalog lacks. It is
    empty when every served item is reachable through MCP.
    """

    alias AshA2A.Sim.MCP.{Tools, Wire}
    alias AshA2A.Sim.Surface

    @jr %{"binding" => "jsonrpc"}
    @jr_owner %{"binding" => "jsonrpc", "jsonrpc_mount" => "jsonrpc"}
    @rest %{"binding" => "http_json"}
    @grpc %{"binding" => "grpc"}

    @completed "TASK_STATE_COMPLETED"

    @doc "The plan entry of every item of `items/0`, in order."
    @spec plan() :: [map()]
    def plan, do: Enum.map(items(), &entry/1)

    @doc """
    Every item MCP must reach: the served surface (`AshA2A.Sim.Surface.items/0`)
    and the parity surfaces (`AshA2A.Sim.Surface.parity/0`).
    """
    @spec items() :: [Surface.item()]
    def items, do: Surface.items() ++ Surface.parity()

    @doc """
    The items of `items` (`items/0` by default) that MCP cannot reach.
    """
    @spec uncovered([Surface.item()]) :: [Surface.item()]
    def uncovered(items \\ items()) do
      names = MapSet.new(Tools.names())
      stubbed = Wire.grpc_stubbed()

      Enum.filter(items, fn item ->
        steps = steps(item)

        steps == [] or
          not Enum.any?(steps, & &1["tested"]) or
          Enum.any?(steps, &(not MapSet.member?(names, &1["tool"]))) or
          (item.kind == :grpc_rpc and item.name not in stubbed)
      end)
    end

    @doc "The tools each surface item's plan calls, by surface item id."
    @spec tools_by_surface() :: %{String.t() => [String.t()]}
    def tools_by_surface do
      Map.new(items(), fn item ->
        {item.id, item |> steps() |> Enum.map(& &1["tool"]) |> Enum.uniq()}
      end)
    end

    @doc "The plan entry of one surface item. Its `\"steps\"` are empty when MCP has no path to it."
    @spec entry(Surface.item()) :: map()
    def entry(item) do
      steps = steps(item)
      tested = Enum.find(steps, & &1["tested"])

      %{
        "surface" => item.id,
        "kind" => to_string(item.kind),
        "name" => item.name,
        "tool" => tested && tested["tool"],
        "binding" => tested && (tested["arguments"]["binding"] || binding_of(tested["tool"])),
        "steps" => steps
      }
    end

    defp binding_of("jsonrpc_" <> _), do: "jsonrpc"
    defp binding_of("http_" <> _), do: "http_json"
    defp binding_of("grpc_" <> _), do: "grpc"
    defp binding_of(_tool), do: "mcp"

    # == steps per surface item ==================================================

    defp steps(%{kind: :jsonrpc_method} = item) do
      operation(Tools.operation(item), native(@jr), @jr)
    end

    defp steps(%{kind: :jsonrpc_alias, name: spelling}) do
      target = Surface.alias_target(spelling)
      op = Tools.operation(%{kind: :jsonrpc_method, name: target})
      operation(op, native(Map.put(@jr, "method_spelling", spelling)), @jr)
    end

    defp steps(%{kind: :grpc_rpc} = item),
      do: operation(Tools.operation(item), native(@grpc), @grpc)

    defp steps(%{kind: :http_route, name: route} = item) do
      case Tools.operation(item) do
        :schema ->
          [
            step("GET the schema document", {Tools.operation_tool(item), %{}},
              tested: true,
              expect: [ex("status", "eq", 200), ex("json", "exists")] ++ schema_expect(route)
            )
          ]

        op ->
          operation(op, native(Map.put(@rest, "http_route", route)), @rest)
      end
    end

    defp steps(%{kind: :skill, name: id}), do: skill(id)
    defp steps(%{kind: :consequence, name: class}), do: consequence(class)
    defp steps(%{kind: :task_state, name: state}), do: task_state(state)
    defp steps(%{kind: :security_scheme, name: scheme}), do: security(scheme)
    defp steps(%{kind: :mount, name: mount}), do: mount(mount)

    defp steps(%{kind: :parity, name: binding}) do
      [
        step(
          "the wire output of #{binding} matches the upstream v1.1 reference",
          {"sim_parity", %{"binding" => binding}},
          tested: true,
          expect: [
            ex("ran", "eq", true),
            ex("verdicts.0.binding", "eq", binding),
            ex("verdicts.0.verdict", "in", ["pass", "known"]),
            ex("summary.fail", "eq", 0),
            ex("summary.pass", "gte", 1)
          ]
        )
      ]
    end

    defp steps(_item), do: []

    defp schema_expect("GET /.well-known/agent-card.schema.json"),
      do: [ex("json.$schema", "exists")]

    defp schema_expect(_route),
      do: for(%{name: id} <- Surface.skills(), do: ex("body", "contains", id))

    # A caller of the binding's own tool: the tool a surface item derives.
    defp native(bind) do
      fn op, args ->
        # The message id is part of the plan, so the plan is the same data on
        # every read; `{{uniq}}` keeps it fresh on every run.
        args =
          if op in [:send, :stream, :live],
            do: Map.put_new(args, "message_id", "msg-{{uniq}}-#{:erlang.phash2({op, args})}"),
            else: args

        case Tools.native(op, Map.merge(bind, args)) do
          {:ok, tool, arguments} -> {tool, arguments}
          {:error, _reason} -> nil
        end
      end
    end

    # A caller of the `a2a_*` tool of an operation.
    defp a2a(op, bind, args), do: {Tools.a2a_tool(op), Map.merge(bind, args)}

    defp step(_label, nil, _opts), do: nil

    defp step(label, {tool, arguments}, opts) do
      %{"label" => label, "tool" => tool, "arguments" => arguments}
      |> put_opt("tested", opts[:tested])
      |> put_opt("capture", opts[:capture])
      |> put_opt("expect", opts[:expect])
      |> put_opt("retry_ms", opts[:retry_ms])
      |> put_opt("always", opts[:always])
    end

    defp put_opt(map, _key, nil), do: map
    defp put_opt(map, key, value), do: Map.put(map, key, value)

    defp ex(path, op, value \\ nil), do: %{"path" => path, "op" => op, "value" => value}

    defp state(expected), do: [ex("ok", "eq", true), ex("state", "eq", expected)]

    # A plan with a step that could not be built reaches nothing.
    defp built(steps), do: if(Enum.any?(steps, &is_nil/1), do: [], else: steps)

    # -- seeds -------------------------------------------------------------------

    defp seed_send(bind, label, args, expected, capture \\ %{"task_id" => "task.id"}) do
      step(label, a2a(:send, bind, args), expect: state(expected), capture: capture)
    end

    defp seed_parked(bind) do
      seed_send(
        bind,
        "park a task: create_note without a title",
        %{"skill" => "create_note", "data" => %{}},
        "TASK_STATE_INPUT_REQUIRED"
      )
    end

    defp seed_running(bind, delay_ms) do
      step(
        "start slow_count (#{delay_ms} ms) without waiting",
        a2a(:send, bind, %{
          "skill" => "slow_count",
          "data" => %{"delay_ms" => delay_ms},
          "return_immediately" => true
        }),
        expect: [
          ex("ok", "eq", true),
          ex("state", "in", ["TASK_STATE_SUBMITTED", "TASK_STATE_WORKING"])
        ],
        capture: %{"task_id" => "task.id"}
      )
    end

    defp seed_config(bind, suffix) do
      step(
        "store a webhook config",
        a2a(:push_create, bind, %{
          "task_id" => "{{task_id}}",
          "url" => "{{push_url}}/#{suffix}-{{uniq}}",
          "push_token" => "tok-{{uniq}}"
        }),
        expect: [ex("ok", "eq", true), ex("config.id", "exists")],
        capture: %{"config_id" => "config.id"}
      )
    end

    # == one scenario per A2A operation ==========================================

    defp operation(nil, _call, _bind), do: []

    defp operation(:send, call, _bind) do
      built([
        step("send count_notes", call.(:send, %{"skill" => "count_notes"}),
          tested: true,
          expect:
            state(@completed) ++ [ex("data.count", "gte", 0), ex("task.artifacts.0", "exists")]
        )
      ])
    end

    defp operation(:stream, call, bind) do
      built([
        seed_send(
          bind,
          "seed a note",
          %{"skill" => "create_note", "data" => %{"title" => "mcp-stream-{{uniq}}"}},
          @completed
        ),
        step(
          "stream list_notes",
          call.(:stream, %{"skill" => "list_notes", "data" => %{"stream" => true}}),
          tested: true,
          expect: [
            ex("ok", "eq", true),
            ex("frame_kinds", "contains", "artifactUpdate"),
            ex("frames", "contains", "mcp-stream-{{uniq}}"),
            ex("final_state", "eq", @completed)
          ]
        )
      ])
    end

    defp operation(:live, call, _bind) do
      built([
        step(
          "open a live session and send count_notes",
          call.(:live, %{"skill" => "count_notes"}),
          tested: true,
          expect: [
            ex("ok", "eq", true),
            ex("frame_kinds", "contains", "task"),
            ex("final_state", "eq", @completed)
          ]
        )
      ])
    end

    defp operation(:get, call, bind) do
      built([
        seed_send(bind, "run count_notes", %{"skill" => "count_notes"}, @completed),
        step("read the task back", call.(:get, %{"task_id" => "{{task_id}}"}),
          tested: true,
          expect: state(@completed) ++ [ex("task.id", "eq", "{{task_id}}")]
        ),
        step("an unknown task is refused", call.(:get, %{"task_id" => "tsk-does-not-exist"}),
          expect: [ex("ok", "eq", false), ex("error", "exists")]
        )
      ])
    end

    defp operation(:list, call, bind) do
      built([
        seed_send(
          bind,
          "run count_notes in a fresh context",
          %{"skill" => "count_notes", "context_id" => "ctx-mcp-{{uniq}}"},
          @completed
        ),
        step(
          "list the tasks of that context",
          call.(:list, %{"context_id" => "ctx-mcp-{{uniq}}"}),
          tested: true,
          expect: [
            ex("ok", "eq", true),
            ex("result.tasks.0.id", "eq", "{{task_id}}"),
            ex("result.tasks.1", "absent")
          ]
        )
      ])
    end

    defp operation(:cancel, call, bind) do
      built([
        seed_running(bind, 30_000),
        step("cancel it while it runs", call.(:cancel, %{"task_id" => "{{task_id}}"}),
          tested: true,
          expect: state("TASK_STATE_CANCELED")
        ),
        step("it stays canceled", a2a(:get, bind, %{"task_id" => "{{task_id}}"}),
          expect: state("TASK_STATE_CANCELED")
        )
      ])
    end

    defp operation(:subscribe, call, bind) do
      built([
        seed_running(bind, 1_200),
        step(
          "follow the running task to its final state",
          call.(:subscribe, %{"task_id" => "{{task_id}}"}),
          tested: true,
          expect: [
            ex("ok", "eq", true),
            ex("frames.0.task.id", "eq", "{{task_id}}"),
            ex("final_state", "eq", @completed)
          ]
        ),
        seed_running(bind, 1_200),
        step(
          "resubscribe with lastSeenGeneration",
          call.(:subscribe, %{"task_id" => "{{task_id}}", "last_seen_generation" => 1}),
          expect: [ex("ok", "eq", true), ex("final_state", "eq", @completed)]
        ),
        step(
          "an unknown task is refused",
          call.(:subscribe, %{"task_id" => "tsk-does-not-exist"}),
          expect: [ex("ok", "eq", false)]
        )
      ])
    end

    defp operation(:push_create, call, bind) do
      built([
        seed_parked(bind),
        step(
          "store a webhook config for the parked task",
          call.(:push_create, %{
            "task_id" => "{{task_id}}",
            "url" => "{{push_url}}/mcp-{{uniq}}",
            "push_token" => "tok-{{uniq}}"
          }),
          tested: true,
          expect: [
            ex("ok", "eq", true),
            ex("config.url", "eq", "{{push_url}}/mcp-{{uniq}}"),
            ex("config.id", "exists")
          ]
        ),
        seed_send(
          bind,
          "finish the task: send the title",
          %{
            "skill" => "create_note",
            "data" => %{"title" => "mcp-pushed-{{uniq}}"},
            "task_id" => "{{task_id}}"
          },
          @completed,
          %{}
        ),
        step(
          "the webhook receiver got the delivery",
          {"sim_push_deliveries", %{"path_suffix" => "/mcp-{{uniq}}", "wait_ms" => 8_000}},
          expect: [
            ex("count", "gte", 1),
            ex("deliveries.-1.headers.x-a2a-notification-token", "eq", "tok-{{uniq}}"),
            ex("deliveries.-1.raw", "contains", "{{task_id}}"),
            ex("deliveries.-1.raw", "contains", @completed)
          ]
        )
      ])
    end

    defp operation(:push_get, call, bind) do
      built([
        seed_parked(bind),
        seed_config(bind, "mcp-get"),
        step(
          "read the config back",
          call.(:push_get, %{"task_id" => "{{task_id}}", "config_id" => "{{config_id}}"}),
          tested: true,
          expect: [
            ex("ok", "eq", true),
            ex("config.id", "eq", "{{config_id}}"),
            ex("config.url", "eq", "{{push_url}}/mcp-get-{{uniq}}")
          ]
        )
      ])
    end

    defp operation(:push_list, call, bind) do
      built([
        seed_parked(bind),
        seed_config(bind, "mcp-list"),
        step("list the configs of the task", call.(:push_list, %{"task_id" => "{{task_id}}"}),
          tested: true,
          expect: [
            ex("ok", "eq", true),
            ex("configs.0.id", "eq", "{{config_id}}"),
            ex("configs.1", "absent")
          ]
        )
      ])
    end

    defp operation(:push_delete, call, bind) do
      built([
        seed_parked(bind),
        seed_config(bind, "mcp-delete"),
        step(
          "delete the config",
          call.(:push_delete, %{"task_id" => "{{task_id}}", "config_id" => "{{config_id}}"}),
          tested: true,
          expect: [ex("ok", "eq", true)]
        ),
        step("the task has no config left", a2a(:push_list, bind, %{"task_id" => "{{task_id}}"}),
          expect: [ex("ok", "eq", true), ex("configs.0", "absent")]
        ),
        step(
          "reading the deleted config is refused",
          a2a(:push_get, bind, %{"task_id" => "{{task_id}}", "config_id" => "{{config_id}}"}),
          expect: [ex("ok", "eq", false)]
        )
      ])
    end

    defp operation(:extended_card, call, _bind) do
      built([
        step("an authenticated caller gets the extended card", call.(:extended_card, %{}),
          tested: true,
          expect: [
            ex("ok", "eq", true),
            ex("result.name", "eq", "ash-a2a-sim"),
            ex("result.skills", "contains", "AshA2A.Sim.extended_only")
          ]
        ),
        step("it is refused without credentials", call.(:extended_card, %{"token" => "none"}),
          expect: [ex("ok", "eq", false)]
        )
      ])
    end

    defp operation(:card, call, _bind) do
      built([
        step("read the public card without credentials", call.(:card, %{"token" => "none"}),
          tested: true,
          expect: card_expect()
        )
      ])
    end

    defp operation(_op, _call, _bind), do: []

    defp card_expect do
      [
        ex("status", "eq", 200),
        ex("json.name", "eq", "ash-a2a-sim"),
        ex("json.skills", "not_contains", "AshA2A.Sim.extended_only"),
        ex("json.supportedInterfaces.0.url", "exists")
      ]
    end

    # == skills ==================================================================

    defp rows(label, args, expect),
      do: step(label, {"sim_read_rows", args}, expect: expect)

    defp run_skill(label, bind, args, expected, opts \\ []) do
      step(label, a2a(:send, bind, args),
        tested: opts[:tested],
        capture: opts[:capture],
        expect: state(expected) ++ (opts[:expect] || [])
      )
    end

    defp create(bind, title, opts \\ []) do
      run_skill(
        "create a note over #{bind["binding"]}",
        bind,
        %{"skill" => "create_note", "data" => %{"title" => title, "body" => "first body"}},
        @completed,
        Keyword.merge(
          [capture: %{"note_id" => "data.id"}, expect: [ex("data.id", "exists")]],
          opts
        )
      )
    end

    defp skill("AshA2A.Sim.Note.create") do
      [
        create(@jr, "mcp-create-{{uniq}}", tested: true),
        rows("the row is in the data layer", %{"id" => "{{note_id}}"}, [
          ex("count", "eq", 1),
          ex("rows.0.title", "eq", "mcp-create-{{uniq}}"),
          ex("rows.0.body", "eq", "first body")
        ]),
        create(@rest, "mcp-create-rest-{{uniq}}"),
        create(@grpc, "mcp-create-grpc-{{uniq}}"),
        rows("each binding wrote one row", %{"title_prefix" => "mcp-create-"}, [
          ex("rows", "contains", "mcp-create-rest-{{uniq}}"),
          ex("rows", "contains", "mcp-create-grpc-{{uniq}}")
        ]),
        run_skill(
          "create without authority is refused",
          @jr,
          %{
            "skill" => "create_note",
            "data" => %{"title" => "mcp-refused-{{uniq}}"},
            "token" => "reader"
          },
          "TASK_STATE_REJECTED",
          expect: [ex("task", "contains", "authority_required")]
        ),
        rows("the refused create wrote nothing", %{"title" => "mcp-refused-{{uniq}}"}, [
          ex("count", "eq", 0)
        ])
      ]
    end

    defp skill("AshA2A.Sim.Note.update") do
      [
        create(@jr, "mcp-update-{{uniq}}"),
        run_skill(
          "update the note's body",
          @rest,
          %{
            "skill" => "update_note",
            "data" => %{"id" => "{{note_id}}", "body" => "second body"}
          },
          @completed,
          tested: true
        ),
        rows("the row changed, the title did not", %{"id" => "{{note_id}}"}, [
          ex("rows.0.body", "eq", "second body"),
          ex("rows.0.title", "eq", "mcp-update-{{uniq}}")
        ]),
        run_skill(
          "update without authority is refused",
          @grpc,
          %{
            "skill" => "update_note",
            "data" => %{"id" => "{{note_id}}", "body" => "overwritten"},
            "token" => "reader"
          },
          "TASK_STATE_REJECTED"
        ),
        rows("the refused update changed nothing", %{"id" => "{{note_id}}"}, [
          ex("rows.0.body", "eq", "second body")
        ])
      ]
    end

    defp skill("AshA2A.Sim.Note.destroy") do
      [
        create(@grpc, "mcp-destroy-{{uniq}}"),
        run_skill(
          "destroy without authority is refused",
          @jr,
          %{"skill" => "delete_note", "data" => %{"id" => "{{note_id}}"}, "token" => "reader"},
          "TASK_STATE_REJECTED"
        ),
        rows("the row is still there", %{"id" => "{{note_id}}"}, [ex("count", "eq", 1)]),
        run_skill(
          "destroy the note",
          @jr,
          %{"skill" => "delete_note", "data" => %{"id" => "{{note_id}}"}},
          @completed,
          tested: true
        ),
        rows("the row is gone", %{"id" => "{{note_id}}"}, [ex("count", "eq", 0)])
      ]
    end

    defp skill("AshA2A.Sim.Note.read") do
      [
        create(@jr, "mcp-read-{{uniq}}"),
        run_skill("list_notes answers the row", @rest, %{"skill" => "list_notes"}, @completed,
          tested: true,
          expect: [ex("task.artifacts", "contains", "mcp-read-{{uniq}}")]
        ),
        run_skill(
          "a caller without grants can read",
          @grpc,
          %{"skill" => "list_notes", "token" => "reader"},
          @completed
        )
      ]
    end

    defp skill("AshA2A.Sim.Note.count_notes") do
      [
        run_skill("count_notes answers a count", @grpc, %{"skill" => "count_notes"}, @completed,
          tested: true,
          expect: [ex("data.count", "gte", 0)]
        )
      ]
    end

    defp skill("AshA2A.Sim.Note.slow_count") do
      [
        run_skill(
          "slow_count answers after its delay",
          @jr,
          %{"skill" => "slow_count", "data" => %{"delay_ms" => 50}},
          @completed,
          tested: true,
          expect: [ex("data.count", "gte", 0)]
        )
      ]
    end

    defp skill("AshA2A.Sim.Note.step_up") do
      [
        run_skill(
          "step_up parks for a credential",
          @jr,
          %{"skill" => "step_up"},
          "TASK_STATE_AUTH_REQUIRED",
          tested: true,
          capture: %{"task_id" => "task.id"}
        ),
        run_skill(
          "sending the one-time code finishes the task",
          @jr,
          %{"skill" => "step_up", "data" => %{"otp" => "123456"}, "task_id" => "{{task_id}}"},
          @completed
        )
      ]
    end

    defp skill("AshA2A.Sim.Note.publish_note") do
      [
        run_skill(
          "publish_note records the effect",
          @jr,
          %{"skill" => "publish_note", "data" => %{"title" => "mcp-publish-{{uniq}}"}},
          @completed,
          tested: true
        ),
        rows(
          "the publication is recorded, outside the note table",
          %{"title" => "mcp-publish-{{uniq}}"},
          [
            ex("publications", "contains", "mcp-publish-{{uniq}}"),
            ex("count", "eq", 0)
          ]
        ),
        run_skill(
          "publish without authority is refused",
          @rest,
          %{
            "skill" => "publish_note",
            "data" => %{"title" => "mcp-unpublished-{{uniq}}"},
            "token" => "reader"
          },
          "TASK_STATE_REJECTED"
        ),
        rows("the refused publish recorded nothing", %{}, [
          ex("publications", "not_contains", "mcp-unpublished-{{uniq}}")
        ])
      ]
    end

    defp skill("AshA2A.Sim.Note.unclassified_note") do
      [
        run_skill(
          "an unclassified action is rejected",
          @jr,
          %{"skill" => "unclassified_note"},
          "TASK_STATE_REJECTED",
          tested: true,
          expect: [
            ex("task", "contains", "consequence_unclassified"),
            ex("task.artifacts.0", "absent")
          ]
        )
      ]
    end

    defp skill(_id), do: []

    # == consequence classes =====================================================

    defp consequence("observe") do
      [
        run_skill(
          "an observe skill needs authentication only",
          @jr,
          %{"skill" => "count_notes", "token" => "reader"},
          @completed,
          tested: true
        )
      ]
    end

    defp consequence("change") do
      agent = "sim-agent-{{uniq}}"
      grant = %{"identity" => agent, "skill" => "create_note"}
      granted = [ex("grants.0.capability_id", "eq", "AshA2A.Sim.Note.create")]

      create = fn title ->
        %{"skill" => "create_note", "data" => %{"title" => title}, "token" => agent}
      end

      [
        run_skill(
          "a change skill without a standing grant is refused",
          @jr,
          create.("mcp-ungranted-{{uniq}}"),
          "TASK_STATE_REJECTED",
          tested: true,
          expect: [ex("task", "contains", "authority_required")]
        ),
        rows("nothing was written", %{"title" => "mcp-ungranted-{{uniq}}"}, [ex("count", "eq", 0)]),
        step("issue the standing grant for that caller", {"sim_grant_authority", grant},
          expect: granted ++ [ex("grants.0.granted", "eq", true)]
        ),
        run_skill(
          "with the grant the same call writes the row",
          @jr,
          create.("mcp-granted-{{uniq}}"),
          @completed
        ),
        rows("the row is there", %{"title" => "mcp-granted-{{uniq}}"}, [ex("count", "eq", 1)]),
        step("revoke the grant", {"sim_revoke_authority", grant},
          expect: granted ++ [ex("grants.0.granted", "eq", false)]
        ),
        run_skill(
          "after the revoke the call is refused again",
          @rest,
          create.("mcp-revoked-{{uniq}}"),
          "TASK_STATE_REJECTED"
        ),
        rows("and wrote nothing", %{"title" => "mcp-revoked-{{uniq}}"}, [ex("count", "eq", 0)]),
        step("issue the revoked grant again", {"sim_grant_authority", grant},
          expect:
            granted ++
              [ex("grants.0.granted", "eq", true), ex("grants.0.outcome", "eq", "granted")]
        ),
        run_skill(
          "the re-issued grant admits the call again",
          @grpc,
          create.("mcp-regranted-{{uniq}}"),
          @completed
        ),
        rows("and the row is there", %{"title" => "mcp-regranted-{{uniq}}"}, [
          ex("count", "eq", 1)
        ])
      ]
    end

    defp consequence("external_do") do
      agent = "sim-agent-{{uniq}}"
      grant = %{"identity" => agent, "skill" => "publish_note"}

      publish = fn title ->
        %{"skill" => "publish_note", "data" => %{"title" => title}, "token" => agent}
      end

      [
        run_skill(
          "an external_do skill without a grant is refused",
          @jr,
          publish.("mcp-ext-refused-{{uniq}}"),
          "TASK_STATE_REJECTED",
          tested: true,
          expect: [ex("task", "contains", "authority_required")]
        ),
        step("issue the standing grant for that caller", {"sim_grant_authority", grant},
          expect: [ex("grants.0.granted", "eq", true)]
        ),
        run_skill(
          "with the grant the call has its effect",
          @grpc,
          publish.("mcp-ext-{{uniq}}"),
          @completed
        ),
        step("revoke the grant", {"sim_revoke_authority", grant},
          expect: [ex("grants.0.granted", "eq", false)]
        ),
        rows("only the granted call was recorded", %{"title" => "none"}, [
          ex("publications", "contains", "mcp-ext-{{uniq}}"),
          ex("publications", "not_contains", "mcp-ext-refused-{{uniq}}")
        ])
      ]
    end

    defp consequence("unknown") do
      [
        run_skill(
          "an unknown-consequence skill is refused for every caller",
          @grpc,
          %{"skill" => "unclassified_note"},
          "TASK_STATE_REJECTED",
          tested: true,
          expect: [ex("task", "contains", "consequence_unclassified")]
        )
      ]
    end

    defp consequence(_class), do: []

    # == task states =============================================================

    defp task_state("TASK_STATE_SUBMITTED") do
      [
        run_skill(
          "a send that does not wait answers the submitted task",
          @jr,
          %{
            "skill" => "slow_count",
            "data" => %{"delay_ms" => 300},
            "return_immediately" => true
          },
          "TASK_STATE_SUBMITTED",
          tested: true
        )
      ]
    end

    defp task_state("TASK_STATE_WORKING") do
      [
        step(
          "a streamed list_notes reports working before it completes",
          a2a(:stream, @jr, %{"skill" => "list_notes", "data" => %{"stream" => true}}),
          tested: true,
          expect: [
            ex("ok", "eq", true),
            ex("states", "contains", "TASK_STATE_WORKING"),
            ex("final_state", "eq", @completed)
          ]
        )
      ]
    end

    defp task_state("TASK_STATE_COMPLETED") do
      [
        run_skill("an observe skill completes", @rest, %{"skill" => "count_notes"}, @completed,
          tested: true
        )
      ]
    end

    defp task_state("TASK_STATE_FAILED") do
      [
        run_skill(
          "updating a row that does not exist fails",
          @jr,
          %{
            "skill" => "update_note",
            "data" => %{"id" => "00000000-0000-0000-0000-000000000000", "body" => "x"}
          },
          "TASK_STATE_FAILED",
          tested: true
        )
      ]
    end

    defp task_state("TASK_STATE_CANCELED") do
      [
        seed_running(@grpc, 30_000),
        step("cancel the running task", a2a(:cancel, @grpc, %{"task_id" => "{{task_id}}"}),
          tested: true,
          expect: state("TASK_STATE_CANCELED")
        )
      ]
    end

    defp task_state("TASK_STATE_INPUT_REQUIRED") do
      [
        Map.put(seed_parked(@jr), "tested", true),
        run_skill(
          "sending the missing title on the same task finishes it",
          @jr,
          %{
            "skill" => "create_note",
            "data" => %{"title" => "mcp-input-{{uniq}}"},
            "task_id" => "{{task_id}}"
          },
          @completed
        ),
        rows("the row was written once the input arrived", %{"title" => "mcp-input-{{uniq}}"}, [
          ex("count", "eq", 1)
        ])
      ]
    end

    defp task_state("TASK_STATE_REJECTED") do
      [
        run_skill(
          "an unclassified skill is rejected",
          @rest,
          %{"skill" => "unclassified_note"},
          "TASK_STATE_REJECTED",
          tested: true
        )
      ]
    end

    defp task_state("TASK_STATE_AUTH_REQUIRED") do
      [
        run_skill(
          "step_up parks at auth-required",
          @rest,
          %{"skill" => "step_up"},
          "TASK_STATE_AUTH_REQUIRED",
          tested: true,
          capture: %{"task_id" => "task.id"}
        ),
        step(
          "the parked task can be canceled",
          a2a(:cancel, @rest, %{"task_id" => "{{task_id}}"}),
          expect: state("TASK_STATE_CANCELED")
        )
      ]
    end

    defp task_state(_state), do: []

    # == security scheme =========================================================

    defp security("bearer_auth") do
      refused = fn bind, token, status ->
        step(
          "#{bind["binding"]}: token #{token} is refused #{status}",
          a2a(:send, bind, %{"skill" => "count_notes", "token" => token}),
          expect: [ex("ok", "eq", false), ex("status", "eq", status), ex("task", "eq", nil)]
        )
      end

      [
        step(
          "the public card declares the scheme",
          {"a2a_get_agent_card", %{"binding" => "jsonrpc"}},
          expect: [
            ex("status", "eq", 200),
            ex("json.securitySchemes.bearer_auth", "exists"),
            ex("json.securitySchemes", "contains", "bearer")
          ]
        ),
        run_skill(
          "a known token with the scope is admitted",
          @jr,
          %{"skill" => "count_notes", "token" => "reader"},
          @completed,
          tested: true
        ),
        refused.(@jr, "none", 401),
        refused.(@jr_owner, "none", 401),
        refused.(@rest, "none", 401),
        refused.(@grpc, "none", 16),
        refused.(@jr, "not-a-real-token", 401),
        refused.(@grpc, "not-a-real-token", 16),
        refused.(@jr, "unscoped", 403),
        refused.(@rest, "unscoped", 403),
        refused.(@grpc, "unscoped", 7)
      ]
    end

    defp security(_scheme), do: []

    # == mounts ==================================================================

    defp mount("/") do
      [
        step(
          "the root serves the agent card without credentials",
          {"a2a_get_agent_card", %{"binding" => "jsonrpc", "mount" => "root"}},
          tested: true,
          expect: card_expect() ++ [ex("json.capabilities.pushNotifications", "eq", true)]
        ),
        step(
          "the root serves nothing else",
          {"a2a_raw_request",
           %{
             "binding" => "jsonrpc",
             "mount" => "root",
             "method" => "POST",
             "path" => "/",
             "json" => %{}
           }},
          expect: [ex("status", "eq", 404)]
        )
      ]
    end

    defp mount("/jsonrpc") do
      [
        run_skill("JSON-RPC send on /jsonrpc", @jr_owner, %{"skill" => "count_notes"}, @completed,
          tested: true,
          capture: %{"task_id" => "task.id"}
        ),
        step(
          "this mount does not serve push configs",
          a2a(:push_list, @jr_owner, %{"task_id" => "{{task_id}}"}),
          expect: [ex("ok", "eq", false), ex("error.code", "eq", -32_003)]
        ),
        step(
          "its own card is public",
          {"a2a_get_agent_card", %{"binding" => "jsonrpc", "jsonrpc_mount" => "jsonrpc"}},
          expect: [ex("status", "eq", 200), ex("json.name", "eq", "ash-a2a-sim")]
        )
      ] ++ malformed_jsonrpc("jsonrpc")
    end

    defp mount("/a2a") do
      [
        run_skill("JSON-RPC send on /a2a", @jr, %{"skill" => "count_notes"}, @completed,
          tested: true
        ),
        step(
          "its own card is public",
          {"a2a_get_agent_card", %{"binding" => "jsonrpc", "jsonrpc_mount" => "a2a"}},
          expect: [ex("status", "eq", 200), ex("json.capabilities.pushNotifications", "eq", true)]
        ),
        step(
          "an unknown method is -32601",
          {"a2a_raw_request",
           %{
             "binding" => "jsonrpc",
             "json" => %{"jsonrpc" => "2.0", "id" => 1, "method" => "no/such", "params" => %{}}
           }},
          expect: [ex("error.code", "eq", -32_601)]
        )
      ] ++ malformed_jsonrpc("a2a")
    end

    defp mount("/rest") do
      [
        run_skill("HTTP+JSON send on /rest", @rest, %{"skill" => "count_notes"}, @completed,
          tested: true
        ),
        step(
          "malformed JSON is refused 400",
          {"a2a_raw_request",
           %{"binding" => "http_json", "path" => "/message:send", "body" => "{not json"}},
          expect: [
            ex("status", "eq", 400),
            ex("ok", "eq", false),
            ex("body", "contains", "INVALID_ARGUMENT")
          ]
        ),
        step(
          "an unknown route is 404",
          {"a2a_raw_request",
           %{"binding" => "http_json", "method" => "GET", "path" => "/no/such/route"}},
          expect: [ex("status", "eq", 404)]
        ),
        step(
          "bytes that are not HTTP are refused at the socket",
          {"a2a_raw_request",
           %{"binding" => "http_json", "transport" => "tcp", "body" => "NOT HTTP\r\n\r\n"}},
          expect: [ex("status", "eq", 400), ex("ok", "eq", false)]
        )
      ]
    end

    defp mount("grpc") do
      [
        run_skill(
          "gRPC send on the gRPC endpoint",
          @grpc,
          %{"skill" => "count_notes"},
          @completed,
          tested: true,
          expect: [
            ex("status", "eq", 0),
            ex("trailers.grpc-status", "eq", "0"),
            ex("body_base64", "exists")
          ]
        ),
        step(
          "bytes that are not a protobuf message are refused",
          {"a2a_raw_request", %{"binding" => "grpc", "body_base64" => "////AQI="}},
          expect: [
            ex("ok", "eq", false),
            ex("status", "ne", 0),
            ex("trailers.grpc-status", "exists")
          ]
        ),
        step(
          "an RPC the service does not have is refused",
          {"a2a_raw_request",
           %{"binding" => "grpc", "path" => "/lf.a2a.v1.A2AService/NoSuchRpc", "body" => ""}},
          expect: [ex("ok", "eq", false), ex("status", "ne", 0)]
        )
      ]
    end

    defp mount(_mount), do: []

    defp malformed_jsonrpc(mount) do
      [
        step(
          "malformed JSON is -32700",
          {"a2a_raw_request", %{"binding" => "jsonrpc", "mount" => mount, "body" => "{not json"}},
          expect: [
            ex("ok", "eq", false),
            ex("error.code", "eq", -32_700),
            ex("json.id", "eq", nil)
          ]
        ),
        step(
          "a JSON value that is not a request is -32600",
          {"a2a_raw_request",
           %{"binding" => "jsonrpc", "mount" => mount, "json" => %{"hello" => "world"}}},
          expect: [ex("ok", "eq", false), ex("error.code", "eq", -32_600)]
        )
      ]
    end
  end
end
