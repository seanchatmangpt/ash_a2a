defmodule AshA2A.C2.MemoryClaimStore do
 @behaviour AshA2A.C2.ClaimStore
 def start_link, do: Agent.start_link(fn->%{} end,name: __MODULE__)
 def claim(d,g), do: Agent.get_and_update(__MODULE__,fn s-> if Map.has_key?(s,d),do:{{:error,:already_claimed},s},else:{:ok,Map.put(s,d,{g,:claimed})} end)
 def complete(d,r), do: Agent.update(__MODULE__,&Map.update(&1,d,{0,{:completed,r}},fn {g,_}->{g,{:completed,r}} end))
end