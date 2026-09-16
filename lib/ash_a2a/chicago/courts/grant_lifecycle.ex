defmodule AshA2A.Chicago.Courts.GrantLifecycle do
  @moduledoc """
  RFC-SA2A-002 §67 Grant Lifecycle court, id `SA2A-AUTH-GRANT`.

  Qualifies issue, authorize-before-expiry, refuse-after-expiry, revoke,
  refuse-after-revocation, durable reload and broker unavailability against
  the real durable `AshA2A.Authority.Broker.Ekv` (a real on-disk `EKV`
  instance the court starts, stops and restarts) and the real
  `AshA2A.Authority.Broker.InMemory` process. Every refusal is driven through
  the REAL dispatch path -- a real `A2A.Agent` message ->
  `AshA2A.Authority.Grant.authorize/3` -> `AshA2A.CommandBus` -- because an
  expiry or revocation honoured only by an unused verification path does not
  satisfy §67.

  Attempt evidence is the broker's own `authority.broker.lookup` (which names
  whether it found the grant standing, absent, expired, revoked, or the broker
  unavailable), the grant decision, and BRCE admission. Consequence is read
  from the real `AshA2A.Chicago.Fixtures.Authority.Ledger`; durable grant
  state is read directly through `EKV.get/2`, not through the broker.

  Stopping and restarting the real broker storage process is environment
  fault injection (§10), not a substitute for the broker.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Authority.Broker.{Ekv, InMemory}
  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.AuthorityHarness, as: H
  alias AshA2A.Chicago.Fixtures.Authority, as: Fixtures
  alias AshA2A.Chicago.Fixtures.Authority.ProbeAgent

  @court "SA2A-AUTH-GRANT"
  @capability "actuate"
  @expiry_ms 3_000

  @impl true
  def id, do: @court

  @impl true
  def title, do: "Grant lifecycle: issue, expiry, revocation, durable reload, broker unavailable"

  @impl true
  def gate, do: nil

  @impl true
  def profile, do: :do

  @impl true
  def rfc_sections, do: ["§67", "§100", "§130"]

  @impl true
  def ocel_mappings, do: H.mappings()

  @lookup_decision_admission {:all,
                              [
                                {:observed, "authority.broker.lookup"},
                                {:observed, "authority.decision"},
                                {:observed, "brce.admission"}
                              ]}

  @forbidden {:any,
              [
                {:observed, "authority.broker.lookup", %{"outcome" => "standing"}},
                {:observed, "authority.decision", %{"outcome" => "granted"}},
                {:observed, "brce.admission", %{"outcome" => "admitted"}},
                {:observed, "brce.actuate.start"}
              ]}

  @authorized {:all,
               [
                 {:observed, "authority.broker.lookup", %{"outcome" => "standing"}},
                 {:observed, "authority.decision", %{"outcome" => "granted"}},
                 {:observed, "brce.admission", %{"outcome" => "admitted"}},
                 {:precedes, "brce.prepare", "brce.actuate.start", "command"},
                 {:observed, "brce.commit", %{"outcome" => "committed"}}
               ]}

  # --- declarations (§11) -----------------------------------------------------

  @impl true
  def falsifiers do
    [
      control(1,
        invariant: "Issuing a grant through the durable broker produces a standing grant",
        stimulus: "Grant.grant/3 then Grant.granted?/3 against the real EKV broker",
        boundary: "AshA2A.Authority.Grant.grant/3 + AshA2A.Authority.Broker.Ekv",
        attempt_evidence: "authority.grant.issue attributed to the stimulus",
        survival_evidence:
          "authority.grant.issue issued + authority.broker.lookup standing; EKV.get finds status :issued",
        attempt_predicate: {:observed, "authority.grant.issue"},
        outcome_predicate:
          {:all,
           [
             {:observed, "authority.grant.issue", %{"outcome" => "issued"}},
             {:observed, "authority.broker.lookup", %{"outcome" => "standing"}}
           ]}
      ),
      control(2,
        invariant: "A time-bounded grant authorizes a real dispatch before it expires (§100)",
        stimulus: "real ProbeAgent actuate message within the grant's #{@expiry_ms}ms bound",
        boundary: "Ekv.granted?/3 -> Grant.authorize/3 -> CommandBus",
        attempt_evidence: "authority.broker.lookup, authority.decision, brce.admission",
        survival_evidence:
          "lookup standing, granted, admitted, prepared before actuation, committed; ledger row",
        attempt_predicate: @lookup_decision_admission,
        outcome_predicate: @authorized
      ),
      negative(3,
        invariant: "An expired grant is refused ON THE REAL DISPATCH PATH",
        stimulus:
          "the same principal's real ProbeAgent actuate message after the grant's expires_at",
        guard: "Ekv.granted?/3 past?(expires_at) (+ Authority.admits?/2 expired?)"
      ),
      control(4,
        invariant: "Revoking a standing grant durably records the revocation",
        stimulus: "Grant.revoke/3 of a standing grant against the real EKV broker",
        boundary: "AshA2A.Authority.Grant.revoke/3 + Ekv.revoke/2",
        attempt_evidence: "authority.grant.revoke attributed to the stimulus",
        survival_evidence: "authority.grant.revoke revoked; EKV.get finds status :revoked",
        attempt_predicate: {:observed, "authority.grant.revoke"},
        outcome_predicate: {:observed, "authority.grant.revoke", %{"outcome" => "revoked"}}
      ),
      negative(5,
        invariant: "A revoked grant is refused on the real dispatch path",
        stimulus: "real ProbeAgent actuate message by the principal whose grant was revoked",
        guard: "Ekv.granted?/3 requires status :issued"
      ),
      control(6,
        invariant: "Grants survive a real restart of the durable broker's storage process",
        stimulus:
          "stop the real EKV instance, start a new one on the same data_dir, then a real ProbeAgent actuate message by a granted principal",
        boundary: "EKV on-disk state -> Ekv.granted?/3 -> Grant.authorize/3 -> CommandBus",
        attempt_evidence: "authority.broker.lookup, authority.decision, brce.admission",
        survival_evidence:
          "lookup standing, granted, admitted, committed; ledger row; new EKV pid",
        attempt_predicate: @lookup_decision_admission,
        outcome_predicate: @authorized
      ),
      negative(7,
        invariant: "Revocations survive a real restart of the durable broker's storage process",
        stimulus:
          "stop and restart the real EKV instance, then a real ProbeAgent actuate message by a principal revoked before the restart",
        guard: "revocation persisted by Ekv.mark_revoked/4 and read back by Ekv.granted?/3"
      ),
      negative(8,
        invariant: "Durable broker unavailable fails closed (§67, §130)",
        stimulus:
          "stop the real EKV instance, then a real ProbeAgent actuate message by a principal holding a standing grant",
        guard: "Ekv.granted?/3 storage-failure clause answers false"
      ),
      control(9,
        invariant:
          "Once the durable broker is restored the same standing grant authorizes again: the refusal in SA2A-AUTH-GRANT-008 was the outage, not the grant",
        stimulus:
          "start the real EKV instance again, then the same principal's real ProbeAgent actuate message",
        boundary: "EKV -> Ekv.granted?/3 -> Grant.authorize/3 -> CommandBus",
        attempt_evidence: "authority.broker.lookup, authority.decision, brce.admission",
        survival_evidence: "lookup standing, granted, admitted, committed; ledger row",
        attempt_predicate: @lookup_decision_admission,
        outcome_predicate: @authorized
      ),
      negative(10,
        invariant: "In-process broker unavailable fails closed (§67, §130)",
        stimulus:
          "stop the real AshA2A.Authority.Broker.InMemory process, then a real ProbeAgent actuate message by a principal it had granted",
        guard: "InMemory.granted?/3 catch :exit clause answers false"
      ),
      control(11,
        invariant:
          "The in-process broker's standing grant authorizes while its process runs (§100 pair for -010)",
        stimulus:
          "real ProbeAgent actuate message by the granted principal before the InMemory process is stopped",
        boundary: "InMemory.granted?/3 -> Grant.authorize/3 -> CommandBus",
        attempt_evidence: "authority.broker.lookup, authority.decision, brce.admission",
        survival_evidence: "lookup standing, granted, admitted, committed; ledger row",
        attempt_predicate: @lookup_decision_admission,
        outcome_predicate: @authorized
      )
    ]
  end

  defp negative(n, fields) do
    Falsifier.new!(
      Keyword.merge(
        [
          id: fid(n),
          court_id: @court,
          kind: :negative,
          boundary:
            "AshA2A.Authority.Broker.granted?/3 -> Grant.authorize/3 -> CommandBus admission",
          forbidden_outcome:
            "lookup standing, authority.decision granted, brce.admission admitted or brce.actuate.start; a ledger row",
          attempt_evidence:
            "authority.broker.lookup, authority.decision and brce.admission attributed to the stimulus",
          survival_evidence:
            "independent OCEL consumer observes the forbidden outcome, or Ash.read! finds the nonce's ledger row",
          failure_class: :authority_failure,
          rfc_sections: rfc_sections(),
          attempt_predicate: @lookup_decision_admission,
          outcome_predicate: @forbidden
        ],
        fields
      )
    )
  end

  defp control(n, fields) do
    Falsifier.new!(
      Keyword.merge(
        [
          id: fid(n),
          court_id: @court,
          kind: :positive_control,
          failure_class: :authority_failure,
          rfc_sections: rfc_sections()
        ],
        fields
      )
    )
  end

  defp fid(n), do: "#{@court}-#{String.pad_leading(Integer.to_string(n), 3, "0")}"

  # --- execution --------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    unique = System.unique_integer([:positive])
    ekv_name = :"#{inspect(__MODULE__)}.Ekv#{unique}"
    data_dir = Path.join(System.tmp_dir!(), "ash_a2a_chicago_grant_lifecycle_#{unique}")
    ekv_opts = [name: ekv_name, data_dir: data_dir, cluster_size: 1]
    holder = start_holder(start_ekv(ekv_opts), H.start_agent(ProbeAgent))
    env = %{ctx: ctx, fs: fs, ekv_opts: ekv_opts, ekv_name: ekv_name, holder: holder}

    try do
      durable =
        H.with_broker({Ekv, name: ekv_name}, fn ->
          List.flatten([
            issue(env),
            expiry(env),
            revocation(env),
            restart(env),
            unavailable(env)
          ])
        end)

      durable ++ in_memory(env)
    after
      %{ekv: ekv, agent: agent} = Agent.get(holder, & &1)
      H.stop_agent(agent)
      stop_ekv(ekv)
      Agent.stop(holder)
      File.rm_rf(data_dir)
    end
  end

  # SA2A-AUTH-GRANT-001
  defp issue(%{ctx: ctx, fs: fs, ekv_name: ekv_name}) do
    f = fs[fid(1)]
    subject = Identity.principal(H.principal("issued"))

    {issued, standing} =
      Context.stimulus(ctx, f, fn ->
        {Grant.grant(subject, @capability), Grant.granted?(subject, @capability)}
      end)

    durable = durable_entry(ekv_name, subject)

    Result.positive(f,
      attempt_observed?: H.saw?(ctx, f, "authority.grant.issue"),
      expected_outcome_observed?:
        match?({:ok, %Authority{}}, issued) and standing and
          match?(%{status: :issued, capability_id: @capability}, durable) and
          H.saw?(ctx, f, "authority.grant.issue", %{"outcome" => "issued"}) and
          H.saw?(ctx, f, "authority.broker.lookup", %{"outcome" => "standing"}),
      evidence: %{"durable_entry" => inspect(durable), "observed" => H.seen(ctx, f)}
    )
  end

  # SA2A-AUTH-GRANT-002 / -003
  defp expiry(%{ctx: ctx, fs: fs} = env) do
    principal = H.principal("expiring")
    subject = Identity.principal(principal)
    expires_at = DateTime.add(DateTime.utc_now(), @expiry_ms, :millisecond)
    {:ok, _} = Grant.grant(subject, @capability, expires_at: expires_at)

    control = fs[fid(2)]
    control_nonce = H.nonce("grant-002")

    control_reply =
      Context.stimulus(ctx, control, fn -> actuate_via_agent(env, principal, control_nonce) end)

    dispatched_before_expiry = DateTime.compare(DateTime.utc_now(), expires_at) == :lt

    wait_ms = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond) + 100
    if wait_ms > 0, do: Process.sleep(wait_ms)

    attack = fs[fid(3)]
    nonce = H.nonce("grant-003")
    reply = Context.stimulus(ctx, attack, fn -> actuate_via_agent(env, principal, nonce) end)

    [
      authorized(ctx, control, control_nonce, control_reply, %{
        "expires_at" => DateTime.to_iso8601(expires_at),
        "completed_before_expiry" => dispatched_before_expiry
      }),
      refused(ctx, attack, nonce, reply, %{
        "expires_at" => DateTime.to_iso8601(expires_at),
        "dispatched_at" => DateTime.to_iso8601(DateTime.utc_now())
      })
    ]
  end

  # SA2A-AUTH-GRANT-004 / -005
  defp revocation(%{ctx: ctx, fs: fs, ekv_name: ekv_name} = env) do
    principal = H.principal("revoked")
    subject = Identity.principal(principal)
    {:ok, _} = Grant.grant(subject, @capability)
    standing_before = Grant.granted?(subject, @capability)

    control = fs[fid(4)]
    revoked = Context.stimulus(ctx, control, fn -> Grant.revoke(subject, @capability) end)
    durable = durable_entry(ekv_name, subject)

    control_result =
      Result.positive(control,
        attempt_observed?: H.saw?(ctx, control, "authority.grant.revoke"),
        expected_outcome_observed?:
          revoked == :ok and match?(%{status: :revoked}, durable) and
            H.saw?(ctx, control, "authority.grant.revoke", %{"outcome" => "revoked"}),
        evidence: %{
          "standing_before_revoke" => standing_before,
          "durable_entry" => inspect(durable),
          "observed" => H.seen(ctx, control)
        }
      )

    attack = fs[fid(5)]
    nonce = H.nonce("grant-005")
    reply = Context.stimulus(ctx, attack, fn -> actuate_via_agent(env, principal, nonce) end)

    [
      control_result,
      refused(ctx, attack, nonce, reply, %{"standing_before_revoke" => standing_before})
    ]
  end

  # SA2A-AUTH-GRANT-006 / -007
  defp restart(%{ctx: ctx, fs: fs} = env) do
    survivor = H.principal("survivor")
    {:ok, _} = Grant.grant(Identity.principal(survivor), @capability)
    revoked = H.principal("revoked-before-restart")
    {:ok, _} = Grant.grant(Identity.principal(revoked), @capability)
    :ok = Grant.revoke(Identity.principal(revoked), @capability)

    control = fs[fid(6)]
    control_nonce = H.nonce("grant-006")
    before_pid = current_ekv(env)

    control_reply =
      Context.stimulus(ctx, control, fn ->
        restart_ekv(env)
        actuate_via_agent(env, survivor, control_nonce)
      end)

    after_pid = current_ekv(env)

    attack = fs[fid(7)]
    nonce = H.nonce("grant-007")

    reply =
      Context.stimulus(ctx, attack, fn ->
        restart_ekv(env)
        actuate_via_agent(env, revoked, nonce)
      end)

    [
      authorized(ctx, control, control_nonce, control_reply, %{
        "ekv_restarted" => before_pid != after_pid,
        "ekv_pid_before" => inspect(before_pid),
        "ekv_pid_after" => inspect(after_pid)
      }),
      refused(ctx, attack, nonce, reply, %{"ekv_pid" => inspect(current_ekv(env))})
    ]
  end

  # SA2A-AUTH-GRANT-008 / -009
  defp unavailable(%{ctx: ctx, fs: fs} = env) do
    principal = H.principal("outage")
    {:ok, _} = Grant.grant(Identity.principal(principal), @capability)
    standing_before = Grant.granted?(Identity.principal(principal), @capability)

    # Environment fault: the real broker storage process is stopped.
    stop_ekv(current_ekv(env))
    put_holder(env, :ekv, nil)

    attack = fs[fid(8)]
    nonce = H.nonce("grant-008")
    reply = Context.stimulus(ctx, attack, fn -> actuate_via_agent(env, principal, nonce) end)
    agent_survived = agent_alive?(env)
    ensure_agent(env)

    control = fs[fid(9)]
    control_nonce = H.nonce("grant-009")

    control_reply =
      Context.stimulus(ctx, control, fn ->
        put_holder(env, :ekv, start_ekv(env.ekv_opts))
        actuate_via_agent(env, principal, control_nonce)
      end)

    [
      refused(ctx, attack, nonce, reply, %{
        "standing_before_outage" => standing_before,
        "agent_survived_outage" => agent_survived
      }),
      authorized(ctx, control, control_nonce, control_reply, %{})
    ]
  end

  # SA2A-AUTH-GRANT-010 / -011
  defp in_memory(%{ctx: ctx, fs: fs} = env) do
    name = :"#{inspect(__MODULE__)}.InMemory#{System.unique_integer([:positive])}"
    {:ok, pid} = InMemory.start_link(name: name)
    Process.unlink(pid)

    try do
      H.with_broker({InMemory, name: name}, fn ->
        principal = H.principal("in-memory")
        {:ok, _} = Grant.grant(Identity.principal(principal), @capability)

        control = fs[fid(11)]
        control_nonce = H.nonce("grant-011")

        control_reply =
          Context.stimulus(ctx, control, fn ->
            actuate_via_agent(env, principal, control_nonce)
          end)

        # Environment fault: the real broker process is stopped.
        GenServer.stop(pid, :normal)

        attack = fs[fid(10)]
        nonce = H.nonce("grant-010")
        reply = Context.stimulus(ctx, attack, fn -> actuate_via_agent(env, principal, nonce) end)
        agent_survived = agent_alive?(env)
        ensure_agent(env)

        [
          refused(ctx, attack, nonce, reply, %{
            "broker_alive" => Process.alive?(pid),
            "agent_survived_outage" => agent_survived
          }),
          authorized(ctx, control, control_nonce, control_reply, %{})
        ]
      end)
    after
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  end

  # --- results --------------------------------------------------------------------------

  defp authorized(ctx, f, nonce, reply, extra) do
    Result.positive(f,
      attempt_observed?: attempted?(ctx, f),
      expected_outcome_observed?:
        Fixtures.recorded?(nonce) and
          H.saw?(ctx, f, "authority.broker.lookup", %{"outcome" => "standing"}) and
          H.saw?(ctx, f, "authority.decision", %{"outcome" => "granted"}) and
          H.saw?(ctx, f, "brce.commit", %{"outcome" => "committed"}),
      evidence:
        Map.merge(%{"task_state" => H.task_state(reply), "observed" => H.seen(ctx, f)}, extra)
    )
  end

  defp refused(ctx, f, nonce, reply, extra) do
    Result.negative(f,
      attempt_observed?: attempted?(ctx, f),
      forbidden_outcome_observed?:
        Fixtures.recorded?(nonce) or
          H.saw?(ctx, f, "authority.broker.lookup", %{"outcome" => "standing"}) or
          H.saw?(ctx, f, "authority.decision", %{"outcome" => "granted"}) or
          H.saw?(ctx, f, "brce.admission", %{"outcome" => "admitted"}) or
          H.saw?(ctx, f, "brce.actuate.start"),
      evidence:
        Map.merge(%{"task_state" => H.task_state(reply), "observed" => H.seen(ctx, f)}, extra)
    )
  end

  defp attempted?(ctx, f) do
    H.saw?(ctx, f, "authority.broker.lookup") and H.saw?(ctx, f, "authority.decision") and
      H.saw?(ctx, f, "brce.admission")
  end

  # --- environment ------------------------------------------------------------------------

  defp actuate_via_agent(env, principal, nonce) do
    H.agent_call(ProbeAgent, current_agent(env), principal, %{"nonce" => nonce}, %{
      "skill" => @capability
    })
  end

  defp durable_entry(ekv_name, subject) do
    key = Identity.external(Identity.runtime(Authority.grant_token_id(subject, @capability)))
    EKV.get(ekv_name, key)
  catch
    kind, reason -> {kind, reason}
  end

  defp start_holder(ekv, agent),
    do: elem(Agent.start_link(fn -> %{ekv: ekv, agent: agent} end), 1)

  defp put_holder(%{holder: holder}, key, value),
    do: Agent.update(holder, &Map.put(&1, key, value))

  defp current_ekv(%{holder: holder}), do: Agent.get(holder, & &1.ekv)
  defp current_agent(%{holder: holder}), do: Agent.get(holder, & &1.agent)

  defp agent_alive?(env), do: Process.whereis(current_agent(env)) != nil

  defp ensure_agent(env) do
    unless agent_alive?(env), do: put_holder(env, :agent, H.start_agent(ProbeAgent))
    :ok
  end

  defp start_ekv(opts) do
    {:ok, pid} = EKV.start_link(opts)
    Process.unlink(pid)
    pid
  end

  defp stop_ekv(nil), do: :ok

  defp stop_ekv(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp restart_ekv(env) do
    stop_ekv(current_ekv(env))
    put_holder(env, :ekv, start_ekv(env.ekv_opts))
  end
end
