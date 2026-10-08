# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule ConferenceSim do
  @moduledoc """
  Conference-sim lane EV1 shared fixture: a real AGNTCon+MCPCon conference
  (3,500 attendees / 150 talks / 11 tracks / 7 workshops / exhibitor booths
  with MCP servers / registration tiers / badge scanning) modeled entirely as
  REAL AshA2A machinery — real `AshA2A.Protocol.Agent` GenServers under a real
  `AshA2A.Protocol.AgentSupervisor`, real Ash (ETS) resources, real
  `AshA2A.Protocol.CardSigning` badge cards, real session tasks (paused
  `:input_required` on the venue agent's task store, continued on update) with
  real push-config deliveries through a hand-written REAL sender
  (`ConferenceSim.PushRecorder` — a real implementation of the push-sender
  interface that records deliveries into ETS; not a mock of any owned module).

  ## Model

    * **Attendees** — real GenServers (`ConferenceSim.Attendee`) holding a
      real signed badge card and their recorded badge scans.
    * **Exhibitors** — real `AshA2A` skill agents over `ConferenceSim.Booth`
      exposing one MCP-flavored skill (`call_tool`).
    * **Registration authority** — a real agent over `ConferenceSim.Registration`
      whose `issue_badge` skill issues badges as REAL agent cards built by
      `AshA2A.Info.agent_card/2`, signed with the venue key via
      `AshA2A.Protocol.CardSigning.sign/3` (`kid: "venue-badge-signing-key"`).
    * **Sessions** — real tasks on the venue agent's task store. Opening a
      session withholds the `:room` argument, so the venue agent pauses the
      session task at `:input_required` — a genuine non-terminal long-running
      task. `ConferenceSim.watch_session/2` registers a real push config and
      a stream subscription; `ConferenceSim.session_update/3` continues the
      task with the room assignment, transitioning it to `:completed` and
      fanning the change out to push configs and subscribers.
    * **Tiers** — `:general | :workshop | :vip | :press`, mapping to real
      auth scopes via `ConferenceSim.tier_scopes/1`.

  Later EV lanes import this fixture via `ConferenceSim.build/1` /
  `ConferenceSim.teardown/1`.
  """

  alias AshA2A.Protocol.CardSigning

  @tiers [:general, :workshop, :vip, :press]
  @badge_kid "venue-badge-signing-key"

  @doc "Registration tiers."
  def tiers, do: @tiers

  @doc """
  Tier -> auth scopes. `:general` admits talks; `:workshop` adds the 7
  workshop rooms; `:vip` adds lounge + front-row; `:press` adds interviews
  (talks included).
  """
  def tier_scopes(:general), do: ["session:scan"]

  def tier_scopes(:workshop), do: ["session:scan", "workshop:join"]

  def tier_scopes(:vip),
    do: ["session:scan", "workshop:join", "vip:lounge", "seat:front_row"]

  def tier_scopes(:press), do: ["session:scan", "press:interview"]

  def tier_scopes(other), do: {:error, {:unknown_tier, other}}

  @doc """
  Spins up the whole conference. Options:

    * `:attendees` — count of real attendee GenServers (default `10`)
    * `:exhibitors` — list of exhibitor agent modules (default: the three
      built-in booth agents)
    * `:venue_key` — signing key (default: 32 random bytes)

  Returns `{:ok, sim}`. Call `ConferenceSim.teardown/1` when done (register
  it via `on_exit` in tests).
  """
  def build(opts \\ []) do
    n_attendees = Keyword.get(opts, :attendees, 10)
    exhibitor_modules = Keyword.get(opts, :exhibitors, exhibitor_modules())
    venue_key = Keyword.get(opts, :venue_key, :crypto.strong_rand_bytes(32))
    ref = System.unique_integer([:positive])

    ports_before = Port.list()

    # Real ETS-backed push-delivery recorder; owner = this (calling) process,
    # so the caller must keep the sim alive until teardown.
    table = :"conference_sim_push_#{ref}"
    ^table = :ets.new(table, [:bag, :public, :named_table, read_concurrency: true])

    {:ok, sup} =
      AshA2A.Protocol.AgentSupervisor.start_link(
        agents: [ConferenceSim.BadgeAuthorityAgent, ConferenceSim.VenueAgent | exhibitor_modules],
        name: sup_name(ref),
        registry: registry_name(ref),
        agent_opts: [push_sender: {ConferenceSim.PushRecorder, table: table}]
      )

    {:ok, attendee_sup} =
      Supervisor.start_link(attendee_children(n_attendees, ref), strategy: :one_for_one)

    attendees =
      for i <- 1..n_attendees do
        tier = Enum.at(@tiers, rem(i - 1, length(@tiers)))
        id = "attendee-#{ref}-#{i}"
        name = attendee_name(ref, i)

        %{
          id: id,
          tier: tier,
          pid: GenServer.whereis(name),
          name: name,
          badge: issue_badge(id, tier, venue_key)
        }
      end

    exhibitors =
      for mod <- exhibitor_modules do
        %{name: mod.agent_card().name, module: mod, pid: GenServer.whereis(mod)}
      end

    {:ok,
     %{
       ref: ref,
       sup: sup,
       attendee_sup: attendee_sup,
       attendees: attendees,
       exhibitors: exhibitors,
       authority: ConferenceSim.BadgeAuthorityAgent,
       venue: ConferenceSim.VenueAgent,
       venue_key: venue_key,
       push_table: table,
       ports_before: ports_before
     }}
  end

  @doc """
  Tears the sim down: stops the agent supervisor and the attendee supervisor
  FIRST (so `:one_for_one` does not restart killed children), kills any
  stragglers, deletes the push table, and VERIFIES every recorded process is
  dead and that no ports leaked beyond `sim.ports_before`.

  Returns `:ok`, `{:error, {:processes_alive, pids}}` or
  `{:error, {:ports_leaked, ports}}`.
  """
  def teardown(%{sup: sup, attendee_sup: attendee_sup} = sim) do
    stop_sup(sup)

    try do
      Supervisor.stop(attendee_sup)
    catch
      :exit, _ -> :ok
    end

    Enum.each(sim.attendees, fn %{pid: pid} ->
      if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    if :ets.whereis(sim.push_table) != :undefined, do: :ets.delete(sim.push_table)

    alive =
      sim.attendees
      |> Enum.map(& &1.pid)
      |> Enum.filter(&is_pid(&1) and Process.alive?(&1))

    leaked = Port.list() -- sim.ports_before

    cond do
      alive != [] -> {:error, {:processes_alive, alive}}
      leaked != [] -> {:error, {:ports_leaked, leaked}}
      true -> :ok
    end
  end

  @doc """
  Issues a badge for `attendee_id` at `tier`: a REAL agent card built by
  `AshA2A.Info.agent_card/2` over the registration resource, signed with
  `venue_key` via `CardSigning.sign/3` (`kid: "venue-badge-signing-key"`).

  This is the exact function the registration authority agent's real
  `issue_badge` skill dispatches to — attendees in `build/1` carry these.
  """
  def issue_badge(attendee_id, tier, venue_key) do
    case tier_scopes(tier) do
      {:error, _} = err ->
        err

      scopes ->
        card = AshA2A.Info.agent_card(ConferenceSim.Registration, name: "badge:#{attendee_id}")

        card = %{
          card
          | description:
              "AGNTCon+MCPCon badge = #{attendee_id} (#{tier}): #{Enum.join(scopes, " ")}"
        }

        CardSigning.sign(card, venue_key, kid: @badge_kid)
    end
  end

  @doc "The `kid` stamped into every badge signature."
  def badge_kid, do: @badge_kid

  @doc "Deterministic venue key for the authority agent's `issue_badge` skill path."
  def test_venue_key, do: :crypto.hash(:sha256, "conference-sim-venue-key")

  @doc """
  Records a badge scan on `attendee` for `target` (a session task id or booth
  card name), gated by the attendee's tier scopes — `session:scan` covers
  talks and booths; `workshop:join` covers `workshop:`-prefixed targets.
  Returns `:ok` or `{:error, :scope_denied}`.
  """
  def scan(_sim, attendee, target) do
    scopes = tier_scopes(attendee.tier)

    allowed? =
      if is_binary(target) and String.starts_with?(target, "workshop:") do
        "workshop:join" in scopes
      else
        "session:scan" in scopes
      end

    if allowed? do
      :ok = GenServer.call(attendee.pid, {:scan, target})
    else
      {:error, :scope_denied}
    end
  end

  @doc "Scans recorded on an attendee."
  def scans(attendee), do: GenServer.call(attendee.pid, :scans)

  @doc """
  Opens a session: a real task on the venue agent (`open_session` skill).
  The `:room` argument is withheld, so the venue pauses the session task at
  `:input_required` — a genuine non-terminal long-running task. Returns
  `{:ok, session}` with `:task_id` (used for push configs, subscriptions and
  updates) and `:id`.
  """
  def open_session(_sim, track, title) do
    {:ok, task} =
      ConferenceSim.VenueAgent.call(
        ConferenceSim.VenueAgent,
        data_message(%{track: track, title: title}, :open_session)
      )

    if task.status.state != :input_required do
      raise ArgumentError,
        message:
          "expected session task to pause :input_required, got #{inspect(task.status.state)}"
    end

    {:ok, %{id: task.id, task_id: task.id, track: track, title: title}}
  end

  @doc """
  Watches a session: registers a REAL push config on the (non-terminal)
  session task — deliveries flow through `ConferenceSim.PushRecorder` into
  the sim's ETS table — and subscribes the caller for
  `{:a2a_task_event, task_id, task}` stream events.
  """
  def watch_session(_sim, session) do
    config = %AshA2A.Protocol.PushNotificationConfig{
      id: "watch-#{session.task_id}",
      task_id: session.task_id,
      url: "https://venue.agntcon.example/hooks/#{session.id}",
      token: "venue-webhook-token"
    }

    {:ok, _stored} = GenServer.call(ConferenceSim.VenueAgent, {:set_push_config, config})

    {:ok, _snapshot} = GenServer.call(ConferenceSim.VenueAgent, {:subscribe, session.task_id})

    :ok
  end

  @doc """
  Pushes a session change: a real continuation on the paused session task
  supplying the room assignment — the task transitions to `:completed` and
  the change fans out to the registered push config and stream subscribers.
  """
  def session_update(_sim, session, room) do
    {:ok, task} =
      ConferenceSim.VenueAgent.call(
        ConferenceSim.VenueAgent,
        data_message(%{room: room}, :open_session),
        task_id: session.task_id
      )

    {:ok, task}
  end

  @doc "Push deliveries recorded for `task_id` (`{task_id, config_id, url, payload}`)."
  def push_deliveries(sim, task_id), do: :ets.lookup(sim.push_table, task_id)

  @doc "An MCP-flavored booth call: dispatches the exhibitor's `call_tool` skill."
  def booth_call(exhibitor, tool, arguments \\ %{}) do
    {:ok, task} =
      exhibitor.module.call(
        exhibitor.module,
        data_message(%{tool: tool, arguments: arguments}, :call_tool)
      )

    {:ok, artifact_data(task)}
  end

  @doc "Fetches a real agent card from a running agent GenServer."
  def fetch_card(module) when is_atom(module), do: GenServer.call(module, :get_agent_card)

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp attendee_children(n, ref) do
    for i <- 1..n do
      %{
        id: {:attendee, i},
        start:
          {ConferenceSim.Attendee, :start_link,
           [[name: attendee_name(ref, i), id: "attendee-#{ref}-#{i}"]]}
      }
    end
  end

  defp attendee_name(ref, i), do: :"conference_sim_attendee_#{ref}_#{i}"

  defp sup_name(ref), do: :"conference_sim_sup_#{ref}"
  defp registry_name(ref), do: :"conference_sim_registry_#{ref}"

  defp exhibitor_modules do
    [ConferenceSim.AcmeAIBooth, ConferenceSim.VertexLabsBooth, ConferenceSim.QuantalYTICSBooth]
  end

  defp stop_sup(sup) do
    try do
      Supervisor.stop(sup)
    catch
      :exit, _ -> :ok
    end
  end

  defp artifact_data(task) do
    case task.artifacts do
      [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: data}]}] -> data
      _ -> nil
    end
  end

  defp data_message(data, skill) when is_atom(skill) do
    msg = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(data)])
    %{msg | metadata: %{skill: skill}}
  end
