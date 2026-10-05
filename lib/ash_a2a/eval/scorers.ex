# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Eval.Scorers do
  @moduledoc """
  Suite scorers over a real reply: the predicates that decide whether one
  eval case PASSED or FAILED.

  A scorer is a JSON map. All scorers resolve an optional `path` into the
  reply view first (`"text"` -- joined text parts; `"data"` -- first data
  part map; `"data.a.b"` -- dotted get_in into the first data part; default
  `"text"`), then apply their predicate:

    * `{"type": "exact", "value": ..., "path": ...}` -- resolved value
      exactly equal (`==`) to `value`.
    * `{"type": "contains", "value": "...", "path": ...}` -- resolved value
      is a binary containing `value` as a substring.
    * `{:type "schema_match", "expect": {...}, "path": ...}` -- deep-subset
      match: maps need every expected key present and deep-matching; lists
      need equal length and element-wise match; scalars compare `==`.
    * `{"type": "custom", "module": "M", "function": "f"}` -- real remote
      call `apply(mod, fun, [view, case])`; `view` is
      `%{text:, data:, raw:}`. Pass on `true`/`:ok`/`{:ok, detail}`; fail on
      `false`/`nil`/`{:error, reason}`; anything else (including a raise) is
      a fail with the offending term as detail.

  Scoring is total: a malformed scorer, a missing path, or a raising custom
  function never raises out of `run/3` -- it becomes a FAIL verdict with a
  typed detail, which is exactly what the eval report should record.
  """

  @typedoc "Reply view scorers see; built by `AshA2A.Eval.Runner`."
  @type view :: %{text: String.t(), data: map() | nil, raw: map()}

  @doc """
  Runs every scorer against `view`. Returns one result map per scorer:
  `%{scorer: scorer, verdict: "PASS" | "FAIL", detail: term()}`.
  """
  @spec run([map()], view(), map()) :: [%{scorer: map(), verdict: String.t(), detail: term()}]
  def run(scorers, view, suite_case) when is_list(scorers) do
    Enum.map(scorers, fn scorer ->
      {status, detail} = run_one(scorer, view, suite_case)
      verdict = if status == :pass, do: "PASS", else: "FAIL"

      %{scorer: scorer, verdict: verdict, detail: detail}
    end)
  end

  defp run_one(%{"type" => "exact"} = scorer, view, _case) do
    case resolve(view, path_of(scorer)) do
      {:ok, value} ->
        expected = Map.fetch!(scorer, "value")

        if value == expected do
          {:pass, :ok}
        else
          {:fail, {:mismatch, expected: expected, actual: value}}
        end

      {:error, reason} ->
        {:fail, {:path_error, reason}}
    end
  end

  defp run_one(%{"type" => "contains"} = scorer, view, _case) do
    case resolve(view, path_of(scorer)) do
      {:ok, value} when is_binary(value) ->
        needle = Map.fetch!(scorer, "value")

        if value =~ needle do
          {:pass, :ok}
        else
          {:fail, {:missing_substring, value: needle, actual: value}}
        end

      {:ok, value} ->
        {:fail, {:path_not_a_string, actual: value}}

      {:error, reason} ->
        {:fail, {:path_error, reason}}
    end
  end

  defp run_one(%{"type" => "schema_match"} = scorer, view, _case) do
    case resolve(view, path_of(scorer)) do
      {:ok, value} ->
        expected = Map.fetch!(scorer, "expect")

        case deep_subset_match(expected, value) do
          :ok ->
            {:pass, :ok}

          {:mismatch, path} ->
            {:fail, {:schema_mismatch, at: path, expected: expected, actual: value}}
        end

      {:error, reason} ->
        {:fail, {:path_error, reason}}
    end
  end

  defp run_one(%{"type" => "custom"} = scorer, view, suite_case) do
    mod = module_from_string(Map.fetch!(scorer, "module"))
    fun = String.to_atom(Map.fetch!(scorer, "function"))

    cond do
      is_nil(mod) ->
        {:fail,
         {:custom_scorer_error, "module #{inspect(scorer["module"])} not found or not loaded"}}

      not Code.ensure_loaded?(mod) ->
        {:fail, {:custom_scorer_error, "module #{inspect(mod)} not loaded"}}

      not function_exported?(mod, fun, 2) ->
        {:fail, {:custom_scorer_error, "#{inspect(mod)}.#{fun}/2 not exported"}}

      true ->
        apply_custom(mod, fun, view, suite_case)
    end
  catch
    kind, reason ->
      {:fail, {:custom_scorer_error, "raised: #{Exception.format(kind, reason)}"}}
  end

  defp run_one(scorer, _view, _case) do
    {:fail, {:unknown_scorer_type, inspect(Map.get(scorer, "type"))}}
  end

  defp apply_custom(mod, fun, view, suite_case) do
    case apply(mod, fun, [view, suite_case]) do
      true -> {:pass, :ok}
      :ok -> {:pass, :ok}
      {:ok, detail} -> {:pass, {:ok, detail}}
      false -> {:fail, :rejected}
      nil -> {:fail, :rejected}
      {:error, reason} -> {:fail, {:custom_error, reason}}
      other -> {:fail, {:invalid_custom_return, other}}
    end
  end

  # -- path resolution -------------------------------------------------------

  defp path_of(%{"path" => path}) when is_binary(path), do: path

  defp path_of(%{"type" => "schema_match"}), do: "data"
  defp path_of(_), do: "text"

  defp resolve(_view, path) when not is_binary(path) do
    {:error, {:invalid_path, path}}
  end

  defp resolve(view, "text"), do: {:ok, view.text}

  defp resolve(view, "data"), do: resolve_data(view, [])

  defp resolve(view, "data." <> rest) do
    keys =
      rest
      |> String.split(".")
      |> Enum.map(&String.trim/1)

    resolve_data(view, keys)
  end

  defp resolve(_view, other), do: {:error, {:invalid_path, other}}

  defp resolve_data(%{data: nil}, _keys), do: {:error, :no_data_part}

  defp resolve_data(%{data: data}, []), do: {:ok, data}

  defp resolve_data(%{data: data}, keys) when is_map(data) do
    Enum.reduce_while(keys, {:ok, data}, fn key, {:ok, acc} ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, {:ok, Map.fetch!(acc, key)}}
      else
        {:halt, {:error, {:missing_key, keys: keys, missing: key}}}
      end
    end)
  end

  defp resolve_data(_view, keys), do: {:error, {:missing_key, keys: keys, missing: nil}}

  # -- deep subset match -----------------------------------------------------

  defp deep_subset_match(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.find_value(expected, :ok, fn {k, v} ->
      unless Map.has_key?(actual, k) do
        {:mismatch, [k]}
      else
        case deep_subset_match(v, Map.fetch!(actual, k)) do
          :ok -> nil
          {:mismatch, path} -> {:mismatch, [k | path]}
        end
      end
    end)
  end

  defp deep_subset_match(expected, actual) when is_list(expected) and is_list(actual) do
    if length(expected) == length(actual) do
      expected
      |> Enum.zip(actual)
      |> Enum.find_value(:ok, fn {e, a} ->
        case deep_subset_match(e, a) do
          :ok -> nil
          {:mismatch, path} -> {:mismatch, path}
        end
      end)
    else
      {:mismatch, [:length]}
    end
  end

  defp deep_subset_match(expected, actual) do
    if expected == actual, do: :ok, else: {:mismatch, []}
  end

  defp module_from_string("Elixir." <> _ = name), do: safe_to_module(name)
  defp module_from_string(name) when is_binary(name), do: safe_to_module("Elixir." <> name)

  defp module_from_string(_), do: nil

  defp safe_to_module(name) do
    Code.ensure_loaded(String.to_atom(name))
    |> case do
      {:module, mod} -> mod
      {:error, _} -> nil
    end
  end

  @doc false
  def deep_match?(expected, actual), do: deep_subset_match(expected, actual) == :ok
end
