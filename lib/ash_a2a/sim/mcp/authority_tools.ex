# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.MCP.AuthorityTools do
    @moduledoc """
    The MCP side of the authority surface of the simulation server
    (`AshA2A.Sim.Authority`): the tools that change and read the state the
    mutating skills depend on, and the coverage plans of the `:authority`
    surface items.

    | Tool | What it does |
    |---|---|
    | `sim_grant_authority` | files, renews or re-issues a standing grant: `identity` or `principal` (any principal value), `skill` or `capability` (any capability id), `expires_in_seconds` (negative for a grant that has already run out; on a standing grant it renews in place), `force` (grant again although one stands, to see `token_id_taken`) |
    | `sim_revoke_authority` | revokes a standing grant, for the same `identity`/`principal` and `skill`/`capability` |
    | `sim_trip_kill_switch` | trips the simulation's kill switch class (`AshA2A.KillSwitch.trip/3`): every `:change` and `:external_do` skill is refused until reset |
    | `sim_reset_kill_switch` | resets the class with the simulation operator's reset authority (`AshA2A.KillSwitch.reset/4`) |
    | `sim_receipts` | reads the receipt `AshA2A.CommandBus` committed for a message id and verifies its binding |
    """

    alias AshA2A.Authority.Grant
    alias AshA2A.Sim.{Auth, Authority, Note}

    @completed "TASK_STATE_COMPLETED"
    @rejected "TASK_STATE_REJECTED"
    @failed "TASK_STATE_FAILED"
    @jr "jsonrpc"
    @rest "http_json"
    @grpc "grpc"
    @agent "sim-agent-{{uniq}}"

    # == catalog ================================================================

    @doc "The tools of this module, as MCP `Tool` objects."
    @spec list() :: [map()]
    def list do
      class = %{
        "class" => %{
          "type" => "string",
          "default" => Authority.kill_switch_class(),
          "description" =>
            "The class to act on. The simulation's class is #{inspect(Authority.kill_switch_class())}; " <>
              "tripping any class makes it the host's `:kill_switch_class`, which every consequence-bearing skill consults."
        }
      }

      [
        tool(
          "sim_trip_kill_switch",
          "Trip the kill switch",
          "Trips a kill switch class (`AshA2A.KillSwitch.trip/3`, no authority needed) and makes it the host's " <>
            "`:kill_switch_class`, so `AshA2A.CommandBus` refuses every `:change` and `:external_do` skill with " <>
            "`kill_switch_tripped` on all three bindings. `:observe` skills still run. `sim_reset_kill_switch` undoes it.",
          Map.put(class, "reason", %{
            "type" => "string",
            "description" => "The recorded reason.",
            "default" => "sim_trip_kill_switch"
          }),
          kill_output()
        ),
        tool(
          "sim_reset_kill_switch",
          "Reset the kill switch",
          "Resets a kill switch class with a reset authority minted for the simulation operator " <>
            "(`AshA2A.KillSwitch.reset/4`), and puts the host's previous `:kill_switch_class` back.",
          class,
          kill_output()
        ),
        tool(
          "sim_receipts",
          "Read a receipt",
          "Reads the receipt `AshA2A.CommandBus` committed for the command whose id is `message_id` (the " <>
            "`messageId` of the wire call) and verifies its binding (`AshA2A.Receipt.Binding`). A performed " <>
            "`:change` or `:external_do` skill commits one; an `:observe` skill, and a refusal before the command " <>
            "is claimed (`authority_required`, `kill_switch_tripped`), commit none.",
          %{
            "message_id" => %{
              "type" => "string",
              "description" => "The `messageId` the call was sent with."
            }
          },
          receipts_output(),
          ["message_id"]
        )
      ]
    end

    @doc "The input properties of `sim_grant_authority`: `base` plus the grant options."
    @spec grant_props(map()) :: map()
    def grant_props(base) do
      base
      |> Map.merge(selector_props())
      |> Map.merge(%{
        "expires_in_seconds" => %{
          "type" => "integer",
          "description" =>
            "Give the grant a time bound this many seconds from now; a negative value is a grant that has " <>
              "already run out. On a standing grant it renews the bound in place (`AshA2A.Authority.Grant.renew/3`); " <>
              "an expired grant cannot be renewed."
        },
        "force" => %{
          "type" => "boolean",
          "default" => false,
          "description" =>
            "Grant again although the grant stands: the broker refuses with `token_id_taken` (see `refusal`)."
        }
      })
    end

    @doc "The input properties of `sim_revoke_authority`: `base` plus the selectors."
    @spec revoke_props(map()) :: map()
    def revoke_props(base), do: Map.merge(base, selector_props())

    defp selector_props do
      %{
        "principal" => %{
          "type" => "string",
          "description" =>
            "Act on this principal value instead of an identity's, for example `someone-else`. " <>
              "A principal that no token authenticates as holds a grant nobody can present."
        },
        "capability" => %{
          "type" => "string",
          "description" =>
            "Act on this capability id instead of a skill's, for example `Some.Other.capability`: a grant " <>
              "for a capability the skill being called does not have."
        }
      }
    end

    @doc "`output` (the grants result) with the members the grant options add."
    @spec grants_output(map()) :: map()
    def grants_output(output) do
      update_in(output, ["properties", "grants", "items", "properties"], fn props ->
        props
        |> Map.put("expires_at", %{"type" => ["string", "null"]})
        |> Map.put("refusal", %{"type" => ["string", "null"]})
      end)
    end

    # == running ================================================================

    @doc "Runs one of this module's tools. Answers `{:ok, structured}` or `{:error, text}`."
    @spec run(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
    def run("sim_trip_kill_switch", args) do
      class = Map.get(args, "class", Authority.kill_switch_class())
      :ok = Authority.trip_kill_switch(class, Map.get(args, "reason", "sim_trip_kill_switch"))
      {:ok, kill_state(class, "tripped")}
    end

    def run("sim_reset_kill_switch", args) do
      class = Map.get(args, "class", Authority.kill_switch_class())

      case Authority.reset_kill_switch(class) do
        :ok -> {:ok, kill_state(class, "reset")}
        {:error, reason} -> {:ok, kill_state(class, "refused: #{inspect(reason)}")}
      end
    end

    def run("sim_receipts", %{"message_id" => id}) do
      case Authority.fetch_receipt(id) do
        {:ok, receipt} ->
          {:ok, %{"found" => true, "message_id" => id, "receipt" => Authority.describe_receipt(receipt)}}

        :error ->
          {:ok, %{"found" => false, "message_id" => id, "receipt" => nil}}
      end
    end

    defp kill_state(class, outcome) do
      {tripped, reason} =
        case Authority.kill_switch_state(class) do
          {true, reason} -> {true, to_string(reason)}
          false -> {false, nil}
        end

      %{
        "class" => class,
        "outcome" => outcome,
        "tripped" => tripped,
        "reason" => reason,
        "configured_class" =>
          case Application.get_env(:ash_a2a, :kill_switch_class) do
            nil -> nil
            configured -> to_string(configured)
          end
      }
    end

    @doc """
    Files (`:grant`) or revokes (`:revoke`) standing grants for
    `sim_grant_authority` and `sim_revoke_authority`.
    """
    @spec grant(map(), :grant | :revoke) :: {:ok, map()} | {:error, String.t()}
    def grant(args, action) do
      role = Map.get(args, "identity", "writer")

      case subject(args, role) do
        nil ->
          {:error,
           "no identity #{inspect(role)}: use writer, reader, unscoped or a sim-agent-<name> token"}

        subject ->
          case selected(args) do
            [] ->
              wanted = Map.get(args, "skill", "all")

              {:error,
               "no skill named #{inspect(wanted)}; skills are #{Enum.map_join(skills(), ", ", & &1.name)}"}

            chosen ->
              grants = for skill <- chosen, do: change(subject, skill, action, args)
              {:ok, %{"identity" => role, "principal" => subject.value, "grants" => grants}}
          end
      end
    end

    defp subject(%{"principal" => value}, _role) when is_binary(value),
      do: AshA2A.Identity.principal(value)

    defp subject(_args, role) do
      tokens = Map.new(Auth.tokens(), fn {name, token} -> {to_string(name), token} end)
      Auth.principal(Map.get(tokens, role, role))
    end

    defp selected(%{"capability" => capability}) when is_binary(capability),
      do: [%{name: capability, id: capability, consequence: "change"}]

    defp selected(args) do
      case Map.get(args, "skill", "all") do
        "all" -> Enum.filter(skills(), &(&1.consequence in ["change", "external_do"]))
        one -> Enum.filter(skills(), &(&1.name == one or &1.id == one))
      end
    end

    defp change(subject, skill, action, args) do
      expires = expires_at(args)
      issue_opts = if expires, do: [expires_at: expires], else: []
      force? = Map.get(args, "force", false)

      {outcome, refusal} =
        case {action, Grant.granted?(subject, skill.id)} do
          {:grant, true} when force? ->
            subject |> Grant.grant(skill.id, issue_opts) |> outcome("granted")

          {:grant, true} when not is_nil(expires) ->
            subject |> Grant.renew(skill.id, issue_opts) |> outcome("renewed")

          {:grant, true} ->
            {"already granted", nil}

          {:grant, false} ->
            subject |> Grant.grant(skill.id, issue_opts) |> outcome("granted")

          {:revoke, false} ->
            {"not granted", nil}

          {:revoke, true} ->
            subject |> Grant.revoke(skill.id) |> outcome("revoked")
        end

      %{
        "skill" => skill.name,
        "capability_id" => skill.id,
        "granted" => Grant.granted?(subject, skill.id),
        "outcome" => outcome,
        "expires_at" => standing_expiry(subject, skill.id),
        "refusal" => refusal
      }
    end

    defp expires_at(%{"expires_in_seconds" => seconds}) when is_integer(seconds),
      do: DateTime.add(DateTime.utc_now(), seconds, :second)

    defp expires_at(_args), do: nil

    defp standing_expiry(subject, capability_id) do
      with {:ok, grants} <- Grant.list_grants(subject),
           %{expires_at: %DateTime{} = at} <- Enum.find(grants, &(&1.capability_id == capability_id)) do
        DateTime.to_iso8601(at)
      else
        _ -> nil
      end
    end

    defp outcome({:ok, _authority}, done), do: {done, nil}
    defp outcome(:ok, done), do: {done, nil}

    defp outcome({:error, refusal}, _done),
      do: {"refused: #{inspect(refusal)}", refusal |> Map.get(:reason) |> to_string()}

    defp skills do
      for skill <- AshA2A.Info.capability_index(Note) do
        %{id: skill.id, name: to_string(skill.name), consequence: to_string(skill.consequence)}
      end
    end

    # == output schemas =========================================================

    defp kill_output do
      object(
        %{
          "class" => %{"type" => "string"},
          "outcome" => %{"type" => "string"},
          "tripped" => %{"type" => "boolean"},
          "reason" => %{"type" => ["string", "null"]},
          "configured_class" => %{"type" => ["string", "null"]}
        },
        ["class", "outcome", "tripped", "reason", "configured_class"]
      )
    end

    defp receipts_output do
      object(
        %{
          "found" => %{"type" => "boolean"},
          "message_id" => %{"type" => "string"},
          "receipt" =>
            Map.put(
              object(
                %{
                  "receipt_id" => %{"type" => "string"},
                  "command_id" => %{"type" => "string"},
                  "capability_id" => %{"type" => "string"},
                  "principal_id" => %{"type" => "string"},
                  "consequence" => %{"type" => "string"},
                  "status" => %{"type" => "string"},
                  "terminal_status" => %{"type" => ["string", "null"]},
                  "standing" => %{"type" => "string"},
                  "binding_verified" => %{"type" => "boolean"},
                  "binding_code" => %{"type" => ["string", "null"]},
                  "binding_links" => %{"type" => "integer"}
                },
                [
                  "capability_id",
                  "consequence",
                  "status",
                  "terminal_status",
                  "binding_verified"
                ]
              ),
              "type",
              ["object", "null"]
            )
        },
        ["found", "message_id", "receipt"]
      )
    end

    defp tool(name, title, description, props, output, required \\ []) do
      %{
        "name" => name,
        "title" => title,
        "description" => description,
        "inputSchema" =>
          props
          |> object(required)
          |> Map.put("additionalProperties", false),
        "outputSchema" => output
      }
    end

    defp object(props, required),
      do: %{"type" => "object", "properties" => props, "required" => required}

    # == coverage plans =========================================================

    @doc """
    The coverage steps of the `:authority` surface item `name`
    (`AshA2A.Sim.MCP.Coverage` runs them through `tools/call`).
    """
    @spec steps(String.t()) :: [map()]
    def steps("grant") do
      [
        grant_step("issue the standing grant", @agent, "create_note",
          tested: true,
          expect: [ex("grants.0.outcome", "eq", "granted"), ex("grants.0.granted", "eq", true)]
        ),
        send_ok("granted: JSON-RPC", @jr, "create_note", "mcp-auth-grant-{{uniq}}-1"),
        send_ok("granted: HTTP+JSON", @rest, "create_note", "mcp-auth-grant-{{uniq}}-2"),
        send_ok("granted: gRPC", @grpc, "create_note", "mcp-auth-grant-{{uniq}}-3"),
        rows("each binding wrote a row", %{"title_prefix" => "mcp-auth-grant-{{uniq}}"}, [
          ex("count", "eq", 3)
        ])
      ]
    end

    def steps("revoke") do
      [
        grant_step("issue the standing grant", @agent, "create_note", []),
        send_ok("granted", @jr, "create_note", "mcp-auth-revoke-{{uniq}}-ok"),
        step("revoke the grant", "sim_revoke_authority", %{"identity" => @agent, "skill" => "create_note"},
          tested: true,
          expect: [ex("grants.0.outcome", "eq", "revoked"), ex("grants.0.granted", "eq", false)]
        ),
        send_refused("revoked: JSON-RPC", @jr, "create_note", "mcp-auth-revoke-{{uniq}}-1"),
        send_refused("revoked: HTTP+JSON", @rest, "create_note", "mcp-auth-revoke-{{uniq}}-2"),
        send_refused("revoked: gRPC", @grpc, "create_note", "mcp-auth-revoke-{{uniq}}-3"),
        rows("only the granted call wrote a row", %{"title_prefix" => "mcp-auth-revoke-{{uniq}}"}, [
          ex("count", "eq", 1)
        ])
      ]
    end

    def steps("verify"), do: [prove("authority:verify", 2)]

    def steps("token_id_taken") do
      [
        grant_step("issue the standing grant", @agent, "create_note", []),
        step(
          "grant again while it stands",
          "sim_grant_authority",
          %{"identity" => @agent, "skill" => "create_note", "force" => true},
          tested: true,
          expect: [
            ex("grants.0.refusal", "eq", "token_id_taken"),
            ex("grants.0.granted", "eq", true)
          ]
        ),
        prove("authority:token_id_taken", 2)
      ]
    end

    def steps("expiry") do
      [
        step(
          "grant with a bound an hour out",
          "sim_grant_authority",
          %{"identity" => @agent, "skill" => "create_note", "expires_in_seconds" => 3600},
          expect: [ex("grants.0.granted", "eq", true), ex("grants.0.expires_at", "exists")]
        ),
        send_ok("inside the bound", @rest, "create_note", "mcp-auth-expiry-{{uniq}}-ok"),
        step(
          "renew the bound into the past",
          "sim_grant_authority",
          %{"identity" => @agent, "skill" => "create_note", "expires_in_seconds" => -60},
          expect: [ex("grants.0.outcome", "eq", "renewed"), ex("grants.0.granted", "eq", false)]
        ),
        send_refused("past the bound", @jr, "create_note", "mcp-auth-expiry-{{uniq}}-1", tested: true),
        step(
          "an expired grant cannot be renewed back",
          "sim_grant_authority",
          %{"identity" => @agent, "skill" => "create_note", "expires_in_seconds" => 3600},
          expect: [ex("grants.0.refusal", "eq", "grant_not_standing"), ex("grants.0.granted", "eq", false)]
        ),
        send_refused("still refused", @grpc, "create_note", "mcp-auth-expiry-{{uniq}}-2"),
        rows("only the call inside the bound wrote a row", %{"title_prefix" => "mcp-auth-expiry-{{uniq}}"}, [
          ex("count", "eq", 1)
        ])
      ]
    end

    def steps("reissue_after_revoke") do
      [
        grant_step("issue the standing grant", @agent, "create_note", []),
        step("revoke the grant", "sim_revoke_authority", %{"identity" => @agent, "skill" => "create_note"},
          expect: [ex("grants.0.granted", "eq", false)]
        ),
        send_refused("refused while revoked", @jr, "create_note", "mcp-auth-reissue-{{uniq}}-0"),
        grant_step("issue the revoked grant again", @agent, "create_note",
          tested: true,
          expect: [ex("grants.0.outcome", "eq", "granted"), ex("grants.0.granted", "eq", true)]
        ),
        send_ok("re-granted: JSON-RPC", @jr, "create_note", "mcp-auth-reissue-{{uniq}}-1"),
        send_ok("re-granted: HTTP+JSON", @rest, "create_note", "mcp-auth-reissue-{{uniq}}-2"),
        send_ok("re-granted: gRPC", @grpc, "create_note", "mcp-auth-reissue-{{uniq}}-3"),
        prove("authority:reissue_after_revoke", 2)
      ]
    end

    def steps("principal_scope") do
      holder = "sim-agent-holder-{{uniq}}"
      other = "sim-agent-other-{{uniq}}"

      [
        grant_step("grant the holder", holder, "create_note", []),
        send_refused("another principal is refused", @jr, "create_note", "mcp-auth-principal-{{uniq}}-0",
          token: other,
          tested: true
        ),
        send_ok("the holder is admitted", @jr, "create_note", "mcp-auth-principal-{{uniq}}-1", token: holder),
        send_refused("another principal over gRPC", @grpc, "create_note", "mcp-auth-principal-{{uniq}}-2",
          token: other
        ),
        rows("only the holder wrote", %{"title_prefix" => "mcp-auth-principal-{{uniq}}"}, [
          ex("count", "eq", 1)
        ])
      ]
    end

    def steps("capability_scope") do
      [
        step(
          "grant publish_note to a principal named directly",
          "sim_grant_authority",
          %{"principal" => @agent, "skill" => "publish_note"},
          expect: [ex("principal", "eq", @agent), ex("grants.0.granted", "eq", true)]
        ),
        send_refused("create_note is not covered", @jr, "create_note", "mcp-auth-capability-{{uniq}}-0",
          tested: true
        ),
        send_ok("publish_note is", @rest, "publish_note", "mcp-auth-capability-{{uniq}}-1"),
        step(
          "grant a capability the skills do not have",
          "sim_grant_authority",
          %{"principal" => @agent, "capability" => "Some.Other.capability"},
          expect: [
            ex("grants.0.capability_id", "eq", "Some.Other.capability"),
            ex("grants.0.granted", "eq", true)
          ]
        ),
        send_refused("create_note is still not covered", @grpc, "create_note", "mcp-auth-capability-{{uniq}}-2"),
        rows("only the publication happened", %{"title" => "none"}, [
          ex("publications", "contains", "mcp-auth-capability-{{uniq}}-1"),
          ex("publications", "not_contains", "mcp-auth-capability-{{uniq}}-0")
        ])
      ]
    end

    def steps("presenter_binding"), do: [prove("authority:presenter_binding", 2)]

    def steps("authority_required") do
      [
        send_refused("no grant: JSON-RPC", @jr, "create_note", "mcp-auth-required-{{uniq}}-1", tested: true),
        send_refused("no grant: HTTP+JSON", @rest, "create_note", "mcp-auth-required-{{uniq}}-2"),
        send_refused("no grant: gRPC", @grpc, "create_note", "mcp-auth-required-{{uniq}}-3"),
        rows("nothing was written", %{"title_prefix" => "mcp-auth-required-{{uniq}}"}, [
          ex("count", "eq", 0)
        ])
      ]
    end

    def steps("kill_switch") do
      blocked = fn label, binding, skill, title, opts ->
        step(
          label,
          "a2a_send_message",
          %{"binding" => binding, "skill" => skill, "data" => %{"title" => title}, "token" => @agent},
          tested: opts[:tested],
          expect: [
            ex("ok", "eq", true),
            ex("state", "in", [@rejected, @failed]),
            ex("task", "contains", "kill_switch_tripped")
          ]
        )
      end

      [
        grant_step("grant create_note", @agent, "create_note", []),
        grant_step("grant publish_note", @agent, "publish_note", []),
        step("trip the kill switch", "sim_trip_kill_switch", %{"reason" => "mcp coverage"},
          expect: [ex("tripped", "eq", true), ex("reason", "eq", "mcp coverage")]
        ),
        blocked.("tripped: create_note over JSON-RPC", @jr, "create_note", "mcp-auth-kill-{{uniq}}-1", tested: true),
        blocked.("tripped: create_note over HTTP+JSON", @rest, "create_note", "mcp-auth-kill-{{uniq}}-2", []),
        blocked.("tripped: create_note over gRPC", @grpc, "create_note", "mcp-auth-kill-{{uniq}}-3", []),
        blocked.("tripped: publish_note over gRPC", @grpc, "publish_note", "mcp-auth-kill-{{uniq}}-4", []),
        step(
          "an observe skill still runs",
          "a2a_send_message",
          %{"binding" => @rest, "skill" => "count_notes", "token" => @agent},
          expect: state(@completed)
        ),
        rows("nothing was written or published", %{"title_prefix" => "mcp-auth-kill-{{uniq}}"}, [
          ex("count", "eq", 0),
          ex("publications", "not_contains", "mcp-auth-kill-{{uniq}}")
        ]),
        step("reset the kill switch", "sim_reset_kill_switch", %{},
          always: true,
          expect: [ex("tripped", "eq", false), ex("outcome", "eq", "reset")]
        ),
        send_ok("reset: JSON-RPC", @jr, "create_note", "mcp-auth-kill-{{uniq}}-5"),
        send_ok("reset: HTTP+JSON", @rest, "create_note", "mcp-auth-kill-{{uniq}}-6"),
        send_ok("reset: gRPC", @grpc, "create_note", "mcp-auth-kill-{{uniq}}-7"),
        rows("the resumed calls wrote", %{"title_prefix" => "mcp-auth-kill-{{uniq}}"}, [
          ex("count", "eq", 3)
        ])
      ]
    end

    def steps("kill_switch_reset") do
      [
        step("trip the kill switch", "sim_trip_kill_switch", %{}, expect: [ex("tripped", "eq", true)]),
        step("reset with the operator's authority", "sim_reset_kill_switch", %{},
          always: true,
          tested: true,
          expect: [ex("tripped", "eq", false), ex("outcome", "eq", "reset")]
        ),
        prove("authority:kill_switch_reset", 1)
      ]
    end

    def steps("two_port_gate:" <> _ = name), do: [prove("authority:" <> name, 1)]

    def steps("receipt_executed") do
      message = "msg-mcp-receipt-{{uniq}}"

      [
        grant_step("grant create_note", @agent, "create_note", []),
        send_ok("perform the effect", @jr, "create_note", "mcp-auth-receipt-{{uniq}}", message_id: message),
        step("read the receipt back", "sim_receipts", %{"message_id" => message},
          tested: true,
          expect: [
            ex("found", "eq", true),
            ex("receipt.consequence", "eq", "change"),
            ex("receipt.terminal_status", "eq", "executed"),
            ex("receipt.binding_verified", "eq", true)
          ]
        )
      ]
    end

    def steps("receipt_refused"), do: [prove("authority:receipt_refused", 1)]

    def steps("outcome:observe:admitted") do
      message = "msg-mcp-observe-{{uniq}}"

      [
        step(
          "an observe skill runs for a caller with no grant",
          "a2a_send_message",
          %{"binding" => @grpc, "skill" => "count_notes", "token" => @agent, "message_id" => message},
          tested: true,
          expect: state(@completed)
        ),
        step("it committed no receipt", "sim_receipts", %{"message_id" => message},
          expect: [ex("found", "eq", false)]
        )
      ]
    end

    def steps("outcome:change:admitted") do
      message = "msg-mcp-change-{{uniq}}"

      [
        grant_step("grant create_note", @agent, "create_note", []),
        send_ok("the change is admitted", @rest, "create_note", "mcp-auth-change-{{uniq}}",
          message_id: message,
          tested: true
        ),
        rows("the row exists", %{"title" => "mcp-auth-change-{{uniq}}"}, [ex("count", "eq", 1)]),
        step("its receipt is a verifying change receipt", "sim_receipts", %{"message_id" => message},
          expect: [
            ex("receipt.consequence", "eq", "change"),
            ex("receipt.binding_verified", "eq", true)
          ]
        )
      ]
    end

    def steps("outcome:change:refused") do
      [
        send_refused("a change without a grant", @grpc, "create_note", "mcp-auth-change-refused-{{uniq}}",
          tested: true
        ),
        rows("nothing was written", %{"title" => "mcp-auth-change-refused-{{uniq}}"}, [
          ex("count", "eq", 0)
        ])
      ]
    end

    def steps("outcome:external_do:admitted") do
      message = "msg-mcp-external-{{uniq}}"

      [
        grant_step("grant publish_note", @agent, "publish_note", []),
        send_ok("the external effect is admitted", @grpc, "publish_note", "mcp-auth-external-{{uniq}}",
          message_id: message,
          tested: true
        ),
        rows("the effect was recorded", %{"title" => "none"}, [
          ex("publications", "contains", "mcp-auth-external-{{uniq}}")
        ]),
        step("its receipt is a verifying external_do receipt", "sim_receipts", %{"message_id" => message},
          expect: [
            ex("receipt.consequence", "eq", "external_do"),
            ex("receipt.binding_verified", "eq", true)
          ]
        )
      ]
    end

    def steps("outcome:external_do:refused") do
      [
        send_refused(
          "an external effect without a grant",
          @rest,
          "publish_note",
          "mcp-auth-external-refused-{{uniq}}",
          tested: true
        ),
        rows("nothing was recorded", %{"title" => "none"}, [
          ex("publications", "not_contains", "mcp-auth-external-refused-{{uniq}}")
        ])
      ]
    end

    def steps("outcome:unknown:refused") do
      [
        grant_step("grant the unclassified skill anyway", @agent, "unclassified_note", []),
        step(
          "an unknown-consequence skill is refused despite the grant",
          "a2a_send_message",
          %{"binding" => @jr, "skill" => "unclassified_note", "token" => @agent},
          tested: true,
          expect: state(@rejected) ++ [ex("task", "contains", "consequence_unclassified")]
        )
      ]
    end

    def steps(_name), do: []

    # -- step builders ----------------------------------------------------------

    defp step(label, tool, arguments, opts) do
      %{"label" => label, "tool" => tool, "arguments" => arguments}
      |> put_opt("tested", opts[:tested])
      |> put_opt("expect", opts[:expect])
      |> put_opt("always", opts[:always])
    end

    defp put_opt(map, _key, nil), do: map
    defp put_opt(map, key, value), do: Map.put(map, key, value)

    defp ex(path, op, value \\ nil), do: %{"path" => path, "op" => op, "value" => value}

    defp state(expected), do: [ex("ok", "eq", true), ex("state", "eq", expected)]

    defp grant_step(label, agent, skill, opts) do
      step(
        label,
        "sim_grant_authority",
        %{"identity" => agent, "skill" => skill},
        Keyword.put_new(opts, :expect, [ex("grants.0.granted", "eq", true)])
      )
    end

    defp rows(label, args, expect), do: step(label, "sim_read_rows", args, expect: expect)

    defp send_skill(label, binding, skill, title, expect, opts) do
      arguments =
        %{
          "binding" => binding,
          "skill" => skill,
          "data" => %{"title" => title},
          "token" => Keyword.get(opts, :token, @agent)
        }
        |> put_opt("message_id", opts[:message_id])

      step(label, "a2a_send_message", arguments, tested: opts[:tested], expect: expect)
    end

    defp send_ok(label, binding, skill, title, opts \\ []),
      do: send_skill(label, binding, skill, title, state(@completed), opts)

    defp send_refused(label, binding, skill, title, opts \\ []),
      do:
        send_skill(
          label,
          binding,
          skill,
          title,
          state(@rejected) ++ [ex("task", "contains", "authority_required")],
          opts
        )

    # The probes of an item that has no wire tool of its own (broker internals,
    # the lease gate) run through the prover, which is itself an MCP tool.
    defp prove(prefix, at_least) do
      step("run the probes of #{prefix}", "sim_prove", %{"surface_prefix" => prefix},
        tested: true,
        expect: [ex("summary.fail", "eq", 0), ex("summary.skip", "eq", 0), ex("summary.pass", "gte", at_least)]
      )
    end
  end
end
