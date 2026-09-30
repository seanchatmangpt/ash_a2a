defmodule AshA2A.SPIFFE.Identity do
  @enforce_keys [:uri, :trust_domain, :path]
  defstruct @enforce_keys

  def parse(raw) when is_binary(raw) do
    uri = URI.parse(raw)
    cond do
      uri.scheme != "spiffe" -> {:error, :invalid_spiffe_scheme}
      not is_binary(uri.host) or uri.host == "" -> {:error, :missing_trust_domain}
      not is_nil(uri.query) or not is_nil(uri.fragment) -> {:error, :spiffe_query_fragment_forbidden}
      not is_nil(uri.userinfo) or not is_nil(uri.port) -> {:error, :spiffe_authority_invalid}
      true ->
        path = uri.path || ""
        {:ok, %__MODULE__{uri: "spiffe://#{uri.host}#{path}", trust_domain: uri.host, path: path}}
    end
  end
  def parse(_), do: {:error, :invalid_spiffe_id}
end
