# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConferenceSim.Networking.Venue do
  @moduledoc """
  The venue: the conference's real discovery point. A real Plug served over a
  real loopback HTTP listener (`AshA2A.Test.EphemeralHttp`) that keeps a
  registry of attendee cards.

  Attendees register over real HTTP (`POST /register` with
  `{name, url, tier}`); the venue then fetches each attendee's card from the
  attendee's own served `/.well-known/agent-card.json` over real HTTP -- the
  venue never accepts a hand-supplied card. `GET /registry` returns the
  entries so any attendee can discover its peers.

  The venue stores CARDS ONLY. No message content ever passes through it,
  which is what the privacy court asserts against the real registry bytes.
  """

  @behaviour Plug

  @impl true
  def init(table: table), do: %{table: table}

  @impl true
  def call(%{method: "POST", path_info: ["register"]} = conn, %{table: table}) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"name" => name, "url" => url, "tier" => tier} = Jason.decode!(body)

    {:ok, %Req.Response{status: 200, body: card}} =
      Req.get(url <> "/.well-known/agent-card.json")

    true = is_map(card) and is_binary(card["name"])

    true =
      :ets.insert(table, {{:attendee, name}, %{"url" => url, "tier" => tier, "card" => card}})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "name" => name}))
  end

  def call(%{method: "GET", path_info: ["registry"]} = conn, %{table: table}) do
    entries =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {{:attendee, name}, value} -> Map.put(value, "name", name) end)
      |> Enum.sort_by(& &1["name"])

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"attendees" => every_entry(entries)}))
  end

  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not_found"}))
  end

  defp every_entry(entries), do: entries
end

defmodule AshA2A.ConferenceSim.Networking.Policy do
  @moduledoc """
  The conference's real contact policy, evaluated by every receiving
  attendee:

  1. a sender on the recipient's blocked-contact list is refused with
     `contact_blocked`;
  2. a `general`-tier sender may not open contact with another `general`-tier
     attendee (`tier_policy_denied`) -- `vip` attendees may contact, and be
     contacted by, any tier;
  3. otherwise the contact is allowed.
  """

  @spec evaluate(MapSet.t(), String.t(), String.t(), String.t()) :: :ok | {:refused, String.t()}
  def evaluate(blocked, recipient_tier, sender_name, sender_tier) do
    cond do
      MapSet.member?(blocked, sender_name) -> {:refused, "contact_blocked"}
      recipient_tier == "general" && sender_tier == "general" -> {:refused, "tier_policy_denied"}
      true -> :ok
    end
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendee do
  @moduledoc """
  Shared attendee logic. Config (identity, tier, blocked list, transcript
  table) reaches the agent's spawned, unregistered worker processes through
  `:persistent_term` keyed by the agent module -- the same measured constraint
  `AshA2A.Test.SemanticPeerFixture.PeerB` documents (SEC-02/SEC-08 worker
  isolation): no registered name exists inside `handle_message/2`.
  """

  @doc "Installs the real config for one attendee agent module."
  def configure(agent_mod, config) do
    :persistent_term.put({agent_mod, :conference_sim_config}, config)
  end

  def deconfigure(agent_mod) do
    :persistent_term.erase({agent_mod, :conference_sim_config})
  end

  @doc """
  Real handling shared by all six attendee agents. A delivered message is
  answered with a completed task carrying an ack data part; a refused message
  is answered with a bare typed-refusal message (`{"message": ...}` on the
  SendMessageResponse oneof) and never creates a task.
  """
  def handle(agent_mod, %AshA2A.Protocol.Message{} = message, _context) do
    config = :persistent_term.get({agent_mod, :conference_sim_config})
    %{"from" => sender, "tier" => sender_tier, "body" => body} = data_part(message)

    case AshA2A.ConferenceSim.Networking.Policy.evaluate(config.blocked, config.tier, sender, sender_tier) do
      :ok ->
        AshA2A.ConferenceSim.Networking.Attendee.record(config.transcript, config.name, :message, sender, body)

        {:reply, [AshA2A.Protocol.Part.Data.new(%{"ack" => body, "from" => config.name})]}

      {:refused, code} ->
        AshA2A.ConferenceSim.Networking.Attendee.record(config.transcript, config.name, :refusal, sender, body)

        {:message,
         [
           AshA2A.Protocol.Part.Data.new(%{
             "standing" => "refused",
             "code" => code,
             "from" => config.name,
             "detail" => "#{config.name} refuses contact from #{sender} (#{sender_tier}): #{code}"
           })
         ]}
    end
  end

  @doc """
  One attendee's real transcript, in arrival order. The table is shared by
  all six attendees in a test, so entries are keyed by the RECEIVING
  attendee's own name -- an attendee's transcript is what that attendee
  actually saw, and nobody else's.
  """
  @spec transcript(atom(), String.t(), :message | :refusal) :: [{String.t(), String.t()}]
  def transcript(table, owner, kind \\ :message) do
    table
    |> :ets.tab2list()
    |> Enum.sort()
    |> Enum.filter(fn
      {seq, entry_owner, entry_kind, _from, _body} ->
        is_integer(seq) and entry_owner == owner and entry_kind == kind

      _counter ->
        false
    end)
    |> Enum.map(fn {_seq, _owner, _kind, from, body} -> {from, body} end)
  end

  @doc "Records one real transcript entry owned by the receiving attendee."
  def record(table, owner, kind, from, body) do
    seq = :ets.update_counter(table, :seq, {2, 1}, {:seq, 0})
    true = :ets.insert(table, {seq, owner, kind, from, body})
    :ok
  end

  defp data_part(%AshA2A.Protocol.Message{parts: parts}) do
    Enum.find_value(parts, fn
      %AshA2A.Protocol.Part.Data{data: %{"from" => _, "tier" => _, "body" => _} = data} -> data
      _ -> nil
    end)
  end
