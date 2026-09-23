defmodule AshA2A.Chicago.Courts.ExtensionNegotiation do
  @moduledoc """
  RFC-SA2A-002 §55 Extension Negotiation Court and §56 Downgrade Prevention
  Court (`SA2A-NEG`).

  Every card in this court is the card the real, unmodified `A2A.Plug`
  actually serves for a real `A2A.Agent` process (decoded with the real
  `A2A.JSON`), every negotiation is the real
  `AshA2A.Semantic.Extension.negotiate/2`, and every message crosses the real
  `AshA2A.Semantic.Peer` boundary in a real agent GenServer -- in-process via
  `A2A.call/3`, or as a real JSON-RPC `message/send` through the real
  `A2A.Plug` pipeline where the attack is a remote peer.

  Silent profile assumption fails this court (§55): ordinary A2A traffic
  presented as semantic, an incompatible profile version (on the card and on
  the envelope), a missing advertisement (on the remote card and on the
  receiving peer's own card), and a consequence-bearing task without the
  negotiated profile. §56: a strict peer facing a remote that does not support
  the profile yields a typed refusal/UNSUPPORTED outcome, never a hidden
  fallback to ordinary A2A. Two positive controls prove discrimination (§100).
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.SemanticBoundary, as: SB
  alias AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport, as: Fx

  alias AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.{
    Catalog,
    Envelopes,
    Graphs,
    Http,
    Ordering,
    SemanticPeerAgent
  }

  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Semantic.{Extension, GraphLaw}

  @court "SA2A-NEG"
  @receive "sa2a.neg.receive"
  @admission "sa2a.neg.admission.start"
  @decision "sa2a.neg.decision"
  @negotiate "sa2a.neg.negotiate"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Extension Negotiation and Downgrade Prevention Court"
  @impl true
  def gate, do: 2
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§55", "§56", "§100", "§101"]

  @impl true
  def ocel_mappings do
    SB.peer_mappings("sa2a.neg", __MODULE__) ++
      [
        Mapping.new!(
          event: [:ash_a2a, :semantic, :extension, :negotiate],
          activity: @negotiate,
          source: __MODULE__,
          objects: fn _m, meta -> [{"sa2a_profile", meta[:profile_id], "profile"}] end,
          attributes: fn _m, meta ->
            Map.take(meta, [:outcome, :code, :local_advertised, :remote_advertised])
          end
        )
      ]
  end

  @admitted {:observed, @decision, %{"standing" => "admitted"}}
  @ordinary {:observed, @receive, %{"activated" => "false"}}
  @actuation [{:observed, "brce.actuate.start"}, {:observed, "dispatch.start"}]

  @impl true
  def falsifiers do
    [
      negative("001",
        invariant:
          "Ordinary A2A traffic presented as Semantic A2A never enters the semantic path",
        stimulus:
          "real A2A.call/3 of a NON-activated message carrying a complete envelope as a DataPart, as text, and under metadata sa2a/profile keys",
        boundary: "Extension.activated?/1 inside Peer.receive_message/3",
        forbidden_outcome: "semantic admission started or standing :admitted",
        attempt: @ordinary,
        guard: "Extension.activated?/1 (no content sniffing)",
        class: :admission_failure,
        forbidden: {:any, [{:observed, @admission}, @admitted]}
      ),
      negative("002",
        invariant: "A remote card advertising an incompatible profile version does not negotiate",
        stimulus:
          "negotiate/2 against the card A2A.Plug serves for a remote advertising SA2A-PROFILE-v26.9.20 at protocolVersion v25.1.0",
        boundary: "AshA2A.Semantic.Extension.negotiate/2",
        forbidden_outcome: "negotiation outcome :ok",
        attempt: {:observed, @negotiate},
        guard: "Extension.advertised?/1 profile-version check",
        class: :admission_failure,
        forbidden: {:observed, @negotiate, %{"outcome" => "ok"}}
      ),
      negative("003",
        invariant: "An envelope declaring an incompatible profile version is not admitted",
        stimulus:
          "real A2A.call/3 of an activated admissible envelope declaring urn:sa2a:profile:core:v25.1.0",
        boundary: "Peer.receive_message/3 + Envelope.validate_profile/1",
        forbidden_outcome: "semantic admission started or standing :admitted",
        attempt: {:observed, @receive, %{"activated" => "true"}},
        guard: "Envelope.validate_profile/1 known-profile set",
        class: :admission_failure,
        forbidden: {:any, [{:observed, @admission}, @admitted]}
      ),
      negative("004",
        invariant: "A remote card without the SA2A advertisement does not negotiate",
        stimulus: "negotiate/2 against the card A2A.Plug serves for a non-advertising remote",
        boundary: "AshA2A.Semantic.Extension.negotiate/2",
        forbidden_outcome: "negotiation outcome :ok",
        attempt: {:observed, @negotiate},
        guard: "Extension.negotiate/2 two-sided advertisement requirement",
        class: :admission_failure,
        forbidden: {:observed, @negotiate, %{"outcome" => "ok"}}
      ),
      negative("005",
        invariant:
          "A receiving peer whose own served card does not advertise SA2A never lets semantic standing cross its boundary",
        stimulus:
          "real A2A.call/3 of an activated, fully admissible envelope to a peer configured with the non-advertising card its A2A.Plug serves",
        boundary: "Peer.receive_message/3 own-advertisement check",
        forbidden_outcome: "semantic admission started or standing :admitted",
        attempt: {:observed, @receive, %{"activated" => "true"}},
        guard: "Peer.receive_message/3 Extension.advertised?(peer.agent_card) check",
        class: :admission_failure,
        forbidden: {:any, [{:observed, @admission}, @admitted]}
      ),
      negative("006",
        invariant:
          "A consequence-bearing task without the negotiated profile is refused as UNSUPPORTED_PROFILE even when the counterparty labels it harmless",
        stimulus:
          "real A2A.call/3 of a non-activated message naming the real :change capability place_order with metadata consequenceBearing=false",
        boundary: "Peer.bridge_path/2 + Peer.consequence_bearing?/2 (local capability DSL)",
        forbidden_outcome:
          "silent ordinary-A2A handling (code profile_not_negotiated), admission, or actuation",
        attempt: @ordinary,
        guard: "Peer.consequence_bearing?/2 reads the local DSL, never message metadata",
        class: :authority_failure,
        forbidden:
          {:any,
           [
             {:observed, @decision, %{"code" => "profile_not_negotiated"}},
             {:observed, @admission},
             @admitted
             | @actuation
           ]}
      ),
      negative("007",
        invariant:
          "§56: a Strict peer facing a remote without the required profile never silently downgrades a consequence-bearing interaction to ordinary A2A",
        stimulus:
          "strict peer negotiates against the non-advertising remote's served card, then the remote sends the consequence-bearing task as ordinary JSON-RPC message/send through the real A2A.Plug",
        boundary: "Extension.negotiate/2 then Peer.bridge_path/2 strict clause",
        forbidden_outcome:
          "negotiation :ok, hidden fallback (code profile_not_negotiated), standing :admitted, or actuation",
        attempt: {:all, [{:observed, @negotiate}, @ordinary]},
        guard: "Peer.bridge_path/2 strict + consequence-bearing => :unsupported_profile",
        class: :authority_failure,
        forbidden:
          {:any,
           [
             {:observed, @negotiate, %{"outcome" => "ok"}},
             {:observed, @decision, %{"code" => "profile_not_negotiated"}},
             @admitted
             | @actuation
           ]}
      ),
      control("008",
        invariant:
          "Two peers whose served cards both advertise the compatible profile negotiate, and an admissible envelope over real JSON-RPC is admitted",
        stimulus:
          "negotiate/2 over both served cards, then an activated admissible envelope as JSON-RPC message/send through the real A2A.Plug",
        boundary: "Extension.negotiate/2 + Peer.receive_message/3",
        attempt:
          {:all, [{:observed, @negotiate}, {:observed, @receive, %{"activated" => "true"}}]},
        expected: {:all, [{:observed, @negotiate, %{"outcome" => "ok"}}, @admitted]}
      ),
      control("009",
        invariant:
          "A strict peer still answers a NON-consequence-bearing ordinary request, typed profile_not_negotiated (UNSUPPORTED, not REFUSED) -- the §76 guard discriminates",
        stimulus:
          "real A2A.call/3 of an ordinary message to a strict peer whose only capability is an observation",
        boundary: "Peer.bridge_path/2",
        attempt: @ordinary,
        expected:
          {:all,
           [
             {:observed, @decision,
              %{"standing" => "unsupported", "code" => "profile_not_negotiated"}},
             {:not_observed, @decision, %{"standing" => "refused"}}
           ]}
      )
    ]
  end

  defp negative(n, opts) do
    Falsifier.new!(
      id: "#{@court}-#{n}",
      court_id: @court,
      kind: :negative,
      invariant: opts[:invariant],
      stimulus: opts[:stimulus],
      boundary: opts[:boundary],
      forbidden_outcome: opts[:forbidden_outcome],
      attempt_evidence: "boundary telemetry #{inspect(opts[:attempt])}",
      survival_evidence: "boundary telemetry #{inspect(opts[:forbidden])}",
      guard: opts[:guard],
      failure_class: opts[:class],
      rfc_sections: ["§55", "§56"],
      attempt_predicate: opts[:attempt],
      outcome_predicate: opts[:forbidden]
    )
  end

  defp control(n, opts) do
    Falsifier.new!(
      id: "#{@court}-#{n}",
      court_id: @court,
      kind: :positive_control,
      invariant: opts[:invariant],
      stimulus: opts[:stimulus],
      boundary: opts[:boundary],
      attempt_evidence: "boundary telemetry #{inspect(opts[:attempt])}",
      survival_evidence: "boundary telemetry #{inspect(opts[:expected])}",
      rfc_sections: ["§55", "§100"],
      attempt_predicate: opts[:attempt],
      outcome_predicate: opts[:expected]
    )
  end

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = &Map.fetch!(fs, "#{@court}-#{&1}")
    engine? = Fx.engine_available?()

    digest =
      if engine?, do: elem(GraphLaw.graph_hash(Graphs.conforming()), 1), else: "unavailable"

    payload = fn overrides -> Envelopes.admissible(Graphs.conforming(), digest, overrides) end

    remote = :"chicago_neg_remote_#{System.unique_integer([:positive])}"
    {:ok, remote_pid} = SemanticPeerAgent.start_link(name: remote)

    try do
      strict_order_peer(fn order ->
        local_card = SB.served_card!(order.agent, :compatible)

        results_order = [
          ordinary_as_semantic(ctx, f.("001"), order, payload.(%{})),
          negotiate_against(ctx, f.("002"), local_card, remote, {:version, "v25.1.0"}),
          envelope_version(ctx, f.("003"), order, payload),
          negotiate_against(ctx, f.("004"), local_card, remote, :none),
          harmless_label(ctx, f.("006"), order),
          downgrade(ctx, f.("007"), order, local_card, remote),
          if(engine?,
            do: compatible(ctx, f.("008"), order, local_card, remote, payload.(%{})),
            else: Result.blocked(f.("008"), "the real praxis-graphlaw engine is unreachable")
          )
        ]

        results_order ++
          [
            if(engine?,
              do: unadvertised_peer(ctx, f.("005"), payload.(%{})),
              else: Result.blocked(f.("005"), "the real praxis-graphlaw engine is unreachable")
            ),
            observe_only_peer(ctx, f.("009"))
          ]
      end)
    after
      SB.stop(remote_pid)
    end
  end

  # --- peers -----------------------------------------------------------------

  defp strict_order_peer(fun) do
    SB.with_peer(
      "neg_order",
      fn agent, ledger ->
        [
          name: "chicago-neg-strict-order-peer",
          ledger: ledger,
          shapes: Graphs.shapes(),
          mode: :strict,
          capabilities: Ordering,
          agent_card: SB.served_card!(agent, :compatible)
        ]
      end,
      fun
    )
  end

  # --- stimuli ---------------------------------------------------------------

  defp ordinary_as_semantic(ctx, f, peer, payload) do
    message =
      Envelopes.ordinary(
        [A2A.Part.Data.new(payload), A2A.Part.Text.new(Jason.encode!(payload))],
        %{
          "sa2a" => payload,
          "extensions" => [Extension.profile_id()],
          "profile" => Extension.profile_id()
        }
      )

    reply = Context.stimulus(ctx, f, fn -> SB.call(peer.agent, message) end)

    Result.negative(f,
      attempt_observed?: SB.observed?(ctx, f, @receive, %{"activated" => "false"}),
      forbidden_outcome_observed?:
        SB.observed?(ctx, f, @admission) or admitted?(ctx, f) or
          match?(%{"standing" => "admitted"}, reply),
      evidence: %{"reply" => SB.evidence(reply)}
    )
  end

  defp negotiate_against(ctx, f, local_card, remote, advertise) do
    {served, result} =
      Context.stimulus(ctx, f, fn ->
        {:ok, remote_card, json} = Http.served_card(agent: remote, advertise: advertise)
        {json["supportedInterfaces"], Extension.negotiate(local_card, remote_card)}
      end)

    Result.negative(f,
      attempt_observed?: SB.observed?(ctx, f, @negotiate),
      forbidden_outcome_observed?:
        match?({:ok, _}, result) or SB.observed?(ctx, f, @negotiate, %{"outcome" => "ok"}),
      evidence: %{"served_interfaces" => served, "negotiation" => inspect(result)}
    )
  end

  defp envelope_version(ctx, f, peer, payload) do
    message = Envelopes.activated(payload.(%{"profile" => "urn:sa2a:profile:core:v25.1.0"}))
    reply = Context.stimulus(ctx, f, fn -> SB.call(peer.agent, message) end)

    Result.negative(f,
      attempt_observed?: SB.observed?(ctx, f, @receive, %{"activated" => "true"}),
      forbidden_outcome_observed?: SB.observed?(ctx, f, @admission) or admitted?(ctx, f),
      evidence: %{"reply" => SB.evidence(reply)}
    )
  end

  defp harmless_label(ctx, f, peer) do
    message =
      Envelopes.ordinary(
        [A2A.Part.Data.new(%{"item" => Fx.unique("chicago-neg-harmless"), "quantity" => 1})],
        %{"skill" => "place_order", "consequenceBearing" => false}
      )

    reply = Context.stimulus(ctx, f, fn -> SB.call(peer.agent, message) end)

    Result.negative(f,
      attempt_observed?: SB.observed?(ctx, f, @receive, %{"activated" => "false"}),
      forbidden_outcome_observed?: downgraded?(ctx, f),
      evidence: %{"reply" => SB.evidence(reply)}
    )
  end

  defp downgrade(ctx, f, peer, local_card, remote) do
    message =
      Envelopes.ordinary(
        [A2A.Part.Data.new(%{"item" => Fx.unique("chicago-neg-downgrade"), "quantity" => 2})],
        %{"skill" => "place_order"}
      )

    {negotiation, {status, response}} =
      Context.stimulus(ctx, f, fn ->
        {:ok, remote_card, _json} = Http.served_card(agent: remote, advertise: :none)
        negotiation = Extension.negotiate(local_card, remote_card)
        {negotiation, Http.post_message([agent: peer.agent, advertise: :compatible], message)}
      end)

    data = Http.reply_data(response)

    Result.negative(f,
      attempt_observed?:
        SB.observed?(ctx, f, @negotiate) and
          SB.observed?(ctx, f, @receive, %{"activated" => "false"}),
      forbidden_outcome_observed?:
        match?({:ok, _}, negotiation) or downgraded?(ctx, f) or
          SB.observed?(ctx, f, @negotiate, %{"outcome" => "ok"}),
      evidence: %{
        "negotiation" => inspect(negotiation),
        "http_status" => status,
        "reply" => SB.evidence(data)
      }
    )
  end

  defp compatible(ctx, f, peer, local_card, remote, payload) do
    message = Envelopes.activated(payload)

    {negotiation, {status, response}} =
      Context.stimulus(ctx, f, fn ->
        {:ok, remote_card, _json} = Http.served_card(agent: remote, advertise: :compatible)
        negotiation = Extension.negotiate(local_card, remote_card)
        {negotiation, Http.post_message([agent: peer.agent, advertise: :compatible], message)}
      end)

    data = Http.reply_data(response)

    Result.positive(f,
      attempt_observed?:
        SB.observed?(ctx, f, @negotiate) and
          SB.observed?(ctx, f, @receive, %{"activated" => "true"}),
      expected_outcome_observed?:
        match?({:ok, _}, negotiation) and admitted?(ctx, f) and
          is_map(data) and data["standing"] == "admitted",
      evidence: %{
        "negotiation" => inspect(negotiation),
        "http_status" => status,
        "reply" => SB.evidence(data)
      }
    )
  end

  defp unadvertised_peer(ctx, f, payload) do
    SB.with_peer(
      "neg_unadvertised",
      fn agent, ledger ->
        [
          name: "chicago-neg-unadvertised-peer",
          ledger: ledger,
          shapes: Graphs.shapes(),
          mode: :strict,
          agent_card: SB.served_card!(agent, :none)
        ]
      end,
      fn peer ->
        reply =
          Context.stimulus(ctx, f, fn -> SB.call(peer.agent, Envelopes.activated(payload)) end)

        Result.negative(f,
          attempt_observed?: SB.observed?(ctx, f, @receive, %{"activated" => "true"}),
          forbidden_outcome_observed?: SB.observed?(ctx, f, @admission) or admitted?(ctx, f),
          evidence: %{"reply" => SB.evidence(reply)}
        )
      end
    )
  end

  defp observe_only_peer(ctx, f) do
    SB.with_peer(
      "neg_catalog",
      fn agent, ledger ->
        [
          name: "chicago-neg-catalog-peer",
          ledger: ledger,
          shapes: Graphs.shapes(),
          mode: :strict,
          capabilities: Catalog,
          agent_card: SB.served_card!(agent, :compatible)
        ]
      end,
      fn peer ->
        message = Envelopes.ordinary("what is in the catalog?")
        reply = Context.stimulus(ctx, f, fn -> SB.call(peer.agent, message) end)

        Result.positive(f,
          attempt_observed?: SB.observed?(ctx, f, @receive, %{"activated" => "false"}),
          expected_outcome_observed?:
            SB.observed?(ctx, f, @decision, %{
              "standing" => "unsupported",
              "code" => "profile_not_negotiated"
            }) and not SB.observed?(ctx, f, @decision, %{"standing" => "refused"}),
          evidence: %{"reply" => SB.evidence(reply)}
        )
      end
    )
  end

  defp admitted?(ctx, f), do: SB.observed?(ctx, f, @decision, %{"standing" => "admitted"})

  defp downgraded?(ctx, f) do
    SB.observed?(ctx, f, @decision, %{"code" => "profile_not_negotiated"}) or
      SB.observed?(ctx, f, @admission) or admitted?(ctx, f) or
      SB.observed?(ctx, f, "brce.actuate.start") or SB.observed?(ctx, f, "dispatch.start")
  end
end
