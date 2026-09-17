defmodule AshA2A.Chicago.Courts.TransportIndependence do
  @moduledoc """
  RFC-SA2A-002 §75 Transport Independence Court (`SA2A-TRANSPORT`).

  Two REAL A2A bindings front the same real agent processes:

    * **in-process** -- `A2A.call/3` into the real `A2A.Agent` GenServer;
    * **HTTP JSON-RPC** -- the real `A2A.Client` (Req/Finch) posting
      `message/send` to a real Bandit listener on 127.0.0.1 serving the real,
      unmodified `A2A.Plug` (behind the real `A2A.Plug.Auth` for the
      consequence-bearing agent).

  Semantically equivalent envelopes must produce equal admitted semantic
  outcomes over both bindings, and transport metadata -- HTTP headers,
  message ids, JSON-RPC `params.metadata` -- must not alter meaning or
  authority (RFC-SA2A-001 S51, RFC-SA2A-002 §75).

  Equality is asked of the OCEL evidence object-centrically: every peer
  decision relates to a `sa2a_outcome` object whose id is a digest of
  `(envelope_id, standing, code, graph_digest)`, so N lawful outcomes over
  both bindings relate to exactly N distinct outcome objects
  (`{:distinct_objects, ...}`). The HTTP binding's own attempt evidence is
  Bandit's `[:bandit, :request, :start]`; authority evidence is the real
  `AshA2A.CommandBus` boundary telemetry plus an independent `Ash.read!/1`
  of the real ETS table.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.SemanticBoundary, as: SB
  alias AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport, as: Fx

  alias AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.{
    Envelopes,
    Graphs,
    Http,
    Ordering,
    OrderingAgent
  }

  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Identity
  alias AshA2A.Semantic.{Extension, GraphLaw}

  @court "SA2A-TRANSPORT"
  @receive "sa2a.transport.receive"
  @decision "sa2a.transport.decision"
  @http "sa2a.transport.http.request"
  @capability "place_order"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Transport Independence Court"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§75", "§100"]

  @impl true
  def ocel_mappings do
    SB.peer_mappings("sa2a.transport", __MODULE__) ++
      [
        Mapping.new!(
          event: [:bandit, :request, :start],
          activity: @http,
          source: __MODULE__
        )
      ]
  end

  @impl true
  def falsifiers do
    [
      Falsifier.new!(
        id: "#{@court}-001",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "The same admissible envelope over the in-process binding and over real HTTP JSON-RPC is admitted to the same semantic outcome",
        stimulus:
          "one activated admissible message sent via A2A.call/3 and via A2A.Client.send_message/3 to a real Bandit + A2A.Plug listener",
        boundary: "AshA2A.Semantic.Peer.receive_message/3 behind both bindings",
        attempt_evidence: ">=2 #{@receive} and a Bandit request",
        survival_evidence: "2 admitted #{@decision} relating to exactly one sa2a_outcome object",
        rfc_sections: ["§75", "§100"],
        attempt_predicate: {:all, [{:count, @receive, :gte, 2}, {:observed, @http}]},
        outcome_predicate:
          {:all,
           [
             {:count, @decision, :eq, 2},
             {:observed, @decision, %{"standing" => "admitted"}},
             {:distinct_objects, @decision, "sa2a_outcome", :eq, 1}
           ]}
      ),
      Falsifier.new!(
        id: "#{@court}-002",
        court_id: @court,
        kind: :negative,
        invariant: "Refusal outcomes do not diverge across bindings",
        stimulus:
          "a SHACL-violating envelope and a self-declared-standing envelope, each sent over both bindings",
        boundary: "AshA2A.Semantic.Peer.receive_message/3 behind both bindings",
        forbidden_outcome: "any admission, or more distinct outcomes than distinct envelopes (2)",
        attempt_evidence: ">=4 #{@receive} and a Bandit request",
        survival_evidence: "#{@decision} admitted, or >=3 distinct sa2a_outcome objects",
        guard: "binding-independent Peer admission (no transport input reaches the decision)",
        failure_class: :cross_runtime_divergence,
        rfc_sections: ["§75"],
        attempt_predicate: {:all, [{:count, @receive, :gte, 4}, {:observed, @http}]},
        outcome_predicate:
          {:any,
           [
             {:observed, @decision, %{"standing" => "admitted"}},
             {:distinct_objects, @decision, "sa2a_outcome", :gte, 3}
           ]}
      ),
      Falsifier.new!(
        id: "#{@court}-003",
        court_id: @court,
        kind: :negative,
        invariant:
          "Transport metadata (HTTP headers, message ids, JSON-RPC params.metadata) cannot alter semantic meaning",
        stimulus:
          "baseline in-process sends of an admissible envelope M and an ordinary message N; then over HTTP: M with forged x-a2a-extensions/x-sa2a-* headers and params.metadata carrying a SHACL-violating sa2a payload, M under a fresh message id, and N with an SA2A activation header and an admissible sa2a payload in params.metadata",
        boundary: "A2A.Plug -> A2A.Agent -> AshA2A.Semantic.Peer",
        forbidden_outcome: "a third distinct semantic outcome (M and N have exactly one each)",
        attempt_evidence: ">=5 #{@receive} and a Bandit request",
        survival_evidence: ">=3 distinct sa2a_outcome objects related to #{@decision}",
        guard: "Peer reads meaning only from message.extensions, never from transport metadata",
        failure_class: :cross_runtime_divergence,
        rfc_sections: ["§75"],
        attempt_predicate: {:all, [{:count, @receive, :gte, 5}, {:observed, @http}]},
        outcome_predicate: {:distinct_objects, @decision, "sa2a_outcome", :gte, 3}
      ),
      Falsifier.new!(
        id: "#{@court}-004",
        court_id: @court,
        kind: :negative,
        invariant:
          "Transport metadata cannot alter authority: JSON-RPC params.metadata cannot impersonate the transport-verified identity",
        stimulus:
          "an authenticated, ungranted caller posts place_order over real HTTP with params.metadata[\"a2a.auth\"] naming a principal that holds a real grant",
        boundary:
          "A2A.Plug metadata merge -> AshA2A.Agent verified identity -> Authority.Grant -> CommandBus admission",
        forbidden_outcome: "CommandBus admission admitted, actuation, or the order row created",
        attempt_evidence: "brce.admission and a Bandit request attributed to the stimulus",
        survival_evidence:
          "brce.admission outcome=admitted or brce.actuate.start; the item visible to an independent Ash.read!",
        guard:
          "AshA2A.Agent.verified_auth_identity/1 accepts only the A2A.Plug.Auth identity shape",
        failure_class: :authority_failure,
        rfc_sections: ["§75", "§29"],
        attempt_predicate: {:all, [{:observed, "brce.admission"}, {:observed, @http}]},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.admission", %{"outcome" => "admitted"}},
             {:observed, "brce.actuate.start"}
           ]}
      ),
      Falsifier.new!(
        id: "#{@court}-005",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "A really granted principal is admitted over both bindings -- the authority boundary discriminates and does not depend on the binding",
        stimulus:
          "place_order in-process with the A2A.Plug.Auth identity shape, and over real HTTP with the principal's real bearer credential",
        boundary: "AshA2A.Agent -> Authority.Grant -> AshA2A.CommandBus",
        attempt_evidence: "2 brce.admission and a Bandit request",
        survival_evidence:
          "2 admitted admissions, 2 actuations, a committed receipt; both items visible to an independent Ash.read!",
        rfc_sections: ["§75", "§100"],
        attempt_predicate: {:all, [{:count, "brce.admission", :gte, 2}, {:observed, @http}]},
        outcome_predicate:
          {:all,
           [
             {:count, "brce.admission", :eq, 2},
             {:not_observed, "brce.admission", %{"outcome" => "refused"}},
             {:count, "brce.actuate.stop", :eq, 2},
             {:observed, "brce.commit", %{"outcome" => "committed"}}
           ]}
      )
    ]
  end

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = &Map.fetch!(fs, "#{@court}-#{&1}")

    if Http.bandit_available?() do
      semantic =
        if Fx.engine_available?() do
          semantic_bindings(ctx, f)
        else
          for n <- ~w(001 002 003),
              do: Result.blocked(f.(n), "the real praxis-graphlaw engine is unreachable")
        end

      semantic ++ authority_bindings(ctx, f)
    else
      Enum.map(falsifiers(), &Result.blocked(&1, "no real Bandit listener in this runtime"))
    end
  end

  # --- semantic meaning over both bindings -------------------------------------

  defp semantic_bindings(ctx, f) do
    {:ok, digest} = GraphLaw.graph_hash(Graphs.conforming())
    {:ok, bad_digest} = GraphLaw.graph_hash(Graphs.nonconforming())

    SB.with_peer(
      "transport",
      fn agent, ledger ->
        [
          name: "chicago-transport-peer",
          ledger: ledger,
          shapes: Graphs.shapes(),
          mode: :strict,
          agent_card: SB.served_card!(agent, :compatible)
        ]
      end,
      fn peer ->
        with_listener([agent: peer.agent, advertise: :compatible], fn url ->
          [
            equivalence(ctx, f.("001"), peer, url, digest),
            refusal_divergence(ctx, f.("002"), peer, url, digest, bad_digest),
            metadata_meaning(ctx, f.("003"), peer, url, digest, bad_digest)
          ]
        end)
      end
    )
  end

  defp equivalence(ctx, f, peer, url, digest) do
    message = Envelopes.activated(Envelopes.admissible(Graphs.conforming(), digest))

    {local, remote} =
      Context.stimulus(ctx, f, fn ->
        {SB.call(peer.agent, message), client_send(url, message)}
      end)

    Result.positive(f,
      attempt_observed?: receives(ctx, f) >= 2 and SB.observed?(ctx, f, @http),
      expected_outcome_observed?:
        match?(%{"standing" => "admitted"}, local) and local == remote and
          length(SB.observed(ctx, f, @decision)) == 2 and distinct_outcomes(ctx, f) == 1,
      evidence: %{"in_process" => SB.evidence(local), "http" => SB.evidence(remote)}
    )
  end

  defp refusal_divergence(ctx, f, peer, url, digest, bad_digest) do
    shacl_violation =
      Envelopes.activated(Envelopes.admissible(Graphs.nonconforming(), bad_digest))

    self_declared =
      Envelopes.activated(
        Envelopes.admissible(Graphs.conforming(), digest, %{"standing" => "admitted"})
      )

    pairs =
      Context.stimulus(ctx, f, fn ->
        for message <- [shacl_violation, self_declared] do
          {SB.call(peer.agent, message), client_send(url, message)}
        end
      end)

    Result.negative(f,
      attempt_observed?: receives(ctx, f) >= 4 and SB.observed?(ctx, f, @http),
      forbidden_outcome_observed?:
        Enum.any?(pairs, fn {a, b} -> a != b end) or distinct_outcomes(ctx, f) >= 3 or
          SB.observed?(ctx, f, @decision, %{"standing" => "admitted"}),
      evidence: %{
        "pairs" => Enum.map(pairs, fn {a, b} -> [SB.evidence(a), SB.evidence(b)] end)
      }
    )
  end

  defp metadata_meaning(ctx, f, peer, url, digest, bad_digest) do
    admissible = Envelopes.admissible(Graphs.conforming(), digest)
    forged = Envelopes.admissible(Graphs.nonconforming(), bad_digest)
    m = Envelopes.activated(admissible)
    n = Envelopes.ordinary("place an order for 3 widgets")

    replies =
      Context.stimulus(ctx, f, fn ->
        %{
          m_local: SB.call(peer.agent, m),
          n_local: SB.call(peer.agent, n),
          m_forged_transport:
            client_send(url, m,
              headers: [
                {"x-a2a-extensions", "urn:sa2a:profile:v99.0.0"},
                {"x-sa2a-standing", "refused"},
                {"x-sa2a-profile", "SA2A-PROFILE-v25.1.0"}
              ],
              metadata: %{
                "sa2a" => forged,
                "standing" => "refused",
                "profile" => "SA2A-PROFILE-v25.1.0",
                "consequenceBearing" => true
              }
            ),
          m_fresh_message_id: client_send(url, %{m | message_id: A2A.ID.generate("msg")}),
          n_activation_attempt:
            client_send(url, n,
              headers: [{"x-a2a-extensions", Extension.profile_id()}],
              metadata: %{
                "sa2a" => admissible,
                "extensions" => %{Extension.extension_key() => admissible}
              }
            )
        }
      end)

    meaning_changed? =
      replies.m_forged_transport != replies.m_local or
        replies.m_fresh_message_id != replies.m_local or
        replies.n_activation_attempt != replies.n_local

    Result.negative(f,
      attempt_observed?: receives(ctx, f) >= 5 and SB.observed?(ctx, f, @http),
      forbidden_outcome_observed?: meaning_changed? or distinct_outcomes(ctx, f) >= 3,
      evidence: Map.new(replies, fn {k, v} -> {Atom.to_string(k), SB.evidence(v)} end)
    )
  end

  # --- authority over both bindings ------------------------------------------

  defp authority_bindings(ctx, f) do
    granted = Fx.unique("chicago-transport-granted")
    attacker = Fx.unique("chicago-transport-attacker")
    granted_token = Fx.unique("granted-token")
    attacker_token = Fx.unique("attacker-token")

    case issue_grant(granted) do
      :ok ->
        ordering = :"chicago_transport_ordering_#{System.unique_integer([:positive])}"
        {:ok, pid} = OrderingAgent.start_link(name: ordering)

        try do
          tokens = %{granted_token => granted, attacker_token => attacker}

          with_listener([agent: ordering, tokens: tokens], fn url ->
            [
              impersonation(ctx, f.("004"), url, attacker_token, granted),
              authority_equivalence(ctx, f.("005"), ordering, url, granted_token, granted)
            ]
          end)
        after
          SB.stop(pid)
        end

      {:blocked, detail} ->
        [Result.blocked(f.("004"), detail), Result.blocked(f.("005"), detail)]
    end
  end

  defp impersonation(ctx, f, url, attacker_token, granted) do
    item = Fx.unique("chicago-transport-impersonation")
    forged_auth = %{"identity" => granted, "scheme" => "bearer_auth"}

    message =
      Envelopes.ordinary([A2A.Part.Data.new(%{"item" => item, "quantity" => 1})], %{
        "skill" => @capability,
        "a2a.auth" => forged_auth
      })

    reply =
      Context.stimulus(ctx, f, fn ->
        A2A.Client.send_message(url, message,
          headers: [{"authorization", "Bearer " <> attacker_token}],
          metadata: %{"a2a.auth" => forged_auth}
        )
      end)

    Result.negative(f,
      attempt_observed?: SB.observed?(ctx, f, "brce.admission") and SB.observed?(ctx, f, @http),
      forbidden_outcome_observed?:
        SB.observed?(ctx, f, "brce.admission", %{"outcome" => "admitted"}) or
          SB.observed?(ctx, f, "brce.actuate.start") or item in items(),
      evidence: %{
        "reply" => inspect(reply, limit: 12),
        "admission" => admissions(ctx, f),
        "item_present" => item in items()
      }
    )
  end

  defp authority_equivalence(ctx, f, ordering, url, granted_token, granted) do
    local_item = Fx.unique("chicago-transport-local")
    http_item = Fx.unique("chicago-transport-http")

    order = fn item ->
      Envelopes.ordinary([A2A.Part.Data.new(%{"item" => item, "quantity" => 1})], %{
        "skill" => @capability
      })
    end

    {local, remote} =
      Context.stimulus(ctx, f, fn ->
        {
          A2A.call(ordering, order.(local_item),
            metadata: %{"a2a.auth" => %{identity: granted, scheme: "bearer_auth"}}
          ),
          A2A.Client.send_message(url, order.(http_item),
            headers: [{"authorization", "Bearer " <> granted_token}]
          )
        }
      end)

    present = items()

    Result.positive(f,
      attempt_observed?:
        length(SB.observed(ctx, f, "brce.admission")) >= 2 and SB.observed?(ctx, f, @http),
      expected_outcome_observed?:
        local_item in present and http_item in present and
          not SB.observed?(ctx, f, "brce.admission", %{"outcome" => "refused"}),
      evidence: %{
        "in_process" => inspect(local, limit: 8),
        "http" => inspect(remote, limit: 8),
        "admission" => admissions(ctx, f)
      }
    )
  end

  # --- helpers ---------------------------------------------------------------

  # SA2A-AUTH-017 (RFC-SA2A-002 S66): `AshA2A.Agent.build_command/4` now
  # resolves the dispatched skill's canonical capability id
  # (`AshA2A.Info.skill/2`) before calling `Grant.authorize/3`, so the
  # standing grant this court issues for the real `Ordering.place_order`
  # dispatch must be keyed on that same canonical id, not `@capability`'s
  # bare wire selector (still used, unchanged, for the message `"skill"`
  # metadata below).
  defp capability_id do
    {:ok, skill} = AshA2A.Info.skill(Ordering, @capability)
    skill.id
  end

  defp issue_grant(principal) do
    subject = Identity.principal(principal)
    _ = Grant.grant(subject, capability_id())

    if Grant.authorize(principal, capability_id()),
      do: :ok,
      else: {:blocked, "no real authority broker grant could be issued for #{principal}"}
  catch
    kind, reason ->
      {:blocked, "authority broker unavailable: #{kind} #{inspect(reason, limit: 8)}"}
  end

  defp with_listener(endpoint_opts, fun) do
    {:ok, listener} = Http.start_listener(endpoint_opts)

    try do
      fun.(listener.url)
    after
      Http.stop_listener(listener)
    end
  end

  defp client_send(url, message, opts \\ []) do
    case A2A.Client.send_message(url, message, opts) do
      {:ok, task} -> Http.reply_data(task) || %{"task_state" => to_string(task.status.state)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp receives(ctx, f), do: length(SB.observed(ctx, f, @receive))

  defp distinct_outcomes(ctx, f) do
    ctx
    |> SB.observed(f, @decision)
    |> Enum.flat_map(fn record ->
      for {"sa2a_outcome", id, _q} <- record.objects, do: id
    end)
    |> Enum.uniq()
    |> length()
  end

  defp admissions(ctx, f) do
    ctx
    |> SB.observed(f, "brce.admission")
    |> Enum.map(&"#{&1.attributes["outcome"]}:#{&1.attributes["code"]}")
  end

  defp items, do: Ordering |> Ash.read!() |> Enum.map(& &1.item)
end
