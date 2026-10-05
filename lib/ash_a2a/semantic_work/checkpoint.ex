# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.Checkpoint do
  @moduledoc "Exact semantic-work Checkpoint boundary."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:checkpoint, :epoch, :graph_digest]) do
      {:ok, %{checkpoint: r.checkpoint, epoch: r.epoch, graph_digest: r.graph_digest}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
