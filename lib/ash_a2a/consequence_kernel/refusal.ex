defmodule AshA2A.ConsequenceKernel.Refusal do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.RefusalCodes

  def new(code, attrs \\ %{}) do
    case RefusalCodes.classify(code) do
      {:ok, class} ->
        {:error, Map.merge(%{code: code, class: class}, attrs)}

      :error ->
        {:error, %{code: :unknown_refusal_code, class: :blocked_unknown, original: code}}
    end
  end
end
