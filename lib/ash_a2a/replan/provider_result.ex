defmodule AshA2A.Replan.ProviderResult do
  def normalize({:ok, %{} = v}, id), do: {:ok, %{provider: id, candidate: v}}
  def normalize({:error, r}, id), do: {:error, %{provider: id, reason: r}}
  def normalize(v, id), do: {:error, %{provider: id, reason: {:invalid_provider_result, v}}}
end
