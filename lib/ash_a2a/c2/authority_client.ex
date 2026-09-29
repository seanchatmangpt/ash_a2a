defmodule AshA2A.C2.AuthorityClient do
  @callback authorize(AshA2A.C2.AuthorityRequest.t() | map(), map()) ::
              {:ok, term()} | {:error, term()}
  def authorize(client, request, ctx) when is_atom(client), do: client.authorize(request, ctx)
end
