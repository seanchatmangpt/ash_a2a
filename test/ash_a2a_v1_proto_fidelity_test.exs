defmodule AshA2A.V1ProtoFidelityTest do
  @moduledoc """
  Z16 — a2a.proto schema-fidelity court.

  Pins that the codec's wire vocabulary (`AshA2A.Protocol.JSON`) IS the
  official A2A v1 proto's protojson mapping, judged against the REAL vendored
  IDL: `priv/a2a_v1_spec_corpus/a2a.proto` (kept pristine; provenance here).

  ## Provenance of the vendored IDL

  - Source URL:
    https://raw.githubusercontent.com/a2aproject/A2A/main/specification/a2a.proto
    (the `specification/gRPC/a2a.proto` path named in the lane contract 404s;
    the GitHub tree listing resolves the official IDL at
    `specification/a2a.proto`)
  - Fetched from a2aproject/A2A `main` @ `fe182ee3c053d2e6a3ad2576c959fa5f7d8b5d07`
  - Last commit touching `specification/a2a.proto`:
    `cfc9d34bc41e368827eb6446d31f912e44f795c5` (2026-07-21T16:48:19Z)
  - Vendored verbatim, byte-for-byte, no edits. `syntax = "proto3"`,
    `package lf.a2a.v1`, service `A2AService` with 11 RPCs.

  ## Method

  A lightweight regex IDL parser (no protoc) parses the vendored file at test
  time into messages (fields + oneofs), enums, and services. REAL codec encode
  outputs (`AshA2A.Protocol.JSON.encode*/encode_agent_card/
  encode_stream_response`) are compared against the parsed IDL:

  - (a) every wire member a real encode emits must be the lowerCamelCase
    rendering of a real field of the corresponding proto message — divergent
    keys must match the pinned-findings ledger EXACTLY (no unpinned drift,
    no stale pins);
  - (b) `TaskState`/`Role` enum spellings: our `TASK_STATE_*`/`ROLE_*` strings
    vs the proto enum values, both directions, divergences pinned;
  - (c) the `A2AService` RPC list must equal the dispatch mapping surface
    (`AshA2A.Transport.Grpc.Dispatch.methods/0`), streaming flags included,
    and each RPC's internal JSON-RPC path must be present in
    `lib/ash_a2a/protocol/jsonrpc.ex`;
  - (d) role enum fidelity (`ROLE_USER`/`ROLE_AGENT`).

  Falsifier: green (all matched) or green-with-pinned-findings. Any NEW
  drift — an emitted key or enum value not in the proto and not pinned —
  fails the court with both sides in the failure message.
  """

  use ExUnit.Case, async: true

  @proto_path Path.join(__DIR__, "../priv/a2a_v1_spec_corpus/a2a.proto")
  @jsonrpc_path Path.join(__DIR__, "../lib/ash_a2a/protocol/jsonrpc.ex")

  # ------------------------------------------------------------------
  # Lightweight proto IDL parser (no protoc)
  # ------------------------------------------------------------------

  defmodule IDL do
    @moduledoc false

    @field_re ~r/^\s*(?:(repeated|optional)\s+)?((?:map\s*<[^>]+>)|(?:[[:alnum:]_.]+))\s+(\w+)\s*=\s*(\d+)\s*(?:\[[^\]]*\])?\s*;/
    @rpc_re ~r/\brpc\s+(\w+)\s*\(([\w.]*)\)\s*returns\s*\(\s*(stream\s+)?([\w.]*)\s*\)/

    def parse(src) do
      src = strip_comments(src)

      %{
        messages:
          src
          |> blocks("message")
          |> Map.new(fn {n, b} -> {n, %{fields: fields(b), oneofs: oneofs(b)}} end),
        enums: src |> blocks("enum") |> Map.new(fn {n, b} -> {n, enum_values(b)} end),
        services: src |> blocks("service") |> Map.new(fn {n, b} -> {n, rpcs(b)} end)
      }
    end

    def strip_comments(src), do: String.replace(src, ~r{//[^\n]*}, "")

    # Finds every `kind Name {` header and brace-matches each block body.
    defp blocks(src, kind, acc \\ []) do
      header = Regex.compile!("\\b#{kind}\\s+(\\w+)\\s*\\{")

      case Regex.run(header, src, return: :index) do
        [{start, len}, {name_start, name_len}] ->
          open = start + len - 1
          rest = binary_part(src, open, byte_size(src) - open)
          close = matching_brace(rest, 0)
          body = binary_part(rest, 1, close - 1)
          name = binary_part(src, name_start, name_len)
          tail = close + 1
          blocks(binary_part(rest, tail, byte_size(rest) - tail), kind, [{name, body} | acc])

        nil ->
          Enum.reverse(acc)
      end
    end

    # `bin` starts at the open brace; returns the index of its match.
    defp matching_brace(bin, idx, depth \\ 0) do
      case binary_part(bin, idx, 1) do
        "{" ->
          matching_brace(bin, idx + 1, depth + 1)

        "}" when depth == 1 ->
          idx

        "}" ->
          matching_brace(bin, idx + 1, depth - 1)

        _other ->
          matching_brace(bin, idx + 1, depth)
      end
    end

    defp fields(body) do
      body
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(@field_re, line) do
          [_, label, type, name, num] ->
            [{name, %{label: label || "", type: type, number: String.to_integer(num)}}]

          nil ->
            []
        end
      end)
      |> Map.new()
    end

    # Single-level oneofs (true of this IDL). Oneof members are also message
    # fields, so `fields/1` already keeps them; this records the grouping.
    defp oneofs(body, acc \\ %{}) do
      case Regex.run(~r/\boneof\s+(\w+)\s*\{/, body, return: :index) do
        [{start, len}, {name_start, name_len}] ->
          open = start + len - 1
          from_open = binary_part(body, open, byte_size(body) - open)
          close = matching_brace(from_open, 0)
          inner = binary_part(from_open, 1, close - 1)

          members =
            inner
            |> String.split("\n")
            |> Enum.flat_map(fn line ->
              case Regex.run(@field_re, line) do
                [_, _label, _type, name, _num] -> [name]
                nil -> []
              end
            end)

          name = binary_part(body, name_start, name_len)
          tail = close + 1
          remaining = binary_part(from_open, tail, byte_size(from_open) - tail)
          oneofs(remaining, Map.put(acc, name, members))

        nil ->
          acc
      end
    end

    defp enum_values(body) do
      body
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\s*(\w+)\s*=\s*(-?\d+)\s*;/, line) do
          [_, name, num] -> [{name, String.to_integer(num)}]
          nil -> []
        end
      end)
      |> Map.new()
    end

    defp rpcs(body) do
      body
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(@rpc_re, line) do
          [_, name, req, stream, resp] ->
            [{name, %{request: req, streaming: stream not in [nil, ""], response: resp}}]

          nil ->
            []
        end
      end)
      |> Map.new()
    end
  end

  # ------------------------------------------------------------------
  # Pinned findings ledger (green-with-findings). Each entry carries BOTH
  # sides: the proto-side member and our emitted-side member(s). The court
  # requires the OBSERVED divergences per surface to equal the pinned ones
  # exactly — an unpinned divergence fails, and so does a stale pin (the
  # finding must be retired when lib/ is fixed).
  # ------------------------------------------------------------------

  @pinned_findings [
    %{
      id: "Z16-F5",
      kind: :legacy_surface,
      proto_side:
        "Part oneof content {text, raw, url, data} + filename + mediaType (flat v1 shape)",
      our_side_keys: ["name", "mimeType", "uri", "bytes"],
      why:
        "The standalone encode of %AshA2A.Protocol.FileContent{} emits the v0.3 " <>
          "nested-file shape. The v1 wire path for file parts is the flat Part " <>
          "oneof (raw/url/mediaType/filename), which the %Part.File{} encoder " <>
          "uses; the standalone FileContent encode is legacy v0.3 mirror surface, " <>
          "not part of the v1 wire vocabulary."
    }
  ]

  # Findings this court OBSERVED against the pre-fix codec and that were fixed
  # in lib/ (Z16-F2 by the codec lane while Z16 was running; Z16-F1/F3/F4 by
  # lane Z27). Kept here as the both-sides record; a regression re-emits the
  # old key/value and the (a)/(b) courts fail — the retirement is not a pass.
  @retired_findings [
    %{
      id: "Z16-F2",
      proto_side: "AgentCard.security_requirements -> \"securityRequirements\"",
      fixed_side: "AgentCard emits \"securityRequirements\" (was v0.3 \"security\")"
    },
    %{
      id: "Z16-F1",
      proto_side: "TaskState.TASK_STATE_UNSPECIFIED (proto3 zero value, value 0)",
      fixed_side:
        "the indeterminate state (:unknown) emits TASK_STATE_UNSPECIFIED; " <>
          "TASK_STATE_UNKNOWN is never emitted (decode still accepts it → :unknown)"
    },
    %{
      id: "Z16-F3",
      proto_side:
        "AgentCapabilities {streaming, pushNotifications, extensions, extendedAgentCard} — no state_transition_history",
      fixed_side: "AgentCapabilities no longer emits \"stateTransitionHistory\""
    },
    %{
      id: "Z16-F4",
      proto_side: "APIKeySecurityScheme.location (\"query\"/\"header\"/\"cookie\")",
      fixed_side: "APIKeySecurityScheme emits \"location\" (was v0.3 \"in\"); struct key stays :in"
    }
  ]

  defp pinned_keys do
    MapSet.new(Enum.flat_map(@pinned_findings, & &1.our_side_keys))
  end

  # ------------------------------------------------------------------
  # Fixtures — REAL codec outputs (Chicago: the actual encoder under test)
  # ------------------------------------------------------------------

  alias AshA2A.Protocol.{
    AgentExtension,
    Artifact,
    Event,
    FileContent,
    JSON,
    Message,
    Part,
    PushNotificationConfig,
    Task
  }

  defp status(state \\ :working) do
    %Task.Status{state: state, message: nil, timestamp: ~U[2026-10-04T00:00:00Z]}
  end

  defp part_text, do: %Part.Text{text: "hello", metadata: %{"k" => "v"}}
  defp part_data, do: %Part.Data{data: %{"x" => 1}, metadata: %{}}

  defp part_file do
    %Part.File{
      file: %FileContent{
        name: "doc.pdf",
        mime_type: "application/pdf",
        uri: "https://example.com/doc.pdf",
        bytes: <<1, 2, 3>>
      },
      metadata: %{"p" => "q"}
    }
  end

  defp message_user do
    %Message{
      message_id: "m1",
      role: :user,
      parts: [part_text()],
      task_id: "t1",
      context_id: "c1",
      reference_task_ids: ["t0"],
      metadata: %{"mk" => "mv"}
    }
  end

  defp message_agent do
    %Message{
      message_id: "m2",
      role: :agent,
      parts: [part_text(), part_file(), part_data()],
      context_id: "c1"
    }
  end

  defp artifact do
    %Artifact{
      artifact_id: "a1",
      name: "out",
      description: "an output",
      parts: [part_text()],
      extensions: ["https://ext.example"],
      metadata: %{"a" => "b"}
    }
  end

  defp push_config do
    %PushNotificationConfig{
      id: "p1",
      task_id: "t1",
      url: "https://hook.example",
      token: "tok",
      authentication: %{scheme: "Bearer", credentials: "creds"}
    }
  end

  defp agent_extension do
    %AgentExtension{
      uri: "https://ext.example",
      description: "uses the extension",
      required: true,
      params: %{"x" => 1}
    }
  end

  defp card do
    %AshA2A.Protocol.AgentCard{
      name: "Agent",
      description: "A test agent",
      url: "https://agent.example",
      version: "1.0.0",
      documentation_url: "https://docs.example",
      icon_url: "https://icon.example",
      provider: %{organization: "Org", url: "https://org.example"},
      skills: [
        %{
          id: "s1",
          name: "Skill",
          description: "Does things",
          tags: ["t"],
          input_modes: ["text/plain"],
          output_modes: ["text/plain"]
        }
      ],
      capabilities: %{
        streaming: true,
        push_notifications: true,
        state_transition_history: true,
        extended_agent_card: true,
        extensions: [agent_extension()]
      },
      default_input_modes: ["text/plain"],
      default_output_modes: ["application/json"],
      supported_interfaces: [
        %{url: "https://agent.example", protocol_binding: "JSONRPC", protocol_version: "1.0"}
      ],
      security_schemes: %{
        "api_key" => %AshA2A.Protocol.SecurityScheme.APIKey{name: "X-Api-Key", in: "header"},
        "http" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "Bearer"},
        "oauth2" => %AshA2A.Protocol.SecurityScheme.OAuth2{
          flows: %{"authorizationCode" => %{"tokenUrl" => "https://tok"}},
          oauth2_metadata_url: "https://meta.example"
        },
        "oidc" => %AshA2A.Protocol.SecurityScheme.OpenIDConnect{
          open_id_connect_url: "https://oidc.example"
        },
        "mtls" => %AshA2A.Protocol.SecurityScheme.MutualTLS{}
      },
      security: [%{"api_key" => ["scope1"]}],
      signatures: [%{"protected" => "p", "signature" => "s", "header" => %{}}]
    }
  end

  defp encoded_card do
    JSON.encode_agent_card(card(), url: "https://agent.example")
  end

  # ------------------------------------------------------------------
  # Court helpers
  # ------------------------------------------------------------------

  defp idl, do: @proto_path |> File.read!() |> IDL.parse()

  defp camel(snake) do
    [first | rest] = String.split(snake, "_")
    Enum.join([String.downcase(first) | Enum.map(rest, &String.capitalize/1)])
  end

  defp proto_camel_fields(idl, message) do
    idl.messages
    |> Map.fetch!(message)
    |> Map.fetch!(:fields)
    |> Map.keys()
    |> Enum.map(&camel/1)
    |> MapSet.new()
  end

  defp proto_oneof_members(idl, message, oneof) do
    idl.messages
    |> Map.fetch!(message)
    |> Map.fetch!(:oneofs)
    |> Map.fetch!(oneof)
    |> Enum.map(&camel/1)
    |> MapSet.new()
  end

  # ------------------------------------------------------------------
  # Court — every surface's observed divergence set (emitted keys that are
  # NOT lowerCamelCase renderings of real proto fields) must be a subset of
  # the pinned ledger, and across all surfaces EQUAL to it (no unpinned
  # drift, no stale pin).
  # ------------------------------------------------------------------

  defp encoded_surfaces do
    task =
      JSON.encode!(%Task{
        id: "t1",
        context_id: "c1",
        status: %{status() | message: message_user()},
        history: [message_agent()],
        artifacts: [artifact()],
        metadata: %{"m" => "v"}
      })

    card = encoded_card()

    [
      {"Task", task},
      {"TaskStatus", task["status"]},
      {"Message", JSON.encode!(message_user())},
      {"Artifact", JSON.encode!(artifact())},
      {"Part", JSON.encode!(part_text())},
      {"Part", JSON.encode!(part_data())},
      {"Part", JSON.encode!(part_file())},
      {"TaskStatusUpdateEvent", JSON.encode!(status_update())},
      {"TaskArtifactUpdateEvent", JSON.encode!(artifact_update())},
      {"TaskPushNotificationConfig", JSON.encode!(push_config())},
      {"AuthenticationInfo", JSON.encode!(push_config())["authentication"]},
      {"AgentExtension", JSON.encode_agent_extension(agent_extension())},
      {"AgentCard", card},
      {"AgentSkill", hd(card["skills"])},
      {"AgentCapabilities", card["capabilities"]},
      {"AgentInterface", hd(card["supportedInterfaces"])},
      {"AgentProvider", card["provider"]},
      {"AgentCardSignature", hd(card["signatures"])},
      {"APIKeySecurityScheme", card["securitySchemes"]["api_key"]["apiKeySecurityScheme"]},
      {"HTTPAuthSecurityScheme", card["securitySchemes"]["http"]["httpAuthSecurityScheme"]},
      {"OAuth2SecurityScheme", card["securitySchemes"]["oauth2"]["oauth2SecurityScheme"]},
      {"OpenIdConnectSecurityScheme", card["securitySchemes"]["oidc"]["openIdConnectSecurityScheme"]},
      {"MutualTlsSecurityScheme", card["securitySchemes"]["mtls"]["mtlsSecurityScheme"]}
    ]
  end

  defp status_update do
    %Event.StatusUpdate{
      task_id: "t1",
      context_id: "c1",
      status: status(),
      final: true,
      metadata: %{"s" => "t"}
    }
  end

  defp artifact_update do
    %Event.ArtifactUpdate{
      task_id: "t1",
      context_id: "c1",
      artifact: artifact(),
      append: true,
      last_chunk: false,
      metadata: %{"u" => "v"}
    }
  end

  # ------------------------------------------------------------------
  # Tests
  # ------------------------------------------------------------------

  @moduletag :z16

  describe "vendored proto corpus" do
    @describetag :z16
    test "is the official proto3 lf.a2a.v1 IDL and parses completely" do
      src = File.read!(@proto_path)
      assert src =~ ~s(syntax = "proto3";)
      assert src =~ ~s(package lf.a2a.v1;)

      parsed = idl()

      for msg <- [
            "Task",
            "Message",
            "Part",
            "TaskStatus",
            "Artifact",
            "AgentCard",
            "AgentSkill",
            "TaskStatusUpdateEvent",
            "TaskArtifactUpdateEvent",
            "StreamResponse",
            "SendMessageResponse",
            "AgentExtension",
            "TaskPushNotificationConfig",
            "AuthenticationInfo",
            "AgentCapabilities",
            "AgentInterface",
            "AgentProvider",
            "AgentCardSignature",
            "SecurityScheme",
            "OAuthFlows",
            "ListTasksResponse"
          ] do
        assert Map.has_key?(parsed.messages, msg), "missing proto message #{msg}"
      end

      assert map_size(parsed.enums["TaskState"]) == 9
      assert map_size(parsed.enums["Role"]) == 3
      assert map_size(parsed.services["A2AService"]) == 11

      # Parser sanity: real field numbers come out of the real IDL.
      assert parsed.messages["Task"].fields["id"].number == 1
      assert parsed.messages["Task"].fields["context_id"].number == 2
      assert parsed.messages["Task"].fields["status"].number == 3

      # lowerCamelCase rendering sanity — the mapping the court compares with.
      assert MapSet.equal?(
               proto_camel_fields(parsed, "Task"),
               MapSet.new(~w(id contextId status artifacts history metadata))
             )

      assert MapSet.equal?(
               proto_camel_fields(parsed, "TaskStatusUpdateEvent"),
               MapSet.new(~w(taskId contextId status metadata))
             )

      assert MapSet.equal?(
               proto_camel_fields(parsed, "AgentCard"),
               MapSet.new(
                 ~w(name description supportedInterfaces provider version documentationUrl capabilities securitySchemes securityRequirements defaultInputModes defaultOutputModes skills signatures iconUrl)
               )
             )
    end
  end

  describe "(a) message field fidelity" do
    @describetag :z16

    test "every emitted wire member is a proto field; divergences equal the pinned ledger exactly" do
      parsed = idl()
      observed_all = MapSet.new()
      unexpected_all = []

      {observed_all, unexpected_all} =
        Enum.reduce(encoded_surfaces(), {observed_all, unexpected_all}, fn {message, wire},
                                                                           {obs_acc, unp_acc} ->
          proto = proto_camel_fields(parsed, message)

          observed =
            wire
            |> Map.keys()
            |> MapSet.new()
            |> MapSet.difference(proto)

          unexpected = MapSet.difference(observed, pinned_keys())

          unp_acc =
            if MapSet.size(unexpected) > 0 do
              [
                "Z16 FINDING (unpinned) on proto message #{message}: emitted wire members " <>
                  "#{inspect(MapSet.to_list(unexpected))} are not fields of the proto message " <>
                  "(proto camelCase fields: #{inspect(MapSet.to_list(proto))})"
                | unp_acc
              ]
            else
              unp_acc
            end

          {MapSet.union(obs_acc, observed), unp_acc}
        end)

      assert unexpected_all == [],
             "Z16 unpinned findings:\n" <> Enum.join(Enum.reverse(unexpected_all), "\n")

      field_pins =
        @pinned_findings
        |> Enum.filter(&(&1.kind == :field_name))
        |> Enum.flat_map(& &1.our_side_keys)
        |> MapSet.new()

      assert MapSet.equal?(observed_all, field_pins),
             "Z16 ledger drift: observed divergences " <>
               "#{inspect(MapSet.to_list(observed_all))} != pinned field findings " <>
               "#{inspect(MapSet.to_list(field_pins))} — either lib/ was fixed without " <>
               "retiring a pin, or a divergence is missing from the ledger"
    end

    test "positive spot checks: emitted key sets equal the proto renderings" do
      parsed = idl()
      surfaces = encoded_surfaces()

      task_surface =
        surfaces |> Enum.find(fn {m, _} -> m == "Task" end) |> elem(1)

      # Task: exact set equality with the proto's camelCase renderings.
      assert MapSet.equal?(
               MapSet.new(Map.keys(task_surface)),
               proto_camel_fields(parsed, "Task")
             )

      # Part surfaces: every flat oneof member and descriptor is a Part field.
      for {message, wire} <- surfaces, message == "Part" do
        assert MapSet.subset?(MapSet.new(Map.keys(wire)), proto_camel_fields(parsed, "Part"))
      end

      # A flat file part emits exactly the v1 Part oneof members + descriptors.
      file_part = JSON.encode!(part_file())

      assert MapSet.equal?(
               MapSet.new(Map.keys(file_part)),
               MapSet.new(~w(filename mediaType url raw metadata))
             )
    end
  end

  describe "(a2) StreamResponse / SendMessageResponse oneof fidelity" do
    @describetag :z16

    test "encode_stream_response wrapper keys == the proto oneof members, both directions" do
      parsed = idl()

      oneof = proto_oneof_members(parsed, "StreamResponse", "payload")

      assert MapSet.equal?(oneof, MapSet.new(~w(task message statusUpdate artifactUpdate)))

      {:ok, w_task} = JSON.encode_stream_response(%Task{id: "t1", status: status()})
      {:ok, w_msg} = JSON.encode_stream_response(message_agent())
      {:ok, w_status} = JSON.encode_stream_response(status_update())
      {:ok, w_artifact} = JSON.encode_stream_response(artifact_update())

      emitted =
        [w_task, w_msg, w_status, w_artifact]
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()

      assert MapSet.equal?(emitted, oneof)

      # SendMessageResponse's payload oneof uses the same task/message members.
      assert MapSet.subset?(
               proto_oneof_members(parsed, "SendMessageResponse", "payload"),
               emitted
             )
    end

    test "SecurityScheme oneof wrapper keys == the proto oneof members exactly" do
      parsed = idl()

      assert MapSet.equal?(
               proto_oneof_members(parsed, "SecurityScheme", "scheme"),
               MapSet.new(~w(apiKeySecurityScheme httpAuthSecurityScheme oauth2SecurityScheme openIdConnectSecurityScheme mtlsSecurityScheme))
             )

      schemes = encoded_card()["securitySchemes"]

      emitted_wrappers =
        schemes |> Map.values() |> Enum.flat_map(&Map.keys/1) |> MapSet.new()

      assert MapSet.equal?(
               emitted_wrappers,
               proto_oneof_members(parsed, "SecurityScheme", "scheme")
             )
    end

    test "OAuthFlows oneof: emitted flow keys are proto oneof members" do
      parsed = idl()

      flows_oneof = proto_oneof_members(parsed, "OAuthFlows", "flow")

      assert MapSet.equal?(
               flows_oneof,
               MapSet.new(~w(authorizationCode clientCredentials implicit password deviceCode))
             )

      oauth2 = encoded_card()["securitySchemes"]["oauth2"]["oauth2SecurityScheme"]

      for flow_key <- Map.keys(oauth2["flows"]) do
        assert flow_key in flows_oneof
      end
    end
  end

  describe "(b) TaskState enum fidelity" do
    @describetag :z16

    test "our TASK_STATE_* strings == the proto enum exactly, both directions" do
      parsed = idl()

      proto =
        parsed.enums["TaskState"]
        |> Map.keys()
        |> MapSet.new()

      ours =
        JSON.valid_state_strings()
        |> MapSet.new()

      emitted_not_in_proto = MapSet.difference(ours, proto)
      proto_not_emitted = MapSet.difference(proto, ours)

      # Z16-F1 retired (MATCH): the emitted vocabulary IS the proto enum.
      # The indeterminate state emits the proto3 zero value
      # TASK_STATE_UNSPECIFIED; TASK_STATE_UNKNOWN is no longer emitted. Any
      # regression re-emits it and fails here (stale-pin-kills holds).
      assert MapSet.equal?(emitted_not_in_proto, MapSet.new()),
             "Z16-F1 regression: emitted-but-not-in-proto states " <>
               "#{inspect(MapSet.to_list(emitted_not_in_proto))} (proto TaskState values: " <>
               "#{inspect(MapSet.to_list(proto))})"

      assert MapSet.equal?(proto_not_emitted, MapSet.new()),
             "Z16-F1 regression: proto TaskState values we do not produce " <>
               "#{inspect(MapSet.to_list(proto_not_emitted))} — every proto value must be produced"
    end
  end

  describe "(d) Role enum fidelity" do
    @describetag :z16

    test "emitted ROLE_* values are proto Role values; only ROLE_UNSPECIFIED is unproduced" do
      parsed = idl()

      proto =
        parsed.enums["Role"]
        |> Map.keys()
        |> MapSet.new()

      user_role = JSON.encode!(message_user())["role"]
      agent_role = JSON.encode!(message_agent())["role"]

      assert user_role == "ROLE_USER"
      assert agent_role == "ROLE_AGENT"

      assert MapSet.subset?(MapSet.new([user_role, agent_role]), proto)

      assert MapSet.equal?(
               MapSet.difference(proto, MapSet.new([user_role, agent_role])),
               MapSet.new(["ROLE_UNSPECIFIED"])
             )
    end
  end

  describe "(c) A2AService RPC surface vs dispatch mapping" do
    @describetag :z16

    test "proto RPC list == Dispatch.methods names, streaming flags, JSON-RPC paths" do
      parsed = idl()
      rpcs = parsed.services["A2AService"]

      assert map_size(rpcs) == 11

      dispatch = AshA2A.Transport.Grpc.Dispatch.methods()

      assert MapSet.new(Map.keys(rpcs)) == MapSet.new(Enum.map(dispatch, & &1.name)),
             "Z16: proto A2AService RPCs #{inspect(Map.keys(rpcs) |> Enum.sort())} != " <>
               "dispatch names #{inspect(Enum.map(dispatch, & &1.name) |> Enum.sort())}"

      jsonrpc_src = File.read!(@jsonrpc_path)

      for m <- dispatch do
        assert rpcs[m.name].streaming == m.streaming,
               "Z16: streaming flag mismatch for #{m.name} " <>
                 "(proto: #{rpcs[m.name].streaming}, dispatch: #{m.streaming})"

        assert jsonrpc_src =~ m.internal,
               "Z16: RPC #{m.name} internal path #{inspect(m.internal)} is not handled " <>
                 "anywhere in lib/ash_a2a/protocol/jsonrpc.ex"
      end
    end
  end

  describe "pinned findings ledger" do
    @describetag :z16

    test "Z16-F5: legacy FileContent encode emits exactly the pinned v0.3 nested-file shape" do
      # The standalone %FileContent{} encode is the one surface whose keys are
      # NOT proto v1 Part fields (see Z16-F5); pin its exact shape here so any
      # drift on it fails too.
      legacy =
        JSON.encode!(%FileContent{
          name: "f.txt",
          mime_type: "text/plain",
          bytes: <<1>>,
          uri: "https://example.com/f.txt"
        })

      f5 = Enum.find(@pinned_findings, &(&1.id == "Z16-F5"))

      assert MapSet.equal?(
               MapSet.new(Map.keys(legacy)),
               MapSet.new(f5.our_side_keys)
             )
    end

    test "every finding carries both sides and an explanation" do
      assert length(@pinned_findings) == 1
      assert length(@retired_findings) == 4

      for finding <- @pinned_findings do
        assert is_binary(finding.id)
        assert finding.id =~ ~r/^Z16-F\d$/
        assert is_binary(finding.proto_side) and finding.proto_side != ""
        assert finding.our_side_keys != []
        assert is_binary(finding.why) and finding.why != ""
      end

      for retired <- @retired_findings do
        assert is_binary(retired.id)
        assert is_binary(retired.proto_side) and retired.proto_side != ""
        assert is_binary(retired.fixed_side) and retired.fixed_side != ""
      end
    end
  end
end
