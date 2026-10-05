defmodule AshA2A.Chicago.Bench.B11Wire.WidgetDomain do
  @moduledoc "Domain for `AshA2A.Chicago.Bench.B11Wire.Widget`."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Bench.B11Wire.Widget)
  end
end

defmodule AshA2A.Chicago.Bench.B11Wire.Widget do
  @moduledoc """
  Real ETS-backed Ash resource with one consequence-bearing capability
  (`:create_widget`, `:change`) and one streaming observation
  (`:list_widgets`).
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Bench.B11Wire.WidgetDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, create: [:label]])
  end

  a2a do
    skill(:create_widget, :create)
    skill(:list_widgets, :read)
  end
end

defmodule AshA2A.Chicago.Bench.B11Wire.WidgetAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over `Widget`."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Chicago.Bench.B11Wire.Widget,
    name: "chicago_b11_wire_agent"
end

defmodule AshA2A.Chicago.Bench.B11Wire.Endpoint do
  @moduledoc """
  Real Plug endpoint: real `AshA2A.Protocol.Plug.Auth` (one bearer token,
  resolved to the bench principal) then the real `AshA2A.A2ATransport.Plug`.
  """

  @behaviour Plug

  @impl Plug
  def init(opts) do
    agent = Keyword.fetch!(opts, :agent)
    token = Keyword.fetch!(opts, :token)

    auth =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
        verify: fn "bearer_auth", ^token, _conn ->
          # The verified identity is the PRINCIPAL STRING: `Grant.authorize/3`
          # looks the standing grant up under `Identity.principal(identity)`
          # (grant issued for `Identity.principal("chicago-b11-principal")`),
          # so the identity the wire carries must be exactly that value.
          {:ok, "chicago-b11-principal"}
        end
      )

    %{
      auth: auth,
      a2a:
        AshA2A.A2ATransport.Plug.init(
          agent: agent,
          base_url: "http://127.0.0.1/b11",
          transport: Keyword.fetch!(opts, :transport)
        )
    }
  end

  @impl Plug
  def call(conn, %{auth: auth, a2a: a2a}) do
    conn = AshA2A.Protocol.Plug.Auth.call(conn, auth)

    if conn.halted, do: conn, else: AshA2A.A2ATransport.Plug.call(conn, a2a)
  end
end

defmodule AshA2A.Chicago.Bench.B11Wire do
  @moduledoc """
  Wire-path benchmark `SA2A-B11` -- the HTTP/SSE category B1-B10 do not have.

  Closes the gap the v1.0 performance notes recorded ("the suite has no HTTP /
  SSE / streaming bench category"): every iteration sends real HTTP requests
  over a real local Bandit listener to the real `AshA2A.A2ATransport.Plug`
  fronting a real `AshA2A.Agent` GenServer over a real ETS-backed Ash resource,
  with a real `AshA2A.Protocol.Plug.Auth` bearer pipeline. Two scenarios
  reported separately:

    * `send` -- an authenticated JSON-RPC `message/send` round trip whose
      dispatch carries a `:change` consequence all the way through the real
      authority decision (`AshA2A.Authority.Grant.authorize/3`), the real sole
      DO boundary (`AshA2A.CommandBus`), and a committed receipt (the same
      dispatch path SA2A-B5 times, entered through the wire instead of in
      process).
    * `stream` -- an authenticated `message/stream` whose read skill streams
      three seeded rows as three SSE artifact frames; the sample is the full
      drain wall time of the real `text/event-stream` body.

  The timed region is the whole wire round trip (request write -> response
  fully received, or SSE body fully drained), plus the independent post-state
  read (`Ash.read!/2` on the resource, never the HTTP response's own claim).

  ## Invariants (§84), every sample

  `send`: HTTP 200, wire task state `TASK_STATE_COMPLETED`, authority decision
  `:granted`, `brce.admission` `:admitted`, `brce.commit` `:committed`,
  prepared receipt precedes actuation, the created row is visible to the
  independent reader, and the bearer token appears in no response body.

  `stream`: HTTP 200, `text/event-stream` content type, every SSE frame a
  decodable JSON-RPC success envelope, at least three artifact-update frames
  carrying the seeded rows, a final terminal `TASK_STATE_COMPLETED` frame, and
  the bearer token appears in no response body.

  Bandit is resolved at runtime (a test-environment dependency): without a
  loadable `Bandit`/`ThousandIsland` the benchmark reports `{:blocked, ...}`
  instead of pretending to measure.
  """

  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago.Bench
  alias AshA2A.Chicago.Bench.{B5Authority, Timeline}
  alias AshA2A.Chicago.Bench.B11Wire.{Endpoint, Widget, WidgetAgent}
  alias AshA2A.Identity

  require Ash.Query

  @id "SA2A-B11"
  @scenarios ["send", "stream"]
  @selector "create_widget"
  @stream_selector "list_widgets"
  @seed_rows 3
  @principal "chicago-b11-principal"

  @first_frame_key :"$ash_a2a_chicago_bench_b11_first_frame"

  @grant [:ash_a2a, :authority, :decision]
  @admission [:ash_a2a, :command_bus, :admission]
  @claim [:ash_a2a, :command_bus, :claim]
  @prepare [:ash_a2a, :command_bus, :prepare]
  @actuate_start [:ash_a2a, :command_bus, :actuate, :start]
  @actuate_stop [:ash_a2a, :command_bus, :actuate, :stop]
  @commit [:ash_a2a, :command_bus, :commit]

  @spec id() :: String.t()
  def id, do: @id

  @spec scenarios() :: [String.t()]
  def scenarios, do: @scenarios

  @doc "The canonical capability id the `send` scenario dispatches against."
  @spec capability() :: String.t()
  def capability do
    {:ok, skill} = AshA2A.Info.skill(Widget, @selector)
    skill.id
  end

  @doc "Telemetry events the benchmark times (the SA2A-B5 dispatch-path set)."
  @spec events() :: [[atom()]]
  def events, do: B5Authority.events()

  @doc """
  Runs the benchmark. Options: `:iterations`, `:warmup`, `:scenarios` (subset
  of `scenarios/0`).
  """
  @spec run(keyword()) :: {:ok, map()} | {:blocked, String.t()}
  def run(opts \\ []) do
    with {:ok, env} <- setup(opts) do
      scenarios = Keyword.get(opts, :scenarios, @scenarios)
      ref = Timeline.attach(events())

      try do
        handlers = length(:telemetry.list_handlers(@commit))

        measured =
          Bench.measure(
            fn _phase, _i -> Enum.map(scenarios, &scenario(&1, env, ref)) end,
            opts
          )

        send_phases = get_in(measured, ["by_case", "send", "phases_us"]) || %{}
        stream_case = get_in(measured, ["by_case", "stream", "latency_us"]) || %{}

        {:ok,
         Map.merge(measured, %{
           "benchmark" => "B11 wire path",
           "rfc_sections" => ["§84"],
           "sut" => %{
             "listener" => "Bandit on 127.0.0.1 (ephemeral port)",
             "plug" => inspect(AshA2A.A2ATransport.Plug),
             "auth" => inspect(AshA2A.Protocol.Plug.Auth) <> " bearer -> principal identity",
             "agent" => inspect(WidgetAgent),
             "resource" => inspect(Widget),
             "client" => "Req over loopback HTTP",
             "authority_broker" => inspect(InMemory)
           },
           "fixture" => %{
             "resource" => inspect(Widget),
             "capability" => capability(),
             "streamed_rows" => @seed_rows,
             "scenarios" => scenarios
           },
           "scenarios_reported_separately" => true,
           "evidence_handlers_attached" => handlers,
           "highlights" => %{
             "send_end_to_end_p50_us" => get_in(send_phases, ["end_to_end", "p50"]),
             "send_end_to_end_p99_us" => get_in(send_phases, ["end_to_end", "p99"]),
             "send_authority_decision_p50_us" =>
               get_in(send_phases, ["authority_decision", "p50"]),
             "stream_drain_p50_us" => stream_case["p50"],
             "stream_drain_p99_us" => stream_case["p99"]
           }
         })}
      after
        Timeline.detach(ref)
        teardown(env)
      end
    end
  end

  @doc """
  Starts the real collaborators: a named in-memory authority broker wired into
  `:ash_a2a` application env, a standing grant for the wire principal, the
  real agent GenServer, and a real Bandit listener on an ephemeral loopback
  port. Returns `{:ok, env}` or `{:blocked, detail}` when Bandit is absent.
  """
  @spec setup(keyword()) :: {:ok, map()} | {:blocked, String.t()}
  def setup(_opts \\ []) do
    unless bandit_available?() do
      {:blocked,
       "Bandit/ThousandIsland not loadable in this environment " <>
         "(the mix.exs dependency is `only: :test`); run with MIX_ENV=test"}
    else
      unique = System.unique_integer([:positive])
      broker_name = Module.concat(__MODULE__, "Broker#{unique}")
      agent_name = Module.concat(__MODULE__, "Agent#{unique}")
      transport_name = Module.concat(__MODULE__, "Transport#{unique}")

      previous_broker = Application.get_env(:ash_a2a, :authority_broker)
      Application.put_env(:ash_a2a, :authority_broker, {InMemory, [name: broker_name]})

      {:ok, broker_pid} = InMemory.start_link(name: broker_name)
      {:ok, agent_pid} = WidgetAgent.start_link(name: agent_name)
      {:ok, transport_pid} = AshA2A.A2ATransport.start_link(name: transport_name)

      token = "b11-bearer-#{unique}"
      {:ok, _authority} = Grant.grant(Identity.principal(@principal), capability())

      # Three real seeded rows so every `stream` iteration drains exactly the
      # artifact frames the invariant expects, from the very first warmup.
      for i <- 1..@seed_rows do
        Ash.Seed.seed!(Widget, %{label: "chicago-b11-seed-#{unique}-#{i}"})
      end

      {:ok, listener} = start_listener(agent: agent_name, token: token, transport: transport_name)

      {:ok,
       %{
         previous_broker: previous_broker,
         broker_pid: broker_pid,
         agent_pid: agent_pid,
         transport_pid: transport_pid,
         listener_pid: listener.pid,
         url: listener.url,
         token: token,
         principal: @principal
       }}
    end
  end

  @doc "Stops the collaborators `setup/1` started and restores `:authority_broker` env."
  @spec teardown(map()) :: :ok
  def teardown(env) do
    stop_listener(%{pid: env.listener_pid})
    restore_broker_env(env.previous_broker)

    for pid <- [env.agent_pid, env.transport_pid, env.broker_pid], Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end

    :ok
  end

  defp restore_broker_env(nil), do: Application.delete_env(:ash_a2a, :authority_broker)
  defp restore_broker_env(value), do: Application.put_env(:ash_a2a, :authority_broker, value)

  @doc """
  Runs one scenario and returns its timed, invariant-checked sample. `ref` is
  an attached `AshA2A.Chicago.Bench.Timeline` over `events/0`.
  """
  @spec scenario(String.t(), map(), reference()) :: Bench.sample()
  def scenario("send", env, ref), do: timed_send(env, ref)
  def scenario("stream", env, ref), do: timed_stream(env, ref)

  # -- send: authenticated message/send over the wire --------------------------

  defp timed_send(env, ref) do
    unique = Integer.to_string(System.unique_integer([:positive]))
    label = "chicago-b11-send-#{unique}"
    _ = Timeline.drain(ref)

    t0 = System.monotonic_time(:microsecond)

    resp =
      Req.post!(env.url,
        json: envelope("message/send", %{"message" => message(%{"label" => label}, @selector)}),
        headers: headers(env),
        retry: false
      )

    returned = System.monotonic_time(:microsecond)
    present? = label_present?(label)
    finished = System.monotonic_time(:microsecond)
    timeline = Timeline.drain(ref)

    %{
      case: "send",
      duration_us: finished - t0,
      outcome: send_outcome(resp),
      phases: send_phases(timeline, t0, returned, finished),
      invariant:
        send_invariant(resp, timeline, present?, credential_free?(resp.body, env.token))
    }
  end

  defp send_outcome(resp) do
    case wire_state(resp) do
      "TASK_STATE_COMPLETED" -> "committed"
      nil -> "refused"
      other -> "state:#{other}"
    end
  end

  defp send_phases(timeline, t0, returned, finished) do
    grant = Timeline.first(timeline, @grant)
    admission = Timeline.first(timeline, @admission)

    %{
      "authority_decision" => Timeline.gap(t0, grant),
      "bus_admission" => Timeline.gap(grant, admission),
      "prepared_receipt_durability" =>
        Timeline.gap(Timeline.first(timeline, @claim), Timeline.first(timeline, @prepare)),
      "actuator" =>
        Timeline.gap(
          Timeline.first(timeline, @actuate_start),
          Timeline.first(timeline, @actuate_stop)
        ),
      "final_receipt" =>
        Timeline.gap(Timeline.first(timeline, @actuate_stop), Timeline.first(timeline, @commit)),
      "wire_round_trip" => returned - t0,
      "end_to_end" => finished - t0
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp send_invariant(resp, timeline, present?, credential_free?) do
    checks = [
      {resp.status == 200, "HTTP status #{resp.status}"},
      {wire_state(resp) == "TASK_STATE_COMPLETED",
       "wire task state #{inspect(wire_state(resp))}, not TASK_STATE_COMPLETED"},
      {outcome_of(timeline, @grant) == :granted,
       "authority.decision outcome #{inspect(outcome_of(timeline, @grant))}"},
      {outcome_of(timeline, @admission) == :admitted,
       "brce.admission outcome #{inspect(outcome_of(timeline, @admission))}"},
      {outcome_of(timeline, @prepare) == :prepared,
       "brce.prepare outcome #{inspect(outcome_of(timeline, @prepare))}"},
      {before?(timeline, @prepare, @actuate_start), "prepared receipt did not precede actuation"},
      {outcome_of(timeline, @actuate_stop) == :ok,
       "actuation outcome #{inspect(outcome_of(timeline, @actuate_stop))}"},
      {outcome_of(timeline, @commit) == :committed,
       "brce.commit outcome #{inspect(outcome_of(timeline, @commit))}"},
      {present?, "independent reader does not see the created row"},
      {credential_free?, "the bearer token leaked into a response body"}
    ]

    first_failure(checks)
  end

  # -- stream: authenticated message/stream, full SSE drain --------------------

  defp timed_stream(env, ref) do
    _ = Timeline.drain(ref)

    t0 = System.monotonic_time(:microsecond)
    Process.put(@first_frame_key, nil)

    resp =
      Req.post!(env.url,
        json:
          envelope(
            "message/stream",
            %{"message" => message(%{"stream" => true}, @stream_selector)}
          ),
        headers: headers(env),
        retry: false,
        receive_timeout: 30_000,
        into: fn {:data, data}, {req, resp} ->
          if is_nil(Process.get(@first_frame_key)),
            do: Process.put(@first_frame_key, System.monotonic_time(:microsecond))

          {:cont, {req, %{resp | body: [data | List.wrap(resp.body)]}}}
        end
      )

    finished = System.monotonic_time(:microsecond)
    first_frame_us = Process.get(@first_frame_key)
    body = resp.body |> Enum.reverse() |> IO.iodata_to_binary()

    %{
      case: "stream",
      duration_us: finished - t0,
      outcome: stream_outcome(resp, body),
      phases: stream_phases(t0, first_frame_us, finished),
      invariant: stream_invariant(resp, body, env.token)
    }
  end

  defp stream_phases(t0, first_frame_us, finished) do
    %{"time_to_first_frame" => first_frame_us && first_frame_us - t0, "end_to_end" => finished - t0}
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp stream_outcome(resp, body) do
    frames = sse_frames(body)

    cond do
      resp.status != 200 -> "http:#{resp.status}"
      frames == [] -> "no_frames"
      true -> "streamed:#{length(frames)}_frames"
    end
  end

  defp stream_invariant(resp, body, token) do
    frames = sse_frames(body)
    artifacts = Enum.count(frames, &Map.has_key?(&1, "artifactUpdate"))
    terminal? = Enum.any?(frames, &terminal_state?/1)

    checks = [
      {resp.status == 200, "HTTP status #{resp.status}"},
      {content_type_streaming?(resp), "content type #{inspect(content_type(resp))}, not text/event-stream"},
      {frames != [] and Enum.all?(frames, &is_map/1),
       "unparseable or empty SSE frame stream (#{length(frames)} frames)"},
      {artifacts >= @seed_rows,
       "#{artifacts} artifact-update frames, expected at least #{@seed_rows} streamed rows"},
      {terminal?, "no terminal TASK_STATE_COMPLETED frame in the stream"},
      {credential_free?(body, token), "the bearer token leaked into the SSE body"}
    ]

    first_failure(checks)
  end

  # -- wire helpers --------------------------------------------------------------

  defp envelope(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }
  end

  defp message(input, selector) do
    AshA2A.Protocol.JSON.encode!(
      %{AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(input)]) |
        metadata: %{"skill" => selector}}
    )
  end

  defp headers(env), do: [{"authorization", "Bearer " <> env.token}]

  defp wire_state(resp), do: get_in(resp.body, ["result", "task", "status", "state"])

  defp content_type(resp),
    do: resp |> Req.Response.get_header("content-type") |> List.first()

  defp content_type_streaming?(resp) do
    case content_type(resp) do
      nil -> false
      type -> String.starts_with?(String.downcase(type), "text/event-stream")
    end
  end

  defp sse_frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json ->
        case Jason.decode(json) do
          {:ok, %{"result" => result}} when is_map(result) -> result
          _ -> :error
        end
      end)
    end)
  end

  defp terminal_state?(%{"statusUpdate" => %{"status" => %{"state" => state}}}),
    do: state == "TASK_STATE_COMPLETED"

  defp terminal_state?(%{"task" => %{"status" => %{"state" => state}}}),
    do: state == "TASK_STATE_COMPLETED"

  defp terminal_state?(_), do: false

  defp credential_free?(body, token) do
    text =
      cond do
        is_binary(body) -> body
        is_map(body) -> Jason.encode!(body)
        true -> inspect(body)
      end

    not (text =~ token)
  end

  @doc "Independent post-state reader: is a Widget row with `label` visible?"
  @spec label_present?(String.t()) :: boolean()
  def label_present?(label) do
    Widget
    |> Ash.Query.filter(label == ^label)
    |> Ash.read!()
    |> Enum.any?()
  end

  defp outcome_of(timeline, event) do
    case Timeline.first(timeline, event) do
      nil -> nil
      entry -> entry.metadata[:outcome]
    end
  end

  defp before?(timeline, a, b) do
    case {Timeline.index(timeline, a), Timeline.index(timeline, b)} do
      {ia, ib} when is_integer(ia) and is_integer(ib) -> ia < ib
      _ -> false
    end
  end

  defp first_failure(checks) do
    case Enum.find(checks, fn {ok?, _detail} -> ok? != true end) do
      nil -> :ok
      {_, detail} -> {:error, detail}
    end
  end

  # -- Bandit listener (runtime-resolved test dependency) ------------------------

  @doc "True when a real Bandit listener can be started in this runtime."
  @spec bandit_available?() :: boolean()
  def bandit_available?, do: Code.ensure_loaded?(bandit()) and Code.ensure_loaded?(island())

  defp start_listener(endpoint_opts) do
    bandit_opts = [
      plug: {Endpoint, endpoint_opts},
      ip: {127, 0, 0, 1},
      port: 0,
      startup_log: false
    ]

    with {:ok, pid} <- apply(bandit(), :start_link, [bandit_opts]),
         {:ok, {_ip, port}} <- apply(island(), :listener_info, [pid]) do
      {:ok, %{pid: pid, url: "http://127.0.0.1:#{port}"}}
    end
  end

  defp stop_listener(%{pid: pid}) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal)
    :ok
  end

  defp bandit, do: Module.concat([Bandit])
  defp island, do: Module.concat([ThousandIsland])
end
