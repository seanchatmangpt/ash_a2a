# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Eval.Suite do
  @moduledoc """
  Golden-dataset eval suite: JSON on disk, loaded and validated before any
  agent traffic. Conformance asks "does the agent speak the protocol?";
  evaluation asks "is the agent GOOD at its skills?" A suite encodes the
  second question: real `message/send` cases over a real transport with
  expected artifact shapes and scorers.

  Case fields: `id` (unique string), `skill`, optional `input`
  (`{"text": ...}` | `{"data": {...}}` | `{"parts": [...]}`), optional
  `metadata`, required non-empty `scorers`, optional `timeout_ms`.
  Scorer shapes: see `AshA2A.Eval.Scorers`.
  """

  @known_scorer_types ~w(exact contains schema_match custom)

  @doc "Loads and validates a suite JSON file. `{:ok, suite}` | `{:error, reason}`."
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    with {:ok, body} <- read_file(path),
         {:ok, suite} <- decode(body),
         :ok <- validate(suite) do
      {:ok, suite}
    end
  end

  @doc "Validates a decoded suite map. `:ok` | `{:error, {:invalid_suite, problems}}`."
  @spec validate(term()) :: :ok | {:error, {:invalid_suite, [String.t(), ...]}}
  def validate(%{"cases" => cases}) when is_list(cases) do
    problems =
      validate_cases(cases) ++
        validate_scorers(cases) ++
        validate_optionals(cases) ++
        duplicate_id_problems(cases)

    if problems == [], do: :ok, else: {:error, {:invalid_suite, problems}}
  end

  def validate(_other) do
    {:error, {:invalid_suite, ["suite must be a JSON object with a non-empty \"cases\" array"]}}
  end

  defp read_file(path) do
    if is_binary(path) and File.regular?(path) do
      File.read(path)
    else
      {:error, {:suite_not_found, path}}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, {:invalid_suite, ["suite JSON must be an object"]}}
      {:error, reason} -> {:error, {:invalid_suite_json, inspect(reason)}}
    end
  end

  defp validate_cases(cases) do
    if cases == [] do
      ["suite must declare at least one case"]
    else
      Enum.flat_map(Enum.with_index(cases), &validate_case/1)
    end
  end

  defp validate_case({case, _idx}) when is_map(case) do
    required_value(case, "id") ++
      required_value(case, "skill") ++
      required_scorers(case)
  end

  defp validate_case({case, idx}) do
    ["cases[#{idx}] must be an object; got: #{inspect(case)}"]
  end

  defp duplicate_id_problems(cases) do
    ids = Enum.map(cases, &Map.get(&1, "id"))
    dupes = ids -- Enum.uniq(ids)

    case Enum.reject(dupes, &is_nil/1) do
      [] -> []
      dupes -> ["duplicate case id(s): " <> Enum.join(dupes, ", ")]
    end
  end

  defp required_value(case, field) do
    case Map.get(case, field) do
      v when is_binary(v) and v != "" ->
        []

      _ ->
        id = Map.get(case, "id")
        ["case id=#{inspect(id)} field #{inspect(field)} must be a non-empty string"]
    end
  end

  defp required_scorers(case) do
    case Map.get(case, "scorers") do
      s when is_list(s) and s != [] ->
        []

      _ ->
        ["case id=#{inspect(Map.get(case, "id"))} scorers must be a non-empty array"]
    end
  end

  defp validate_scorers(cases) do
    Enum.flat_map(cases, fn suite_case ->
      scorers = Map.get(suite_case, "scorers")
      id = Map.get(suite_case, "id")

      case scorers do
        scorers when is_list(scorers) ->
          Enum.flat_map(Enum.with_index(scorers), fn {scorer, i} ->
            validate_scorer(scorer, i, id)
          end)

        _ ->
          []
      end
    end)
  end

  defp validate_scorer(%{"type" => type} = scorer, i, id) when type in @known_scorer_types do
    case type do
      t when t in ~w(exact contains) ->
        if Map.has_key?(scorer, "value") do
          []
        else
          ["case id=#{inspect(id)} scorer[#{i}] (#{t}) requires \"value\""]
        end

      "schema_match" ->
        if match?(%{}, Map.get(scorer, "expect")) do
          []
        else
          ["case id=#{inspect(id)} scorer[#{i}] (schema_match) requires a map \"expect\""]
        end

      "custom" ->
        if is_binary(Map.get(scorer, "module")) and is_binary(Map.get(scorer, "function")) do
          []
        else
          [
            "case id=#{inspect(id)} scorer[#{i}] (custom) requires string \"module\" and \"function\""
          ]
        end
    end
  end

  defp validate_scorer(scorer, i, id) do
    known = Enum.join(@known_scorer_types, ", ")

    [
      "case id=#{inspect(id)} scorer[#{i}] has unknown \"type\" " <>
        "#{inspect(Map.get(scorer, "type"))}; known types: #{known}"
    ]
  end

  defp validate_optionals(cases) do
    Enum.flat_map(cases, fn suite_case ->
      id = Map.get(suite_case, "id")

      validate_timeout(Map.get(suite_case, "timeout_ms"), id) ++
        validate_metadata(Map.get(suite_case, "metadata"), id) ++
        validate_input(Map.get(suite_case, "input"), id)
    end)
  end

  defp validate_timeout(nil, _id), do: []
  defp validate_timeout(ms, _id) when is_integer(ms) and ms > 0, do: []

  defp validate_timeout(other, id) do
    ["case id=#{inspect(id)} timeout_ms must be a positive integer; got: #{inspect(other)}"]
  end

  defp validate_metadata(nil, _id), do: []
  defp validate_metadata(m, _id) when is_map(m), do: []

  defp validate_metadata(other, id) do
    ["case id=#{inspect(id)} metadata must be an object; got: #{inspect(other)}"]
  end

  defp validate_input(nil, _id), do: []
  defp validate_input(%{"text" => t}, _id) when is_binary(t), do: []
  defp validate_input(%{"data" => d}, _id) when is_map(d), do: []

  defp validate_input(%{"parts" => parts}, id) when is_list(parts) do
    Enum.flat_map(Enum.with_index(parts), fn
      {p, _i} when is_map(p) and is_map_key(p, "text") -> []
      {p, _i} when is_map(p) and is_map_key(p, "data") -> []
      {p, i} -> ["case id=#{inspect(id)} input.parts[#{i}] invalid part: #{inspect(p)}"]
    end)
  end

  defp validate_input(other, id) do
    [
      "case id=#{inspect(id)} input must be {\"text\"}|{\"data\"}|{\"parts\"}; got: #{inspect(other)}"
    ]
  end
end
