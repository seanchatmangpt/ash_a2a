defmodule AshA2A.Chicago.Bench.B5Authority do
  @moduledoc """
  RFC-SA2A-002 §89 benchmark `SA2A-B5` -- authority and BRCE latency.

  Every iteration runs five scenarios through the real dispatch-path authority
  decision (`AshA2A.Authority.Grant.authorize/3` over a real
  `AshA2A.Authority.Broker.InMemory` process) and the real sole DO boundary
  (`AshA2A.CommandBus.run/4`) against the real
  `AshA2A.Chicago.Fixtures.BenchHarness.Ledger` ETS resource with a real
  `AshA2A.ReceiptStore.Memory`, reported separately (§89):

    * `authorized` -- a standing grant; prepared receipt, actuation, final receipt
    * `refused` -- no grant at all
    * `expired` -- a grant whose `expires_at` has passed
    * `revoked` -- a grant issued then revoked through the broker
    * `broker_unavailable` -- the broker process was really stopped (environment
      fault injection around a real component, §10)

  Grant issuance / revocation / broker shutdown is setup and is excluded from
  the timed region. The timed region is: authority decision -> command ->
  CommandBus -> independent post-state read (`Ash.read!/2` filtered on the
  command's label, never the actuator's return value).

  ## Phases (from real boundary telemetry)

  | §89 measure                         | phase                          |
  |-------------------------------------|--------------------------------|
  | authority decision latency          | `authority_decision` (t0 -> `authority.decision`) |
  | DO-boundary admission               | `bus_admission` (grant -> `brce.admission`)    |
  | prepared-receipt durability latency | `prepared_receipt_durability` (`brce.claim` -> `brce.prepare`, synced outbox write) |
  | actuator latency                    | `actuator` (`brce.actuate.start` -> `.stop`)   |
  | final-receipt latency               | `final_receipt` (`brce.actuate.stop` -> `brce.commit`) |
  | independent postcondition latency   | `independent_postcondition` (bus return -> read done) |
  | end-to-end consequence latency      | `end_to_end` (t0 -> read done) |

  ## Invariants (§84), every sample

  `authorized`: grant granted, admission admitted, prepared receipt precedes
  actuation, actuation ok, receipt committed, row visible to the independent
  reader. Every refusal scenario: grant refused, bus refused with
  `:authority_required`, no claim / prepare / actuation, no row.
  """

  alias AshA2A.{Command, CommandBus, Identity}
  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago.Bench
  alias AshA2A.Chicago.Bench.Timeline
  alias AshA2A.Chicago.Fixtures.BenchHarness.Ledger

  require Ash.Query

  @id "SA2A-B5"
  @scenarios ["authorized", "refused", "expired", "revoked", "broker_unavailable"]
  @capability "AshA2A.Chicago.Fixtures.BenchHarness.Ledger.create"

  @grant [:ash_a2a, :authority, :decision]
  @target [:ash_a2a, :command_bus, :target]
  @admission [:ash_a2a, :command_bus, :admission]
  @kill_switch [:ash_a2a, :command_bus, :kill_switch]
  @claim [:ash_a2a, :command_bus, :claim]
  @prepare [:ash_a2a, :command_bus, :prepare]
  @actuate_start [:ash_a2a, :command_bus, :actuate, :start]
  @actuate_stop [:ash_a2a, :command_bus, :actuate, :stop]
  @commit [:ash_a2a, :command_bus, :commit]

  @spec id() :: String.t()
  def id, do: @id

  @spec scenarios() :: [String.t()]
  def scenarios, do: @scenarios

  @spec capability() :: String.t()
  def capability, do: @capability

  @doc """
  The ONE grant-decision telemetry event `AshA2A.Authority.Grant.authorize/3`
  emits (shared with the CHI-REAL and SA2A-AUTH courts); B5 times and checks
  its `:outcome`.
  """
  @spec grant_event() :: [atom()]
  def grant_event, do: @grant

  @doc "Telemetry events the benchmark times."
  @spec events() :: [[atom()]]
  def events,
    do: [
      @grant,
      @target,
      @admission,
      @kill_switch,
      @claim,
      @prepare,
      @actuate_start,
      @actuate_stop,
      @commit
    ]

  @doc """
  Runs the benchmark. Options: `:iterations`, `:warmup`, `:scenarios` (subset
  of `scenarios/0`).
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) do
    scenarios = Keyword.get(opts, :scenarios, @scenarios)
    env = setup()
    ref = Timeline.attach(events())

    try do
      handlers = length(:telemetry.list_handlers(@commit))

      measured =
        Bench.measure(
          fn _phase, _i -> Enum.map(scenarios, &scenario(&1, env, ref)) end,
          opts
        )

      authorized = get_in(measured, ["by_case", "authorized", "phases_us"]) || %{}

      {:ok,
       Map.merge(measured, %{
         "benchmark" => "B5 authority and BRCE",
         "rfc_sections" => ["§84", "§89"],
         "sut" => %{
           "authority_decision" => "AshA2A.Authority.Grant.authorize/3",
           "broker" => inspect(InMemory),
           "do_boundary" => "AshA2A.CommandBus.run/4",
           "receipt_store" => inspect(AshA2A.ReceiptStore.Memory),
           "prepared_receipt_medium" =>
             "AshA2A.ReceiptOutbox (File.write/3 :sync + rename) at #{AshA2A.ReceiptOutbox.dir()}",
           "postcondition_reader" => "Ash.read!/2 on #{inspect(Ledger)}"
         },
         "fixture" => %{
           "resource" => inspect(Ledger),
           "capability" => @capability,
           "scenarios" => scenarios
         },
         "scenarios_reported_separately" => true,
         "evidence_handlers_attached" => handlers,
         "highlights" => %{
           "authorized_end_to_end_p50_us" => get_in(authorized, ["end_to_end", "p50"]),
           "authorized_end_to_end_p99_us" => get_in(authorized, ["end_to_end", "p99"]),
           "authority_decision_p50_us" => get_in(authorized, ["authority_decision", "p50"]),
           "prepared_receipt_durability_p50_us" =>
             get_in(authorized, ["prepared_receipt_durability", "p50"])
         }
       })}
    after
      Timeline.detach(ref)
      teardown(env)
    end
  end

  @doc """
  Starts the real collaborators: a receipt store, a live broker, and a broker
  that was started and then really stopped. Returns the environment map.
  """
  @spec setup() :: map()
  def setup do
    unique = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, "Store#{unique}")
    broker = Module.concat(__MODULE__, "Broker#{unique}")
    dead_broker = Module.concat(__MODULE__, "DeadBroker#{unique}")

    {:ok, store_pid} = AshA2A.ReceiptStore.Memory.start_link(name: store)
    {:ok, broker_pid} = InMemory.start_link(name: broker)
    {:ok, dead_pid} = InMemory.start_link(name: dead_broker)
    :ok = GenServer.stop(dead_pid, :normal)

    %{
      store_pid: store_pid,
      store_opts: [name: store],
      broker_pid: broker_pid,
      broker: {InMemory, [name: broker]},
      broker_name: broker,
      dead_broker: {InMemory, [name: dead_broker]}
    }
  end

  @doc "Stops the collaborators `setup/0` started."
  @spec teardown(map()) :: :ok
  def teardown(env) do
    for pid <- [env.store_pid, env.broker_pid], Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end

    :ok
  end

  @doc """
  Runs one scenario and returns its timed, invariant-checked sample.
  `ref` is an attached `AshA2A.Chicago.Bench.Timeline` over `events/0`.
  """
  @spec scenario(String.t(), map(), reference()) :: Bench.sample()
  def scenario(name, env, ref) when name in @scenarios do
    unique = Integer.to_string(System.unique_integer([:positive]))
    principal = "chicago-bench-#{name}-#{unique}"
    subject = Identity.principal(principal)

    case arrange(name, subject, env) do
      {:ok, broker} ->
        timed(name, principal, broker, unique, env, ref)

      {:error, reason} ->
        %{
          case: name,
          duration_us: 0,
          outcome: "setup_failed",
          phases: %{},
          invariant: {:error, "scenario setup failed: #{inspect(reason)}"}
        }
    end
  end

  defp arrange("authorized", subject, env) do
    with {:ok, _authority} <- Grant.grant(subject, @capability, broker: env.broker),
         do: {:ok, env.broker}
  end

  defp arrange("refused", _subject, env), do: {:ok, env.broker}

  defp arrange("expired", subject, env) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    with {:ok, _authority} <-
           Grant.grant(subject, @capability, broker: env.broker, expires_at: past),
         do: {:ok, env.broker}
  end

  defp arrange("revoked", subject, env) do
    with {:ok, authority} <- Grant.grant(subject, @capability, broker: env.broker),
         :ok <- InMemory.revoke(authority, name: env.broker_name),
         do: {:ok, env.broker}
  end

  defp arrange("broker_unavailable", _subject, env), do: {:ok, env.dead_broker}

  defp timed(name, principal, broker, unique, env, ref) do
    label = "chicago-bench-b5-#{name}-#{unique}"
    _ = Timeline.drain(ref)

    t0 = System.monotonic_time(:microsecond)
    authority = Grant.authorize(principal, @capability, policy: :broker, broker: broker)

    command =
      Command.new(@capability,
        command_id: "chicago-bench-b5-" <> unique,
        agent_id: "chicago-bench-agent",
        principal_id: principal,
        authority: authority,
        input: %{label: label}
      )

    message = A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])

    reply =
      CommandBus.run(command, message, Ledger,
        store: AshA2A.ReceiptStore.Memory,
        store_opts: env.store_opts
      )

    returned = System.monotonic_time(:microsecond)
    present? = label_present?(label)
    finished = System.monotonic_time(:microsecond)
    timeline = Timeline.drain(ref)

    %{
      case: name,
      duration_us: finished - t0,
      outcome: outcome(reply),
      phases: phases(timeline, t0, returned, finished),
      invariant: invariant(name, reply, timeline, present?)
    }
  end

  @doc "Independent post-state reader: is a Ledger row with `label` visible?"
  @spec label_present?(String.t()) :: boolean()
  def label_present?(label) do
    Ledger
    |> Ash.Query.filter(label == ^label)
    |> Ash.read!()
    |> Enum.any?()
  end

  defp outcome({:ok, _receipt}), do: "committed"
  defp outcome({:error, %{code: code}}), do: "refused:#{code}"
  defp outcome({:error, _}), do: "refused"

  defp phases(timeline, t0, returned, finished) do
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
      "independent_postcondition" => finished - returned,
      "end_to_end" => finished - t0
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp invariant("authorized", reply, timeline, present?) do
    checks = [
      {match?({:ok, %AshA2A.Receipt{}}, reply),
       "reply was #{inspect_reply(reply)}, not a receipt"},
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
      {present?, "independent reader does not see the committed row"}
    ]

    first_failure(checks)
  end

  defp invariant(_refusal_scenario, reply, timeline, present?) do
    checks = [
      {match?({:error, %{code: :authority_required}}, reply),
       "reply was #{inspect_reply(reply)}, not an :authority_required refusal"},
      {outcome_of(timeline, @grant) == :refused,
       "authority.decision outcome #{inspect(outcome_of(timeline, @grant))}"},
      {outcome_of(timeline, @admission) == :refused,
       "brce.admission outcome #{inspect(outcome_of(timeline, @admission))}"},
      {Enum.all?([@claim, @prepare, @actuate_start], &(Timeline.first(timeline, &1) == nil)),
       "a refused command reached claim/prepare/actuation"},
      {not present?, "a refused command left a row visible to the independent reader"}
    ]

    first_failure(checks)
  end

  defp first_failure(checks) do
    case Enum.find(checks, fn {ok?, _detail} -> ok? != true end) do
      nil -> :ok
      {_, detail} -> {:error, detail}
    end
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

  defp inspect_reply({:ok, %{__struct__: struct}}), do: "{:ok, %#{inspect(struct)}{}}"
  defp inspect_reply({:error, %{code: code}}), do: "{:error, #{inspect(code)}}"
  defp inspect_reply(other), do: inspect(other, limit: 5)
end
