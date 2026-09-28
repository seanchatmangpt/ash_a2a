defmodule AshA2A.Delivery.Oban do
  @moduledoc """
  Optional Oban delivery adapter.

  Queue insertion records delivery only. The Oban worker that eventually
  receives this payload must reconstruct an admitted command and call
  `AshA2A.CommandBus`; an Oban job id is never promoted to A2A TaskID or to an
  execution receipt.

  ## An enqueued authority is an enqueue-time snapshot, not a live grant

  Oban's whole point is to defer `perform/1` to an arbitrary later time --
  the job may sit in the queue for seconds, minutes, or (after a crash and
  retry) much longer. `payload/1` carries only the admitted command's content
  across that gap; it does NOT keep the principal's real capability grant
  live. A worker that reconstructs an `AshA2A.Authority` from `args` and
  hands it straight to `AshA2A.CommandBus` is replaying whatever the grant
  looked like at enqueue time, not asking whether it still stands now.

  Two independent ways that snapshot can go stale before `perform/1` runs:

    * **Expiry** -- `payload/1` carries `"authority_expires_at"` (the grant's
      real time bound, additive since this field was introduced) precisely so
      a worker using `AshA2A.Delivery.ObanAuthority.reconstruct/2` restores
      the ORIGINAL `expires_at` rather than always reconstructing
      `expires_at: nil`. Without it, `AshA2A.Authority.expired?/1` -- which
      itself compares against `DateTime.utc_now()` at call time, so it is
      already "live" given a real timestamp -- could never observe an expiry
      that had, in real wall-clock time, already passed.
    * **Revocation** -- no timestamp on the wire can ever encode "the broker
      revoked this grant after I enqueued the job." Only a live re-query of
      the configured `AshA2A.Authority.Broker` at `perform/1` time can catch
      that. `AshA2A.Delivery.ObanAuthority.verify_live!/3` is the explicit,
      opt-in helper for exactly this: it re-checks
      `AshA2A.Authority.Broker.granted?/3` against the SAME broker the
      synchronous dispatch path (`AshA2A.Authority.Grant.authorize/3`)
      consults, so a principal whose grant was revoked (or simply never
      existed under this broker) does not silently regain ambient DO merely
      because their command sat in a queue.

  A worker is not required to call `verify_live!/3` -- `reconstruct/2` alone
  fixes expiry, which covers a caller with no broker configured at all -- but
  a worker that wants the authority it dispatches with to reflect the
  broker's REAL, CURRENT standing (not just "not yet past its original
  expiry") must call it explicitly. `AshA2A.Test.Support.CommandWorker` is
  this repo's own reference implementation and restores `expires_at` via
  `reconstruct/2`; see `test/ash_a2a/oban_authority_staleness_test.exs` for a
  real, broker-backed regression proof of both halves of this gap.

  ## Enqueue deduplication and in-flight retries

  `enqueue/3` applies `unique_opts/0` by default, so the same command
  (`command_id` + `fingerprint`) is held by at most one live job. Host
  workers should map the `AshA2A.CommandBus` result with `perform_result/2`
  so a claim still held elsewhere snoozes instead of burning attempts.
  """

  alias AshA2A.{Authority, Command, Delivery, Identity, SemanticSubject}

  @in_flight_codes [:in_flight, :actuation_in_flight]

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Oban.Job)

  @spec payload(Command.t()) :: map()
  def payload(%Command{} = command) do
    %{
      "command_id" => Identity.external(command.command_id),
      "agent_id" => Identity.external(command.agent_id),
      "principal_id" => Identity.external(command.principal_id),
      "task_id" => external_or_nil(command.task_id),
      "capability_id" => command.capability_id,
      "fingerprint" => command.fingerprint,
      "input" => command.input,
      "authority_token_id" => authority_token(command.authority),
      "authority_expires_at" => authority_expires_at(command.authority),
      "metadata" => command.metadata
    }
    |> Map.merge(semantic_subject_fields(command.semantic_subject))
  end

  @spec enqueue(module(), Command.t(), keyword()) :: {:ok, Delivery.t()} | {:error, term()}
  def enqueue(worker, %Command{} = command, opts \\ []) when is_atom(worker) do
    if available?() do
      job_opts =
        opts
        |> Keyword.get(:job_opts, [])
        |> Keyword.put(:worker, worker)
        |> Keyword.put_new(:unique, unique_opts())

      changeset = apply(Oban.Job, :new, [payload(command), job_opts])

      result =
        case Keyword.get(opts, :name) do
          nil -> apply(Oban, :insert, [changeset])
          name -> apply(Oban, :insert, [name, changeset])
        end

      case result do
        {:ok, job} ->
          {:ok,
           Delivery.new(:oban, command,
             provider_ref: Map.get(job, :id),
             status: :scheduled,
             metadata: %{worker: worker, deduplicated?: Map.get(job, :conflict?, false) == true}
           )}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:unsupported, :oban}}
    end
  end

  @doc """
  Default Oban `:unique` options applied by `enqueue/3`.

  One live job per `(worker, command_id, fingerprint)`: a second enqueue of
  the same admitted command (client retry, or a web node and a reactor both
  delivering it) returns the existing job (`Delivery.metadata.deduplicated?`
  is `true`) instead of inserting a duplicate that would only collide with
  the first on the `AshA2A.CommandBus` claim. `:completed` is included so a
  re-enqueue after success is also collapsed (CommandBus would only replay
  the receipt); `:cancelled` and `:discarded` are excluded so a dead job can
  be legitimately re-enqueued. The fingerprint is part of the key so a
  same-id/different-content command is NOT silently absorbed -- it is
  inserted and then refused by CommandBus as `:command_conflict`.

  A caller may override via `job_opts: [unique: ...]` (including
  `unique: false` to opt out).
  """
  @spec unique_opts() :: keyword()
  def unique_opts do
    [
      fields: [:args, :worker],
      keys: [:command_id, :fingerprint],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :completed, :suspended]
    ]
  end

  @doc """
  Maps an `AshA2A.CommandBus.run/4` result to an `Oban.Worker.perform/1`
  return value. Host workers should return `perform_result(CommandBus.run(...))`.

    * `{:ok, _}` / `:ok` -> `:ok`
    * a claim still held by another executor (`:in_flight`,
      `:actuation_in_flight`, bare or as `%{code: ...}`) -> `{:snooze, seconds}`
      (default 30). Snoozing does not consume an attempt, so a concurrent
      duplicate delivery cannot exhaust `max_attempts` and discard a
      legitimate job while the first attempt is still running.
    * any other `{:error, reason}` passes through unchanged.
  """
  @spec perform_result(term(), pos_integer()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  def perform_result(result, snooze_seconds \\ 30)
      when is_integer(snooze_seconds) and snooze_seconds > 0 do
    case result do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, %{code: code}} when code in @in_flight_codes -> {:snooze, snooze_seconds}
      {:error, code} when code in @in_flight_codes -> {:snooze, snooze_seconds}
      {:error, _} = error -> error
      other -> {:error, {:unexpected_command_bus_result, other}}
    end
  end

  defp external_or_nil(nil), do: nil
  defp external_or_nil(%Identity{} = identity), do: Identity.external(identity)

  defp authority_token(%Authority{token_id: token_id}), do: Identity.external(token_id)
  defp authority_token(_), do: nil

  # Additive-only, mirroring `semantic_subject_fields/1` below: a nil
  # `expires_at` (every existing caller today, since `Authority.new/3`
  # defaults to no time bound) serializes to `nil` here too, so this field's
  # presence changes nothing for an already-shipped standing/unbounded
  # authority. A real `expires_at` round-trips as its own ISO 8601 string --
  # never re-derived, never trusted from anywhere else -- so
  # `AshA2A.Delivery.ObanAuthority.reconstruct/2` can restore the ORIGINAL
  # time bound instead of the enqueue-time reconstruction silently becoming
  # unbounded (see this module's moduledoc).
  defp authority_expires_at(%Authority{expires_at: nil}), do: nil

  defp authority_expires_at(%Authority{expires_at: %DateTime{} = expires_at}),
    do: DateTime.to_iso8601(expires_at)

  defp authority_expires_at(_), do: nil

  # Additive-only: when `semantic_subject` is nil (the already-tested,
  # already-shipped case), this returns %{} and `Map.merge/2` leaves the
  # base payload map byte-identical to before this field existed. When
  # non-nil, every field `AshA2A.Command.fingerprint/1` actually folds in
  # via `SemanticSubject.fingerprint_token/1` (graph_digest,
  # projection_digest, manufacturer_digest, ephemeral?) rides along on the
  # wire, so a worker reconstructing the command (e.g.
  # `AshA2A.Test.Support.CommandWorker.reconstruct_command/1`) can rebuild
  # the exact same `AshA2A.SemanticSubject` and therefore recompute the
  # exact same fingerprint -- never trusting the carried `"fingerprint"`
  # string itself as executable truth (see that module's own moduledoc).
  defp semantic_subject_fields(nil), do: %{}

  defp semantic_subject_fields(%SemanticSubject{} = subject) do
    %{
      "semantic_subject_graph_digest" => subject.graph_digest,
      "semantic_subject_projection_digest" => subject.projection_digest,
      "semantic_subject_manufacturer_digest" => subject.manufacturer_digest,
      "semantic_subject_ephemeral" => subject.ephemeral?
    }
  end
end
