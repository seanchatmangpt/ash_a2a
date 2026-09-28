defmodule AshA2A.Telemetry.ObsHardeningTest do
  @moduledoc """
  OBS-01/02/03/05/12 qualification for the observability egress, Chicago
  style: real `AshA2A.Dispatcher.dispatch/6`, the real application-attached
  `AshA2A.Telemetry.OcelForwarder` handlers, a real Bandit HTTP ingest, real
  `Req` POSTs and real `:telemetry` handlers. No mocks.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  import ExUnit.CaptureLog
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Telemetry.{OcelForwarder, Redact}

  defmodule Ingest do
    @moduledoc false
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      %{"events" => events} = conn.body_params
      {status, owner} = Agent.get(__MODULE__.Store, & &1)
      send(owner, {:ingested, events})
      Plug.Conn.send_resp(conn, status, "secret-response-body token=abc123")
    end
  end

  setup do
    parent = self()

    start_supervised!(%{
      id: Ingest.Store,
      start: {Agent, :start_link, [fn -> {201, parent} end, [name: Ingest.Store]]}
    })

    port = Enum.random(23_000..23_999)
    start_supervised!({Bandit, plug: Ingest, port: port, ip: {127, 0, 0, 1}})

    previous =
      for key <- [:ocel_ingest_url, :ocel_log_interval_ms, :ocel_task_supervisor, :ocel_log_body],
          do: {key, Application.get_env(:ash_a2a, key)}

    :ok = OcelForwarder.attach!()

    Application.put_env(
      :ash_a2a,
      :ocel_ingest_url,
      "http://obsuser:s3cr3t-token@127.0.0.1:#{port}"
    )

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:ash_a2a, key),
          else: Application.put_env(:ash_a2a, key, value)
      end
    end)

    %{port: port}
  end

  defp set_ingest_status(status), do: Agent.update(Ingest.Store, fn {_s, o} -> {status, o} end)

  defp probe(events) do
    ref = make_ref()
    parent = self()
    id = {__MODULE__, ref}

    :ok =
      :telemetry.attach_many(
        id,
        events,
        fn event, measurements, metadata, _ ->
          send(parent, {ref, event, measurements, metadata, Logger.metadata()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    ref
  end

  defp emit_dispatch_stop(extra \\ %{}) do
    :telemetry.execute(
      [:ash_a2a, :dispatch, :stop],
      %{duration: 1_000},
      Map.merge(%{resource_or_domain: AshA2A.Test.Fixture.Item, skill_name: "obs_probe"}, extra)
    )
  end

  describe "OBS-01: dispatch stop metadata carries a redacted error" do
    test "an unknown-skill refusal reaches telemetry as a data-free summary; the reply is unchanged" do
      ref = probe([[:ash_a2a, :dispatch, :stop]])
      Application.delete_env(:ash_a2a, :ocel_ingest_url)

      reply =
        AshA2A.Dispatcher.dispatch(
          "no_such_skill_secret_input",
          data_message(%{"password" => "hunter2"}),
          AshA2A.Test.Fixture.Item
        )

      assert {:error, {:skill_lookup, raw}} = reply
      assert inspect(raw) =~ "no_such_skill_secret_input"

      assert_receive {^ref, [:ash_a2a, :dispatch, :stop], _m, meta, _md}, 1_000
      assert meta.stage == :skill_lookup
      assert %{kind: kind} = meta.error
      assert is_atom(kind)
      refute inspect(meta.error) =~ "no_such_skill_secret_input"
    end

    test "raw error terms return only under the explicit :telemetry_raw_errors opt-in" do
      Application.put_env(:ash_a2a, :telemetry_raw_errors, true)
      on_exit(fn -> Application.delete_env(:ash_a2a, :telemetry_raw_errors) end)
      assert Redact.telemetry_error({:x, "raw"}) == {:x, "raw"}
      Application.delete_env(:ash_a2a, :telemetry_raw_errors)
      assert Redact.telemetry_error({:x, "raw"}) == %{kind: :x}
    end

    test "the OCEL body error attribute is the kind only, even for a raw error term" do
      emit_dispatch_stop(%{stage: :execution, error: %{code: :boom, detail: "token=abc123"}})
      assert_receive {:ingested, [event]}, 2_000
      assert event["attributes"]["error"] == "boom"
      refute Jason.encode!(event) =~ "abc123"
    end
  end

  describe "OBS-12: correlation" do
    test "command_id/task_id/traceparent reach dispatch start metadata and Logger metadata, then are restored" do
      ref = probe([[:ash_a2a, :dispatch, :start]])
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
      tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
      msg = data_message(%{}, %{metadata: %{"traceparent" => tp}})
      Logger.metadata(ash_a2a_task_id: "outer")

      AshA2A.Dispatcher.dispatch("no_such_skill", msg, AshA2A.Test.Fixture.Item, [], nil,
        command_id: "cmd-1",
        task_id: "task-1"
      )

      assert_receive {^ref, [:ash_a2a, :dispatch, :start], _m, meta, logger_md}, 1_000
      assert meta.command_id == "cmd-1"
      assert meta.task_id == "task-1"
      assert meta.traceparent == tp
      assert logger_md[:ash_a2a_traceparent] == tp
      assert logger_md[:ash_a2a_command_id] == "cmd-1"
      # restored after the dispatch
      assert Logger.metadata()[:ash_a2a_task_id] == "outer"
      assert Logger.metadata()[:ash_a2a_traceparent] == nil
      Logger.metadata(ash_a2a_task_id: nil)
    end

    test "a malformed traceparent from the wire is not admitted" do
      msg = data_message(%{}, %{metadata: %{"traceparent" => "not-a-traceparent\nINJECT"}})
      assert AshA2A.Dispatcher.correlation_meta(msg, []) == %{}
    end

    test "oversized correlation ids (bare or identity-wrapped) are not admitted" do
      msg = data_message(%{}, %{})
      big = String.duplicate("a", 257)

      assert AshA2A.Dispatcher.correlation_meta(msg,
               command_id: %{value: big},
               task_id: big
             ) == %{}

      assert AshA2A.Dispatcher.correlation_meta(msg, command_id: %{value: "c-1"}) ==
               %{command_id: "c-1"}
    end
  end

  describe "OBS-02/03: delivery accounting and egress hygiene" do
    test "a 2xx delivery increments delivered_count and emits :delivered with a credential-free endpoint",
         %{port: port} do
      ref = probe([[:ash_a2a, :ocel, :delivered]])
      before = OcelForwarder.delivered_count()
      emit_dispatch_stop()
      assert_receive {^ref, _, %{duration: d}, %{endpoint: endpoint}, _}, 2_000
      assert is_integer(d)
      assert endpoint == "http://127.0.0.1:#{port}"
      assert OcelForwarder.delivered_count() == before + 1
    end

    test "a 503 is counted, emitted as :failed, logged without credentials or body, and the log is rate-limited" do
      set_ingest_status(503)
      ref = probe([[:ash_a2a, :ocel, :failed]])
      Logger.metadata(ash_a2a_command_id: "corr-1")
      on_exit(fn -> Logger.metadata(ash_a2a_command_id: nil) end)

      Application.put_env(:ash_a2a, :ocel_log_interval_ms, 0)
      before = OcelForwarder.failed_count()

      log =
        capture_log(fn ->
          emit_dispatch_stop()
          assert_receive {^ref, _, %{duration: _}, meta, task_md}, 2_000
          assert meta.status == 503
          assert meta.reason == :non_2xx
          refute meta.endpoint =~ "s3cr3t"
          # OBS-12: the POST task inherited the emitter's Logger metadata.
          assert task_md[:ash_a2a_command_id] == "corr-1"
          Process.sleep(50)
        end)

      assert OcelForwarder.failed_count() == before + 1
      assert log =~ "non-2xx status 503"
      refute log =~ "s3cr3t-token"
      refute log =~ "secret-response-body"

      # Rate limit: a long interval suppresses the next three warnings...
      Application.put_env(:ash_a2a, :ocel_log_interval_ms, 3_600_000)

      suppressed_log =
        capture_log(fn ->
          for _ <- 1..3, do: emit_dispatch_stop()
          for _ <- 1..3, do: assert_receive({^ref, _, _, _, _}, 2_000)
          Process.sleep(50)
        end)

      refute suppressed_log =~ "OcelForwarder"
      assert OcelForwarder.failed_count() == before + 4

      # ...and the next emitted warning reports how many were suppressed.
      Application.put_env(:ash_a2a, :ocel_log_interval_ms, 0)

      next_log =
        capture_log(fn ->
          emit_dispatch_stop()
          assert_receive {^ref, _, _, _, _}, 2_000
          Process.sleep(50)
        end)

      assert next_log =~ "(3 similar warnings suppressed)"
    end

    test "a transport failure (connection refused) is counted and emitted as :failed" do
      ref = probe([[:ash_a2a, :ocel, :failed]])
      Application.put_env(:ash_a2a, :ocel_ingest_url, "http://u:p@127.0.0.1:1")
      Application.put_env(:ash_a2a, :ocel_log_interval_ms, 3_600_000)
      before = OcelForwarder.failed_count()

      capture_log(fn ->
        emit_dispatch_stop()
        assert_receive {^ref, _, _, %{status: nil, reason: reason, endpoint: ep}, _}, 5_000
        assert is_atom(reason)
        assert ep == "http://127.0.0.1:1"
      end)

      assert OcelForwarder.failed_count() == before + 1
    end

    test "shed metadata carries a sanitized :endpoint, never the raw :url" do
      ref = probe([[:ash_a2a, :ocel, :shed]])
      Application.put_env(:ash_a2a, :ocel_task_supervisor, :no_such_obs_task_supervisor)
      emit_dispatch_stop()
      assert_receive {^ref, _, %{count: 1}, meta, _}, 1_000
      refute Map.has_key?(meta, :url)
      refute meta.endpoint =~ "s3cr3t"
    end
  end

  describe "OBS-05: dispatch exceptions reach OCEL" do
    test "the forwarder is attached to [:ash_a2a, :dispatch, :exception]" do
      assert Enum.any?(
               :telemetry.list_handlers([:ash_a2a, :dispatch, :exception]),
               &(&1.id == {OcelForwarder, :dispatch_exception})
             )
    end

    test "an exception event is forwarded as <type>.exception with a redacted error code and no stacktrace" do
      :telemetry.execute(
        [:ash_a2a, :dispatch, :exception],
        %{duration: 42},
        %{
          resource_or_domain: AshA2A.Test.Fixture.Item,
          skill_name: "obs_probe",
          kind: :error,
          reason: %RuntimeError{message: "token=abc123"},
          stacktrace: [{__MODULE__, :f, 0, [file: ~c"secret_path.ex", line: 1]}]
        }
      )

      assert_receive {:ingested, [event]}, 2_000
      assert String.ends_with?(event["event_type"], ".obs_probe.exception")
      assert event["attributes"]["kind"] == "error"
      assert event["attributes"]["error_code"] == "exception:RuntimeError"
      assert event["attributes"]["duration_native"] == "42"
      body = Jason.encode!(event)
      refute body =~ "abc123"
      refute body =~ "secret_path"
    end
  end
end
