defmodule AshA2A.AuthZEN.Client do
  @moduledoc """
  Access-evaluation client that posts `AshA2A.AuthZEN.Wire` requests through an injected
  transport and returns the observed decision via `evaluate/2`. It observes PDP outcomes
  as evidence; an allow confers no authority.
  """

  alias AshA2A.AuthZEN.{Metadata, Types, Wire}
  @enforce_keys [:metadata, :transport]
  defstruct @enforce_keys

  def evaluate(
        %__MODULE__{metadata: %Metadata{} = metadata, transport: transport},
        %Types.Request{} = request
      )
      when is_function(transport, 2) do
    with {:ok, raw} <- transport.(metadata.access_evaluation_endpoint, Wire.request(request)),
         {:ok, decision} <- Wire.decode_decision(raw) do
      {:ok, %{decision | source: metadata.policy_decision_point}}
    end
  end
end
