defmodule AshA2A.V1PbFidelityTest do
  @moduledoc """
  Lane X14 — pb-descriptor fidelity court (closes X8's drift exposure).

  X8 (`ash_a2a_v1_proto_fidelity_test.exs`) courts the codec against the
  vendored IDL (`priv/a2a_v1_spec_corpus/a2a.proto`) — but nothing courts the
  *generated* pb projection (`lib/ash_a2a/transport/grpc/pb/lf/a2a/v1/
  a2a.pb.ex`, never hand-edited) against the codec. Two exposures follow:

    1. `Protobuf.JSON.decode!/2` FAILS OPEN on unknown camelCase keys: a
       codec-emitted key the pb projection does not know is silently dropped
       at the gRPC bridge (`AshA2A.Transport.GRPC.Server.to_params/1`), so a
       codec/pb drift would lose fields on the wire with no error anywhere.
    2. A pb regeneration that adds/renames fields changes the descriptor
       silently; if the codec cannot emit a pb json_name, that field is dead
       on the gRPC binding until someone notices.

  ## The three-way court

  Three independent sources of wire vocabulary, cross-checked pairwise per
  message row:

    * W1 codec — the keys a REAL encode emits (`AshA2A.Protocol.JSON.encode/
      encode_stream_response/encode_agent_card` on populated samples);
    * W2 pb — the json_names extracted at test time from the generated
      descriptors (`Lf.A2a.V1.*.__message_props__().field_props`, protobuf
      0.17 introspection surface);
    * W3 corpus — the vendored spec IDL parsed at test time (field names
      lowerCamelCased; `[(google.api.field_behavior) = REQUIRED]` fields
      pinned as the TCK-required surface).

  Assertions per row (see `run_court/0` for the emitted table):

    a. W1 ⊆ W2 — every codec-emitted key exists as a pb json_name (the
       fail-open direction: an unknown key would be silently dropped);
    b. W2 − W1 == pinned ledger — every pb json_name the codec cannot emit
       is enumerated and pinned (`@pb_only_ledger`), so pb regen drift
       changes the delta and fails the court;
    c. W3-required ⊆ W1 — every TCK-required field is codec-emittable;
    d. W3-required ⊆ W2 — the descriptors carry every TCK-required field;
    e. W1 ⊆ W3-vocab — codec vocabulary stays inside the spec IDL's.

  ## Mutation witness

  The comparison MECHANISM is exercised directly: a copy of the real `Task`
  descriptor field map with one json_name renamed (`contextId` →
  `contextIdX`) must be flagged as drift by the comparator; a copy with an
  extra pb-only key must likewise flag. The court is green only because the
  real descriptors pass — not because the comparator is vacuous.

  ## Protobuf.JSON round-trip

  For a sample instance per message: pb message → `Protobuf.JSON.encode!` →
  our codec `decode/2` → equivalent codec struct. **Fail-open edge, pinned:**
  the round-trip only VALUE-asserts the fields listed in each row's
  `value_asserts/0`; every other field's survival is guaranteed solely by
  assertions (a)/(b) above (the key-level court), not by value checks. The
  pinned lists below are exactly the fields whose wire values the tests
  value-assert.

  Falsifier: court green + mutation witness flags the mutation. Any new
  codec key not in the descriptors, or any descriptor change moving the
  pb-only delta off its pin, fails the court.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.JSON

  alias AshA2A.Protocol.{
    AgentCard,
    AgentExtension,
    Artifact,
    Event,
    Message,
    Part,
    PushNotificationConfig,
    Task
  }

  alias Lf.A2a.V1, as: Pb

  @proto_path Path.join(__DIR__, "../priv/a2a_v1_spec_corpus/a2a.proto")

  # ------------------------------------------------------------------
  # Comparator — the pure mechanism under test
  # ------------------------------------------------------------------

  defmodule Comparator do
    @moduledoc false

    # Pure three-way comparison, fed field maps as input so the mutation
    # witness can drive it directly. `required` is a MapSet of wire keys the
    # spec corpus pins as REQUIRED. Returns the drift triad.
    @spec compare(MapSet.t(), MapSet.t(), MapSet.t()) :: %{
            missing: [String.t()],
            added: [String.t()],
            required_missing: [String.t()]
          }
    def compare(codec_keys, pb_names, required \\ MapSet.new()) do
      %{
        missing: MapSet.difference(codec_keys, pb_names) |> Enum.sort(),
        added: MapSet.difference(pb_names, codec_keys) |> Enum.sort(),
        required_missing: MapSet.difference(required, codec_keys) |> Enum.sort()
      }
    end
  end

  # ------------------------------------------------------------------
  # W2 — json_name maps from the generated pb descriptors
  # ------------------------------------------------------------------

  @spec pb_names(module()) :: MapSet.t(String.t())
  defp pb_names(mod) do
    mod.__message_props__().field_props
    |> Map.new(fn {_fnum, %Protobuf.FieldProps{} = prop} -> {prop.json_name, true} end)
    |> MapSet.new(Map.keys())
  end

  # ------------------------------------------------------------------
  # W3 — spec corpus: vocabulary + REQUIRED pins parsed from the IDL
  # ------------------------------------------------------------------

  defmodule Corpus do
    @moduledoc false

    @field_re ~r/^\s*(?:(repeated|optional)\s+)?((?:map\s*<[^>]+>)|(?:[[:alnum:]_.]+))\s+(\w+)\s*=\s*(\d+)\s*(?:\[([^\]]*)\])?\s*;/

    # %{message_name => %{vocab: MapSet(camelCase), required: MapSet(camelCase)}}
    def messages(path) do
      src = path |> File.read!() |> String.replace(~r{//[^\n]*}, "")

      blocks(src, "message")
      |> Map.new(fn {name, body} ->
        fields =
          body
          |> String.split("\n")
          |> Enum.flat_map(fn line ->
            case Regex.run(@field_re, line) do
              [_, _label, _type, name, _num, annotation] ->
                [{name, annotation != nil and String.contains?(annotation, "REQUIRED")}]

              nil ->
                []
            end
          end)

        # A field may appear in both a oneof block and nowhere else; dedupe by
        # keeping the REQUIRED-est entry.
        fields =
          Map.new(fields, fn {name, req} -> {name, req} end)
          |> Map.merge(
            fields
            |> Map.filter(fn {_n, req} -> req end)
            |> Map.new(fn {n, true} -> {n, true} end)
          )

        vocab = MapSet.new(fields, fn {name, _} -> camel(name) end)
        required = MapSet.new(for {name, true} <- fields, do: camel(name))

        %{name => %{vocab: vocab, required: required}}
      end)
    end

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

    def camel(name) do
      [head | rest] = String.split(name, "_")
      Enum.join([head | Enum.map(rest, &String.capitalize/1)])
    end
  end

  # ------------------------------------------------------------------
  # Court rows: one per pb message the codec bridges
  # ------------------------------------------------------------------

  defp rows do
    [
      %{
        label: "Task",
        pb_mod: Pb.Task,
        corpus: "Task",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(task_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      %{
        label: "TaskStatus",
        pb_mod: Pb.TaskStatus,
        corpus: "TaskStatus",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(status_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      %{
        label: "Message",
        pb_mod: Pb.Message,
        corpus: "Message",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(message_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      # Part: the three oneof members + the flat file shape; union of keys.
      %{
        label: "Part (oneof text/raw/url/data)",
        pb_mod: Pb.Part,
        corpus: "Part",
        codec_keys: fn ->
          ["text", "raw", "url", "data"]
          |> Enum.flat_map(fn variant ->
            {:ok, m} = JSON.encode(part_sample(variant))
            Map.keys(m)
          end)
          |> MapSet.new()
        end,
        ledger: []
      },
      %{
        label: "Artifact",
        pb_mod: Pb.Artifact,
        corpus: "Artifact",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(artifact_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      %{
        label: "TaskStatusUpdateEvent",
        pb_mod: Pb.TaskStatusUpdateEvent,
        corpus: "TaskStatusUpdateEvent",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(status_update_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      %{
        label: "TaskArtifactUpdateEvent",
        pb_mod: Pb.TaskArtifactUpdateEvent,
        corpus: "TaskArtifactUpdateEvent",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(artifact_update_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      %{
        label: "TaskPushNotificationConfig",
        pb_mod: Pb.TaskPushNotificationConfig,
        corpus: "TaskPushNotificationConfig",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(push_config_sample())
          MapSet.new(Map.keys(m))
        end,
        # Pb TaskPushNotificationConfig.tenant (field 1) has no codec
        # counterpart: %AshA2A.Protocol.PushNotificationConfig{} carries no
        # tenant — the gRPC bridge's request side takes tenant from
        # SendMessageRequest.tenant instead.
        ledger: ["tenant"]
      },
      %{
        label: "StreamResponse (all four members)",
        pb_mod: Pb.StreamResponse,
        corpus: "StreamResponse",
        codec_keys: fn ->
          [task_sample(), message_sample(), status_update_sample(), artifact_update_sample()]
          |> Enum.flat_map(fn s ->
            {:ok, m} = JSON.encode_stream_response(s)
            Map.keys(m)
          end)
          |> MapSet.new()
        end,
        ledger: []
      },
      %{
        label: "AgentCard",
        pb_mod: Pb.AgentCard,
        corpus: "AgentCard",
        codec_keys: fn -> card_map() |> MapSet.new(Map.keys()) end,
        ledger: []
      },
      %{
        label: "AgentCapabilities",
        pb_mod: Pb.AgentCapabilities,
        corpus: "AgentCapabilities",
        codec_keys: fn -> card_map()["capabilities"] |> MapSet.new(Map.keys()) end,
        ledger: []
      },
      %{
        label: "AgentInterface",
        pb_mod: Pb.AgentInterface,
        corpus: "AgentInterface",
        codec_keys: fn ->
          card_map()["supportedInterfaces"] |> hd() |> MapSet.new(Map.keys())
        end,
        # Pb AgentInterface.tenant (field 3) is not emitted: the card's
        # supportedInterfaces entries carry no tenant (single-tenant hosts).
        ledger: ["tenant"]
      },
      %{
        label: "AgentProvider",
        pb_mod: Pb.AgentProvider,
        corpus: "AgentProvider",
        codec_keys: fn -> card_map()["provider"] |> MapSet.new(Map.keys()) end,
        ledger: []
      },
      %{
        label: "AgentSkill",
        pb_mod: Pb.AgentSkill,
        corpus: "AgentSkill",
        codec_keys: fn -> card_map()["skills"] |> hd() |> MapSet.new(Map.keys()) end,
        # Pb AgentSkill.examples (field 5) is not emitted: the codec's skill
        # projection has no examples field.
        ledger: ["examples"]
      },
      %{
        label: "AgentExtension",
        pb_mod: Pb.AgentExtension,
        corpus: "AgentExtension",
        codec_keys: fn ->
          card_map()["capabilities"]["extensions"] |> hd() |> MapSet.new(Map.keys())
        end,
        ledger: []
      }
    ]
  end

  # ------------------------------------------------------------------
  # Test 1+2 — the three-way table (directions a–e above)
  # ------------------------------------------------------------------

  test "three-way fidelity court: codec ⇔ pb descriptors ⇔ spec corpus" do
    corpus = Corpus.messages(@proto_path)

    table =
      Enum.map(rows(), fn row ->
        codec = row.codec_keys.()
        pb = pb_names(row.pb_mod)
        %{vocab: vocab, required: required} = Map.fetch!(corpus, row.corpus)

        drift =
          Comparator.compare(codec, pb, required)

        # (a) codec ⊆ pb — the fail-open direction
        assert drift.missing == [],
               "#{row.label}: codec emits keys absent from the pb descriptor " <>
                 "(Protobuf.JSON drops them silently): #{inspect(drift.missing)}"

        # (b) pb − codec == pinned ledger
        assert drift.added == row.ledger,
               "#{row.label}: pb-only json_names drifted off the pinned ledger. " <>
                 "expected #{inspect(row.ledger)}, got #{inspect(drift.added)}"

        # (c)+(d) TCK-required fields: codec-emittable AND in the descriptor
        assert drift.required_missing == [],
               "#{row.label}: TCK-required fields not codec-emittable / not in pb: " <>
                 "#{inspect(drift.required_missing)}"

        # (e) codec vocabulary stays inside the spec IDL
        outside = codec |> MapSet.difference(vocab) |> Enum.sort()

        assert outside == [],
               "#{row.label}: codec emits keys outside the spec corpus vocabulary: " <>
                 "#{inspect(outside)}"

        %{
          "message" => row.label,
          "codec" => MapSet.size(codec),
          "pb" => MapSet.size(pb),
          "pb_only(pinned)" => row.ledger,
          "required" => MapSet.size(required)
        }
      end)

    # The court's three-way table, rendered into the run log.
    IO.puts([?\n, "X14 pb-descriptor fidelity court — three-way table:", ?\n])
    Enum.each(table, fn row -> IO.puts("#{inspect(row)}") end)
  end

  # ------------------------------------------------------------------
  # Test 3 — mutation witness: the comparator detects descriptor drift
  # ------------------------------------------------------------------

  test "mutation witness: renamed json_name and added pb-only key are flagged" do
    real = pb_names(Pb.Task)
    codec = MapSet.new(["id", "contextId", "status", "artifacts", "history", "metadata"])

    # Sanity: the real maps pass the comparator — the witness is not vacuous.
    assert Comparator.compare(codec, real) == %{
             missing: [],
             added: [],
             required_missing: []
           }

    # Mutation 1: copy the pb field map, rename ONE json_name in the copy.
    mutated_rename =
      Pb.Task.__message_props__().field_props
      |> Map.update!(2, fn %Protobuf.FieldProps{} = p -> %{p | json_name: "contextIdX"} end)
      |> Map.new(fn {_fnum, %Protobuf.FieldProps{} = p} -> {p.json_name, true} end)
      |> MapSet.new(Map.keys())

    drift = Comparator.compare(codec, mutated_rename)

    assert "contextId" in drift.missing,
           "comparator failed to flag the renamed json_name: #{inspect(drift)}"

    assert "contextIdX" in drift.added,
           "comparator failed to surface the mutant's new name: #{inspect(drift)}"

    # Mutation 2: a pb regeneration adding a field the codec cannot emit.
    mutated_add = MapSet.put(real, "taskLedgerOnly")
    drift2 = Comparator.compare(codec, mutated_add)
    assert drift2.added == ["taskLedgerOnly"], "comparator failed to flag pb-only addition"
  end

  # ------------------------------------------------------------------
  # Test 4 — Protobuf.JSON round-trip per message
  # ------------------------------------------------------------------

  test "Protobuf.JSON round-trip: pb message -> JSON -> codec struct" do
    Enum.each(round_trips(), fn %{label: label} = rt ->
      pb_msg = rt.pb.()
      json = pb_msg |> Protobuf.JSON.encode!() |> Jason.decode!()
      assert {:ok, struct} = rt.decode.(json), "#{label}: codec decode failed"

      # Pinned value-asserts: exactly the fields whose wire values this test
      # checks (see the pinned list in the moduledoc / per-row asserts).
      Enum.each(rt.value_asserts.(struct), fn {field_path, actual, expected} ->
        assert actual == expected,
               "#{label}: round-trip lost #{field_path}: #{inspect(actual)} != #{inspect(expected)}"
      end)
    end)
  end

  # ------------------------------------------------------------------
  # Test 5 — the documented fail-open edge itself
  # ------------------------------------------------------------------

  test "documented fail-open edge: Protobuf.JSON drops unknown camelCase keys silently" do
    json = %{"id" => "t1", "contextIdX" => "c1", "status" => %{"state" => "TASK_STATE_WORKING"}}

    # No error raised — decode fails open...
    decoded = Protobuf.JSON.decode!(Jason.encode!(json), Pb.Task)
    # ...and the unknown key's payload is gone: this is the silent-loss edge
    # the three-way court above exists to pre-empt.
    assert decoded.context_id == ""
  end

  # ------------------------------------------------------------------
  # Round-trip rows: pb sample -> codec decode, pinned value-asserts
  # ------------------------------------------------------------------

  defp round_trips do
    [
      %{
        label: "Task",
        pb: fn ->
          %Pb.Task{
            id: "t1",
            context_id: "c1",
            status: %Pb.TaskStatus{state: :TASK_STATE_WORKING},
            artifacts: [
              %Pb.Artifact{
                artifact_id: "a1",
                name: "out",
                parts: [%Pb.Part{content: {:text, "result"}}]
              }
            ],
            history: [
              %Pb.Message{
                message_id: "m1",
                role: :ROLE_AGENT,
                parts: [%Pb.Part{content: {:text, "hi"}}]
              }
            ],
            metadata: pb_struct(%{"k" => "v"})
          }
        end,
        decode: fn m -> JSON.decode(m, :task) end,
        value_asserts: fn s ->
          [
            {"id", s.id, "t1"},
            {"context_id", s.context_id, "c1"},
            {"status.state", s.status.state, :working},
            {"artifacts len", length(s.artifacts), 1},
            {"artifact_id", hd(s.artifacts).artifact_id, "a1"},
            {"history len", length(s.history), 1},
            {"history role", hd(s.history).role, :agent},
            {"metadata", s.metadata, %{"k" => "v"}}
          ]
        end
      },
      %{
        label: "TaskStatus",
        pb: fn ->
          %Pb.TaskStatus{
            state: :TASK_STATE_INPUT_REQUIRED,
            message: %Pb.Message{
              message_id: "sm",
              role: :ROLE_AGENT,
              parts: [%Pb.Part{content: {:text, "need input"}}]
            },
            timestamp: %Google.Protobuf.Timestamp{seconds: 1_767_225_600}
          }
        end,
        decode: fn m -> JSON.decode(m, :status) end,
        value_asserts: fn s ->
          [
            {"state", s.state, :input_required},
            {"message.message_id", s.message.message_id, "sm"},
            {"timestamp", s.timestamp, ~U[2026-01-01T00:00:00Z]}
          ]
        end
      },
      %{
        label: "Message",
        pb: fn ->
          %Pb.Message{
            message_id: "m1",
            context_id: "c1",
            task_id: "t1",
            role: :ROLE_AGENT,
            parts: [%Pb.Part{content: {:text, "hi"}}],
            metadata: pb_struct(%{"mk" => "mv"}),
            extensions: ["https://ext.example"],
            reference_task_ids: ["r1"]
          }
        end,
        decode: fn m -> JSON.decode(m, :message) end,
        value_asserts: fn s ->
          [
            {"message_id", s.message_id, "m1"},
            {"context_id", s.context_id, "c1"},
            {"task_id", s.task_id, "t1"},
            {"role", s.role, :agent},
            {"parts[0].text", hd(s.parts).text, "hi"},
            {"extensions", s.extensions, ["https://ext.example"]},
            {"referenceTaskIds", s.reference_task_ids, ["r1"]},
            {"metadata", s.metadata, %{"mk" => "mv"}}
          ]
        end
      },
      %{
        label: "Part.text",
        pb: fn -> %Pb.Part{content: {:text, "hello"}, metadata: pb_struct(%{"pk" => "pv"})} end,
        decode: fn m -> JSON.decode(m, :part) end,
        value_asserts: fn s ->
          [
            {"text", s.text, "hello"},
            {"metadata", s.metadata, %{"pk" => "pv"}}
          ]
        end
      },
      %{
        label: "Part.raw (file bytes)",
        pb: fn ->
          %Pb.Part{
            content: {:raw, <<1, 2, 3>>},
            filename: "f.bin",
            media_type: "application/octet-stream"
          }
        end,
        decode: fn m -> JSON.decode(m, :part) end,
        value_asserts: fn s ->
          [
            {"file.bytes", s.file.bytes, <<1, 2, 3>>},
            {"file.name", s.file.name, "f.bin"},
            {"file.mime_type", s.file.mime_type, "application/octet-stream"}
          ]
        end
      },
      %{
        label: "Part.url (file url)",
        pb: fn ->
          %Pb.Part{content: {:url, "https://x.example/i.png"}, media_type: "image/png"}
        end,
        decode: fn m -> JSON.decode(m, :part) end,
        value_asserts: fn s ->
          [
            {"file.uri", s.file.uri, "https://x.example/i.png"},
            {"file.mime_type", s.file.mime_type, "image/png"}
          ]
        end
      },
      %{
        label: "Part.data",
        pb: fn ->
          %Pb.Part{
            content: {:data, %Google.Protobuf.Value{kind: {:string_value, "x"}}},
            metadata: pb_struct(%{"dk" => "dv"})
          }
        end,
        decode: fn m -> JSON.decode(m, :part) end,
        value_asserts: fn s ->
          [
            {"data", s.data, "x"},
            {"metadata", s.metadata, %{"dk" => "dv"}}
          ]
        end
      },
      %{
        label: "Artifact",
        pb: fn ->
          %Pb.Artifact{
            artifact_id: "a1",
            name: "out",
            description: "d",
            parts: [%Pb.Part{content: {:text, "result"}}],
            metadata: pb_struct(%{"ak" => "av"}),
            extensions: ["https://ext.example"]
          }
        end,
        decode: fn m -> JSON.decode(m, :artifact) end,
        value_asserts: fn s ->
          [
            {"artifact_id", s.artifact_id, "a1"},
            {"name", s.name, "out"},
            {"description", s.description, "d"},
            {"parts[0].text", hd(s.parts).text, "result"},
            {"extensions", s.extensions, ["https://ext.example"]},
            {"metadata", s.metadata, %{"ak" => "av"}}
          ]
        end
      },
      %{
        label: "TaskStatusUpdateEvent",
        pb: fn ->
          %Pb.TaskStatusUpdateEvent{
            task_id: "t1",
            context_id: "c1",
            status: %Pb.TaskStatus{state: :TASK_STATE_COMPLETED}
          }
        end,
        decode: fn m -> JSON.decode(m, :status_update_event) end,
        value_asserts: fn s ->
          [
            {"task_id", s.task_id, "t1"},
            {"context_id", s.context_id, "c1"},
            {"status.state", s.status.state, :completed},
            {"final (derived)", s.final, true}
          ]
        end
      },
      %{
        label: "TaskArtifactUpdateEvent",
        pb: fn ->
          %Pb.TaskArtifactUpdateEvent{
            task_id: "t1",
            context_id: "c1",
            artifact: %Pb.Artifact{
              artifact_id: "a1",
              parts: [%Pb.Part{content: {:text, "chunk"}}]
            },
            append: true,
            last_chunk: true
          }
        end,
        decode: fn m -> JSON.decode(m, :artifact_update_event) end,
        value_asserts: fn s ->
          [
            {"task_id", s.task_id, "t1"},
            {"context_id", s.context_id, "c1"},
            {"artifact.artifact_id", s.artifact.artifact_id, "a1"},
            {"append", s.append, true},
            {"last_chunk", s.last_chunk, true}
          ]
        end
      },
      %{
        label: "TaskPushNotificationConfig",
        pb: fn ->
          %Pb.TaskPushNotificationConfig{
            id: "pc1",
            task_id: "t1",
            url: "https://hook.example",
            token: "tok",
            authentication: %Pb.AuthenticationInfo{scheme: "Bearer", credentials: "creds"}
          }
        end,
        decode: fn m -> JSON.decode(m, :push_notification_config) end,
        value_asserts: fn s ->
          [
            {"id", s.id, "pc1"},
            {"task_id", s.task_id, "t1"},
            {"url", s.url, "https://hook.example"},
            {"token", s.token, "tok"},
            {"authentication.scheme", s.authentication[:scheme], "Bearer"},
            {"authentication.credentials", s.authentication[:credentials], "creds"}
          ]
        end
      },
      %{
        label: "StreamResponse.statusUpdate",
        pb: fn ->
          %Pb.StreamResponse{
            payload:
              {:status_update,
               %Pb.TaskStatusUpdateEvent{
                 task_id: "t1",
                 context_id: "c1",
                 status: %Pb.TaskStatus{state: :TASK_STATE_WORKING}
               }}
          }
        end,
        decode: fn m -> JSON.decode(m, :event) end,
        value_asserts: fn s ->
          [
            {"task_id", s.task_id, "t1"},
            {"status.state", s.status.state, :working}
          ]
        end
      },
      %{
        label: "AgentCard",
        pb: fn ->
          %Pb.AgentCard{
            name: "card-agent",
            description: "desc",
            version: "1.0.0",
            supported_interfaces: [
              %Pb.AgentInterface{
                url: "https://a.example",
                protocol_binding: "JSONRPC",
                protocol_version: "1.0"
              }
            ],
            skills: [%Pb.AgentSkill{id: "s1", name: "s", description: "d", tags: ["t"]}],
            default_input_modes: ["text/plain"],
            default_output_modes: ["text/plain"]
          }
        end,
        decode: fn m -> JSON.decode_agent_card(m) end,
        value_asserts: fn s ->
          [
            {"name", s.name, "card-agent"},
            {"description", s.description, "desc"},
            {"version", s.version, "1.0.0"},
            {"interface url (preferred)", s.url, "https://a.example"},
            {"skills[0].id", hd(s.skills).id, "s1"}
          ]
        end
      }
    ]
  end

  # ------------------------------------------------------------------
  # Codec samples (W1 sources) — populated so every emittable key emits
  # ------------------------------------------------------------------

  defp task_sample do
    %Task{
      id: "t1",
      context_id: "c1",
      status: status_sample(),
      history: [message_sample()],
      artifacts: [artifact_sample()],
      metadata: %{"k" => "v"}
    }
  end

  defp status_sample do
    %AshA2A.Protocol.Task.Status{
      state: :working,
      message: message_sample(),
      timestamp: ~U[2026-01-01T00:00:00Z]
    }
  end

  defp message_sample do
    %Message{
      message_id: "m1",
      role: :agent,
      parts: [
        part_sample("text"),
        part_sample("raw"),
        part_sample("url"),
        part_sample("data")
      ],
      task_id: "t1",
      context_id: "c1",
      reference_task_ids: ["r1"],
      metadata: %{"mk" => "mv"},
      extensions: ["https://ext.example"]
    }
  end

  # Variant in {"text", "raw", "url", "data"}.
  defp part_sample("text"), do: %Part.Text{text: "hello", metadata: %{"pk" => "pv"}}

  defp part_sample("raw"),
    do: %Part.File{
      file: %AshA2A.Protocol.FileContent{
        bytes: <<1, 2, 3>>,
        name: "f.bin",
        mime_type: "application/octet-stream"
      },
      metadata: %{"pk" => "pv"}
    }

  defp part_sample("url"),
    do: %Part.File{
      file: %AshA2A.Protocol.FileContent{uri: "https://x.example/i.png", mime_type: "image/png"}
    }

  defp part_sample("data"), do: %Part.Data{data: %{"dk" => "dv"}, metadata: %{"pk" => "pv"}}

  defp artifact_sample do
    %Artifact{
      artifact_id: "a1",
      name: "out",
      description: "d",
      parts: [part_sample("text")],
      extensions: ["https://ext.example"],
      metadata: %{"ak" => "av"}
    }
  end

  defp status_update_sample do
    Event.StatusUpdate.new("t1", status_sample(), context_id: "c1", metadata: %{"ek" => "ev"})
  end

  defp artifact_update_sample do
    Event.ArtifactUpdate.new("t1", artifact_sample(),
      context_id: "c1",
      append: true,
      last_chunk: true,
      metadata: %{"ek" => "ev"}
    )
  end

  defp push_config_sample do
    %PushNotificationConfig{
      id: "pc1",
      task_id: "t1",
      url: "https://hook.example",
      token: "tok",
      authentication: %{scheme: "Bearer", credentials: "creds"}
    }
  end

  defp card do
    %AgentCard{
      name: "card-agent",
      description: "desc",
      url: "https://a.example",
      version: "1.0.0",
      provider: %{organization: "Org", url: "https://p.example"},
      documentation_url: "https://docs.example",
      icon_url: "https://icon.example",
      skills: [
        %{
          id: "s1",
          name: "s",
          description: "d",
          tags: ["t"],
          input_modes: ["text/plain"],
          output_modes: ["text/plain"],
          security_requirements: [%{"api" => ["scope1"]}]
        }
      ],
      capabilities: %{
        streaming: true,
        push_notifications: true,
        extended_agent_card: true,
        extensions: [
          %AgentExtension{
            uri: "https://ext.example",
            required: true,
            description: "d",
            params: %{"a" => "b"}
          }
        ]
      },
      default_input_modes: ["text/plain"],
      default_output_modes: ["text/plain"],
      supported_interfaces: [
        %{url: "https://a.example", protocol_binding: "JSONRPC", protocol_version: "1.0"}
      ],
      security_schemes: %{
        "api" => %AshA2A.Protocol.SecurityScheme.APIKey{name: "key", in: "header"},
        "http" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"},
        "oauth2" => %AshA2A.Protocol.SecurityScheme.OAuth2{
          flows: %{
            "authorizationCode" => %{
              "authorizationUrl" => "https://auth.example",
              "tokenUrl" => "https://tok.example",
              "refreshUrl" => "https://ref.example",
              "scopes" => %{"read" => "r"},
              "pkceRequired" => true
            },
            "clientCredentials" => %{
              "tokenUrl" => "https://tok.example"
            }
          },
          oauth2_metadata_url: "https://meta.example"
        },
        "oidc" => %AshA2A.Protocol.SecurityScheme.OpenIDConnect{
          open_id_connect_url: "https://oidc.example"
        },
        "mtls" => %AshA2A.Protocol.SecurityScheme.MutualTLS{}
      },
      security: [%{"api" => ["scope1"]}],
      signatures: [
        %{"protected" => "p", "signature" => "sig", "header" => %{"alg" => "ES256K"}}
      ]
    }
  end

  defp card_map do
    JSON.encode_agent_card(card(), url: "https://a.example")
  end

  defp pb_struct(map) do
    %Google.Protobuf.Struct{
      fields:
        Map.new(map, fn {k, v} ->
          {k, %Google.Protobuf.Value{kind: {:string_value, v}}}
        end)
    }
  end
end
