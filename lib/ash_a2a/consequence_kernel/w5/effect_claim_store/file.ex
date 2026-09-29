defmodule AshA2A.ConsequenceKernel.W5.EffectClaimStore.File do
  use GenServer
  @behaviour AshA2A.ConsequenceKernel.W5.EffectClaimStore
  alias AshA2A.ConsequenceKernel.W5.{ClaimTransition, EffectClaim}

  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    GenServer.start_link(__MODULE__, path, Keyword.drop(opts, [:path]))
  end

  def init(path), do: {:ok, Map.put(load(path), :path, path)}
  def put(s, c), do: GenServer.call(s, {:put, c})
  def fetch(s, id), do: GenServer.call(s, {:fetch, id})
  def fetch_effect(s, id), do: GenServer.call(s, {:fetch_effect, id})
  def transition(s, id, f, t), do: GenServer.call(s, {:transition, id, f, t})
  def append_receipt(s, id, r), do: GenServer.call(s, {:append_receipt, id, r})
  def receipts(s, id), do: GenServer.call(s, {:receipts, id})

  def handle_call({:put, %EffectClaim{} = c}, _, s) do
    cond do
      Map.has_key?(s.claims, c.claim_id) ->
        {:reply, {:error, :effect_claim_duplicate}, s}

      Map.has_key?(s.effects, c.effect_id) ->
        {:reply, {:error, :effect_already_claimed}, s}

      true ->
        n =
          s
          |> put_in([:claims, c.claim_id], c)
          |> put_in([:effects, c.effect_id], c.claim_id)
          |> put_in([:receipts, c.claim_id], [])

        {:reply, :ok, persist(n)}
    end
  end

  def handle_call({:fetch, id}, _, s),
    do:
      {:reply,
       case Map.fetch(s.claims, id) do
         {:ok, c} -> {:ok, c}
         :error -> :not_found
       end, s}

  def handle_call({:fetch_effect, id}, _, s) do
    r =
      with {:ok, cid} <- Map.fetch(s.effects, id),
           {:ok, c} <- Map.fetch(s.claims, cid),
           do: {:ok, c},
           else: (_ -> :not_found)

    {:reply, r, s}
  end

  def handle_call({:transition, id, f, t}, _, s) do
    with {:ok, c} <- Map.fetch(s.claims, id),
         true <- c.state == f,
         :ok <- ClaimTransition.admit(f, t) do
      n = put_in(s, [:claims, id], %{c | state: t})
      {:reply, :ok, persist(n)}
    else
      _ -> {:reply, {:error, :effect_claim_transition_refused}, s}
    end
  end

  def handle_call({:append_receipt, id, r}, _, s) do
    if Map.has_key?(s.claims, id) and is_map(r) do
      n = put_in(s, [:receipts, id], Map.get(s.receipts, id, []) ++ [r])
      {:reply, :ok, persist(n)}
    else
      {:reply, {:error, :effect_claim_not_found}, s}
    end
  end

  def handle_call({:receipts, id}, _, s),
    do:
      {:reply,
       if(Map.has_key?(s.claims, id), do: {:ok, Map.get(s.receipts, id, [])}, else: :not_found),
       s}

  defp empty, do: %{claims: %{}, effects: %{}, receipts: %{}}

  defp load(path) do
    case File.read(path) do
      {:ok, b} ->
        try do
          case :erlang.binary_to_term(b, [:safe]) do
            %{claims: _, effects: _, receipts: _} = x -> x
            _ -> empty()
          end
        rescue
          _ -> empty()
        end

      _ ->
        empty()
    end
  end

  defp persist(%{path: path} = s) do
    :ok = File.mkdir_p(Path.dirname(path))
    tmp = path <> ".tmp"

    :ok =
      File.write(tmp, s |> Map.delete(:path) |> :erlang.term_to_binary([:deterministic]), [
        :binary,
        :sync
      ])

    :ok = File.rename(tmp, path)
    s
  end
end
