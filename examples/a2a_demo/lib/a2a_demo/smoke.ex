defmodule A2aDemo.Smoke do
  @moduledoc """
  The demo falsifier, executed in-VM after boot:

      mix run -e 'A2aDemo.Smoke.run()'

  Drives every README flow over real HTTP (Req) against the running Bandit
  listener and asserts on real wire state: both cards, observe read, the
  input-required -> tasks/get -> tasks/cancel lifecycle, the grant-gated
  create, the SSE stream, the fail-closed refusals (ungranted principal,
  missing credential), and every REST equivalent.
  """

  @extension_uri "urn:sa2a:profile:v26.9.20"

  def run do
    base = "http://localhost:#{port()}"
    run_flows(base)
  end

  defp run_flows(base) do
    flows = [
      {"card at /jsonrpc", fn -> card_flow(base, "/jsonrpc") end},
      {"card at /rest", fn -> card_flow(base, "/rest") end},
      {"observe read (message/send get_note)", fn -> read_flow(base) end},
      {"input_required -> tasks/get -> tasks/cancel", fn -> cancel_flow(base) end},
      {"grant-gated create (message/send create_note)", fn -> create_flow(base) end},
      {"message/stream SSE", fn -> stream_flow(base) end},
      {"ungranted principal refused (authority gate)", fn -> ungranted_flow(base) end},
      {"unauthenticated refused (401)", fn -> unauthenticated_flow(base) end},
      {"REST message:send + tasks list/get", fn -> rest_flow(base) end},
      {"REST input_required -> cancel", fn -> rest_cancel_flow(base) end}
    ]

    results =
      Enum.map(flows, fn {name, fun} ->
        IO.puts("RUN  #{name}")
        run_flow(name, fun)
      end)

    Enum.each(results, fn
      {:ok, name} -> IO.puts("PASS #{name}")
      {:error, {name, msg}} -> IO.puts("FAIL #{name}: #{msg}")
    end)

    if Enum.any?(results, &match?({:error, _}, &1)) do
      System.halt(1)
    end

    IO.puts("ALL FLOWS GREEN (#{length(results)} flows)")
    System.halt(0)
  end

  defp run_flow(name, fun) do
    fun.()
    {:ok, name}
  rescue
    e -> {:error, {name, Exception.message(e)}}
  end

  # -- flows -------------------------------------------------------------------

  defp card_flow(base, mount) do
    card = get!(base <> mount <> "/.well-known/agent-card.json")
    %{"skills" => skills} = card

    ids = Enum.map(skills, & &1["id"])

    unless Enum.all?(["A2aDemo.Note.create_note", "A2aDemo.Note.read"], &(&1 in ids)) do
      raise "card skills missing: #{inspect(ids)}"
    end

    if mount == "/jsonrpc" do
      extensions = get_in(card, ["capabilities", "extensions"]) || []
      uris = Enum.map(extensions, & &1["uri"])

      unless @extension_uri in uris do
        raise "SA2A extension not advertised: #{inspect(uris)}"
      end

      {:ok, decoded} = AshA2A.Protocol.JSON.decode_agent_card(card)

      case A2aDemo.CardSigning.verify_served(decoded, base) do
        :ok -> :ok
        :no_signing_configured -> :ok
        {:error, reason} -> raise "served card signature invalid: #{inspect(reason)}"
      end
    end

    :ok
  end

  defp read_flow(base) do
    task = send_message(base, "get_note", %{}, "demo-token")

    unless task["status"]["state"] == "TASK_STATE_COMPLETED" do
      raise "expected COMPLETED, got #{inspect(task["status"])}"
    end

    notes = artifact_text(task)
    IO.puts("     notes artifact: #{String.slice(notes || "", 0, 80)}")
    :ok
  end

  defp cancel_flow(base) do
    task = send_message(base, "create_note", %{}, "demo-token")

    unless task["status"]["state"] == "TASK_STATE_INPUT_REQUIRED" do
      raise "expected INPUT_REQUIRED, got #{inspect(task["status"])}"
    end

    id = task["id"]

    got = tasks_get(base, id, "demo-token")
    unless got["status"]["state"] == "TASK_STATE_INPUT_REQUIRED", do: raise "tasks/get wrong state"

    canceled = tasks_cancel(base, id, "demo-token")

    unless canceled["status"]["state"] == "TASK_STATE_CANCELED" do
      raise "expected CANCELED, got #{inspect(canceled["status"])}"
    end

    :ok
  end

  defp create_flow(base) do
    text = "smoke-#{System.system_time(:millisecond)}"
    task = send_message(base, "create_note", %{"text" => text}, "demo-token")

    unless task["status"]["state"] == "TASK_STATE_COMPLETED" do
      raise "expected COMPLETED, got #{inspect(task["status"])}"
    end

    reread = send_message(base, "get_note", %{}, "demo-token")

    unless artifact_text(reread) =~ text do
      raise "created note not visible to observe read"
    end

    :ok
  end

  defp stream_flow(base) do
    body = rpc_body("message/stream", %{"message" => message("get_note", %{})})
    resp = post_raw!(base <> "/jsonrpc", body, "demo-token")

    unless get_header(resp, "content-type") =~ "text/event-stream" do
      raise "expected SSE, got #{get_header(resp, "content-type")}"
    end

    frames =
      raw_of(resp)
      |> String.split("\n\n")
      |> Enum.flat_map(fn block ->
        block
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))
        |> Enum.map(&(&1 |> String.trim_leading("data: ") |> Jason.decode!()))
      end)

    unless Enum.any?(frames, fn %{"result" => r} -> Map.has_key?(r, "task") end) do
      raise "no task frame in stream"
    end

    final =
      Enum.find(frames, fn %{"result" => r} -> Map.has_key?(r, "statusUpdate") end)

    unless final do
      raise "no final status frame; frames: #{inspect(frames)}"
    end

    encoded = Jason.encode!(final)

    # v1.0: finality rides on the terminal status state, not a "final" boolean.
    unless encoded =~ "TASK_STATE_COMPLETED" do
      raise "final status frame not COMPLETED: #{String.slice(encoded, 0, 300)}"
    end

    :ok
  end

  defp ungranted_flow(base) do
    # Valid credential, but no standing grant for the capability: the dispatch
    # path's authority admission refuses before the Ash action runs.
    resp =
      post_raw!(base <> "/jsonrpc", %{
        "jsonrpc" => "2.0",
        "id" => id(),
        "method" => "message/send",
        "params" => %{"message" => message("create_note", %{"text" => "should-not-land"})}
      }, "other-token")

    body = json_of(resp)
    encoded = Jason.encode!(body)

    task = get_in(body, ["result", "task"]) || body["result"]

    cond do
      body["error"] ->
        unless encoded =~ "authority" do
          raise "error envelope does not name authority: #{String.slice(encoded, 0, 300)}"
        end

      is_map(task) ->
        unless task["status"]["state"] == "TASK_STATE_FAILED" and encoded =~ "authority" do
          raise "expected FAILED naming authority, got #{String.slice(encoded, 0, 300)}"
        end

      true ->
        raise "expected a refusal, got #{inspect(body)}"
    end

    reread = send_message(base, "get_note", %{}, "demo-token")

    if artifact_text(reread) =~ "should-not-land" do
      raise "ungranted create landed anyway"
    end

    :ok
  end

  defp unauthenticated_flow(base) do
    body = rpc_body("message/send", %{"message" => message("get_note", %{})})
    resp = post_raw!(base <> "/jsonrpc", body, :none)

    unless resp.status == 401 do
      raise "expected 401, got #{resp.status}"
    end

    :ok
  end

  defp rest_flow(base) do
    task =
      post!(base <> "/rest/message:send", %{
        "message" => message("get_note", %{}),
        "configuration" => %{}
      })

    unless task["status"]["state"] == "TASK_STATE_COMPLETED" do
      raise "REST send expected COMPLETED, got #{inspect(task["status"])}"
    end

    id = task["id"]

    listed = get!(base <> "/rest/tasks")

    unless listed["tasks"] && Enum.any?(listed["tasks"], &(&1["id"] == id)) do
      raise "REST tasks list missing #{id}"
    end

    got = get!(base <> "/rest/tasks/#{id}")

    unless got["id"] == id do
      raise "REST tasks/get mismatch"
    end

    :ok
  end

  defp rest_cancel_flow(base) do
    task =
      post!(base <> "/rest/message:send", %{"message" => message("create_note", %{})})

    unless task["status"]["state"] == "TASK_STATE_INPUT_REQUIRED" do
      raise "REST send expected INPUT_REQUIRED, got #{inspect(task["status"])}"
    end

    id = task["id"]
    canceled = post!(base <> "/rest/tasks/#{id}:cancel", %{})

    unless canceled["status"]["state"] == "TASK_STATE_CANCELED" do
      raise "REST cancel expected CANCELED, got #{inspect(canceled["status"])}"
    end

    :ok
  end

  # -- helpers -------------------------------------------------------------------

  defp port, do: String.to_integer(System.get_env("A2A_DEMO_PORT") || "4010")

  defp message(skill, data) do
    %{
      "messageId" => "msg-#{System.system_time(:nanosecond)}-#{System.unique_integer()}",
      "role" => "ROLE_USER",
      "parts" => [%{"data" => data}],
      "metadata" => %{"skill" => skill}
    }
  end

  defp rpc_body(method, params),
    do: %{"jsonrpc" => "2.0", "id" => id(), "method" => method, "params" => params}

  defp id, do: System.unique_integer([:positive])

  defp send_message(base, skill, data, token) do
    body = rpc_body("message/send", %{"message" => message(skill, data)})
    resp = post_raw!(base <> "/jsonrpc", body, token)
    resp.body["result"]["task"] || resp.body["result"] || raise "no result: #{inspect(resp.body)}"
  end

  defp tasks_get(base, id, token) do
    body = rpc_body("tasks/get", %{"id" => id})
    resp = post_raw!(base <> "/jsonrpc", body, token)
    resp.body["result"] || raise "tasks/get failed: #{inspect(resp.body)}"
  end

  defp tasks_cancel(base, id, token) do
    body = rpc_body("tasks/cancel", %{"id" => id})
    resp = post_raw!(base <> "/jsonrpc", body, token)
    resp.body["result"] || raise "tasks/cancel failed: #{inspect(resp.body)}"
  end

  defp json_of(resp) when is_binary(resp.body), do: Jason.decode!(resp.body)
  defp json_of(%{body: body}) when is_map(body), do: body

  defp raw_of(resp) when is_binary(resp.body), do: resp.body
  defp raw_of(%{body: body}) when is_map(body), do: Jason.encode!(body)

  defp artifact_text(task) do
    task
    |> Kernel.get_in(["artifacts"])
    |> List.wrap()
    |> Enum.flat_map(&(&1["parts"] || []))
    |> Enum.map_join(" ", fn part -> part["text"] || Jason.encode!(part["data"] || %{}) end)
  end

  defp post!(url, json_params) do
    resp = post_raw!(url, json_params, "demo-token")
    resp.body || raise "empty REST body from #{url}"
  end

  defp post_raw!(url, body, token) do
    headers = [{"content-type", "application/json"}] ++ auth_header(token)
    request!(Req.post(url: url, json: body, headers: headers, retry: false))
  end

  defp get!(url) do
    resp =
      request!(
        Req.get(url: url, headers: [{"authorization", "Bearer demo-token"}], retry: false)
      )

    resp.body || raise "empty body from #{url}"
  end

  defp auth_header(:none), do: []
  defp auth_header(token), do: [{"authorization", "Bearer " <> token}]

  defp get_header(resp, name) do
    resp.headers
    |> Enum.find_value(fn {k, v} -> if String.downcase(k) == name, do: v end)
    |> List.wrap()
    |> List.first()
    || ""
  end

  defp request!({:ok, resp}), do: resp

  defp request!({:error, e}),
    do: raise("HTTP request failed: #{Exception.message(e)}")
end
