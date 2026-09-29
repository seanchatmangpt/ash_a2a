defmodule AshA2A.C2.AuthorityService do
 def authorize(client,e,ctx) when is_atom(client), do: client.authorize(e,ctx)
end