# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.Prover do
    @moduledoc """
    Drives every item of `AshA2A.Sim.Surface` over the real wire against a
    running `AshA2A.Sim.Server` and reports what it saw.

        {:ok, _pid} = AshA2A.Sim.Server.start_link()
        results = AshA2A.Sim.Prover.run()
        AshA2A.Sim.Prover.summary(results)
        #=> %{pass: 204, fail: 0, skip: 1}

    Each probe is one real client flow: `Req` for the JSON-RPC and HTTP+JSON
    mounts (server-sent events included), a `GRPC.Stub` channel for the gRPC
    endpoint. Mutation probes read `AshA2A.Sim.Note` through Ash after the wire
    call, so a probe passes only when the row really was created, changed,
    removed, or left alone.

    `probes/0` lists the probes without running them. Every probe names the
    surface item it proves (`:surface`, an `AshA2A.Sim.Surface` item id), so
    `AshA2A.Sim.Surface.uncovered/1` finds any served item with no probe.

    A result is `%{surface: id, probe: name, status: :pass | :fail | :skip,
    detail: text}`. A probe that cannot run reports `:skip` with the reason.
    """

    alias AshA2A.Sim.{Note, PushReceiver, Server, Surface}
    alias Lf.A2a.V1, as: Pb
    alias Lf.A2a.V1.A2AService.Stub
    alias AshA2A.Transport.Live.SessionSup, as: LiveSessionSup
    alias AshA2A.Sim.MCP.Wire, as: RawWire

    @type probe :: %{surface: String.t(), probe: String.t(), run: (map() -> term())}
    @type result :: %{
            surface: String.t(),
            probe: String.t(),
            status: :pass | :fail | :skip,
            detail: String.t()
          }

    @probe_timeout 45_000
    @jsonrpc_mounts ~w(a2a jsonrpc)a
    @terminal ~w(TASK_STATE_COMPLETED TASK_STATE_FAILED TASK_STATE_CANCELED TASK_STATE_REJECTED)

    defmodule Failure do
      @moduledoc false
      defexception [:message]
    end

    # -- public API ------------------------------------------------------------

    @doc """
    Runs every probe against the server described by `info`
    (`AshA2A.Sim.Server.info/0` by default) and returns the results in probe
    order.

    Options: `:only` - a function that takes a probe and returns whether to
    run it.
    """
    @spec run(map(), keyword()) :: [result()]
    def run(info \\ Server.info(), opts \\ []) do
      only = Keyword.get(opts, :only, fn _probe -> true end)

      probes()
      |> Enum.filter(only)
      |> Enum.map(&run_probe(&1, info))
    end

    @doc "Counts results by status."
    @spec summary([result()]) :: %{
            pass: non_neg_integer(),
            fail: non_neg_integer(),
            skip: non_neg_integer()
          }
    def summary(results) do
      counts = Enum.frequencies_by(results, & &1.status)

      %{
        pass: Map.get(counts, :pass, 0),
        fail: Map.get(counts, :fail, 0),
        skip: Map.get(counts, :skip, 0)
      }
    end

    @doc "Renders results as a text table: surface, probe, status, detail."
    @spec format([result()]) :: String.t()
    def format(results) do
      rows = Enum.map(results, &[&1.surface, &1.probe, Atom.to_string(&1.status), &1.detail])
      header = ["SURFACE", "PROBE", "STATUS", "DETAIL"]

      widths =
        [header | rows]
        |> Enum.map(fn row -> row |> Enum.take(3) |> Enum.map(&String.length/1) end)
        |> Enum.zip_with(&Enum.max/1)

      line = fn [a, b, c, d] ->
        [a, b, c]
        |> Enum.zip(widths)
        |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
        |> Kernel.<>("  " <> d)
        |> String.trim_trailing()
      end

      Enum.map_join([header | rows], "\n", line)
    end

    @doc "Every probe, in run order, without running any."
    @spec probes() :: [probe()]
    def probes do
      Enum.flat_map(Surface.items() ++ Surface.parity(), &probes_for/1)
    end

    defp run_probe(probe, info) do
      task = Task.async(fn -> execute(probe, info) end)

      {status, detail} =
        case Task.yield(task, @probe_timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, outcome} -> outcome
          nil -> {:fail, "no answer within #{@probe_timeout} ms"}
          {:exit, reason} -> {:fail, "probe crashed: " <> clip(inspect(reason))}
        end

      %{surface: probe.surface, probe: probe.probe, status: status, detail: detail}
    end

    defp execute(probe, info) do
      case probe.run.(info) do
        {:skip, reason} when is_binary(reason) -> {:skip, reason}
        detail when is_binary(detail) -> {:pass, detail}
        other -> {:fail, "probe returned #{clip(inspect(other))}"}
      end
    rescue
      e in Failure -> {:fail, e.message}
      e -> {:fail, clip(Exception.format(:error, e, __STACKTRACE__), 600)}
    catch
      kind, reason -> {:fail, clip("#{kind}: #{inspect(reason)}")}
    end

    defp p(item, name, fun), do: %{surface: item.id, probe: name, run: fun}

    # -- probes per surface item -----------------------------------------------

    defp probes_for(%{kind: :jsonrpc_method, name: method} = item) do
      a2a =
        for {label, fun} <- jsonrpc_scenarios(method) do
          p(item, label <> " (/a2a)", fn info -> fun.(caller(info, :a2a, method, method)) end)
        end

      owner_scoped =
        for {label, fun} <- owner_scoped_scenarios(method) do
          p(item, label <> " (/jsonrpc)", fn info ->
            fun.(caller(info, :jsonrpc, method, method))
          end)
        end

      a2a ++ owner_scoped ++ jsonrpc_negative(item, method)
    end

    defp probes_for(%{kind: :jsonrpc_alias, name: spelling} = item) do
      target = Surface.alias_target(spelling)

      for {label, fun} <- Enum.take(jsonrpc_scenarios(target), 1) do
        p(item, "#{label} as #{spelling} (/a2a)", fn info ->
          fun.(caller(info, :a2a, target, spelling))
        end)
      end
    end

    defp probes_for(%{kind: :grpc_rpc, name: rpc} = item) do
      for {label, fun} <- grpc_scenarios(rpc), do: p(item, label, fun)
    end

    defp probes_for(%{kind: :http_route, name: route} = item) do
      for {label, fun} <- rest_scenarios(route), do: p(item, label, fun)
    end

    defp probes_for(%{kind: :skill, name: id} = item) do
      for {label, fun} <- skill_scenarios(id), do: p(item, label, fun)
    end

    defp probes_for(%{kind: :consequence, name: class} = item) do
      for {label, fun} <- consequence_scenarios(class), do: p(item, label, fun)
    end

    defp probes_for(%{kind: :task_state, name: state} = item) do
      for {label, fun} <- task_state_scenarios(state), do: p(item, label, fun)
    end

    defp probes_for(%{kind: :security_scheme, name: scheme} = item) do
      for {label, fun} <- security_scenarios(scheme), do: p(item, label, fun)
    end

    defp probes_for(%{kind: :mount, name: mount} = item) do
      for {label, fun} <- mount_scenarios(mount), do: p(item, label, fun)
    end

    defp probes_for(%{kind: :authority, name: name} = item) do
      for {label, fun} <- AshA2A.Sim.Authority.scenarios(name), do: p(item, label, fun)
    end

    defp probes_for(%{kind: kind} = item) when kind in [:email_route, :email_outcome] do
      for {label, fun} <- AshA2A.Sim.Email.probes(item), do: p(item, label, fun)
    end

    # One probe per binding of the parity report. The script runs once per
    # server; every probe reads the same report.
    defp probes_for(%{kind: :parity, name: binding} = item) do
      [
        p(item, "wire output matches the upstream v1.1 reference", fn info ->
          case parity_report(info) do
            {:ok, report} ->
              case AshA2A.Sim.Parity.verdict(report, binding) do
                {:pass, detail} -> detail
                {:skip, detail} -> {:skip, detail}
                {:fail, detail} -> fail!(detail)
              end

            {:skip, reason} ->
              {:skip, reason}

            {:error, reason} ->
              fail!(reason)
          end
        end)
      ]
    end

    defp probes_for(_item), do: []

    defp parity_report(info) do
      key = {__MODULE__, :parity, info.http_port, info.grpc_port}

      case :persistent_term.get(key, nil) do
        nil ->
          result = AshA2A.Sim.Parity.run(info, timeout: @probe_timeout - 3_000)
          :persistent_term.put(key, result)
          result

        result ->
          result
      end
    end

    # == JSON-RPC ================================================================

    # A caller bound to one mount. The method under test is sent under
    # `spelling`; every other method keeps its canonical name.
    defp caller(info, mount, tested, spelling) do
      url = if mount == :a2a, do: info.a2a_url, else: info.jsonrpc_url

      %{
        info: info,
        mount: mount,
        url: url,
        name: fn method -> if method == tested, do: spelling, else: method end
      }
    end

    defp jr(c, method, params, opts \\ []) do
      body = %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => c.name.(method),
        "params" => params
      }

      http(c.info, :post, c.url, Keyword.put(opts, :json, body))
    end

    defp jr_result!(c, method, params, opts \\ []) do
      resp = jr(c, method, params, opts)

      case resp.json do
        %{"result" => result} ->
          result

        other ->
          fail!("#{method} answered #{clip(inspect(other || resp.raw))} (HTTP #{resp.status})")
      end
    end

    defp jr_error!(c, method, params, code, opts \\ []) do
      resp = jr(c, method, params, opts)

      case resp.json do
        %{"error" => %{"code" => ^code} = error} ->
          error

        other ->
          fail!(
            "#{method} expected error #{code}, got #{clip(inspect(other || resp.raw))} (HTTP #{resp.status})"
          )
      end
    end

    defp jr_get!(c, id, opts \\ []),
      do: c |> jr_result!("tasks/get", %{"id" => id}, opts) |> task_of!()

    defp jr_await!(c, id, states, timeout \\ 10_000) do
      await!("task #{id} to reach #{inspect(states)}", timeout, fn ->
        task = jr_get!(c, id)
        if state(task) in List.wrap(states), do: task
      end)
    end

    defp jsonrpc_scenarios("message/live") do
      [
        {"live downlink: session id, task snapshot in JSON-RPC responses",
         fn c ->
           resp =
             jr(c, "message/live", %{"sendMessage" => send_params("count_notes", %{})},
               receive_timeout: 15_000
             )

           check!(resp.status == 200, "HTTP #{resp.status}: #{clip(resp.raw)}")
           sid = resp.headers["a2a-live-session-id"]
           check!(is_binary(sid) and sid != "", "no a2a-live-session-id response header")
           frames = sse_results!(resp)
           kinds = Enum.map(frames, &frame_kind/1)
           check!("task" in kinds, "no task frame in #{inspect(kinds)}")
           states = frames |> Enum.map(&frame_state/1) |> Enum.reject(&is_nil/1)

           check!(
             List.last(states) == "TASK_STATE_COMPLETED",
             "live stream ended in #{inspect(List.last(states))}"
           )

           "session #{sid}: #{length(frames)} frame(s) ending TASK_STATE_COMPLETED"
         end}
      ]
    end

    defp jsonrpc_scenarios("message/send") do
      [
        {"blocking send completes with an artifact",
         fn c ->
           seed_note!(c.info, "send-blocking")
           task = jr_send!(c, "list_notes", %{})
           expect_state!(task, "TASK_STATE_COMPLETED")
           check!(artifacts?(task), "completed task carries no artifact")
           "task #{task["id"]} completed with #{length(task["artifacts"])} artifact(s)"
         end},
        {"non-blocking send returns before the work is done",
         fn c ->
           task =
             jr_send!(c, "slow_count", %{"delay_ms" => 400}, %{
               "configuration" => %{"returnImmediately" => true}
             })

           first = state(task)

           check!(
             first in ["TASK_STATE_SUBMITTED", "TASK_STATE_WORKING"],
             "first state was #{first}"
           )

           done = jr_await!(c, task["id"], "TASK_STATE_COMPLETED")
           check!(artifacts?(done), "finished task carries no artifact")
           "returned #{first}, then tasks/get saw TASK_STATE_COMPLETED"
         end},
        {"a non-blocking send's task id is usable at once: get, then cancel",
         fn c ->
           task =
             jr_send!(c, "slow_count", %{"delay_ms" => 30_000}, %{
               "configuration" => %{"returnImmediately" => true}
             })

           id = task["id"]
           got = jr_get!(c, id)
           check!(got["id"] == id, "tasks/get answered another task")
           check!(state(got) not in @terminal, "the just-sent task was already #{state(got)}")

           jr_error!(c, "tasks/get", %{"id" => id}, -32_001, token: :reader)
           jr_error!(c, "tasks/cancel", %{"id" => id}, -32_001, token: :reader)
           expect_state!(jr_get!(c, id), state(got))
           canceled = c |> jr_result!("tasks/cancel", %{"id" => id}) |> task_of!()
           expect_state!(canceled, "TASK_STATE_CANCELED")
           expect_state!(jr_get!(c, id), "TASK_STATE_CANCELED")

           "task #{id} read back #{state(got)} and canceled right after the send returned; " <>
             "another caller got -32001 for both"
         end}
      ]
    end

    defp jsonrpc_scenarios("message/stream") do
      [
        {"SSE stream: task, artifact chunk, final status",
         fn c ->
           title = seed_note!(c.info, "stream")

           resp =
             jr(c, "message/stream", send_params("list_notes", %{"stream" => true}))

           frames = sse_results!(resp)
           kinds = Enum.map(frames, &frame_kind/1)
           check!(List.first(kinds) == "task", "first frame was #{inspect(List.first(kinds))}")
           check!("artifactUpdate" in kinds, "no artifactUpdate frame in #{inspect(kinds)}")
           check!(resp.raw =~ title, "streamed chunks do not carry the seeded note #{title}")
           final = List.last(frames)

           check!(
             get_in(final, ["statusUpdate", "status", "state"]) == "TASK_STATE_COMPLETED",
             "last frame was #{clip(inspect(final))}"
           )

           "#{length(frames)} frames: #{Enum.join(Enum.uniq(kinds), ", ")}"
         end},
        {"the Task frame arrives while the handler is still running",
         fn c ->
           body = %{
             "jsonrpc" => "2.0",
             "id" => System.unique_integer([:positive]),
             "method" => c.name.("message/stream"),
             "params" => send_params("slow_count", %{"delay_ms" => 1_500})
           }

           c.info
           |> timed_sse!(c.url, body, fn
             %{"result" => result} -> result
             other -> fail!("SSE frame is not a JSON-RPC result: #{clip(inspect(other))}")
           end)
           |> check_admit_first!(1_500, &jr_get!(c, &1))
         end}
      ]
    end

    defp jsonrpc_scenarios("tasks/get") do
      [
        {"returns the stored task by id",
         fn c ->
           task = jr_send!(c, "count_notes", %{})
           got = jr_get!(c, task["id"])
           check!(got["id"] == task["id"], "id mismatch")
           expect_state!(got, "TASK_STATE_COMPLETED")
           check!(got["contextId"] == task["contextId"], "contextId mismatch")
           "task #{got["id"]} read back in state #{state(got)}"
         end}
      ]
    end

    defp jsonrpc_scenarios("tasks/list") do
      [
        {"pages and filters by context and status",
         fn c ->
           context = "ctx-probe-" <> unique()

           ids =
             for _ <- 1..3 do
               c
               |> jr_send!("count_notes", %{}, %{}, context_id: context)
               |> Map.fetch!("id")
             end

           page1 = jr_result!(c, "tasks/list", %{"contextId" => context, "pageSize" => 2})
           check!(length(page1["tasks"]) == 2, "page 1 held #{length(page1["tasks"])} tasks")
           check!(page1["totalSize"] == 3, "totalSize was #{inspect(page1["totalSize"])}")
           token = page1["nextPageToken"]
           check!(is_binary(token) and token != "", "no nextPageToken on a partial page")

           page2 =
             jr_result!(c, "tasks/list", %{
               "contextId" => context,
               "pageSize" => 2,
               "pageToken" => token
             })

           listed = Enum.map(page1["tasks"] ++ page2["tasks"], & &1["id"])

           check!(
             Enum.sort(listed) == Enum.sort(ids),
             "pages did not cover the 3 tasks exactly once"
           )

           check!(page2["nextPageToken"] in [nil, ""], "last page still has a nextPageToken")

           completed =
             jr_result!(c, "tasks/list", %{
               "contextId" => context,
               "status" => "TASK_STATE_COMPLETED"
             })

           failed =
             jr_result!(c, "tasks/list", %{
               "contextId" => context,
               "status" => "TASK_STATE_FAILED"
             })

           check!(
             length(completed["tasks"]) == 3,
             "status filter COMPLETED matched #{length(completed["tasks"])}"
           )

           check!(
             failed["tasks"] == [],
             "status filter FAILED matched #{length(failed["tasks"])}"
           )

           "2 + 1 over two pages, totalSize 3, status filter 3 completed / 0 failed"
         end}
      ]
    end

    defp jsonrpc_scenarios("tasks/cancel") do
      [
        {"cancels a task that is still running",
         fn c ->
           started = System.monotonic_time(:millisecond)

           task =
             jr_send!(c, "slow_count", %{"delay_ms" => 30_000}, %{
               "configuration" => %{"returnImmediately" => true}
             })

           check!(state(task) not in @terminal, "task was already #{state(task)}")
           canceled = c |> jr_result!("tasks/cancel", %{"id" => task["id"]}) |> task_of!()
           expect_state!(canceled, "TASK_STATE_CANCELED")
           expect_state!(jr_get!(c, task["id"]), "TASK_STATE_CANCELED")
           elapsed = System.monotonic_time(:millisecond) - started

           check!(
             elapsed < 10_000,
             "cancel took #{elapsed} ms, the 30 s work was not interrupted"
           )

           "30 s task canceled after #{elapsed} ms and stays TASK_STATE_CANCELED"
         end}
      ]
    end

    defp jsonrpc_scenarios("tasks/resubscribe") do
      [
        {"SSE resubscribe follows a running task to its final state",
         fn c ->
           task =
             jr_send!(c, "slow_count", %{"delay_ms" => 600}, %{
               "configuration" => %{"returnImmediately" => true}
             })

           resp = jr(c, "tasks/resubscribe", %{"id" => task["id"]}, receive_timeout: 15_000)
           frames = sse_results!(resp)
           first = List.first(frames)

           check!(
             get_in(first, ["task", "id"]) == task["id"],
             "first frame was #{clip(inspect(first))}"
           )

           states = Enum.map(frames, &frame_state/1)

           check!(
             List.last(states) == "TASK_STATE_COMPLETED",
             "stream ended in #{inspect(List.last(states))}, frames #{inspect(Enum.map(frames, &frame_kind/1))}"
           )

           "#{length(frames)} frames, states #{Enum.join(Enum.reject(states, &is_nil/1), " -> ")}"
         end}
      ]
    end

    defp jsonrpc_scenarios("tasks/pushNotificationConfig/set") do
      [
        {"stores a config for a task",
         fn c ->
           task = parked_task!(c)
           url = c.info.push_url <> "/set-" <> unique()
           config = jr_push_set!(c, task["id"], url, "tok-set")
           check!(config["url"] == url, "stored url was #{inspect(config["url"])}")
           check!(is_binary(config["id"]) and config["id"] != "", "no config id assigned")
           "config #{config["id"]} stored for #{task["id"]}"
         end},
        {"a stored config receives a real webhook delivery",
         fn c ->
           task = parked_task!(c)
           suffix = "/deliver-" <> unique()
           token = "tok-" <> unique()
           jr_push_set!(c, task["id"], c.info.push_url <> suffix, token)
           title = "pushed-" <> unique()

           done =
             jr_send!(c, "create_note", %{"title" => title}, %{}, task_id: task["id"])

           expect_state!(done, "TASK_STATE_COMPLETED")
           delivery = await_delivery!(suffix)

           check!(
             delivery.headers["x-a2a-notification-token"] == token,
             "delivery carried token #{inspect(delivery.headers["x-a2a-notification-token"])}"
           )

           check!(delivery.raw =~ task["id"], "delivery body does not name task #{task["id"]}")

           check!(
             delivery.raw =~ "TASK_STATE_COMPLETED",
             "delivery body does not carry the final state"
           )

           "webhook POST #{delivery.path} carried the completed task and the config token"
         end}
      ]
    end

    defp jsonrpc_scenarios("tasks/pushNotificationConfig/get") do
      [
        {"reads back the config that was asked for",
         fn c ->
           task = parked_task!(c)
           one = jr_push_set!(c, task["id"], c.info.push_url <> "/get-a-" <> unique(), "a")
           two = jr_push_set!(c, task["id"], c.info.push_url <> "/get-b-" <> unique(), "b")

           got =
             c
             |> jr_result!("tasks/pushNotificationConfig/get", %{
               "id" => task["id"],
               "pushNotificationConfigId" => two["id"]
             })
             |> push_config_of()

           check!(got["id"] == two["id"], "asked for #{two["id"]}, got #{inspect(got["id"])}")
           check!(got["url"] == two["url"], "url mismatch")
           check!(one["id"] != two["id"], "two configs share an id")
           "config #{two["id"]} of 2 read back with its own url"
         end}
      ]
    end

    defp jsonrpc_scenarios("tasks/pushNotificationConfig/list") do
      [
        {"lists every config of a task",
         fn c ->
           task = parked_task!(c)
           one = jr_push_set!(c, task["id"], c.info.push_url <> "/list-a-" <> unique(), "a")
           two = jr_push_set!(c, task["id"], c.info.push_url <> "/list-b-" <> unique(), "b")

           listed =
             c
             |> jr_result!("tasks/pushNotificationConfig/list", %{"id" => task["id"]})
             |> push_configs_of()

           ids = listed |> Enum.map(& &1["id"]) |> Enum.sort()
           check!(ids == Enum.sort([one["id"], two["id"]]), "listed #{inspect(ids)}")
           "2 configs listed for #{task["id"]}"
         end}
      ]
    end

    defp jsonrpc_scenarios("tasks/pushNotificationConfig/delete") do
      [
        {"removes one config and leaves the other",
         fn c ->
           task = parked_task!(c)
           one = jr_push_set!(c, task["id"], c.info.push_url <> "/del-a-" <> unique(), "a")
           two = jr_push_set!(c, task["id"], c.info.push_url <> "/del-b-" <> unique(), "b")

           resp =
             jr(c, "tasks/pushNotificationConfig/delete", %{
               "id" => task["id"],
               "pushNotificationConfigId" => one["id"]
             })

           check!(
             is_map(resp.json) and not Map.has_key?(resp.json, "error"),
             "delete answered #{clip(resp.raw)}"
           )

           left =
             c
             |> jr_result!("tasks/pushNotificationConfig/list", %{"id" => task["id"]})
             |> push_configs_of()
             |> Enum.map(& &1["id"])

           check!(left == [two["id"]], "after delete the task holds #{inspect(left)}")

           jr_error!(
             c,
             "tasks/pushNotificationConfig/get",
             %{"id" => task["id"], "pushNotificationConfigId" => one["id"]},
             -32_001
           )

           "config #{one["id"]} gone (get answers -32001), #{two["id"]} kept"
         end}
      ]
    end

    defp jsonrpc_scenarios("agent/getAuthenticatedExtendedCard") do
      [
        {"an authenticated caller gets the extended card",
         fn c ->
           card = jr_result!(c, "agent/getAuthenticatedExtendedCard", %{})
           ids = Enum.map(card["skills"] || [], & &1["id"])

           check!(
             "AshA2A.Sim.extended_only" in ids,
             "extended skill missing from #{inspect(ids)}"
           )

           public = http(c.info, :get, c.info.card_url, token: :none).json
           public_ids = Enum.map(public["skills"], & &1["id"])

           check!(
             "AshA2A.Sim.extended_only" not in public_ids,
             "public card lists the extended skill"
           )

           check!(public_ids -- ids == [], "extended card dropped public skills")
           "#{length(ids)} skills, #{length(ids) - length(public_ids)} more than the public card"
         end},
        {"the extended card's signature verifies, and a changed byte is refused",
         fn c ->
           card = jr_result!(c, "agent/getAuthenticatedExtendedCard", %{})
           extended_signature!(c.info, card)
         end}
      ]
    end

    # The extended card is signed with the key of the public card
    # (`info.card_jwks`), over the card each binding serves.
    defp extended_signature!(info, card) do
      alias AshA2A.Protocol.AgentCardSignature, as: Signature

      signatures = card["signatures"]

      check!(
        match?([%{"protected" => _, "signature" => _} | _], signatures),
        "the extended card carries no signatures entry: #{clip(inspect(signatures), 200)}"
      )

      check!(
        "AshA2A.Sim.extended_only" in Enum.map(card["skills"] || [], & &1["id"]),
        "not the extended card"
      )

      kids =
        case Signature.verify(card, info.card_jwks, require: :all) do
          {:ok, kids} -> kids
          {:error, reason} -> fail!("signature refused: #{inspect(reason)}")
        end

      <<first, rest::binary>> = card["name"]
      tampered = Map.put(card, "name", <<Bitwise.bxor(first, 1)>> <> rest)

      case Signature.verify(tampered, info.card_jwks) do
        {:error, :bad_signature} -> :ok
        other -> fail!("a changed byte was not refused: #{inspect(other)}")
      end

      "#{length(signatures)} signature, kid #{Enum.join(kids, ", ")} verified over the served extended card; one changed byte refused"
    end

    defp jsonrpc_scenarios(_method), do: []

    # `AshA2A.Transport.Plug` serves the task methods itself and answers the
    # documented typed refusal for the methods it does not carry.
    defp owner_scoped_scenarios("tasks/pushNotificationConfig/" <> _ = method) do
      [
        {"answers -32003: this mount does not serve push configs",
         fn c ->
           task = parked_task!(c)

           params = %{
             "taskId" => task["id"],
             "id" => task["id"],
             "pushNotificationConfigId" => "none",
             "pushNotificationConfig" => %{"url" => c.info.push_url}
           }

           error = jr_error!(c, method, params, -32_003)
           "refused #{error["code"]} #{error["message"]}"
         end}
      ]
    end

    defp owner_scoped_scenarios("agent/getAuthenticatedExtendedCard" = method) do
      [
        {"answers -32007: no extended card on this mount",
         fn c ->
           error = jr_error!(c, method, %{}, -32_007)

           card =
             http(c.info, :get, c.info.jsonrpc_url <> "/.well-known/agent-card.json",
               token: :none
             ).json

           check!(
             get_in(card, ["capabilities", "extendedAgentCard"]) != true,
             "the mount's card still advertises extendedAgentCard"
           )

           "refused #{error["code"]}, and the mount's card does not advertise the capability"
         end}
      ]
    end

    # `/jsonrpc` resubscribes through `AshA2A.Protocol.Plug.SSE`, which replays
    # from the configured `AshA2A.Protocol.EventJournal`. A finished task has
    # no live producer and this mount has no transport event log, so the
    # frames below can only come from the journal.
    defp owner_scoped_scenarios("tasks/resubscribe" = method) do
      jsonrpc_scenarios(method) ++
        [
          {"lastSeenGeneration replays the missed events from the event journal",
           fn c ->
             parked = parked_task!(c)
             seen = wire_generation!(parked)
             title = "journal-" <> unique()

             done = jr_send!(c, "create_note", %{"title" => title}, %{}, task_id: parked["id"])
             expect_state!(done, "TASK_STATE_COMPLETED")
             current = wire_generation!(done)
             check!(current > seen, "generation did not advance: #{seen} -> #{current}")

             resp =
               jr(c, "tasks/resubscribe", %{"id" => parked["id"], "lastSeenGeneration" => seen},
                 receive_timeout: 15_000
               )

             frames = sse_results!(resp)
             kinds = Enum.map(frames, &frame_kind/1)
             gens = Enum.map(frames, &frame_generation/1)

             check!(frames != [], "no frames replayed")

             check!(
               "task" not in kinds,
               "a resume carries no Task snapshot, got #{inspect(kinds)}"
             )

             check!(
               Enum.all?(gens, &is_integer/1),
               "a frame has no generation: #{inspect(kinds)}"
             )

             check!(gens == Enum.sort(gens), "replay out of order: #{inspect(gens)}")

             check!(
               Enum.all?(gens, &(&1 > seen and &1 <= current)),
               "replayed generations #{inspect(gens)} are not within #{seen + 1}..#{current}"
             )

             check!(
               "messageUpdate" in kinds,
               "the follow-up message was not replayed: #{inspect(kinds)}"
             )

             last = List.last(frames)

             check!(
               frame_state(last) == "TASK_STATE_COMPLETED" and List.last(gens) == current,
               "replay ended with #{clip(inspect(last), 200)}"
             )

             "#{length(frames)} journaled frames (#{Enum.join(kinds, ", ")}), generations #{seen + 1}..#{current}"
           end}
        ]
    end

    defp owner_scoped_scenarios(method), do: jsonrpc_scenarios(method)

    defp wire_generation!(task) do
      case task["generation"] do
        g when is_integer(g) ->
          g

        g when is_binary(g) ->
          String.to_integer(g)

        other ->
          fail!("task carries no generation: #{inspect(other)}")
      end
    end

    defp frame_generation(frame) do
      case frame |> Map.values() |> Enum.find_value(&(is_map(&1) && &1["generation"])) do
        g when is_integer(g) -> g
        g when is_binary(g) -> String.to_integer(g)
        _ -> nil
      end
    end

    defp jsonrpc_negative(item, "message/send") do
      [
        p(item, "missing message is -32602 (/a2a)", fn info ->
          c = caller(info, :a2a, nil, nil)
          error = jr_error!(c, "message/send", %{"configuration" => %{}}, -32_602)
          "refused #{error["code"]} #{error["message"]}"
        end),
        p(item, "missing message is -32602 (/jsonrpc)", fn info ->
          c = caller(info, :jsonrpc, nil, nil)
          error = jr_error!(c, "message/send", %{"configuration" => %{}}, -32_602)
          "refused #{error["code"]} #{error["message"]}"
        end),
        p(item, "wrong-typed message is -32602 (/jsonrpc)", fn info ->
          c = caller(info, :jsonrpc, nil, nil)
          error = jr_error!(c, "message/send", %{"message" => "not an object"}, -32_602)
          "refused #{error["code"]} #{error["message"]}"
        end),
        p(item, "stale ifGenerationMatch is -32010 and changes nothing (/jsonrpc)", fn info ->
          c = caller(info, :jsonrpc, nil, nil)
          stale_generation_probe(c)
        end),
        p(item, "stale ifGenerationMatch is -32010 and changes nothing (/a2a)", fn info ->
          c = caller(info, :a2a, nil, nil)
          stale_generation_probe(c)
        end),
        p(item, "a continuation by another caller is refused (/jsonrpc)", fn info ->
          c = caller(info, :jsonrpc, nil, nil)
          task = parked_task!(c)
          title = "foreign-" <> unique()

          resp =
            jr(
              c,
              "message/send",
              send_params("create_note", %{"title" => title}, %{}, task_id: task["id"]),
              token: :reader
            )

          check!(get_in(resp.json, ["error", "code"]) == -32_001, "answered #{clip(resp.raw)}")
          check!(note_by_title(title) == nil, "the foreign continuation created a row")
          expect_state!(jr_get!(c, task["id"]), "TASK_STATE_INPUT_REQUIRED")
          "refused -32001, no row created, the owner's task still waits for input"
        end)
      ]
    end

    defp jsonrpc_negative(item, "tasks/get") do
      for mount <- @jsonrpc_mounts do
        [
          p(item, "unknown task is -32001 (/#{mount})", fn info ->
            c = caller(info, mount, nil, nil)
            error = jr_error!(c, "tasks/get", %{"id" => "tsk-does-not-exist"}, -32_001)
            "refused #{error["code"]} #{error["message"]}"
          end),
          p(item, "another caller's task is -32001 (/#{mount})", fn info ->
            c = caller(info, mount, nil, nil)
            task = jr_send!(c, "count_notes", %{})
            error = jr_error!(c, "tasks/get", %{"id" => task["id"]}, -32_001, token: :reader)
            "the reader cannot see the writer's task: #{error["code"]}"
          end),
          p(item, "missing id is -32602 (/#{mount})", fn info ->
            c = caller(info, mount, nil, nil)
            error = jr_error!(c, "tasks/get", %{}, -32_602)
            "refused #{error["code"]} #{error["message"]}"
          end)
        ]
      end
      |> List.flatten()
    end

    defp jsonrpc_negative(item, "tasks/cancel") do
      for mount <- @jsonrpc_mounts do
        [
          p(item, "unknown task is -32001 (/#{mount})", fn info ->
            c = caller(info, mount, nil, nil)
            error = jr_error!(c, "tasks/cancel", %{"id" => "tsk-does-not-exist"}, -32_001)
            "refused #{error["code"]} #{error["message"]}"
          end),
          p(item, "a completed task is -32002 not cancelable (/#{mount})", fn info ->
            c = caller(info, mount, nil, nil)
            task = jr_send!(c, "count_notes", %{})
            error = jr_error!(c, "tasks/cancel", %{"id" => task["id"]}, -32_002)
            expect_state!(jr_get!(c, task["id"]), "TASK_STATE_COMPLETED")
            "refused #{error["code"]}, task stays completed"
          end)
        ]
      end
      |> List.flatten()
    end

    defp jsonrpc_negative(item, "tasks/list") do
      for mount <- @jsonrpc_mounts do
        [
          p(item, "wrong-typed pageSize is -32602 (/#{mount})", fn info ->
            c = caller(info, mount, nil, nil)
            error = jr_error!(c, "tasks/list", %{"pageSize" => "abc"}, -32_602)
            "refused #{error["code"]}: #{clip(inspect(error["data"]), 120)}"
          end),
          p(item, "out-of-range pageSize is -32602 (/#{mount})", fn info ->
            c = caller(info, mount, nil, nil)
            error = jr_error!(c, "tasks/list", %{"pageSize" => 0}, -32_602)
            "refused #{error["code"]}"
          end),
          p(item, "wrong-typed status is -32602 (/#{mount})", fn info ->
            c = caller(info, mount, nil, nil)
            error = jr_error!(c, "tasks/list", %{"status" => 42}, -32_602)
            "refused #{error["code"]}"
          end),
          p(item, "invalid pageToken is -32602 (/#{mount})", fn info ->
            c = caller(info, mount, nil, nil)
            error = jr_error!(c, "tasks/list", %{"pageToken" => "not-a-token"}, -32_602)
            "refused #{error["code"]}"
          end),
          p(item, "lists only the caller's own tasks (/#{mount})", fn info ->
            c = caller(info, mount, nil, nil)
            context = "ctx-own-" <> unique()
            mine = jr_send!(c, "count_notes", %{}, %{}, context_id: context)
            seen = jr_result!(c, "tasks/list", %{"contextId" => context}, token: :reader)

            check!(
              seen["tasks"] == [],
              "the reader listed #{length(seen["tasks"])} of the writer's tasks"
            )

            own = jr_result!(c, "tasks/list", %{"contextId" => context})

            check!(
              Enum.map(own["tasks"], & &1["id"]) == [mine["id"]],
              "the writer does not see its task"
            )

            "writer sees 1 task in the context, reader sees 0"
          end)
        ]
      end
      |> List.flatten()
    end

    defp jsonrpc_negative(item, "tasks/resubscribe") do
      for mount <- @jsonrpc_mounts do
        p(item, "unknown task is -32001 (/#{mount})", fn info ->
          c = caller(info, mount, nil, nil)
          error = jr_error!(c, "tasks/resubscribe", %{"id" => "tsk-does-not-exist"}, -32_001)
          "refused #{error["code"]} #{error["message"]}"
        end)
      end
    end

    defp jsonrpc_negative(item, "tasks/pushNotificationConfig/set") do
      [
        p(item, "unknown task is -32001 (/a2a)", fn info ->
          c = caller(info, :a2a, nil, nil)

          error =
            jr_error!(
              c,
              "tasks/pushNotificationConfig/set",
              %{
                "taskId" => "tsk-does-not-exist",
                "pushNotificationConfig" => %{"url" => info.push_url}
              },
              -32_001
            )

          "refused #{error["code"]} #{error["message"]}"
        end),
        p(item, "a webhook URL without a host is -32602 (/a2a)", fn info ->
          c = caller(info, :a2a, nil, nil)
          task = parked_task!(c)

          error =
            jr_error!(
              c,
              "tasks/pushNotificationConfig/set",
              %{"taskId" => task["id"], "pushNotificationConfig" => %{"url" => "not a url"}},
              -32_602
            )

          "refused #{error["code"]}: #{clip(inspect(error["data"]), 120)}"
        end),
        p(item, "another caller cannot attach a webhook to the task (/a2a)", fn info ->
          c = caller(info, :a2a, nil, nil)
          task = parked_task!(c)

          error =
            jr_error!(
              c,
              "tasks/pushNotificationConfig/set",
              %{
                "taskId" => task["id"],
                "pushNotificationConfig" => %{"url" => info.push_url <> "/foreign"}
              },
              -32_001,
              token: :reader
            )

          "refused #{error["code"]}: the task is not the reader's"
        end)
      ]
    end

    defp jsonrpc_negative(_item, _method), do: []

    defp stale_generation_probe(c) do
      task = parked_task!(c)
      title = "stale-" <> unique()

      params =
        send_params(
          "create_note",
          %{"title" => title},
          %{"configuration" => %{"ifGenerationMatch" => 0}},
          task_id: task["id"]
        )

      resp = jr(c, "message/send", params)

      if get_in(resp.json, ["error", "code"]) != -32_010 do
        fail!("stale ifGenerationMatch answered #{clip(resp.raw)}")
      end

      check!(note_by_title(title) == nil, "the refused send created the row anyway")
      expect_state!(jr_get!(c, task["id"]), "TASK_STATE_INPUT_REQUIRED")
      "refused -32010, no row created, task still waits for input"
    end

    defp parked_task!(c) do
      task = jr_send!(c, "create_note", %{})
      expect_state!(task, "TASK_STATE_INPUT_REQUIRED")
      task
    end

    defp jr_push_set!(c, task_id, url, token) do
      c
      |> jr_result!("tasks/pushNotificationConfig/set", %{
        "taskId" => task_id,
        "pushNotificationConfig" => %{"url" => url, "token" => token}
      })
      |> push_config_of()
    end

    # == HTTP+JSON ===============================================================

    defp rest(info, method, path, opts), do: http(info, method, info.rest_url <> path, opts)

    defp rest_ok!(info, method, path, opts \\ []) do
      resp = rest(info, method, path, opts)

      check!(
        resp.status == 200,
        "#{method} #{path} answered HTTP #{resp.status}: #{clip(resp.raw)}"
      )

      resp.json
    end

    defp rest_error!(info, method, path, status, opts \\ []) do
      resp = rest(info, method, path, opts)

      check!(
        resp.status == status,
        "#{method} #{path} expected HTTP #{status}, got #{resp.status}: #{clip(resp.raw)}"
      )

      resp
    end

    defp rest_send!(info, skill, data, extra \\ %{}, opts \\ []) do
      {path, opts} = Keyword.pop(opts, :path, "/message:send")
      {msg_opts, http_opts} = Keyword.split(opts, [:task_id, :context_id])

      info
      |> rest_ok!(
        :post,
        path,
        Keyword.put(http_opts, :json, send_params(skill, data, extra, msg_opts))
      )
      |> task_of!()
    end

    defp rest_get!(info, id), do: info |> rest_ok!(:get, "/tasks/#{id}") |> task_of!()

    defp rest_await!(info, id, states, timeout \\ 10_000) do
      await!("task #{id} to reach #{inspect(states)}", timeout, fn ->
        task = rest_get!(info, id)
        if state(task) in List.wrap(states), do: task
      end)
    end

    defp rest_parked!(info) do
      task = rest_send!(info, "create_note", %{})
      expect_state!(task, "TASK_STATE_INPUT_REQUIRED")
      task
    end

    defp rest_push_set!(info, task_id, segment, url, token) do
      info
      |> rest_ok!(:post, "/tasks/#{task_id}/#{segment}",
        json: %{"pushNotificationConfig" => %{"url" => url, "token" => token}}
      )
      |> push_config_of()
    end

    defp rest_scenarios("GET /.well-known/agent-card.json") do
      [
        {"the card is served without credentials and names this mount",
         fn info ->
           resp = rest_error!(info, :get, "/.well-known/agent-card.json", 200, token: :none)
           urls = Enum.map(resp.json["supportedInterfaces"], & &1["url"])

           check!(
             info.rest_url in urls,
             "card interfaces #{inspect(urls)} do not name #{info.rest_url}"
           )

           "card names #{length(urls)} interfaces, this mount among them"
         end}
      ]
    end

    defp rest_scenarios("POST /message:send") do
      [
        {"blocking send completes",
         fn info ->
           task = rest_send!(info, "count_notes", %{})
           expect_state!(task, "TASK_STATE_COMPLETED")
           check!(artifacts?(task), "no artifact")
           "task #{task["id"]} completed"
         end},
        {"non-blocking send returns before the work is done",
         fn info ->
           task =
             rest_send!(info, "slow_count", %{"delay_ms" => 400}, %{
               "configuration" => %{"returnImmediately" => true}
             })

           first = state(task)

           check!(
             first in ["TASK_STATE_SUBMITTED", "TASK_STATE_WORKING"],
             "first state was #{first}"
           )

           rest_await!(info, task["id"], "TASK_STATE_COMPLETED")
           "returned #{first}, then GET /tasks/{id} saw TASK_STATE_COMPLETED"
         end},
        {"a non-blocking send's task id is usable at once: get, then cancel",
         fn info ->
           task =
             rest_send!(info, "slow_count", %{"delay_ms" => 30_000}, %{
               "configuration" => %{"returnImmediately" => true}
             })

           id = task["id"]
           got = rest_get!(info, id)
           check!(got["id"] == id, "GET /tasks/{id} answered another task")
           check!(state(got) not in @terminal, "the just-sent task was already #{state(got)}")
           rest_error!(info, :get, "/tasks/#{id}", 404, token: :reader)
           rest_error!(info, :post, "/tasks/#{id}:cancel", 404, json: %{}, token: :reader)
           expect_state!(rest_get!(info, id), state(got))
           canceled = info |> rest_ok!(:post, "/tasks/#{id}:cancel", json: %{}) |> task_of!()
           expect_state!(canceled, "TASK_STATE_CANCELED")
           expect_state!(rest_get!(info, id), "TASK_STATE_CANCELED")

           "task #{id} read back #{state(got)} and canceled right after the send returned; " <>
             "another caller got 404 for both"
         end},
        {"served under a /{tenant} prefix",
         fn info ->
           task = rest_send!(info, "count_notes", %{}, %{}, path: "/acme/message:send")
           expect_state!(task, "TASK_STATE_COMPLETED")
           "POST /acme/message:send completed task #{task["id"]}"
         end},
        {"missing message is 400",
         fn info ->
           resp = rest_error!(info, :post, "/message:send", 400, json: %{"configuration" => %{}})
           "HTTP 400 #{get_in(resp.json, ["error", "status"])}"
         end},
        {"a body that is not JSON is 400",
         fn info ->
           resp = rest_error!(info, :post, "/message:send", 400, body: "{not json")
           "HTTP 400 #{get_in(resp.json, ["error", "status"])}"
         end},
        {"stale ifGenerationMatch is 409 and changes nothing",
         fn info ->
           task = rest_parked!(info)
           title = "stale-rest-" <> unique()

           resp =
             rest_error!(info, :post, "/message:send", 409,
               json:
                 send_params(
                   "create_note",
                   %{"title" => title},
                   %{"configuration" => %{"ifGenerationMatch" => 0}},
                   task_id: task["id"]
                 )
             )

           check!(
             resp.raw =~ "TASK_GENERATION_MISMATCH",
             "409 body does not name the mismatch: #{clip(resp.raw)}"
           )

           check!(note_by_title(title) == nil, "the refused send created the row anyway")
           "HTTP 409 TASK_GENERATION_MISMATCH, no row created"
         end},
        {"an unsupported A2A-Version is 400",
         fn info ->
           resp =
             rest_error!(info, :post, "/message:send", 400,
               json: send_params("count_notes", %{}),
               version: "9.9"
             )

           check!(
             resp.raw =~ "VERSION_NOT_SUPPORTED",
             "400 body does not name the version: #{clip(resp.raw)}"
           )

           "HTTP 400 VERSION_NOT_SUPPORTED"
         end},
        {"wrong verb is 405",
         fn info ->
           resp = rest_error!(info, :get, "/message:send", 405)
           "HTTP 405, allow: #{resp.headers["allow"]}"
         end}
      ]
    end

    defp rest_scenarios("POST /message:stream") do
      [
        {"SSE stream: task, artifact chunk, final status",
         fn info ->
           title = seed_note!(info, "rest-stream")

           resp =
             rest(info, :post, "/message:stream",
               json: send_params("list_notes", %{"stream" => true})
             )

           frames = sse_frames!(resp)
           kinds = Enum.map(frames, &frame_kind/1)
           check!(List.first(kinds) == "task", "first frame was #{inspect(List.first(kinds))}")
           check!("artifactUpdate" in kinds, "no artifactUpdate frame in #{inspect(kinds)}")
           check!(resp.raw =~ title, "streamed chunks do not carry the seeded note")

           check!(
             frame_state(List.last(frames)) == "TASK_STATE_COMPLETED",
             "last frame was #{clip(inspect(List.last(frames)))}"
           )

           "#{length(frames)} frames: #{Enum.join(Enum.uniq(kinds), ", ")}"
         end},
        {"the Task frame arrives while the handler is still running",
         fn info ->
           info
           |> timed_sse!(
             info.rest_url <> "/message:stream",
             send_params("slow_count", %{"delay_ms" => 1_500}),
             & &1
           )
           |> check_admit_first!(1_500, &rest_get!(info, &1))
         end}
      ]
    end

    defp rest_scenarios("POST /message:live") do
      [
        {"live downlink: session id, task snapshot, final status",
         fn info ->
           resp =
             rest(info, :post, "/message:live",
               json: %{"sendMessage" => send_params("count_notes", %{})},
               receive_timeout: 15_000
             )

           check!(resp.status == 200, "HTTP #{resp.status}: #{clip(resp.raw)}")
           sid = resp.headers["a2a-live-session-id"]
           check!(is_binary(sid) and sid != "", "no a2a-live-session-id response header")
           frames = sse_frames!(resp)
           kinds = Enum.map(frames, &frame_kind/1)
           check!("task" in kinds, "no task frame in #{inspect(kinds)}")
           states = frames |> Enum.map(&frame_state/1) |> Enum.reject(&is_nil/1)

           check!(
             List.last(states) == "TASK_STATE_COMPLETED",
             "live stream ended in #{inspect(List.last(states))}"
           )

           "session #{sid}: #{length(frames)} frames ending TASK_STATE_COMPLETED"
         end},
        {"live subscribe to an unknown task answers a NOT_FOUND stream error",
         fn info ->
           resp =
             rest(info, :post, "/message:live",
               json: %{"subscribe" => %{"id" => "tsk-does-not-exist"}},
               receive_timeout: 15_000
             )

           check!(resp.raw =~ "NOT_FOUND", "answered HTTP #{resp.status}: #{clip(resp.raw)}")
           "stream error NOT_FOUND"
         end}
      ]
    end

    defp rest_scenarios("GET /tasks/{id}") do
      [
        {"returns the stored task",
         fn info ->
           task = rest_send!(info, "count_notes", %{})
           got = rest_get!(info, task["id"])
           check!(got["id"] == task["id"], "id mismatch")
           expect_state!(got, "TASK_STATE_COMPLETED")
           "task #{got["id"]} read back"
         end},
        {"unknown task is 404",
         fn info ->
           resp = rest_error!(info, :get, "/tasks/tsk-does-not-exist", 404)
           "HTTP 404 #{get_in(resp.json, ["error", "status"])}"
         end},
        {"another caller's task is 404",
         fn info ->
           task = rest_send!(info, "count_notes", %{})
           rest_error!(info, :get, "/tasks/#{task["id"]}", 404, token: :reader)
           "the reader gets 404 for the writer's task"
         end}
      ]
    end

    defp rest_scenarios("POST /tasks/{id}:cancel") do
      [
        {"cancels a task that is still running",
         fn info ->
           task =
             rest_send!(info, "slow_count", %{"delay_ms" => 30_000}, %{
               "configuration" => %{"returnImmediately" => true}
             })

           canceled =
             info |> rest_ok!(:post, "/tasks/#{task["id"]}:cancel", json: %{}) |> task_of!()

           expect_state!(canceled, "TASK_STATE_CANCELED")
           expect_state!(rest_get!(info, task["id"]), "TASK_STATE_CANCELED")
           "30 s task canceled in flight"
         end},
        {"unknown task is 404",
         fn info ->
           rest_error!(info, :post, "/tasks/tsk-does-not-exist:cancel", 404, json: %{})
           "HTTP 404"
         end},
        {"a completed task is not cancelable",
         fn info ->
           task = rest_send!(info, "count_notes", %{})
           resp = rest(info, :post, "/tasks/#{task["id"]}:cancel", json: %{})
           check!(resp.status in [400, 409], "HTTP #{resp.status}: #{clip(resp.raw)}")

           check!(
             resp.raw =~ "TASK_NOT_CANCELABLE",
             "body does not name the refusal: #{clip(resp.raw)}"
           )

           "HTTP #{resp.status} TASK_NOT_CANCELABLE"
         end}
      ]
    end

    defp rest_scenarios("GET /tasks") do
      [
        {"pages and filters by context and status",
         fn info ->
           context = "ctx-rest-" <> unique()

           ids =
             for _ <- 1..3,
                 do: rest_send!(info, "count_notes", %{}, %{}, context_id: context)["id"]

           page1 = rest_ok!(info, :get, "/tasks", params: [contextId: context, pageSize: 2])
           check!(length(page1["tasks"]) == 2, "page 1 held #{length(page1["tasks"])}")
           check!(page1["totalSize"] == 3, "totalSize was #{inspect(page1["totalSize"])}")

           page2 =
             rest_ok!(info, :get, "/tasks",
               params: [contextId: context, pageSize: 2, pageToken: page1["nextPageToken"]]
             )

           listed = Enum.map(page1["tasks"] ++ page2["tasks"], & &1["id"])

           check!(
             Enum.sort(listed) == Enum.sort(ids),
             "pages did not cover the 3 tasks exactly once"
           )

           failed =
             rest_ok!(info, :get, "/tasks",
               params: [contextId: context, status: "TASK_STATE_FAILED"]
             )

           check!(
             failed["tasks"] == [],
             "status filter FAILED matched #{length(failed["tasks"])}"
           )

           "2 + 1 over two pages, totalSize 3, FAILED filter empty"
         end},
        {"wrong-typed pageSize is 400",
         fn info ->
           resp = rest_error!(info, :get, "/tasks", 400, params: [pageSize: "abc"])
           "HTTP 400 #{get_in(resp.json, ["error", "status"])}"
         end},
        {"invalid pageToken is 400",
         fn info ->
           rest_error!(info, :get, "/tasks", 400, params: [pageToken: "not-a-token"])
           "HTTP 400"
         end},
        {"unknown status value is 400",
         fn info ->
           rest_error!(info, :get, "/tasks", 400, params: [status: "TASK_STATE_NOPE"])
           "HTTP 400"
         end}
      ]
    end

    defp rest_scenarios(verb_subscribe)
         when verb_subscribe in ["GET /tasks/{id}:subscribe", "POST /tasks/{id}:subscribe"] do
      method = if String.starts_with?(verb_subscribe, "GET"), do: :get, else: :post

      [
        {"SSE subscribe follows a running task to its final state",
         fn info ->
           task =
             rest_send!(info, "slow_count", %{"delay_ms" => 600}, %{
               "configuration" => %{"returnImmediately" => true}
             })

           opts = if method == :post, do: [json: %{}], else: []

           resp =
             rest(
               info,
               method,
               "/tasks/#{task["id"]}:subscribe",
               [receive_timeout: 15_000] ++ opts
             )

           frames = sse_frames!(resp)

           check!(
             get_in(List.first(frames), ["task", "id"]) == task["id"],
             "first frame was #{clip(inspect(List.first(frames)))}"
           )

           states = frames |> Enum.map(&frame_state/1) |> Enum.reject(&is_nil/1)

           check!(
             List.last(states) == "TASK_STATE_COMPLETED",
             "stream ended in #{inspect(List.last(states))}"
           )

           "#{length(frames)} frames, states #{Enum.join(states, " -> ")}"
         end},
        {"unknown task is 404",
         fn info ->
           opts = if method == :post, do: [json: %{}], else: []
           rest_error!(info, method, "/tasks/tsk-does-not-exist:subscribe", 404, opts)
           "HTTP 404"
         end},
        {"a finished task is 400 unsupported operation",
         fn info ->
           task = rest_send!(info, "count_notes", %{})
           opts = if method == :post, do: [json: %{}], else: []
           resp = rest_error!(info, method, "/tasks/#{task["id"]}:subscribe", 400, opts)
           check!(resp.raw =~ "UNSUPPORTED_OPERATION", "body: #{clip(resp.raw)}")
           "HTTP 400 UNSUPPORTED_OPERATION"
         end}
      ]
    end

    defp rest_scenarios("POST /tasks/{id}/" <> segment)
         when segment in ["pushNotificationConfigs", "pushNotificationConfig"] do
      [
        {"stores a config and a real webhook delivery follows",
         fn info ->
           task = rest_parked!(info)
           suffix = "/rest-#{segment}-" <> unique()
           token = "tok-" <> unique()
           config = rest_push_set!(info, task["id"], segment, info.push_url <> suffix, token)

           check!(
             config["url"] == info.push_url <> suffix,
             "stored url #{inspect(config["url"])}"
           )

           done =
             rest_send!(info, "create_note", %{"title" => "rest-pushed-" <> unique()}, %{},
               task_id: task["id"]
             )

           expect_state!(done, "TASK_STATE_COMPLETED")
           delivery = await_delivery!(suffix)

           check!(
             delivery.headers["x-a2a-notification-token"] == token,
             "delivery token mismatch"
           )

           check!(delivery.raw =~ task["id"], "delivery does not name the task")
           "config #{config["id"]} stored; webhook POST #{delivery.path} received"
         end},
        {"unknown task is 404",
         fn info ->
           rest_error!(info, :post, "/tasks/tsk-does-not-exist/#{segment}", 404,
             json: %{"pushNotificationConfig" => %{"url" => info.push_url}}
           )

           "HTTP 404"
         end}
      ]
    end

    defp rest_scenarios("GET /tasks/{id}/" <> segment)
         when segment in ["pushNotificationConfigs", "pushNotificationConfig"] do
      [
        {"lists every config of a task",
         fn info ->
           task = rest_parked!(info)

           one =
             rest_push_set!(info, task["id"], segment, info.push_url <> "/l1-" <> unique(), "a")

           two =
             rest_push_set!(info, task["id"], segment, info.push_url <> "/l2-" <> unique(), "b")

           listed = info |> rest_ok!(:get, "/tasks/#{task["id"]}/#{segment}") |> push_configs_of()
           ids = listed |> Enum.map(& &1["id"]) |> Enum.sort()
           check!(ids == Enum.sort([one["id"], two["id"]]), "listed #{inspect(ids)}")
           "2 configs listed"
         end}
      ]
    end

    defp rest_scenarios("GET /tasks/{id}/" <> rest)
         when rest in ["pushNotificationConfigs/{configId}", "pushNotificationConfig/{configId}"] do
      segment = rest |> String.split("/") |> hd()

      [
        {"reads back the config that was asked for",
         fn info ->
           task = rest_parked!(info)

           _one =
             rest_push_set!(info, task["id"], segment, info.push_url <> "/g1-" <> unique(), "a")

           two =
             rest_push_set!(info, task["id"], segment, info.push_url <> "/g2-" <> unique(), "b")

           got =
             info
             |> rest_ok!(:get, "/tasks/#{task["id"]}/#{segment}/#{two["id"]}")
             |> push_config_of()

           check!(
             got["id"] == two["id"] and got["url"] == two["url"],
             "got #{clip(inspect(got))}"
           )

           "config #{two["id"]} of 2 read back"
         end},
        {"a missing config is 404",
         fn info ->
           task = rest_parked!(info)
           rest_error!(info, :get, "/tasks/#{task["id"]}/#{segment}/no-such-config", 404)
           "HTTP 404"
         end}
      ]
    end

    defp rest_scenarios("DELETE /tasks/{id}/" <> rest)
         when rest in ["pushNotificationConfigs/{configId}", "pushNotificationConfig/{configId}"] do
      segment = rest |> String.split("/") |> hd()

      [
        {"removes one config and leaves the other",
         fn info ->
           task = rest_parked!(info)

           one =
             rest_push_set!(info, task["id"], segment, info.push_url <> "/d1-" <> unique(), "a")

           two =
             rest_push_set!(info, task["id"], segment, info.push_url <> "/d2-" <> unique(), "b")

           rest_error!(info, :delete, "/tasks/#{task["id"]}/#{segment}/#{one["id"]}", 200)

           left =
             info
             |> rest_ok!(:get, "/tasks/#{task["id"]}/#{segment}")
             |> push_configs_of()
             |> Enum.map(& &1["id"])

           check!(left == [two["id"]], "after delete the task holds #{inspect(left)}")
           "config #{one["id"]} gone, #{two["id"]} kept"
         end}
      ]
    end

    defp rest_scenarios(route) when route in ["GET /extendedAgentCard", "POST /agent"] do
      [method, path] = String.split(route, " ")
      method = method |> String.downcase() |> String.to_existing_atom()

      [
        {"an authenticated caller gets the extended card",
         fn info ->
           opts = if method == :post, do: [json: %{}], else: []
           resp = rest_error!(info, method, path, 200, opts)
           ids = Enum.map(resp.json["skills"] || [], & &1["id"])

           check!(
             "AshA2A.Sim.extended_only" in ids,
             "extended skill missing from #{inspect(ids)}"
           )

           check!(
             resp.headers["cache-control"] =~ "private",
             "extended card is cacheable: #{resp.headers["cache-control"]}"
           )

           urls = Enum.map(resp.json["supportedInterfaces"], & &1["url"])

           check!(
             info.rest_url in urls,
             "extended card interfaces #{inspect(urls)} do not name this mount"
           )

           "#{length(ids)} skills, cache-control #{resp.headers["cache-control"]}"
         end},
        {"the extended card's signature verifies, and a changed byte is refused",
         fn info ->
           opts = if method == :post, do: [json: %{}], else: []
           resp = rest_error!(info, method, path, 200, opts)
           extended_signature!(info, Jason.decode!(resp.raw))
         end},
        {"refused without credentials",
         fn info ->
           opts = if method == :post, do: [json: %{}], else: []
           rest_error!(info, method, path, 401, [token: :none] ++ opts)
           "HTTP 401"
         end}
      ]
    end

    defp rest_scenarios("GET /.well-known/agent-card.schema.json") do
      [
        {"serves the agent card JSON Schema",
         fn info ->
           schema = rest_ok!(info, :get, "/.well-known/agent-card.schema.json")

           check!(
             is_map(schema) and Map.has_key?(schema, "$schema"),
             "not a JSON Schema: #{clip(inspect(schema))}"
           )

           card = rest_ok!(info, :get, "/.well-known/agent-card.json", token: :none)
           missing = (schema["required"] || []) -- Map.keys(card)

           check!(
             missing == [],
             "the served card lacks schema-required members #{inspect(missing)}"
           )

           "schema #{schema["$id"] || schema["title"]}; the served card has every required member"
         end}
      ]
    end

    defp rest_scenarios("GET /.well-known/skills.schema.json") do
      [
        {"serves an input schema for every skill",
         fn info ->
           schema = rest_ok!(info, :get, "/.well-known/skills.schema.json")
           raw = Jason.encode!(schema)
           missing = for %{name: id} <- Surface.skills(), not (raw =~ id), do: id
           check!(missing == [], "no schema for skills #{inspect(missing)}")
           "schemas for all #{length(Surface.skills())} skills"
         end}
      ]
    end

    defp rest_scenarios(_route), do: []

    # == gRPC ====================================================================

    defp grpc(info, token, fun) do
      {:ok, channel} = GRPC.Stub.connect(info.grpc_target, adapter: GRPC.Client.Adapters.Mint)

      try do
        fun.(channel, grpc_opts(info, token))
      after
        GRPC.Stub.disconnect(channel)
      end
    end

    defp grpc_opts(info, token, extra \\ %{}) do
      metadata =
        case token_value(info, token) do
          nil -> %{"a2a-version" => "1.1"}
          value -> %{"a2a-version" => "1.1", "authorization" => "Bearer " <> value}
        end

      [metadata: Map.merge(metadata, extra), timeout: 20_000]
    end

    defp pb(module, map), do: map |> Jason.encode!() |> Protobuf.JSON.decode!(module)
    defp unpb(message), do: message |> Protobuf.JSON.encode!() |> Jason.decode!()

    defp grpc_ok!({:ok, reply}, _what), do: unpb(reply)
    defp grpc_ok!({:ok, reply, _headers}, _what), do: unpb(reply)

    defp grpc_ok!({:error, %GRPC.RPCError{} = error}, what),
      do: fail!("#{what} answered gRPC status #{error.status}: #{clip(to_string(error.message))}")

    defp grpc_status!({:error, %GRPC.RPCError{status: status} = error}, status, _what), do: error

    defp grpc_status!(other, status, what),
      do: fail!("#{what} expected gRPC status #{status}, got #{clip(inspect(other))}")

    defp grpc_send!(channel, opts, skill, data, extra \\ %{}, msg_opts \\ []) do
      request = pb(Pb.SendMessageRequest, send_params(skill, data, extra, msg_opts))
      channel |> Stub.send_message(request, opts) |> grpc_ok!("SendMessage") |> task_of!()
    end

    defp grpc_get!(channel, opts, id),
      do: channel |> Stub.get_task(%Pb.GetTaskRequest{id: id}, opts) |> grpc_ok!("GetTask")

    defp grpc_await!(channel, opts, id, states, timeout \\ 10_000) do
      await!("task #{id} to reach #{inspect(states)}", timeout, fn ->
        task = grpc_get!(channel, opts, id)
        if state(task) in List.wrap(states), do: task
      end)
    end

    defp grpc_parked!(channel, opts) do
      task = grpc_send!(channel, opts, "create_note", %{})
      expect_state!(task, "TASK_STATE_INPUT_REQUIRED")
      task
    end

    defp grpc_push_set!(channel, opts, task_id, url, token) do
      channel
      |> Stub.create_task_push_notification_config(
        %Pb.TaskPushNotificationConfig{task_id: task_id, url: url, token: token},
        opts
      )
      |> grpc_ok!("CreateTaskPushNotificationConfig")
    end

    defp grpc_stream!({:ok, replies}, _what) do
      Enum.map(replies, fn
        {:ok, frame} ->
          unpb(frame)

        {:error, %GRPC.RPCError{} = error} ->
          fail!("stream ended with gRPC status #{error.status}: #{error.message}")

        other ->
          fail!("unexpected stream element #{clip(inspect(other))}")
      end)
    end

    defp grpc_stream!({:error, %GRPC.RPCError{} = error}, what),
      do: fail!("#{what} answered gRPC status #{error.status}: #{clip(to_string(error.message))}")

    defp grpc_scenarios("SendMessage") do
      [
        {"a message the decoder refuses (no parts) is INVALID_ARGUMENT",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             params =
               update_in(send_params("count_notes", %{}), ["message"], &Map.put(&1, "parts", []))

             request = pb(Pb.SendMessageRequest, params)

             error =
               ch
               |> Stub.send_message(request, opts)
               |> grpc_status!(3, "SendMessage without parts")

             "gRPC status 3 INVALID_ARGUMENT: #{clip(to_string(error.message), 80)}"
           end)
         end},
        {"blocking send completes",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task = grpc_send!(ch, opts, "count_notes", %{})
             expect_state!(task, "TASK_STATE_COMPLETED")
             check!(artifacts?(task), "no artifact")
             "task #{task["id"]} completed"
           end)
         end},
        {"non-blocking send returns before the work is done",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task =
               grpc_send!(ch, opts, "slow_count", %{"delay_ms" => 400}, %{
                 "configuration" => %{"returnImmediately" => true}
               })

             first = state(task)

             check!(
               first in ["TASK_STATE_SUBMITTED", "TASK_STATE_WORKING"],
               "first state was #{first}"
             )

             grpc_await!(ch, opts, task["id"], "TASK_STATE_COMPLETED")
             "returned #{first}, then GetTask saw TASK_STATE_COMPLETED"
           end)
         end},
        {"an integer argument sent as a protobuf number is accepted",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task = grpc_send!(ch, opts, "slow_count", %{"delay_ms" => 50})
             expect_state!(task, "TASK_STATE_COMPLETED")
             "delay_ms 50 (a double inside google.protobuf.Struct) ran the integer-typed action"
           end)
         end},
        {"create over gRPC writes the row",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             title = "grpc-create-" <> unique()

             task =
               grpc_send!(ch, opts, "create_note", %{"title" => title, "body" => "over grpc"})

             expect_state!(task, "TASK_STATE_COMPLETED")
             note = note_by_title(title)
             check!(note != nil, "no row titled #{title} after the call")
             check!(note.body == "over grpc", "row body is #{inspect(note.body)}")
             "row #{note.id} exists in the data layer"
           end)
         end},
        {"create over gRPC without authority writes nothing",
         fn info ->
           grpc(info, :reader, fn ch, opts ->
             title = "grpc-refused-" <> unique()
             before = note_count()
             task = grpc_send!(ch, opts, "create_note", %{"title" => title})
             expect_state!(task, "TASK_STATE_REJECTED")

             check!(
               Jason.encode!(task) =~ "authority_required",
               "refusal does not name authority"
             )

             check!(note_by_title(title) == nil, "the refused create wrote a row")
             check!(note_count() == before, "row count changed from #{before} to #{note_count()}")
             "refused authority_required, row count stays #{before}"
           end)
         end},
        {"stale ifGenerationMatch is ABORTED",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task = grpc_parked!(ch, opts)
             title = "grpc-stale-" <> unique()

             request =
               pb(
                 Pb.SendMessageRequest,
                 send_params(
                   "create_note",
                   %{"title" => title},
                   %{"configuration" => %{"ifGenerationMatch" => 0}},
                   task_id: task["id"]
                 )
               )

             ch |> Stub.send_message(request, opts) |> grpc_status!(10, "stale SendMessage")
             check!(note_by_title(title) == nil, "the refused send created the row anyway")
             "gRPC status 10 ABORTED, no row created"
           end)
         end},
        {"an unsupported A2A-Version is FAILED_PRECONDITION",
         fn info ->
           grpc(info, :writer, fn ch, _opts ->
             opts = grpc_opts(info, :writer, %{"a2a-version" => "9.9"})
             request = pb(Pb.SendMessageRequest, send_params("count_notes", %{}))

             error =
               ch |> Stub.send_message(request, opts) |> grpc_status!(9, "SendMessage v9.9")

             "gRPC status 9: #{clip(to_string(error.message), 80)}"
           end)
         end},
        {"a non-blocking send's task id is usable at once: get, then cancel",
         fn info ->
           {id, first} =
             grpc(info, :writer, fn ch, opts ->
               task =
                 grpc_send!(ch, opts, "slow_count", %{"delay_ms" => 30_000}, %{
                   "configuration" => %{"returnImmediately" => true}
                 })

               got = grpc_get!(ch, opts, task["id"])
               check!(got["id"] == task["id"], "GetTask answered another task")
               check!(state(got) not in @terminal, "the just-sent task was already #{state(got)}")
               {task["id"], state(got)}
             end)

           grpc(info, :reader, fn ch, opts ->
             ch |> Stub.get_task(%Pb.GetTaskRequest{id: id}, opts) |> grpc_status!(5, "GetTask")

             ch
             |> Stub.cancel_task(%Pb.CancelTaskRequest{id: id}, opts)
             |> grpc_status!(5, "CancelTask")
           end)

           grpc(info, :writer, fn ch, opts ->
             expect_state!(grpc_get!(ch, opts, id), first)

             canceled =
               ch
               |> Stub.cancel_task(%Pb.CancelTaskRequest{id: id}, opts)
               |> grpc_ok!("CancelTask")

             expect_state!(canceled, "TASK_STATE_CANCELED")
             expect_state!(grpc_get!(ch, opts, id), "TASK_STATE_CANCELED")
           end)

           "task #{id} read back #{first} and canceled right after the send returned; " <>
             "another caller got NOT_FOUND for both"
         end}
      ]
    end

    defp grpc_scenarios("SendStreamingMessage") do
      [
        {"server stream: task, artifact chunk, final status",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             title = seed_note!(info, "grpc-stream")
             request = pb(Pb.SendMessageRequest, send_params("list_notes", %{"stream" => true}))

             frames =
               ch
               |> Stub.send_streaming_message(request, opts)
               |> grpc_stream!("SendStreamingMessage")

             kinds = Enum.map(frames, &frame_kind/1)
             check!("artifactUpdate" in kinds, "no artifactUpdate frame in #{inspect(kinds)}")

             check!(
               Jason.encode!(frames) =~ title,
               "streamed chunks do not carry the seeded note"
             )

             check!(
               frame_state(List.last(frames)) == "TASK_STATE_COMPLETED",
               "last frame #{clip(inspect(List.last(frames)))}"
             )

             "#{length(frames)} frames: #{Enum.join(Enum.uniq(kinds), ", ")}"
           end)
         end},
        {"the Task frame arrives while the handler is still running",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             request =
               pb(Pb.SendMessageRequest, send_params("slow_count", %{"delay_ms" => 1_500}))

             started = System.monotonic_time(:millisecond)

             {:ok, replies} =
               case Stub.send_streaming_message(ch, request, opts) do
                 {:ok, _replies} = ok -> ok
                 other -> fail!("SendStreamingMessage answered #{clip(inspect(other))}")
               end

             replies
             |> Enum.map(fn
               {:ok, frame} -> {System.monotonic_time(:millisecond) - started, unpb(frame)}
               other -> fail!("unexpected stream element #{clip(inspect(other))}")
             end)
             |> check_admit_first!(1_500, &grpc_get!(ch, opts, &1))
           end)
         end}
      ]
    end

    defp grpc_scenarios("SendLiveMessage") do
      [
        {"bidirectional stream: send, task snapshot, final status",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             stream = Stub.send_live_message(ch, opts)
             request = pb(Pb.SendMessageRequest, send_params("count_notes", %{}))

             stream =
               GRPC.Stub.send_request(stream, %Pb.StreamRequest{
                 payload: {:send_message, request}
               })

             frames = stream |> GRPC.Stub.recv(timeout: 15_000) |> grpc_stream!("SendLiveMessage")
             kinds = Enum.map(frames, &frame_kind/1)
             check!("task" in kinds, "no task frame in #{inspect(kinds)}")
             states = frames |> Enum.map(&frame_state/1) |> Enum.reject(&is_nil/1)

             check!(
               List.last(states) == "TASK_STATE_COMPLETED",
               "live stream ended in #{inspect(List.last(states))}"
             )

             "#{length(frames)} frames ending TASK_STATE_COMPLETED"
           end)
         end},
        {"a client that half-closes after its one message still gets the task",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             title = "live-half-close-" <> unique()
             stream = Stub.send_live_message(ch, opts)

             request =
               pb(Pb.SendMessageRequest, send_params("create_note", %{"title" => title}))

             stream =
               GRPC.Stub.send_request(
                 stream,
                 %Pb.StreamRequest{payload: {:send_message, request}},
                 end_stream: true
               )

             frames =
               stream |> GRPC.Stub.recv(timeout: 15_000) |> grpc_stream!("SendLiveMessage")

             kinds = Enum.map(frames, &frame_kind/1)
             check!(List.first(kinds) == "task", "first frame was #{inspect(List.first(kinds))}")
             states = frames |> Enum.map(&frame_state/1) |> Enum.reject(&is_nil/1)

             check!(
               List.last(states) == "TASK_STATE_COMPLETED",
               "the half-closed stream ended in #{inspect(List.last(states))}"
             )

             note = note_by_title(title)
             check!(note != nil, "frames arrived but the row is missing")

             check!(
               Jason.encode!(frames) =~ note.id,
               "the frames do not carry the created row #{note.id}"
             )

             "#{length(frames)} frame(s) after half-close ending TASK_STATE_COMPLETED; row #{note.id} exists"
           end)
         end},
        {"a half-closed stream stays open until slow in-flight work answers",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             stream = Stub.send_live_message(ch, opts)

             request =
               pb(Pb.SendMessageRequest, send_params("slow_count", %{"delay_ms" => 1_500}))

             started = System.monotonic_time(:millisecond)

             stream =
               GRPC.Stub.send_request(
                 stream,
                 %Pb.StreamRequest{payload: {:send_message, request}},
                 end_stream: true
               )

             frames =
               stream |> GRPC.Stub.recv(timeout: 15_000) |> grpc_stream!("SendLiveMessage")

             elapsed = System.monotonic_time(:millisecond) - started
             states = frames |> Enum.map(&frame_state/1) |> Enum.reject(&is_nil/1)

             check!(
               List.last(states) == "TASK_STATE_COMPLETED",
               "#{length(frames)} frame(s) after #{elapsed} ms, ending in #{inspect(List.last(states))}"
             )

             check!(elapsed >= 1_500, "the stream ended after #{elapsed} ms, before the work")
             check!(Jason.encode!(frames) =~ "count", "no frame carries the answer")

             "#{length(frames)} frame(s) #{elapsed} ms after the half-close, ending TASK_STATE_COMPLETED"
           end)
         end},
        {"several messages on one stream continue one task",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             context = "ctx-live-multi-" <> unique()
             title = "live-multi-" <> unique()
             before = note_count()
             stream = Stub.send_live_message(ch, opts)

             first =
               pb(
                 Pb.SendMessageRequest,
                 send_params("create_note", %{"body" => "from message one"}, %{},
                   context_id: context
                 )
               )

             stream =
               GRPC.Stub.send_request(stream, %Pb.StreamRequest{payload: {:send_message, first}})

             parked =
               await!("the first message to park its task", 5_000, fn ->
                 listed =
                   ch
                   |> Stub.list_tasks(%Pb.ListTasksRequest{context_id: context}, opts)
                   |> grpc_ok!("ListTasks")

                 case listed["tasks"] do
                   [%{"status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}} = task] -> task
                   _other -> nil
                 end
               end)

             check!(note_count() == before, "the incomplete first message wrote a row")

             # No taskId: a later request applies to the task the stream is bound to.
             second = pb(Pb.SendMessageRequest, send_params("create_note", %{"title" => title}))

             stream =
               GRPC.Stub.send_request(
                 stream,
                 %Pb.StreamRequest{payload: {:send_message, second}},
                 end_stream: true
               )

             frames =
               stream |> GRPC.Stub.recv(timeout: 15_000) |> grpc_stream!("SendLiveMessage")

             kinds = Enum.map(frames, &frame_kind/1)
             check!("error" not in kinds, "a request was rejected: #{clip(inspect(frames))}")
             check!(List.first(kinds) == "task", "first frame was #{inspect(List.first(kinds))}")
             states = frames |> Enum.map(&frame_state/1) |> Enum.reject(&is_nil/1)

             check!(
               List.first(states) == "TASK_STATE_INPUT_REQUIRED" and
                 List.last(states) == "TASK_STATE_COMPLETED",
               "states were #{inspect(states)}"
             )

             ids =
               frames
               |> Enum.map(fn frame ->
                 get_in(frame, ["task", "id"]) || get_in(frame, [frame_kind(frame), "taskId"])
               end)
               |> Enum.uniq()

             check!(ids == [parked["id"]], "frames name tasks #{inspect(ids)}")

             check!(
               "messageUpdate" in kinds,
               "the second message was not echoed as a messageUpdate: #{inspect(kinds)}"
             )

             note = note_by_title(title)
             check!(note != nil, "no row after the second message")

             check!(
               note.body == "from message one",
               "the first message's body was lost: #{inspect(note.body)}"
             )

             "2 messages, #{length(frames)} frames on task #{parked["id"]}: " <>
               "INPUT_REQUIRED then COMPLETED, the row holds both messages' fields"
           end)
         end},
        {"a client cancel mid-stream ends the session and leaves the task running",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             context = "ctx-live-cancel-" <> unique()
             sessions = fn -> DynamicSupervisor.count_children(LiveSessionSup).active end
             before = sessions.()
             stream = Stub.send_live_message(ch, opts)

             request =
               pb(
                 Pb.SendMessageRequest,
                 send_params("slow_count", %{"delay_ms" => 30_000}, %{}, context_id: context)
               )

             stream =
               GRPC.Stub.send_request(stream, %Pb.StreamRequest{payload: {:send_message, request}})

             working =
               await!("the task in #{context} to be working", 5_000, fn ->
                 listed =
                   ch
                   |> Stub.list_tasks(%Pb.ListTasksRequest{context_id: context}, opts)
                   |> grpc_ok!("ListTasks")

                 case listed["tasks"] do
                   [%{"status" => %{"state" => "TASK_STATE_WORKING"}} = task] -> task
                   _other -> nil
                 end
               end)

             check!(sessions.() == before + 1, "the open stream holds no live session")
             canceled = GRPC.Stub.cancel(stream)

             check!(
               match?(%{canceled: true}, canceled),
               "cancel answered #{clip(inspect(canceled))}"
             )

             await!("the live session to end after the client cancel", 5_000, fn ->
               sessions.() <= before
             end)

             # Canceling the RPC is not tasks/cancel: the work is still running.
             expect_state!(grpc_get!(ch, opts, working["id"]), "TASK_STATE_WORKING")

             stopped =
               ch
               |> Stub.cancel_task(%Pb.CancelTaskRequest{id: working["id"]}, opts)
               |> grpc_ok!("CancelTask")

             expect_state!(stopped, "TASK_STATE_CANCELED")

             "the RPC cancel ended the live session; task #{working["id"]} stayed " <>
               "TASK_STATE_WORKING until CancelTask"
           end)
         end},
        {"a bad request is a StreamError frame and the stream stays usable",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             stream = Stub.send_live_message(ch, opts)

             # No payload at all: a payload kind the server does not recognise.
             stream = GRPC.Stub.send_request(stream, %Pb.StreamRequest{})

             # A send that would create a task but carries no message.
             stream =
               GRPC.Stub.send_request(stream, %Pb.StreamRequest{
                 payload: {:send_message, %Pb.SendMessageRequest{}}
               })

             good = pb(Pb.SendMessageRequest, send_params("count_notes", %{}))

             stream =
               GRPC.Stub.send_request(
                 stream,
                 %Pb.StreamRequest{payload: {:send_message, good}},
                 end_stream: true
               )

             frames =
               stream |> GRPC.Stub.recv(timeout: 15_000) |> grpc_stream!("SendLiveMessage")

             kinds = Enum.map(frames, &frame_kind/1)
             codes = for %{"error" => error} <- frames, do: error["code"]

             check!(
               codes == ["UNIMPLEMENTED", "INVALID_ARGUMENT"],
               "StreamError codes were #{inspect(codes)} in #{inspect(kinds)}"
             )

             check!(
               Enum.take(kinds, 2) == ["error", "error"],
               "the rejections did not precede the accepted work: #{inspect(kinds)}"
             )

             states = frames |> Enum.map(&frame_state/1) |> Enum.reject(&is_nil/1)

             check!(
               List.last(states) == "TASK_STATE_COMPLETED",
               "after the rejections the stream ended in #{inspect(List.last(states))}"
             )

             "StreamError UNIMPLEMENTED and INVALID_ARGUMENT, then the same stream " <>
               "completed a task (#{length(frames)} frames)"
           end)
         end},
        {"opening on another caller's task is NOT_FOUND",
         fn info ->
           task = grpc(info, :writer, fn ch, opts -> grpc_parked!(ch, opts) end)

           grpc(info, :reader, fn ch, opts ->
             stream = Stub.send_live_message(ch, opts)

             stream =
               GRPC.Stub.send_request(
                 stream,
                 %Pb.StreamRequest{
                   payload: {:subscribe, %Pb.SubscribeToTaskRequest{id: task["id"]}}
                 },
                 end_stream: true
               )

             status =
               case GRPC.Stub.recv(stream, timeout: 15_000) do
                 {:error, _} = error ->
                   stream_error_status(error)

                 {:ok, replies} ->
                   replies |> Enum.take(1) |> List.first() |> stream_error_status()
               end

             check!(status == 5, "expected gRPC status 5, got #{clip(inspect(status))}")

             "the reader's subscribe to the writer's task ended gRPC status 5 NOT_FOUND"
           end)
         end}
      ]
    end

    defp grpc_scenarios("GetTask") do
      [
        {"returns the stored task",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task = grpc_send!(ch, opts, "count_notes", %{})
             got = grpc_get!(ch, opts, task["id"])
             check!(got["id"] == task["id"], "id mismatch")
             expect_state!(got, "TASK_STATE_COMPLETED")
             "task #{got["id"]} read back"
           end)
         end},
        {"unknown task is NOT_FOUND",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             ch
             |> Stub.get_task(%Pb.GetTaskRequest{id: "tsk-does-not-exist"}, opts)
             |> grpc_status!(5, "GetTask")

             "gRPC status 5 NOT_FOUND"
           end)
         end},
        {"another caller's task is NOT_FOUND",
         fn info ->
           task = grpc(info, :writer, fn ch, opts -> grpc_send!(ch, opts, "count_notes", %{}) end)

           grpc(info, :reader, fn ch, opts ->
             ch
             |> Stub.get_task(%Pb.GetTaskRequest{id: task["id"]}, opts)
             |> grpc_status!(5, "GetTask")

             "the reader gets NOT_FOUND for the writer's task"
           end)
         end}
      ]
    end

    defp grpc_scenarios("ListTasks") do
      [
        {"pages and filters by context and status",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             context = "ctx-grpc-" <> unique()

             ids =
               for _ <- 1..3,
                   do: grpc_send!(ch, opts, "count_notes", %{}, %{}, context_id: context)["id"]

             page1 =
               ch
               |> Stub.list_tasks(%Pb.ListTasksRequest{context_id: context, page_size: 2}, opts)
               |> grpc_ok!("ListTasks")

             check!(length(page1["tasks"]) == 2, "page 1 held #{length(page1["tasks"] || [])}")
             check!(page1["totalSize"] == 3, "totalSize was #{inspect(page1["totalSize"])}")

             page2 =
               ch
               |> Stub.list_tasks(
                 %Pb.ListTasksRequest{
                   context_id: context,
                   page_size: 2,
                   page_token: page1["nextPageToken"]
                 },
                 opts
               )
               |> grpc_ok!("ListTasks")

             listed = Enum.map(page1["tasks"] ++ page2["tasks"], & &1["id"])

             check!(
               Enum.sort(listed) == Enum.sort(ids),
               "pages did not cover the 3 tasks exactly once"
             )

             failed =
               ch
               |> Stub.list_tasks(
                 %Pb.ListTasksRequest{context_id: context, status: :TASK_STATE_FAILED},
                 opts
               )
               |> grpc_ok!("ListTasks")

             check!((failed["tasks"] || []) == [], "status filter FAILED matched tasks")
             "2 + 1 over two pages, totalSize 3, FAILED filter empty"
           end)
         end},
        {"invalid page token is INVALID_ARGUMENT",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             ch
             |> Stub.list_tasks(%Pb.ListTasksRequest{page_token: "not-a-token"}, opts)
             |> grpc_status!(3, "ListTasks")

             "gRPC status 3 INVALID_ARGUMENT"
           end)
         end}
      ]
    end

    defp grpc_scenarios("CancelTask") do
      [
        {"cancels a task that is still running",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task =
               grpc_send!(ch, opts, "slow_count", %{"delay_ms" => 30_000}, %{
                 "configuration" => %{"returnImmediately" => true}
               })

             canceled =
               ch
               |> Stub.cancel_task(%Pb.CancelTaskRequest{id: task["id"]}, opts)
               |> grpc_ok!("CancelTask")

             expect_state!(canceled, "TASK_STATE_CANCELED")
             expect_state!(grpc_get!(ch, opts, task["id"]), "TASK_STATE_CANCELED")
             "30 s task canceled in flight"
           end)
         end},
        {"a completed task is FAILED_PRECONDITION",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task = grpc_send!(ch, opts, "count_notes", %{})

             ch
             |> Stub.cancel_task(%Pb.CancelTaskRequest{id: task["id"]}, opts)
             |> grpc_status!(9, "CancelTask")

             "gRPC status 9 FAILED_PRECONDITION"
           end)
         end}
      ]
    end

    defp grpc_scenarios("SubscribeToTask") do
      [
        {"server stream follows a running task to its final state",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task =
               grpc_send!(ch, opts, "slow_count", %{"delay_ms" => 600}, %{
                 "configuration" => %{"returnImmediately" => true}
               })

             frames =
               ch
               |> Stub.subscribe_to_task(%Pb.SubscribeToTaskRequest{id: task["id"]}, opts)
               |> grpc_stream!("SubscribeToTask")

             states = frames |> Enum.map(&frame_state/1) |> Enum.reject(&is_nil/1)

             check!(
               List.last(states) == "TASK_STATE_COMPLETED",
               "stream ended in #{inspect(List.last(states))}"
             )

             "#{length(frames)} frames, states #{Enum.join(states, " -> ")}"
           end)
         end},
        {"unknown task is NOT_FOUND",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             result =
               Stub.subscribe_to_task(
                 ch,
                 %Pb.SubscribeToTaskRequest{id: "tsk-does-not-exist"},
                 opts
               )

             status =
               case result do
                 {:error, %GRPC.RPCError{status: status}} ->
                   status

                 {:ok, replies} ->
                   replies |> Enum.take(1) |> List.first() |> stream_error_status()
               end

             check!(status == 5, "expected gRPC status 5, got #{inspect(status)}")
             "gRPC status 5 NOT_FOUND"
           end)
         end}
      ]
    end

    defp grpc_scenarios("CreateTaskPushNotificationConfig") do
      [
        {"stores a config and a real webhook delivery follows",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task = grpc_parked!(ch, opts)
             suffix = "/grpc-" <> unique()
             token = "tok-" <> unique()
             config = grpc_push_set!(ch, opts, task["id"], info.push_url <> suffix, token)

             check!(
               config["url"] == info.push_url <> suffix,
               "stored url #{inspect(config["url"])}"
             )

             check!(config["taskId"] == task["id"], "stored taskId #{inspect(config["taskId"])}")

             # The continuation goes through an HTTP mount: the config store is
             # shared, so the gRPC-created config must fire.
             c = caller(info, :a2a, nil, nil)

             done =
               jr_send!(c, "create_note", %{"title" => "grpc-pushed-" <> unique()}, %{},
                 task_id: task["id"]
               )

             expect_state!(done, "TASK_STATE_COMPLETED")
             delivery = await_delivery!(suffix)

             check!(
               delivery.headers["x-a2a-notification-token"] == token,
               "delivery token mismatch"
             )

             "config #{config["id"]} stored over gRPC; webhook POST #{delivery.path} received"
           end)
         end},
        {"unknown task is NOT_FOUND",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             ch
             |> Stub.create_task_push_notification_config(
               %Pb.TaskPushNotificationConfig{task_id: "tsk-does-not-exist", url: info.push_url},
               opts
             )
             |> grpc_status!(5, "CreateTaskPushNotificationConfig")

             "gRPC status 5 NOT_FOUND"
           end)
         end}
      ]
    end

    defp grpc_scenarios("GetTaskPushNotificationConfig") do
      [
        {"reads back the config that was asked for",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task = grpc_parked!(ch, opts)

             _one =
               grpc_push_set!(ch, opts, task["id"], info.push_url <> "/gg1-" <> unique(), "a")

             two = grpc_push_set!(ch, opts, task["id"], info.push_url <> "/gg2-" <> unique(), "b")

             got =
               ch
               |> Stub.get_task_push_notification_config(
                 %Pb.GetTaskPushNotificationConfigRequest{task_id: task["id"], id: two["id"]},
                 opts
               )
               |> grpc_ok!("GetTaskPushNotificationConfig")

             check!(
               got["id"] == two["id"] and got["url"] == two["url"],
               "got #{clip(inspect(got))}"
             )

             "config #{two["id"]} of 2 read back"
           end)
         end}
      ]
    end

    defp grpc_scenarios("ListTaskPushNotificationConfigs") do
      [
        {"lists every config of a task",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task = grpc_parked!(ch, opts)
             one = grpc_push_set!(ch, opts, task["id"], info.push_url <> "/gl1-" <> unique(), "a")
             two = grpc_push_set!(ch, opts, task["id"], info.push_url <> "/gl2-" <> unique(), "b")

             listed =
               ch
               |> Stub.list_task_push_notification_configs(
                 %Pb.ListTaskPushNotificationConfigsRequest{task_id: task["id"]},
                 opts
               )
               |> grpc_ok!("ListTaskPushNotificationConfigs")

             ids = (listed["configs"] || []) |> Enum.map(& &1["id"]) |> Enum.sort()
             check!(ids == Enum.sort([one["id"], two["id"]]), "listed #{inspect(ids)}")
             "2 configs listed"
           end)
         end}
      ]
    end

    defp grpc_scenarios("DeleteTaskPushNotificationConfig") do
      [
        {"removes one config and leaves the other",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             task = grpc_parked!(ch, opts)
             one = grpc_push_set!(ch, opts, task["id"], info.push_url <> "/gd1-" <> unique(), "a")
             two = grpc_push_set!(ch, opts, task["id"], info.push_url <> "/gd2-" <> unique(), "b")

             ch
             |> Stub.delete_task_push_notification_config(
               %Pb.DeleteTaskPushNotificationConfigRequest{task_id: task["id"], id: one["id"]},
               opts
             )
             |> grpc_ok!("DeleteTaskPushNotificationConfig")

             listed =
               ch
               |> Stub.list_task_push_notification_configs(
                 %Pb.ListTaskPushNotificationConfigsRequest{task_id: task["id"]},
                 opts
               )
               |> grpc_ok!("ListTaskPushNotificationConfigs")

             left = Enum.map(listed["configs"] || [], & &1["id"])
             check!(left == [two["id"]], "after delete the task holds #{inspect(left)}")
             "config #{one["id"]} gone, #{two["id"]} kept"
           end)
         end}
      ]
    end

    defp grpc_scenarios("GetExtendedAgentCard") do
      [
        {"an authenticated caller gets the extended card",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             card =
               ch
               |> Stub.get_extended_agent_card(%Pb.GetExtendedAgentCardRequest{}, opts)
               |> grpc_ok!("GetExtendedAgentCard")

             ids = Enum.map(card["skills"] || [], & &1["id"])

             check!(
               "AshA2A.Sim.extended_only" in ids,
               "extended skill missing from #{inspect(ids)}"
             )

             urls = Enum.map(card["supportedInterfaces"] || [], & &1["url"])

             check!(
               info.grpc_target in urls,
               "card interfaces #{inspect(urls)} do not name the gRPC endpoint"
             )

             "#{length(ids)} skills; the card names the gRPC endpoint #{info.grpc_target}"
           end)
         end},
        {"the extended card's signature verifies, and a changed byte is refused",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             card =
               ch
               |> Stub.get_extended_agent_card(%Pb.GetExtendedAgentCardRequest{}, opts)
               |> grpc_ok!("GetExtendedAgentCard")

             # The ProtoJSON form of the protobuf message that was received.
             extended_signature!(info, card)
           end)
         end}
      ]
    end

    defp grpc_scenarios(_rpc), do: []

    defp stream_error_status({:error, %GRPC.RPCError{status: status}}), do: status
    defp stream_error_status(other), do: other

    # == skills: mutations checked against the data layer =======================

    defp skill_scenarios("AshA2A.Sim.Note.create") do
      [
        {"create over JSON-RPC writes the row",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           title = "create-" <> unique()
           task = jr_send!(c, "create_note", %{"title" => title, "body" => "first"})
           expect_state!(task, "TASK_STATE_COMPLETED")
           wire_id = artifact_data(task)["id"]
           note = Ash.get!(Note, wire_id, authorize?: false)

           check!(
             note.title == title and note.body == "first",
             "row is #{inspect({note.title, note.body})}"
           )

           "row #{note.id} read back through Ash with the sent title and body"
         end},
        {"create over HTTP+JSON writes the row",
         fn info ->
           title = "create-rest-" <> unique()
           task = rest_send!(info, "create_note", %{"title" => title})
           expect_state!(task, "TASK_STATE_COMPLETED")
           check!(note_by_title(title) != nil, "no row titled #{title}")
           "row #{note_by_title(title).id} exists"
         end},
        {"create without authority is refused and writes nothing",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           title = "create-refused-" <> unique()
           before = note_count()
           task = jr_send!(c, "create_note", %{"title" => title}, %{}, token: :reader)
           expect_state!(task, "TASK_STATE_REJECTED")

           check!(
             Jason.encode!(task) =~ "authority_required",
             "refusal does not name authority: #{clip(inspect(task["status"]))}"
           )

           check!(note_by_title(title) == nil, "the refused create wrote a row")
           check!(note_count() == before, "row count changed from #{before} to #{note_count()}")
           "refused authority_required; row count stays #{before}"
         end},
        {"create over HTTP+JSON without authority writes nothing",
         fn info ->
           title = "create-rest-refused-" <> unique()
           before = note_count()
           task = rest_send!(info, "create_note", %{"title" => title}, %{}, token: :reader)
           expect_state!(task, "TASK_STATE_REJECTED")

           check!(
             note_by_title(title) == nil and note_count() == before,
             "the refused create changed the table"
           )

           "refused; row count stays #{before}"
         end},
        {"create selected by capability id writes the row",
         fn info ->
           c = caller(info, :a2a, nil, nil)
           title = "create-by-id-" <> unique()
           task = jr_send!(c, "AshA2A.Sim.Note.create", %{"title" => title})
           expect_state!(task, "TASK_STATE_COMPLETED")
           check!(note_by_title(title) != nil, "no row titled #{title}")
           "skill metadata \"AshA2A.Sim.Note.create\" created row #{note_by_title(title).id}"
         end}
      ]
    end

    defp skill_scenarios("AshA2A.Sim.Note.update") do
      [
        {"update over JSON-RPC changes the row",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           note = seed_row!(info, "update", "old body")
           task = jr_send!(c, "update_note", %{"id" => note.id, "body" => "new body"})
           expect_state!(task, "TASK_STATE_COMPLETED")
           after_update = Ash.get!(Note, note.id, authorize?: false)
           check!(after_update.body == "new body", "row body is #{inspect(after_update.body)}")
           check!(after_update.title == note.title, "the title changed too")
           "row #{note.id}: body \"old body\" -> \"new body\", title untouched"
         end},
        {"update over HTTP+JSON changes the row",
         fn info ->
           note = seed_row!(info, "update-rest", "old")

           task =
             rest_send!(info, "update_note", %{
               "id" => note.id,
               "title" => note.title <> "-renamed"
             })

           expect_state!(task, "TASK_STATE_COMPLETED")

           check!(
             Ash.get!(Note, note.id, authorize?: false).title == note.title <> "-renamed",
             "title not changed"
           )

           "row #{note.id} renamed"
         end},
        {"update without authority is refused and the row is unchanged",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           note = seed_row!(info, "update-refused", "keep me")

           task =
             jr_send!(c, "update_note", %{"id" => note.id, "body" => "overwritten"}, %{},
               token: :reader
             )

           expect_state!(task, "TASK_STATE_REJECTED")
           same = Ash.get!(Note, note.id, authorize?: false)

           check!(
             same.body == "keep me",
             "the refused update changed the body to #{inspect(same.body)}"
           )

           check!(same.updated_at == note.updated_at, "updated_at moved")
           "refused; row #{note.id} still has body \"keep me\""
         end},
        {"update of a missing row fails and writes nothing",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           before = note_count()
           task = jr_send!(c, "update_note", %{"id" => Ash.UUID.generate(), "body" => "x"})
           expect_state!(task, "TASK_STATE_FAILED")
           check!(note_count() == before, "row count changed")
           "TASK_STATE_FAILED not_found; row count stays #{before}"
         end}
      ]
    end

    defp skill_scenarios("AshA2A.Sim.Note.destroy") do
      [
        {"destroy over JSON-RPC removes the row",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           note = seed_row!(info, "destroy", nil)
           task = jr_send!(c, "delete_note", %{"id" => note.id})
           expect_state!(task, "TASK_STATE_COMPLETED")

           check!(
             match?({:error, _}, Ash.get(Note, note.id, authorize?: false)),
             "row #{note.id} still exists"
           )

           "row #{note.id} is gone from the data layer"
         end},
        {"destroy over HTTP+JSON removes the row",
         fn info ->
           note = seed_row!(info, "destroy-rest", nil)
           task = rest_send!(info, "delete_note", %{"id" => note.id})
           expect_state!(task, "TASK_STATE_COMPLETED")

           check!(
             match?({:error, _}, Ash.get(Note, note.id, authorize?: false)),
             "row still exists"
           )

           "row #{note.id} is gone"
         end},
        {"destroy over gRPC removes the row",
         fn info ->
           grpc(info, :writer, fn ch, opts ->
             note = seed_row!(info, "destroy-grpc", nil)
             task = grpc_send!(ch, opts, "delete_note", %{"id" => note.id})
             expect_state!(task, "TASK_STATE_COMPLETED")

             check!(
               match?({:error, _}, Ash.get(Note, note.id, authorize?: false)),
               "row still exists"
             )

             "row #{note.id} is gone"
           end)
         end},
        {"destroy without authority is refused and the row stays",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           note = seed_row!(info, "destroy-refused", nil)
           task = jr_send!(c, "delete_note", %{"id" => note.id}, %{}, token: :reader)
           expect_state!(task, "TASK_STATE_REJECTED")

           check!(
             match?({:ok, _}, Ash.get(Note, note.id, authorize?: false)),
             "the refused destroy removed the row"
           )

           "refused; row #{note.id} still exists"
         end}
      ]
    end

    defp skill_scenarios("AshA2A.Sim.Note.read") do
      [
        {"read returns what the data layer holds",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           note = seed_row!(info, "read", "visible")
           task = jr_send!(c, "list_notes", %{}, %{}, token: :reader)
           expect_state!(task, "TASK_STATE_COMPLETED")
           rows = artifact_data(task)["results"] || []

           check!(
             Enum.any?(rows, &(&1["id"] == note.id and &1["title"] == note.title)),
             "seeded row missing from the wire result"
           )

           check!(
             length(rows) == note_count(),
             "wire returned #{length(rows)} rows, the table holds #{note_count()}"
           )

           "#{length(rows)} rows on the wire, the same as the table"
         end}
      ]
    end

    defp skill_scenarios("AshA2A.Sim.Note.count_notes") do
      [
        {"count matches the data layer",
         fn info ->
           c = caller(info, :a2a, nil, nil)
           seed_row!(info, "count", nil)
           task = jr_send!(c, "count_notes", %{})
           expect_state!(task, "TASK_STATE_COMPLETED")
           wire = artifact_data(task)["count"]

           check!(
             wire == note_count(),
             "wire count #{inspect(wire)}, table holds #{note_count()}"
           )

           "count #{wire} on the wire and in the table"
         end}
      ]
    end

    defp skill_scenarios("AshA2A.Sim.Note.ping") do
      message_only! = fn binding, reply, echo ->
        check!(
          match?(%{"message" => %{"role" => "ROLE_AGENT"}}, reply) and map_size(reply) == 1,
          "#{binding} answered #{clip(inspect(reply), 200)}, not a bare Message"
        )

        check!(
          Jason.encode!(reply) =~ echo,
          "the Message over #{binding} does not carry the result: #{clip(inspect(reply), 200)}"
        )
      end

      no_task! = fn info, context ->
        listed =
          jr_result!(caller(info, :jsonrpc, nil, nil), "tasks/list", %{"contextId" => context})

        check!(
          listed["tasks"] == [],
          "a message-only send stored #{length(listed["tasks"])} task(s) in #{context}"
        )
      end

      [
        {"message/send answers a bare Message on every binding and stores no task",
         fn info ->
           context = "ctx-ping-" <> unique()
           echo = "echo-" <> unique()
           data = %{"echo" => echo}

           over_jsonrpc =
             jr_result!(
               caller(info, :jsonrpc, nil, nil),
               "message/send",
               send_params("ping", data, %{}, context_id: context)
             )

           over_a2a =
             jr_result!(
               caller(info, :a2a, nil, nil),
               "message/send",
               send_params("ping", data, %{}, context_id: context)
             )

           over_rest =
             rest_ok!(info, :post, "/message:send",
               json: send_params("ping", data, %{}, context_id: context)
             )

           over_grpc =
             grpc(info, :writer, fn ch, opts ->
               request =
                 pb(Pb.SendMessageRequest, send_params("ping", data, %{}, context_id: context))

               ch |> Stub.send_message(request, opts) |> grpc_ok!("SendMessage")
             end)

           for {binding, reply} <- [
                 {"JSON-RPC /jsonrpc", over_jsonrpc},
                 {"JSON-RPC /a2a", over_a2a},
                 {"HTTP+JSON", over_rest},
                 {"gRPC", over_grpc}
               ],
               do: message_only!.(binding, reply, echo)

           no_task!.(info, context)
           "a bare Message on JSON-RPC (both mounts), HTTP+JSON and gRPC; no task in #{context}"
         end},
        {"a stream is exactly one Message frame on every binding and stores no task",
         fn info ->
           context = "ctx-ping-stream-" <> unique()
           echo = "echo-" <> unique()
           params = fn -> send_params("ping", %{"echo" => echo}, %{}, context_id: context) end

           rpc = fn c ->
             body = %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "message/stream",
               "params" => params.()
             }

             timed_sse!(info, c.url, body, fn
               %{"result" => result} -> result
               other -> fail!("SSE frame is not a JSON-RPC result: #{clip(inspect(other))}")
             end)
           end

           grpc_frames =
             grpc(info, :writer, fn ch, opts ->
               ch
               |> Stub.send_streaming_message(pb(Pb.SendMessageRequest, params.()), opts)
               |> grpc_stream!("SendStreamingMessage")
             end)

           streams = [
             {"JSON-RPC /jsonrpc",
              Enum.map(rpc.(caller(info, :jsonrpc, nil, nil)), &elem(&1, 1))},
             {"JSON-RPC /a2a", Enum.map(rpc.(caller(info, :a2a, nil, nil)), &elem(&1, 1))},
             {"HTTP+JSON",
              info
              |> timed_sse!(info.rest_url <> "/message:stream", params.(), & &1)
              |> Enum.map(&elem(&1, 1))},
             {"gRPC", grpc_frames}
           ]

           for {binding, frames} <- streams do
             check!(
               length(frames) == 1,
               "#{binding} streamed #{length(frames)} frames: #{inspect(Enum.map(frames, &frame_kind/1))}"
             )

             message_only!.(binding, hd(frames), echo)
           end

           no_task!.(info, context)
           "one Message frame, then the stream closed, on all four mounts; no task in #{context}"
         end}
      ]
    end

    defp skill_scenarios("AshA2A.Sim.Note.slow_count") do
      [
        {"answers after the requested delay",
         fn info ->
           c = caller(info, :a2a, nil, nil)
           started = System.monotonic_time(:millisecond)
           task = jr_send!(c, "slow_count", %{"delay_ms" => 300})
           elapsed = System.monotonic_time(:millisecond) - started
           expect_state!(task, "TASK_STATE_COMPLETED")
           check!(elapsed >= 300, "answered after #{elapsed} ms, before the 300 ms delay")
           "completed after #{elapsed} ms"
         end},
        {"an out-of-range argument does not run the action",
         fn info ->
           c = caller(info, :a2a, nil, nil)
           task = jr_send!(c, "slow_count", %{"delay_ms" => 600_000})
           check!(state(task) != "TASK_STATE_COMPLETED", "a 10 minute delay was accepted")
           "delay_ms above the constraint answered #{state(task)}"
         end}
      ]
    end

    defp skill_scenarios("AshA2A.Sim.Note.step_up") do
      [
        {"parks at auth-required, then completes when the code is sent",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           task = jr_send!(c, "step_up", %{})
           expect_state!(task, "TASK_STATE_AUTH_REQUIRED")
           done = jr_send!(c, "step_up", %{"otp" => "123456"}, %{}, task_id: task["id"])
           expect_state!(done, "TASK_STATE_COMPLETED")
           check!(done["id"] == task["id"], "the continuation made a new task")
           "task #{task["id"]}: AUTH_REQUIRED -> COMPLETED"
         end}
      ]
    end

    defp skill_scenarios("AshA2A.Sim.Note.publish_note") do
      [
        {"publish records the effect outside the data layer",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           title = "publish-" <> unique()
           before = note_count()
           task = jr_send!(c, "publish_note", %{"title" => title})
           expect_state!(task, "TASK_STATE_COMPLETED")
           check!(title in Note.publications(), "publication #{title} was not recorded")
           check!(note_count() == before, "publish changed the note table")
           "publication recorded; note table untouched"
         end},
        {"publish without authority is refused and records nothing",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           title = "publish-refused-" <> unique()
           task = jr_send!(c, "publish_note", %{"title" => title}, %{}, token: :reader)
           expect_state!(task, "TASK_STATE_REJECTED")
           check!(title not in Note.publications(), "the refused publish was recorded")
           "refused; nothing recorded"
         end}
      ]
    end

    defp skill_scenarios("AshA2A.Sim.Note.unclassified_note") do
      [
        {"an unclassified action is rejected even with a grant-holding caller",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           task = jr_send!(c, "unclassified_note", %{})
           expect_state!(task, "TASK_STATE_REJECTED")

           check!(
             Jason.encode!(task) =~ "consequence_unclassified",
             "refusal does not name the reason"
           )

           check!(not artifacts?(task), "the action ran and produced an artifact")
           "TASK_STATE_REJECTED consequence_unclassified, no artifact"
         end}
      ]
    end

    defp skill_scenarios("AshA2A.Sim.Note.bad_reply") do
      [
        {"a reply that is not an A2A value is -32006 INTERNAL on every binding",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           params = send_params("bad_reply", %{})
           error = jr_error!(c, "message/send", params, -32_006)

           check!(
             Jason.encode!(error) =~ "INVALID_AGENT_RESPONSE",
             "-32006 carries no INVALID_AGENT_RESPONSE ErrorInfo: #{clip(inspect(error))}"
           )

           a2a_error = jr_error!(caller(info, :a2a, nil, nil), "message/send", params, -32_006)

           check!(
             Jason.encode!(a2a_error) =~ "INVALID_AGENT_RESPONSE",
             "the /a2a mount's -32006 carries no ErrorInfo: #{clip(inspect(a2a_error))}"
           )

           resp = rest_error!(info, :post, "/message:send", 500, json: params)

           check!(
             resp.raw =~ "INVALID_AGENT_RESPONSE",
             "HTTP 500 carries no INVALID_AGENT_RESPONSE reason: #{clip(resp.raw)}"
           )

           grpc(info, :writer, fn ch, opts ->
             ch
             |> Stub.send_message(pb(Pb.SendMessageRequest, params), opts)
             |> grpc_status!(13, "SendMessage")
           end)

           "-32006 over JSON-RPC, HTTP 500 over HTTP+JSON, gRPC INTERNAL(13)"
         end}
      ]
    end

    defp skill_scenarios(_id), do: []

    # == consequence classes ====================================================

    defp consequence_scenarios("observe") do
      [
        {"runs for an authenticated caller with no grant",
         fn info ->
           task = rest_send!(info, "count_notes", %{}, %{}, token: :reader)
           expect_state!(task, "TASK_STATE_COMPLETED")
           "the reader (no grants) ran count_notes over HTTP+JSON"
         end}
      ]
    end

    defp consequence_scenarios("change") do
      [
        {"admitted with a grant, refused without, over gRPC",
         fn info ->
           title = "class-change-" <> unique()

           refused =
             grpc(info, :reader, fn ch, opts ->
               grpc_send!(ch, opts, "create_note", %{"title" => title})
             end)

           expect_state!(refused, "TASK_STATE_REJECTED")
           check!(note_by_title(title) == nil, "the ungranted caller created the row")

           admitted =
             grpc(info, :writer, fn ch, opts ->
               grpc_send!(ch, opts, "create_note", %{"title" => title})
             end)

           expect_state!(admitted, "TASK_STATE_COMPLETED")
           check!(note_by_title(title) != nil, "the granted caller's row is missing")
           "reader refused with no row; writer admitted and the row exists"
         end}
      ]
    end

    defp consequence_scenarios("external_do") do
      [
        {"admitted with a grant, refused without, over HTTP+JSON",
         fn info ->
           title = "class-external-" <> unique()
           refused = rest_send!(info, "publish_note", %{"title" => title}, %{}, token: :reader)
           expect_state!(refused, "TASK_STATE_REJECTED")
           check!(title not in Note.publications(), "the ungranted caller's effect happened")
           admitted = rest_send!(info, "publish_note", %{"title" => title})
           expect_state!(admitted, "TASK_STATE_COMPLETED")
           check!(title in Note.publications(), "the granted caller's effect is missing")
           "reader refused with no effect; writer admitted and the effect is recorded"
         end}
      ]
    end

    defp consequence_scenarios("unknown") do
      [
        {"never runs, on any binding",
         fn info ->
           over_rest = rest_send!(info, "unclassified_note", %{})

           over_grpc =
             grpc(info, :writer, fn ch, opts -> grpc_send!(ch, opts, "unclassified_note", %{}) end)

           expect_state!(over_rest, "TASK_STATE_REJECTED")
           expect_state!(over_grpc, "TASK_STATE_REJECTED")
           check!(not artifacts?(over_rest) and not artifacts?(over_grpc), "the action ran")
           "TASK_STATE_REJECTED over HTTP+JSON and gRPC"
         end}
      ]
    end

    defp consequence_scenarios(_class), do: []

    # == task states =============================================================

    defp task_state_scenarios("TASK_STATE_SUBMITTED") do
      [
        {"a non-blocking send answers the submitted task",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)

           task =
             jr_send!(c, "slow_count", %{"delay_ms" => 500}, %{
               "configuration" => %{"returnImmediately" => true}
             })

           expect_state!(task, "TASK_STATE_SUBMITTED")
           jr_await!(c, task["id"], "TASK_STATE_COMPLETED")
           "message/send returned TASK_STATE_SUBMITTED"
         end}
      ]
    end

    defp task_state_scenarios("TASK_STATE_WORKING") do
      [
        {"a task is working while a blocking send is in flight",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           context = "ctx-working-" <> unique()

           blocking =
             Task.async(fn ->
               jr_send!(c, "slow_count", %{"delay_ms" => 1_200}, %{}, context_id: context)
             end)

           working =
             await!("a working task in #{context}", 1_100, fn ->
               case jr_result!(c, "tasks/list", %{"contextId" => context})["tasks"] do
                 [%{"status" => %{"state" => "TASK_STATE_WORKING"}} = task] -> task
                 _other -> nil
               end
             end)

           done = Task.await(blocking, 10_000)
           check!(done["id"] == working["id"], "the listed task is not the one in flight")
           expect_state!(done, "TASK_STATE_COMPLETED")
           "tasks/list saw TASK_STATE_WORKING while the send was blocked; it then completed"
         end}
      ]
    end

    defp task_state_scenarios("TASK_STATE_COMPLETED") do
      [
        {"an observe skill completes",
         fn info ->
           task = jr_send!(caller(info, :jsonrpc, nil, nil), "count_notes", %{})
           expect_state!(task, "TASK_STATE_COMPLETED")
           "count_notes ended TASK_STATE_COMPLETED"
         end}
      ]
    end

    defp task_state_scenarios("TASK_STATE_FAILED") do
      [
        {"an action error fails the task",
         fn info ->
           task =
             jr_send!(caller(info, :jsonrpc, nil, nil), "update_note", %{
               "id" => Ash.UUID.generate(),
               "body" => "x"
             })

           expect_state!(task, "TASK_STATE_FAILED")

           check!(
             Jason.encode!(task["status"]) =~ "not_found",
             "status does not say why: #{clip(inspect(task["status"]))}"
           )

           "update of a missing row ended TASK_STATE_FAILED (not_found)"
         end}
      ]
    end

    defp task_state_scenarios("TASK_STATE_CANCELED") do
      [
        {"a canceled running task stays canceled",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)

           task =
             jr_send!(c, "slow_count", %{"delay_ms" => 1_000}, %{
               "configuration" => %{"returnImmediately" => true}
             })

           jr_result!(c, "tasks/cancel", %{"id" => task["id"]})
           Process.sleep(1_200)
           after_delay = jr_get!(c, task["id"])
           expect_state!(after_delay, "TASK_STATE_CANCELED")
           check!(not artifacts?(after_delay), "the canceled action still delivered an artifact")
           "still TASK_STATE_CANCELED after the action's delay passed, no late artifact"
         end}
      ]
    end

    defp task_state_scenarios("TASK_STATE_INPUT_REQUIRED") do
      [
        {"parks for missing input, then the continuation writes the row",
         fn info ->
           c = caller(info, :jsonrpc, nil, nil)
           before = note_count()
           task = jr_send!(c, "create_note", %{"body" => "kept from turn one"})
           expect_state!(task, "TASK_STATE_INPUT_REQUIRED")
           check!(note_count() == before, "the incomplete create wrote a row")
           title = "continued-" <> unique()
           done = jr_send!(c, "create_note", %{"title" => title}, %{}, task_id: task["id"])
           expect_state!(done, "TASK_STATE_COMPLETED")
           note = note_by_title(title)
           check!(note != nil, "no row after the continuation")

           check!(
             note.body == "kept from turn one",
             "the first turn's body was lost: #{inspect(note.body)}"
           )

           "INPUT_REQUIRED with no row, then COMPLETED with the row holding both turns' fields"
         end},
        {"the input-required message carries no stack trace",
         fn info ->
           task = jr_send!(caller(info, :jsonrpc, nil, nil), "create_note", %{})
           expect_state!(task, "TASK_STATE_INPUT_REQUIRED")
           text = Jason.encode!(task["status"])
           check!(text =~ "title", "the message does not name the missing field: #{clip(text)}")

           check!(
             not (text =~ ~r/\.ex:\d+/),
             "the wire message carries source locations: #{clip(text, 300)}"
           )

           "names the missing field, no source locations"
         end}
      ]
    end

    defp task_state_scenarios("TASK_STATE_REJECTED") do
      [
        {"an admission refusal rejects the task",
         fn info ->
           task = jr_send!(caller(info, :a2a, nil, nil), "unclassified_note", %{})
           expect_state!(task, "TASK_STATE_REJECTED")
           "unclassified_note ended TASK_STATE_REJECTED"
         end},
        {"an unknown skill is rejected on every binding, without running anything",
         fn info ->
           before = note_count()
           data = %{"title" => "unknown-skill-" <> unique()}

           tasks = [
             {"JSON-RPC", jr_send!(caller(info, :jsonrpc, nil, nil), "no_such_skill", data)},
             {"HTTP+JSON", rest_send!(info, "no_such_skill", data)},
             {"gRPC",
              grpc(info, :writer, fn ch, opts -> grpc_send!(ch, opts, "no_such_skill", data) end)}
           ]

           for {binding, task} <- tasks do
             check!(
               state(task) == "TASK_STATE_REJECTED",
               "an unknown skill ended #{state(task)} over #{binding}: #{clip(inspect(task["status"]))}"
             )

             check!(not artifacts?(task), "an unknown skill produced an artifact over #{binding}")
           end

           check!(note_count() == before, "an unknown skill changed the table")
           "skill \"no_such_skill\" ended TASK_STATE_REJECTED over JSON-RPC, HTTP+JSON and gRPC"
         end},
        {"an authority refusal is rejected on every binding, and the stored task agrees",
         fn info ->
           before = note_count()
           c = caller(info, :jsonrpc, nil, nil)
           title = fn -> "rejected-" <> unique() end

           over_jsonrpc =
             jr_send!(c, "create_note", %{"title" => title.()}, %{}, token: :reader)

           over_rest =
             rest_send!(info, "create_note", %{"title" => title.()}, %{}, token: :reader)

           {over_grpc, stored_grpc} =
             grpc(info, :reader, fn ch, opts ->
               task = grpc_send!(ch, opts, "create_note", %{"title" => title.()})
               {task, grpc_get!(ch, opts, task["id"])}
             end)

           stored_jsonrpc = jr_get!(c, over_jsonrpc["id"], token: :reader)

           stored_rest =
             info
             |> rest_ok!(:get, "/tasks/#{over_rest["id"]}", token: :reader)
             |> task_of!()

           for {binding, task} <- [
                 {"JSON-RPC send", over_jsonrpc},
                 {"JSON-RPC get", stored_jsonrpc},
                 {"HTTP+JSON send", over_rest},
                 {"HTTP+JSON get", stored_rest},
                 {"gRPC send", over_grpc},
                 {"gRPC get", stored_grpc}
               ] do
             check!(
               state(task) == "TASK_STATE_REJECTED",
               "an authority refusal ended #{state(task)} over #{binding}"
             )

             check!(
               Jason.encode!(task) =~ "authority_required",
               "the refusal over #{binding} does not name authority"
             )
           end

           check!(note_count() == before, "a refused create changed the table")
           "authority_required ended TASK_STATE_REJECTED over JSON-RPC, HTTP+JSON and gRPC"
         end}
      ]
    end

    defp task_state_scenarios("TASK_STATE_AUTH_REQUIRED") do
      [
        {"parks for a credential and can be canceled",
         fn info ->
           c = caller(info, :a2a, nil, nil)
           task = jr_send!(c, "step_up", %{})
           expect_state!(task, "TASK_STATE_AUTH_REQUIRED")
           expect_state!(jr_get!(c, task["id"]), "TASK_STATE_AUTH_REQUIRED")
           canceled = c |> jr_result!("tasks/cancel", %{"id" => task["id"]}) |> task_of!()
           expect_state!(canceled, "TASK_STATE_CANCELED")
           "step_up parked at TASK_STATE_AUTH_REQUIRED, then canceled"
         end}
      ]
    end

    defp task_state_scenarios(_state), do: []

    # == security ================================================================

    defp security_scenarios("bearer_auth") do
      http_mounts = [{"/jsonrpc", :jsonrpc_url}, {"/a2a", :a2a_url}]

      unauthenticated =
        for {label, key} <- http_mounts do
          {"no credential is 401 (#{label})",
           fn info ->
             before = note_count()
             title = "unauth-" <> unique()

             resp =
               http(info, :post, Map.fetch!(info, key),
                 token: :none,
                 json: rpc_body("message/send", send_params("create_note", %{"title" => title}))
               )

             check!(resp.status == 401, "HTTP #{resp.status}: #{clip(resp.raw)}")
             check!(resp.headers["www-authenticate"] =~ "Bearer", "no Bearer challenge")

             check!(
               note_count() == before and note_by_title(title) == nil,
               "the unauthenticated call wrote a row"
             )

             "HTTP 401 with a Bearer challenge; no row written"
           end}
        end

      unauthenticated ++
        [
          {"no credential is 401 (/rest)",
           fn info ->
             resp =
               rest_error!(info, :post, "/message:send", 401,
                 token: :none,
                 json: send_params("count_notes", %{})
               )

             check!(resp.headers["www-authenticate"] =~ "Bearer", "no Bearer challenge")
             "HTTP 401 with a Bearer challenge"
           end},
          {"no credential is UNAUTHENTICATED (gRPC)",
           fn info ->
             grpc(info, :none, fn ch, opts ->
               request = pb(Pb.SendMessageRequest, send_params("count_notes", %{}))
               ch |> Stub.send_message(request, opts) |> grpc_status!(16, "SendMessage")
               "gRPC status 16 UNAUTHENTICATED"
             end)
           end},
          {"an unknown token is 401",
           fn info ->
             resp =
               http(info, :post, info.jsonrpc_url,
                 token: {:raw, "not-a-real-token"},
                 json: rpc_body("message/send", send_params("count_notes", %{}))
               )

             check!(resp.status == 401, "HTTP #{resp.status}")
             "HTTP 401"
           end},
          {"a token without the required scope is 403",
           fn info ->
             resp =
               http(info, :post, info.a2a_url,
                 token: :unscoped,
                 json: rpc_body("message/send", send_params("count_notes", %{}))
               )

             check!(resp.status == 403, "HTTP #{resp.status}: #{clip(resp.raw)}")
             check!(resp.raw =~ "insufficient_scope", "body does not name the scope shortfall")
             "HTTP 403 insufficient_scope"
           end},
          {"a token without the required scope is refused (gRPC)",
           fn info ->
             grpc(info, :unscoped, fn ch, opts ->
               request = pb(Pb.SendMessageRequest, send_params("count_notes", %{}))

               case Stub.send_message(ch, request, opts) do
                 {:error, %GRPC.RPCError{status: status}} when status in [7, 16] ->
                   "gRPC status #{status} #{AshA2A.Transport.Grpc.Dispatch.status_name(status)}"

                 other ->
                   fail!("an under-scoped gRPC call answered #{clip(inspect(other))}")
               end
             end)
           end},
          {"the card declares the scheme and its requirement",
           fn info ->
             card = http(info, :get, info.card_url, token: :none).json

             check!(
               Map.has_key?(card["securitySchemes"] || %{}, "bearer_auth"),
               "card has no bearer_auth scheme"
             )

             check!(
               Jason.encode!(card["securityRequirements"] || card["security"]) =~ "a2a:invoke",
               "card does not state the required scope"
             )

             "securitySchemes.bearer_auth and the a2a:invoke requirement are on the card"
           end},
          {"the verified identity is never echoed on the wire",
           fn info ->
             c = caller(info, :jsonrpc, nil, nil)

             task =
               jr_send!(c, "slow_count", %{"delay_ms" => 300}, %{
                 "configuration" => %{"returnImmediately" => true}
               })

             bodies = [
               jr(c, "tasks/get", %{"id" => task["id"]}, leak_check: false).raw,
               jr(c, "tasks/resubscribe", %{"id" => task["id"]},
                 leak_check: false,
                 receive_timeout: 15_000
               ).raw,
               jr(c, "tasks/list", %{}, leak_check: false).raw
             ]

             leaked = for body <- bodies, marker <- leak_markers(info), body =~ marker, do: marker
             check!(leaked == [], "wire bodies carry #{inspect(Enum.uniq(leaked))}")
             "tasks/get, tasks/resubscribe and tasks/list carry no identity, owner key or token"
           end}
        ]
    end

    defp security_scenarios(_scheme), do: []

    # == mounts ==================================================================

    defp mount_scenarios("grpc") do
      [
        {"the advertised gRPC interface answers an RPC",
         fn info ->
           card = http(info, :get, info.card_url, token: :none).json

           target =
             Enum.find_value(
               card["supportedInterfaces"],
               &(&1["protocolBinding"] == "GRPC" && &1["url"])
             )

           check!(
             target == info.grpc_target,
             "card advertises #{inspect(target)}, the endpoint is #{info.grpc_target}"
           )

           grpc(%{info | grpc_target: target}, :writer, fn ch, opts ->
             task = grpc_send!(ch, opts, "count_notes", %{})
             expect_state!(task, "TASK_STATE_COMPLETED")
             "dialed #{target} from the card and completed a task"
           end)
         end},
        {"request bytes that are not the request message are INVALID_ARGUMENT",
         fn info ->
           headers = [
             {"a2a-version", "1.1"},
             {"authorization", "Bearer " <> token_value(info, :writer)}
           ]

           {:ok, answer} =
             RawWire.grpc_raw(
               info.grpc_target,
               "/lf.a2a.v1.A2AService/SendMessage",
               headers,
               <<0xFF, 0xFF, 0xFF, 0x01, 0x02>>
             )

           check!(answer["status"] == 200, "HTTP #{inspect(answer["status"])}")
           status = answer["trailers"]["grpc-status"]
           check!(status == "3", "grpc-status #{inspect(status)}: #{inspect(answer["trailers"])}")

           check!(
             Base.decode64!(answer["trailers"]["grpc-status-details-bin"] || "", padding: false) =~
               "INVALID_PARAMS",
             "no ErrorInfo INVALID_PARAMS in grpc-status-details-bin"
           )

           # The channel is still good for a well-formed call.
           grpc(info, :writer, fn ch, opts ->
             expect_state!(grpc_send!(ch, opts, "count_notes", %{}), "TASK_STATE_COMPLETED")
           end)

           "grpc-status 3 INVALID_ARGUMENT with ErrorInfo INVALID_PARAMS"
         end},
        {"an RPC the service does not have is UNIMPLEMENTED in gRPC trailers",
         fn info ->
           path = "/lf.a2a.v1.A2AService/NoSuchMethod"
           {:ok, answer} = RawWire.grpc_raw(info.grpc_target, path, [], "")
           check!(answer["status"] == 200, "HTTP #{inspect(answer["status"])}, not 200")
           status = answer["trailers"]["grpc-status"]
           check!(status == "12", "grpc-status #{inspect(status)}: #{inspect(answer)}")

           check!(
             (answer["headers"]["content-type"] || "") =~ "application/grpc",
             "content-type #{inspect(answer["headers"]["content-type"])}"
           )

           "HTTP 200, grpc-status 12 UNIMPLEMENTED: #{answer["trailers"]["grpc-message"]}"
         end}
      ]
    end

    defp mount_scenarios(mount) do
      card_scenarios =
        [
          {"the well-known card is served and passes the audit",
           fn info ->
             url = mount_url(info, mount) <> "/.well-known/agent-card.json"
             resp = http(info, :get, url, token: :none)
             check!(resp.status == 200, "HTTP #{resp.status}")
             card = resp.json
             issues = AshA2A.Protocol.AgentCard.audit(card, audit_expectations(mount))

             check!(
               issues == [],
               "card audit found #{inspect(Enum.map(issues, & &1.code))}: #{clip(inspect(issues), 300)}"
             )

             ids = card["skills"] |> Enum.map(& &1["id"]) |> Enum.sort()
             expected = Surface.skills() |> Enum.map(& &1.name) |> Enum.sort()

             check!(
               ids == expected,
               "card skills #{inspect(ids -- expected)} / missing #{inspect(expected -- ids)}"
             )

             "audit clean; #{length(ids)} skills, exactly the capability index"
           end},
          {"the card's capabilities match what the mount serves",
           fn info ->
             card =
               http(info, :get, mount_url(info, mount) <> "/.well-known/agent-card.json",
                 token: :none
               ).json

             expected = audit_expectations(mount)
             caps = card["capabilities"] || %{}

             for {key, wire} <- [
                   push_notifications: "pushNotifications",
                   extended_agent_card: "extendedAgentCard",
                   streaming: "streaming"
                 ] do
               check!(
                 caps[wire] == true == Keyword.fetch!(expected, key),
                 "#{wire} is #{inspect(caps[wire])}, the mount serves it: #{Keyword.fetch!(expected, key)}"
               )
             end

             "streaming #{caps["streaming"]}, pushNotifications #{caps["pushNotifications"] == true}, extendedAgentCard #{caps["extendedAgentCard"] == true}"
           end},
          {"the served card's signature verifies, and a changed byte is refused",
           fn info ->
             alias AshA2A.Protocol.AgentCardSignature, as: Signature

             resp =
               http(info, :get, mount_url(info, mount) <> "/.well-known/agent-card.json",
                 token: :none
               )

             check!(resp.status == 200, "HTTP #{resp.status}")
             card = resp.json
             signatures = card["signatures"]

             check!(
               match?([%{"protected" => _, "signature" => _} | _], signatures),
               "the card carries no signatures entry: #{clip(inspect(signatures), 200)}"
             )

             kids =
               case Signature.verify(card, info.card_jwks, require: :all) do
                 {:ok, kids} -> kids
                 {:error, reason} -> fail!("signature refused: #{inspect(reason)}")
               end

             # Change one byte of the served bytes inside the signed document.
             name = card["name"]
             <<first, rest::binary>> = name
             changed = <<Bitwise.bxor(first, 1)>> <> rest

             tampered =
               resp.raw
               |> String.replace(Jason.encode!(name), Jason.encode!(changed), global: false)
               |> Jason.decode!()

             check!(tampered != card, "the tampered card equals the served card")

             case Signature.verify(tampered, info.card_jwks) do
               {:error, :bad_signature} -> :ok
               other -> fail!("a changed byte was not refused: #{inspect(other)}")
             end

             "#{length(signatures)} signature, kid #{Enum.join(kids, ", ")} verified over #{byte_size(resp.raw)} served bytes; one changed byte refused"
           end}
        ]

      card_scenarios ++ mount_negative(mount)
    end

    defp mount_negative(mount) when mount in ["/jsonrpc", "/a2a"] do
      key = if mount == "/a2a", do: :a2a, else: :jsonrpc

      [
        {"an unknown method is -32601",
         fn info ->
           c = caller(info, key, nil, nil)
           error = jr_error!(c, "sim/noSuchMethod", %{}, -32_601)
           "refused #{error["code"]} #{error["message"]}"
         end},
        {"a body that is not JSON is -32700",
         fn info ->
           resp = http(info, :post, mount_url(info, mount), body: "{not json")

           check!(
             get_in(resp.json, ["error", "code"]) == -32_700,
             "answered HTTP #{resp.status}: #{clip(resp.raw)}"
           )

           "refused -32700"
         end},
        {"a request without jsonrpc/method is -32600",
         fn info ->
           resp = http(info, :post, mount_url(info, mount), json: %{"id" => 1})

           check!(
             get_in(resp.json, ["error", "code"]) == -32_600,
             "answered HTTP #{resp.status}: #{clip(resp.raw)}"
           )

           "refused -32600"
         end},
        {"an unsupported A2A-Version is -32009",
         fn info ->
           c = caller(info, key, nil, nil)
           error = jr_error!(c, "tasks/list", %{}, -32_009, version: "9.9")
           "refused #{error["code"]} #{error["message"]}"
         end},
        {"an unserved path is 404",
         fn info ->
           resp = http(info, :get, mount_url(info, mount) <> "/no/such/path")
           check!(resp.status == 404, "HTTP #{resp.status}")
           "HTTP 404"
         end}
      ]
    end

    defp mount_negative("/rest") do
      [
        {"an unserved path is 404",
         fn info ->
           rest_error!(info, :get, "/no/such/path", 404)
           "HTTP 404"
         end}
      ]
    end

    defp mount_negative("/") do
      [
        {"the card honours If-None-Match",
         fn info ->
           first = http(info, :get, info.card_url, token: :none)
           etag = first.headers["etag"]
           check!(is_binary(etag), "the card response has no ETag")

           second =
             http(info, :get, info.card_url, token: :none, headers: [{"if-none-match", etag}])

           check!(second.status == 304, "revalidation answered HTTP #{second.status}")
           "ETag #{etag}; revalidation answers 304"
         end},
        {"a path outside every mount is 404",
         fn info ->
           resp = http(info, :get, info.base_url <> "/nowhere")
           check!(resp.status == 404, "HTTP #{resp.status}")
           "HTTP 404"
         end}
      ]
    end

    defp mount_negative(_mount), do: []

    defp mount_url(info, "/"), do: info.base_url
    defp mount_url(info, "/jsonrpc"), do: info.jsonrpc_url
    defp mount_url(info, "/a2a"), do: info.a2a_url
    defp mount_url(info, "/rest"), do: info.rest_url

    # What each mount really serves, for `AgentCard.audit/2`.
    defp audit_expectations(mount) do
      full? = mount != "/jsonrpc"

      [
        bindings: ["JSONRPC", "HTTP+JSON", "GRPC"],
        streaming: true,
        push_notifications: full?,
        extended_agent_card: full?,
        skill_ids: Enum.map(Surface.skills(), & &1.name),
        security_schemes: Enum.map(Surface.security_schemes(), & &1.name)
      ]
    end

    # == shared helpers ==========================================================

    defp http(info, method, url, opts \\ []) do
      {token, opts} = Keyword.pop(opts, :token, :writer)
      {version, opts} = Keyword.pop(opts, :version, "1.1")
      {leak_check?, opts} = Keyword.pop(opts, :leak_check, true)
      {headers, opts} = Keyword.pop(opts, :headers, [])

      auth =
        case token_value(info, token) do
          nil -> []
          value -> [{"authorization", "Bearer " <> value}]
        end

      content_type =
        if Keyword.has_key?(opts, :body), do: [{"content-type", "application/json"}], else: []

      request =
        [
          method: method,
          url: url,
          headers: [{"a2a-version", version}] ++ auth ++ content_type ++ headers,
          retry: false,
          decode_body: false,
          redirect: false,
          receive_timeout: 20_000
        ]
        |> Keyword.merge(opts)

      resp = Req.request!(request)
      raw = if is_binary(resp.body), do: resp.body, else: inspect(resp.body)

      if leak_check? do
        for marker <- leak_markers(info), raw =~ marker do
          fail!("the response to #{method} #{url} carries #{inspect(marker)}")
        end
      end

      json =
        case Jason.decode(raw) do
          {:ok, decoded} -> decoded
          {:error, _} -> nil
        end

      headers =
        Map.new(resp.headers, fn {name, values} ->
          {name, values |> List.wrap() |> Enum.join(", ")}
        end)

      %{status: resp.status, headers: headers, raw: raw, json: json}
    end

    defp leak_markers(info), do: ["a2a.auth", "ash_a2a.owner" | Map.values(info.tokens)]

    defp token_value(_info, :none), do: nil
    defp token_value(_info, {:raw, value}), do: value
    defp token_value(info, role), do: Map.fetch!(info.tokens, role)

    defp rpc_body(method, params),
      do: %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      }

    defp send_params(skill, data, extra \\ %{}, opts \\ []) do
      message =
        %{
          "messageId" => "msg-probe-" <> unique(),
          "role" => "ROLE_USER",
          "parts" => [%{"data" => data}],
          "metadata" => %{"skill" => skill}
        }
        |> put_some("taskId", opts[:task_id])
        |> put_some("contextId", opts[:context_id])

      Map.merge(%{"message" => message}, extra)
    end

    defp jr_send!(c, skill, data, extra \\ %{}, opts \\ []) do
      {msg_opts, http_opts} = Keyword.split(opts, [:task_id, :context_id])

      c
      |> jr_result!("message/send", send_params(skill, data, extra, msg_opts), http_opts)
      |> task_of!()
    end

    defp put_some(map, _key, nil), do: map
    defp put_some(map, key, value), do: Map.put(map, key, value)

    defp task_of!(%{"task" => %{"id" => _} = task}), do: task
    defp task_of!(%{"id" => _, "status" => _} = task), do: task
    defp task_of!(other), do: fail!("expected a task, got #{clip(inspect(other))}")

    defp push_config_of(%{"pushNotificationConfig" => %{} = inner}), do: inner
    defp push_config_of(%{} = flat), do: flat

    defp push_configs_of(%{"configs" => configs}), do: Enum.map(configs, &push_config_of/1)
    defp push_configs_of(configs) when is_list(configs), do: Enum.map(configs, &push_config_of/1)
    defp push_configs_of(other), do: fail!("expected a config list, got #{clip(inspect(other))}")

    defp state(task), do: get_in(task, ["status", "state"])

    defp expect_state!(task, expected) do
      check!(
        state(task) == expected,
        "expected #{expected}, got #{state(task)}: #{clip(inspect(task["status"]), 300)}"
      )

      task
    end

    defp artifacts?(task), do: match?([_ | _], task["artifacts"])

    defp artifact_data(task) do
      case task["artifacts"] do
        [%{"parts" => [%{"data" => data} | _]} | _] -> data
        other -> fail!("expected a data artifact, got #{clip(inspect(other))}")
      end
    end

    # SSE bodies: JSON-RPC mounts wrap each StreamResponse in a JSON-RPC
    # envelope; the HTTP+JSON mount sends the StreamResponse itself.
    # POSTs `json` and reads the SSE answer as it arrives: `[{ms since the
    # request, StreamResponse map}]`, one entry per `data:` frame. `unwrap`
    # takes a frame's JSON to its StreamResponse (identity for HTTP+JSON, the
    # JSON-RPC `result` otherwise).
    defp timed_sse!(info, url, json, unwrap) do
      started = System.monotonic_time(:millisecond)
      table = :ets.new(:timed_sse, [:ordered_set, :public])

      collect = fn {:data, data}, acc ->
        elapsed = System.monotonic_time(:millisecond) - started
        :ets.insert(table, {System.unique_integer([:monotonic]), elapsed, data})
        {:cont, acc}
      end

      resp =
        Req.request!(
          method: :post,
          url: url,
          json: json,
          headers: [
            {"a2a-version", "1.1"},
            {"authorization", "Bearer " <> token_value(info, :writer)}
          ],
          retry: false,
          receive_timeout: 20_000,
          into: collect
        )

      chunks = :ets.tab2list(table)
      :ets.delete(table)
      check!(resp.status == 200, "HTTP #{resp.status}")

      for {_key, elapsed, data} <- chunks,
          block <- String.split(data, "\n\n"),
          line <- String.split(block, "\n"),
          String.starts_with?(line, "data: ") do
        {elapsed, line |> String.replace_prefix("data: ", "") |> Jason.decode!() |> unwrap.()}
      end
    end

    # The admit-first contract of a stream (A2A v1.1 3.1.2): the Task frame is
    # on the wire while the handler is still running, and its id is usable.
    defp check_admit_first!(timed, delay_ms, get_task) do
      check!(timed != [], "no frame")
      [{first_at, first} | _rest] = timed
      {last_at, last} = List.last(timed)
      check!(frame_kind(first) == "task", "first frame was #{inspect(frame_kind(first))}")

      check!(
        first_at < delay_ms,
        "the Task frame arrived after #{first_at} ms, the handler runs #{delay_ms} ms"
      )

      check!(
        frame_state(first) in ["TASK_STATE_SUBMITTED", "TASK_STATE_WORKING"],
        "the first frame already says #{frame_state(first)}"
      )

      check!(last_at >= delay_ms, "the stream ended after #{last_at} ms, before the work")

      check!(
        frame_state(last) == "TASK_STATE_COMPLETED",
        "last frame was #{clip(inspect(last), 200)}"
      )

      states =
        timed |> Enum.map(fn {_at, frame} -> frame_state(frame) end) |> Enum.reject(&is_nil/1)

      check!("TASK_STATE_WORKING" in states, "no working status in #{inspect(states)}")
      expect_state!(get_task.(first["task"]["id"]), "TASK_STATE_COMPLETED")

      "Task frame after #{first_at} ms of a #{delay_ms} ms handler, " <>
        "#{length(timed)} frames, completed after #{last_at} ms"
    end

    defp sse_frames!(resp) do
      check!(resp.status == 200, "HTTP #{resp.status}: #{clip(resp.raw)}")

      check!(
        (resp.headers["content-type"] || "") =~ "text/event-stream",
        "not an event stream (#{resp.headers["content-type"]}): #{clip(resp.raw)}"
      )

      for block <- String.split(resp.raw, "\n\n"),
          line <- String.split(block, "\n"),
          String.starts_with?(line, "data: ") do
        line |> String.replace_prefix("data: ", "") |> Jason.decode!()
      end
    end

    defp sse_results!(resp) do
      for frame <- sse_frames!(resp) do
        case frame do
          %{"result" => result} -> result
          other -> fail!("SSE frame is not a JSON-RPC result: #{clip(inspect(other))}")
        end
      end
    end

    defp frame_kind(frame) when is_map(frame),
      do:
        Enum.find(
          ~w(task statusUpdate artifactUpdate messageUpdate message error),
          &Map.has_key?(frame, &1)
        )

    defp frame_state(%{"task" => task}), do: state(task)
    defp frame_state(%{"statusUpdate" => update}), do: state(update)
    defp frame_state(_frame), do: nil

    defp await_delivery!(path_suffix) do
      case PushReceiver.await(&String.ends_with?(&1.path, path_suffix), 8_000) do
        {:ok, delivery} -> delivery
        :timeout -> fail!("no webhook delivery to #{path_suffix} within 8 s")
      end
    end

    defp await!(what, timeout, fun) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_await(what, deadline, fun)
    end

    defp do_await(what, deadline, fun) do
      case fun.() do
        falsy when falsy in [nil, false] ->
          if System.monotonic_time(:millisecond) >= deadline do
            fail!("timed out waiting for #{what}")
          else
            Process.sleep(40)
            do_await(what, deadline, fun)
          end

        value ->
          value
      end
    end

    # Rows are seeded through the wire too: the granted `create_note` skill is
    # the one lawful way to write, and the row is then read back through Ash.
    defp seed_row!(info, prefix, body) do
      c = caller(info, :jsonrpc, nil, nil)
      title = "#{prefix}-seed-#{unique()}"
      data = put_some(%{"title" => title}, "body", body)
      task = jr_send!(c, "create_note", data)
      expect_state!(task, "TASK_STATE_COMPLETED")
      Ash.get!(Note, artifact_data(task)["id"], authorize?: false)
    end

    defp seed_note!(info, prefix), do: seed_row!(info, prefix, nil).title

    defp note_by_title(title) do
      Note |> Ash.read!(authorize?: false) |> Enum.find(&(&1.title == title))
    end

    defp note_count, do: Note |> Ash.read!(authorize?: false) |> length()

    defp unique, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    defp check!(true, _message), do: :ok
    defp check!(_falsy, message), do: fail!(message)

    @spec fail!(String.t()) :: no_return()
    defp fail!(message), do: raise(Failure, message: message)

    defp clip(text, max \\ 400) do
      text = text |> to_string() |> String.replace(~r/\s+/, " ")
      if String.length(text) > max, do: String.slice(text, 0, max) <> "...", else: text
    end
  end
end
