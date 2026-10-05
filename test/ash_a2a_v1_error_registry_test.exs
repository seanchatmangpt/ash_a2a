# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# In-file real fixtures (real ETS Ash resources, real agents)
# ---------------------------------------------------------------------------

defmodule AshA2A.V1ErrorRegistry.Echo do
  @moduledoc """
  Real ETS fixture resource with exactly one skill, so the agent's
  single-skill default dispatch (`AshA2A.Agent.default_skill_name/1`)
  resolves without `:skill` metadata — the same shape the HTTP+JSON
  transport court uses.
  """

  use Ash.Resource,
    domain: AshA2A.V1ErrorRegistry.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.V1ErrorRegistry.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V1ErrorRegistry.Echo)
  end
end

defmodule AshA2A.V1ErrorRegistry.EchoAgent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.V1ErrorRegistry.Echo,
    name: "v1_error_registry_echo_agent"
end

defmodule AshA2A.V1ErrorRegistry.BusyAgent do
  @moduledoc """
  Real agent with a zero in-flight admission cap: every `message:send` is
  genuinely refused `:server_busy` before a task is created, driving the
  transport's `-32000` / 503 path.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.V1ErrorRegistry.Echo,
    name: "v1_error_registry_busy_agent",
    execution: [max_in_flight: 0]
end

defmodule AshA2A.Protocol.V1ErrorRegistryTest do
  @moduledoc """
  A2A v1.0 error-registry totality court (lane W4) over the FULL 14-code
  registry of `AshA2A.Protocol.JSONRPC.Error` (-32001..-32009 plus the five
  JSON-RPC 2.0 standard codes -32700/-32600/-32601/-32602/-32603).

  Real codecs, real agents (`use AshA2A.Agent` over real ETS Ash resources),
  real transport conns (`Plug.Test`), real compiled BEAM artifacts — zero
  mocks (Chicago style). Five courts:

    (a) every A2A-range code (-32001..-32009) — plus -32602 — serializes
        through the real `Error.to_map/1` with exactly one
        `google.rpc.ErrorInfo` (`@type`, domain `a2a-protocol.org`,
        UPPER_SNAKE_CASE reason, caller detail preserved under
        `metadata.detail`);
    (b) re-wrap idempotence: an already-wrapped `data` list passes through
        `to_map/1` byte-identical (the relay/proxy path must not wrap
        twice);
    (c) the JSON-RPC standard codes -32700/-32600/-32601/-32603 carry
        free-form `data` per spec (pass-through; omitted when nil; never
        force-wrapped into an ErrorInfo);
    (d) the HTTP+JSON transport's status mapping
        (`AshA2A.Transport.HTTPJSON.status_for/1`, consumed read-only) is
        TOTAL over the registry: the shipped BEAM's compiled clauses are
        extracted structurally and every registry code is pinned to an
        expected status, and the eight error classes the binding can
        actually produce are each exercised end-to-end over real conns
        with the exact pinned status;
    (e) `AshA2A.ToA2AError` cross-check with real Ash error structs:
        `Ash.Error.Query.NotFound` -> -32001/TASK_NOT_FOUND,
        `Ash.Error.Forbidden`/`Ash.Error.Forbidden.Policy` ->
        -32001/POLICY_FORBIDDEN (the deliberate -32001 collision, the
        ErrorInfo reason is the discriminator), the validation class and
        its caller-input members -> -32602/INVALID_PARAMS, everything
        else -> -32603 ref-only.

  Positive controls per class throughout. No file outside this one is
  touched.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.JSONRPC.Error

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @a2a_domain "a2a-protocol.org"

  # The FULL registry, as shipped in `Error`'s constructors: {code,
  # constructor name, exact message, ErrorInfo reason (nil = the four
  # standard codes with no defined reason)}. -32602 is a standard code that
  # nonetheless carries an ErrorInfo (reason INVALID_PARAMS) per the landed
  # lane-V3 remap.
  @registry [
    {-32_700, :parse_error, "Invalid JSON payload", nil},
    {-32_600, :invalid_request, "Request payload validation error", nil},
    {-32_601, :method_not_found, "Method not found", nil},
    {-32_602, :invalid_params, "Invalid parameters", "INVALID_PARAMS"},
    {-32_603, :internal_error, "Internal error", nil},
    {-32_001, :task_not_found, "Task not found", "TASK_NOT_FOUND"},
    {-32_002, :task_not_cancelable, "Task cannot be canceled", "TASK_NOT_CANCELABLE"},
    {-32_003, :push_notification_not_supported, "Push Notification is not supported",
     "PUSH_NOTIFICATION_NOT_SUPPORTED"},
    {-32_004, :unsupported_operation, "This operation is not supported",
     "UNSUPPORTED_OPERATION"},
    {-32_005, :content_type_not_supported, "Incompatible content types",
     "CONTENT_TYPE_NOT_SUPPORTED"},
    {-32_006, :invalid_agent_response, "Invalid agent response", "INVALID_AGENT_RESPONSE"},
    {-32_007, :authenticated_extended_card_not_configured,
     "Authenticated Extended Card is not configured", "EXTENDED_AGENT_CARD_NOT_CONFIGURED"},
    {-32_008, :extension_support_required, "Extension support is required",
     "EXTENSION_SUPPORT_REQUIRED"},
    {-32_009, :version_not_supported, "Version not supported", "VERSION_NOT_SUPPORTED"}
  ]

  @standard_codes [-32_700, -32_600, -32_601, -32_603]

  # ---------------------------------------------------------------------------
  # Shared setup / helpers
  # ---------------------------------------------------------------------------

  defp start_agent(agent_module) do
    name = :"v1_error_registry_#{System.unique_integer([:positive])}"
    {:ok, pid} = agent_module.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    plug_opts =
      AshA2A.Transport.HTTPJSON.init(agent: name, base_url: "http://127.0.0.1/fixture")

    %{agent: name, pid: pid, plug_opts: plug_opts}
  end

  defp rest_conn(plug_opts, method, path, body) do
    method
    |> Plug.Test.conn(path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> AshA2A.Transport.HTTPJSON.call(plug_opts)
  end

  defp get(plug_opts, path), do: rest_conn(plug_opts, "get", path, nil)

  defp post_json(plug_opts, path, map),
    do: rest_conn(plug_opts, "post", path, Jason.encode!(map))

  defp message_map(text) do
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end

  defp send_message(plug_opts, text) do
    resp = post_json(plug_opts, "/message:send", %{"message" => message_map(text)})
    assert resp.status == 200
    Jason.decode!(resp.resp_body)
  end

  # The exact `google.rpc.ErrorInfo` shape the A2A v1.0 registry (§3.3.2)
  # requires, asserted once here and reused by every court.
  defp assert_error_info(info, reason) do
    assert %{"@type" => @error_info_type, "domain" => @a2a_domain, "reason" => ^reason} = info
    assert reason =~ ~r/^[A-Z][A-Z0-9_]*$/, "reason not UPPER_SNAKE_CASE: #{reason}"
    info
  end

  # ---------------------------------------------------------------------------
  # Court (a): every A2A-range code carries exactly one google.rpc.ErrorInfo
  # ---------------------------------------------------------------------------

  describe "court (a): ErrorInfo serialization over the full registry" do
    test "every A2A-range code (+ -32602) wraps into exactly one ErrorInfo; detail preserved" do
      for {code, ctor, message, reason} <- @registry, reason != nil do
        err = apply(Error, ctor, [nil])
        assert %Error{code: ^code, message: ^message} = err

        wire = Error.to_map(err)

        assert wire["code"] == code
        assert wire["message"] == message

        assert [info] = wire["data"], "expected exactly one ErrorInfo for code #{code}"
        assert_error_info(info, reason)
        # nil data: no metadata key at all.
        refute Map.has_key?(info, "metadata")

        # Positive control per class: a real caller-actionable detail string
        # must survive under metadata.detail.
        detail = "control detail for #{ctor}"
        wire_detail = Error.to_map(apply(Error, ctor, [detail]))
        assert [info_detail] = wire_detail["data"]
        assert %{"metadata" => %{"detail" => ^detail}} = assert_error_info(info_detail, reason)

        # Non-binary detail is preserved under inspect/1, never dropped.
        wire_term = Error.to_map(apply(Error, ctor, [42]))
        assert [%{"metadata" => %{"detail" => "42"}}] = wire_term["data"]
      end
    end

    test "the constructor set exported by the compiled Error module covers the registry 1:1" do
      constructors =
        for {name, 0} <- Error.module_info(:functions),
            name not in [:__struct__, :module_info] do
          assert %Error{} = err = apply(Error, name, [])
          {err.code, name}
        end

      assert constructors |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               @registry |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
             "registry drift: compiled constructors vs @registry: #{inspect(constructors)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Court (b): re-wrap idempotence
  # ---------------------------------------------------------------------------

  describe "court (b): re-wrap idempotence" do
    test "already-wrapped data passes through to_map/1 byte-identical" do
      for {code, ctor, message, reason} <- @registry, reason != nil do
        first = Error.to_map(apply(Error, ctor, ["relay detail"]))

        assert [%{"@type" => @error_info_type, "reason" => ^reason}] = first["data"]

        # An error decoded from the wire (data already the ErrorInfo list)
        # re-serialized must not wrap twice.
        rewrapped = Error.to_map(%Error{code: code, message: message, data: first["data"]})

        assert :erlang.term_to_binary(rewrapped) == :erlang.term_to_binary(first),
               "re-wrap not byte-identical for code #{code}"

        # Idempotence holds under repeated re-serialization too.
        again = Error.to_map(%Error{code: code, message: message, data: rewrapped["data"]})
        assert :erlang.term_to_binary(again) == :erlang.term_to_binary(first)
      end
    end

    test "a list without the ErrorInfo @type is NOT treated as already-wrapped" do
      # Negative control: the @type key is the discriminator, not list-ness.
      wire = Error.to_map(%Error{code: -32_001, message: "Task not found", data: ["plain"]})
      expected_detail = inspect(["plain"])

      assert [%{"@type" => @error_info_type, "reason" => "TASK_NOT_FOUND"}] = wire["data"]
      assert %{"metadata" => %{"detail" => ^expected_detail}} = hd(wire["data"])
    end
  end

  # ---------------------------------------------------------------------------
  # Court (c): standard JSON-RPC codes carry free-form data per spec
  # ---------------------------------------------------------------------------

  describe "court (c): standard codes keep free-form data" do
    test "the four no-reason standard codes pass data through unwrapped and omit nil" do
      for {code, ctor, message, nil} <- @registry do
        # Free-form data passes through as-is.
        wire = Error.to_map(apply(Error, ctor, ["boom"]))
        assert wire == %{"code" => code, "message" => message, "data" => "boom"}

        # Arbitrary terms pass through unchanged.
        term = %{"arbitrary" => [1, 2, 3]}
        assert Error.to_map(apply(Error, ctor, [term]))["data"] == term

        # nil data: the key is omitted entirely.
        assert Error.to_map(apply(Error, ctor, [])) == %{"code" => code, "message" => message}

        # Never force-wrapped into an ErrorInfo.
        refute match?([%{"@type" => @error_info_type} | _], wire["data"])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Court (d): HTTP+JSON status mapping is total over the registry
  # ---------------------------------------------------------------------------

  describe "court (d): HTTP+JSON status mapping totality" do
    # The compiled status_for/1 clauses of the shipped BEAM, extracted
    # structurally (read-only): {matched registry codes, body literal}.
    defp status_for_table do
      forms = abstract_forms(AshA2A.Transport.HTTPJSON)

      clause_groups = for {:function, _, :status_for, 1, clauses} <- forms, do: clauses
      assert clause_groups != [], "status_for/1 not found in the compiled module"

      # -32000 is not one of `Error`'s constructors (the transport mints it
      # for server_busy/rate_limited), but it has its own explicit clause;
      # include it so the -32000 clause doesn't masquerade as the catch-all.
      registry = MapSet.new(Enum.map(@registry, &elem(&1, 0)) ++ [-32_000])

      table =
        Enum.map(hd(clause_groups), fn {:clause, _anno, head, guards, body} ->
          matched =
            (collect_ints(head) ++ Enum.flat_map(guards, &collect_ints/1))
            |> MapSet.new()
            |> MapSet.intersection(registry)

          status =
            case body do
              [{:integer, _, literal}] -> literal
              _ -> :dynamic
            end

          {matched, status}
        end)

      # TOTALITY ANCHOR: exactly one catch-all clause (empty matched set)
      # closes the function over every term, registry codes included.
      catch_alls = Enum.filter(table, fn {matched, _} -> MapSet.size(matched) == 0 end)

      assert length(catch_alls) == 1,
             "expected exactly one catch-all status_for/1 clause, got #{inspect(catch_alls)}"

      table
    end

    # A code may appear in several compiled clauses (explicit + future
    # refinement); every clause that matches it must agree on the status.
    # A code with no explicit clause resolves through the single catch-all.
    defp status_for_lookup(table, code) do
      statuses =
        table
        |> Enum.filter(fn {matched, _} -> code in matched end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.uniq()

      case statuses do
        [status] ->
          status

        [] ->
          # Catch-all: the one clause whose matched set is empty.
          [{_empty, catch_all}] = Enum.filter(table, fn {matched, _} -> matched == MapSet.new() end)
          catch_all

        _conflicting ->
          flunk("conflicting status_for/1 clauses for code #{code}: #{inspect(statuses)}")
      end
    end

    test "every registry code has a compiled status_for/1 clause with the pinned status" do
      table = status_for_table()

      # No clause defers its status to a runtime expression: the whole
      # mapping is compile-time literals.
      for {matched, status} <- table do
        assert status != :dynamic,
               "status_for/1 clause for #{inspect(MapSet.to_list(matched))} has a non-literal body"
      end

      expected = %{
        -32_001 => 404,
        -32_600 => 400,
        -32_601 => 400,
        -32_602 => 400,
        -32_700 => 400,
        -32_002 => 409,
        -32_004 => 400,
        -32_000 => 503,
        # (-32003/-32007/-32008 are NOT catch-all: PushNotificationNotSupported,
        # ExtendedCardNotConfigured and ExtensionSupportRequired are
        # FAILED_PRECONDITION-class per spec §5.4 → HTTP 400, and the binding
        # produces -32003/-32007 on its own paths.)
        -32_603 => 500,
        -32_003 => 400,
        -32_005 => 500,
        -32_006 => 500,
        -32_007 => 400,
        -32_008 => 400,
        -32_009 => 500
      }

      # TOTALITY: every registry code resolves through the compiled table.
      for {code, _, _, _} <- @registry do
        assert status_for_lookup(table, code) == expected[code],
               "code #{code}: compiled status #{inspect(status_for_lookup(table, code))}, " <>
                 "expected #{expected[code]}"
      end

      # No explicit clause matches a code outside the pinned table (the
      # catch-all clause has an empty matched set).
      pinned = MapSet.new(Map.keys(expected))

      for {matched, _status} <- table, MapSet.size(matched) > 0 do
        assert MapSet.subset?(matched, pinned),
               "unexpected explicit clause for #{inspect(MapSet.to_list(matched))}"
      end
    end

    test "each producible error class is answered with its pinned status over the real binding" do
      # -32700 parse error -> 400
      %{plug_opts: opts} = start_agent(AshA2A.V1ErrorRegistry.EchoAgent)

      conn = rest_conn(opts, "post", "/message:send", "definitely not json")
      assert conn.status == 400

      assert Jason.decode!(conn.resp_body) ==
               %{
                 "error" => %{
                   "code" => 400,
                   "status" => "INVALID_ARGUMENT",
                   "message" => "Invalid JSON payload"
                 }
               }

      # -32600 over-cap body -> 400 (a second real binding, tiny body cap)
      %{plug_opts: small_opts} = start_agent(AshA2A.V1ErrorRegistry.EchoAgent)
      small_opts = Map.put(small_opts, :max_body_bytes, 16)

      conn =
        post_json(small_opts, "/message:send", %{
          "message" => message_map("much longer than sixteen bytes")
        })

      assert conn.status == 400

      assert %{"error" => %{"code" => 400, "details" => "Body too large"}} =
               Jason.decode!(conn.resp_body)

      # -32602 invalid params -> 400
      conn = post_json(opts, "/message:send", %{"configuration" => %{}})
      assert conn.status == 400

      assert %{
               "error" => %{
                 "code" => 400,
                 "details" => [%{"@type" => @error_info_type, "reason" => "INVALID_PARAMS"}]
               }
             } = Jason.decode!(conn.resp_body)

      # -32001 task not found -> 404
      conn = get(opts, "/tasks/tsk-does-not-exist")
      assert conn.status == 404

      assert %{
               "error" => %{
                 "code" => 404,
                 "details" => [
                   %{
                     "@type" => @error_info_type,
                     "domain" => @a2a_domain,
                     "reason" => "TASK_NOT_FOUND"
                   }
                 ]
               }
             } = Jason.decode!(conn.resp_body)

      # -32002 cancel a terminal task -> 409 (spec §3.1.5/§5.4 state conflict;
      # TCK CORE-CANCEL-002 pins 409 on the REST binding)
      %{"task" => %{"id" => task_id}} = send_message(opts, "go")
      conn = post_json(opts, "/tasks/#{task_id}:cancel", %{})
      assert conn.status == 409

      assert %{
               "error" => %{
                 "code" => 409,
                 "details" => [%{"@type" => @error_info_type, "reason" => "TASK_NOT_CANCELABLE"}]
               }
             } = Jason.decode!(conn.resp_body)

      # -32004 unsupported operation -> 400 (message:stream streams since the
      # lane G-P TCK closure; the owned-task :subscribe route is the binding's
      # UnsupportedOperation answer, mirroring Transport.Plug.resubscribe/4)
      %{"task" => %{"id" => task_id}} = send_message(opts, "go")
      conn = post_json(opts, "/tasks/#{task_id}:subscribe", %{})
      assert conn.status == 400

      assert %{
               "error" => %{
                 "code" => 400,
                 "details" => [%{"@type" => @error_info_type, "reason" => "UNSUPPORTED_OPERATION"}]
               }
             } = Jason.decode!(conn.resp_body)
    end

    test "server busy is answered -32000 / 503 over the real binding" do
      # A real agent with a zero in-flight cap: admission genuinely refuses.
      %{plug_opts: opts} = start_agent(AshA2A.V1ErrorRegistry.BusyAgent)

      conn = post_json(opts, "/message:send", %{"message" => message_map("go")})
      assert conn.status == 503

      assert %{"error" => %{"code" => 503, "details" => %{"reason" => "server_busy"}}} =
               Jason.decode!(conn.resp_body)
    end

    test "a real transport-to-agent failure is answered -32603 / 500, ref-only" do
      # A genuinely dead agent process: the transport's GenServer call exits
      # and its typed fail-closed conversion (SafeError) drives the real
      # error_for/1 catch-all -> -32603 path.
      %{agent: agent, plug_opts: opts} = start_agent(AshA2A.V1ErrorRegistry.EchoAgent)
      GenServer.stop(agent)

      conn = post_json(opts, "/tasks/tsk-x:cancel", %{})
      assert conn.status == 500

      assert %{"error" => %{"code" => 500, "details" => details}} = Jason.decode!(conn.resp_body)
      assert %{"ref" => ref} = details
      assert is_binary(ref) and ref != ""
    end
  end

  # ---------------------------------------------------------------------------
  # Court (e): ToA2AError cross-check
  # ---------------------------------------------------------------------------

  describe "court (e): ToA2AError cross-check" do
    test "Ash.Error.Query.NotFound maps to -32001 TASK_NOT_FOUND with the record named" do
      error =
        Ash.Error.Query.NotFound.exception(
          primary_key: %{id: "tsk-abc123"},
          resource: AshA2A.V1ErrorRegistry.Echo
        )

      envelope = AshA2A.ToA2AError.to_a2a_error(error, "req-1")

      assert envelope["jsonrpc"] == "2.0"
      assert envelope["id"] == "req-1"
      assert envelope["error"]["code"] == -32_001
      assert envelope["error"]["message"] == "Task not found"

      assert [info] = envelope["error"]["data"]
      assert_error_info(info, "TASK_NOT_FOUND")
      assert %{"detail" => detail} = info["metadata"]
      assert detail =~ "tsk-abc123"
    end

    test "Forbidden (class and direct policy denial) maps to -32001 POLICY_FORBIDDEN" do
      for forbidden <- [%Ash.Error.Forbidden{}, %Ash.Error.Forbidden.Policy{}] do
        envelope = AshA2A.ToA2AError.to_a2a_error(forbidden, 7)

        assert envelope["id"] == 7
        assert envelope["error"]["code"] == -32_001

        assert [info] = envelope["error"]["data"]
        assert_error_info(info, "POLICY_FORBIDDEN")
      end
    end

    test "the same -32001 code is discriminated by the ErrorInfo reason" do
      not_found =
        Ash.Error.Query.NotFound.exception(
          primary_key: %{id: "tsk-1"},
          resource: AshA2A.V1ErrorRegistry.Echo
        )

      not_found_reason =
        not_found
        |> AshA2A.ToA2AError.to_a2a_error(nil)
        |> get_in(["error", "data"])
        |> hd()
        |> Map.fetch!("reason")

      forbidden_reason =
        %Ash.Error.Forbidden{}
        |> AshA2A.ToA2AError.to_a2a_error(nil)
        |> get_in(["error", "data"])
        |> hd()
        |> Map.fetch!("reason")

      assert {not_found_reason, forbidden_reason} == {"TASK_NOT_FOUND", "POLICY_FORBIDDEN"}
    end

    test "validation class and its caller-input members map to -32602 INVALID_PARAMS" do
      invalid_argument =
        Ash.Error.Changes.InvalidArgument.exception(
          field: :status,
          message: "must be one of",
          value: "bogus"
        )

      for validation <- [
            %Ash.Error.Invalid{errors: [invalid_argument]},
            Ash.Error.Invalid.NoSuchInput.exception(input: "bogus_input", inputs: ["status"]),
            invalid_argument
          ] do
        envelope = AshA2A.ToA2AError.to_a2a_error(validation, "v")

        assert envelope["error"]["code"] == -32_602
        assert envelope["error"]["message"] == "Invalid parameters"

        # The free-form message is wrapped by to_map/1 into the ErrorInfo.
        assert [info] = envelope["error"]["data"]
        assert_error_info(info, "INVALID_PARAMS")
        assert %{"detail" => detail} = info["metadata"]
        assert is_binary(detail) and detail != ""
      end
    end

    test "anything else falls back fail-closed to -32603 with an opaque ref" do
      envelope = AshA2A.ToA2AError.to_a2a_error({:git, :shas}, "x")

      assert envelope["error"]["code"] == -32_603
      assert envelope["error"]["message"] == "Internal error"

      assert %{"ref" => ref} = envelope["error"]["data"]
      assert is_binary(ref) and ref != ""

      # -32603 carries no ErrorInfo by design.
      refute match?([%{"@type" => @error_info_type} | _], envelope["error"]["data"])
    end

    test "pre-wrapped ToA2AError envelopes re-serialize byte-identical (courts b+e joint)" do
      not_found =
        Ash.Error.Query.NotFound.exception(
          primary_key: %{id: "tsk-abc"},
          resource: AshA2A.V1ErrorRegistry.Echo
        )

      envelope = AshA2A.ToA2AError.to_a2a_error(not_found, "req-2")
      data = envelope["error"]["data"]

      rewrapped = Error.to_map(%Error{code: -32_001, message: "Task not found", data: data})
      assert :erlang.term_to_binary(rewrapped["data"]) == :erlang.term_to_binary(data)
    end
  end

  # ---------------------------------------------------------------------------
  # BEAM abstract-code helpers (read-only structural introspection)
  # ---------------------------------------------------------------------------

  defp abstract_forms(module) do
    path = :code.which(module)
    assert is_list(path), "no compiled BEAM found for #{inspect(module)}"

    {:ok, {_module, [{:abstract_code, {:raw_abstract_v1, forms}}]}} =
      :beam_lib.chunks(path, [:abstract_code])

    forms
  end

  defp collect_ints(ast) when is_list(ast), do: Enum.flat_map(ast, &collect_ints/1)
  defp collect_ints({:integer, _anno, n}) when is_integer(n), do: [n]

  defp collect_ints(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.flat_map(&collect_ints/1)

  defp collect_ints(_other), do: []
end