end

# Six real attendee agents. Each is a genuine `use AshA2A.Protocol.Agent`
# GenServer with its own served identity, delegating to the shared attendee
# logic with its own module as the config key.
defmodule AshA2A.ConferenceSim.Networking.Attendees.Alice do
  @moduledoc "Attendee agent alice (VIP)."

  use AshA2A.Protocol.Agent,
    name: "attendee-alice",
    description: "VIP attendee alice",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendees.Ben do
  @moduledoc "Attendee agent ben (VIP)."

  use AshA2A.Protocol.Agent,
    name: "attendee-ben",
    description: "VIP attendee ben",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendees.Carol do
  @moduledoc "Attendee agent carol (general admission)."

  use AshA2A.Protocol.Agent,
    name: "attendee-carol",
    description: "General-admission attendee carol",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendees.Dee do
  @moduledoc "Attendee agent dee (general admission)."

  use AshA2A.Protocol.Agent,
    name: "attendee-dee",
    description: "General-admission attendee dee",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendees.Eli do
  @moduledoc "Attendee agent eli (VIP)."

  use AshA2A.Protocol.Agent,
    name: "attendee-eli",
    description: "VIP attendee eli",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendees.Fay do
  @moduledoc "Attendee agent fay (general admission)."

  use AshA2A.Protocol.Agent,
    name: "attendee-fay",
    description: "General-admission attendee fay",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.NetworkingCourt do
  @moduledoc """
  Conference-sim lane EV12: attendee-to-attendee agent messaging -- the
  "networking" feature as real A2A agent-to-agent messaging.

  ## The world under court

  Six attendee agents (alice/ben/eli VIP, carol/dee/fay general), each a real
  `use AshA2A.Protocol.Agent` GenServer behind a real `AshA2A.Transport.HTTPJSON`
  binding on its own real loopback Bandit listener (ephemeral port), plus a
  real venue plug on its own listener acting as the discovery point.

  ## Courts

  1. Discovery: all six attendees register with the venue over real HTTP; the
     venue fetches each card from the attendee's own well-known endpoint; the
     registry served back matches what each attendee itself serves.
  2. Two-way conversation: alice sends a message/task to ben over the real
     transport and gets ben's ack back in the completed task; ben then sends
     to alice; each attendee's real transcript contains the other's message,
     so both sides see both messages.
  3. Privacy boundary: carol (a third attendee) sees nothing of the alice<->ben
     conversation -- her transcript has none of it and the venue's registry
     bytes contain no message content at all.
  4. Auth tiers: VIP->general and general->VIP contacts succeed where the
     tier policy allows, and general->general is a typed refusal.
  5. Blocked contact: ben blocks alice; alice's messages get the typed
     refusal (`contact_blocked`), ben's transcript is untouched, and ben is
     unaffected elsewhere (still messages eli, still receives fay).
  6. Rate: alice sends 20 messages rapidly to ben; all 20 deliver, in send
     order, with unique task ids -- no loss, no reorder.

  Chicago-style: real supervised agent GenServers, real HTTP listeners, real
  `AshA2A.Protocol.Client` round trips, assertions on real transcripts and
  real wire responses. No Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: false

  alias AshA2A.ConferenceSim.Networking.{Attendee, Venue}
  alias AshA2A.ConferenceSim.Networking.Attendees.{Alice, Ben, Carol, Dee, Eli, Fay}
  alias AshA2A.Protocol.{Client, Message, Part, Task}
  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}

  @tiers %{Alice => "vip", Ben => "vip", Carol => "general", Dee => "general", Eli => "vip", Fay => "general"}
  @agents [Alice, Ben, Carol, Dee, Eli, Fay]

  setup do
    unique = System.unique_integer([:positive])
    transcript = :"conference_sim_transcript_#{unique}"
    venue_table = :"conference_sim_venue_#{unique}"
    :ets.new(transcript, [:named_table, :public, :ordered_set])
    :ets.new(venue_table, [:named_table, :public, :set])

    Enum.each(@agents, fn mod ->
      Attendee.configure(mod, %{
        name: attendee_name(mod),
        tier: Map.fetch!(@tiers, mod),
        blocked: MapSet.new(),
        transcript: transcript
      })
    end)

    {_sup, _registry} = AgentSupervisorCase.start_supervised_agents!(__MODULE__, @agents)

    servers =
      Map.new(@agents, fn mod ->
        {mod,
         EphemeralHttp.start!({AshA2A.Transport.HTTPJSON,
          AshA2A.Transport.HTTPJSON.init(
            agent: mod,
            base_url: "http://127.0.0.1/attendee-#{attendee_name(mod)}"
          )})}
      end)

    venue = EphemeralHttp.start!({Venue, table: venue_table})

    on_exit(fn ->
      Enum.each(@agents, &Attendee.deconfigure/1)
      # The tables are owned by the test process and die with it; tolerate
      # that when the on_exit callback runs after the owner has exited.
      if :ets.info(transcript) != :undefined, do: :ets.delete(transcript)
      if :ets.info(venue_table) != :undefined, do: :ets.delete(venue_table)
    end)

    %{transcript: transcript, venue: venue, servers: servers}
  end

  # -- helpers -------------------------------------------------------------------

  defp attendee_name(Alice), do: "alice"
  defp attendee_name(Ben), do: "ben"
  defp attendee_name(Carol), do: "carol"
  defp attendee_name(Dee), do: "dee"
  defp attendee_name(Eli), do: "eli"
  defp attendee_name(Fay), do: "fay"

  defp tier(mod), do: Map.fetch!(@tiers, mod)

  # Register every attendee with the venue over real HTTP; the venue fetches
  # each card from the attendee's own well-known endpoint.
  defp register_all!(venue, servers) do
    Enum.each(@agents, fn mod ->
      {:ok, %Req.Response{status: 200, body: %{"ok" => true}}} =
        Req.post(venue.base_url <> "/register",
          json: %{
            "name" => attendee_name(mod),
            "url" => Map.fetch!(servers, mod).base_url,
            "tier" => tier(mod)
          }
        )
    end)
  end

  defp registry!(venue) do
    {:ok, %Req.Response{status: 200, body: %{"attendees" => attendees}}} =
      Req.get(venue.base_url <> "/registry")

    attendees
  end

  # A real attendee-to-attendee A2A message: the sender posts to the
  # RECIPIENT's served HTTPJSON binding -- the recipient's client is built
  # from the recipient's own base_url, exactly as a real peer would.
  defp attendee_send(servers, from, to, body) do
    message =
      Message.new_user([
        Part.Data.new(%{"from" => attendee_name(from), "tier" => tier(from), "body" => body})
      ])

    client = Client.new(Map.fetch!(servers, to).base_url, transport: :http_json)
    Client.send_message(client, message)
  end

  defp task_data(%Task{artifacts: [%{parts: parts} | _]}) do
    Enum.find_value(parts, fn
      %Part.Data{data: data} -> data
      _ -> nil
    end)
  end

  defp refusal_data(%Message{parts: parts}) do
    Enum.find_value(parts, fn
      %Part.Data{data: %{"standing" => "refused"} = data} -> data
      _ -> nil
    end)
  end

  # -- courts --------------------------------------------------------------------

  test "1. discovery: six attendees discover each other through the venue's registry over real transport",
       %{venue: venue, servers: servers} do
    register_all!(venue, servers)
    attendees = registry!(venue)

    assert Enum.map(attendees, & &1["name"]) |> Enum.sort() == ~w(alice ben carol dee eli fay)

    # Every registry entry's card is exactly the card that attendee itself
    # serves, at the URL the registry hands back -- discovery is real.
    for entry <- attendees do
      assert entry["url"] == Map.fetch!(servers, safe_mod!(entry["name"])).base_url

      # The registry card is byte-identical to what the attendee itself
      # serves, and a real client can discover the attendee through it.
      {:ok, %Req.Response{status: 200, body: raw_card}} =
        Req.get(entry["url"] <> "/.well-known/agent-card.json")

      assert entry["card"] == raw_card

      {:ok, served} = Client.discover(entry["url"])
      assert served.name == entry["card"]["name"]
      assert Enum.any?(served.skills, &(&1.id == "networking.message"))
    end
  end

  test "2. two-way conversation: alice and ben each see both messages over the real transport",
       %{transcript: transcript, venue: venue, servers: servers} do
    register_all!(venue, servers)

    {:ok, %Task{status: %{state: :completed}} = task} =
      attendee_send(servers, Alice, Ben, "hi ben, this is alice")

    assert task_data(task) == %{"ack" => "hi ben, this is alice", "from" => "ben"}

    {:ok, %Task{status: %{state: :completed}} = reply_task} =
      attendee_send(servers, Ben, safe_mod!("alice"), "hi alice, ben here")

    assert task_data(reply_task) == %{"ack" => "hi alice, ben here", "from" => "alice"}

    # Each side's REAL transcript contains the other's message.
    assert Attendee.transcript(transcript, "ben") == [{"alice", "hi ben, this is alice"}]
    assert Attendee.transcript(transcript, "alice") == [{"ben", "hi alice, ben here"}]
  end

  test "3. privacy boundary: carol sees nothing of the alice<->ben conversation, and the venue carries no message content",
       %{transcript: transcript, venue: venue, servers: servers} do
    register_all!(venue, servers)

    {:ok, %Task{status: %{state: :completed}}} =
      attendee_send(servers, Alice, safe_mod!("ben"), "secret handoff at the lobby")

    {:ok, %Task{status: %{state: :completed}}} =
      attendee_send(servers, Ben, safe_mod!("alice"), "secret confirmed")

    # Carol's real transcript: nothing from alice or ben, none of their bodies.
    assert Attendee.transcript(transcript, "carol") == []
    assert Attendee.transcript(transcript, "alice") == [{"ben", "secret confirmed"}]
    assert Attendee.transcript(transcript, "ben") == [{"alice", "secret handoff at the lobby"}]

    # The venue's registry bytes contain no message content at all -- the
    # discovery plane never becomes a surveillance plane.
    {:ok, %Req.Response{body: registry_body}} = Req.get(venue.base_url <> "/registry")
    registry_bytes = Jason.encode!(registry_body)
    refute registry_bytes =~ "secret handoff at the lobby"
    refute registry_bytes =~ "secret confirmed"

    # Carol can still conduct her own networking, unaffected.
    {:ok, %Task{status: %{state: :completed}} = carol_task} =
      attendee_send(servers, Carol, safe_mod!("eli"), "eli, meet carol")

    assert task_data(carol_task) == %{"ack" => "eli, meet carol", "from" => "eli"}
    assert Attendee.transcript(transcript, "eli") == [{"carol", "eli, meet carol"}]
  end

  test "4. auth tiers: vip->general and general->vip deliver where the policy allows; general->general is a typed refusal",
       %{transcript: transcript, venue: venue, servers: servers} do
    register_all!(venue, servers)

    # VIP -> general: allowed.
    {:ok, %Task{status: %{state: :completed}} = vip_task} =
      attendee_send(servers, Alice, safe_mod!("dee"), "vip alice to general dee")

    assert task_data(vip_task) == %{"ack" => "vip alice to general dee", "from" => "dee"}

    # general -> VIP: allowed.
    {:ok, %Task{status: %{state: :completed}} = general_task} =
      attendee_send(servers, Carol, safe_mod!("eli"), "general carol to vip eli")

    assert task_data(general_task) == %{"ack" => "general carol to vip eli", "from" => "eli"}

    # general -> general: refused, typed, and no task is ever created.
    {:ok, %Message{} = refusal} =
      attendee_send(servers, Dee, safe_mod!("carol"), "dee to carol")

    assert refusal_data(refusal) == %{
             "standing" => "refused",
             "code" => "tier_policy_denied",
             "from" => "carol",
             "detail" => "carol refuses contact from dee (general): tier_policy_denied"
           }

    # The refusal never entered carol's delivered-message transcript.
    assert Attendee.transcript(transcript, "dee") == [{"alice", "vip alice to general dee"}]
    assert Attendee.transcript(transcript, "eli") == [{"carol", "general carol to vip eli"}]
    assert Attendee.transcript(transcript, "carol", :message) == []
    assert Attendee.transcript(transcript, "carol", :refusal) == [{"dee", "dee to carol"}]
  end

  test "5. blocked contact: ben blocks alice -- typed refusal, ben's transcript untouched, ben unaffected elsewhere",
       %{transcript: transcript, venue: venue, servers: servers} do
    register_all!(venue, servers)

    # Ben blocks alice: a real config change at ben's own boundary.
    ben_config = :persistent_term.get({Ben, :conference_sim_config})
    Attendee.configure(Ben, %{ben_config | blocked: MapSet.put(ben_config.blocked, "alice")})

    # Alice's messages now get the typed refusal.
    {:ok, %Message{} = refusal} =
      attendee_send(servers, Alice, safe_mod!("ben"), "still want to connect?")

    assert refusal_data(refusal)["code"] == "contact_blocked"
    assert refusal_data(refusal)["from"] == "ben"

    # Ben's delivered-message transcript is untouched.
    assert Attendee.transcript(transcript, "ben", :message) == []
    assert Attendee.transcript(transcript, "ben", :refusal) == [{"alice", "still want to connect?"}]

    # Ben is unaffected elsewhere: he can still initiate to eli ...
    {:ok, %Task{status: %{state: :completed}} = out_task} =
      attendee_send(servers, Ben, safe_mod!("eli"), "ben to eli, ignoring alice")

    assert task_data(out_task) == %{"ack" => "ben to eli, ignoring alice", "from" => "eli"}

    # ... and still receive from a non-blocked attendee.
    {:ok, %Task{status: %{state: :completed}}} =
      attendee_send(servers, Fay, safe_mod!("ben"), "fay says hi to ben")

    assert Attendee.transcript(transcript, "eli") == [{"ben", "ben to eli, ignoring alice"}]
    assert Attendee.transcript(transcript, "ben") == [{"fay", "fay says hi to ben"}]
  end

  test "6. rate: alice sends 20 messages rapidly to ben -- all delivered, in order, no loss, no reorder",
       %{transcript: transcript, venue: venue, servers: servers} do
    register_all!(venue, servers)

    tasks =
      for i <- 1..20 do
        case attendee_send(servers, Alice, Ben, "rapid-#{String.pad_leading(Integer.to_string(i), 3, "0")}") do
          {:ok, %Task{} = task} -> task
          other -> flunk("message #{i} lost: #{inspect(other)}")
        end
      end

    # All 20 completed, all unique tasks.
    assert length(tasks) == 20
    assert Enum.all?(tasks, &(&1.status.state == :completed))
    assert tasks |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 20

    # Ben's real transcript: all 20 bodies, in exact send order.
    assert Attendee.transcript(transcript, "ben") ==
             Enum.map(1..20, fn i ->
               {"alice", "rapid-#{String.pad_leading(Integer.to_string(i), 3, "0")}"}
             end)
  end

  defp safe_mod!("alice"), do: Alice
  defp safe_mod!("ben"), do: Ben
  defp safe_mod!("carol"), do: Carol
  defp safe_mod!("dee"), do: Dee
  defp safe_mod!("eli"), do: Eli
  defp safe_mod!("fay"), do: Fay
end
