defmodule AshA2A.KillSwitch do
  @moduledoc """
  A class-level kill switch: halts every agent/worker sharing a caller-chosen
  "class" (any term this module normalizes to a string -- typically a
  capability_id prefix or a resource module name) with one `trip/3` call,
  independent of `AshA2A.CommandBus`'s existing real per-command fail-closed
  admission (`AshA2A.CommandBus.admit/2`). That existing gate refuses one
  command at a time, at dispatch, per its own authority check; nothing in
  this repo today halts an entire already-running class in one move. This
  module is that missing primitive.

  ## Fail-safe asymmetry (deliberate, not an oversight)

  `trip/3` requires NO `AshA2A.Authority`. Tripping is the SAFE direction
  for a kill switch: a false positive (tripped when it did not strictly
  need to be) costs a paused class of workers until someone resets it; a
  false negative (unable to halt a class during a real incident because the
  caller lacked the "right" authority at the exact moment it mattered) is
  the one failure mode a kill switch exists to prevent. So halting is
  deliberately as close to zero-barrier as this codebase gets -- any caller
  that can reach this `GenServer` can trip any class, on purpose, the same
  way a physical emergency-stop button is never behind a lock.

  `reset/4` is the opposite direction: resuming a halted class is the
  consequential one (workers immediately resume taking new work), so it is
  real-authority-gated using the same `AshA2A.Authority.admits?/2` this
  codebase already uses for command admission, against the documented
  capability convention `"kill_switch:reset:\#{class}"` (see
  `reset_capability_id/1`). A caller without a real, unexpired
  `AshA2A.Authority` whose `capability_id` matches that convention cannot
  resume a class, full stop, and a failed reset attempt never partially
  clears the tripped state.

  ## A real, independently-sourced expected principal is required (not optional)

  `AshA2A.CommandBus.admit/2` checks `Authority.admits?/2` against a
  `principal_id` sourced INDEPENDENTLY of the authority struct being
  checked (`Command.principal_id`, bound at command-construction time from
  the real caller's own verified identity -- `command.ex`,
  `command_bus.ex`). An earlier version of `reset/4` (real, adversarially
  found and fixed before this module ever shipped) compared
  `authority.subject` against itself
  (`principal_id: authority.subject`) -- a tautology: any caller able to
  construct an `AshA2A.Authority.t()` naming the right (public, exported)
  `reset_capability_id/1` string passed this check regardless of whose
  identity that authority actually names, because nothing independent was
  ever compared against. `reset/4` now REQUIRES the caller to separately
  supply `expected_principal` (the real, independently-known identity of
  whoever is attempting the reset -- e.g. a transport-verified session
  identity, never derived from the authority argument itself) and checks
  `authority.subject == expected_principal` for real, the same
  independent-source discipline `Command.principal_id` already gives
  `admit/2`.

  ## Scope: a real, isolated primitive -- not wired into dispatch

  This module is deliberately NOT wired into `AshA2A.CommandBus.admit/2`,
  `AshA2A.Dispatcher`, or any other existing admission/dispatch path --
  `tripped?/1` is not consulted anywhere on the real command-execution path
  today, and `mix ash_a2a.verify_architecture`'s gates are unchanged by this
  module's existence. Wiring a class kill switch into live command
  admission is a larger, separate, and riskier change (which commands
  belong to which class? does a trip mid-flight cancel in-progress work or
  only refuse new admission? what's the blast radius of one bad `trip/3`
  call reaching production dispatch?) intentionally left out of scope here.
  This branch proves the mechanism works in isolation, against its own real
  demo workers (`AshA2A.Test.Support.KillSwitchDemo.Worker`, real
  `GenServer` processes -- see `test/ash_a2a/kill_switch_test.exs`), not
  that it is safe to flip on for real traffic.

  ## One global switchboard by default

  `trip/3` and `reset/4` accept `opts[:name]` (default `__MODULE__`),
  matching this codebase's existing `AshA2A.ReceiptStore.Memory` idiom for a
  swappable server target. `tripped?/1`'s fixed single-argument signature
  always checks the default `__MODULE__`-registered instance -- the common
  case this module is built for is one node-wide switchboard tracking many
  classes in a single process's state (a `class` is just a map key), which
  is exactly what `tripped?/1`'s deliberately minimal signature and the
  demo/tests below exercise. A host that starts a second, independently
  named instance via `opts[:name]` on `trip/3`/`reset/4` is responsible for
  checking that instance's state itself (e.g. `GenServer.call(name,
  ...)`) -- `tripped?/1` does not discover it.
  """

  use GenServer

  alias AshA2A.{Authority, Identity}

  @type class :: String.t() | atom()
  @type reason :: term()
  @type trip_info :: %{reason: reason(), tripped_at: DateTime.t()}

  @doc """
  The `AshA2A.Authority.t()` `capability_id` convention `reset/4` checks
  authority against for a given `class`. Documented and exported so a host
  minting authorities for kill-switch operators has one real source of
  truth for the string, rather than reconstructing it by hand at each call
  site.
  """
  @spec reset_capability_id(class()) :: String.t()
  def reset_capability_id(class), do: "kill_switch:reset:#{normalize(class)}"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(state), do: {:ok, state}

  @doc """
  Trips (halts) `class`. Real, low-barrier, no authority required -- see
  the moduledoc's "Fail-safe asymmetry" section for why. `reason` is
  arbitrary caller-supplied evidence (an atom, a string, an incident id --
  whatever the caller has) recorded alongside a real `DateTime.utc_now/0`
  timestamp (overridable via `opts[:tripped_at]` for deterministic tests).
  Idempotent: tripping an already-tripped class simply replaces the
  recorded reason/timestamp with the latest trip.
  """
  @spec trip(class(), reason(), keyword()) :: :ok
  def trip(class, reason, opts \\ []) do
    tripped_at = Keyword.get(opts, :tripped_at, DateTime.utc_now())
    GenServer.call(server(opts), {:trip, normalize(class), reason, tripped_at})
  end

  @doc """
  Real, fast, read-only check of whether `class` is currently tripped.
  Always checks the default `__MODULE__`-registered instance (see
  moduledoc). Returns `{true, reason}` when tripped (the same `reason`
  `trip/3` recorded), `false` otherwise.
  """
  @spec tripped?(class()) :: {true, reason()} | false
  def tripped?(class) do
    GenServer.call(__MODULE__, {:tripped?, normalize(class)})
  end

  @doc """
  Resumes `class`. REQUIRES a real, valid `AshA2A.Authority.t()` whose
  `capability_id` matches `reset_capability_id(class)`, has not expired,
  AND whose `subject` real-matches `expected_principal` -- a real,
  independently-sourced identity the caller supplies separately from
  `authority` itself (see the moduledoc's "independently-sourced expected
  principal" section for why this independence is the whole point: an
  authority struct's own self-reported `subject` field is never trusted
  as its own proof of identity).

  A missing, wrong-capability, expired, subject-mismatched, or
  non-`AshA2A.Authority.t()` authority real-fails closed with
  `{:error, :authority_mismatch}` and leaves the class exactly as tripped
  as it was -- never a partial reset.
  """
  @spec reset(class(), Authority.t() | nil, Identity.t() | nil, keyword()) ::
          :ok | {:error, :authority_mismatch}
  def reset(class, authority, expected_principal, opts \\ [])

  def reset(class, %Authority{} = authority, %Identity{} = expected_principal, opts) do
    class = normalize(class)

    admitted =
      Authority.admits?(authority, %{
        principal_id: expected_principal,
        capability_id: reset_capability_id(class)
      })

    if admitted do
      GenServer.call(server(opts), {:reset, class})
    else
      {:error, :authority_mismatch}
    end
  end

  def reset(_class, _authority, _expected_principal, _opts), do: {:error, :authority_mismatch}

  @impl true
  def handle_call({:trip, class, reason, tripped_at}, _from, state) do
    {:reply, :ok, Map.put(state, class, %{reason: reason, tripped_at: tripped_at})}
  end

  @impl true
  def handle_call({:tripped?, class}, _from, state) do
    case Map.get(state, class) do
      %{reason: reason} -> {:reply, {true, reason}, state}
      nil -> {:reply, false, state}
    end
  end

  @impl true
  def handle_call({:reset, class}, _from, state) do
    {:reply, :ok, Map.delete(state, class)}
  end

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)

  defp normalize(class) when is_binary(class), do: class
  defp normalize(class) when is_atom(class), do: Atom.to_string(class)
end
