# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.Falsifier do
  @moduledoc "Evaluates bounded negative controls without turning a failure into authority."

  def evaluate(expected, observed) when is_map(expected) and is_map(observed) do
    mismatches =
      expected
      |> Enum.reduce([], fn {key, value}, acc ->
        actual = Map.get(observed, key, Map.get(observed, to_string(key)))

        if actual == value,
          do: acc,
          else: [%{field: key, expected: value, observed: actual} | acc]
      end)
      |> Enum.reverse()

    case mismatches do
      [] -> {:ok, :not_falsified}
      list -> {:error, {:falsified, list}}
    end
  end

  def evaluate(_, _),
    do: {:error, {:falsified, [%{field: :envelope, expected: :map, observed: :invalid}]}}
end
