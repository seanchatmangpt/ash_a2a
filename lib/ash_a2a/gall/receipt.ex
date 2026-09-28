defmodule AshA2A.Gall.Receipt do
  @moduledoc "GALL-local receipt projection that binds a finding to the canonical AshA2A receipt identity without granting authority."

  alias AshA2A.Gall.Closure.Determinism

  @schema "ash_a2a.gall.receipt/v1"

  def prepare(subject, finding, authority, scope)
      when is_map(subject) and is_map(finding) and is_map(scope) do
    body = %{
      schema: @schema,
      subject: subject,
      finding_digest: field(finding, :candidate_digest) || field(finding, :finding_digest),
      authority_token: authority_token(authority),
      scope: scope,
      state: :prepared,
      standing: :unknown,
      replayed?: false
    }

    Map.put(body, :digest, Determinism.digest(body))
  end

  def actuated(%{schema: @schema} = receipt) do
    receipt
    |> Map.put(:state, :actuated)
    |> reseal()
  end

  def verified(%{schema: @schema} = receipt, postcondition) when is_map(postcondition) do
    receipt
    |> Map.put(:state, :completed)
    |> Map.put(:postcondition, postcondition)
    |> Map.put(:standing, :verified)
    |> reseal()
  end

  def replay(%{schema: @schema} = receipt), do: receipt |> Map.put(:replayed?, true) |> reseal()

  def valid?(%{schema: @schema, digest: digest} = receipt) do
    digest == receipt |> Map.delete(:digest) |> Determinism.digest()
  end

  def valid?(_), do: false

  defp reseal(receipt),
    do: Map.put(receipt, :digest, receipt |> Map.delete(:digest) |> Determinism.digest())

  defp authority_token(%{token_id: token}), do: token
  defp authority_token(%{"token_id" => token}), do: token
  defp authority_token(_), do: nil

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
