defmodule AshA2A.Twin.Tony do
  @moduledoc """
  Tony: ergonomic load balancer over a coordinator mesh.

  Pure functions over tensor snapshots (no processes, no clock reads — the
  caller supplies observation data). Integration seam disclosed: the
  `:heuristic_frequency` dimension is expected to be fed by Vince's heuristic
  detectors' flagged-event counts; Tony only consumes the number.

  ## API

  - `register_coordinator/3` — put a coordinator id → tensor snapshot into the mesh map.
  - `handle_inbound/2` — strain-check the target coordinator: `{:admit, id}` |
    `{:shed, {:senior_queue, target}}`.
  - `triage/2` — partition tickets into `{pre_staged_routine, escalated_edges}`
    via the pre-staging verification checklist.
  - `balance/3` — divert high-friction tickets from saturated coordinators to
    fresh ones (pure over tensor snapshots).
  """

  alias AshA2A.Strain.Tensor

  @type mesh :: %{optional(term()) => Tensor.t()}

  @shed_target {:senior_queue, :tony_relief}

  @doc "Register a coordinator's tensor snapshot in the mesh."
  @spec register_coordinator(mesh(), term(), Tensor.t()) :: mesh()
  def register_coordinator(mesh, id, %{} = tensor) when is_map(mesh) do
    Map.put(mesh, id, tensor)
  end

  @doc """
  Strain-check the target coordinator for an inbound ticket.

  `{:admit, id}` when no hyperplane gate breaches; `{:shed, {:senior_queue, target}}`
  when the saturation gate breaches. Unknown coordinator raises.
  """
  @spec handle_inbound(mesh(), keyword() | map()) :: {:admit, term()} | {:shed, {:senior_queue, :tony_relief}}
  def handle_inbound(mesh, ticket)

  def handle_inbound(mesh, ticket) when is_map(mesh) do
    id = target(ticket)
    tensor = Map.fetch!(mesh, id)

    case Tensor.hyperplane_check(tensor) do
      :ok -> {:admit, id}
      {:breach, _} = breach -> {:shed, {:senior_queue, relief_target(breach)}}
    end
  end

  defp target(ticket) when is_map(ticket), do: Map.get(ticket, :coordinator_id)
  defp target(ticket) when is_list(ticket), do: Keyword.get(ticket, :coordinator_id)

  defp relief_target(_breach), do: elem(@shed_target, 1)

  @friction_threshold 0.7

  @doc """
  Divert high-friction tickets away from saturated coordinators to fresh ones.

  Pure over tensor snapshots: `tickets` each carry `:coordinator_id` and
  `:friction` (0.0-1.0); `mesh` maps coordinator id → tensor snapshot. A
  coordinator whose tensor breaches the saturation gate is saturated; its
  tickets with `friction > @friction_threshold` are reassigned to the mesh's
  freshest coordinator (lowest weighted strain). Returns the reassigned
  `[ticket]` list (original order preserved; non-diverted tickets untouched).
  """
  @spec balance([map()], mesh(), keyword()) :: [map()]
  def balance(tickets, mesh, _opts \\ []) when is_list(tickets) and is_map(mesh) do
    saturated = MapSet.new(saturated_ids(mesh))
    freshest = freshest_id(mesh)

    case {MapSet.size(saturated), freshest} do
      {0, _} ->
        tickets

      {_, nil} ->
        tickets

      _ ->
        Enum.map(tickets, fn ticket ->
          if divert?(ticket, saturated) do
            Map.put(ticket, :coordinator_id, freshest)
          else
            ticket
          end
        end)
    end
  end

  defp divert?(%{friction: f} = ticket, saturated) do
    MapSet.member?(saturated, ticket.coordinator_id) and is_number(f) and f > @friction_threshold
  end

  defp saturated_ids(mesh) do
    mesh
    |> Enum.reject(fn {_id, tensor} -> Tensor.hyperplane_check(tensor) == :ok end)
    |> Enum.map(fn {id, _tensor} -> id end)
  end

  defp freshest_id(mesh) do
    saturated = MapSet.new(saturated_ids(mesh))

    case Enum.reject(mesh, fn {id, _} -> MapSet.member?(saturated, id) end) do
      [] ->
        nil

      candidates ->
        {id, _} = Enum.min_by(candidates, fn {_id, tensor} -> weighted_strain(tensor) end)
        id
    end
  end

  defp weighted_strain(tensor) do
    Tensor.dimensions()
    |> Enum.map(fn dim -> Tensor.strain(tensor, dim) end)
    |> Enum.sum()
  end

  @doc """
  Partition tickets into `{pre_staged_routine, escalated_edges}`.

  Pre-staging checklist — ALL must pass for a ticket to be routine:
  `warranty_status == :active`, `operating_hours <= 2000`,
  `sla_window` an open range containing `now` (or `:open`), and
  `contractor_coi_valid == true`. Any missing/invalid field → escalation edge.
  """
  @spec triage([map()], keyword()) :: {[map()], [map()]}
  def triage(tickets, opts \\ []) when is_list(tickets) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    max_operating_hours = Keyword.get(opts, :max_operating_hours, 2000)

    Enum.reduce(tickets, {[], []}, fn ticket, {routine, edges} ->
      case prestage_pass?(ticket, now, max_operating_hours) do
        true -> {[ticket | routine], edges}
        false -> {routine, [ticket | edges]}
      end
    end)
    |> then(fn {r, e} -> {Enum.reverse(r), Enum.reverse(e)} end)
  end

  defp prestage_pass?(ticket, now, max_hours) do
    with :ok <- warranty_ok?(ticket),
         :ok <- hours_ok?(ticket, max_hours),
         :ok <- sla_ok?(ticket, now),
         :ok <- coi_ok?(ticket) do
      true
    else
      _ -> false
    end
  end

  defp warranty_ok?(%{warranty_status: :active}), do: :ok
  defp warranty_ok?(_), do: :error

  defp hours_ok?(%{operating_hours: h}, max) when is_number(h) and h >= 0 and h <= max, do: :ok
  defp hours_ok?(_, _), do: :error

  defp sla_ok?(%{sla_window: {start_s, end_s}}, now)
       when is_struct(start_s, DateTime) and is_struct(end_s, DateTime) do
    case DateTime.compare(now, start_s) != :lt and DateTime.compare(now, end_s) != :gt do
      true -> :ok
      false -> :error
    end
  end

  defp sla_ok?(%{sla_window: :open}, _now), do: :ok

  defp sla_ok?(_ticket, _now), do: :error

  defp coi_ok?(%{contractor_coi_valid: true}), do: :ok
  defp coi_ok?(_), do: :error
end
