defmodule AshA2A.C3.SignerSet do
 def threshold?(signatures,k) when is_integer(k) and k>0 do signatures|>Enum.map(& &1.signer)|>Enum.uniq()|>length()>=k end
end