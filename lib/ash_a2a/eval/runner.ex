# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Eval.Runner do
  @moduledoc """
  Dispatches each suite case through the REAL transport -- a JSON-RPC
  `message/send` POST against a live agent endpoint -- and scores the
  artifacts that come back.

  No in-process shortcut, no dispatcher bypass: every case is a real HTTP
  round trip to `url`, the same wire path an external A2A client takes. The
  runner is transport-only: it never inspects the agent's process state,
  capability index, or Ash resources.
  """

  @default_timeout_ms 10_000

  @doc """
  Runs every case in the validated `suite` map against `url`. Returns the
  per-case results (see `AshA2A.Eval.Report.finalize/2` for aggregation into
  a full report).
  """
  @spec run(map(), String.t(), keyword()) :: [map()]
  def run(suite, url, opts \\ []) do
    default_timeout = opts[:timeout_ms] || @default_timeout_ms

    Enum.map(suite["cases"], fn suite_case ->
      run_case(suite_case, url, default_timeout)
    end)
  end

  @doc "Runs one case. Returns `%{id, skill, verdict, scorers:, latency_ms:, error:}`."
  @spec run_case(map(), String.t(), pos_integer()) :: map()
  def run_case(suite_case, url, default_timeout_ms \\ @default_timeout_ms) do
    timeout_ms = suite_case["timeout_ms"] || default_timeout_ms

    {latency_ms, outcome} = timed(fn -> send_message(suite_case, url, timeout_ms) end)

    case outcome do
      {:ok, result} ->
        view = build_view(result)

        scorer_results = AshA2A.Eval.Scorers.run(suite_case["scorers"], view, suite_case)

        verdict =
          if Enum.all?(scorer_results, &(&1.verdict == "PASS")) do
            "PASS"
          else
            "FAIL"
          end

        %{
          id: suite_case["id"],
          skill: suite_case["skill"],
          verdict: verdict,
          scorers: scorer_results,
          latency_ms: latency_ms,
          error: nil
        }

      {:error, reason} ->
        %{
          id: suite_case["id"],
          skill: suite_case["skill"],
          verdict: "FAIL",
          scorers: [],
          latency_ms: latency_ms,
          error: reason
        }
    end
  end

  # -- real transport: JSON-RPC message/send over HTTP -----------------------

  defp send_message(suite_case, url, timeout_ms) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "message/send",
      "params" => %{"message" => message_wire(suite_case)}
    }

    case Req.post(url,
           json: body,
           headers: [{"a2a-version", "1.0"}, {"accept", "application/json"}],
           retry: false,
           receive_timeout: timeout_ms
         ) do
      {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
        {:error, {:jsonrpc_error, code_and_message(error)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, snippet(body)}}

      {:ok, %Req.Response{} = resp} ->
        {:error, {:http_status, resp.status, ""}}

      {:error, exception} ->
        {:error, {:transport, Exception.message(exception)}}
    end
  end

  defp message_wire(suite_case) do
    %{
      "role" => "ROLE_USER",
      "parts" => input_parts(suite_case),
      "messageId" => "msg-eval-" <> unique_suffix(),
      "metadata" => metadata(suite_case)
    }
  end

  defp input_parts(%{"input" => %{"text" => text}}), do: [%{"text" => text}]
  defp input_parts(%{"input" => %{"data" => data}}), do: [%{"data" => data}]

  defp input_parts(%{"input" => %{"parts" => parts}}), do: parts

  defp input_parts(_), do: [%{"text" => ""}]

  defp metadata(%{"skill" => skill} = suite_case) do
    Map.merge(%{"skill" => skill}, suite_case_metadata(suite_case))
  end

  defp suite_case_metadata(%{"metadata" => m}) when is_map(m), do: m
  defp suite_case_metadata(_), do: %{}

  defp build_view(%{"task" => task}) do
    parts = task_parts(task)

    %{
      text: text_of(parts),
      data: data_of(parts),
      raw: %{"task" => task}
    }
  end

  defp build_view(%{"message" => message}) do
    parts = Map.get(message, "parts") || []

    %{
      text: text_of(parts),
      data: data_of(parts),
      raw: %{"message" => message}
    }
  end

  defp build_view(other), do: %{text: "", data: nil, raw: other}

  defp task_parts(%{"artifacts" => artifacts}) when is_list(artifacts) do
    Enum.flat_map(artifacts, fn a -> Map.get(a, "parts") || [] end)
  end

  defp task_parts(_), do: []

  defp text_of(parts) do
    parts
    |> Enum.filter(&is_map_key(&1, "text"))
    |> Enum.map_join("", & &1["text"])
  end

  defp data_of(parts) do
    Enum.find_value(parts, fn p -> if is_map(p) and is_map_key(p, "data"), do: p["data"] end)
  end

  defp code_and_message(%{} = error) do
    %{code: Map.get(error, "code"), message: Map.get(error, "message")}
  end

  defp code_and_message(other), do: %{code: nil, message: inspect(other)}

  defp snippet(body) when is_binary(body), do: binary_slice(body, 0, min(byte_size(body), 200))
  defp snippet(body), do: inspect(String.slice(inspect(body), 0, 200))

  defp unique_suffix do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp timed(fun) do
    t0 = System.monotonic_time(:millisecond)
    outcome = fun.()
    {System.monotonic_time(:millisecond) - t0, outcome}
  end
end
