# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.GraphIdentity do
  @moduledoc "Exact semantic-work GraphIdentity boundary."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:graph_digest]) do
      {:ok, %{graph_digest: r.graph_digest, algorithm: Map.get(m, :algorithm, "sha256")}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
