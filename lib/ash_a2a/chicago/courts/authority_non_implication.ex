defmodule AshA2A.Chicago.Courts.AuthorityNonImplication do
  @moduledoc """
  RFC-SA2A-002 §57 (Capability), §64 (Authority), §65 (Authority
  Non-Implication) and §66 (Confused Deputy) court, id `SA2A-AUTH`.

  Every attack is driven through a real consequence entry point -- the real
  `A2A.Agent` dispatch path (`AshA2A.Agent.__dispatch__/3` ->
  `AshA2A.Authority.Grant.authorize/3` -> `AshA2A.CommandBus`), the real
  `A2A.Plug.Auth` + `A2A.Plug` HTTP transport, or a direct
  `AshA2A.CommandBus.run/4` exactly as `Reactor`/`Oban` callers reach it -- and
  must be observed REACHING the authority boundary (`authority.decision`,
  `brce.admission`, `bounds.delegate`) before its refusal can count (§12).
  Consequence is read independently from the real
  `AshA2A.Chicago.Fixtures.Authority.Ledger` (`Ash.read!/1`), never from a
  reply.

  Positive controls (§100) prove the boundary discriminates: a granted
  principal really actuates over the agent path and over the HTTP transport, a
  per-capability grant really authorizes its own capability, and a narrowing
  delegation really delegates.

  The host's configured `:authority_policy` is qualified as-is; the court only
  points `:authority_broker` at a fresh, real `AshA2A.Authority.Broker.InMemory`
  process for the run (environment, §10) and restores it afterwards.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Authority, Command, CommandBus, Identity, Planning}
  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.AuthorityHarness, as: H
  alias AshA2A.Chicago.Fixtures.Authority, as: Fixtures
  alias AshA2A.Chicago.Fixtures.Authority.{Probe, ProbeAgent, VaultAgent}
  alias AshA2A.Semantic.{Bounds, ExecutionPackage, IR, Ontology, PlanningIR, Source}

  @court "SA2A-AUTH"
  @probe_actuate "AshA2A.Chicago.Fixtures.Authority.Probe.actuate"
  @probe_mutate "AshA2A.Chicago.Fixtures.Authority.Probe.mutate"

  @impl true
  def id, do: @court

  @impl true
  def title, do: "Authority non-implication, capability and confused-deputy court"

  @impl true
  def gate, do: nil

  @impl true
  def profile, do: :do

  @impl true
  def rfc_sections, do: ["§57", "§64", "§65", "§66", "§100"]

  @impl true
  def ocel_mappings, do: H.mappings()

  # --- declarations (§11) -----------------------------------------------------

  @impl true
  def falsifiers do
    [
      control(1,
        invariant:
          "A principal holding a real broker grant for a consequential capability is admitted and actuates: the authority boundary discriminates (§100)",
        stimulus:
          "real ProbeAgent message (skill actuate) as a transport-verified principal holding Grant.grant(principal, \"actuate\")",
        boundary: "AshA2A.Authority.Grant.authorize/3 + AshA2A.CommandBus admission",
        attempt_evidence: "authority.decision and brce.admission attributed to the stimulus",
        survival_evidence:
          "authority.decision granted, brce.admission admitted, prepare precedes actuation, commit committed; ledger row read back by Ash.read!",
        attempt_predicate: H.reached_authority_and_admission(),
        outcome_predicate: H.granted_and_committed()
      ),
      negative(2,
        invariant:
          "Authentication ⇏ Authority: an authenticated principal with zero grants cannot actuate",
        stimulus:
          "real ProbeAgent message (skill actuate) as a transport-verified principal with no grant",
        guard:
          "Grant.broker_authorize/3 granted?/3 check + CommandBus.admit/2 :authority_required"
      ),
      control(3,
        invariant:
          "A grant for capability A (mutate) really authorizes A: the grant used by SA2A-AUTH-004 stands",
        stimulus: "real ProbeAgent message (skill mutate) as a principal granted only \"mutate\"",
        boundary: "AshA2A.Authority.Grant.authorize/3 + AshA2A.CommandBus admission",
        attempt_evidence: "authority.decision and brce.admission attributed to the stimulus",
        survival_evidence: "granted + admitted + committed; probe.mutate ledger row",
        attempt_predicate: H.reached_authority_and_admission(),
        outcome_predicate: H.granted_and_committed()
      ),
      negative(4,
        invariant: "Grant(a, A) ⇏ Authority(a, B): a grant for mutate does not authorize actuate",
        stimulus:
          "real ProbeAgent message (skill actuate) as the principal granted only \"mutate\"",
        guard:
          "grant keyed on (subject, capability_id) in Authority.grant_token_id/2 + broker granted?/3"
      ),
      negative(5,
        invariant:
          "TaskAssignment ⇏ Authority: a command bound to a real A2A task is refused without a grant",
        stimulus:
          "CommandBus.run/4 of Probe actuate with task_id = a real A2A task the ProbeAgent created, authority = Grant.authorize/3",
        guard: "Grant.authorize/3 ignores task binding + CommandBus.admit/2 :authority_required",
        attempt_evidence: "authority.decision and brce.admission attributed to the stimulus"
      ),
      negative(6,
        invariant:
          "PlanValidity ⇏ Authority: a Planning.admit/2-admitted plan's ExecutionPackage presented as the closing dispatch confers nothing",
        stimulus:
          "real ProbeAgent message (skill actuate, continuation_fingerprint = real ExecutionPackage fingerprint) with no grant",
        guard:
          "Grant.authorize/3 consults only the broker; ExecutionPackage.fence authority: :none"
      ),
      negative(7,
        invariant:
          "Proof ⇏ Authority: an Ed25519 proof the court verifies with :crypto confers nothing",
        stimulus:
          "real ProbeAgent message (skill actuate) carrying a verified Ed25519 signature over the request, no grant",
        guard: "no proof input in Grant.authorize/3 or CommandBus.admit/2"
      ),
      control(8,
        invariant:
          "A transport-verified identity WITH a grant actuates over the real HTTP transport (proves the HTTP harness can actuate)",
        stimulus:
          "JSON-RPC message/send through A2A.Plug.Auth (bearer) + A2A.Plug with the victim's valid bearer token",
        boundary: "A2A.Plug.Auth -> AshA2A.Agent -> Grant.authorize/3 -> CommandBus",
        attempt_evidence: "authority.decision and brce.admission attributed to the stimulus",
        survival_evidence: "granted + admitted + committed; ledger row",
        attempt_predicate: H.reached_authority_and_admission(),
        outcome_predicate: H.granted_and_committed()
      ),
      negative(9,
        invariant:
          "TransportVerification ⇏ Authority: a bearer-verified identity with no grant cannot request consequence",
        stimulus:
          "JSON-RPC message/send through A2A.Plug.Auth (valid bearer) + A2A.Plug, skill actuate, no grant",
        guard: "Grant.authorize/3 broker decision on the transport-verified identity"
      ),
      negative(10,
        invariant:
          "AgentCardDeclaration ⇏ Authority (§57): dispatching the capability id the real agent card declares is refused without a grant",
        stimulus:
          "read the running ProbeAgent's card (GenServer :get_agent_card), dispatch its declared actuate skill id, no grant",
        guard: "Grant.authorize/3 keyed on the dispatched capability id"
      ),
      negative(11,
        invariant:
          "A caller-supplied capability name plus a self-computed grant token id is not authority (§57)",
        stimulus:
          "real ProbeAgent message naming actuate and carrying metadata authority {token_id: Authority.grant_token_id(principal, actuate)}, no grant",
        guard: "Grant.authorize/3 asks the broker; token ids are never bearer credentials"
      ),
      negative(12,
        invariant:
          "Unknown capability (§57): even a broker grant for a capability name the index does not declare cannot actuate anything",
        stimulus:
          "Grant.grant(principal, unknown) then CommandBus.run/4 of that unknown capability with the real Grant.authorize/3 authority",
        guard: "CommandBus.inspect_target/2 :capability_not_found before admission",
        attempt_evidence: "authority.decision and brce.target attributed to the stimulus",
        attempt_predicate:
          {:all, [{:observed, "authority.decision"}, {:observed, "brce.target"}]},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.admission", %{"outcome" => "admitted"}},
             {:observed, "brce.actuate.start"},
             {:observed, "dispatch.start"}
           ]},
        forbidden_outcome: "admission, actuation or any dispatch of the unknown capability"
      ),
      negative(13,
        invariant:
          "Composition does not raise the authority ceiling (§48, §57): executing an admitted composite's granted step does not authorize its ungranted step",
        stimulus:
          "principal granted mutate executes mutate, then dispatches actuate with continuation_fingerprint of the admitted [mutate, actuate] ExecutionPackage",
        guard: "Grant.authorize/3 per-capability decision; Planning candidate authority: :none"
      ),
      negative(14,
        invariant:
          "Confused deputy / token rebinding (§66): a valid bearer credential cannot be rebound to another principal's identity",
        stimulus:
          "JSON-RPC through A2A.Plug.Auth with the attacker's VALID bearer token and client params.metadata \"a2a.auth\" = {\"identity\": victim principal}; the victim holds the grant",
        guard:
          "AshA2A.Agent.verified_auth_identity/1 accepts only the atom-keyed identity A2A.Plug.Auth stores"
      ),
      negative(15,
        invariant:
          "Confused deputy / subject substitution (§66): a caller with no credential cannot substitute the subject of a granted principal",
        stimulus:
          "JSON-RPC through A2A.Plug alone (no transport auth wired) with client params.metadata \"a2a.auth\" = {\"identity\": victim principal}",
        guard:
          "AshA2A.Agent.verified_auth_identity/1 accepts only the atom-keyed identity A2A.Plug.Auth stores"
      ),
      negative(16,
        invariant:
          "A peer does not use its own authority merely because another peer requested the operation (§66)",
        stimulus:
          "deputy's real Grant.authorize/3 authority for actuate attached to the requesting peer's command, CommandBus.run/4",
        guard: "Authority.admits?/2 subject == command.principal_id",
        forbidden_outcome: "admission or actuation of the peer's command",
        outcome_predicate: H.admitted_or_actuated()
      ),
      negative(17,
        invariant:
          "Capability substitution (§66): a grant issued for the Probe agent's actuate capability must not authorize a different capability that merely shares its selector name",
        stimulus:
          "principal granted \"actuate\" (the Probe skill selector) sends skill actuate to the VaultAgent, whose actuate is a different capability",
        guard: "grant bound to the canonical capability identity actually dispatched"
      ),
      control(18,
        invariant:
          "A narrowing Bounds delegation is delegated: the delegation boundary discriminates (§100)",
        stimulus: "Bounds.delegate/2 of a [mutate, actuate] envelope narrowed to [mutate]",
        boundary: "AshA2A.Semantic.Bounds.delegate/2",
        attempt_evidence: "bounds.delegate attributed to the stimulus",
        survival_evidence: "bounds.delegate delegated; child capabilities == [mutate]",
        attempt_predicate: {:observed, "bounds.delegate"},
        outcome_predicate: {:observed, "bounds.delegate", %{"outcome" => "delegated"}}
      ),
      negative(19,
        invariant:
          "Delegated-envelope widening (§66, RFC-001 §73): a delegate cannot widen its envelope, and a widened envelope confers no authority",
        stimulus:
          "Bounds.delegate/2 of the [mutate] child asking for [mutate, actuate], then a ProbeAgent actuate dispatch carrying the hand-widened envelope, no grant",
        guard: "Bounds.narrowed_capabilities/2 + Grant.authorize/3",
        attempt_evidence:
          "bounds.delegate, authority.decision and brce.admission attributed to the stimulus",
        attempt_predicate:
          {:all,
           [
             {:observed, "bounds.delegate"},
             {:observed, "authority.decision"},
             {:observed, "brce.admission"}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "bounds.delegate", %{"outcome" => "delegated"}},
             {:observed, "authority.decision", %{"outcome" => "granted"}},
             {:observed, "brce.admission", %{"outcome" => "admitted"}},
             {:observed, "brce.actuate.start"}
           ]}
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
          boundary: "AshA2A.Authority.Grant.authorize/3 + AshA2A.CommandBus admission",
          forbidden_outcome:
            "authority.decision granted, brce.admission admitted or brce.actuate.start for the stimulus; a ledger row for its nonce",
          attempt_evidence: "authority.decision and brce.admission attributed to the stimulus",
          survival_evidence:
            "independent OCEL consumer observes the forbidden outcome, or Ash.read! finds the nonce's ledger row",
          failure_class: :authority_failure,
          rfc_sections: rfc_sections(),
          attempt_predicate: H.reached_authority_and_admission(),
          outcome_predicate: H.granted_admitted_or_actuated()
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
          rfc_sections: ["§100" | rfc_sections()]
        ],
        fields
      )
    )
  end

  defp fid(n), do: "#{@court}-#{String.pad_leading(Integer.to_string(n), 3, "0")}"

  # --- execution ------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    broker_name = :"#{inspect(__MODULE__)}.Broker#{System.unique_integer([:positive])}"
    {:ok, broker_pid} = InMemory.start_link(name: broker_name)
    Process.unlink(broker_pid)

    probe = H.start_agent(ProbeAgent)
    vault = H.start_agent(VaultAgent)
    env = %{ctx: ctx, fs: fs, probe: probe, vault: vault}

    try do
      H.with_broker({InMemory, name: broker_name}, fn ->
        victim = %{id: H.principal("transport-victim"), tenant: "chicago"}
        grant!(victim, "actuate")
        {r18, child} = delegation_control(env)

        [
          granted_control(env),
          zero_grant(env),
          per_capability(env)
        ]
        |> List.flatten()
        |> Kernel.++([
          task_without_grant(env),
          plan_without_grant(env),
          proof_without_grant(env),
          transport_control(env, victim),
          transport_without_grant(env),
          card_without_grant(env),
          caller_supplied_name(env),
          unknown_capability(env),
          composition(env),
          token_rebinding(env, victim),
          subject_substitution(env, victim),
          deputy(env),
          capability_substitution(env),
          r18,
          widening(env, child)
        ])
      end)
    after
      H.stop_agent(probe)
      H.stop_agent(vault)
      if Process.alive?(broker_pid), do: GenServer.stop(broker_pid, :normal)
    end
  end

  # SA2A-AUTH-001
  defp granted_control(%{ctx: ctx, fs: fs, probe: probe}) do
    f = fs[fid(1)]
    principal = H.principal("granted")
    grant!(principal, "actuate")
    nonce = H.nonce("auth-001")

    reply = Context.stimulus(ctx, f, fn -> call_probe(probe, principal, "actuate", nonce) end)
    positive(ctx, f, nonce, reply)
  end

  # SA2A-AUTH-002
  defp zero_grant(%{ctx: ctx, fs: fs, probe: probe}) do
    f = fs[fid(2)]
    principal = H.principal("zero-grant")
    nonce = H.nonce("auth-002")

    reply = Context.stimulus(ctx, f, fn -> call_probe(probe, principal, "actuate", nonce) end)
    negative_result(ctx, f, nonce, %{"task_state" => H.task_state(reply)})
  end

  # SA2A-AUTH-003 + SA2A-AUTH-004 (same principal: the control proves the grant stands)
  defp per_capability(%{ctx: ctx, fs: fs, probe: probe}) do
    principal = H.principal("capability-a")
    grant!(principal, "mutate")

    control = fs[fid(3)]
    control_nonce = H.nonce("auth-003")

    control_reply =
      Context.stimulus(ctx, control, fn ->
        call_probe(probe, principal, "mutate", control_nonce)
      end)

    attack = fs[fid(4)]
    nonce = H.nonce("auth-004")

    reply =
      Context.stimulus(ctx, attack, fn -> call_probe(probe, principal, "actuate", nonce) end)

    [
      positive(ctx, control, control_nonce, control_reply),
      negative_result(ctx, attack, nonce, %{
        "task_state" => H.task_state(reply),
        "grant_for_mutate_stands" => Grant.granted?(Identity.principal(principal), "mutate")
      })
    ]
  end

  # SA2A-AUTH-005
  defp task_without_grant(%{ctx: ctx, fs: fs, probe: probe}) do
    f = fs[fid(5)]
    principal = H.principal("task")

    # A real A2A task the real agent created for this principal (observe skill,
    # outside the stimulus window).
    {:ok, task} = call_probe_result(probe, principal, "peek", nil)
    nonce = H.nonce("auth-005")

    reply =
      Context.stimulus(ctx, f, fn ->
        command =
          Command.new("actuate",
            command_id: "chicago-auth-005-" <> nonce,
            agent_id: inspect(Probe),
            principal_id: Identity.principal(principal),
            task_id: Identity.task(task.id),
            authority: Grant.authorize(principal, "actuate"),
            input: %{"nonce" => nonce},
            metadata: %{"a2a_task_id" => task.id, "a2a_context_id" => task.context_id}
          )

        CommandBus.run(command, data_message(nonce), Probe)
      end)

    negative_result(ctx, f, nonce, %{
      "task_id" => task.id,
      "task_state" => to_string(task.status.state),
      "reply" => reply_code(reply)
    })
  end

  # SA2A-AUTH-006
  defp plan_without_grant(%{ctx: ctx, fs: fs, probe: probe}) do
    f = fs[fid(6)]
    principal = H.principal("plan")
    nonce = H.nonce("auth-006")
    {package, admitted} = plan_package([@probe_actuate], nonce)

    reply =
      Context.stimulus(ctx, f, fn ->
        call_probe(probe, principal, "actuate", nonce, %{
          "continuation_fingerprint" => package.fingerprint
        })
      end)

    negative_result(ctx, f, nonce, %{
      "task_state" => H.task_state(reply),
      "package_fingerprint" => package.fingerprint,
      "plan_standing" => to_string(admitted.standing),
      "plan_authority" => to_string(admitted.authority)
    })
  end

  # SA2A-AUTH-007
  defp proof_without_grant(%{ctx: ctx, fs: fs, probe: probe}) do
    f = fs[fid(7)]
    principal = H.principal("proof")
    nonce = H.nonce("auth-007")
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    payload = "sa2a-authority-request|#{principal}|actuate|#{nonce}"
    signature = :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
    verified = :crypto.verify(:eddsa, :none, payload, signature, [public, :ed25519])

    reply =
      Context.stimulus(ctx, f, fn ->
        call_probe(probe, principal, "actuate", nonce, %{
          "proof" => %{
            "alg" => "Ed25519",
            "payload" => payload,
            "signature" => Base.encode64(signature),
            "public_key" => Base.encode64(public)
          }
        })
      end)

    negative_result(ctx, f, nonce, %{
      "task_state" => H.task_state(reply),
      "proof_verified_by_court" => verified
    })
  end

  # SA2A-AUTH-008
  defp transport_control(%{ctx: ctx, fs: fs, probe: probe}, victim) do
    f = fs[fid(8)]
    token = "victim-" <> H.nonce("bearer")
    nonce = H.nonce("auth-008")

    http =
      Context.stimulus(ctx, f, fn ->
        H.http_send(probe, "actuate", %{"nonce" => nonce},
          tokens: %{token => victim},
          bearer: token
        )
      end)

    positive(ctx, f, nonce, nil, %{"http_status" => http.status, "task_state" => http.task_state})
  end

  # SA2A-AUTH-009
  defp transport_without_grant(%{ctx: ctx, fs: fs, probe: probe}) do
    f = fs[fid(9)]
    identity = %{id: H.principal("transport-nogrant"), tenant: "chicago"}
    token = "nogrant-" <> H.nonce("bearer")
    nonce = H.nonce("auth-009")

    http =
      Context.stimulus(ctx, f, fn ->
        H.http_send(probe, "actuate", %{"nonce" => nonce},
          tokens: %{token => identity},
          bearer: token
        )
      end)

    negative_result(ctx, f, nonce, %{
      "http_status" => http.status,
      "task_state" => http.task_state
    })
  end

  # SA2A-AUTH-010
  defp card_without_grant(%{ctx: ctx, fs: fs, probe: probe}) do
    f = fs[fid(10)]
    principal = H.principal("card")
    nonce = H.nonce("auth-010")
    card = GenServer.call(probe, :get_agent_card)

    declared =
      card.skills
      |> Enum.map(&to_string(&1.id))
      |> Enum.find(&String.ends_with?(&1, ".actuate"))

    reply = Context.stimulus(ctx, f, fn -> call_probe(probe, principal, declared, nonce) end)

    negative_result(ctx, f, nonce, %{
      "declared_skill_id" => declared,
      "card_skill_ids" => Enum.map_join(card.skills, ",", &to_string(&1.id)),
      "task_state" => H.task_state(reply)
    })
  end

  # SA2A-AUTH-011
  defp caller_supplied_name(%{ctx: ctx, fs: fs, probe: probe}) do
    f = fs[fid(11)]
    principal = H.principal("caller-named")
    nonce = H.nonce("auth-011")
    token = Authority.grant_token_id(Identity.principal(principal), "actuate")

    reply =
      Context.stimulus(ctx, f, fn ->
        call_probe(probe, principal, "actuate", nonce, %{
          "capability_id" => "actuate",
          "authority" => %{
            "token_id" => token,
            "subject" => principal,
            "capability_id" => "actuate",
            "source" => "transport_verified"
          }
        })
      end)

    negative_result(ctx, f, nonce, %{
      "task_state" => H.task_state(reply),
      "claimed_token" => token
    })
  end

  # SA2A-AUTH-012
  defp unknown_capability(%{ctx: ctx, fs: fs}) do
    f = fs[fid(12)]
    principal = H.principal("unknown")
    capability = "drop_every_ledger_row"
    grant!(principal, capability)
    nonce = H.nonce("auth-012")

    plan_refusal =
      case Planning.admit(
             Probe,
             Planning.Candidate.new(:chicago_authority_court, %{"nonce" => nonce}, [capability])
           ) do
        {:ok, _} -> "admitted"
        {:error, %{code: code}} -> to_string(code)
        {:error, reason} -> inspect(reason, limit: 8)
      end

    reply =
      Context.stimulus(ctx, f, fn ->
        command =
          Command.new(capability,
            command_id: "chicago-auth-012-" <> nonce,
            agent_id: inspect(Probe),
            principal_id: Identity.principal(principal),
            authority: Grant.authorize(principal, capability),
            input: %{"nonce" => nonce}
          )

        CommandBus.run(command, data_message(nonce), Probe)
      end)

    attempted = H.saw?(ctx, f, "authority.decision") and H.saw?(ctx, f, "brce.target")

    forbidden =
      H.saw?(ctx, f, "brce.admission", %{"outcome" => "admitted"}) or
        H.saw?(ctx, f, "brce.actuate.start") or H.saw?(ctx, f, "dispatch.start") or
        Fixtures.recorded?(nonce)

    Result.negative(f,
      attempt_observed?: attempted,
      forbidden_outcome_observed?: forbidden,
      evidence: %{
        "reply" => reply_code(reply),
        "unknown_capability_in_plan" => plan_refusal,
        "observed" => H.seen(ctx, f)
      }
    )
  end

  # SA2A-AUTH-013
  defp composition(%{ctx: ctx, fs: fs, probe: probe}) do
    f = fs[fid(13)]
    principal = H.principal("composer")
    grant!(principal, "mutate")
    step_nonce = H.nonce("auth-013-step")
    step = call_probe_result(probe, principal, "mutate", step_nonce)
    nonce = H.nonce("auth-013")
    {package, admitted} = plan_package([@probe_mutate, @probe_actuate], nonce)

    reply =
      Context.stimulus(ctx, f, fn ->
        call_probe(probe, principal, "actuate", nonce, %{
          "continuation_fingerprint" => package.fingerprint
        })
      end)

    negative_result(ctx, f, nonce, %{
      "task_state" => H.task_state(reply),
      "granted_step_state" => H.task_state(step),
      "granted_step_recorded" => Fixtures.recorded?(step_nonce),
      "composite_capabilities" => Enum.join(admitted.capability_ids, ","),
      "composite_authority" => to_string(admitted.authority)
    })
  end

  # SA2A-AUTH-014
  defp token_rebinding(%{ctx: ctx, fs: fs, probe: probe}, victim) do
    f = fs[fid(14)]
    attacker = %{id: H.principal("rebinding-attacker"), tenant: "chicago"}
    token = "attacker-" <> H.nonce("bearer")
    nonce = H.nonce("auth-014")
    victim_principal = Identity.principal(victim).value

    http =
      Context.stimulus(ctx, f, fn ->
        H.http_send(probe, "actuate", %{"nonce" => nonce},
          tokens: %{token => attacker},
          bearer: token,
          params_metadata: %{"a2a.auth" => %{"identity" => victim_principal}}
        )
      end)

    negative_result(ctx, f, nonce, %{
      "http_status" => http.status,
      "task_state" => http.task_state,
      "rebound_to" => victim_principal
    })
  end

  # SA2A-AUTH-015
  defp subject_substitution(%{ctx: ctx, fs: fs, probe: probe}, victim) do
    f = fs[fid(15)]
    nonce = H.nonce("auth-015")
    victim_principal = Identity.principal(victim).value

    http =
      Context.stimulus(ctx, f, fn ->
        H.http_send(probe, "actuate", %{"nonce" => nonce},
          params_metadata: %{"a2a.auth" => %{"identity" => victim_principal}}
        )
      end)

    negative_result(ctx, f, nonce, %{
      "http_status" => http.status,
      "task_state" => http.task_state,
      "substituted_subject" => victim_principal
    })
  end

  # SA2A-AUTH-016
  defp deputy(%{ctx: ctx, fs: fs}) do
    f = fs[fid(16)]
    deputy = H.principal("deputy")
    peer = H.principal("peer")
    grant!(deputy, "actuate")
    nonce = H.nonce("auth-016")

    reply =
      Context.stimulus(ctx, f, fn ->
        command =
          Command.new("actuate",
            command_id: "chicago-auth-016-" <> nonce,
            agent_id: inspect(Probe),
            principal_id: Identity.principal(peer),
            authority: Grant.authorize(deputy, "actuate"),
            input: %{"nonce" => nonce},
            metadata: %{"requested_by" => peer, "deputy" => deputy}
          )

        CommandBus.run(command, data_message(nonce), Probe)
      end)

    attempted = H.saw?(ctx, f, "authority.decision") and H.saw?(ctx, f, "brce.admission")

    forbidden =
      H.saw?(ctx, f, "brce.admission", %{"outcome" => "admitted"}) or
        H.saw?(ctx, f, "brce.actuate.start") or Fixtures.recorded?(nonce)

    Result.negative(f,
      attempt_observed?: attempted,
      forbidden_outcome_observed?: forbidden,
      evidence: %{"reply" => reply_code(reply), "observed" => H.seen(ctx, f)}
    )
  end

  # SA2A-AUTH-017
  defp capability_substitution(%{ctx: ctx, fs: fs, vault: vault}) do
    f = fs[fid(17)]
    principal = H.principal("substitution")
    grant!(principal, "actuate")
    nonce = H.nonce("auth-017")

    reply =
      Context.stimulus(ctx, f, fn ->
        H.agent_call(VaultAgent, vault, principal, %{"nonce" => nonce}, %{"skill" => "actuate"})
      end)

    negative_result(ctx, f, nonce, %{
      "task_state" => H.task_state(reply),
      "granted_selector" => "actuate",
      "dispatched_capability" => "AshA2A.Chicago.Fixtures.Authority.Vault.actuate",
      "ledger_capabilities" => nonce |> Fixtures.rows() |> Enum.map_join(",", & &1.capability)
    })
  end

  # SA2A-AUTH-018
  defp delegation_control(%{ctx: ctx, fs: fs}) do
    f = fs[fid(18)]

    {:ok, parent} =
      Bounds.new(
        fan_out: 2,
        depth: 2,
        parallelism: 1,
        resources: %{calls: 4},
        capabilities: [@probe_mutate, @probe_actuate]
      )

    result =
      Context.stimulus(ctx, f, fn ->
        Bounds.delegate(parent, capabilities: [@probe_mutate], resources: %{calls: 1})
      end)

    {child, delegated?} =
      case result do
        {:ok, %{child: child}} ->
          {child, MapSet.equal?(child.capabilities, MapSet.new([@probe_mutate]))}

        _ ->
          {nil, false}
      end

    r =
      Result.positive(f,
        attempt_observed?: H.saw?(ctx, f, "bounds.delegate"),
        expected_outcome_observed?:
          delegated? and H.saw?(ctx, f, "bounds.delegate", %{"outcome" => "delegated"}),
        evidence: %{"observed" => H.seen(ctx, f)}
      )

    {r, child}
  end

  # SA2A-AUTH-019
  defp widening(%{ctx: ctx, fs: fs, probe: probe}, child) do
    f = fs[fid(19)]
    deputy = H.principal("delegating-deputy")
    delegate = H.principal("delegate")
    grant!(deputy, "actuate")
    nonce = H.nonce("auth-019")

    child =
      child ||
        with {:ok, parent} <-
               Bounds.new(
                 fan_out: 2,
                 depth: 2,
                 parallelism: 1,
                 capabilities: [@probe_mutate, @probe_actuate]
               ),
             {:ok, %{child: child}} <- Bounds.delegate(parent, capabilities: [@probe_mutate]) do
          child
        end

    {widened, reply} =
      Context.stimulus(ctx, f, fn ->
        widened = Bounds.delegate(child, capabilities: [@probe_mutate, @probe_actuate])
        forged = %{child | capabilities: MapSet.new([@probe_mutate, @probe_actuate])}

        reply =
          call_probe(probe, delegate, "actuate", nonce, %{
            "delegated_by" => deputy,
            "bounds" => %{
              "capabilities" => Enum.sort(forged.capabilities),
              "depth" => forged.depth,
              "fan_out" => forged.fan_out
            }
          })

        {widened, reply}
      end)

    attempted =
      H.saw?(ctx, f, "bounds.delegate") and H.saw?(ctx, f, "authority.decision") and
        H.saw?(ctx, f, "brce.admission")

    forbidden =
      match?({:ok, _}, widened) or Fixtures.recorded?(nonce) or
        H.saw?(ctx, f, "bounds.delegate", %{"outcome" => "delegated"}) or
        H.saw?(ctx, f, "authority.decision", %{"outcome" => "granted"}) or
        H.saw?(ctx, f, "brce.admission", %{"outcome" => "admitted"}) or
        H.saw?(ctx, f, "brce.actuate.start")

    Result.negative(f,
      attempt_observed?: attempted,
      forbidden_outcome_observed?: forbidden,
      evidence: %{
        "widening" => reply_code(widened),
        "task_state" => H.task_state(reply),
        "observed" => H.seen(ctx, f)
      }
    )
  end

  # --- helpers ------------------------------------------------------------------------

  defp grant!(identity, capability_id) do
    subject = Identity.principal(identity)

    case Grant.grant(subject, capability_id) do
      {:ok, %Authority{}} -> :ok
      {:error, %{reason: :token_id_taken}} -> :ok
    end
  end

  defp call_probe(probe, principal, skill, nonce, extra \\ %{}) do
    H.agent_call(ProbeAgent, probe, principal, nonce_data(nonce), Map.put(extra, "skill", skill))
  end

  defp call_probe_result(probe, principal, skill, nonce),
    do: call_probe(probe, principal, skill, nonce)

  defp nonce_data(nil), do: %{}
  defp nonce_data(nonce), do: %{"nonce" => nonce}

  defp data_message(nonce), do: A2A.Message.new_user([A2A.Part.Data.new(%{"nonce" => nonce})])

  defp reply_code({:ok, %{status: status}}), do: "ok:#{status}"
  defp reply_code({:ok, _}), do: "ok"
  defp reply_code({:error, %{code: code}}), do: "error:#{code}"
  defp reply_code(other), do: inspect(other, limit: 8)

  defp positive(ctx, f, nonce, reply, extra \\ %{}) do
    Result.positive(f,
      attempt_observed?:
        H.saw?(ctx, f, "authority.decision") and H.saw?(ctx, f, "brce.admission"),
      expected_outcome_observed?:
        Fixtures.recorded?(nonce) and
          H.saw?(ctx, f, "authority.decision", %{"outcome" => "granted"}) and
          H.saw?(ctx, f, "brce.commit", %{"outcome" => "committed"}),
      evidence:
        Map.merge(
          %{"task_state" => H.task_state(reply), "observed" => H.seen(ctx, f)},
          extra
        )
    )
  end

  defp negative_result(ctx, f, nonce, evidence) do
    Result.negative(f,
      attempt_observed?:
        H.saw?(ctx, f, "authority.decision") and H.saw?(ctx, f, "brce.admission"),
      forbidden_outcome_observed?:
        Fixtures.recorded?(nonce) or
          H.saw?(ctx, f, "authority.decision", %{"outcome" => "granted"}) or
          H.saw?(ctx, f, "brce.admission", %{"outcome" => "admitted"}) or
          H.saw?(ctx, f, "brce.actuate.start"),
      evidence: Map.merge(%{"observed" => H.seen(ctx, f)}, evidence)
    )
  end

  defp plan_package(capability_ids, label) do
    text = "Chicago authority court #{label}: the agent shall actuate the authority probe."
    source = Source.new(text)

    ir = %IR{
      source_id: source.id,
      standing: :admitted,
      authority: :none,
      goals: [
        %{
          "id" => "goal-1",
          "kind" => "goal",
          "description" => "Actuate the authority probe",
          "source_quote" => text
        }
      ]
    }

    {:ok, ontology} = Ontology.from_ir(ir)
    {:ok, planning_ir} = PlanningIR.from_ir(ir, ontology)

    candidate =
      Planning.Candidate.new(
        :chicago_authority_court,
        %{"label" => label, "capability_ids" => capability_ids},
        capability_ids,
        formalism: :hddl_fond
      )

    {:ok, admitted} = Planning.admit(Probe, candidate)
    {:ok, package} = ExecutionPackage.new(source, ir, ontology, planning_ir, admitted)
    {package, admitted}
  end
end
