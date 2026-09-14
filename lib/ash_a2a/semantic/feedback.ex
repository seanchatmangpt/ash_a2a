defmodule AshA2A.Semantic.Feedback do
  @moduledoc "Typed receipt evidence fed back into semantic planning without granting authority."

  alias AshA2A.{Receipt, SemanticProjection}
  alias AshA2A.Semantic.ExecutionPackage

  @enforce_keys [:package_fingerprint, :receipt_id, :observation, :fingerprint]
  defstruct [
    :package_fingerprint,
    :receipt_id,
    :observation,
    :fingerprint,
    standing: :observed,
    authority: :none
  ]

  @type t :: %__MODULE__{}

  def from_receipt(%ExecutionPackage{} = package, %Receipt{} = receipt) do
    semantic = SemanticProjection.receipt(receipt)

    observation = %{
      "kind" => "runtime_receipt",
      "receipt_id" => semantic.receipt_id,
      "capability_id" => semantic.capability_id,
      "status" => to_string(semantic.status),
      "standing" => to_string(semantic.standing),
      "consequence" => to_string(semantic.consequence),
      "replayed" => semantic.replayed?
    }

    term = {package.fingerprint, observation}

    {:ok,
     %__MODULE__{
       package_fingerprint: package.fingerprint,
       receipt_id: semantic.receipt_id,
       observation: observation,
       fingerprint: fingerprint(term)
     }}
  end

  defp fingerprint(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
