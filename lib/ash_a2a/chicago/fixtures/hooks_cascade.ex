defmodule AshA2A.Chicago.Fixtures.HooksCascade.Domain do
  @moduledoc "Ash domain for the knowledge-hook / reactive-cascade court fixtures."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Fixtures.HooksCascade.Signal)
  end
end

defmodule AshA2A.Chicago.Fixtures.HooksCascade.Signal do
  @moduledoc """
  The real actuator the hook courts drive: a `:change` create over the ETS
  data layer, reachable only as the `emit_signal` skill through
  `AshA2A.CommandBus`. Rows are read back by the courts through `Ash.read!/1`
  -- an independent post-state reader, not the receipt or the reply.
  """
  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.HooksCascade.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:kind, :string, public?: true, allow_nil?: false)
    attribute(:subject, :string, public?: true, allow_nil?: false)
    attribute(:cause, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :emit do
      accept([:kind, :subject, :cause])
    end
  end

  a2a do
    skill(:emit_signal, :emit)
  end
end

defmodule AshA2A.Chicago.Fixtures.HooksCascade do
  @moduledoc """
  Shared fixtures for `AshA2A.Chicago.Courts.KnowledgeHooks` and
  `AshA2A.Chicago.Courts.ReactiveCascade`: hook builders over the
  `h:` vocabulary, a real receipt store and a real authority broker per court
  run, the delta projection the reactor feeds back, independent post-state
  readers, OCEL mappings for `AshA2A.Semantic.HookReactor` telemetry, and
  small evidence readers over the observer's attributed records.

  Everything here drives real collaborators: the real GraphLaw engine
  (`AshA2A.Semantic.HookReactor.Engine`), the real `AshA2A.CommandBus`, a
  real `AshA2A.ReceiptStore.Memory`, a real `AshA2A.Authority.Broker.InMemory`
  and the real ETS-backed `Signal` resource.
  """

  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Identity
  alias AshA2A.Semantic.{Bounds, HookReactor}
  alias AshA2A.Semantic.HookReactor.Hook
  alias __MODULE__.Signal

  @ns "http://example.org/sa2a/hooks#"
  @capability "AshA2A.Chicago.Fixtures.HooksCascade.Signal.emit"

  @spec ns() :: String.t()
  def ns, do: @ns

  @spec capability() :: String.t()
  def capability, do: @capability

  # --- environment ------------------------------------------------------------

  @doc """
  Starts a real receipt store and a real authority broker, grants
  `@capability` to one principal (`env.granted`) and not to another
  (`env.ungranted`), runs `fun.(env)`, and stops both.
  """
  @spec with_env((map() -> result)) :: result when result: var
  def with_env(fun) do
    n = System.unique_integer([:positive])
    store_name = Module.concat(__MODULE__, "Store#{n}")
    broker_name = Module.concat(__MODULE__, "Broker#{n}")
    {:ok, store} = AshA2A.ReceiptStore.Memory.start_link(name: store_name)
    {:ok, broker} = InMemory.start_link(name: broker_name)

    env = %{
      nonce: n,
      store_opts: [name: store_name],
      broker: {InMemory, [name: broker_name]},
      granted: "hook-reflex-granted-#{n}",
      ungranted: "hook-reflex-ungranted-#{n}"
    }

    {:ok, _authority} =
      Grant.grant(Identity.principal(env.granted), @capability, broker: env.broker)

    try do
      fun.(env)
    after
      for pid <- [store, broker], Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  # --- hooks ------------------------------------------------------------------

  @doc "An N3 denial-rule condition over the `h:` vocabulary."
  @spec condition(String.t()) :: String.t()
  def condition(body), do: "@prefix h: <#{@ns}> .\n#{body} => false .\n"

  @doc """
  A hook firing on `?s a h:<on_class>` and asking for a `Signal` of
  `emit_class` about `subject`. Options: `:revision`, `:guard`, `:witness`,
  `:provenance`, `:trigger`, `:intent_extra` (merged into the intent map).
  """
  @spec hook(String.t(), String.t(), String.t(), String.t(), keyword()) :: Hook.t()
  def hook(id, on_class, emit_class, subject, opts \\ []) do
    intent =
      Map.merge(
        %{capability_id: @capability, input: %{"kind" => emit_class, "subject" => subject}},
        Keyword.get(opts, :intent_extra, %{})
      )

    Hook.new(
      id: id,
      revision: Keyword.get(opts, :revision, 1),
      trigger: Keyword.get(opts, :trigger, condition("{ ?s a h:#{on_class} }")),
      guard: Keyword.get(opts, :guard),
      witness: Keyword.get(opts, :witness, "<urn:sa2a:witness:#{id}> a <#{@ns}#{on_class}> ."),
      intent: intent,
      provenance:
        Keyword.get(opts, :provenance, %{
          source: inspect(__MODULE__),
          author: "sa2a-chicago-court"
        })
    )
  end

  @doc """
  The guarded alarm hook: fires on any `h:reading` in the delta, but only
  when the post-state also holds an armed sensor reading.
  """
  @spec alarm_hook(String.t(), String.t()) :: Hook.t()
  def alarm_hook(id, subject) do
    hook(id, "Reading", "Alert", subject,
      trigger: condition("{ ?s h:reading ?r }"),
      guard: condition("{ ?s h:reading ?r . ?s h:mode h:Armed }"),
      witness: "<urn:sa2a:witness:#{id}> <#{@ns}reading> 1 ; <#{@ns}mode> <#{@ns}Armed> ."
    )
  end

  @spec typed_delta(String.t(), String.t()) :: String.t()
  def typed_delta(class, iri), do: "<#{iri}> a <#{@ns}#{class}> .\n"

  @spec reading_delta(String.t(), integer()) :: String.t()
  def reading_delta(sensor_iri, value), do: "<#{sensor_iri}> <#{@ns}reading> #{value} .\n"

  @spec armed_base(String.t()) :: String.t()
  def armed_base(sensor_iri), do: "<#{sensor_iri}> <#{@ns}mode> <#{@ns}Armed> .\n"

  @spec bounds!(non_neg_integer(), non_neg_integer(), pos_integer()) :: Bounds.t()
  def bounds!(depth, fan_out, parallelism) do
    {:ok, bounds} = Bounds.new(depth: depth, fan_out: fan_out, parallelism: parallelism)
    bounds
  end

  # --- episodes ---------------------------------------------------------------

  @doc """
  Meta-admits `opts[:admit]` (default `opts[:hooks]`) and runs one reactor
  episode. Returns `%{admission, refused, result}`.

  Options: `:hooks`, `:admit`, `:admission`, `:delta`, `:principal`,
  `:bounds`, `:base`, `:parallelism`, `:project` (default `project/2`;
  `false` disables feedback).
  """
  @spec episode(map(), map(), keyword()) :: map()
  def episode(runtime, env, opts) do
    hooks = Keyword.fetch!(opts, :hooks)

    %{admission: admission, refused: refused} =
      case Keyword.fetch(opts, :admission) do
        {:ok, admission} -> %{admission: admission, refused: []}
        :error -> HookReactor.admit(Keyword.get(opts, :admit, hooks), runtime: runtime)
      end

    %{admission: admission, refused: refused, result: run!(runtime, env, admission, opts)}
  end

  @doc "Runs one reactor episode with an already-admitted set."
  @spec run!(map(), map(), HookReactor.Admission.t(), keyword()) :: HookReactor.Result.t()
  def run!(runtime, env, admission, opts) do
    project =
      case Keyword.get(opts, :project, &project/2) do
        false -> nil
        fun -> fun
      end

    reactor_opts =
      [
        runtime: runtime,
        hooks: Keyword.fetch!(opts, :hooks),
        admission: admission,
        bounds: Keyword.fetch!(opts, :bounds),
        resource_or_domain: Signal,
        principal: Keyword.fetch!(opts, :principal),
        authority_opts: [policy: :broker, broker: env.broker],
        store: AshA2A.ReceiptStore.Memory,
        store_opts: env.store_opts,
        base: Keyword.get(opts, :base, ""),
        agent_id: "sa2a-hook-court",
        project: project
      ] ++ Keyword.take(opts, [:parallelism])

    case HookReactor.run(Keyword.fetch!(opts, :delta), reactor_opts) do
      {:ok, result} -> result
      {:error, refusal} -> raise ArgumentError, "reactor refused its options: #{inspect(refusal)}"
    end
  end

  @doc """
  The admitted resulting-delta projection: reads the `Signal` rows a
  committed intent caused back through `Ash.read!/1` and renders them as
  Turtle. No row, no delta.
  """
  @spec project(HookReactor.Intent.t(), AshA2A.Receipt.t()) :: {:ok, String.t()} | :none
  def project(%HookReactor.Intent{intent_id: cause}, _receipt) do
    case signals_caused_by(cause) do
      [] ->
        :none

      rows ->
        {:ok,
         Enum.map_join(rows, "", fn row ->
           "<urn:sa2a:signal:#{row.id}> a <#{@ns}#{row.kind}> ; " <>
             "<#{@ns}subject> \"#{row.subject}\" ; <#{@ns}cause> \"#{row.cause}\" .\n"
         end)}
    end
  end

  @doc """
  An adversarial projection that renders a delta from the intent itself,
  whether or not any consequence happened. Used to prove the reactor -- not
  the projection -- is what keeps refused intents out of the cascade.
  """
  @spec optimistic_project(HookReactor.Intent.t(), AshA2A.Receipt.t() | nil) :: {:ok, String.t()}
  def optimistic_project(%HookReactor.Intent{} = intent, _receipt) do
    {:ok,
     "<urn:sa2a:phantom:#{intent.intent_id}> a <#{@ns}#{intent.input["kind"]}> ; " <>
       "<#{@ns}subject> \"#{intent.input["subject"]}\" .\n"}
  end

  @doc "Independent post-state reader: every `Signal` about `subject`."
  @spec signals(String.t()) :: [struct()]
  def signals(subject), do: Signal |> Ash.read!() |> Enum.filter(&(&1.subject == subject))

  @spec signals_caused_by(String.t()) :: [struct()]
  def signals_caused_by(cause), do: Signal |> Ash.read!() |> Enum.filter(&(&1.cause == cause))

  # --- OCEL -------------------------------------------------------------------

  @activities [
    {[:hook, :admission], "hook.admission"},
    {[:cascade, :start], "hook.cascade.start"},
    {[:cascade, :bound], "hook.cascade.bound"},
    {[:hook, :evaluate], "hook.evaluate"},
    {[:intent, :constructed], "hook.intent.constructed"},
    {[:intent, :idempotency], "hook.intent.idempotency"},
    {[:intent, :route_start], "hook.intent.route_start"},
    {[:intent, :routed], "hook.intent.routed"},
    {[:cascade, :stop], "hook.cascade.stop"}
  ]

  @attribute_keys [
    :outcome,
    :code,
    :generation,
    :trigger,
    :guard,
    :bound,
    :requested,
    :ceiling,
    :in_flight,
    :authority,
    :standing,
    :revision,
    :hook_revision,
    :idempotency,
    :delta_size,
    :depth_ceiling,
    :fan_out_ceiling,
    :parallelism_ceiling,
    :requested_parallelism,
    :generations,
    :depth_reached,
    :intents,
    :receipts,
    :capability_id,
    :memory_peak_bytes,
    :condition_digest
  ]

  @doc """
  OCEL mappings for `[:ash_a2a, :hook_reactor, ...]` telemetry. Object types:
  `cascade`, `hook`, `delta`, `intent`, `command` (shared with the
  `brce.*` activities, so a hook's intent and the command CommandBus decided
  are one object), `receipt`.
  """
  @spec mappings(module()) :: [Mapping.t()]
  def mappings(source) do
    objects = fn _m, meta ->
      [
        {"cascade", meta[:cascade_id], "cascade"},
        {"hook", meta[:hook_id], "hook"},
        {"delta", meta[:delta_digest], "delta"},
        {"intent", meta[:intent_id], "intent"},
        {"command", meta[:command_id], "command"},
        {"receipt", meta[:receipt_id], "receipt"}
      ]
    end

    attributes = fn measurements, meta ->
      meta
      |> Map.take(@attribute_keys)
      |> Map.merge(Map.take(measurements, [:duration_us]))
    end

    for {suffix, activity} <- @activities do
      Mapping.new!(
        event: [:ash_a2a, :hook_reactor | suffix],
        activity: activity,
        source: source,
        objects: objects,
        attributes: attributes
      )
    end
  end

  # --- evidence readers over the observer's attributed records -----------------

  @doc "Records of `activity` attributed to `falsifier` whose attributes equal `attrs`."
  @spec records(Context.t(), Falsifier.t(), String.t(), map()) :: [map()]
  def records(ctx, falsifier, activity, attrs \\ %{}) do
    ctx
    |> Context.observed(falsifier)
    |> Enum.filter(fn r ->
      r.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(Map.get(r.attributes, k)) == to_string(v) end)
    end)
  end

  @spec seen?(Context.t(), Falsifier.t(), String.t(), map()) :: boolean()
  def seen?(ctx, falsifier, activity, attrs \\ %{}),
    do: records(ctx, falsifier, activity, attrs) != []

  @spec count(Context.t(), Falsifier.t(), String.t(), map()) :: non_neg_integer()
  def count(ctx, falsifier, activity, attrs \\ %{}),
    do: length(records(ctx, falsifier, activity, attrs))

  @doc "Object id of `type` on a record, or nil."
  @spec object(map(), String.t()) :: String.t() | nil
  def object(record, type) do
    Enum.find_value(record.objects, fn
      {^type, id, _q} -> id
      _ -> nil
    end)
  end

  @doc """
  Maximum number of simultaneously open CommandBus actuations among `records`
  (paired `brce.actuate.start`/`brce.actuate.stop` by execution object,
  ordered by the observer's monotonic sequence), optionally restricted to
  `command_ids`.
  """
  @spec actuation_overlap([map()], MapSet.t() | nil) :: non_neg_integer()
  def actuation_overlap(records, command_ids \\ nil) do
    records
    |> Enum.filter(&(&1.activity in ["brce.actuate.start", "brce.actuate.stop"]))
    |> Enum.filter(&(command_ids == nil or MapSet.member?(command_ids, object(&1, "command"))))
    |> Enum.sort_by(& &1.seq)
    |> Enum.reduce({0, 0}, fn
      %{activity: "brce.actuate.start"}, {open, max} -> {open + 1, max(max, open + 1)}
      %{activity: "brce.actuate.stop"}, {open, max} -> {max(open - 1, 0), max}
    end)
    |> elem(1)
  end

  @doc "Summary statistics of a list of integers (JSON-safe)."
  @spec stats([integer()]) :: map()
  def stats([]), do: %{"n" => 0}

  def stats(values) do
    %{
      "n" => length(values),
      "total" => Enum.sum(values),
      "min" => Enum.min(values),
      "max" => Enum.max(values),
      "mean" => div(Enum.sum(values), length(values))
    }
  end

  @doc """
  Runs one falsifier body, converting a raise/exit into an honest `:unknown`
  result for that falsifier alone instead of losing the whole court.
  """
  @spec guarded(Falsifier.t(), (-> Result.t())) :: Result.t()
  def guarded(%Falsifier{} = falsifier, fun) do
    fun.()
  rescue
    exception ->
      Result.unknown(falsifier, "court body raised: " <> Exception.message(exception))
  catch
    kind, reason ->
      Result.unknown(falsifier, "court body #{kind}: #{inspect(reason, limit: 10)}")
  end
end
