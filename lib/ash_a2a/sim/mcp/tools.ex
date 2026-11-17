# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.MCP.Tools do
    @moduledoc """
    The MCP tool catalog of the simulation server. Every wire tool sends a
    real request to a listener of `AshA2A.Sim.Server` and answers the status,
    headers and body it received.

    | Tools | What they are |
    |---|---|
    | `jsonrpc_*`, `http_*`, `grpc_*` | one tool per item of `AshA2A.Sim.Surface` of kind `:jsonrpc_method`, `:http_route` and `:grpc_rpc`, taking the binding's own request shape |
    | `a2a_send_message`, `a2a_get_task`, ... | one tool per A2A operation, taking `binding` (`"jsonrpc"`, `"http_json"`, `"grpc"`) and the operation's parameters |
    | `a2a_raw_request` | bytes the caller chose, sent to a binding over HTTP, gRPC or a bare TCP socket |
    | `sim_*` | the simulation server itself: URLs and tokens, authority grants, the Ash rows, webhook deliveries, the surface inventory, the coverage plan, the prover and the v1.1 parity check |

    `list/0` is the catalog (`name`, `title`, `description`, `inputSchema`,
    `outputSchema`). `call/3` validates the arguments against the tool's
    `inputSchema` and runs it.

    A wire tool answers a map with `binding`, `request` (what was sent),
    `status` (the HTTP status, or the gRPC status code), `headers`,
    `trailers`, `body` (the response body as text, `null` when it is not
    UTF-8), `body_base64` (set when `body` is `null`, and for gRPC replies
    the protobuf bytes), `json`, `frames` (the stream responses of a
    server-sent event or gRPC stream) and fields read out of the answer:
    `result`, `error`, `task`, `state`, `states`, `final_state`,
    `frame_kinds`, `data`, `config`, `configs` and `ok`.

    The `token` argument names a fixture of `AshA2A.Sim.Auth` (`"writer"`,
    `"reader"`, `"unscoped"`), `"none"` for no credentials, or any other
    string to send as the bearer token. A `sim-agent-<name>` token
    authenticates as an identity of its own that holds no grants.
    """

    alias AshA2A.Sim.MCP.{AuthorityTools, Coverage, Wire}
    alias AshA2A.Sim.{Note, Parity, Prover, PushReceiver, Surface}

    @bindings ~w(jsonrpc http_json grpc)
    @last_matrix {__MODULE__, :last_matrix}

    @jsonrpc_ops %{
      "message/send" => :send,
      "message/stream" => :stream,
      "message/live" => :live,
      "tasks/get" => :get,
      "tasks/list" => :list,
      "tasks/cancel" => :cancel,
      "tasks/resubscribe" => :subscribe,
      "tasks/pushNotificationConfig/set" => :push_create,
      "tasks/pushNotificationConfig/get" => :push_get,
      "tasks/pushNotificationConfig/list" => :push_list,
      "tasks/pushNotificationConfig/delete" => :push_delete,
      "agent/getAuthenticatedExtendedCard" => :extended_card
    }

    @grpc_ops %{
      "SendMessage" => :send,
      "SendStreamingMessage" => :stream,
      "SendLiveMessage" => :live,
      "GetTask" => :get,
      "ListTasks" => :list,
      "CancelTask" => :cancel,
      "SubscribeToTask" => :subscribe,
      "CreateTaskPushNotificationConfig" => :push_create,
      "GetTaskPushNotificationConfig" => :push_get,
      "ListTaskPushNotificationConfigs" => :push_list,
      "DeleteTaskPushNotificationConfig" => :push_delete,
      "GetExtendedAgentCard" => :extended_card
    }

    @http_ops %{
      "GET /.well-known/agent-card.json" => :card,
      "POST /message:send" => :send,
      "POST /message:stream" => :stream,
      "POST /message:live" => :live,
      "GET /tasks/{id}" => :get,
      "GET /tasks" => :list,
      "POST /tasks/{id}:cancel" => :cancel,
      "GET /tasks/{id}:subscribe" => :subscribe,
      "POST /tasks/{id}:subscribe" => :subscribe,
      "POST /tasks/{id}/pushNotificationConfigs" => :push_create,
      "GET /tasks/{id}/pushNotificationConfigs" => :push_list,
      "GET /tasks/{id}/pushNotificationConfigs/{configId}" => :push_get,
      "DELETE /tasks/{id}/pushNotificationConfigs/{configId}" => :push_delete,
      "POST /tasks/{id}/pushNotificationConfig" => :push_create,
      "GET /tasks/{id}/pushNotificationConfig" => :push_list,
      "GET /tasks/{id}/pushNotificationConfig/{configId}" => :push_get,
      "DELETE /tasks/{id}/pushNotificationConfig/{configId}" => :push_delete,
      "GET /extendedAgentCard" => :extended_card,
      "POST /agent" => :extended_card,
      "GET /.well-known/agent-card.schema.json" => :schema,
      "GET /.well-known/skills.schema.json" => :schema
    }

    # The route an `a2a_*` tool uses for `binding: "http_json"`.
    @http_default %{
      send: "POST /message:send",
      stream: "POST /message:stream",
      live: "POST /message:live",
      get: "GET /tasks/{id}",
      list: "GET /tasks",
      cancel: "POST /tasks/{id}:cancel",
      subscribe: "POST /tasks/{id}:subscribe",
      push_create: "POST /tasks/{id}/pushNotificationConfigs",
      push_list: "GET /tasks/{id}/pushNotificationConfigs",
      push_get: "GET /tasks/{id}/pushNotificationConfigs/{configId}",
      push_delete: "DELETE /tasks/{id}/pushNotificationConfigs/{configId}",
      extended_card: "GET /extendedAgentCard",
      card: "GET /.well-known/agent-card.json"
    }

    @a2a_tools [
      {"a2a_send_message", :send},
      {"a2a_stream_message", :stream},
      {"a2a_live_message", :live},
      {"a2a_get_task", :get},
      {"a2a_list_tasks", :list},
      {"a2a_cancel_task", :cancel},
      {"a2a_subscribe_task", :subscribe},
      {"a2a_create_push_config", :push_create},
      {"a2a_get_push_config", :push_get},
      {"a2a_list_push_configs", :push_list},
      {"a2a_delete_push_config", :push_delete},
      {"a2a_get_extended_agent_card", :extended_card}
    ]

    # == catalog =================================================================

    @doc "Every tool, as MCP `Tool` objects."
    @spec list() :: [map()]
    def list do
      operation_tools() ++
        a2a_tools() ++
        [raw_tool()] ++ sim_tools() ++ AuthorityTools.list() ++ AshA2A.Sim.MCP.EmailTools.list()
    end

    @doc "The names of every tool."
    @spec names() :: [String.t()]
    def names, do: Enum.map(list(), & &1["name"])

    @doc """
    The name of the tool derived from a surface item of kind
    `:jsonrpc_method`, `:http_route` or `:grpc_rpc`, or `nil` for another kind.
    """
    @spec operation_tool(Surface.item()) :: String.t() | nil
    def operation_tool(%{kind: :jsonrpc_method, name: name}), do: "jsonrpc_" <> slug(name)
    def operation_tool(%{kind: :http_route, name: name}), do: "http_" <> slug(name)
    def operation_tool(%{kind: :grpc_rpc, name: name}), do: "grpc_" <> name
    def operation_tool(_item), do: nil

    @doc "The A2A operation a surface item serves (`:send`, `:get`, ...), or `nil`."
    @spec operation(Surface.item()) :: atom() | nil
    def operation(%{kind: :jsonrpc_method, name: name}), do: @jsonrpc_ops[name]
    def operation(%{kind: :http_route, name: name}), do: @http_ops[name]
    def operation(%{kind: :grpc_rpc, name: name}), do: @grpc_ops[name]
    def operation(_item), do: nil

    @doc "The `a2a_*` tool of an operation, or `nil`."
    @spec a2a_tool(atom()) :: String.t() | nil
    def a2a_tool(:card), do: "a2a_get_agent_card"

    def a2a_tool(op) do
      Enum.find_value(@a2a_tools, fn {name, tool_op} -> if tool_op == op, do: name end)
    end

    defp slug(name) do
      name |> String.replace(~r/[^A-Za-z0-9]+/, "_") |> String.trim("_")
    end

    defp operation_tools do
      for item <- operation_items(),
          tool = operation_tool(item),
          do: operation_tool_def(item, tool)
    end

    # The served items that get a tool of their own, plus one for every
    # JSON-RPC method that is served only under an alias spelling.
    defp operation_items do
      items = Surface.items()
      methods = for %{kind: :jsonrpc_method, name: name} <- items, do: name

      alias_only =
        for %{name: spelling} <- Surface.jsonrpc_aliases(),
            target = Surface.alias_target(spelling),
            target not in methods,
            uniq: true do
          %{
            id: "jsonrpc_alias:" <> spelling,
            kind: :jsonrpc_method,
            name: target,
            source: "JSON-RPC method alias tables"
          }
        end

      items ++ alias_only
    end

    defp operation_tool_def(%{kind: :jsonrpc_method, name: method} = item, tool) do
      spellings = [
        method
        | for(a <- Surface.jsonrpc_aliases(), Surface.alias_target(a.name) == method, do: a.name)
      ]

      tool(
        tool,
        "JSON-RPC #{method}",
        "Sends the JSON-RPC 2.0 request `#{method}` to a JSON-RPC mount of the simulation server " <>
          "(POST, real HTTP) and answers the exact response. `params` is the method's params object, " <>
          "sent as given. Derived from surface item `#{item.id}`.",
        %{
          "params" => %{
            "description" => "The JSON-RPC params, sent as given.",
            "default" => %{}
          },
          "mount" => %{
            "type" => "string",
            "enum" => ["a2a", "jsonrpc", "required_a2a"],
            "default" => "a2a",
            "description" =>
              "`a2a` is AshA2A.A2ATransport.Plug (push configs, resubscribe, extended card); `jsonrpc` is AshA2A.Transport.Plug; " <>
                "`required_a2a` is the A2ATransport mount that requires the extension `sim_info` names as `required_extension` in `A2A-Extensions`."
          },
          "method_spelling" => %{
            "type" => "string",
            "enum" => spellings,
            "default" => default_spelling(method) || method,
            "description" =>
              "The method name to put on the wire: the canonical name or one of its aliases."
          },
          "request_id" => %{
            "type" => ["string", "integer", "null"],
            "description" => "The JSON-RPC id. Defaults to a fresh integer."
          }
        },
        []
      )
    end

    defp operation_tool_def(%{kind: :http_route, name: route} = item, tool) do
      [verb, path] = String.split(route, " ", parts: 2)

      path_props =
        for {segment, key, text} <- [
              {"{id}", "id", "The task id in the path."},
              {"{configId}", "configId", "The push notification config id in the path."}
            ],
            String.contains?(path, segment),
            into: %{} do
          {key, %{"type" => "string", "description" => text}}
        end

      body =
        if verb in ["POST", "PUT", "PATCH"],
          do: %{
            "body" => %{
              "description" => "The JSON request body, sent as given. Defaults to `{}`."
            }
          },
          else: %{}

      tool(
        tool,
        "HTTP+JSON #{route}",
        "Sends `#{route}` to the HTTP+JSON mount (`/rest`) of the simulation server and answers " <>
          "the exact response. Derived from surface item `#{item.id}`.",
        path_props
        |> Map.merge(body)
        |> Map.put("query", %{
          "type" => "object",
          "description" => "Query string parameters.",
          "additionalProperties" => %{"type" => ["string", "integer", "boolean"]}
        }),
        Map.keys(path_props)
      )
    end

    defp operation_tool_def(%{kind: :grpc_rpc, name: rpc} = item, tool) do
      shape = Map.get(Wire.grpc_rpcs(), rpc)
      request = shape && inspect(shape.request)

      {props, required} =
        if shape && shape.client_stream do
          {%{
             "requests" => %{
               "type" => "array",
               "items" => %{"type" => "object"},
               "description" => "The #{request} messages to write, in order, as protobuf JSON."
             },
             "half_close" => %{
               "type" => "boolean",
               "default" => false,
               "description" => "Send END_STREAM after the last request."
             }
           }, ["requests"]}
        else
          {%{
             "request" => %{
               "type" => "object",
               "default" => %{},
               "description" => "The #{request} message as protobuf JSON."
             }
           }, []}
        end

      tool(
        tool,
        "gRPC #{rpc}",
        "Calls `#{Wire.grpc_service()}/#{rpc}` on the gRPC endpoint of the simulation server over " <>
          "HTTP/2 and answers the reply as protobuf JSON (`body`), its protobuf bytes (`body_base64`), " <>
          "the gRPC status and the trailers. Derived from surface item `#{item.id}`.",
        props
        |> Map.put("metadata", %{
          "type" => "object",
          "description" => "Extra gRPC metadata.",
          "additionalProperties" => %{"type" => "string"}
        })
        |> Map.put("target", %{
          "type" => "string",
          "enum" => ["default", "required"],
          "default" => "default",
          "description" =>
            "`required` calls the second gRPC listener, whose A2A-Extensions gate requires the extension `sim_info` names as `required_extension`."
        }),
        required
      )
    end

    defp tool(name, title, description, props, required, output \\ nil) do
      %{
        "name" => name,
        "title" => title,
        "description" => description,
        "inputSchema" => %{
          "type" => "object",
          "properties" => Map.merge(common_props(), props),
          "required" => required,
          "additionalProperties" => false
        },
        "outputSchema" => output || wire_output()
      }
    end

    defp common_props do
      %{
        "a2a_version" => %{
          "type" => "string",
          "default" => "1.1",
          "description" =>
            "The A2A-Version header (gRPC: `a2a-version` metadata). `none` omits it."
        },
        "token" => %{
          "type" => "string",
          "default" => "writer",
          "description" =>
            "`writer` (holds the grants), `reader` (no grants), `unscoped` (lacks a2a:invoke), `none` (no credentials), or a literal bearer token (`sim-agent-<name>` is a caller of its own)."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "minimum" => 1,
          "default" => 20_000,
          "description" => "How long to wait for the response."
        },
        "headers" => %{
          "type" => "object",
          "description" => "Extra request headers (gRPC: metadata).",
          "additionalProperties" => %{"type" => "string"}
        }
      }
    end

    defp binding_props(bindings \\ @bindings) do
      %{
        "binding" => %{
          "type" => "string",
          "enum" => bindings,
          "description" =>
            "`jsonrpc` (JSON-RPC 2.0 over HTTP), `http_json` (the HTTP+JSON mount) or `grpc`."
        },
        "jsonrpc_mount" => %{
          "type" => "string",
          "enum" => ["a2a", "jsonrpc", "required_a2a"],
          "default" => "a2a",
          "description" => "Which JSON-RPC mount to use when `binding` is `jsonrpc`."
        }
      }
    end

    defp a2a_tools do
      skills = Enum.map(skills(), & &1.name)

      message_props = %{
        "skill" => %{
          "type" => "string",
          "enum" => skills,
          "description" => "The skill to run; sent as `message.metadata.skill`."
        },
        "data" => %{
          "type" => "object",
          "description" => "The skill's arguments; sent as the message's data part."
        },
        "text" => %{"type" => "string", "description" => "A text part to add to the message."},
        "task_id" => %{
          "type" => "string",
          "description" => "Continue this task (`message.taskId`)."
        },
        "context_id" => %{"type" => "string", "description" => "`message.contextId`."},
        "message_id" => %{
          "type" => "string",
          "description" => "`message.messageId`; a fresh id by default."
        },
        "return_immediately" => %{
          "type" => "boolean",
          "description" => "`configuration.returnImmediately`: answer before the work is done."
        },
        "if_generation_match" => %{
          "type" => "integer",
          "description" => "`configuration.ifGenerationMatch`: refuse when the task has moved on."
        },
        "history_length" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" => "`configuration.historyLength`."
        },
        "configuration" => %{
          "type" => "object",
          "description" => "Extra `configuration` members, sent as given."
        },
        "metadata" => %{"type" => "object", "description" => "Request-level `metadata`."},
        "message" => %{
          "type" => "object",
          "description" =>
            "A whole Message object to send instead of the one built from the fields above."
        }
      }

      task = %{"task_id" => %{"type" => "string", "description" => "The task id."}}

      config = %{
        "config_id" => %{"type" => "string", "description" => "The push notification config id."}
      }

      [
        a2a(
          "a2a_send_message",
          "Send a message",
          "Runs a skill with SendMessage (`message/send`, `POST /message:send`, `SendMessage`) and answers the task.",
          message_props,
          []
        ),
        a2a(
          "a2a_stream_message",
          "Send a message and stream the task",
          "Runs a skill with SendStreamingMessage (`message/stream`, `POST /message:stream`, `SendStreamingMessage`) " <>
            "and collects every stream response in `frames`. With a progress token each frame is also sent as a " <>
            "`notifications/progress` message while the stream runs.",
          message_props,
          []
        ),
        a2a(
          "a2a_live_message",
          "Open a live session",
          "Opens a live session (`POST /message:live`, gRPC `SendLiveMessage`), sends one message or one " <>
            "subscribe request and collects the stream responses. Over JSON-RPC the method is `SendLiveMessage`.",
          Map.merge(message_props, %{
            "subscribe_task_id" => %{
              "type" => "string",
              "description" => "Send a `subscribe` request for this task instead of a message."
            },
            "last_seen_generation" => %{"type" => "integer", "minimum" => 0},
            "half_close" => %{
              "type" => "boolean",
              "default" => false,
              "description" => "gRPC only: send END_STREAM after the request."
            }
          }),
          []
        ),
        a2a(
          "a2a_get_task",
          "Get a task",
          "Reads a task (`tasks/get`, `GET /tasks/{id}`, `GetTask`).",
          Map.put(task, "history_length", %{"type" => "integer", "minimum" => 0}),
          ["task_id"]
        ),
        a2a(
          "a2a_list_tasks",
          "List tasks",
          "Lists the caller's tasks (`tasks/list`, `GET /tasks`, `ListTasks`).",
          %{
            "context_id" => %{"type" => "string"},
            "status" => %{
              "type" => "string",
              "description" => "A TaskState name, for example TASK_STATE_WORKING."
            },
            "page_size" => %{"type" => "integer", "minimum" => 0},
            "page_token" => %{"type" => "string"},
            "history_length" => %{"type" => "integer", "minimum" => 0},
            "include_artifacts" => %{"type" => "boolean"}
          },
          []
        ),
        a2a(
          "a2a_cancel_task",
          "Cancel a task",
          "Cancels a task (`tasks/cancel`, `POST /tasks/{id}:cancel`, `CancelTask`).",
          task,
          ["task_id"]
        ),
        a2a(
          "a2a_subscribe_task",
          "Subscribe to a task",
          "Follows a task that is not finished to its final state (`tasks/resubscribe`, `/tasks/{id}:subscribe`, " <>
            "`SubscribeToTask`) and collects the stream responses. `last_seen_generation` resumes after that generation.",
          Map.merge(task, %{
            "last_seen_generation" => %{"type" => "integer", "minimum" => 0},
            "http_verb" => %{
              "type" => "string",
              "enum" => ["POST", "GET"],
              "default" => "POST",
              "description" => "Which verb to use when `binding` is `http_json`."
            }
          }),
          ["task_id"]
        ),
        a2a(
          "a2a_create_push_config",
          "Create a push notification config",
          "Stores a webhook for a task (`tasks/pushNotificationConfig/set`, `POST /tasks/{id}/pushNotificationConfigs`, " <>
            "`CreateTaskPushNotificationConfig`). `sim_info` gives `push_url`, the webhook receiver of the simulation server.",
          Map.merge(task, %{
            "url" => %{"type" => "string", "description" => "The webhook URL."},
            "push_token" => %{
              "type" => "string",
              "description" => "Sent back in X-A2A-Notification-Token."
            },
            "config_id" => %{
              "type" => "string",
              "description" => "An id for the config; assigned when absent."
            }
          }),
          ["task_id", "url"]
        ),
        a2a(
          "a2a_get_push_config",
          "Get a push notification config",
          "Reads one webhook config of a task.",
          Map.merge(task, config),
          ["task_id", "config_id"]
        ),
        a2a(
          "a2a_list_push_configs",
          "List push notification configs",
          "Lists the webhook configs of a task.",
          task,
          ["task_id"]
        ),
        a2a(
          "a2a_delete_push_config",
          "Delete a push notification config",
          "Removes one webhook config of a task.",
          Map.merge(task, config),
          ["task_id", "config_id"]
        ),
        a2a(
          "a2a_get_extended_agent_card",
          "Get the extended agent card",
          "Reads the authenticated extended card (`agent/getAuthenticatedExtendedCard`, `GET /extendedAgentCard`, `GetExtendedAgentCard`).",
          %{},
          []
        ),
        tool(
          "a2a_get_agent_card",
          "Get the public agent card",
          "Reads `/.well-known/agent-card.json`. `binding` picks the mount whose card is read: `jsonrpc` reads " <>
            "the JSON-RPC mount's card, `http_json` the HTTP+JSON mount's, `grpc` the root card (gRPC has no " <>
            "public card RPC). `mount` overrides that. No credentials are sent unless `token` is set.",
          binding_props()
          |> Map.put("mount", %{
            "type" => "string",
            "enum" => ["root", "a2a", "jsonrpc", "rest", "required_a2a", "required_rest"]
          })
          |> Map.put("token", %{
            "type" => "string",
            "default" => "none",
            "description" => "As on the other tools; the public card needs none."
          }),
          []
        )
      ]
    end

    defp a2a(name, title, description, props, required, bindings \\ @bindings) do
      tool(name, title, description, Map.merge(binding_props(bindings), props), [
        "binding" | required
      ])
    end

    defp raw_tool do
      tool(
        "a2a_raw_request",
        "Send a raw request",
        "Sends a request the caller wrote byte for byte, to probe malformed input. `transport: \"http\"` sends an " <>
          "HTTP request with exactly `body` (or `body_base64`, or `json` encoded) to a mount; for `binding: \"grpc\"` " <>
          "it sends an HTTP/2 gRPC call whose message bytes are `body`/`body_base64`. `transport: \"tcp\"` writes the " <>
          "bytes to the listener's socket and answers what came back. The answer carries the status, the headers " <>
          "and the exact body bytes (`body_base64` when they are not UTF-8).",
        %{
          "binding" => %{"type" => "string", "enum" => @bindings},
          "transport" => %{"type" => "string", "enum" => ["http", "tcp"], "default" => "http"},
          "mount" => %{
            "type" => "string",
            "enum" => ["root", "a2a", "jsonrpc", "rest", "required_a2a", "required_rest"],
            "description" =>
              "The HTTP mount. Defaults to `a2a` for `jsonrpc` and `rest` for `http_json`. " <>
                "`required_a2a` and `required_rest` are the mounts that require the extension named by `sim_info`."
          },
          "method" => %{
            "type" => "string",
            "default" => "POST",
            "description" => "The HTTP method."
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Appended to the mount URL, for example `/tasks/x:cancel`. For gRPC, the HTTP/2 path; " <>
                "defaults to `/lf.a2a.v1.A2AService/SendMessage`."
          },
          "body" => %{
            "type" => "string",
            "description" => "The request body (or TCP bytes) as text."
          },
          "body_base64" => %{
            "type" => "string",
            "description" => "The request body (or TCP bytes), base64."
          },
          "json" => %{"description" => "Any JSON value; encoded and sent as the body."},
          "grpc_frame" => %{
            "type" => "boolean",
            "default" => true,
            "description" => "gRPC: wrap the bytes in the 5-byte length prefix."
          }
        },
        ["binding"]
      )
    end

    defp sim_tools do
      identity = %{
        "identity" => %{
          "type" => "string",
          "default" => "writer",
          "description" =>
            "Whose standing grant to change: `writer`, `reader`, `unscoped`, or a `sim-agent-<name>` token " <>
              "(any such token authenticates as an identity of its own, with no grants)."
        },
        "skill" => %{
          "type" => "string",
          "default" => "all",
          "description" =>
            "A skill name (`create_note`), a capability id (`AshA2A.Sim.Note.create`), or `all` for every skill that bears a consequence."
        }
      }

      grants_output =
        object(
          %{
            "identity" => %{"type" => "string"},
            "principal" => %{"type" => "string"},
            "grants" => %{
              "type" => "array",
              "items" =>
                object(
                  %{
                    "skill" => %{"type" => "string"},
                    "capability_id" => %{"type" => "string"},
                    "granted" => %{"type" => "boolean"},
                    "outcome" => %{"type" => "string"}
                  },
                  ["skill", "capability_id", "granted"]
                )
            }
          },
          ["identity", "grants"]
        )

      [
        sim(
          "sim_info",
          "Simulation server facts",
          "The bound URLs and ports of the simulation server, the fixture bearer tokens and the skills.",
          %{},
          [],
          object(
            %{
              "base_url" => %{"type" => "string"},
              "card_url" => %{"type" => "string"},
              "jsonrpc_url" => %{"type" => "string"},
              "a2a_url" => %{"type" => "string"},
              "rest_url" => %{"type" => "string"},
              "grpc_target" => %{"type" => "string"},
              "required_a2a_url" => %{"type" => "string"},
              "required_rest_url" => %{"type" => "string"},
              "required_grpc_target" => %{"type" => "string"},
              "required_extension" => %{"type" => "string"},
              "push_url" => %{"type" => "string"},
              "tokens" => %{"type" => "object"},
              "skills" => %{"type" => "array", "items" => %{"type" => "object"}},
              "a2a_version" => %{"type" => "string"}
            },
            [
              "base_url",
              "a2a_url",
              "jsonrpc_url",
              "rest_url",
              "grpc_target",
              "required_a2a_url",
              "required_rest_url",
              "required_grpc_target",
              "required_extension",
              "push_url",
              "tokens",
              "skills"
            ]
          )
        ),
        sim(
          "sim_grant_authority",
          "Issue a standing grant",
          "Files the standing authority grant a mutating skill needs (`AshA2A.Authority.Grant.grant/2`). " <>
            "The writer identity holds every grant when the server boots. Options: `principal`, `capability`, " <>
            "`expires_in_seconds`, `force` (see `AshA2A.Sim.MCP.AuthorityTools`).",
          AuthorityTools.grant_props(identity),
          [],
          AuthorityTools.grants_output(grants_output)
        ),
        sim(
          "sim_revoke_authority",
          "Revoke a standing grant",
          "Revokes a standing authority grant (`AshA2A.Authority.Grant.revoke/2`), so the skill is refused for " <>
            "that identity until `sim_grant_authority` issues the grant again. The prover needs the `writer` grants.",
          AuthorityTools.revoke_props(identity),
          [],
          AuthorityTools.grants_output(grants_output)
        ),
        sim(
          "sim_read_rows",
          "Read the note rows",
          "Reads `AshA2A.Sim.Note` straight from the Ash data layer (no A2A call), to confirm what a wire call " <>
            "changed. Also answers `publications`, the effects the `publish_note` skill recorded outside the data layer.",
          %{
            "id" => %{"type" => "string", "description" => "Only the row with this id."},
            "title" => %{
              "type" => "string",
              "description" => "Only rows with exactly this title."
            },
            "title_prefix" => %{
              "type" => "string",
              "description" => "Only rows whose title starts with this."
            }
          },
          [],
          object(
            %{
              "count" => %{"type" => "integer"},
              "total" => %{"type" => "integer"},
              "rows" => %{
                "type" => "array",
                "items" =>
                  object(
                    %{
                      "id" => %{"type" => "string"},
                      "title" => %{"type" => "string"},
                      "body" => %{"type" => ["string", "null"]},
                      "inserted_at" => %{"type" => "string"},
                      "updated_at" => %{"type" => "string"}
                    },
                    ["id", "title", "body"]
                  )
              },
              "publications" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            ["count", "total", "rows", "publications"]
          )
        ),
        sim(
          "sim_push_deliveries",
          "Read the webhook deliveries",
          "What the webhook receiver of the simulation server recorded: the path, headers, decoded body and raw " <>
            "bytes of every push notification delivered. `wait_ms` waits for a delivery that matches `path_suffix`.",
          %{
            "path_suffix" => %{
              "type" => "string",
              "description" => "Only deliveries whose path ends with this."
            },
            "wait_ms" => %{"type" => "integer", "minimum" => 0, "default" => 0},
            "reset" => %{
              "type" => "boolean",
              "default" => false,
              "description" => "Forget every delivery after reading."
            }
          },
          [],
          object(
            %{
              "count" => %{"type" => "integer"},
              "deliveries" => %{
                "type" => "array",
                "items" =>
                  object(
                    %{
                      "path" => %{"type" => "string"},
                      "headers" => %{"type" => "object"},
                      "body" => %{},
                      "raw" => %{"type" => ["string", "null"]},
                      "raw_base64" => %{"type" => ["string", "null"]}
                    },
                    ["path", "headers"]
                  )
              }
            },
            ["count", "deliveries"]
          )
        ),
        sim(
          "sim_surface",
          "The served surface",
          "The inventory `AshA2A.Sim.Surface` derives from the library: every JSON-RPC method and alias, " <>
            "HTTP+JSON route, gRPC RPC, skill, consequence class, task state, security scheme and mount, each " <>
            "with the MCP tools that reach it.",
          %{
            "kind" => %{
              "type" => "string",
              "description" => "Only items of this kind, for example `grpc_rpc`."
            }
          },
          [],
          object(
            %{
              "count" => %{"type" => "integer"},
              "uncovered" => %{"type" => "array", "items" => %{"type" => "string"}},
              "items" => %{
                "type" => "array",
                "items" =>
                  object(
                    %{
                      "id" => %{"type" => "string"},
                      "kind" => %{"type" => "string"},
                      "name" => %{"type" => "string"},
                      "source" => %{"type" => "string"},
                      "tools" => %{"type" => "array", "items" => %{"type" => "string"}}
                    },
                    ["id", "kind", "name", "source", "tools"]
                  )
              }
            },
            ["count", "items", "uncovered"]
          )
        ),
        sim(
          "sim_coverage",
          "The coverage plan",
          "For every surface item, the tool calls that reach it and what each must answer " <>
            "(`AshA2A.Sim.MCP.Coverage.plan/0`). A client runs the steps in order through `tools/call`.",
          %{
            "surface" => %{"type" => "string", "description" => "Only the item with this id."},
            "kind" => %{"type" => "string", "description" => "Only items of this kind."},
            "steps" => %{
              "type" => "boolean",
              "description" =>
                "Include each item's steps. Defaults to true when `surface` is given, else false (the whole plan is large)."
            }
          },
          [],
          object(
            %{
              "count" => %{"type" => "integer"},
              "uncovered" => %{"type" => "array", "items" => %{"type" => "string"}},
              "items" => %{"type" => "array", "items" => %{"type" => "object"}}
            },
            ["count", "items", "uncovered"]
          )
        ),
        sim(
          "sim_prove",
          "Run the prover",
          "Runs `AshA2A.Sim.Prover` against the running simulation server and answers the matrix: one row per " <>
            "probe with its surface item, status and detail. The whole run takes about a minute; `surface_prefix` " <>
            "runs only the probes of matching surface items.",
          %{
            "surface_prefix" => %{
              "type" => "string",
              "description" =>
                "Only probes whose surface id starts with this, for example `grpc_rpc:`."
            }
          },
          [],
          object(
            %{
              "summary" =>
                object(
                  %{
                    "pass" => %{"type" => "integer"},
                    "fail" => %{"type" => "integer"},
                    "skip" => %{"type" => "integer"}
                  },
                  ["pass", "fail", "skip"]
                ),
              "uncovered" => %{"type" => "array", "items" => %{"type" => "string"}},
              "results" => %{
                "type" => "array",
                "items" =>
                  object(
                    %{
                      "surface" => %{"type" => "string"},
                      "probe" => %{"type" => "string"},
                      "status" => %{"type" => "string", "enum" => ["pass", "fail", "skip"]},
                      "detail" => %{"type" => "string"}
                    },
                    ["surface", "probe", "status", "detail"]
                  )
              }
            },
            ["summary", "uncovered", "results"]
          )
        ),
        sim(
          "sim_parity",
          "Run the A2A v1.1 parity check",
          "Runs the byte-for-byte parity script (`AshA2A.Sim.Parity`, `scripts/a2a_v1_1_parity/parity.py`) " <>
            "against the running simulation server: an independent reference built from the upstream A2A v1.1 " <>
            "proto calls every RPC, route and method and compares the bytes on the wire. Answers one verdict per " <>
            "binding (`pass`, `known` when its only failing rows are documented defects, `fail`), the row counts " <>
            "and the rows asked for. The script runs once per server; later calls answer from that report unless " <>
            "`fresh` is set. `ran` is false, with the `reason`, when the Python reference is not installed " <>
            "(`scripts/a2a_v1_1_parity/setup.sh`).",
          %{
            "binding" => %{
              "type" => "string",
              "enum" => Parity.bindings(),
              "description" => "Only this binding's verdict, counts and rows."
            },
            "strict" => %{
              "type" => "boolean",
              "default" => false,
              "description" => "Count a known defect as a failure."
            },
            "statuses" => %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => ["pass", "fail", "known", "skip"]},
              "description" =>
                "Which rows to return. Defaults to `fail` and `known`; the counts always cover every row."
            },
            "operation" => %{
              "type" => "string",
              "description" => "Only rows whose operation contains this text."
            },
            "fresh" => %{
              "type" => "boolean",
              "default" => false,
              "description" => "Run the script again."
            },
            "timeout_ms" => %{"type" => "integer", "minimum" => 1, "default" => 120_000}
          },
          [],
          object(
            %{
              "ran" => %{"type" => "boolean"},
              "ok" => %{"type" => "boolean"},
              "reason" => %{"type" => "string"},
              "strict" => %{"type" => "boolean"},
              "summary" =>
                object(
                  Map.new(~w(pass fail known skip), &{&1, %{"type" => "integer"}}),
                  ~w(pass fail known skip)
                ),
              "known_defects" => %{"type" => "array", "items" => %{"type" => "string"}},
              "verdicts" => %{
                "type" => "array",
                "items" =>
                  object(
                    %{
                      "binding" => %{"type" => "string"},
                      "verdict" => %{"type" => "string", "enum" => ["pass", "known", "fail"]},
                      "detail" => %{"type" => "string"}
                    },
                    ["binding", "verdict", "detail"]
                  )
              },
              "row_count" => %{"type" => "integer"},
              "rows" => %{"type" => "array", "items" => %{"type" => "object"}}
            },
            ["ran", "ok", "summary", "known_defects", "verdicts", "row_count", "rows"]
          )
        )
      ]
    end

    defp sim(name, title, description, props, required, output) do
      %{
        "name" => name,
        "title" => title,
        "description" => description,
        "inputSchema" => object(props, required) |> Map.put("additionalProperties", false),
        "outputSchema" => output
      }
    end

    defp object(props, required),
      do: %{"type" => "object", "properties" => props, "required" => required}

    defp wire_output do
      nullable = fn type -> %{"type" => [type, "null"]} end

      object(
        %{
          "binding" => %{"type" => "string", "enum" => @bindings},
          "request" => %{"type" => "object"},
          "status" => nullable.("integer"),
          "status_name" => %{"type" => "string"},
          "headers" => %{"type" => "object", "additionalProperties" => %{"type" => "string"}},
          "trailers" => %{"type" => "object", "additionalProperties" => %{"type" => "string"}},
          "body" => nullable.("string"),
          "body_base64" => nullable.("string"),
          "json" => %{},
          "frames" => %{"type" => "array"},
          "frame_kinds" => %{"type" => "array", "items" => %{"type" => "string"}},
          "states" => %{"type" => "array", "items" => %{"type" => "string"}},
          "final_state" => nullable.("string"),
          "result" => %{},
          "error" => %{},
          "task" => nullable.("object"),
          "state" => nullable.("string"),
          "data" => %{},
          "config" => nullable.("object"),
          "configs" => %{"type" => "array"},
          "ok" => %{"type" => "boolean"},
          "note" => %{"type" => "string"}
        },
        ["binding", "request", "status", "headers", "body", "body_base64", "frames", "ok"]
      )
    end

    # == calling =================================================================

    @doc """
    Runs the tool `name` with `arguments` against the server described by
    `ctx.info` (`AshA2A.Sim.Server.info/0`). `ctx.on_frame` is called with
    each stream response as it arrives.

    Answers `{:ok, structured}` or `{:error, text}`. An A2A refusal (a `401`,
    a JSON-RPC error, a non-zero gRPC status) is an `{:ok, _}` answer: the
    tool did its job and the answer says what the server refused.
    """
    @spec call(String.t(), map(), map()) :: {:ok, map()} | {:error, String.t()}
    def call(name, arguments, ctx) do
      case Enum.find(list(), &(&1["name"] == name)) do
        nil ->
          {:error, "unknown tool #{inspect(name)}"}

        tool ->
          case validate(tool["inputSchema"], arguments, "arguments") do
            [] -> run(name, arguments, ctx)
            errors -> {:error, "invalid arguments for #{name}: " <> Enum.join(errors, "; ")}
          end
      end
    end

    @doc """
    Checks `value` against the subset of JSON Schema the catalog uses (`type`,
    `enum`, `required`, `properties`, `additionalProperties`, `items`,
    `minimum`) and answers the list of violations.
    """
    @spec validate(map(), term(), String.t()) :: [String.t()]
    def validate(schema, value, path) do
      type_errors(schema["type"], value, path) ++
        enum_errors(schema["enum"], value, path) ++
        minimum_errors(schema["minimum"], value, path) ++
        object_errors(schema, value, path) ++ items_errors(schema["items"], value, path)
    end

    defp type_errors(nil, _value, _path), do: []

    defp type_errors(types, value, path) do
      if Enum.any?(List.wrap(types), &type?(&1, value)),
        do: [],
        else: ["#{path} must be #{types |> List.wrap() |> Enum.join(" or ")}"]
    end

    defp type?("object", value), do: is_map(value)
    defp type?("array", value), do: is_list(value)
    defp type?("string", value), do: is_binary(value)
    defp type?("integer", value), do: is_integer(value)
    defp type?("number", value), do: is_number(value)
    defp type?("boolean", value), do: is_boolean(value)
    defp type?("null", value), do: is_nil(value)
    defp type?(_other, _value), do: false

    defp enum_errors(nil, _value, _path), do: []

    defp enum_errors(allowed, value, path),
      do:
        if(value in allowed, do: [], else: ["#{path} must be one of #{Enum.join(allowed, ", ")}"])

    defp minimum_errors(minimum, value, path) when is_number(minimum) and is_number(value),
      do: if(value >= minimum, do: [], else: ["#{path} must be at least #{minimum}"])

    defp minimum_errors(_minimum, _value, _path), do: []

    defp object_errors(schema, value, path) when is_map(value) do
      props = schema["properties"] || %{}

      missing =
        for key <- schema["required"] || [],
            not Map.has_key?(value, key),
            do: "#{path}.#{key} is required"

      unknown =
        case schema["additionalProperties"] do
          false ->
            for {key, _} <- value,
                not Map.has_key?(props, key),
                do: "#{path}.#{key} is not a known argument"

          %{} = extra ->
            for {key, v} <- value,
                not Map.has_key?(props, key),
                error <- validate(extra, v, "#{path}.#{key}"),
                do: error

          _ ->
            []
        end

      nested =
        for {key, sub} <- props,
            Map.has_key?(value, key),
            error <- validate(sub, value[key], "#{path}.#{key}"),
            do: error

      missing ++ unknown ++ nested
    end

    defp object_errors(_schema, _value, _path), do: []

    defp items_errors(%{} = items, value, path) when is_list(value) do
      for {element, index} <- Enum.with_index(value),
          error <- validate(items, element, "#{path}[#{index}]"),
          do: error
    end

    defp items_errors(_items, _value, _path), do: []

    # -- dispatch ----------------------------------------------------------------

    defp run("a2a_get_agent_card", args, ctx) do
      mount =
        args["mount"] ||
          case args["binding"] do
            "jsonrpc" -> args["jsonrpc_mount"] || "a2a"
            "http_json" -> "rest"
            _other -> "root"
          end

      url = mount_url(ctx.info, mount) <> "/.well-known/agent-card.json"
      args = Map.put_new(args, "token", "none")
      binding = if mount in ["rest", "required_rest"], do: "http_json", else: "jsonrpc"

      with {:ok, answer} <- http_request(binding, :get, url, nil, args, ctx) do
        note =
          if args["binding"] == "grpc",
            do: %{"note" => "gRPC has no public agent card RPC; this is the root card over HTTP."},
            else: %{}

        {:ok, Map.merge(answer, note)}
      end
    end

    defp run("a2a_raw_request", args, ctx), do: raw(args, ctx)

    defp run("sim_email_" <> _ = name, args, ctx),
      do: AshA2A.Sim.MCP.EmailTools.run(name, args, ctx)

    defp run("sim_info", _args, ctx), do: {:ok, sim_info(ctx.info)}
    defp run("sim_grant_authority", args, _ctx), do: AuthorityTools.grant(args, :grant)
    defp run("sim_revoke_authority", args, _ctx), do: AuthorityTools.grant(args, :revoke)

    defp run(name, args, _ctx)
         when name in ["sim_trip_kill_switch", "sim_reset_kill_switch", "sim_receipts"],
         do: AuthorityTools.run(name, args)

    defp run("sim_read_rows", args, _ctx), do: {:ok, read_rows(args)}
    defp run("sim_push_deliveries", args, _ctx), do: {:ok, push_deliveries(args)}
    defp run("sim_surface", args, _ctx), do: {:ok, surface(args)}
    defp run("sim_coverage", args, _ctx), do: {:ok, coverage(args)}
    defp run("sim_prove", args, ctx), do: {:ok, prove(args, ctx)}
    defp run("sim_parity", args, ctx), do: parity(args, ctx)

    defp run("a2a_" <> _ = name, args, ctx) do
      {_name, op} = List.keyfind(@a2a_tools, name, 0)

      case native(op, args) do
        {:ok, tool, native_args} -> run(tool, native_args, ctx)
        {:error, _} = error -> error
      end
    end

    defp run(name, args, ctx) do
      case Enum.find(operation_items(), &(operation_tool(&1) == name)) do
        %{kind: :jsonrpc_method, name: method} -> jsonrpc(method, args, ctx)
        %{kind: :http_route, name: route} -> http_route(route, args, ctx)
        %{kind: :grpc_rpc, name: rpc} -> grpc(rpc, args, ctx)
        nil -> {:error, "tool #{name} has no implementation"}
      end
    end

    # -- a2a_* -> the binding's own tool -----------------------------------------

    @doc """
    Translates the arguments of an `a2a_*` tool into the binding's own tool
    and arguments: `{:ok, tool_name, arguments}`. `args["binding"]` picks the
    binding; for `"http_json"`, `args["http_route"]` may name the route.
    """
    @spec native(atom(), map()) :: {:ok, String.t(), map()} | {:error, String.t()}
    def native(op, args) do
      common = Map.take(args, ~w(a2a_version token timeout_ms headers))

      case args["binding"] do
        "jsonrpc" ->
          case Enum.find(@jsonrpc_ops, fn {_method, method_op} -> method_op == op end) do
            {method, _} ->
              native_args =
                common
                |> Map.put("params", payload(op, args))
                |> put_some("mount", args["jsonrpc_mount"])
                |> put_some(
                  "method_spelling",
                  args["method_spelling"] || default_spelling(method)
                )

              {:ok, "jsonrpc_" <> slug(method), native_args}

            nil ->
              {:error,
               "the JSON-RPC binding has no method for this operation; use http_json or grpc"}
          end

        "http_json" ->
          route = args["http_route"] || subscribe_route(op, args) || @http_default[op]
          {:ok, "http_" <> slug(route), Map.merge(common, http_args(op, route, args))}

        "grpc" ->
          case Enum.find(@grpc_ops, fn {_rpc, rpc_op} -> rpc_op == op end) do
            {rpc, _} -> {:ok, "grpc_" <> rpc, Map.merge(common, grpc_args(op, args))}
            nil -> {:error, "the gRPC binding has no RPC for this operation"}
          end

        other ->
          {:error, "binding must be one of #{Enum.join(@bindings, ", ")}, got #{inspect(other)}"}
      end
    end

    # A method served only under an alias goes on the wire under that alias.
    defp default_spelling(method) do
      methods = for %{name: name} <- Surface.jsonrpc_methods(), do: name

      if method not in methods do
        Enum.find_value(Surface.jsonrpc_aliases(), fn %{name: spelling} ->
          if Surface.alias_target(spelling) == method, do: spelling
        end)
      end
    end

    defp subscribe_route(:subscribe, %{"http_verb" => "GET"}), do: "GET /tasks/{id}:subscribe"
    defp subscribe_route(_op, _args), do: nil

    # The operation's request in the JSON shape JSON-RPC params and protobuf
    # JSON share.
    defp payload(op, args) when op in [:send, :stream] do
      message =
        args["message"] ||
          %{
            "messageId" => args["message_id"] || "msg-mcp-" <> unique(),
            "role" => "ROLE_USER",
            "parts" => parts(args),
            "metadata" => %{"skill" => args["skill"]}
          }
          |> put_some("taskId", args["task_id"])
          |> put_some("contextId", args["context_id"])

      configuration =
        (args["configuration"] || %{})
        |> put_some("returnImmediately", args["return_immediately"])
        |> put_some("ifGenerationMatch", args["if_generation_match"])
        |> put_some("historyLength", args["history_length"])

      %{"message" => message}
      |> put_some("configuration", if(configuration == %{}, do: nil, else: configuration))
      |> put_some("metadata", args["metadata"])
    end

    defp payload(:live, %{"subscribe_task_id" => id} = args) when is_binary(id) do
      %{
        "subscribe" => put_some(%{"id" => id}, "lastSeenGeneration", args["last_seen_generation"])
      }
    end

    defp payload(:live, args), do: %{"sendMessage" => payload(:send, args)}

    defp payload(:get, args),
      do: put_some(%{"id" => args["task_id"]}, "historyLength", args["history_length"])

    defp payload(:list, args) do
      %{}
      |> put_some("contextId", args["context_id"])
      |> put_some("status", args["status"])
      |> put_some("pageSize", args["page_size"])
      |> put_some("pageToken", args["page_token"])
      |> put_some("historyLength", args["history_length"])
      |> put_some("includeArtifacts", args["include_artifacts"])
    end

    defp payload(:cancel, args), do: %{"id" => args["task_id"]}

    defp payload(:subscribe, args),
      do: put_some(%{"id" => args["task_id"]}, "lastSeenGeneration", args["last_seen_generation"])

    defp payload(:push_create, args),
      do: %{"taskId" => args["task_id"], "pushNotificationConfig" => push_config(args)}

    defp payload(op, args) when op in [:push_get, :push_delete],
      do: %{"id" => args["task_id"], "pushNotificationConfigId" => args["config_id"]}

    defp payload(:push_list, args), do: %{"id" => args["task_id"]}
    defp payload(_op, _args), do: %{}

    defp push_config(args) do
      %{"url" => args["url"]}
      |> put_some("token", args["push_token"])
      |> put_some("id", args["config_id"])
    end

    defp parts(args) do
      data =
        if args["data"] || is_nil(args["text"]), do: [%{"data" => args["data"] || %{}}], else: []

      text = if args["text"], do: [%{"text" => args["text"]}], else: []
      data ++ text
    end

    defp http_args(op, route, args) do
      [verb, path] = String.split(route, " ", parts: 2)

      path_args =
        %{}
        |> put_some("id", if(String.contains?(path, "{id}"), do: args["task_id"]))
        |> put_some("configId", if(String.contains?(path, "{configId}"), do: args["config_id"]))

      body =
        case op do
          op when op in [:send, :stream, :live] -> payload(op, args)
          :push_create -> %{"pushNotificationConfig" => push_config(args)}
          _other -> %{}
        end

      query =
        case op do
          :get -> Map.delete(payload(:get, args), "id")
          :list -> payload(:list, args)
          :subscribe -> Map.delete(payload(:subscribe, args), "id")
          _other -> %{}
        end

      path_args
      |> put_some("body", if(verb == "POST", do: body))
      |> put_some("query", if(query == %{}, do: nil, else: query))
    end

    defp grpc_args(:live, args) do
      %{"requests" => [payload(:live, args)]} |> put_some("half_close", args["half_close"])
    end

    defp grpc_args(:push_create, args),
      do: %{"request" => Map.put(push_config(args), "taskId", args["task_id"])}

    defp grpc_args(op, args) when op in [:push_get, :push_delete],
      do: %{"request" => %{"taskId" => args["task_id"], "id" => args["config_id"]}}

    defp grpc_args(:push_list, args), do: %{"request" => %{"taskId" => args["task_id"]}}
    defp grpc_args(op, args), do: %{"request" => payload(op, args)}

    # -- the three bindings ------------------------------------------------------

    defp jsonrpc(method, args, ctx) do
      envelope = %{
        "jsonrpc" => "2.0",
        "id" => args["request_id"] || System.unique_integer([:positive]),
        "method" => args["method_spelling"] || default_spelling(method) || method,
        "params" => Map.get(args, "params", %{})
      }

      url = mount_url(ctx.info, args["mount"] || "a2a")
      http_request("jsonrpc", :post, url, Jason.encode!(envelope), args, ctx)
    end

    defp http_route(route, args, ctx) do
      [verb, path] = String.split(route, " ", parts: 2)

      path =
        path
        |> String.replace("{id}", encode(args["id"]))
        |> String.replace("{configId}", encode(args["configId"]))

      query =
        case args["query"] do
          query when is_map(query) and query != %{} -> "?" <> URI.encode_query(query)
          _other -> ""
        end

      body = if verb == "POST", do: Jason.encode!(Map.get(args, "body", %{}))
      method = verb |> String.downcase() |> String.to_existing_atom()
      http_request("http_json", method, ctx.info.rest_url <> path <> query, body, args, ctx)
    end

    defp encode(nil), do: ""
    defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

    defp http_request(binding, method, url, body, args, ctx) do
      headers =
        version_header(args) ++
          auth_header(args, ctx.info) ++
          if(body, do: [{"content-type", "application/json"}], else: []) ++
          Enum.map(args["headers"] || %{}, fn {name, value} -> {String.downcase(name), value} end)

      opts = [timeout: args["timeout_ms"] || 20_000, on_frame: on_frame(binding, ctx)]

      with {:ok, wire} <- Wire.http(method, url, headers, body, opts) do
        request = %{
          "method" => method |> Atom.to_string() |> String.upcase(),
          "url" => url,
          "headers" => Map.new(headers),
          "body" => body
        }

        {:ok, http_answer(binding, request, wire)}
      end
    end

    defp on_frame("jsonrpc", ctx) do
      emit = Map.get(ctx, :on_frame, fn _ -> :ok end)
      fn frame -> emit.(unwrap_frame(frame)) end
    end

    defp on_frame(_binding, ctx), do: Map.get(ctx, :on_frame, fn _ -> :ok end)

    defp grpc(rpc, args, ctx) do
      metadata =
        (args["metadata"] || %{})
        |> Map.merge(args["headers"] || %{})
        |> Map.merge(Map.new(version_header(args) ++ auth_header(args, ctx.info)))

      request =
        if Map.has_key?(args, "requests"),
          do: args["requests"],
          else: Map.get(args, "request", %{})

      opts = [
        timeout: args["timeout_ms"] || 20_000,
        half_close: args["half_close"] == true,
        on_frame: Map.get(ctx, :on_frame, fn _ -> :ok end)
      ]

      target =
        if args["target"] == "required",
          do: ctx.info.required_grpc_target,
          else: ctx.info.grpc_target

      with {:ok, wire} <- Wire.grpc(target, rpc, request, metadata, opts) do
        described = %{
          "method" => "POST",
          "url" => "http://#{target}/#{Wire.grpc_service()}/#{rpc}",
          "headers" => metadata,
          "body" => Jason.encode!(request)
        }

        {:ok, grpc_answer(described, wire)}
      end
    end

    defp version_header(args) do
      case Map.get(args, "a2a_version", "1.1") do
        "none" -> []
        version -> [{"a2a-version", version}]
      end
    end

    defp auth_header(args, info) do
      case Map.get(args, "token", "writer") do
        "none" -> []
        "writer" -> [{"authorization", "Bearer " <> info.tokens.writer}]
        "reader" -> [{"authorization", "Bearer " <> info.tokens.reader}]
        "unscoped" -> [{"authorization", "Bearer " <> info.tokens.unscoped}]
        literal -> [{"authorization", "Bearer " <> literal}]
      end
    end

    defp mount_url(info, "root"), do: info.base_url
    defp mount_url(info, "a2a"), do: info.a2a_url
    defp mount_url(info, "jsonrpc"), do: info.jsonrpc_url
    defp mount_url(info, "rest"), do: info.rest_url
    defp mount_url(info, "required_a2a"), do: info.required_a2a_url
    defp mount_url(info, "required_rest"), do: info.required_rest_url

    # -- answers -----------------------------------------------------------------

    defp http_answer(binding, request, wire) do
      raw = wire["raw"]
      json = decode_json(raw)
      sse? = (wire["headers"]["content-type"] || "") =~ "text/event-stream"

      frames =
        if binding == "jsonrpc",
          do: Enum.map(wire["frames"], &unwrap_frame/1),
          else: wire["frames"]

      success? = wire["status"] in 200..299

      {result, error} =
        cond do
          sse? ->
            {nil, Enum.find_value(frames, & &1["error"])}

          binding == "jsonrpc" and is_map(json) and Map.has_key?(json, "error") ->
            {nil, json["error"]}

          binding == "jsonrpc" and is_map(json) and Map.has_key?(json, "result") ->
            {json["result"], nil}

          success? ->
            {json, nil}

          true ->
            {nil, json || %{"status" => wire["status"]}}
        end

      %{
        "binding" => binding,
        "request" => request,
        "status" => wire["status"],
        "status_name" => "HTTP #{wire["status"]}",
        "headers" => wire["headers"],
        "trailers" => %{},
        "json" => json,
        "frames" => frames
      }
      |> Map.merge(body_fields(raw))
      |> derive(result, error, success? and is_nil(error))
    end

    defp grpc_answer(request, wire) do
      reply = wire["reply"]

      error =
        if wire["status"] != 0,
          do: %{
            "code" => wire["status"],
            "status" => wire["status_name"],
            "message" => wire["message"]
          }

      %{
        "binding" => "grpc",
        "request" => request,
        "status" => wire["status"],
        "status_name" => wire["status_name"],
        "headers" => wire["headers"],
        "trailers" => wire["trailers"],
        "json" => reply,
        "frames" => wire["frames"],
        "body" => reply && Jason.encode!(reply),
        "body_base64" => wire["reply_bytes"] && Base.encode64(wire["reply_bytes"])
      }
      |> derive(reply, error, wire["status"] == 0)
    end

    defp body_fields(raw) do
      if String.valid?(raw),
        do: %{"body" => raw, "body_base64" => nil},
        else: %{"body" => nil, "body_base64" => Base.encode64(raw)}
    end

    defp decode_json(raw) do
      case Jason.decode(raw) do
        {:ok, decoded} -> decoded
        {:error, _} -> nil
      end
    end

    defp unwrap_frame(%{"result" => result}) when is_map(result), do: result
    defp unwrap_frame(frame), do: frame

    # The fields a caller most often needs, read out of the answer.
    defp derive(answer, result, error, ok?) do
      frames = answer["frames"]
      task = task_of(result) || Enum.find_value(Enum.reverse(frames), &task_of/1)
      states = frames |> Enum.map(&frame_state/1) |> Enum.reject(&is_nil/1)
      state = task && get_in(task, ["status", "state"])

      Map.merge(answer, %{
        "result" => result,
        "error" => error,
        "task" => task,
        "state" => if(frames == [], do: state, else: List.last(states) || state),
        "states" => states,
        "final_state" => List.last(states) || state,
        "frame_kinds" => frames |> Enum.map(&frame_kind/1) |> Enum.reject(&is_nil/1),
        "data" => artifact_data(task) || Enum.find_value(frames, &frame_data/1),
        "config" => config_of(result),
        "configs" => configs_of(result),
        "ok" => ok?
      })
    end

    defp task_of(%{"task" => %{"id" => _} = task}), do: task
    defp task_of(%{"id" => _, "status" => %{}} = task), do: task
    defp task_of(_other), do: nil

    defp frame_kind(frame) when is_map(frame),
      do:
        Enum.find(
          ~w(task statusUpdate artifactUpdate messageUpdate message error),
          &Map.has_key?(frame, &1)
        )

    defp frame_kind(_frame), do: nil

    defp frame_state(%{"task" => %{"status" => %{"state" => state}}}), do: state
    defp frame_state(%{"statusUpdate" => %{"status" => %{"state" => state}}}), do: state
    defp frame_state(_frame), do: nil

    defp artifact_data(%{"artifacts" => [%{"parts" => [%{"data" => data} | _]} | _]}), do: data
    defp artifact_data(_task), do: nil

    defp frame_data(%{
           "artifactUpdate" => %{"artifact" => %{"parts" => [%{"data" => data} | _]}}
         }),
         do: data

    defp frame_data(_frame), do: nil

    defp config_of(%{"pushNotificationConfig" => %{"url" => _} = inner} = outer),
      do: outer |> Map.take(["taskId"]) |> Map.merge(inner)

    defp config_of(%{"url" => _} = flat), do: flat
    defp config_of(_other), do: nil

    defp configs_of(%{"configs" => configs}) when is_list(configs),
      do: Enum.map(configs, &config_of/1)

    defp configs_of(configs) when is_list(configs),
      do: configs |> Enum.map(&config_of/1) |> Enum.reject(&is_nil/1)

    defp configs_of(_other), do: []

    # -- a2a_raw_request ---------------------------------------------------------

    defp raw(args, ctx) do
      with {:ok, bytes} <- raw_bytes(args) do
        case {Map.get(args, "transport", "http"), args["binding"]} do
          {"tcp", binding} -> raw_tcp(binding, bytes, args, ctx)
          {"http", "grpc"} -> raw_grpc(bytes, args, ctx)
          {"http", binding} -> raw_http(binding, bytes, args, ctx)
        end
      end
    end

    defp raw_bytes(%{"body_base64" => encoded}) when is_binary(encoded) do
      case Base.decode64(encoded) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> {:error, "body_base64 is not base64"}
      end
    end

    defp raw_bytes(%{"body" => body}) when is_binary(body), do: {:ok, body}
    defp raw_bytes(args) when is_map_key(args, "json"), do: {:ok, Jason.encode!(args["json"])}
    defp raw_bytes(_args), do: {:ok, nil}

    # `a2a_raw_request` may only reach the sim's own listeners. The path is
    # appended to a loopback mount URL, so it must stay a path (or query):
    # `@evil.example/` after the bare `root` mount would otherwise turn the
    # mount into userinfo and the request into an SSRF. The method is a closed set.
    @raw_methods ~w(get post put patch delete head options)

    defp raw_http(binding, bytes, args, ctx) do
      with {:ok, path} <- raw_path(args["path"]),
           {:ok, method} <- raw_method(Map.get(args, "method", "POST")) do
        raw_http(binding, bytes, args, ctx, path, method)
      end
    end

    defp raw_path(nil), do: {:ok, ""}

    defp raw_path(path) when is_binary(path) do
      if (path == "" or String.starts_with?(path, ["/", "?"])) and
           not String.starts_with?(path, "//") and not String.contains?(path, ["\r", "\n", " "]),
         do: {:ok, path},
         else: {:error, "path must start with / or ? and stay on the sim's own listener"}
    end

    defp raw_path(_other), do: {:error, "path must be a string"}

    defp raw_method(method) when is_binary(method) do
      down = String.downcase(method)

      if down in @raw_methods,
        do: {:ok, String.to_existing_atom(down)},
        else: {:error, "method must be one of #{Enum.join(@raw_methods, ", ")}"}
    end

    defp raw_method(_other), do: {:error, "method must be a string"}

    defp raw_http(binding, bytes, args, ctx, path, method) do
      mount = args["mount"] || if(binding == "jsonrpc", do: "a2a", else: "rest")
      url = mount_url(ctx.info, mount) <> path

      extra =
        Enum.map(args["headers"] || %{}, fn {name, value} -> {String.downcase(name), value} end)

      content_type =
        if bytes && not List.keymember?(extra, "content-type", 0),
          do: [{"content-type", "application/json"}],
          else: []

      headers = version_header(args) ++ auth_header(args, ctx.info) ++ content_type ++ extra

      with {:ok, wire} <-
             Wire.http(method, url, headers, bytes, timeout: args["timeout_ms"] || 20_000) do
        request =
          %{
            "method" => String.upcase(to_string(method)),
            "url" => url,
            "headers" => Map.new(headers)
          }
          |> Map.merge(request_body(bytes))

        {:ok, http_answer(binding, request, wire)}
      end
    end

    defp raw_grpc(bytes, args, ctx) do
      case raw_path(args["path"] || "/#{Wire.grpc_service()}/SendMessage") do
        {:ok, path} -> raw_grpc(bytes, args, ctx, path)
        {:error, _} = error -> error
      end
    end

    defp raw_grpc(bytes, args, ctx, path) do
      extra =
        Enum.map(args["headers"] || %{}, fn {name, value} -> {String.downcase(name), value} end)

      headers = version_header(args) ++ auth_header(args, ctx.info) ++ extra

      opts = [timeout: args["timeout_ms"] || 10_000, frame: Map.get(args, "grpc_frame", true)]

      with {:ok, wire} <- Wire.grpc_raw(ctx.info.grpc_target, path, headers, bytes || "", opts) do
        meta = Map.merge(wire["headers"], wire["trailers"])

        grpc_status =
          case Integer.parse(meta["grpc-status"] || "") do
            {code, ""} -> code
            _ -> nil
          end

        error =
          if grpc_status != 0,
            do: %{
              "code" => grpc_status,
              "status" => grpc_status && Wire.grpc_status_name(grpc_status),
              "message" => meta["grpc-message"],
              "http_status" => wire["status"]
            }

        request =
          %{
            "method" => "POST",
            "url" => "http://#{ctx.info.grpc_target}#{path}",
            "headers" => Map.new(headers)
          }
          |> Map.merge(request_body(bytes))

        {:ok,
         %{
           "binding" => "grpc",
           "request" => request,
           "status" => grpc_status,
           "status_name" =>
             (grpc_status && Wire.grpc_status_name(grpc_status)) || "HTTP #{wire["status"]}",
           "headers" => wire["headers"],
           "trailers" => wire["trailers"],
           "json" => nil,
           "frames" => [],
           "note" =>
             "HTTP/2 status #{wire["status"]}; body is the DATA bytes received (gRPC length-prefixed)."
         }
         |> Map.merge(body_fields(wire["raw"]))
         |> derive(nil, error, grpc_status == 0)}
      end
    end

    defp raw_tcp(binding, bytes, args, ctx) do
      port = if binding == "grpc", do: ctx.info.grpc_port, else: ctx.info.http_port

      with {:ok, wire} <-
             Wire.tcp("127.0.0.1", port, bytes || "",
               idle_ms: min(args["timeout_ms"] || 1_000, 10_000)
             ) do
        raw = wire["raw"]

        {status, headers, body} =
          case Regex.run(~r/\AHTTP\/1\.[01] (\d{3})[^\r\n]*\r\n(.*?)\r\n\r\n(.*)\z/s, raw) do
            [_, status, head, body] ->
              headers =
                for line <- String.split(head, "\r\n"),
                    [name, value] <- [String.split(line, ":", parts: 2)],
                    into: %{} do
                  {String.downcase(name), String.trim(value)}
                end

              {String.to_integer(status), headers, body}

            nil ->
              {nil, %{}, raw}
          end

        request =
          %{"method" => "TCP", "url" => "tcp://127.0.0.1:#{port}", "headers" => %{}}
          |> Map.merge(request_body(bytes))

        {:ok,
         %{
           "binding" => binding,
           "request" => request,
           "status" => status,
           "status_name" => if(status, do: "HTTP #{status}", else: "no HTTP/1.1 status line"),
           "headers" => headers,
           "trailers" => %{},
           "json" => if(String.valid?(body), do: decode_json(body)),
           "frames" => [],
           "note" =>
             "body is every byte the listener wrote after the header block" <>
               if(wire["closed"],
                 do: "; the listener closed the connection",
                 else: "; the connection stayed open"
               )
         }
         |> Map.merge(body_fields(body))
         |> derive(nil, nil, status in 200..299)}
      end
    end

    defp request_body(nil), do: %{"body" => nil}

    defp request_body(bytes) do
      if String.valid?(bytes),
        do: %{"body" => bytes},
        else: %{"body" => nil, "body_base64" => Base.encode64(bytes)}
    end

    # -- sim_* -------------------------------------------------------------------

    defp skills do
      for skill <- AshA2A.Info.capability_index(Note) do
        %{id: skill.id, name: to_string(skill.name), consequence: to_string(skill.consequence)}
      end
    end

    defp sim_info(info) do
      %{
        "base_url" => info.base_url,
        "card_url" => info.card_url,
        "jsonrpc_url" => info.jsonrpc_url,
        "a2a_url" => info.a2a_url,
        "rest_url" => info.rest_url,
        "grpc_target" => info.grpc_target,
        "required_a2a_url" => info.required_a2a_url,
        "required_rest_url" => info.required_rest_url,
        "required_grpc_target" => info.required_grpc_target,
        "required_extension" => info.required_extension,
        "push_url" => info.push_url,
        "http_port" => info.http_port,
        "grpc_port" => info.grpc_port,
        "push_port" => info.push_port,
        "a2a_version" => "1.1",
        "tokens" => Map.new(info.tokens, fn {role, token} -> {to_string(role), token} end),
        "skills" =>
          Enum.map(
            skills(),
            &%{"id" => &1.id, "name" => &1.name, "consequence" => &1.consequence}
          )
      }
    end

    defp read_rows(args) do
      all = Ash.read!(Note, authorize?: false)

      rows =
        all
        |> Enum.filter(fn row ->
          (is_nil(args["id"]) or row.id == args["id"]) and
            (is_nil(args["title"]) or row.title == args["title"]) and
            (is_nil(args["title_prefix"]) or String.starts_with?(row.title, args["title_prefix"]))
        end)
        |> Enum.sort_by(& &1.inserted_at, DateTime)
        |> Enum.map(fn row ->
          %{
            "id" => row.id,
            "title" => row.title,
            "body" => row.body,
            "inserted_at" => DateTime.to_iso8601(row.inserted_at),
            "updated_at" => DateTime.to_iso8601(row.updated_at)
          }
        end)

      %{
        "count" => length(rows),
        "total" => length(all),
        "rows" => rows,
        "publications" => Note.publications()
      }
    end

    defp push_deliveries(args) do
      suffix = args["path_suffix"]
      match? = fn delivery -> is_nil(suffix) or String.ends_with?(delivery.path, suffix) end

      if (args["wait_ms"] || 0) > 0, do: PushReceiver.await(match?, args["wait_ms"])

      deliveries =
        for delivery <- PushReceiver.deliveries(), match?.(delivery) do
          text? = String.valid?(delivery.raw)

          %{
            "path" => delivery.path,
            "headers" => delivery.headers,
            "body" => delivery.body,
            "raw" => if(text?, do: delivery.raw),
            "raw_base64" => if(text?, do: nil, else: Base.encode64(delivery.raw))
          }
        end

      if args["reset"] == true, do: PushReceiver.reset()
      %{"count" => length(deliveries), "deliveries" => deliveries}
    end

    defp surface(args) do
      tools = Coverage.tools_by_surface()

      items =
        for item <- Coverage.items(),
            is_nil(args["kind"]) or to_string(item.kind) == args["kind"] do
          %{
            "id" => item.id,
            "kind" => to_string(item.kind),
            "name" => item.name,
            "source" => item.source,
            "tools" => Map.get(tools, item.id, [])
          }
        end

      %{
        "count" => length(items),
        "items" => items,
        "uncovered" => Enum.map(Coverage.uncovered(), & &1.id)
      }
    end

    defp coverage(args) do
      steps? = Map.get(args, "steps", is_binary(args["surface"]))

      items =
        for entry <- Coverage.plan(),
            is_nil(args["surface"]) or entry["surface"] == args["surface"],
            is_nil(args["kind"]) or entry["kind"] == args["kind"] do
          if steps? do
            entry
          else
            entry |> Map.put("step_count", length(entry["steps"])) |> Map.delete("steps")
          end
        end

      %{
        "count" => length(items),
        "items" => items,
        "uncovered" => Enum.map(Coverage.uncovered(), & &1.id)
      }
    end

    defp prove(args, ctx) do
      prefix = args["surface_prefix"]
      only = fn probe -> is_nil(prefix) or String.starts_with?(probe.surface, prefix) end
      results = Prover.run(ctx.info, only: only)

      matrix = %{
        "summary" => results |> Prover.summary() |> Map.new(fn {k, v} -> {to_string(k), v} end),
        "uncovered" => Prover.probes() |> Surface.uncovered() |> Enum.map(& &1.id),
        "results" =>
          Enum.map(results, fn result ->
            %{
              "surface" => result.surface,
              "probe" => result.probe,
              "status" => to_string(result.status),
              "detail" => result.detail
            }
          end)
      }

      :persistent_term.put(@last_matrix, Map.put(matrix, "surface_prefix", prefix))
      matrix
    end

    # The script runs once per server; `fresh: true` runs it again.
    defp parity(args, ctx) do
      key = {__MODULE__, :parity, ctx.info.http_port, ctx.info.grpc_port}

      outcome =
        case {args["fresh"] == true, :persistent_term.get(key, nil)} do
          {false, {:ok, _report} = cached} ->
            cached

          _run ->
            result = Parity.run(ctx.info, timeout: args["timeout_ms"] || 120_000)
            :persistent_term.put(key, result)
            result
        end

      case outcome do
        {:ok, report} -> {:ok, parity_answer(report, args)}
        {:skip, reason} -> {:ok, parity_not_run(reason)}
        {:error, reason} -> {:error, "the parity script failed: " <> reason}
      end
    end

    defp parity_not_run(reason) do
      %{
        "ran" => false,
        "ok" => false,
        "reason" => reason,
        "summary" => %{"pass" => 0, "fail" => 0, "known" => 0, "skip" => 0},
        "known_defects" => [],
        "verdicts" => [],
        "row_count" => 0,
        "rows" => []
      }
    end

    defp parity_answer(report, args) do
      strict? = args["strict"] == true
      binding = args["binding"]
      statuses = args["statuses"] || ["fail", "known"]
      all = Enum.filter(report["rows"], &(is_nil(binding) or &1["binding"] == binding))

      verdicts =
        for name <- Parity.bindings(), is_nil(binding) or name == binding do
          {verdict, detail} = Parity.verdict(report, name)

          verdict =
            case verdict do
              :pass -> "pass"
              :skip -> if strict?, do: "fail", else: "known"
              :fail -> "fail"
            end

          %{"binding" => name, "verdict" => verdict, "detail" => detail}
        end

      rows =
        for row <- all,
            row["status"] in statuses,
            is_nil(args["operation"]) or to_string(row["operation"]) =~ args["operation"] do
          Map.take(row, ~w(binding operation vector check status detail finding))
        end

      %{
        "ran" => true,
        "ok" => verdicts != [] and Enum.all?(verdicts, &(&1["verdict"] != "fail")),
        "strict" => strict?,
        "summary" =>
          Map.new(~w(pass fail known skip), fn status ->
            {status, Enum.count(all, &(&1["status"] == status))}
          end),
        "known_defects" =>
          all |> Enum.map(& &1["finding"]) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
        "verdicts" => verdicts,
        "row_count" => length(all),
        "rows" => rows
      }
    end

    @doc "The matrix of the last `sim_prove` run in this VM, or `nil`."
    @spec last_matrix() :: map() | nil
    def last_matrix, do: :persistent_term.get(@last_matrix, nil)

    defp put_some(map, _key, nil), do: map
    defp put_some(map, key, value), do: Map.put(map, key, value)

    defp unique, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  end
end
