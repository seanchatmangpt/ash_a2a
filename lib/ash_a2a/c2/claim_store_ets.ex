defmodule AshA2A.C2.ClaimStoreETS do
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts,:name))
  def init(_), do: {:ok, %{}}
  def claim(server,digest,generation), do: GenServer.call(server,{:claim,digest,generation})
  def complete(server,digest,result), do: GenServer.call(server,{:complete,digest,result})
  def handle_call({:claim,d,g},_,s) do
    case s[d] do
      nil -> {:reply,:ok,Map.put(s,d,{:claimed,g})}
      {:claimed,^g} -> {:reply,{:error,:already_claimed},s}
      {:complete,_,r} -> {:reply,{:error,{:already_complete,r}},s}
      _ -> {:reply,{:error,:stale_generation},s}
    end
  end
  def handle_call({:complete,d,r},_,s), do: {:reply,:ok,Map.put(s,d,{:complete,System.monotonic_time(),r})}
end
