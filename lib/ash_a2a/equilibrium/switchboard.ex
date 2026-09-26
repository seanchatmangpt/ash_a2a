defmodule AshA2A.Equilibrium.Switchboard do
  @moduledoc """
  Pure control-plane kernel for bounded planner/provider selection.

  The switchboard has no DO capability. It turns an admitted work order into a
  deterministic SELECT/CONSTRUCT receipt. Consequential execution remains an
  AshA2A.CommandBus/BRCE responsibility.
  """

  @type refusal ::
          :subject_mismatch | :capability_missing | :role_mismatch |
          :policy_mismatch | :authority_increase | :stale_epoch |
          :no_planner | :no_provider | :unbounded_plan | :duplicate |
          :backpressure | :stale_lease | :ontology_contract_missing

  defmodule WorkOrder do
    @enforce_keys [:id, :subject, :capability, :role, :policy, :authority, :epoch, :max_steps]
    defstruct @enforce_keys
  end

  defmodule Planner do
    @enforce_keys [:id, :kind, :capabilities, :roles, :policies, :authority_ceiling, :max_steps, :provider_ids]
    defstruct @enforce_keys ++ [priority: 0]
  end

  defmodule Provider do
    @enforce_keys [:id, :epoch, :capabilities]
    defstruct @enforce_keys ++ [alive: true]
  end

  defmodule Receipt do
    @enforce_keys [:id, :kind, :subject, :work_order_id, :planner_id, :provider_id, :authority, :epoch, :digest]
    defstruct @enforce_keys ++ [standing: :candidate, consequence: :none]
  end

  defmodule Queue do
    defstruct pending: :queue.new(), known: MapSet.new(), leases: %{}, completed: MapSet.new(), limit: 128
  end

  @required_ttl ~w(Planner Policy Role Agent Authority DO Standing WorkOrder Selection Construct BRCEReceipt)a

  @spec validate_ontology(String.t()) :: :ok | {:error, refusal(), [atom()]}
  def validate_ontology(ttl) when is_binary(ttl) do
    missing = Enum.reject(@required_ttl, &String.contains?(ttl, Atom.to_string(&1)))
    if missing == [], do: :ok, else: {:error, :ontology_contract_missing, missing}
  end

  @spec admit(WorkOrder.t(), map()) :: :ok | {:error, refusal()}
  def admit(%WorkOrder{} = w, ctx) do
    cond do
      w.subject != ctx.subject -> {:error, :subject_mismatch}
      w.epoch != ctx.epoch -> {:error, :stale_epoch}
      w.capability not in ctx.capabilities -> {:error, :capability_missing}
      w.role not in ctx.roles -> {:error, :role_mismatch}
      w.policy not in ctx.policies -> {:error, :policy_mismatch}
      not authority_leq?(w.authority, ctx.authority_ceiling) -> {:error, :authority_increase}
      not is_integer(w.max_steps) or w.max_steps < 1 -> {:error, :unbounded_plan}
      true -> :ok
    end
  end

  @spec select(WorkOrder.t(), [Planner.t()], [Provider.t()]) ::
          {:ok, Receipt.t()} | {:error, refusal()}
  def select(%WorkOrder{} = w, planners, providers) do
    eligible =
      planners
      |> Enum.filter(&planner_eligible?(&1, w))
      |> Enum.sort_by(fn p -> {-p.priority, to_string(p.id)} end)

    case eligible do
      [] -> {:error, :no_planner}
      [planner | _] ->
        case provider_for(planner, w, providers) do
          nil -> {:error, :no_provider}
          provider -> {:ok, receipt(w, planner, provider)}
        end
    end
  end

  defp planner_eligible?(p, w) do
    w.capability in p.capabilities and w.role in p.roles and w.policy in p.policies and
      authority_leq?(w.authority, p.authority_ceiling) and w.max_steps <= p.max_steps
  end

  defp provider_for(planner, w, providers) do
    providers
    |> Enum.filter(fn p ->
      p.alive and p.epoch == w.epoch and p.id in planner.provider_ids and w.capability in p.capabilities
    end)
    |> Enum.sort_by(&to_string(&1.id))
    |> List.first()
  end

  defp receipt(w, planner, provider) do
    payload = %{
      authority: w.authority, capability: w.capability, epoch: w.epoch,
      planner: planner.id, provider: provider.id, subject: w.subject,
      work_order: w.id, max_steps: w.max_steps
    }

    digest = canonical_digest(payload)

    %Receipt{
      id: "select:" <> digest,
      kind: :select,
      subject: w.subject,
      work_order_id: w.id,
      planner_id: planner.id,
      provider_id: provider.id,
      authority: w.authority,
      epoch: w.epoch,
      digest: digest
    }
  end

  @spec enqueue(Queue.t(), WorkOrder.t()) :: {:ok, Queue.t()} | {:error, refusal()}
  def enqueue(%Queue{} = q, %WorkOrder{id: id} = w) do
    cond do
      MapSet.member?(q.known, id) -> {:error, :duplicate}
      :queue.len(q.pending) >= q.limit -> {:error, :backpressure}
      true -> {:ok, %{q | pending: :queue.in(w, q.pending), known: MapSet.put(q.known, id)}}
    end
  end

  @spec lease(Queue.t(), term(), non_neg_integer(), non_neg_integer()) ::
          {:ok, WorkOrder.t(), map(), Queue.t()} | {:empty, Queue.t()}
  def lease(%Queue{} = q, owner, epoch, ttl) when ttl > 0 do
    case :queue.out(q.pending) do
      {:empty, _} -> {:empty, q}
      {{:value, w}, rest} ->
        token = canonical_digest(%{id: w.id, owner: owner, epoch: epoch})
        lease = %{owner: owner, epoch: epoch, token: token, expires_at: epoch + ttl, work_order: w}
        {:ok, w, lease, %{q | pending: rest, leases: Map.put(q.leases, w.id, lease)}}
    end
  end

  @spec reclaim(Queue.t(), non_neg_integer()) :: Queue.t()
  def reclaim(%Queue{} = q, now_epoch) do
    {expired, live} = Enum.split_with(q.leases, fn {_id, l} -> l.expires_at <= now_epoch end)
    pending = Enum.reduce(expired, q.pending, fn {_id, l}, acc -> :queue.in(l.work_order, acc) end)
    %{q | pending: pending, leases: Map.new(live)}
  end

  @spec complete(Queue.t(), term(), String.t(), non_neg_integer()) ::
          {:ok, Queue.t()} | {:error, refusal()}
  def complete(%Queue{} = q, id, token, epoch) do
    case Map.get(q.leases, id) do
      %{token: ^token, epoch: ^epoch} ->
        {:ok, %{q | leases: Map.delete(q.leases, id), completed: MapSet.put(q.completed, id)}}
      _ -> {:error, :stale_lease}
    end
  end

  @spec replay([Receipt.t()]) :: {:ok, [String.t()]} | {:error, :non_deterministic_receipt}
  def replay(receipts) do
    ids = Enum.map(receipts, & &1.id)
    if ids == Enum.uniq(ids), do: {:ok, Enum.sort(ids)}, else: {:error, :non_deterministic_receipt}
  end

  @spec canonical_digest(map()) :: String.t()
  def canonical_digest(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp authority_leq?(requested, ceiling) when is_integer(requested) and is_integer(ceiling),
    do: requested <= ceiling
  defp authority_leq?(requested, ceiling), do: requested == ceiling
end
