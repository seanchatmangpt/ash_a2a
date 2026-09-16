defmodule AshA2A.Chicago.Collaborators.DurabilityProbe do
  @moduledoc """
  Proves -- never takes on declaration -- whether an `AshA2A.ReceiptStore`
  module keeps committed receipts across a real restart (RFC-SA2A-002 §34).

  `AshA2A.CommandBus` stamps `standing: :durable` on every receipt committed
  to a store that merely *declares* `durable?/0 -> true`. This probe is the
  independent check of that declaration:

      write  -- claim + commit a real nonce receipt through the store's own API
      restart -- terminate the store's real process through its supervisor and
                 start it again (new pid, same configuration / data_dir)
      read   -- fetch the receipt by command id through the store's own API
      replay -- re-claim the same command: a durable store must answer :replay,
                not :execute (replay protection survives the restart)

  `proven?` is true only when all four hold.

  ## Isolation

  The probe never restarts the application's live store instance (that would
  drop in-flight state for every other caller). It starts a fresh,
  uniquely-named instance of the *configured store module* under a private
  supervisor, with its own data directory under `:probe_dir`, and tears it down
  afterwards. The claim it proves is therefore about the store module's
  durability semantics on that volume, not about a particular running pid.

  A store module with no startable process (`child_spec/1`) cannot be
  restarted by the probe, so its durability is `proven?: false` with the reason
  recorded -- UNKNOWN is not durable.

  The whole probe runs in a dedicated exit-trapping process so a store that
  crashes on start cannot take the caller down with it.

  ## Telemetry

  `[:ash_a2a, :chicago, :collaborators, :durability_probe]` once per stage,
  metadata `%{store:, stage: :write | :restart | :read | :replay | :verdict,
  outcome:, command_id:}`.
  """

  alias AshA2A.{Command, Receipt}

  @event [:ash_a2a, :chicago, :collaborators, :durability_probe]
  @capability "ash_a2a.chicago.collaborators.durability_probe"
  @restart "supervised_terminate_restart"

  @type result :: %{
          store: module(),
          restart: String.t(),
          lifecycle: :supervised | :unsupported,
          write: :committed | :failed | :skipped,
          restarted?: boolean(),
          read: :found | :missing | :mismatch | :failed | :skipped,
          replay: :replay | :execute | :failed | :skipped,
          proven?: boolean(),
          command_id: String.t() | nil,
          detail: String.t() | nil
        }

  @spec event() :: [atom()]
  def event, do: @event

  @doc """
  Runs the probe against `store`. Options: `:probe_dir` (parent directory for
  the probe instance's data, default `System.tmp_dir!()`), `:timeout_ms`
  (default 60_000).
  """
  @spec run(module(), keyword()) :: result()
  def run(store, opts \\ []) when is_atom(store) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        send(caller, {ref, probe(store, opts)})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        finish(base(store, nil), "probe process exited: #{inspect(reason, limit: 20)}")
    after
      timeout ->
        Process.exit(pid, :kill)
        finish(base(store, nil), "probe exceeded #{timeout}ms")
    end
  end

  defp probe(store, opts) do
    nonce = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    name = :"ash_a2a_chicago_durability_probe_#{nonce}"
    data_dir = Path.join(Keyword.get(opts, :probe_dir, System.tmp_dir!()), Atom.to_string(name))

    command =
      Command.new(@capability,
        command_id: "chicago-durability-probe-" <> nonce,
        agent_id: "ash_a2a.chicago",
        principal_id: "ash_a2a.chicago.collaborators",
        input: %{"nonce" => nonce}
      )

    result = base(store, command.command_id.value)

    case lifecycle(store, name, data_dir) do
      {:ok, child, store_opts} ->
        try do
          supervised(result, store, child, store_opts, command)
        after
          File.rm_rf(data_dir)
        end

      {:unsupported, detail} ->
        emit(result, :write, :skipped)
        finish(%{result | lifecycle: :unsupported}, detail)
    end
  rescue
    exception ->
      finish(base(store, nil), "probe raised: " <> Exception.message(exception))
  end

  defp supervised(result, store, child, store_opts, command) do
    case Supervisor.start_link([Supervisor.child_spec(child, id: :store)],
           strategy: :one_for_one,
           max_restarts: 0
         ) do
      {:ok, sup} ->
        try do
          result
          |> write(store, store_opts, command)
          |> restart(sup)
          |> read(store, store_opts, command)
          |> replay(store, store_opts, command)
          |> verdict()
        after
          stop(sup)
        end

      {:error, reason} ->
        emit(result, :write, :failed)
        finish(result, "store instance failed to start: #{inspect(reason, limit: 20)}")
    end
  end

  # --- stages ---------------------------------------------------------------

  defp write(result, store, store_opts, command) do
    with {:execute, execution_id} <- store.claim(command, store_opts),
         receipt = Receipt.from_reply(command, execution_id, :observe, {:reply, []}),
         :ok <- store.commit(receipt, store_opts) do
      emit(result, :write, :committed)
      Map.put(%{result | write: :committed}, :receipt, receipt)
    else
      other ->
        emit(result, :write, :failed)
        %{result | write: :failed, detail: "write returned #{inspect(other, limit: 20)}"}
    end
  catch
    kind, reason ->
      emit(result, :write, :failed)
      %{result | write: :failed, detail: "write #{kind}: #{inspect(reason, limit: 20)}"}
  end

  defp restart(%{write: :committed} = result, sup) do
    with [{:store, old_pid, _, _}] when is_pid(old_pid) <- Supervisor.which_children(sup),
         :ok <- Supervisor.terminate_child(sup, :store),
         false <- Process.alive?(old_pid),
         {:ok, new_pid} when is_pid(new_pid) and new_pid != old_pid <-
           Supervisor.restart_child(sup, :store) do
      emit(result, :restart, :restarted)
      %{result | restarted?: true}
    else
      other ->
        emit(result, :restart, :failed)
        %{result | detail: "restart did not complete: #{inspect(other, limit: 20)}"}
    end
  catch
    kind, reason ->
      emit(result, :restart, :failed)
      %{result | detail: "restart #{kind}: #{inspect(reason, limit: 20)}"}
  end

  defp restart(result, _sup), do: result

  defp read(%{restarted?: true, receipt: written} = result, store, store_opts, command) do
    outcome =
      case store.fetch(command.command_id, store_opts) do
        {:ok, %Receipt{receipt_id: id, fingerprint: fp}}
        when id == written.receipt_id and fp == written.fingerprint ->
          :found

        {:ok, _other} ->
          :mismatch

        _ ->
          :missing
      end

    emit(result, :read, outcome)
    %{result | read: outcome}
  catch
    kind, reason ->
      emit(result, :read, :failed)
      %{result | read: :failed, detail: "read #{kind}: #{inspect(reason, limit: 20)}"}
  end

  defp read(result, _store, _store_opts, _command), do: result

  defp replay(%{read: :found} = result, store, store_opts, command) do
    outcome =
      case store.claim(command, store_opts) do
        {:replay, %Receipt{}} -> :replay
        {:execute, _} -> :execute
        _ -> :failed
      end

    emit(result, :replay, outcome)
    %{result | replay: outcome}
  catch
    kind, reason ->
      emit(result, :replay, :failed)
      %{result | replay: :failed, detail: "replay #{kind}: #{inspect(reason, limit: 20)}"}
  end

  defp replay(result, _store, _store_opts, _command), do: result

  defp verdict(result) do
    proven? =
      result.write == :committed and result.restarted? and result.read == :found and
        result.replay == :replay

    detail =
      result.detail ||
        if proven?,
          do: nil,
          else: "receipt written before restart was #{result.read} after restart"

    finish(%{result | proven?: proven?}, detail)
  end

  # --- lifecycle ------------------------------------------------------------

  # `AshA2A.ReceiptStore.Ekv` has no process of its own: its durable state
  # lives in a separately supervised `EKV` instance, the same one
  # `AshA2A.Application.receipt_store_children/0` starts for it.
  defp lifecycle(AshA2A.ReceiptStore.Ekv, name, data_dir) do
    {:ok, _} = Application.ensure_all_started(:ekv)
    {:ok, {EKV, name: name, data_dir: data_dir, cluster_size: 1}, [name: name]}
  end

  defp lifecycle(store, name, data_dir) do
    if Code.ensure_loaded?(store) and function_exported?(store, :child_spec, 1) do
      File.mkdir_p!(data_dir)
      {:ok, {store, [name: name, data_dir: data_dir]}, [name: name]}
    else
      {:unsupported,
       "#{inspect(store)} exports no child_spec/1: no real restart can be performed, " <>
         "so durability cannot be proven"}
    end
  end

  defp stop(sup) do
    Supervisor.stop(sup, :normal, 10_000)
  catch
    :exit, _reason ->
      Process.exit(sup, :kill)
      :ok
  end

  # --- result helpers -------------------------------------------------------

  defp base(store, command_id) do
    %{
      store: store,
      restart: @restart,
      lifecycle: :supervised,
      write: :skipped,
      restarted?: false,
      read: :skipped,
      replay: :skipped,
      proven?: false,
      command_id: command_id,
      detail: nil
    }
  end

  defp finish(result, detail) do
    emit(result, :verdict, if(result.proven?, do: :proven, else: :unproven))
    result |> Map.delete(:receipt) |> Map.put(:detail, detail)
  end

  defp emit(result, stage, outcome) do
    :telemetry.execute(@event, %{system_time: System.system_time()}, %{
      store: result.store,
      stage: stage,
      outcome: outcome,
      command_id: result.command_id
    })
  end
end
