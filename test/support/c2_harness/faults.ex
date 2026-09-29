defmodule C2Harness.Faults do
  @moduledoc """
  Fault-injection attacks against the actuator (RFC-SA2A-006 s26 crash items, s29). Each
  attack repeats `env.n` times (default 20, at most 50) with the actuator process killed at
  the fault point; every iteration uses a fresh effect instance, a fresh journaled
  issuance, and is judged by the same ledger oracle.

    * F01 `after_write_ahead`: durable claim written, DO not yet performed. The instrumented
      `Actuator.Store` parks at that point (rendezvous) and the harness delivers a real `kill -9`. Ledger must stay at 0 entries for the
      effect, the instance must come back `unknown_outcome`, and neither certificate replay
      nor a fresh-generation certificate may cause a DO.
    * F02 `after_perform`: DO performed (one ledger entry), completion not journaled. After
      restart the instance is `unknown_outcome`; replay returns evidence and performs nothing:
      the ledger keeps exactly one entry.
    * F03 restart after unknown outcome: F02's crash followed by further real `kill -9`
      restarts with a retry after each; the only exit from `unknown_outcome` is the
      operator `reconcile`, which is not reachable on the wire.
    * F04 external SIGKILL at a random moment of an in-flight request (seeded jitter), any
      fault point including before/inside the fence and mid-fsync; afterwards ledger entries
      for the effect <= 1 whatever the kill point.

  The crash points F01/F02 need `Actuator.Store` compiled with `fault_hook: true` (the
  actuator's test env); the hosts in this court always are. F04 needs no hook.
  """
  alias C2Harness.{Attack, Env}

  defp m(attck, capec, atlas), do: %{attck: attck, capec: capec, atlas: atlas}

  def attacks do
    [
      %Attack{
        id: "C2C-F01",
        title: "crash after the durable claim, before the DO (halt 137), N restarts",
        s26: ["worker crash before DO"],
        faults: true,
        checks: [14, 16],
        expect: ["transport_closed", "replayed", "unknown_outcome"],
        mapping: m(["T1499", "T1529"], ["CAPEC-125"], ["AML.T0029"]),
        run: fn env -> crash_series(env, :after_write_ahead) end
      },
      %Attack{
        id: "C2C-F02",
        title: "crash after the DO, before the completion is journaled (halt 137), N restarts",
        s26: ["crash during uncertain DO"],
        faults: true,
        checks: [14],
        killers_for: [14],
        expect: ["transport_closed", "replayed", "unknown_outcome"],
        mapping: m(["T1499", "T1529"], ["CAPEC-125", "CAPEC-26"], ["AML.T0029"]),
        run: fn env -> crash_series(env, :after_perform) end
      },
      %Attack{
        id: "C2C-F03",
        title:
          "restart after unknown outcome: repeated kill -9 restarts with retries, reconcile not on the wire",
        s26: ["restart after unknown outcome", "duplicated DO"],
        faults: true,
        checks: [14, 15],
        killers_for: [14],
        expect: ["transport_closed", "replayed", "malformed_request"],
        mapping: m(["T1499", "T1550"], ["CAPEC-60", "CAPEC-26"], ["AML.T0029"]),
        run: &restart_series/1
      },
      %Attack{
        id: "C2C-F04",
        title: "external SIGKILL at a random moment of an in-flight request, N restarts",
        s26: ["worker crash before DO", "crash during uncertain DO"],
        faults: true,
        checks: [14, 15],
        killers_for: [14],
        mapping: m(["T1499", "T1529"], ["CAPEC-26", "CAPEC-125"], ["AML.T0029"]),
        run: &sigkill_series/1
      }
    ]
  end

  # ---- series -------------------------------------------------------------------------------------

  defp crash_series(env, point) do
    rows =
      for _ <- 1..env.n do
        e = Env.effect()
        l = Env.issue!(env, e)
        crash_once(env, l, point)
        restart(env)
        statuses = for _ <- 1..3, do: Env.submit(env, l.effect, l.cert)[:status]
        # a fresh-generation certificate for the same instance (mis-issued, so it is not an
        # extra authorization) must not open the claim either
        g2 = Env.misissue!(env, e, generation: 2)
        r2 = Env.submit(env, g2.effect, g2.cert)

        %{
          digest: l.digest,
          statuses: statuses,
          gen2: r2[:refusal],
          ledger: entries_for(env, l.digest),
          state: state(env, e)
        }
      end

    summarize(rows, point)
  end

  defp restart_series(env) do
    rows =
      for _ <- 1..env.n do
        e = Env.effect()
        l = Env.issue!(env, e)
        crash_once(env, l, :after_perform)
        restart(env)
        first = Env.submit(env, l.effect, l.cert)[:status]
        Env.kill_actuator(env)
        restart(env)
        second = Env.submit(env, l.effect, l.cert)[:status]
        Env.kill_actuator(env)
        restart(env)
        third = Env.submit(env, l.effect, l.cert)[:status]
        # reconcile is an operator action, not a wire operation
        Env.frame(
          env,
          Jason.encode!(%{
            "op" => "reconcile",
            "effect_instance_id" => e["effect_instance_id"],
            "resolution" => "confirmed_not_performed"
          })
        )

        %{
          digest: l.digest,
          statuses: [first, second, third],
          ledger: entries_for(env, l.digest),
          state: state(env, e)
        }
      end

    summarize(rows, :restart_after_unknown)
  end

  # A burst of @burst distinct effects is in flight when a real SIGKILL lands at a random
  # microsecond offset, so the kill falls before, inside and after individual requests (a single
  # request completes in ~2 ms, faster than a kill can be delivered). After the restart every
  # certificate is presented again; per effect, ledger entries must stay <= 1.
  @burst 24

  defp sigkill_series(env) do
    :rand.seed(:exsss, env.seed)

    rows =
      for _ <- 1..env.n do
        ls = for _ <- 1..@burst, do: Env.issue!(env, Env.effect())
        tasks = for l <- ls, do: Task.async(fn -> Env.submit(env, l.effect, l.cert) end)
        spin(:rand.uniform(30_000))
        Env.kill_actuator(env)
        firsts = Enum.map(tasks, &Task.await(&1, 60_000))
        restart(env)

        states =
          for l <- ls do
            {:ok, e} = Jason.decode(l.effect)
            state(env, e)
          end

        retries = for l <- ls, do: Env.submit(env, l.effect, l.cert)
        counts = for l <- ls, do: entries_for(env, l.digest)

        %{
          digests: Enum.map(ls, & &1.digest),
          states: Enum.frequencies(states),
          first: Enum.frequencies(Enum.map(firsts, &(&1[:status] || &1[:refusal]))),
          retry: Enum.frequencies(Enum.map(retries, &(&1[:status] || &1[:refusal]))),
          max_entries: Enum.max(counts)
        }
      end

    %{
      authorized: Enum.flat_map(rows, & &1.digests),
      iterations: length(rows),
      notes: [
        {:point, :sigkill_random_burst},
        {:burst_size, @burst},
        {:state_after_kill, merge_freq(rows, :states)},
        {:first_attempt, merge_freq(rows, :first)},
        {:retry, merge_freq(rows, :retry)},
        {:max_ledger_entries_for_one_effect, rows |> Enum.map(& &1.max_entries) |> Enum.max()}
      ]
    }
  end

  defp merge_freq(rows, key) do
    Enum.reduce(rows, %{}, fn r, acc -> Map.merge(acc, r[key], fn _, a, b -> a + b end) end)
  end

  # ---- pieces ------------------------------------------------------------------------------------------

  # Park the actuator exactly at the armed fault point (the instrumented Store writes
  # <ctl>/at_fault and blocks), then deliver a REAL `kill -9` from outside.
  defp crash_once(env, l, point) do
    Env.arm_crash(env, point)
    Process.sleep(120)
    task = Task.async(fn -> Env.submit(env, l.effect, l.cert) end)
    wait_at_fault(env, point)
    :ok = Env.kill_actuator(env)
    r = Task.await(task, 60_000)

    unless r[:transport],
      do: raise("actuator answered a request that was killed at #{point}: #{inspect(r)}")

    :ok
  end

  defp wait_at_fault(env, point, tries \\ 1000) do
    cond do
      Env.at_fault(env) == Atom.to_string(point) -> :ok
      tries == 0 -> raise "actuator never reached fault point #{point}"
      true -> Process.sleep(5) && wait_at_fault(env, point, tries - 1)
    end
  end

  defp spin(us) do
    stop = System.monotonic_time(:microsecond) + us
    Stream.repeatedly(fn -> System.monotonic_time(:microsecond) end) |> Enum.find(&(&1 >= stop))
    :ok
  end

  defp restart(env) do
    :ok = Env.restart_actuator(env)
    :ok = Env.wait_healthy(env)
  end

  defp entries_for(env, digest) do
    case Env.ledger(env) do
      {:ok, e} -> Enum.count(e, &(&1["effect_digest"] == digest))
      {:error, why, _} -> raise "ledger unreadable: #{inspect(why)}"
    end
  end

  defp state(env, e) do
    case Env.status(env, e["effect_instance_id"]) do
      %{ok: true, evidence: %{"state" => s}} -> s
      %{refusal: r} -> "none:" <> to_string(r)
    end
  end

  defp summarize(rows, point) do
    %{
      authorized: Enum.map(rows, & &1.digest),
      iterations: length(rows),
      notes: [
        {:point, point},
        {:ledger_entries_per_effect, rows |> Enum.frequencies_by(& &1.ledger)},
        {:final_state, rows |> Enum.frequencies_by(& &1[:state])},
        {:retry_statuses, rows |> Enum.flat_map(& &1.statuses) |> Enum.frequencies()},
        {:gen2_refusal, rows |> Enum.frequencies_by(& &1[:gen2])},
        {:state_after_kill, rows |> Enum.frequencies_by(& &1[:state_after_kill])}
      ]
    }
  end
end
