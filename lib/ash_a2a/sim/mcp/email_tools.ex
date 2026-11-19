# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.MCP.EmailTools do
    @moduledoc """
    The MCP tools of the email surface of the simulation server
    (`AshA2A.Sim.Email`), and the coverage plans of its surface items.

    | Tool | What it does |
    |---|---|
    | `sim_email_issue_brief` | Files a brief (two numbered actions pinned to a graph digest) and answers it with the reply tokens, the DKIM facts and the webhook secret |
    | `sim_email_send_reply` | Sends a reply to the email gateway over real HTTP: a canned `scenario` (every outcome of `AshA2A.Sim.Email.outcomes/0`), a reply the tool builds and DKIM-signs, or a signed `raw` message you supply. Answers the status, the body and whether an Ash row changed |
    | `sim_email_deliveries` | The mail the gateway sent (receipt summaries, reconfirm briefs) and the requests it answered |

    `AshA2A.Sim.MCP.Coverage` asks `steps/1` for the plan of every
    `:email_route` and `:email_outcome` item of `AshA2A.Sim.Surface`.
    """

    alias AshA2A.Sim.Email

    @tools ~w(sim_email_issue_brief sim_email_send_reply sim_email_deliveries)

    @doc "The names of the email tools."
    @spec names() :: [String.t()]
    def names, do: @tools

    @doc "The email tools, as MCP `Tool` objects."
    @spec list() :: [map()]
    def list do
      scenarios = Enum.map(Email.outcomes(), & &1.name)
      nullable = fn type -> %{"type" => [type, "null"]} end

      [
        tool(
          "sim_email_issue_brief",
          "Issue an email brief",
          "Files a brief the way the operator would receive it: two numbered actions (`create_note`, `publish_note`) " <>
            "pinned to a graph digest, each with its reply token. Answers the brief, the DKIM key facts the gateway " <>
            "trusts (domain, selector, `p=`), the webhook secret and the ingest URLs. A reply to it goes through " <>
            "`sim_email_send_reply`.",
          %{
            "title" => %{
              "type" => "string",
              "description" => "The title of the notes the actions create (default: generated)."
            },
            "bound" => %{
              "type" => "boolean",
              "default" => true,
              "description" =>
                "Bind the brief to `sim-email-approver`: only that principal may approve it."
            },
            "drift" => %{
              "type" => "boolean",
              "default" => false,
              "description" =>
                "Change the simulated graph under the brief right away, so a reply to it is stale (409)."
            }
          },
          [],
          object(
            %{
              "brief_id" => %{"type" => "string"},
              "message_id" => %{"type" => "string"},
              "subject" => %{"type" => "string"},
              "text" => %{"type" => "string"},
              "title" => %{"type" => "string"},
              "approver" => nullable.("string"),
              "actions" => %{"type" => "array", "items" => %{"type" => "object"}},
              "reply_tokens" => %{"type" => "object"},
              "dkim" => %{"type" => "object"},
              "webhook_secret" => %{"type" => "string"},
              "ingest_urls" => %{"type" => "object"},
              "senders" => %{"type" => "object"},
              "limits" => %{"type" => "object"}
            },
            ["brief_id", "message_id", "actions", "reply_tokens", "dkim", "ingest_urls"]
          )
        ),
        tool(
          "sim_email_send_reply",
          "Send a reply to the email gateway",
          "POSTs to `/v1/email:ingest` of the simulation server over real HTTP. Three ways to say what to send: " <>
            "`scenario` runs a canned outcome end to end (issues its own brief, sends, judges: `as_expected`); " <>
            "`raw` sends a DKIM-signed message you supply; otherwise the tool builds and signs a reply to `brief_id` " <>
            "(rsa-sha256, relaxed/relaxed). `build_only` answers the signed message without sending it. " <>
            "Every answer says whether the Ash note rows or publications changed (`landed`): a refusal must leave them as they were.",
          %{
            "scenario" => %{
              "type" => "string",
              "enum" => scenarios,
              "description" => "Run this canned outcome; the other arguments are ignored."
            },
            "brief_id" => %{
              "type" => "string",
              "description" => "The brief to reply to (from `sim_email_issue_brief`)."
            },
            "text" => %{"type" => "string", "default" => "Approve 1."},
            "from" => %{
              "type" => "string",
              "default" => "approver@sim.example",
              "description" => "The sender (see `senders` of `sim_email_issue_brief`)."
            },
            "message_id" => %{
              "type" => "string",
              "description" =>
                "The reply's Message-ID, without angle brackets. Sending the same id twice is a replay."
            },
            "reply_tokens" => %{
              "type" => "object",
              "description" =>
                "Action number to token. Default: the brief's real tokens (`tokens_mode` `all`)."
            },
            "tokens_mode" => %{
              "type" => "string",
              "enum" => ["all", "none", "forged"],
              "default" => "all"
            },
            "sign" => %{
              "type" => "string",
              "enum" => ["sim", "foreign"],
              "default" => "sim",
              "description" => "`foreign` signs with a key the gateway does not trust."
            },
            "from_domain" => %{
              "type" => "string",
              "description" =>
                "The domain of the From header, when it should differ from the sender."
            },
            "dkim_tags" => %{
              "type" => "string",
              "description" => "Extra DKIM-Signature tag text, for example ` l=5;`."
            },
            "tamper" => %{
              "type" => "string",
              "enum" => ["none", "body_byte"],
              "default" => "none",
              "description" => "`body_byte` flips one byte of the signed message after signing."
            },
            "mount" => %{
              "type" => "string",
              "enum" => ["ses", "workspace"],
              "default" => "ses",
              "description" =>
                "`ses`: DKIM-verified. `workspace`: authenticated with the webhook secret."
            },
            "auth" => %{
              "type" => "string",
              "enum" => ["ok", "wrong", "none"],
              "default" => "ok",
              "description" => "The webhook secret sent to the `workspace` mount."
            },
            "topic" => %{
              "type" => "string",
              "enum" => ["ok", "wrong"],
              "default" => "ok",
              "description" =>
                "`wrong` sends an SNS envelope for another topic to the `ses` mount."
            },
            "raw" => %{
              "type" => "string",
              "description" => "A signed raw message to send as it is (CRLF line ends)."
            },
            "build_only" => %{
              "type" => "boolean",
              "default" => false,
              "description" => "Answer the signed message and the envelope without sending."
            },
            "padding" => %{
              "type" => "integer",
              "minimum" => 0,
              "description" => "Bytes of filler added to the body."
            },
            "nest" => %{
              "type" => "integer",
              "minimum" => 1,
              "description" => "Levels of nesting added to the body."
            },
            "http_method" => %{
              "type" => "string",
              "enum" => ["POST", "GET", "PUT", "DELETE"],
              "default" => "POST",
              "description" => "Any method but POST is sent with an empty body."
            }
          },
          [],
          object(
            %{
              "mode" => %{"type" => "string", "enum" => ["scenario", "send", "build", "method"]},
              "scenario" => nullable.("string"),
              "status" => nullable.("integer"),
              "headers" => %{"type" => "object"},
              "body" => nullable.("string"),
              "json" => %{},
              "landed" => %{"type" => ["boolean", "null"]},
              "added" => %{"type" => "array", "items" => %{"type" => "string"}},
              "rows_before" => nullable.("integer"),
              "rows_after" => nullable.("integer"),
              "publications_before" => nullable.("integer"),
              "publications_after" => nullable.("integer"),
              "message_id" => nullable.("string"),
              "raw" => nullable.("string"),
              "envelope" => %{},
              "expected" => %{"type" => ["object", "null"]},
              "as_expected" => %{"type" => ["boolean", "null"]},
              "verdict" => nullable.("string"),
              "detail" => %{"type" => ["object", "null"]}
            },
            ["mode"]
          )
        ),
        tool(
          "sim_email_deliveries",
          "Read the gateway's mail",
          "The mail the email gateway sent (receipt summaries and reconfirm briefs; a reconfirm mail carries the " <>
            "refreshed brief that can be approved) and every request it answered (mount, path, status).",
          %{
            "reset" => %{
              "type" => "boolean",
              "default" => false,
              "description" => "Forget everything recorded, after reading."
            }
          },
          [],
          object(
            %{
              "count" => %{"type" => "integer"},
              "deliveries" => %{"type" => "array", "items" => %{"type" => "object"}},
              "attempts" => %{"type" => "array", "items" => %{"type" => "object"}}
            },
            ["count", "deliveries", "attempts"]
          )
        )
      ]
    end

    # == running ==================================================================

    @doc false
    @spec run(String.t(), map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run("sim_email_issue_brief", args, ctx) do
      brief = Email.issue_brief(title: args["title"], bound: Map.get(args, "bound", true))
      if args["drift"] == true, do: Email.drift(brief["brief_id"])
      facts = Email.facts()

      {:ok,
       brief
       |> Map.merge(Map.take(facts, ["dkim", "webhook_secret", "senders", "limits"]))
       |> Map.put("ingest_urls", %{
         "ses" => Email.url(ctx.info, :ses),
         "workspace" => Email.url(ctx.info, :workspace)
       })}
    end

    def run("sim_email_deliveries", args, _ctx) do
      %{deliveries: deliveries, attempts: attempts} = Email.deliveries()
      if args["reset"] == true, do: Email.reset_deliveries()
      {:ok, %{"count" => length(deliveries), "deliveries" => deliveries, "attempts" => attempts}}
    end

    def run("sim_email_send_reply", %{"scenario" => name}, ctx) do
      result = Email.run(ctx.info, name)
      spec = Email.outcome(name)

      {as_expected, verdict} =
        case Email.evaluate(name, result) do
          {:ok, detail} -> {true, detail}
          {:error, why} -> {false, why}
        end

      {:ok,
       result
       |> reply_fields("scenario")
       |> Map.merge(%{
         "scenario" => name,
         "expected" => %{
           "status" => spec.status,
           "landed" => spec.landed,
           "error" => spec[:error]
         },
         "as_expected" => as_expected,
         "verdict" => verdict,
         "detail" => detail(result)
       })}
    end

    def run("sim_email_send_reply", %{"http_method" => method} = args, ctx)
        when method != "POST" do
      resp =
        Email.post(ctx.info, "",
          method: method |> String.downcase() |> String.to_existing_atom(),
          mount: mount(args)
        )

      {:ok,
       %{
         "mode" => "method",
         "status" => resp.status,
         "headers" => resp.headers,
         "body" => resp.raw,
         "json" => resp.json,
         "landed" => false,
         "added" => []
       }}
    end

    def run("sim_email_send_reply", args, ctx) do
      brief =
        case args["brief_id"] do
          nil -> nil
          id -> Email.brief(id)
        end

      cond do
        is_binary(args["brief_id"]) and is_nil(brief) ->
          {:error, "no brief #{args["brief_id"]}; issue one with sim_email_issue_brief"}

        is_nil(brief) and is_nil(args["raw"]) ->
          {:error, "give a scenario, a brief_id, or a raw signed message"}

        args["build_only"] == true ->
          built = Email.build_reply(brief, opts(args, brief))

          {:ok,
           %{
             "mode" => "build",
             "raw" => built.raw,
             "message_id" => built.message_id,
             "envelope" => built.envelope
           }}

        true ->
          result = Email.send_reply(ctx.info, brief, opts(args, brief))
          {:ok, reply_fields(result, "send")}
      end
    end

    defp opts(args, _brief) do
      [
        from: args["from"],
        text: args["text"],
        message_id: args["message_id"],
        sign: atom(args["sign"], %{"sim" => :sim, "foreign" => :foreign}),
        from_domain: args["from_domain"],
        dkim_tags: args["dkim_tags"],
        tamper: atom(args["tamper"], %{"body_byte" => :body_byte}),
        topic: atom(args["topic"], %{"wrong" => :wrong}),
        mount: mount(args),
        auth: atom(args["auth"], %{"wrong" => :wrong, "none" => :none}),
        raw: args["raw"],
        padding: args["padding"],
        nest: args["nest"],
        tokens: tokens(args)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    end

    defp mount(%{"mount" => "workspace"}), do: :workspace
    defp mount(_args), do: :ses

    defp atom(nil, _table), do: nil
    defp atom(key, table), do: Map.get(table, key)

    defp tokens(%{"reply_tokens" => %{} = given}) do
      Map.new(given, fn {n, token} -> {String.to_integer(n), token} end)
    end

    defp tokens(%{"tokens_mode" => "none"}), do: :none
    defp tokens(%{"tokens_mode" => "forged"}), do: :forged
    defp tokens(_args), do: nil

    defp reply_fields(result, mode) do
      %{
        "mode" => mode,
        "status" => result.status,
        "headers" => result.headers,
        "body" => result.raw_body,
        "json" => result.json,
        "landed" => result.landed,
        "added" => result.added,
        "rows_before" => result.rows_before,
        "rows_after" => result.rows_after,
        "publications_before" => result.publications_before,
        "publications_after" => result.publications_after,
        "message_id" => result.message_id,
        "raw" => result.signed_raw
      }
    end

    # Extra observations of the outcomes that take more than one request.
    defp detail(result) do
      %{}
      |> put("first", result[:first] && Map.take(result.first, [:status, :landed, :added]))
      |> put("variants", result[:variants])
      |> put("statuses", result[:statuses])
      |> put("reconfirm_mail", result[:reconfirm_mail])
      |> put(
        "reconfirm_approved",
        result[:reconfirm_approved] &&
          Map.take(result.reconfirm_approved, [:status, :landed, :added])
      )
      |> json_safe()
    end

    defp put(map, _key, nil), do: map
    defp put(map, key, value), do: Map.put(map, key, value)

    defp json_safe(value) do
      value |> Jason.encode!() |> Jason.decode!()
    end

    # == coverage =================================================================

    @doc """
    The coverage plan steps of an `:email_route` or `:email_outcome` surface
    item (see `AshA2A.Sim.MCP.Coverage`).
    """
    @spec steps(map()) :: [map()]
    def steps(%{kind: :email_outcome, name: name}) do
      spec = Email.outcome(name)

      expect =
        [
          ex("status", "eq", spec.status),
          ex("landed", "eq", spec.landed),
          ex("as_expected", "eq", true)
        ] ++
          if(spec[:error], do: [ex("json.error", "eq", spec.error)], else: [])

      mail =
        case name do
          "approved_reply_dispatched" ->
            [
              step("the gateway mailed the receipt summary", "sim_email_deliveries", %{},
                expect: [
                  ex("deliveries", "contains", "Receipt summary"),
                  ex("deliveries", "contains", "1: dispatched")
                ]
              )
            ]

          "held_reply_dispatches_nothing" ->
            [
              step("the receipt summary says held", "sim_email_deliveries", %{},
                expect: [ex("deliveries", "contains", "1: held")]
              )
            ]

          "stale_graph_digest_refused" ->
            [
              step("the gateway mailed a reconfirm brief", "sim_email_deliveries", %{},
                expect: [
                  ex("deliveries.0.subject", "eq", "Reconfirm required"),
                  ex("deliveries.0.reconfirm_brief.brief_id", "exists")
                ]
              )
            ]

          _ ->
            []
        end

      reset =
        if mail == [],
          do: [],
          else: [
            step("forget earlier mail", "sim_email_deliveries", %{"reset" => true})
          ]

      reset ++
        [
          step("run the outcome over the wire", "sim_email_send_reply", %{"scenario" => name},
            tested: true,
            expect: expect
          )
        ] ++ mail
    end

    def steps(%{kind: :email_route, name: "POST /email/v1/email:ingest"}) do
      issue = issue_step()

      [
        issue,
        step(
          "build and DKIM-sign the reply without sending it",
          "sim_email_send_reply",
          %{"brief_id" => "{{brief_id}}", "build_only" => true},
          capture: %{"signed_raw" => "raw", "reply_message_id" => "message_id"},
          expect: [ex("mode", "eq", "build"), ex("raw", "contains", "DKIM-Signature")]
        ),
        step(
          "POST the signed message to /email/v1/email:ingest",
          "sim_email_send_reply",
          %{"brief_id" => "{{brief_id}}", "raw" => "{{signed_raw}}"},
          tested: true,
          expect: [
            ex("status", "eq", 200),
            ex("landed", "eq", true),
            ex("json.results.0.standing", "eq", "dispatched")
          ]
        ),
        step("the Ash row exists", "sim_read_rows", %{"title" => "{{title}}"},
          expect: [ex("count", "eq", 1)]
        )
      ]
    end

    def steps(%{kind: :email_route, name: "POST /email-workspace/v1/email:ingest"}) do
      [
        issue_step(),
        step(
          "a wrong webhook secret is refused 401",
          "sim_email_send_reply",
          %{"brief_id" => "{{brief_id}}", "mount" => "workspace", "auth" => "wrong"},
          expect: [ex("status", "eq", 401), ex("landed", "eq", false)]
        ),
        step(
          "POST with the webhook secret to /email-workspace/v1/email:ingest",
          "sim_email_send_reply",
          %{"brief_id" => "{{brief_id}}", "mount" => "workspace"},
          tested: true,
          expect: [
            ex("status", "eq", 200),
            ex("landed", "eq", true),
            ex("json.results.0.standing", "eq", "dispatched")
          ]
        ),
        step("the Ash row exists", "sim_read_rows", %{"title" => "{{title}}"},
          expect: [ex("count", "eq", 1)]
        )
      ]
    end

    def steps(%{kind: :email_route, name: "GET /email/v1/email:ingest"}) do
      [
        step(
          "GET is refused 405 with allow: POST",
          "sim_email_send_reply",
          %{"http_method" => "GET"},
          tested: true,
          expect: [
            ex("status", "eq", 405),
            ex("headers.allow", "eq", "POST"),
            ex("landed", "eq", false)
          ]
        )
      ]
    end

    def steps(_item), do: []

    defp issue_step do
      step(
        "issue a brief",
        "sim_email_issue_brief",
        %{"title" => "sim-email-mcp-{{uniq}}"},
        capture: %{"brief_id" => "brief_id", "title" => "title"},
        expect: [ex("actions.0.reply_token", "exists"), ex("dkim.domain", "eq", "sim.example")]
      )
    end

    defp step(label, tool, arguments, opts \\ []) do
      %{"label" => label, "tool" => tool, "arguments" => arguments}
      |> put_opt("tested", opts[:tested])
      |> put_opt("capture", opts[:capture])
      |> put_opt("expect", opts[:expect])
    end

    defp put_opt(map, _key, nil), do: map
    defp put_opt(map, key, value), do: Map.put(map, key, value)

    defp ex(path, op, value \\ nil), do: %{"path" => path, "op" => op, "value" => value}

    # -- schema helpers -----------------------------------------------------------

    defp tool(name, title, description, props, required, output) do
      %{
        "name" => name,
        "title" => title,
        "description" => description,
        "inputSchema" => props |> object(required) |> Map.put("additionalProperties", false),
        "outputSchema" => output
      }
    end

    defp object(props, required),
      do: %{"type" => "object", "properties" => props, "required" => required}
  end
end