end

defmodule ConferenceSim.Attendee do
  @moduledoc """
  A real attendee GenServer: holds the attendee's identity and the set of
  badge scans they recorded. This is an ordinary `GenServer` under a real
  supervisor owned by the sim — no mocks anywhere in the fixture.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, Map.new(opts), name: Keyword.fetch!(opts, :name))
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:scan, target}, _from, state) do
    {:reply, :ok, update_in(state, [Access.key(:scans, MapSet.new())], &MapSet.put(&1, target))}
  end

  def handle_call(:scans, _from, state) do
    {:reply, MapSet.to_list(state.scans || MapSet.new()), state}
  end

  def handle_call(:badge, _from, state), do: {:reply, Map.get(state, :badge), state}
end

defmodule ConferenceSim.PushRecorder do
  @moduledoc """
  A REAL push-notification sender (same `deliver/3` interface as
  `AshA2A.Protocol.PushNotificationSender.HTTP`) that records every delivery
  into the sim's ETS table as `{task_id, config_id, url, payload}`. This is a
  hand-written real implementation of a public interface — the Chicago-school
  allowed double — not a mock of any owned module.
  """

  def deliver(config, payload, opts) do
    table = Keyword.fetch!(opts, :table)
    true = :ets.insert(table, {config.task_id, config.id, config.url, payload})
    :ok
  end
end

defmodule ConferenceSim.Registration do
  @moduledoc """
  Real registration-authority resource: its `issue_badge` skill mints the
  same signed card `ConferenceSim.issue_badge/3` produces, then returns a
  plain-map receipt (so the artifact stays wire-encodable).
  """

  use Ash.Resource,
    domain: ConferenceSim.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :issue_badge, :map do
      argument(:attendee_id, :string, allow_nil?: false)
      argument(:tier, :atom, allow_nil?: false)

      run(fn input, _context ->
        case ConferenceSim.issue_badge(
               input.arguments.attendee_id,
               input.arguments.tier,
               ConferenceSim.test_venue_key()
             ) do
          %{signatures: [_ | _]} ->
            {:ok,
             %{
               attendee_id: input.arguments.attendee_id,
               tier: input.arguments.tier,
               badge_kid: ConferenceSim.badge_kid(),
               signed: true
             }}

          {:error, _} = err ->
            {:error, err}
        end
      end)
    end
  end

  a2a do
    skill(:issue_badge, :issue_badge, consequence: :observe)
  end
end

defmodule ConferenceSim.Venue do
  @moduledoc """
  Real venue resource. `open_session` requires `track`, `title` AND `room`;
  the fixture's `open_session/3` withholds `:room`, pausing the session task
  at `:input_required`, and `session_update/3` continues it.
  """

  use Ash.Resource,
    domain: ConferenceSim.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :open_session, :map do
      argument(:track, :string, allow_nil?: false)
      argument(:title, :string, allow_nil?: false)
      argument(:room, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok,
         %{
           session_id: "sess-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)),
           track: input.arguments.track,
           title: input.arguments.title,
           room: input.arguments.room
         }}
      end)
    end
  end

  a2a do
    skill(:open_session, :open_session, consequence: :observe)
  end
end

defmodule ConferenceSim.Booth do
  @moduledoc """
  Real exhibitor-booth resource with one MCP-flavored skill: `call_tool`
  echoes a JSON-RPC 2.0-shaped tool result, the way an MCP server behind an
  exhibitor booth would answer.
  """

  use Ash.Resource,
    domain: ConferenceSim.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :call_tool, :map do
      argument(:tool, :string, allow_nil?: false)
      argument(:arguments, :map, allow_nil?: true)

      run(fn input, _context ->
        {:ok,
         %{
           "jsonrpc" => "2.0",
           "tool" => input.arguments.tool,
           "result" => %{
             "content" => [
               %{"type" => "text", "text" => "#{input.arguments.tool} ok (booth demo)"}
             ]
           }
         }}
      end)
    end
  end

  a2a do
    skill(:call_tool, :call_tool, consequence: :observe)
  end
end

defmodule ConferenceSim.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(ConferenceSim.Registration)
    resource(ConferenceSim.Venue)
    resource(ConferenceSim.Booth)
  end
end

defmodule ConferenceSim.BadgeAuthorityAgent do
  @moduledoc "Real registration authority agent (issues signed badge cards)."

  use AshA2A.Agent,
    resource_or_domain: ConferenceSim.Registration,
    name: "agntcon_registration_authority"
end

defmodule ConferenceSim.VenueAgent do
  @moduledoc "Real venue agent (session tasks, push configs, stream subscribers)."

  use AshA2A.Agent,
    resource_or_domain: ConferenceSim.Venue,
    name: "agntcon_venue"
end

defmodule ConferenceSim.AcmeAIBooth do
  @moduledoc "Real exhibitor agent: Acme AI booth (MCP server skills)."

  use AshA2A.Agent,
    resource_or_domain: ConferenceSim.Booth,
    name: "booth_acme_ai"
end

defmodule ConferenceSim.VertexLabsBooth do
  @moduledoc "Real exhibitor agent: Vertex Labs booth (MCP server skills)."

  use AshA2A.Agent,
    resource_or_domain: ConferenceSim.Booth,
    name: "booth_vertex_labs"
end

defmodule ConferenceSim.QuantalYTICSBooth do
  @moduledoc "Real exhibitor agent: Quantalytics booth (MCP server skills)."

  use AshA2A.Agent,
    resource_or_domain: ConferenceSim.Booth,
    name: "booth_quantalytics"
end
