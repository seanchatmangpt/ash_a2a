# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.Provider do
  @moduledoc "Semantic-work Provider guard."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:provider, :subject, :contract]) do
      {:ok, %{provider: r.provider, subject: r.subject, contract: r.contract}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
