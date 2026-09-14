defmodule AshA2A.Test.RestartableDurableServerFixture do
  @moduledoc """
  A real `DurableServer` implementation, backed by the real
  `durable_server` hex package, used by
  `AshA2A.DurableServerRealRestartTest` to exercise the real
  `DurableServer.LifecycleManager`'s own automatic restart-after-crash
  path -- distinct from `AshA2A.Test.DurableServerFixture` (used by
  `AshA2A.RuntimeProvidersIntegrationTest`), which is never killed and so
  never needs restart eligibility.

  Two real, load-bearing differences from `DurableServerFixture`:

  1. `init/1` returns `permanent: true`. Per
     `deps/durable_server/lib/durable_server/lifecycle_manager.ex`
     (`not meta.permanent -> :ineligible` in the restart-claim
     eligibility check) and `deps/durable_server/lib/durable_server.ex`'s
     own moduledoc ("`:permanent` - Mark server for automatic restart by
     LifecycleManager (default: false)"), only servers that opt in this
     way are ever considered for automatic restart. Without this, a real
     kill would simply stay dead.
  2. `handle_call(:increment, ...)` returns `sync: true`. A bare
     `Process.exit(pid, :kill)` is untrappable, so `terminate/2` never
     runs and nothing sync-pending only in memory would reach the real
     EKV-backed storage. Explicitly syncing on every mutating call is
     what makes the post-restart recovered count real (read back from
     real durable storage) rather than coincidentally correct.
  """
  use DurableServer, vsn: 1

  @impl true
  def dump_state(state), do: %{count: Map.get(state, :count, 0)}

  # `DurableServer.Backends.EKVStore` (this fixture's real backend, same one
  # `AshA2A.RuntimeProvidersIntegrationTest` uses) round-trips
  # `dump_state/1`'s return through `DurableServer.StoredState.to_storage_term/1`
  # as a native Elixir term (real, verified by reading
  # deps/durable_server/lib/durable_server/stored_state.ex and by direct
  # observation: `DurableServer.Supervisor.get_server_info/2` showed a real
  # `user_state: %{count: 3}` -- an ATOM-keyed map -- durably persisted
  # right up to the kill). That differs from the STRING-keyed
  # (`%{"count" => count}`) shape `AshA2A.Test.DurableServerFixture` matches
  # on, which is the `ObjectStore`/S3 JSON-backend convention
  # (`StoredState.to_object_store_term/1`) -- a shape that fixture's own
  # test never actually restarts against, so its mismatch (present in that
  # fixture too, left unmodified as out of this unit's orthogonal scope) is
  # currently silent. Matching the atom-keyed shape here is load-bearing:
  # without it, real post-restart recovery silently falls through to the
  # `%{count: 0}` default below and this test would pass for the wrong
  # reason (coincidentally starting fresh) instead of proving real
  # durable-state recovery.
  @impl true
  def load_state(_old_vsn, %{count: count}), do: %{count: count}
  def load_state(_old_vsn, %{"count" => count}), do: %{count: count}
  def load_state(_old_vsn, _), do: %{count: 0}

  @impl true
  def init(state), do: {:ok, Map.put_new(state, :count, 0), permanent: true}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.count, state}

  @impl true
  def handle_call(:increment, _from, state) do
    new_state = %{state | count: state.count + 1}
    {:reply, new_state.count, new_state, sync: true}
  end
end
