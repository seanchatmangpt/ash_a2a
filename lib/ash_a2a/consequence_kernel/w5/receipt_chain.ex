defmodule AshA2A.ConsequenceKernel.W5.ReceiptChain do
  alias AshA2A.Identity.Canonical
  def append(prev,event) when is_binary(prev) and is_map(event),
    do: Canonical.digest(%{"schema"=>"sa2a.receipt-chain-link.v1","previous"=>prev,"event"=>norm(event)})
  def append(_,_), do: {:error,:invalid_receipt_chain}
  defp norm(%_{}=s), do: s|>Map.from_struct()|>norm()
  defp norm(m) when is_map(m), do: Map.new(m,fn {k,v}->{to_string(k),norm(v)} end)
  defp norm(l) when is_list(l), do: Enum.map(l,&norm/1)
  defp norm(a) when is_atom(a) and a not in [true,false,nil], do: Atom.to_string(a)
  defp norm(v), do: v
end
