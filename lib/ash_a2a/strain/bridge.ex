defmodule AshA2A.Strain.Bridge do
  @moduledoc """
  Integration wire between live observation events and the AHDCLT tensor.

  Pure, caller-threaded state: `record_observation/3` folds an observation
  into the mesh_state map; `route/2` strain-checks every candidate
  coordinator and picks the minimum-strain admit.

  ## Observation → tensor dimension mapping

  | observation event | tensor dimension | effect |
  |---|---|---|
  | `ticket_completed` | `:active_leases` | decrement by 1 (floor 0) |
  | `ticket_assigned` | `:active_leases` | increment by 1 |
  | `challenge_received` (Vince) | `:heuristic_frequency` | increment flagged-event count by 1 |
  | `error_reported` | `:error_rate` | append to rolling window (see below) |
  | `clock_hour` | `:shift_hours_continuous` | advance shift clock by `:hours` (default 1) |

  Event contract: `error_reported` carries `error:` `true | 1` (errored) or
  `false | 0 | nil` / absent (counts as a non-error outcome); any other value
  raises `ArgumentError`. `clock_hour` carries `hours:` a non-negative number
  (default 1); negative or non-numeric raises `ArgumentError`. Unknown event
  types raise `ArgumentError`.

  The error window is a rolling list of the last `@error_window 20` binary
  error outcomes; `error_rate` is the window ratio. `clock_hour` events
  decay nothing themselves — the circadian decay `1 - exp(-h/4.0)` lives in
  `Tensor.strain/2`; the observation only advances the raw shift clock.

  ## Fatigue-diversion invariant

  A coordinator with deep circadian decay (normalized shift strain > 0.85)
  AND rising error drift receives no high-friction ticket (friction > 0.7):
  the ticket diverts to the freshest eligible coordinator, or sheds with a
  reason if none exists. Every ticket in `route/2`'s sweep ends assigned or
  shed-with-reason — none dropped. All functions are structurally recursive
  over finite lists/maps (no loops, no clock reads), so termination is by
  construction.

  ## Integration seam (I9 / Vince)

  `challenge_received` events carry `source: :vince`; the
  `lib/ash_a2a/copilot/pipeline.ex` pipeline has landed and threads a Bridge
  `mesh_state`. The seam stays producer-agnostic: any producer that emits
  `%{type: :challenge_received, source: :vince, coordinator_id: id}` can feed
  `record_observation/3` without modifying Bridge. `source` is accepted but
  not required — Tony's moduledoc contract (Bridge consumes the flagged-event
  count, not the detector) is preserved.
  """

  alias AshA2A.Strain.Tensor

  @error_window 20
  @fatigue_threshold 0.85
  @friction_threshold 0.7

  @type event ::
          %{
            required(:type) =>
              :ticket_completed
              | :ticket_assigned
              | :challenge_received
              | :error_reported
              | :clock_hour,
            optional(atom()) => term()
          }

  @type coordinator_state :: %{
          tensor: Tensor.t(),
          error_window: [0 | 1]
        }

  @type mesh_state :: %{optional(term()) => coordinator_state()}

  @doc """
  Create an empty mesh_state, optionally registering coordinator ids with
  zero-observation tensors.
  """
  @spec new_mesh_state([term()]) :: mesh_state()
  def new_mesh_state(ids \\ []) when is_list(ids) do
    Enum.reduce(ids, %{}, fn id, acc ->
      Map.put(acc, id, %{tensor: Tensor.new(%{}), error_window: []})
    end)
  end

  @doc """
  Fold an observation event into mesh_state (pure: mesh_state in, mesh_state
  out). Observations for an unregistered coordinator id are NOT folded
  (no auto-register: a forged id must not mint a mesh entry); the mesh_state
  is returned unchanged. Register ids via `new_mesh_state/1`. Unknown event
  `:type` raises.
  """
  @spec record_observation(mesh_state(), term(), event()) :: mesh_state()
  def record_observation(mesh_state, coordinator_id, %{type: type} = event)
      when is_map(mesh_state) do
    case Map.fetch(mesh_state, coordinator_id) do
      {:ok, state} -> Map.put(mesh_state, coordinator_id, fold(state, type, event))
      :error -> validate_type!(type) && mesh_state
    end
  end

  @observation_types [:ticket_completed, :ticket_assigned, :challenge_received, :error_reported, :clock_hour]

  defp validate_type!(type) when type in @observation_types, do: true
  defp validate_type!(other), do: raise(ArgumentError, "unknown observation type: #{inspect(other)}")

  defp fold(state, type, event) do
    case type do
        :ticket_completed -> lease_step(state, -1)
        :ticket_assigned -> lease_step(state, +1)
        :challenge_received -> heuristic_step(state, +1)
        :error_reported -> error_step(state, event)
        :clock_hour -> shift_step(state, event)
        other -> raise ArgumentError, "unknown observation type: #{inspect(other)}"
      end
  end

  @doc """
  Route a ticket to the minimum-strain eligible coordinator.

  Ticket fields: `:friction` (0.0-1.0, default 0.0) and `:candidates`
  (list of coordinator ids; defaults to all registered ids). Returns
  `{:assign, coordinator_id}` or `{:shed, {:senior_queue, reason}}`; reason is
  `:no_candidates` for an empty candidate list, `:all_saturated`, or
  `{:all_saturated_or_fatigued, :high_friction}`.
  """
  @spec route(map(), mesh_state()) :: {:assign, term()} | {:shed, {:senior_queue, term()}}
  def route(ticket, mesh_state) when is_map(ticket) and is_map(mesh_state) do
    candidates = Map.get(ticket, :candidates, Map.keys(mesh_state))
    friction = Map.get(ticket, :friction, 0.0)

    eligible =
      candidates
      |> Enum.filter(fn id ->
        case Map.fetch(mesh_state, id) do
          {:ok, state} ->
            not fatigued_for_high_friction?(state, friction) and
              Tensor.hyperplane_check(state.tensor) == :ok

          :error ->
            false
        end
      end)

    case eligible do
      [] ->
        reason =
          cond do
            candidates == [] -> :no_candidates
            high_friction?(friction) -> {:all_saturated_or_fatigued, :high_friction}
            true -> :all_saturated
          end

        {:shed, {:senior_queue, reason}}

      ids ->
        id = Enum.min_by(ids, fn id -> total_strain(mesh_state[id].tensor) end)
        {:assign, id}
    end
  end

  @doc "Normalized shift strain (circadian decay); an unregistered id reads 0.0."
  @spec circadian_decay(mesh_state(), term()) :: float()
  def circadian_decay(mesh_state, id) do
    case Map.fetch(mesh_state, id) do
      {:ok, state} -> Tensor.strain(state.tensor, :shift_hours_continuous)
      :error -> 0.0
    end
  end

  @doc "Rolling error-rate ratio for a coordinator; an unregistered id reads 0.0."
  @spec error_rate(mesh_state(), term()) :: float()
  def error_rate(mesh_state, id) do
    window =
      case Map.fetch(mesh_state, id) do
        {:ok, state} -> state.error_window
        :error -> []
      end

    if window == [] do
      0.0
    else
      Enum.sum(window) / length(window) * 1.0
    end
  end

  @doc """
  Rising error drift: recent-half error rate > older-half rate. Needs at
  least 4 outcomes; an unregistered id is `false`.
  """
  @spec error_drift_rising?(mesh_state(), term()) :: boolean()
  def error_drift_rising?(mesh_state, id) when is_map(mesh_state) do
    case Map.fetch(mesh_state, id) do
      {:ok, state} -> drift_rising_on_window?(state.error_window)
      :error -> false
    end
  end

  defp drift_rising_on_window?(window) do
    n = length(window)

    if n < 4 do
      false
    else
      # window is newest-first (insert_at 0), so the first half is the recent half
      half = div(n, 2)
      {recent, older} = Enum.split(window, half)
      recent_rate = Enum.sum(recent) / length(recent)
      older_rate = Enum.sum(older) / length(older)
      recent_rate > older_rate
    end
  end

  # --- observation steps ---------------------------------------------------

  defp lease_step(state, delta) do
    cur = state.tensor.active_leases
    update_tensor(state, active_leases: max(0, cur + delta))
  end

  defp heuristic_step(state, delta) do
    cur = state.tensor.heuristic_frequency
    update_tensor(state, heuristic_frequency: max(0, cur + delta))
  end

  defp error_step(state, event) do
    errored? =
      case event do
        %{error: e} when e in [true, 1] -> 1
        %{error: e} when e in [false, 0, nil] -> 0
        %{error: other} -> raise ArgumentError, "invalid error flag: #{inspect(other)}"
        _ -> 0
      end

    window =
      state.error_window
      |> List.insert_at(0, errored?)
      |> Enum.take(@error_window)

    rate = if window == [], do: 0.0, else: Enum.sum(window) / length(window) * 1.0

    state
    |> update_tensor(error_rate: rate)
    |> Map.put(:error_window, window)
  end

  defp shift_step(state, event) do
    hours = Map.get(event, :hours, 1)

    unless is_number(hours) and hours >= 0 do
      raise ArgumentError,
            "clock_hour :hours must be a non-negative number, got: #{inspect(hours)}"
    end

    cur = state.tensor.shift_hours_continuous
    update_tensor(state, shift_hours_continuous: max(0, cur + hours))
  end

  defp update_tensor(state, kw) do
    %{state | tensor: Tensor.update(state.tensor, Map.new(kw))}
  end

  # --- routing invariants ----------------------------------------------------

  defp fatigued_for_high_friction?(state, friction) do
    high_friction?(friction) and fatigued?(state)
  end

  defp fatigued?(state) do
    Tensor.strain(state.tensor, :shift_hours_continuous) > @fatigue_threshold and
      drift_rising_on_window?(state.error_window)
  end

  defp high_friction?(friction), do: is_number(friction) and friction > @friction_threshold

  defp total_strain(tensor) do
    Tensor.dimensions()
    |> Enum.map(&Tensor.strain(tensor, &1))
    |> Enum.sum()
  end
end
