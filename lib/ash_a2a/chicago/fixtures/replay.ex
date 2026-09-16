defmodule AshA2A.Chicago.Fixtures.Replay do
  @moduledoc """
  Real fixtures for the Gate 10 offline-replay court
  (`AshA2A.Chicago.Courts.OfflineReplay`, RFC-SA2A-002 §41, §92).

  ## Producer

  `produce/3` drives the real `AshA2A.CommandBus` over the real SA2A-CHAOS
  external-domain ledger (`AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect`)
  with the real durable stores of a
  `AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment` (on-disk `EKV`
  primary store + dedicated `AshA2A.ReceiptOutbox` directory), inside a
  producer process the caller kills once the chain is sealed. Per command it
  records, as links of an `AshA2A.Receipt.EvidenceChain`:

    * `prepared` -- the outbox journal bytes, read from disk at the real
      `[:ash_a2a, :command_bus, :prepare]` boundary (after the anchor was
      durably appended, before DO);
    * `final` -- the receipt read back from the EKV primary store;
    * `post_state` -- the ledger row count for the command's operation, read
      through `Ash.read!` (`Effect.rows/1`), never the actuator's reply.

  Commands carry a declared idempotency token, so the real bus's S55
  actuation claim deduplicates a retry of the same effect under a new command
  id (a `:deduplicated` receipt with no prepared anchor and no DO).

  ## Mutations

  Environment fault injection on real chain files (§10): delete, rewrite,
  swap, move, splice links; `reforge!/2` is a forger with write access who
  recomputes file digests, link chaining and (optionally) both roots with the
  engine's own public functions.

  Compiled in every environment; nothing here references `test/support`.
  """

  alias AshA2A.{Authority, Command, CommandBus, Identity, ReceiptOutbox}
  alias AshA2A.Chicago.Fixtures.ChaosReconciliation.{Effect, Environment}
  alias AshA2A.Receipt.{EvidenceChain, OfflineReplay}
  alias AshA2A.ReceiptStore.Ekv

  @principal "chicago-replay-subject"
  @agent "chicago-replay-agent"
  @prepare_event [:ash_a2a, :command_bus, :prepare]

  @spec principal() :: String.t()
  def principal, do: @principal

  # --- producer ---------------------------------------------------------------------

  @doc """
  Produces and seals a real evidence chain in `dir` from a producer process.

  Options:

    * `:executed` -- number of distinct executed effects (default 2)
    * `:dedup_retry` -- append a retry of effect 1 under a new command id that
      the real bus deduplicates (default true)
    * `:double_actuation` -- append a retry of effect 1 run with
      `actuation_dedup: :off`, so the real bus crosses the boundary again
      (default false)

  Returns `{:ok, %{seal, pid, dir, operations, command_ids}}` after the
  producer process has been killed, or `{:error, reason}`.
  """
  @spec produce(Environment.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def produce(%Environment{} = env, dir, opts \\ []) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {ref, safe_produce(env, dir, opts)})

        receive do
          :never -> :ok
        after
          900_000 -> :ok
        end
      end)

    receive do
      {^ref, {:ok, produced}} ->
        kill(pid, monitor)
        {:ok, Map.merge(produced, %{pid: pid, dir: Path.expand(dir)})}

      {^ref, {:error, reason}} ->
        kill(pid, monitor)
        {:error, reason}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, "producer exited: #{inspect(reason)}"}
    after
      300_000 ->
        kill(pid, monitor)
        {:error, "producer timed out"}
    end
  end

  defp kill(pid, monitor) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      10_000 -> :ok
    end
  end

  defp safe_produce(env, dir, opts) do
    do_produce(env, dir, opts)
  rescue
    exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp do_produce(env, dir, opts) do
    unique = System.unique_integer([:positive])
    prefix = "chicago-replay-#{unique}-"
    handler = {__MODULE__, :prepared, unique}

    :ok =
      :telemetry.attach(handler, @prepare_event, &__MODULE__.capture_prepared/4, %{
        collector: self(),
        prefix: prefix
      })

    try do
      executed = Keyword.get(opts, :executed, 2)

      specs =
        for i <- 1..executed do
          %{
            command_id: "#{prefix}c#{i}",
            operation_id: "#{prefix}op#{i}",
            token: "#{prefix}tok#{i}"
          }
        end

      [first | _] = specs

      retries =
        [
          Keyword.get(opts, :dedup_retry, true) &&
            {%{first | command_id: "#{prefix}retry"}, []},
          Keyword.get(opts, :double_actuation, false) &&
            {%{first | command_id: "#{prefix}double"}, [actuation_dedup: :off]}
        ]
        |> Enum.filter(& &1)

      steps = Enum.map(specs, &{&1, []}) ++ retries

      chain =
        Enum.reduce_while(steps, {:ok, EvidenceChain.new("#{prefix}chain")}, fn {spec, bus_opts},
                                                                                {:ok, chain} ->
          case record_command(env, chain, spec, bus_opts) do
            {:ok, chain} -> {:cont, {:ok, chain}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      with {:ok, chain} <- chain,
           {:ok, seal} <- EvidenceChain.write(chain, dir) do
        {:ok,
         %{
           seal: seal,
           operations: specs |> Enum.map(& &1.operation_id),
           command_ids: Enum.map(steps, fn {spec, _} -> spec.command_id end)
         }}
      else
        {:error, reason} -> {:error, inspect(reason)}
      end
    after
      :telemetry.detach(handler)
    end
  end

  defp record_command(env, chain, spec, bus_opts) do
    reply = CommandBus.run(command(spec), message(spec), Effect, bus_opts(env, bus_opts))

    prepared =
      receive do
        {:replay_prepared, command_id, bytes} when command_id == spec.command_id -> bytes
      after
        0 -> nil
      end

    with {:ok, final} <- Ekv.fetch(Identity.command(spec.command_id), Environment.store_opts(env)),
         {:ok, chain} <- maybe_prepared(chain, prepared) do
      observation = %{
        "command_id" => spec.command_id,
        "receipt_id" => final.receipt_id.value,
        "actuation_id" => final.actuation_id.value,
        "operation_id" => spec.operation_id,
        "reader" => "AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect.rows/1 (Ash.read!)",
        "rows" => Environment.rows(spec.operation_id)
      }

      {:ok,
       chain
       |> EvidenceChain.append_final(final)
       |> EvidenceChain.append_post_state(observation)}
    else
      :error -> {:error, "no committed receipt for #{spec.command_id}: #{inspect(reply)}"}
      {:error, reason} -> {:error, "#{spec.command_id}: #{inspect(reason)}"}
    end
  end

  defp maybe_prepared(chain, nil), do: {:ok, chain}
  defp maybe_prepared(chain, bytes), do: EvidenceChain.append_prepared(chain, bytes)

  defp bus_opts(env, extra),
    do: [store: Ekv, store_opts: Environment.store_opts(env)] ++ extra

  @doc false
  # Runs in the SUT process at the real prepare boundary: the anchor has been
  # durably appended; copy the journal bytes the SUT wrote.
  def capture_prepared(_event, _measurements, %{outcome: :prepared} = meta, config) do
    command_id = meta[:command_id]

    if is_binary(command_id) and String.starts_with?(command_id, config.prefix) and
         is_binary(meta[:receipt_id]) do
      path =
        Path.join(
          ReceiptOutbox.dir(),
          Identity.external(Identity.runtime(meta[:receipt_id])) <> ".receipt"
        )

      case File.read(path) do
        {:ok, bytes} -> send(config.collector, {:replay_prepared, command_id, bytes})
        _ -> :ok
      end
    end

    :ok
  end

  def capture_prepared(_event, _measurements, _meta, _config), do: :ok

  @doc "A real consequence-bearing command with a declared idempotency token."
  @spec command(map(), keyword()) :: Command.t()
  def command(spec, overrides \\ []) do
    capability = Environment.capability()
    principal = Identity.principal(@principal)

    Command.new(
      capability,
      Keyword.merge(
        [
          command_id: spec.command_id,
          agent_id: @agent,
          principal_id: principal,
          authority:
            Authority.new(principal, capability, token_id: "chicago-replay-" <> spec.command_id),
          input: %{"operation_id" => spec.operation_id},
          metadata: %{idempotency_key: spec.token}
        ],
        overrides
      )
    )
  end

  @spec message(map()) :: A2A.Message.t()
  def message(spec), do: Environment.message(%{"operation_id" => spec.operation_id})

  @doc "Independent reader: total ledger rows across `operations`."
  @spec rows([String.t()]) :: non_neg_integer()
  def rows(operations), do: Enum.reduce(operations, 0, &(Environment.rows(&1) + &2))

  # --- chain files -----------------------------------------------------------------

  @spec copy_chain(map(), Path.t(), String.t()) :: Path.t()
  def copy_chain(%{dir: src}, root, name) do
    dir = Path.join(root, "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp_r!(src, dir)
    dir
  end

  @spec manifest(Path.t()) :: map()
  def manifest(dir),
    do: dir |> Path.join(EvidenceChain.manifest_file()) |> File.read!() |> JSON.decode!()

  @spec write_manifest!(Path.t(), map()) :: :ok
  def write_manifest!(dir, manifest),
    do:
      File.write!(
        Path.join(dir, EvidenceChain.manifest_file()),
        EvidenceChain.canonical_json(manifest)
      )

  @doc "The link of `kind` for the `n`th command (1-based, chain order) of the manifest."
  @spec link(map(), pos_integer(), String.t()) :: map() | nil
  def link(manifest, n, kind) do
    command_id =
      manifest["links"] |> Enum.map(& &1["command_id"]) |> Enum.uniq() |> Enum.at(n - 1)

    Enum.find(manifest["links"], &(&1["command_id"] == command_id and &1["kind"] == kind))
  end

  @doc "Decodes, rewrites and re-encodes one receipt link file in place (manifest untouched)."
  @spec rewrite_receipt!(Path.t(), map(), (AshA2A.Receipt.t() -> AshA2A.Receipt.t())) :: :ok
  def rewrite_receipt!(dir, link, fun) do
    path = Path.join(dir, link["file"])
    {:ok, receipt} = path |> File.read!() |> EvidenceChain.decode_receipt()
    File.write!(path, EvidenceChain.encode_receipt(fun.(receipt)))
  end

  @doc "Rewrites one post-state observation file in place (manifest untouched)."
  @spec rewrite_post_state!(Path.t(), map(), (map() -> map())) :: :ok
  def rewrite_post_state!(dir, link, fun) do
    path = Path.join(dir, link["file"])
    observation = path |> File.read!() |> JSON.decode!()
    File.write!(path, EvidenceChain.canonical_json(fun.(observation)))
  end

  @doc "Deletes a link's file only."
  @spec delete_file!(Path.t(), map()) :: :ok
  def delete_file!(dir, link), do: File.rm!(Path.join(dir, link["file"]))

  @doc "Removes a link from the manifest and deletes its file (manifest not re-forged)."
  @spec remove_link!(Path.t(), map()) :: :ok
  def remove_link!(dir, link) do
    delete_file!(dir, link)
    m = manifest(dir)
    write_manifest!(dir, %{m | "links" => Enum.reject(m["links"], &(&1["seq"] == link["seq"]))})
  end

  @doc "Swaps two links' positions in the manifest (manifest not re-forged)."
  @spec swap_links!(Path.t(), map(), map()) :: :ok
  def swap_links!(dir, a, b) do
    m = manifest(dir)
    {seq_a, seq_b} = {a["seq"], b["seq"]}

    links =
      Enum.map(m["links"], fn
        %{"seq" => ^seq_a} -> b
        %{"seq" => ^seq_b} -> a
        link -> link
      end)

    write_manifest!(dir, %{m | "links" => links})
  end

  @doc "Moves every link of the `n`th command to the front of the manifest (not re-forged)."
  @spec move_command_first!(Path.t(), pos_integer()) :: :ok
  def move_command_first!(dir, n) do
    m = manifest(dir)
    command_id = link(m, n, "final")["command_id"]
    {moved, rest} = Enum.split_with(m["links"], &(&1["command_id"] == command_id))
    write_manifest!(dir, %{m | "links" => moved ++ rest})
  end

  @doc """
  Replays the `n`th command's links: copies their files under new names and
  appends them to the manifest (not re-forged).
  """
  @spec splice_command!(Path.t(), pos_integer()) :: :ok
  def splice_command!(dir, n) do
    m = manifest(dir)
    command_id = link(m, n, "final")["command_id"]

    copies =
      m["links"]
      |> Enum.filter(&(&1["command_id"] == command_id))
      |> Enum.map(fn link ->
        file = String.replace(link["file"], "links/", "links/replayed-")
        File.cp!(Path.join(dir, link["file"]), Path.join(dir, file))
        %{link | "file" => file}
      end)

    write_manifest!(dir, %{m | "links" => m["links"] ++ copies})
  end

  @doc """
  A forger with write access: recomputes every link's file digest and size,
  the link chaining, and the roots. `:link_root` / `:basis_root` are
  `:recompute` (default) or `:keep` (leave the manifest's recorded root).
  """
  @spec reforge!(Path.t(), keyword()) :: map()
  def reforge!(dir, opts \\ []) do
    m = manifest(dir)

    links =
      Enum.map(m["links"], fn link ->
        case File.read(Path.join(dir, link["file"])) do
          {:ok, bytes} ->
            %{link | "sha256" => EvidenceChain.sha256(bytes), "bytes" => byte_size(bytes)}

          _ ->
            link
        end
      end)

    forged = EvidenceChain.relink(%{m | "links" => links})

    forged =
      if Keyword.get(opts, :link_root, :recompute) == :keep,
        do: %{forged | "link_root" => m["link_root"]},
        else: forged

    forged =
      if Keyword.get(opts, :basis_root, :recompute) == :keep,
        do: forged,
        else: %{forged | "basis_root" => OfflineReplay.reconstruct_dir(dir, forged).basis_root}

    write_manifest!(dir, forged)
    forged
  end
end
