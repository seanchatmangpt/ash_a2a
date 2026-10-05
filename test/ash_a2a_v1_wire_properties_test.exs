defmodule AshA2A.V1WirePropertiesTest do
  @moduledoc """
  Property-based wire round-trip suite (lane W8) over the real v1.0 JSON codec
  (`AshA2A.Protocol.JSON`) and the real JSON-RPC dispatch layer
  (`AshA2A.Protocol.JSONRPC`).

  Structs are generated from their real field types: atom `:user`/`:agent`
  roles, `AshA2A.TaskLifecycle.states/0` states, string/float/int/bool/nil
  JSON leaves for wire maps and `Part.Data` payloads. No test doubles
  anywhere: the JSON-RPC properties run `handle/3` against a real handler
  module (`EchoHandler`, defined below) and assert on real returned state.

  Properties:

    1. encode -> `Jason.encode!` -> `Jason.decode!` -> decode returns an
       equivalent struct, field-wise, modulo the codec's documented
       normalizations (Task contextId "" sentinel, nil members omitted,
       timestamp wire formatting, `final` reconstructed from status state,
       agent-card top-level `protocol_version` not emitted — v1.0-correct
       absence, protocolVersion is per-interface — and `preferred_transport`
       never emitted or decoded: the v1.0 AgentCard proto message
       (priv/a2a_v1_spec_corpus/a2a.proto:362, fields 1-14) has NO
       `preferredTransport` field, so the member is struct-only by spec,
       not a codec gap — preference IS `supportedInterfaces[0]`).
    2. encode output NEVER contains a `"kind"` or `"final"` key at any depth
       (v1.0 invariant), across every encodable struct, the v1.0
       StreamResponse wrapper, and the agent card.
    3. JSON-RPC envelopes: generated message/send and tasks/get requests
       survive handle -> Response envelope -> Jason -> decode with the
       result struct equivalent and the envelope id round-tripping;
       malformed envelopes answer -32600; error envelopes round-trip with
       the spec's google.rpc.ErrorInfo normalization.
    4. idempotence: `decode(encode(decode(encode(x)))) == decode(encode(x))`
       for every generated shape.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshA2A.Protocol.{
    AgentCard,
    AgentExtension,
    Artifact,
    Event,
    JSON,
    JSONRPC,
    Message,
    Part,
    SecurityScheme,
    Task
  }

  alias AshA2A.Protocol.JSONRPC.{Error, Response}
  alias AshA2A.TaskLifecycle

  # All 14 A2A/JSON-RPC error codes with constructors on
  # `AshA2A.Protocol.JSONRPC.Error`.
  @error_codes Enum.to_list(-32_009..-32_001) ++
                 [-32_700, -32_600, -32_601, -32_602, -32_603]

  # The codec reconstructs `final` from these terminal/interrupted states on
  # decode (mirrors `AshA2A.Protocol.JSON`'s documented `@final_states`
  # normalization).
  @derived_final_states [
    :completed,
    :canceled,
    :failed,
    :rejected,
    :input_required,
    :auth_required
  ]

  @a2a_error_info_codes Enum.to_list(-32_009..-32_001) ++ [-32_602]

  # ---------------------------------------------------------------------
  # Real JSON-RPC handler collaborator (no doubles)
  # ---------------------------------------------------------------------

  defmodule EchoHandler do
    @moduledoc false

    @behaviour AshA2A.Protocol.JSONRPC

    @impl true
    def handle_send(message, params, _context) do
      Process.put(:w8_last_send, {message, params})
      {:ok, message}
    end

    @impl true
    def handle_get(task_id, params, _context) do
      Process.put(:w8_last_get, {task_id, params})

      case Process.get(:w8_task) do
        %AshA2A.Protocol.Task{id: ^task_id} = task -> {:ok, task}
        _ -> {:error, AshA2A.Protocol.JSONRPC.Error.task_not_found()}
      end
    end

    @impl true
    def handle_cancel(task_id, _params, _context) do
      case Process.get(:w8_task) do
        %AshA2A.Protocol.Task{id: ^task_id} = task -> {:ok, task}
        _ -> {:error, AshA2A.Protocol.JSONRPC.Error.task_not_found()}
      end
    end
  end

  # ---------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------

  defp nonempty_string, do: string(:alphanumeric, min_length: 1, max_length: 24)

  defp key_gen, do: string(:alphanumeric, min_length: 1, max_length: 8)

  # A key space that can never collide with the codec's banned discriminator
  # keys, so the property-wide "no kind/final" scan is well-formed even over
  # user-controlled maps (metadata, data payloads, scheme names).
  defp safe_key_gen, do: filter(key_gen(), &(&1 not in ["kind", "final"]))

  defp scalar_gen do
    one_of([
      member_of([nil, true, false]),
      integer(-1_000_000..1_000_000),
      map(integer(-8..1_000_000), &(&1 / 8.0)),
      string(:printable, max_length: 24)
    ])
  end

  defp wire_map_gen, do: map_of(safe_key_gen(), scalar_gen(), max_length: 4)

  defp value_gen do
    one_of([
      scalar_gen(),
      wire_map_gen(),
      list_of(scalar_gen(), max_length: 3)
    ])
  end

  defp data_gen, do: map_of(safe_key_gen(), value_gen(), max_length: 4)

  defp text_part_gen do
    gen all text <- string(:printable, min_length: 1, max_length: 40),
            metadata <- wire_map_gen() do
      Part.Text.new(text, metadata)
    end
  end

  defp data_part_gen do
    gen all data <- data_gen(),
            metadata <- wire_map_gen() do
      Part.Data.new(data, metadata)
    end
  end

  defp part_gen, do: one_of([text_part_gen(), data_part_gen()])

  # Full-microsecond-precision UTC timestamps: the wire emits the 6-digit
  # fraction, so the decoded struct's `microsecond` matches exactly.
  defp timestamp_gen do
    gen all secs <- integer(1_600_000_000..3_000_000_000),
            us <- integer(0..999_999) do
      dt = DateTime.add(~U[2020-09-01T00:00:00Z], secs, :second)
      %{dt | microsecond: {us, 6}}
    end
  end

  defp message_gen do
    gen all message_id <- nonempty_string(),
            role <- member_of([:user, :agent]),
            parts <- list_of(part_gen(), min_length: 1, max_length: 3),
            task_id <- one_of([constant(nil), nonempty_string()]),
            context_id <- one_of([constant(nil), nonempty_string()]),
            reference_task_ids <- list_of(nonempty_string(), max_length: 3),
            metadata <- wire_map_gen(),
            extensions <- wire_map_gen() do
      %Message{
        message_id: message_id,
        role: role,
        parts: parts,
        task_id: task_id,
        context_id: context_id,
        reference_task_ids: reference_task_ids,
        metadata: metadata,
        extensions: extensions
      }
    end
  end

  defp status_gen do
    gen all state <- member_of(TaskLifecycle.states()),
            message <- one_of([constant(nil), message_gen()]),
            timestamp <- timestamp_gen() do
      %Task.Status{state: state, message: message, timestamp: timestamp}
    end
  end

  defp task_gen do
    gen all id <- nonempty_string(),
            context_id <- one_of([constant(nil), nonempty_string()]),
            status <- status_gen(),
            history <- list_of(message_gen(), max_length: 3),
            artifacts <- list_of(artifact_gen(), max_length: 2),
            metadata <- wire_map_gen() do
      %Task{
        id: id,
        context_id: context_id,
        status: status,
        history: history,
        artifacts: artifacts,
        metadata: metadata
      }
    end
  end

  defp artifact_gen do
    gen all artifact_id <- one_of([constant(nil), nonempty_string()]),
            name <- one_of([constant(nil), nonempty_string()]),
            description <- one_of([constant(nil), nonempty_string()]),
            parts <- list_of(part_gen(), max_length: 3),
            extensions <- list_of(nonempty_string(), max_length: 2),
            metadata <- wire_map_gen() do
      %Artifact{
        artifact_id: artifact_id,
        name: name,
        description: description,
        parts: parts,
        extensions: extensions,
        metadata: metadata
      }
    end
  end

  defp status_update_gen do
    gen all task_id <- nonempty_string(),
            context_id <- one_of([constant(nil), nonempty_string()]),
            status <- status_gen(),
            metadata <- wire_map_gen() do
      %Event.StatusUpdate{
        task_id: task_id,
        context_id: context_id,
        status: status,
        final: false,
        metadata: metadata
      }
    end
  end

  defp artifact_update_gen do
    gen all task_id <- nonempty_string(),
            context_id <- one_of([constant(nil), nonempty_string()]),
            append <- one_of([constant(nil), boolean()]),
            last_chunk <- one_of([constant(nil), boolean()]),
            artifact <- artifact_gen(),
            metadata <- wire_map_gen() do
      %Event.ArtifactUpdate{
        task_id: task_id,
        context_id: context_id,
        artifact: artifact,
        append: append,
        last_chunk: last_chunk,
        metadata: metadata
      }
    end
  end

  defp caps_gen do
    gen all streaming <- boolean(),
            push_notifications <- boolean(),
            extended_agent_card <- boolean(),
            extensions <- list_of(agent_extension_gen(), max_length: 2) do
      base = %{
        streaming: streaming,
        push_notifications: push_notifications,
        extended_agent_card: extended_agent_card
      }

      if extensions == [] do
        base
      else
        Map.put(base, :extensions, extensions)
      end
    end
  end

  defp agent_extension_gen do
    gen all uri <- nonempty_string(),
            description <- one_of([constant(nil), nonempty_string()]),
            required <- boolean(),
            params <- one_of([constant(nil), wire_map_gen()]) do
      %AgentExtension{uri: uri, description: description, required: required, params: params}
    end
  end

  defp skill_gen do
    gen all id <- nonempty_string(),
            name <- nonempty_string(),
            description <- nonempty_string(),
            tags <- list_of(nonempty_string(), max_length: 2) do
      %{id: id, name: name, description: description, tags: tags}
    end
  end

  defp url_gen, do: map(nonempty_string(), &("https://" <> &1))

  defp provider_gen do
    gen all organization <- nonempty_string(),
            url <- url_gen() do
      %{organization: organization, url: url}
    end
  end

  defp interface_gen do
    gen all url <- url_gen(),
            protocol_binding <- member_of(["JSONRPC", "GRPC", "HTTP+JSON"]),
            protocol_version <- nonempty_string() do
      %{url: url, protocol_binding: protocol_binding, protocol_version: protocol_version}
    end
  end

  defp schemes_gen, do: map_of(safe_key_gen(), scheme_gen(), max_length: 2)

  defp scheme_gen do
    one_of([
      gen all name <- nonempty_string(),
              location <- member_of(["query", "header", "cookie"]) do
        %SecurityScheme.APIKey{name: name, in: location}
      end,
      gen all scheme <- nonempty_string() do
        %SecurityScheme.HTTPAuth{scheme: scheme}
      end,
      gen all flows <- data_gen(),
              metadata_url <- one_of([constant(nil), url_gen()]) do
        %SecurityScheme.OAuth2{flows: flows, oauth2_metadata_url: metadata_url}
      end,
      gen all oauth_url <- url_gen() do
        %SecurityScheme.OpenIDConnect{open_id_connect_url: oauth_url}
      end,
      constant(%SecurityScheme.MutualTLS{})
    ])
  end

  defp security_gen do
    list_of(
      gen all name <- safe_key_gen(),
              scopes <- list_of(nonempty_string(), max_length: 2) do
        %{name => scopes}
      end,
      max_length: 2
    )
  end

  defp sig_gen do
    gen all protected <- nonempty_string(),
            signature <- nonempty_string(),
            header <- wire_map_gen() do
      %{"protected" => protected, "signature" => signature, "header" => header}
    end
  end

  defp agent_card_gen do
    gen all name <- nonempty_string(),
            description <- nonempty_string(),
            url <- url_gen(),
            version <- nonempty_string(),
            skills <- list_of(skill_gen(), max_length: 3),
            capabilities <- caps_gen(),
            input_modes <- list_of(nonempty_string(), min_length: 1, max_length: 3),
            output_modes <- list_of(nonempty_string(), min_length: 1, max_length: 3),
            provider <- one_of([constant(nil), provider_gen()]),
            documentation_url <- one_of([constant(nil), url_gen()]),
            icon_url <- one_of([constant(nil), url_gen()]),
            interfaces <- list_of(interface_gen(), min_length: 1, max_length: 2),
            schemes <- schemes_gen(),
            security <- security_gen(),
            signatures <- list_of(sig_gen(), max_length: 2) do
      %AgentCard{
        name: name,
        description: description,
        url: url,
        version: version,
        skills: skills,
        capabilities: capabilities,
        default_input_modes: input_modes,
        default_output_modes: output_modes,
        provider: provider,
        documentation_url: documentation_url,
        icon_url: icon_url,
        supported_interfaces: interfaces,
        security_schemes: schemes,
        security: security,
        signatures: signatures
      }
    end
  end

  defp rpc_id_gen do
    one_of([nonempty_string(), integer(-1_000..1_000), constant(nil)])
  end

  defp encodable_gen do
    one_of([
      message_gen(),
      status_gen(),
      task_gen(),
      artifact_gen(),
      part_gen(),
      status_update_gen(),
      artifact_update_gen()
    ])
  end

  defp malformed_request_gen do
    one_of([
      constant(%{"jsonrpc" => "1.0", "method" => "message/send", "params" => %{}, "id" => "a1"}),
      constant(%{"method" => "tasks/get", "params" => %{}, "id" => "a2"}),
      constant(%{"jsonrpc" => "2.0", "method" => 42, "params" => %{}, "id" => "a3"}),
      gen all bad_id <- one_of([constant(1.5), constant([1])]) do
        %{"jsonrpc" => "2.0", "id" => bad_id, "method" => "tasks/get", "params" => %{}}
      end
    ])
  end

  defp send_request_gen do
    gen all id <- rpc_id_gen(),
            method <- member_of(["message/send", "SendMessage"]),
            msg <- message_gen(),
            extra_metadata <- one_of([constant(nil), wire_map_gen()]) do
      params = %{"message" => JSON.encode!(msg)}
      params = if extra_metadata, do: Map.put(params, "metadata", extra_metadata), else: params
      raw = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
      {raw, msg}
    end
  end

  defp get_request_gen do
    gen all id <- rpc_id_gen(),
            method <- member_of(["tasks/get", "GetTask"]),
            task <- task_gen() do
      request = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => %{"id" => task.id}}
      {request, task}
    end
  end

  # ---------------------------------------------------------------------
  # Documented-normalization expectations
  #
  # For each generated struct, `expected/1` is exactly the struct a wire
  # round trip is documented to produce.
  # ---------------------------------------------------------------------

  defp expected(%Message{} = m), do: m
  defp expected(%Part.Text{} = p), do: p
  defp expected(%Part.Data{} = p), do: p
  defp expected(%Task.Status{} = s), do: s
  defp expected(%Artifact{} = a), do: a
  defp expected(%Event.ArtifactUpdate{} = e), do: e

  defp expected(%Task{} = t) do
    %{
      t
      | context_id: t.context_id || "",
        status: expected(t.status),
        history: Enum.map(t.history, &expected/1),
        artifacts: Enum.map(t.artifacts, &expected/1)
    }
  end

  defp expected(%Event.StatusUpdate{} = e) do
    %{e | final: e.status.state in @derived_final_states}
  end

  defp expected(%AgentCard{} = card) do
    # v1.0 drops the top-level `url`/`protocolVersion` members (both are
    # per-interface), so decode reconstructs `url` from the first supported
    # interface (`AshA2A.Protocol.JSON.preferred_interface_url/1`).
    # `preferred_transport` is struct-only by spec, not a codec gap: the
    # v1.0 AgentCard proto message (priv/a2a_v1_spec_corpus/a2a.proto:362,
    # fields 1-14) defines no `preferredTransport` field — preference is
    # positional via supportedInterfaces[0] (a2a.proto:370) — so encode
    # never emits it and decode leaves it nil.
    expected_url =
      case Enum.find(card.supported_interfaces, &is_binary(Map.get(&1, :url))) do
        %{url: url} -> url
        _ -> card.url
      end

    %{
      card
      | protocol_version: nil,
        preferred_transport: nil,
        url: expected_url
    }
  end

  # The `kind`/`final` scan recurses real maps and lists; structs are leaves.
  defp no_kind_or_final?(value) do
    cond do
      is_map(value) and not is_struct(value) ->
        keys_ok? = not Enum.any?(Map.keys(value), &(&1 in ["kind", "final"]))
        keys_ok? and Enum.all?(Map.values(value), &no_kind_or_final?/1)

      is_list(value) ->
        Enum.all?(value, &no_kind_or_final?/1)

      true ->
        true
    end
  end

  defp round_trip_json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp decode_type(%Message{}), do: :message
  defp decode_type(%Task{}), do: :task
  defp decode_type(%Task.Status{}), do: :status
  defp decode_type(%Artifact{}), do: :artifact
  defp decode_type(%Part.Text{}), do: :part
  defp decode_type(%Part.Data{}), do: :part

  # ---------------------------------------------------------------------
  # (a) struct wire round-trips
  # ---------------------------------------------------------------------

  property "Message: encode/Jason/decode round-trips to an equivalent struct" do
    check all msg <- message_gen(), max_runs: 50 do
      {:ok, encoded} = JSON.encode(msg)
      json = round_trip_json(encoded)
      {:ok, decoded} = JSON.decode(json, :message)
      assert decoded == expected(msg)
    end
  end

  property "Part.Text: encode/Jason/decode round-trips to an equivalent struct" do
    check all part <- text_part_gen(), max_runs: 50 do
      {:ok, encoded} = JSON.encode(part)
      json = round_trip_json(encoded)
      {:ok, decoded} = JSON.decode(json, :part)
      assert decoded == expected(part)
    end
  end

  property "Part.Data: encode/Jason/decode round-trips to an equivalent struct" do
    check all part <- data_part_gen(), max_runs: 50 do
      {:ok, encoded} = JSON.encode(part)
      json = round_trip_json(encoded)
      {:ok, decoded} = JSON.decode(json, :part)
      assert decoded == expected(part)
    end
  end

  property "Task.Status: encode/Jason/decode round-trips to an equivalent struct" do
    check all status <- status_gen(), max_runs: 50 do
      {:ok, encoded} = JSON.encode(status)
      json = round_trip_json(encoded)
      {:ok, decoded} = JSON.decode(json, :status)
      assert decoded == expected(status)
    end
  end

  property "Task: encode/Jason/decode round-trips to an equivalent struct" do
    check all task <- task_gen(), max_runs: 50 do
      {:ok, encoded} = JSON.encode(task)
      json = round_trip_json(encoded)
      {:ok, decoded} = JSON.decode(json, :task)
      assert decoded == expected(task)
    end
  end

  property "Artifact: encode/Jason/decode round-trips to an equivalent struct" do
    check all artifact <- artifact_gen(), max_runs: 50 do
      {:ok, encoded} = JSON.encode(artifact)
      json = round_trip_json(encoded)
      {:ok, decoded} = JSON.decode(json, :artifact)
      assert decoded == expected(artifact)
    end
  end

  property "Event.StatusUpdate: StreamResponse-wrapped round-trips to an equivalent struct" do
    check all event <- status_update_gen(), max_runs: 50 do
      {:ok, wrapped} = JSON.encode_stream_response(event)
      assert Map.has_key?(wrapped, "statusUpdate")
      json = round_trip_json(wrapped)
      {:ok, decoded} = JSON.decode(json, :event)
      assert decoded == expected(event)
    end
  end

  property "Event.ArtifactUpdate: StreamResponse-wrapped round-trips to an equivalent struct" do
    check all event <- artifact_update_gen(), max_runs: 50 do
      {:ok, wrapped} = JSON.encode_stream_response(event)
      assert Map.has_key?(wrapped, "artifactUpdate")
      json = round_trip_json(wrapped)
      {:ok, decoded} = JSON.decode(json, :event)
      assert decoded == expected(event)
    end
  end

  property "AgentCard: encode_agent_card/decode_agent_card round-trips field-wise" do
    check all card <- agent_card_gen(), max_runs: 50 do
      encoded = JSON.encode_agent_card(card, url: card.url)
      json = round_trip_json(encoded)
      {:ok, decoded} = JSON.decode_agent_card(json)
      assert decoded == expected(card)
    end
  end

  test "AgentCard preferred_transport is struct-only: never on the v1.0 wire, in either direction" do
    # Ground truth (vendored corpus): the v1.0 AgentCard proto message
    # (priv/a2a_v1_spec_corpus/a2a.proto:362) defines fields 1-14 and NONE
    # of them is `preferredTransport` — transport preference is positional,
    # carried by `supported_interfaces` field 3 ("The first entry is
    # preferred", a2a.proto:370). No example in
    # priv/a2a_v1_spec_corpus/v1_spec_examples.json carries the member
    # either. The struct field is a convenience, deliberately excluded at
    # the wire boundary on BOTH sides.
    card = %AgentCard{
      name: "x",
      description: "y",
      url: "https://x.example.com",
      version: "1.0.0",
      skills: [],
      preferred_transport: "JSONRPC"
    }

    encoded = JSON.encode_agent_card(card, url: card.url)
    refute Map.has_key?(encoded, "preferredTransport")
    json = round_trip_json(encoded)
    refute Map.has_key?(json, "preferredTransport")

    {:ok, decoded} = JSON.decode_agent_card(json)
    assert decoded.preferred_transport == nil

    # Even a legacy/foreign peer shipping a top-level "preferredTransport"
    # key gets it ignored on decode (never surfaced onto the struct).
    {:ok, foreign} =
      JSON.decode_agent_card(Map.put(json, "preferredTransport", "GRPC"))

    assert foreign.preferred_transport == nil
    assert foreign.supported_interfaces == decoded.supported_interfaces
  end

  # ---------------------------------------------------------------------
  # (b) v1.0 invariant: no "kind"/"final" key anywhere in encode output
  # ---------------------------------------------------------------------

  property "encode output never contains a kind or final key at any depth" do
    check all struct <- encodable_gen(), card <- agent_card_gen(), max_runs: 50 do
      {:ok, encoded} = JSON.encode(struct)
      assert no_kind_or_final?(encoded)

      # Only Task/Message/stream events ride the v1.0 StreamResponse wrapper.
      wrappable? =
        match?(%Task{}, struct) or match?(%Message{}, struct) or
          match?(%Event.StatusUpdate{}, struct) or match?(%Event.ArtifactUpdate{}, struct)

      if wrappable? do
        assert {:ok, wrapped} = JSON.encode_stream_response(struct)
        assert no_kind_or_final?(wrapped)
      end

      card_encoded = JSON.encode_agent_card(card, url: card.url)
      assert no_kind_or_final?(card_encoded)
    end
  end

  # ---------------------------------------------------------------------
  # (c) JSON-RPC envelope round-trips through the real dispatch layer
  # ---------------------------------------------------------------------

  property "message/send: generated request survives handle/envelope/Jason/decode" do
    check all {raw, msg} <- send_request_gen(), max_runs: 50 do
      params = raw["params"]

      assert {:reply, response} = JSONRPC.handle(raw, EchoHandler)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == raw["id"]

      # The envelope is pure JSON: a Jason round trip is lossless.
      assert round_trip_json(response) == response

      # The handler saw exactly the decoded message and the raw params.
      assert {seen_message, seen_params} = Process.get(:w8_last_send)
      assert seen_message == expected(msg)
      assert seen_params == params

      {:ok, result_message} = JSON.decode(response["result"]["message"], :message)
      assert result_message == expected(msg)
    end
  end

  property "tasks/get: generated request survives handle/envelope/Jason/decode" do
    check all {raw, task} <- get_request_gen(), max_runs: 50 do
      Process.put(:w8_task, task)

      assert {:reply, response} = JSONRPC.handle(raw, EchoHandler)
      assert response["id"] == raw["id"]
      assert response["jsonrpc"] == "2.0"
      assert round_trip_json(response) == response

      assert {seen_task_id, _params} = Process.get(:w8_last_get)
      assert seen_task_id == task.id

      {:ok, result_task} = JSON.decode(response["result"], :task)
      assert result_task == expected(task)
    end
  end

  property "malformed envelope: handle answers -32600 and the error round-trips" do
    check all raw <- malformed_request_gen(), max_runs: 50 do
      assert {:reply, response} = JSONRPC.handle(raw, EchoHandler)
      assert response["error"]["code"] == -32_600
      assert response["jsonrpc"] == "2.0"

      expected_id =
        case raw["id"] do
          id when is_binary(id) or is_integer(id) -> id
          _ -> nil
        end

      assert response["id"] == expected_id
      assert round_trip_json(response) == response
    end
  end

  property "error envelope: all 14 codes round-trip with ErrorInfo normalization" do
    check all code <- member_of(@error_codes),
              data <- one_of([constant(nil), scalar_gen()]),
              id <- rpc_id_gen(),
              max_runs: 50 do
      error = error_for_code(code, data)
      envelope = Response.error(id, error)
      json = round_trip_json(envelope)
      assert json == envelope

      err = json["error"]
      assert err["code"] == code
      assert err["message"] == error.message

      cond do
        code in @a2a_error_info_codes ->
          assert [info] = err["data"]
          assert info["@type"] == "type.googleapis.com/google.rpc.ErrorInfo"
          assert info["domain"] == "a2a-protocol.org"

          expected_detail = if is_binary(data), do: data, else: inspect(data)

          if data == nil do
            refute Map.has_key?(info, "metadata")
          else
            assert info["metadata"] == %{"detail" => expected_detail}
          end

        data == nil ->
          refute Map.has_key?(err, "data")

        true ->
          assert err["data"] == data
      end
    end
  end

  defp error_for_code(code, data) do
    constructors = %{
      -32_700 => &Error.parse_error/1,
      -32_600 => &Error.invalid_request/1,
      -32_601 => &Error.method_not_found/1,
      -32_602 => &Error.invalid_params/1,
      -32_603 => &Error.internal_error/1,
      -32_001 => &Error.task_not_found/1,
      -32_002 => &Error.task_not_cancelable/1,
      -32_003 => &Error.push_notification_not_supported/1,
      -32_004 => &Error.unsupported_operation/1,
      -32_005 => &Error.content_type_not_supported/1,
      -32_006 => &Error.invalid_agent_response/1,
      -32_007 => &Error.authenticated_extended_card_not_configured/1,
      -32_008 => &Error.extension_support_required/1,
      -32_009 => &Error.version_not_supported/1
    }

    apply(Map.fetch!(constructors, code), [data])
  end

  # ---------------------------------------------------------------------
  # (d) idempotence
  # ---------------------------------------------------------------------

  property "idempotence: decode(encode(decode(encode(x)))) == decode(encode(x))" do
    check all struct <- encodable_gen(), max_runs: 50 do
      if match?(%Event.StatusUpdate{}, struct) or match?(%Event.ArtifactUpdate{}, struct) do
        # Streaming events round-trip through the v1.0 StreamResponse wrapper.
        {:ok, wrapped} = JSON.encode_stream_response(struct)
        {:ok, once} = JSON.decode(round_trip_json(wrapped), :event)
        {:ok, wrapped2} = JSON.encode_stream_response(once)
        {:ok, twice} = JSON.decode(round_trip_json(wrapped2), :event)
        assert once == twice
      else
        {:ok, encoded} = JSON.encode(struct)
        {:ok, once} = JSON.decode(round_trip_json(encoded), decode_type(struct))
        {:ok, encoded_again} = JSON.encode(once)
        {:ok, twice} = JSON.decode(round_trip_json(encoded_again), decode_type(once))
        assert twice == once
      end
    end
  end

  property "AgentCard idempotence: re-encoding a decoded card is a fixed point" do
    check all card <- agent_card_gen(), max_runs: 50 do
      encoded = JSON.encode_agent_card(card, url: card.url)
      {:ok, once} = JSON.decode_agent_card(round_trip_json(encoded))

      encoded_again = JSON.encode_agent_card(once, url: once.url)
      {:ok, twice} = JSON.decode_agent_card(round_trip_json(encoded_again))

      assert twice == once
    end
  end
end
