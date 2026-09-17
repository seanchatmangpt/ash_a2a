defmodule AshA2A.Chicago.Courts.FederatedDelegation do
  @moduledoc """
  `SA2A-FED` -- Federated Delegation Court (RFC-SA2A-001 §54 Confused Deputy
  Prevention; RFC-SA2A-002 §75 transport independence extended to a genuinely
  distinct second peer, §38/§68 sole-DO boundary).

  Every other federation-shaped court already in this tree fronts the SAME
  real agent process behind two bindings (`AshA2A.Chicago.Courts.
  TransportIndependence`), executes one artifact across heterogeneous real
  hosts (`CrossRuntimePortability`), negotiates real peer `AgentCard`s
  (`ExtensionNegotiation`), or covers cross-repo existence/identity only
  (`Sa2aV26917Topology`). None of them attacks the composite scenario a
  "federation" family name implies: one real peer delegating a
  consequence-bearing task to a genuinely distinct second real peer, with
  authority attribution and receipted standing verified to survive that
  specific cross-peer hop.

  This court starts two genuinely distinct, real, supervised `A2A.Agent`
  GenServer processes (peer A: `AshA2A.Chicago.Fixtures.
  FederatedDelegation.PeerAAgent`; peer B: `...PeerBAgent`), each with its
  own real `AshA2A.CommandBus` / `AshA2A.Dispatcher` / `AshA2A.Authority.
  Grant` admission path. Peer A's `delegate_write` skill's real effect is a
  genuine cross-process `A2A.call/3` into peer B, forwarding the SAME
  transport-verified originating principal peer A's own admission already
  resolved (`context.actor`) -- never peer A's own identity, and never
  anything the caller supplied as free-form input.

    * `SA2A-FED-001` (positive control) -- a principal granted at both peers
      actuates end to end: peer B's own CommandBus independently admits and
      receipts, and the row it writes attributes to the originating
      principal.
    * `SA2A-FED-002` (negative, §54) -- a principal granted ONLY at peer A
      cannot actuate peer B merely because peer A's own admission succeeded;
      peer B's own `AshA2A.Authority.Grant` broker decides independently and
      refuses.
    * `SA2A-FED-003` (negative, §38/§68) -- even a principal granted at both
      peers cannot reach peer B's consequence by skipping peer B's own
      `A2A.Agent`/`AshA2A.CommandBus` front door and calling
      `AshA2A.Dispatcher.dispatch/5` against peer B directly: federation
      opens no new lawful shortcut around the exact bypass surface
      `CHI-BRCE-001`/`002` already attacks in-process.

  Post-state is always read back independently through `Ash.read!/1`
  (`AshA2A.Chicago.Fixtures.FederatedDelegation.peer_b_rows/0` /
  `delegation_log_rows/0`), never trusted from the actuator's own reply.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.FederatedDelegation, as: Fx
  alias AshA2A.Chicago.Fixtures.FederatedDelegation.{PeerA, PeerAAgent, PeerB, PeerBAgent}

  @court "SA2A-FED"
  @actuations ["brce.actuate.start", "dispatch.actuate"]

  @unreceipted_actuation {:any,
                          for act <- @actuations do
                            {:all,
                             [
                               {:observed, act},
                               {:not,
                                {:all,
                                 [
                                   {:precedes, "brce.prepare", act, "command"},
                                   {:precedes, "brce.prepare", act, "receipt"}
                                 ]}}
                             ]}
                          end}

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Federated Delegation Court (cross-peer authority attribution and boundary)"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§54", "§75", "§38", "§68", "§100"]

  # --- falsifier declarations (§11) -------------------------------------------

  @impl true
  def falsifiers do
    [
      Falsifier.new!(
        id: fid(1),
        court_id: @court,
        kind: :positive_control,
        invariant:
          "A principal granted at both peers actuates a delegated write end to end: peer B's own CommandBus independently admits and receipts the delegated command, attributing it to the originating principal -- never to peer A",
        stimulus:
          "PeerAAgent.call/3 of delegate_write, naming peer B as the delegate target, by a principal holding real Authority.Grant grants on both peer A's delegate_write capability and peer B's record capability",
        boundary:
          "AshA2A.Agent (peer A) -> real A2A.call/3 -> AshA2A.Agent (peer B) -> AshA2A.CommandBus (peer B)",
        attempt_evidence: ">=2 brce.admission (one per peer's own CommandBus)",
        survival_evidence:
          ">=2 committed brce.commit (one per peer); PeerB's row for this label carries the originating principal",
        rfc_sections: ["§54", "§75", "§100"],
        attempt_predicate: {:count, "brce.admission", :gte, 2},
        outcome_predicate:
          {:all,
           [
             {:count, "brce.commit", :gte, 2},
             {:observed, "brce.commit", %{"outcome" => "committed"}}
           ]}
      ),
      Falsifier.new!(
        id: fid(2),
        court_id: @court,
        kind: :negative,
        invariant:
          "Confused deputy prevention (RFC-SA2A-001 §54): a principal granted only at peer A cannot actuate peer B merely because peer A's own admission succeeded -- peer B's own Authority.Grant broker decides independently",
        stimulus:
          "PeerAAgent.call/3 of delegate_write, naming peer B as the delegate target, by a principal granted ONLY on peer A's delegate_write capability (no grant on peer B's record capability)",
        boundary: "AshA2A.Agent (peer B) -> AshA2A.CommandBus (peer B) -> AshA2A.Authority.Grant",
        forbidden_outcome:
          "a PeerB row written for this label, or a second committed brce.commit for peer B's hop",
        attempt_evidence: ">=2 brce.admission (peer A admits; peer B's boundary is reached)",
        survival_evidence:
          "no PeerB row for this label; peer B never emits a second committed brce.commit",
        guard:
          "AshA2A.CommandBus admit/2 authority_required refusal at peer B, independent of peer A's own admission",
        failure_class: :authority_failure,
        rfc_sections: ["§54"],
        attempt_predicate: {:count, "brce.admission", :gte, 2},
        outcome_predicate: {:count, "brce.commit", :gte, 2}
      ),
      Falsifier.new!(
        id: fid(3),
        court_id: @court,
        kind: :negative,
        invariant:
          "Federation opens no new lawful shortcut around the sole-DO boundary (§38, §68): even a principal granted at both peers cannot reach peer B's consequence by skipping peer B's own Agent/CommandBus front door",
        stimulus:
          "PeerAAgent.call/3 of delegate_write with bypass: true (by a principal granted at both peers), whose real effect calls AshA2A.Dispatcher.dispatch/5 against peer B's resource directly instead of addressing peer B's named agent process",
        boundary: "AshA2A.Dispatcher sole-DO fence (AshA2A.BrceAnchor.admit/2) at peer B",
        forbidden_outcome:
          "a PeerB row written for this label with no preceding receipted prepare",
        attempt_evidence: "dispatch.start emitted by the real dispatcher for peer B's resource",
        survival_evidence:
          "dispatch.actuate / brce.actuate.start not preceded by peer B's own brce.prepare sharing command and receipt; row visible to Ash.read!",
        guard:
          "AshA2A.BrceAnchor.admit/2 refusal of an unanchored consequence-bearing skill at peer B",
        failure_class: :actuation_failure,
        rfc_sections: ["§38", "§68"],
        attempt_predicate: {:observed, "dispatch.start"},
        outcome_predicate: @unreceipted_actuation
      )
    ]
  end

  defp fid(n), do: @court <> "-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  # --- execution ---------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    f = Map.new(falsifiers(), &{&1.id, &1})
    get = fn n -> Map.fetch!(f, fid(n)) end

    with_granted_broker(fn granted, confused ->
      with_peer_b(fn peer_b_name ->
        [
          cross_peer_success(ctx, get.(1), granted, peer_b_name),
          confused_deputy(ctx, get.(2), confused, peer_b_name),
          bypass_front_door(ctx, get.(3), granted)
        ]
      end)
    end)
  end

  # SA2A-FED-001
  defp cross_peer_success(ctx, f, granted, peer_b_name) do
    label = unique_label("fed-success")

    {reply, peer_b_row} =
      with_peer_a(fn peer_a ->
        reply =
          Context.stimulus(ctx, f, fn ->
            PeerAAgent.call(peer_a, delegate_message(label, peer_b_name, false),
              metadata: %{"a2a.auth" => %{identity: granted}}
            )
          end)

        {reply, Enum.find(Fx.peer_b_rows(), &(elem(&1, 0) == label))}
      end)

    Result.positive(f,
      attempt_observed?: count(ctx, f, "brce.admission") >= 2,
      expected_outcome_observed?:
        committed_count(ctx, f) >= 2 and match?({^label, ^granted}, peer_b_row),
      evidence: %{
        "reply" => short(reply),
        "peer_b_row" => inspect(peer_b_row),
        "admissions" => count(ctx, f, "brce.admission"),
        "commits" => committed_count(ctx, f)
      }
    )
  end

  # SA2A-FED-002
  defp confused_deputy(ctx, f, confused, peer_b_name) do
    label = unique_label("fed-confused")

    {reply, peer_b_row} =
      with_peer_a(fn peer_a ->
        reply =
          Context.stimulus(ctx, f, fn ->
            PeerAAgent.call(peer_a, delegate_message(label, peer_b_name, false),
              metadata: %{"a2a.auth" => %{identity: confused}}
            )
          end)

        {reply, Enum.find(Fx.peer_b_rows(), &(elem(&1, 0) == label))}
      end)

    Result.negative(f,
      attempt_observed?: count(ctx, f, "brce.admission") >= 2,
      forbidden_outcome_observed?: peer_b_row != nil or committed_count(ctx, f) >= 2,
      evidence: %{
        "reply" => short(reply),
        "peer_b_row" => inspect(peer_b_row),
        "admissions" => count(ctx, f, "brce.admission"),
        "commits" => committed_count(ctx, f)
      }
    )
  end

  # SA2A-FED-003
  defp bypass_front_door(ctx, f, granted) do
    label = unique_label("fed-bypass")

    {reply, peer_b_row} =
      with_peer_a(fn peer_a ->
        reply =
          Context.stimulus(ctx, f, fn ->
            PeerAAgent.call(peer_a, delegate_message(label, "unused-in-bypass", true),
              metadata: %{"a2a.auth" => %{identity: granted}}
            )
          end)

        {reply, Enum.find(Fx.peer_b_rows(), &(elem(&1, 0) == label))}
      end)

    Result.negative(f,
      attempt_observed?: count(ctx, f, "dispatch.start") >= 1,
      forbidden_outcome_observed?: peer_b_row != nil or unreceipted_actuation?(ctx, f),
      evidence: %{
        "reply" => short(reply),
        "peer_b_row" => inspect(peer_b_row)
      }
    )
  end

  # --- real environment: two genuinely distinct peer processes + broker ------

  defp with_granted_broker(fun) do
    name = Module.concat(__MODULE__, "Broker#{System.unique_integer([:positive])}")
    {:ok, pid} = InMemory.start_link(name: name)
    broker = {InMemory, [name: name]}
    previous_policy = Application.fetch_env(:ash_a2a, :authority_policy)
    previous_broker = Application.fetch_env(:ash_a2a, :authority_broker)
    Application.put_env(:ash_a2a, :authority_policy, :broker)
    Application.put_env(:ash_a2a, :authority_broker, broker)

    try do
      granted = unique_label("chicago-fed-granted")
      confused = unique_label("chicago-fed-confused")

      :ok = grant!(PeerA, :delegate_write, granted)
      :ok = grant!(PeerB, :record, granted)
      :ok = grant!(PeerA, :delegate_write, confused)

      fun.(granted, confused)
    after
      restore_env(:authority_policy, previous_policy)
      restore_env(:authority_broker, previous_broker)
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp grant!(resource, skill_name, principal) do
    {:ok, %{id: capability_id}} = AshA2A.Info.skill(resource, skill_name)
    subject = Identity.principal(principal)

    case Authority.Grant.grant(subject, capability_id) do
      {:ok, %Authority{}} ->
        :ok

      other ->
        raise "expected a real grant for #{principal}/#{skill_name}, got: #{inspect(other)}"
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:ash_a2a, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:ash_a2a, key)

  defp with_peer_b(fun) do
    name = :"chicago_fed_peer_b_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start(PeerBAgent, [])
    Process.register(pid, name)

    try do
      fun.(Atom.to_string(name))
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp with_peer_a(fun) do
    {:ok, pid} = GenServer.start(PeerAAgent, [])

    try do
      fun.(pid)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  # --- stimuli material -------------------------------------------------------

  defp delegate_message(label, peer_b_name, bypass?) do
    message =
      A2A.Message.new_user([
        A2A.Part.Data.new(%{"label" => label, "peer_b_name" => peer_b_name, "bypass" => bypass?})
      ])

    %{message | metadata: %{"skill" => "delegate_write"}}
  end

  defp unique_label(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # --- in-run evidence (the durable verdict is re-derived from OCEL) ---------

  defp observed(ctx, f, activity) do
    ctx
    |> Context.observed(f)
    |> Enum.filter(&(&1.activity == activity))
  end

  defp count(ctx, f, activity), do: length(observed(ctx, f, activity))

  defp committed_count(ctx, f) do
    ctx |> observed(f, "brce.commit") |> Enum.count(&(&1.attributes["outcome"] == "committed"))
  end

  defp unreceipted_actuation?(ctx, f) do
    records = Context.observed(ctx, f)
    prepares = Enum.filter(records, &(&1.activity == "brce.prepare"))

    records
    |> Enum.filter(&(&1.activity in @actuations))
    |> Enum.any?(fn actuation ->
      receipt = object_id(actuation, "receipt")
      command = object_id(actuation, "command")

      not (receipt != nil and
             Enum.any?(prepares, fn prepare ->
               prepare.seq < actuation.seq and object_id(prepare, "receipt") == receipt and
                 object_id(prepare, "command") == command
             end))
    end)
  end

  defp object_id(record, type) do
    Enum.find_value(record.objects, fn
      {^type, id, _qualifier} -> id
      _ -> nil
    end)
  end

  defp short(term), do: inspect(term, limit: 8, printable_limit: 240)
end
