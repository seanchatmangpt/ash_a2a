# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.Projection do
  @moduledoc "Semantic-work Projection guard."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:projection, :source_subject]) do
      {:ok, %{projection: r.projection, source_subject: r.source_subject, derived: true}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
