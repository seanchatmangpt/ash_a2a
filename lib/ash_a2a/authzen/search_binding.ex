defmodule AshA2A.AuthZEN.SearchBinding do
  alias AshA2A.Identity.Canonical
  @enforce_keys [:request_digest]
  defstruct [:request_digest, :page_token]

  def start(initial_request) when is_map(initial_request) do
    with {:ok, digest} <- Canonical.digest(initial_request),
         do: {:ok, %__MODULE__{request_digest: digest}}
  end

  def next(%__MODULE__{} = state, initial_request, page_token)
      when is_map(initial_request) do
    with {:ok, digest} <- Canonical.digest(initial_request),
         true <- digest == state.request_digest do
      {:ok, %{state | page_token: page_token}}
    else
      false -> {:error, :pagination_request_mutated}
      {:error, _} = error -> error
    end
  end
end
