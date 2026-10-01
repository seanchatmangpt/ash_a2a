defmodule AshA2A.Chicago.Fixtures.FiboFinance do
  @moduledoc """
  Real fixtures for the `CHI-FIN` court (`AshA2A.Chicago.Courts.FiboFinance`).

  ## Standing and scope (read first)

  Finite published corpus passes on exact subject; authority NONE; synthetic
  subject; no general financial safety claim.

    * The financial subject is a **synthetic, in-process ledger** (an ETS
      table). There is no payment rail, no real account and no real money.
    * The vocabulary is `fin:` (`https://chicago.graphlaw.dev/fin#`), a
      synthetic namespace of this court. It is not FIBO; FIBO defines neither
      a threshold nor a ceiling.
    * The `$10M` figure is **this court's policy** (`fin:grantCeilingMicros`),
      not FIBO's. Money is integer micros: `$10M = 10_000_000_000_000`.
    * The monetary grant ceiling is a `fin:grantCeilingMicros` fact enforced
      by SHACL `sh:lessThanOrEquals` over the graphlaw ABI. It is **not** a
      graphlaw lease `Ceiling` (those are Observe / Select / Construct only:
      `UNSUPPORTED[money-ceiling]`), and the signature here is the court's own
      Ed25519 signature over the graphlaw canonical id, not a graphlaw signed
      receipt (`UNSUPPORTED[abi:no-receipt-signing]`).

  ## What is real

  Every gate that asks a semantic question asks the compiled graphlaw JSON ABI
  (`Fixtures.FiboFinance.Abi`, Wasmtime via wasmex): SHACL (structure,
  `money_micros` envelope, grant ceiling), SPARQL ASK (capability, key
  standing), RDFC canonical identity (seal), and `law` plan admission with a
  negative precondition `pre_not` (replay). The effect is a real ETS write by a
  real processor function; the independent observer is a full-scan reader of
  that same ledger; the intent journal is a real file; the crash is a real
  `:kill` of a real process between the effect and the receipt.

  `execute/3`'s `:without` option removes exactly one named guard. It exists so
  a test can prove each negative falsifier is non-vacuous: with its guard
  removed the forbidden outcome must be observed.

  Guards: `:envelope`, `:key_status`, `:replay`, `:seal`, `:ceiling`,
  `:observer`, `:reconcile`, `:depth`.
  """

  alias AshA2A.Chicago.Fixtures.FiboFinance.Abi
  alias AshA2A.Chicago.Ocel.Mapping

  @fin "https://chicago.graphlaw.dev/fin#"
  @hard_cap 8

  @doc "The fixture vocabulary namespace."
  def fin, do: @fin

  @doc "US-dollar millions expressed in integer micros (`usd(10) == 10_000_000_000_000`)."
  @spec usd(non_neg_integer()) :: non_neg_integer()
  def usd(millions), do: millions * 1_000_000_000_000

  # --- telemetry + OCEL mappings -------------------------------------------------

  @events %{
    submit: {[:ash_a2a, :chicago, :fibo_finance, :submit], "fin.submit"},
    gate: {[:ash_a2a, :chicago, :fibo_finance, :gate], "fin.gate"},
    mutation: {[:ash_a2a, :chicago, :fibo_finance, :mutation], "fin.mutation"},
    do: {[:ash_a2a, :chicago, :fibo_finance, :do], "fin.do"},
    observe: {[:ash_a2a, :chicago, :fibo_finance, :observe], "fin.observe"},
    receipt: {[:ash_a2a, :chicago, :fibo_finance, :receipt], "fin.receipt"},
    crash: {[:ash_a2a, :chicago, :fibo_finance, :crash], "fin.crash"},
    reconcile: {[:ash_a2a, :chicago, :fibo_finance, :reconcile], "fin.reconcile"},
    hop: {[:ash_a2a, :chicago, :fibo_finance, :cascade, :hop], "fin.cascade.hop"},
    stop: {[:ash_a2a, :chicago, :fibo_finance, :cascade, :stop], "fin.cascade.stop"}
  }

  @doc "OCEL mappings for every `fin.*` activity."
  def mappings do
    for {_key, {event, activity}} <- @events do
      Mapping.new!(
        event: event,
        activity: activity,
        source: __MODULE__,
        objects: fn _m, meta ->
          [{"fin_transaction", meta[:tx_id], "transaction"}]
        end,
        attributes: fn _m, meta -> Map.get(meta, :attrs, %{}) end
      )
    end
  end

  @doc false
  def emit(kind, tx_id, attrs) do
    {event, _activity} = Map.fetch!(@events, kind)
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), str(v)} end)
    :telemetry.execute(event, %{system_time: System.system_time()}, %{tx_id: tx_id, attrs: attrs})
  end

  defp str(v) when is_binary(v), do: v
  defp str(v) when is_atom(v) or is_number(v), do: to_string(v)
  defp str(v), do: inspect(v)

  # --- environment ---------------------------------------------------------------

  defmodule Env do
    @moduledoc false
    @enforce_keys [:abi, :ledger, :state, :journal, :registry, :pubs, :privs]
    defstruct [
      :abi,
      :ledger,
      :state,
      :journal,
      :registry,
      :pubs,
      :privs,
      envelope: 1_000_000_000_000_000,
      ceiling: 1_000_000_000_000_000,
      depth_bound: 3
    ]
  end

  @active "urn:key:active"
  @revoked "urn:key:revoked"

  @doc "Key id of the active signing key."
  def active_key, do: @active
  @doc "Key id of the revoked signing key."
  def revoked_key, do: @revoked

  @doc """
  Starts the graphlaw ABI host and proves it is a HEAD build that knows
  `pre_not` (an older artifact admits the replay plan). Returns
  `{:ok, abi_pid}` or `{:blocked, reason}`.
  """
  @spec start_abi() :: {:ok, pid()} | {:blocked, String.t()}
  def start_abi do
    with {:ok, abi} <- Abi.start_link() do
      case stale_probe(abi) do
        :ok ->
          {:ok, abi}

        {:stale, why} ->
          Abi.stop(abi)
          {:blocked, "graphlaw ABI artifact is stale: " <> why}
      end
    else
      {:error, {:blocked, reason}} -> {:blocked, reason}
      {:error, reason} -> {:blocked, "cannot start graphlaw ABI host: " <> inspect(reason)}
    end
  end

  defp stale_probe(abi) do
    forbidden = "<urn:p:x> <urn:p:occupied> <urn:v:yes> .\n"
    at = "<urn:p:r> <urn:p:at> <urn:p:a> .\n"

    resp =
      Abi.call(abi, %{
        op: "law",
        data: %{text: at <> forbidden, dialect: "ntriples"},
        steps: [
          %{
            step: "plan",
            plan: %{
              actions: [%{name: "probe", pre: at, pre_not: forbidden, add: "", del: ""}],
              goal: at
            }
          }
        ]
      })

    case get_in(resp, ["error", "details", "code"]) do
      "PlanRefused" -> :ok
      _ -> {:stale, "a plan violating pre_not was not refused: " <> inspect(resp)}
    end
  end

  @doc "Opens a fresh synthetic ledger, settled-state, journal and key registry over `abi`."
  @spec open(pid(), keyword()) :: %Env{}
  def open(abi, opts \\ []) do
    {pub_a, priv_a} = :crypto.generate_key(:eddsa, :ed25519)
    {pub_r, priv_r} = :crypto.generate_key(:eddsa, :ed25519)

    dir =
      Path.join(
        System.tmp_dir!(),
        "chi-fin-#{System.unique_integer([:positive])}-#{:erlang.phash2(make_ref())}"
      )

    File.mkdir_p!(dir)
    {:ok, state} = Agent.start_link(fn -> initial_state() end)

    registry =
      "@prefix fin: <#{@fin}> .\n" <>
        "<#{@active}> fin:status fin:Active .\n<#{@revoked}> fin:status fin:Revoked .\n"

    %Env{
      abi: abi,
      ledger: :ets.new(:chi_fin_ledger, [:public, :ordered_set]),
      state: state,
      journal: Path.join(dir, "journal.ndjson"),
      registry: registry,
      pubs: %{@active => pub_a, @revoked => pub_r},
      privs: %{@active => priv_a, @revoked => priv_r},
      envelope: Keyword.get(opts, :envelope, usd(1_000_000)),
      ceiling: Keyword.get(opts, :ceiling, usd(1_000_000)),
      depth_bound: Keyword.get(opts, :depth_bound, 3)
    }
  end

  @doc "Releases everything `open/2` created (the shared ABI host stays up)."
  def close(%Env{} = env) do
    if :ets.info(env.ledger) != :undefined, do: :ets.delete(env.ledger)
    if Process.alive?(env.state), do: Agent.stop(env.state)
    File.rm_rf(Path.dirname(env.journal))
    :ok
  end

  def with_env(abi, opts, fun) do
    env = open(abi, opts)

    try do
      fun.(env)
    after
      close(env)
    end
  end

  defp initial_state do
    "<urn:acct:treasury> <#{@fin}status> \"open\" .\n"
  end

  defp status_pred, do: "<#{@fin}status>"
  defp settled_pred, do: "<#{@fin}settled>"

  # --- transactions and requests ---------------------------------------------------

  @doc "A synthetic transfer."
  def tx(id, amount, opts \\ []) do
    %{
      id: "urn:tx:" <> id,
      amount: amount,
      account: Keyword.get(opts, :account, "urn:acct:treasury"),
      counterparty: Keyword.get(opts, :counterparty, "urn:party:acme"),
      capability: "Transfer"
    }
  end

  @doc "The Turtle form of a transaction (the exact effect that gets sealed)."
  def tx_turtle(tx) do
    "@prefix fin: <#{@fin}> .\n" <>
      "<#{tx.id}> a fin:#{tx.capability} ; fin:amountMicros #{tx.amount} ; " <>
      "fin:debitAccount <#{tx.account}> ; fin:counterparty <#{tx.counterparty}> .\n"
  end

  @doc "A signed submission. `:key` selects the signing key, `:processor` the actuator."
  def request(%Env{} = env, tx, opts \\ []) do
    key = Keyword.get(opts, :key, @active)
    id = canonical_id!(env, tx_turtle(tx))
    sig = :crypto.sign(:eddsa, :none, id, [Map.fetch!(env.privs, key), :ed25519])

    %{
      tx: tx,
      key_id: key,
      sig: sig,
      grant: %{id: "urn:grant:" <> tx.id, capability: tx.capability, ceiling: env.ceiling},
      mutate: Keyword.get(opts, :mutate),
      processor: Keyword.get(opts, :processor, :honest),
      crash_after_do: Keyword.get(opts, :crash_after_do, false)
    }
  end

  defp canonical_id!(env, ttl) do
    %{"ok" => true, "id" => id} =
      Abi.call(env.abi, %{op: "canonical", data: %{text: ttl, dialect: "turtle"}})

    id
  end

  # --- ledger and independent observer ---------------------------------------------

  defmodule Ledger do
    @moduledoc false

    @doc "The court's independent reader: a full scan, never the processor's report."
    def rows(env), do: env.ledger |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

    def rows_for(env, tx_id), do: env |> rows() |> Enum.filter(&(&1.tx_id == tx_id))

    def append(env, tx) do
      row = %{
        tx_id: tx.id,
        account: tx.account,
        amount: tx.amount,
        counterparty: tx.counterparty
      }

      true = :ets.insert(env.ledger, {System.unique_integer([:monotonic, :positive]), row})
      row
    end
  end

  @doc "Every ledger row (independent full scan)."
  def ledger_rows(%Env{} = env), do: Ledger.rows(env)

  # The processor is the actuator. `:lying` claims success and writes nothing.
  defp process(env, tx, :honest) do
    Ledger.append(env, tx)
    {:ok, %{tx_id: tx.id, amount: tx.amount}}
  end

  defp process(_env, tx, :lying), do: {:ok, %{tx_id: tx.id, amount: tx.amount}}

  # --- the pipeline -----------------------------------------------------------------

  @doc """
  Drives one submission through every gate to the effect and its receipt.

  Returns `%{outcome: outcome, sealed_id: id | nil}` where `outcome` is
  `:completed`, `:withheld` (effect claimed but not independently observed),
  `{:refused, gate, reason}` or `:crashed`.
  """
  @spec execute(%Env{}, map(), keyword()) :: map()
  def execute(%Env{} = env, req, opts \\ []) do
    without = Keyword.get(opts, :without, [])
    tx = req.tx
    ttl = tx_turtle(tx)

    emit(:submit, tx.id, %{
      "amount_micros" => tx.amount,
      "key_id" => req.key_id,
      "capability" => tx.capability
    })

    with :ok <- gate(tx, "semantics", false, fn -> semantics(env, ttl) end),
         :ok <- gate(tx, "envelope", :envelope in without, fn -> envelope(env, ttl) end),
         id = canonical_id!(env, ttl),
         :ok <- gate(tx, "signature", false, fn -> signature(env, req, id) end),
         :ok <- gate(tx, "key_status", :key_status in without, fn -> key_status(env, req) end),
         :ok <- gate(tx, "capability", false, fn -> capability(env, ttl, req.grant) end),
         {:ok, admitted} <- plan_gate(env, tx, :replay in without) do
      effect(env, req, id, admitted, without)
    else
      {:refused, gate, reason} -> %{outcome: {:refused, gate, reason}, sealed_id: nil}
    end
  end

  defp effect(env, req, sealed_id, admitted, without) do
    tx = req.tx
    current = mutate(req)

    with :ok <- gate(current, "seal", :seal in without, fn -> seal(env, current, sealed_id) end),
         :ok <-
           gate(current, "ceiling", :ceiling in without, fn ->
             ceiling(env, current, req.grant)
           end) do
      journal(env, %{
        "event" => "intent",
        "tx" => encode_tx(current),
        "processor" => Atom.to_string(req.processor)
      })

      run =
        isolated(fn ->
          emit(:do, tx.id, %{"outcome" => "processed", "processor" => req.processor})
          {:ok, claim} = process(env, current, req.processor)
          maybe_crash(req, tx)
          observe_and_receipt(env, tx, claim, admitted, without)
        end)

      case run do
        {:ok, result} -> Map.put(result, :sealed_id, sealed_id)
        :crashed -> %{outcome: :crashed, sealed_id: sealed_id}
      end
    else
      {:refused, gate, reason} -> %{outcome: {:refused, gate, reason}, sealed_id: sealed_id}
    end
  end

  defp mutate(%{mutate: nil, tx: tx}), do: tx

  defp mutate(%{mutate: fun, tx: tx}) do
    mutated = fun.(tx)

    emit(:mutation, tx.id, %{
      "field" => "counterparty",
      "before" => tx.counterparty,
      "after" => mutated.counterparty
    })

    mutated
  end

  defp maybe_crash(%{crash_after_do: true}, tx) do
    emit(:crash, tx.id, %{"point" => "after_do_before_receipt"})
    Process.exit(self(), :kill)
    # never reached: the receipt below must not be written by a killed process
    Process.sleep(:infinity)
  end

  defp maybe_crash(_req, _tx), do: :ok

  # Runs `fun` in its own process so a real :kill lands between effect and receipt.
  defp isolated(fun) do
    parent = self()
    ref = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        send(parent, {ref, fun.()})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        {:ok, result}

      {:DOWN, ^mon, :process, ^pid, _reason} ->
        # the result may have been sent just before a normal exit
        receive do
          {^ref, result} -> {:ok, result}
        after
          0 -> :crashed
        end
    after
      120_000 -> :crashed
    end
  end

  # Independent postcondition: read the ledger, never the processor's report.
  defp observe_and_receipt(env, tx, claim, admitted, without) do
    rows = Ledger.rows_for(env, tx.id)
    observed_total = rows |> Enum.map(& &1.amount) |> Enum.sum()
    independent? = :observer not in without
    agrees? = if independent?, do: rows != [] and observed_total == claim.amount, else: true

    emit(:observe, tx.id, %{
      "ledger_rows" => length(rows),
      "claimed_micros" => claim.amount,
      "observed_micros" => observed_total,
      "agrees" => agrees?,
      "independent" => independent?
    })

    status = if agrees?, do: :completed, else: :withheld
    commit_receipt(env, tx.id, status, admitted)
    %{outcome: status, observed_rows: length(rows)}
  end

  defp commit_receipt(env, tx_id, status, admitted) do
    if status == :completed, do: Agent.update(env.state, fn _ -> admitted end)
    journal(env, %{"event" => "receipt", "tx_id" => tx_id, "status" => Atom.to_string(status)})
    emit(:receipt, tx_id, %{"status" => status})
  end

  # --- gates ---------------------------------------------------------------------------

  defp gate(tx, name, skip?, fun) do
    result = if skip?, do: :ok, else: fun.()

    {outcome, reason} =
      case result do
        :ok -> {"ok", ""}
        {:refused, reason} -> {"refused", str(reason)}
      end

    emit(:gate, tx.id, %{
      "gate" => name,
      "outcome" => outcome,
      "reason" => reason,
      "guard_removed" => skip?
    })

    case result do
      :ok -> :ok
      {:refused, reason} -> {:refused, name, reason}
    end
  end

  @prefixes "@prefix sh: <http://www.w3.org/ns/shacl#> .\n@prefix fin: <#{@fin}> .\n" <>
              "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n"

  defp semantics(env, ttl) do
    shapes =
      @prefixes <>
        """
        fin:TransferShape a sh:NodeShape ; sh:targetClass fin:Transfer ;
          sh:property [ sh:path fin:amountMicros ; sh:datatype xsd:integer ;
                        sh:minCount 1 ; sh:maxCount 1 ; sh:minInclusive 1 ] ;
          sh:property [ sh:path fin:debitAccount ; sh:minCount 1 ; sh:maxCount 1 ] ;
          sh:property [ sh:path fin:counterparty ; sh:minCount 1 ; sh:maxCount 1 ] .
        """

    conforms(env, ttl, shapes, :semantics_violated)
  end

  defp envelope(env, ttl) do
    shapes =
      @prefixes <>
        """
        fin:EnvelopeShape a sh:NodeShape ; sh:targetClass fin:Transfer ;
          sh:property [ sh:path fin:amountMicros ; sh:maxInclusive #{env.envelope} ] .
        """

    conforms(env, ttl, shapes, :money_micros_envelope_exceeded)
  end

  defp ceiling(env, tx, grant) do
    data = tx_turtle(tx) <> "<#{tx.id}> fin:grantCeilingMicros #{grant.ceiling} .\n"

    shapes =
      @prefixes <>
        """
        fin:CeilingShape a sh:NodeShape ; sh:targetClass fin:Transfer ;
          sh:property [ sh:path fin:amountMicros ; sh:lessThanOrEquals fin:grantCeilingMicros ] .
        """

    conforms(env, data, shapes, :grant_ceiling_exceeded)
  end

  defp conforms(env, data, shapes, reason) do
    case Abi.call(env.abi, %{
           op: "shacl",
           data: %{text: data, dialect: "turtle"},
           shapes: shapes
         }) do
      %{"ok" => true, "conforms" => true} -> :ok
      %{"ok" => true, "conforms" => false} -> {:refused, reason}
      other -> {:refused, {:abi_error, inspect(other)}}
    end
  end

  defp signature(env, req, id) do
    pub = Map.get(env.pubs, req.key_id)

    if pub && :crypto.verify(:eddsa, :none, id, req.sig, [pub, :ed25519]),
      do: :ok,
      else: {:refused, :bad_signature}
  end

  defp key_status(env, req) do
    query = "ASK { <#{req.key_id}> <#{@fin}status> <#{@fin}Active> }"

    case Abi.call(env.abi, %{
           op: "sparql",
           data: %{text: env.registry, dialect: "turtle"},
           query: query
         }) do
      %{"ok" => true, "value" => true} -> :ok
      %{"ok" => true, "value" => false} -> {:refused, :signing_key_revoked}
      other -> {:refused, {:abi_error, inspect(other)}}
    end
  end

  defp capability(env, ttl, grant) do
    data =
      ttl <> "@prefix fin: <#{@fin}> .\n<#{grant.id}> fin:capability fin:#{grant.capability} .\n"

    query = "ASK { ?t a ?c . ?g <#{@fin}capability> ?c }"

    case Abi.call(env.abi, %{op: "sparql", data: %{text: data, dialect: "turtle"}, query: query}) do
      %{"ok" => true, "value" => true} -> :ok
      %{"ok" => true, "value" => false} -> {:refused, :capability_not_granted}
      other -> {:refused, {:abi_error, inspect(other)}}
    end
  end

  defp seal(env, current, sealed_id) do
    if canonical_id!(env, tx_turtle(current)) == sealed_id,
      do: :ok,
      else: {:refused, :effect_mutated_after_seal}
  end

  # Replay protection: the plan forbids an already-settled transaction (`pre_not`).
  defp plan_gate(env, tx, replay_guard_removed?) do
    settled = "<#{tx.id}> #{settled_pred()} \"true\" .\n"
    open = "<#{tx.account}> #{status_pred()} \"open\" .\n"
    state = Agent.get(env.state, & &1)

    resp =
      Abi.call(env.abi, %{
        op: "law",
        data: %{text: state, dialect: "nquads"},
        steps: [
          %{
            step: "plan",
            plan: %{
              actions: [
                %{
                  name: "settle:" <> tx.id,
                  pre: open,
                  pre_not: if(replay_guard_removed?, do: "", else: settled),
                  add: settled,
                  del: ""
                }
              ],
              goal: settled
            }
          }
        ]
      })

    result =
      case resp do
        %{"ok" => true, "nquads" => nquads} ->
          {:ok, nquads}

        %{"ok" => false, "error" => %{"details" => %{"code" => "PlanRefused"}}} ->
          {:refused, :already_settled}

        other ->
          {:refused, {:abi_error, inspect(other)}}
      end

    emit(:gate, tx.id, %{
      "gate" => "plan",
      "outcome" => if(match?({:ok, _}, result), do: "ok", else: "refused"),
      "reason" => if(match?({:refused, _}, result), do: str(elem(result, 1)), else: ""),
      "guard_removed" => replay_guard_removed?
    })

    case result do
      {:ok, nquads} -> {:ok, nquads}
      {:refused, reason} -> {:refused, "plan", reason}
    end
  end

  # --- journal + recovery --------------------------------------------------------------

  defp encode_tx(tx), do: Map.new(tx, fn {k, v} -> {Atom.to_string(k), v} end)

  defp decode_tx(m),
    do: %{
      id: m["id"],
      amount: m["amount"],
      account: m["account"],
      counterparty: m["counterparty"],
      capability: m["capability"]
    }

  defp journal(env, entry),
    do: File.write!(env.journal, JSON.encode!(entry) <> "\n", [:append])

  defp journal_entries(env) do
    case File.read(env.journal) do
      {:ok, bytes} ->
        bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      {:error, _} ->
        []
    end
  end

  @doc """
  Reconciles every journalled intent that never got a receipt.

  With the guard, the independent ledger is read first: an effect already
  present is *reconciled* (receipt + settled state committed, nothing
  re-executed). Without it (`without: [:reconcile]`) recovery blindly replays
  the intent.
  """
  @spec recover(%Env{}, keyword()) :: [map()]
  def recover(%Env{} = env, opts \\ []) do
    without = Keyword.get(opts, :without, [])
    entries = journal_entries(env)
    receipted = for %{"event" => "receipt", "tx_id" => id} <- entries, into: MapSet.new(), do: id

    for %{"event" => "intent", "tx" => tx, "processor" => processor} <- entries,
        not MapSet.member?(receipted, tx["id"]) do
      tx = decode_tx(tx)
      rows = Ledger.rows_for(env, tx.id)

      outcome =
        if :reconcile not in without and rows != [] do
          {:ok, admitted} = plan_admit_quiet(env, tx)
          commit_receipt(env, tx.id, :completed, admitted)
          :reconciled
        else
          {:ok, _} = process(env, tx, String.to_existing_atom(processor))
          {:ok, admitted} = plan_admit_quiet(env, tx)
          commit_receipt(env, tx.id, :completed, admitted)

          emit(:do, tx.id, %{
            "outcome" => "processed",
            "processor" => processor,
            "phase" => "recovery"
          })

          :reexecuted
        end

      emit(:reconcile, tx.id, %{"outcome" => outcome, "ledger_rows_before" => length(rows)})
      %{tx_id: tx.id, outcome: outcome}
    end
  end

  defp plan_admit_quiet(env, tx) do
    settled = "<#{tx.id}> #{settled_pred()} \"true\" .\n"
    state = Agent.get(env.state, & &1)

    case Abi.call(env.abi, %{
           op: "law",
           data: %{text: state, dialect: "nquads"},
           steps: [
             %{
               step: "plan",
               plan: %{
                 actions: [
                   %{
                     name: "settle:" <> tx.id,
                     pre: "<#{tx.account}> #{status_pred()} \"open\" .\n",
                     pre_not: settled,
                     add: settled,
                     del: ""
                   }
                 ],
                 goal: settled
               }
             }
           ]
         }) do
      %{"ok" => true, "nquads" => nquads} -> {:ok, nquads}
      other -> {:error, other}
    end
  end

  # --- scenarios (shared by the court and the non-vacuity tests) -----------------------

  defp summary(env, results, extra) do
    Map.merge(
      %{
        results: results,
        rows: Ledger.rows(env),
        envelope: env.envelope,
        ceiling: env.ceiling
      },
      extra
    )
  end

  @doc "$25M against a $9M `money_micros` envelope."
  def envelope_breach(abi, without \\ []) do
    with_env(abi, [envelope: usd(9)], fn env ->
      req = request(env, tx("env-25m", usd(25)))
      summary(env, [execute(env, req, without: without)], %{amount: usd(25)})
    end)
  end

  @doc "Control: $5M against the same $9M envelope, everything else valid."
  def within_envelope(abi) do
    with_env(abi, [envelope: usd(9)], fn env ->
      req = request(env, tx("env-5m", usd(5)))
      summary(env, [execute(env, req)], %{amount: usd(5)})
    end)
  end

  @doc "Valid semantics, signature, capability and plan; $25M against a $10M grant ceiling."
  def ceiling_breach(abi, without \\ []) do
    with_env(abi, [ceiling: usd(10)], fn env ->
      req = request(env, tx("ceil-25m", usd(25)))
      summary(env, [execute(env, req, without: without)], %{amount: usd(25)})
    end)
  end

  @doc "Control: exactly $10M against the $10M grant ceiling (inclusive)."
  def ceiling_boundary(abi) do
    with_env(abi, [ceiling: usd(10)], fn env ->
      req = request(env, tx("ceil-10m", usd(10)))
      summary(env, [execute(env, req)], %{amount: usd(10)})
    end)
  end

  @doc "Exact $100M authority whose counterparty is swapped after the effect was sealed."
  def counterparty_mutation(abi, without \\ []) do
    with_env(abi, [ceiling: usd(100)], fn env ->
      mutate = fn tx -> %{tx | counterparty: "urn:party:mallory"} end
      req = request(env, tx("exact-100m", usd(100)), mutate: mutate)
      summary(env, [execute(env, req, without: without)], %{amount: usd(100)})
    end)
  end

  @doc "Control: the same exact $100M authority with the sealed counterparty intact."
  def exact_authority(abi) do
    with_env(abi, [ceiling: usd(100)], fn env ->
      req = request(env, tx("exact-100m-ok", usd(100)))
      summary(env, [execute(env, req)], %{amount: usd(100)})
    end)
  end

  @doc "A signature that is cryptographically valid but by a revoked key."
  def revoked_key_submission(abi, without \\ []) do
    with_env(abi, [], fn env ->
      req = request(env, tx("revoked-5m", usd(5)), key: @revoked)
      summary(env, [execute(env, req, without: without)], %{amount: usd(5)})
    end)
  end

  @doc "A completed receipt's transaction submitted a second time."
  def replay(abi, without \\ []) do
    with_env(abi, [], fn env ->
      req = request(env, tx("replay-5m", usd(5)))
      first = execute(env, req, without: without)
      second = execute(env, req, without: without)
      summary(env, [first, second], %{amount: usd(5)})
    end)
  end

  @doc "The processor claims success and writes nothing; the observer reads the ledger."
  def lying_processor(abi, without \\ []) do
    with_env(abi, [], fn env ->
      req = request(env, tx("lying-5m", usd(5)), processor: :lying)
      summary(env, [execute(env, req, without: without)], %{amount: usd(5)})
    end)
  end

  @doc "Control: an honest processor; the observer agrees."
  def honest_processor(abi) do
    with_env(abi, [], fn env ->
      req = request(env, tx("honest-5m", usd(5)))
      summary(env, [execute(env, req)], %{amount: usd(5)})
    end)
  end

  @doc "The executing process is killed after the effect and before the receipt; then recovery."
  def crash_after_do(abi, without \\ []) do
    with_env(abi, [], fn env ->
      req = request(env, tx("crash-5m", usd(5)), crash_after_do: true)
      crashed = execute(env, req, without: without)
      recovered = recover(env, without: without)
      summary(env, [crashed], %{amount: usd(5), recovered: recovered})
    end)
  end

  @doc """
  A cascade: every completed hop triggers the next. `wanted` hops are demanded;
  the depth bound (default 3) stops it. `without: [:depth]` removes the bound
  (a hard cap of #{@hard_cap} exists only so a broken run terminates).
  """
  def cascade(abi, wanted, without \\ []) do
    with_env(abi, [depth_bound: 3], fn env ->
      {results, stop} = cascade_loop(env, wanted, 1, without, [])
      emit(:stop, "urn:tx:cascade-1", %{"reason" => stop, "hops" => length(results)})

      summary(env, Enum.reverse(results), %{
        stop: stop,
        wanted: wanted,
        depth_bound: env.depth_bound
      })
    end)
  end

  defp cascade_loop(env, wanted, depth, without, acc) do
    cond do
      depth > wanted ->
        {acc, "chain_end"}

      depth > env.depth_bound and :depth not in without ->
        {acc, "depth_bound"}

      depth > @hard_cap ->
        {acc, "hard_cap"}

      true ->
        tx = tx("cascade-#{depth}", usd(1))
        emit(:hop, tx.id, %{"depth" => depth})
        result = execute(env, request(env, tx), without: without)

        case result.outcome do
          :completed -> cascade_loop(env, wanted, depth + 1, without, [result | acc])
          _ -> {[result | acc], "hop_not_completed"}
        end
    end
  end
end
