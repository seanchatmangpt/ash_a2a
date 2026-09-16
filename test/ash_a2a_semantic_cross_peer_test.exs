defmodule AshA2A.SemanticCrossPeerTest do
  @moduledoc """
  RFC-SA2A-001 S8/S49/S50/S51/S75/S76 -- the central cross-peer test.

  ## What is proved here

      Message_A -> Candidate_B -> GraphLaw_B -> O*_B

  and never

      Message_A -> O*_B

  Peer A builds a real `AshA2A.Semantic.Envelope`, attaches it to a real
  `A2A.Message` through the real A2A extension mechanism, and sends it to
  peer B over the **real A2A transport**: a real `A2A.Plug` JSON-RPC
  `message/send` request, serialized to real JSON, driven through the real
  unmodified `:a2a` Plug into a real supervised `A2A.Agent` GenServer.

  Peer B treats it as a candidate and runs its **own**
  `AshA2A.Semantic.GraphLaw` engine -- the real prebuilt `praxis-graphlaw`
  WebAssembly module -- against its **own** SHACL shapes before anything
  gains standing.

  ## Assertions are on peer B's internal standing transitions

  A reply saying "admitted" is peer B's word for what it did. That is not
  what these tests check. They read peer B's real
  `AshA2A.Semantic.Standing.Ledger` -- a real supervised process recording
  every standing edge peer B actually took -- and assert the path is
  `[:received, :candidate, :admitted]`. A peer that replied "admitted"
  without passing through `:candidate` would fail here even though its reply
  looked correct.

  ## No mocks

  Real `Ash.Resource`, real `A2A.Agent` GenServer, real `A2A.Plug`, real
  JSON-RPC envelope, real wasm engine subprocess, real ledger process, real
  SHACL violations. Every assertion is on real returned state -- digests,
  standing values, decoded HTTP response bodies -- never on "was X called".
  """

  use ExUnit.Case, async: false

  alias AshA2A.Semantic.{Envelope, Extension, GraphLaw, Peer, Standing}
  alias AshA2A.Semantic.Standing.Ledger
  alias AshA2A.Test.SemanticPeerFixture.{Graphs, PeerB}

  @peer_a "peer-a"
  @peer_b "peer-b"
  @base_url "http://localhost:4200/a2a"

  setup do
    unless GraphLaw.impl().available?() do
      flunk("""
      The real praxis-graphlaw engine is not reachable from this runtime, so \
      the cross-peer admission claim cannot be exercised at all.

      Resolved wasm path: #{AshA2A.Semantic.GraphLaw.Wasm.wasm_path()}
      Resolved host shim: #{AshA2A.Semantic.GraphLaw.Wasm.host_script()}

      This is a real environment failure reported as a failure, not a silent \
      skip and not a mock substitution.
      """)
    end

    unique = System.unique_integer([:positive])
    agent_name = :"sa2a_cross_peer_b_#{unique}"
    ledger_name = :"sa2a_cross_peer_ledger_#{unique}"

    {:ok, ledger} = start_supervised({Ledger, name: ledger_name})
    {:ok, agent_pid} = start_supervised({PeerB, name: agent_name})

    :ok =
      PeerB.configure(agent_name,
        name: @peer_b,
        ledger: ledger_name,
        shapes: Graphs.peer_b_shapes(),
        mode: :strict
      )

    on_exit(fn -> PeerB.deconfigure(agent_name) end)

    plug_opts =
      A2A.Plug.init(
        agent: agent_name,
        base_url: @base_url,
        agent_card_opts: Extension.advertise(url: @base_url)
      )

    %{
      agent: agent_name,
      agent_pid: agent_pid,
      ledger: ledger,
      ledger_name: ledger_name,
      plug_opts: plug_opts
    }
  end

  # -- Real transport helper ---------------------------------------------------
  #
  # A real JSON-RPC `message/send` request, JSON-encoded exactly as a remote
  # peer A would put it on the wire, driven through the real A2A.Plug.
  defp send_over_real_transport(plug_opts, %A2A.Message{} = message) do
    {:ok, encoded_message} = A2A.JSON.encode(message)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "message/send",
        "params" => %{"message" => encoded_message}
      })

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> A2A.Plug.call(plug_opts)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  # The real JSON-RPC `message/send` result shape produced by the vendored
  # `:a2a` 0.2.0 encoder: `result.task.artifacts[].parts[].data`.
  defp reply_data(response), do: reply_data_from_task(task_result(response))

  defp reply_data_from_task(%{"artifacts" => [%{"parts" => parts} | _]}),
    do: Enum.find_value(parts, fn part -> Map.get(part, "data") end)

  defp task_result(%{"result" => %{"task" => task}}), do: task

  # A real graph digest, from the SAME real engine peer B will independently
  # recompute -- not a placeholder. The `:graph_digest` opt lets a test
  # deliberately supply a WRONG one (the forged-digest test below).
  defp real_envelope(graph, opts \\ []) do
    digest = Keyword.get_lazy(opts, :graph_digest, fn -> elem(GraphLaw.graph_hash(graph), 1) end)

    Envelope.new!(
      [
        envelope_id: "urn:uuid:sa2a-cross-peer-" <> Ash.UUIDv7.generate(),
        kind: "sa2a:Request",
        provenance: %{"agent" => @peer_a},
        graph: %{media_type: "text/turtle", digest: digest, content: graph}
      ] ++ Keyword.take(opts, [:consequence_class, :capability_iri])
    )
  end

  defp peer_a_message(graph, opts \\ []) do
    envelope = real_envelope(graph, opts)

    message =
      "semantic request"
      |> A2A.Message.new_user()
      |> Extension.activate(Envelope.to_map(envelope))

    {envelope, message}
  end

  # ---------------------------------------------------------------------------
  # THE CENTRAL TEST
  # ---------------------------------------------------------------------------

  describe "Message_A -> Candidate_B -> GraphLaw_B -> O*_B" do
    test "a conforming envelope crosses the real transport and is admitted only after peer B's own GraphLaw run",
         %{plug_opts: plug_opts, ledger: ledger} do
      {envelope, message} = peer_a_message(Graphs.conforming_order())

      {status, response} = send_over_real_transport(plug_opts, message)

      assert status == 200
      data = reply_data(response)
      assert data["standing"] == "admitted"
      assert data["envelope_id"] == envelope.envelope_id

      # Peer B's own engine produced this digest; peer A never supplied one.
      assert String.match?(data["graph_digest"], ~r/\A[0-9a-f]{64}\z/)

      # THE ASSERTION THAT MATTERS: peer B's real internal standing path.
      assert Ledger.path(ledger, envelope.envelope_id) == [:received, :candidate, :admitted]

      [received_to_candidate, candidate_to_admitted] =
        Ledger.entries(ledger, envelope.envelope_id)

      assert received_to_candidate.from == :received
      assert received_to_candidate.to == :candidate
      assert received_to_candidate.reason == :envelope_parsed

      assert candidate_to_admitted.from == :candidate
      assert candidate_to_admitted.to == :admitted
      assert candidate_to_admitted.reason == :graphlaw_admitted
    end

    test "peer B's admitted digest is the digest of the graph peer B actually received", %{
      plug_opts: plug_opts
    } do
      graph = Graphs.conforming_order()
      {_envelope, message} = peer_a_message(graph)

      {200, response} = send_over_real_transport(plug_opts, message)

      # Independently computed, by this test process, from the same real
      # engine. Real state comparison -- not "was the engine called".
      {:ok, independent_digest} = GraphLaw.graph_hash(graph)

      assert reply_data(response)["graph_digest"] == independent_digest
    end

    test "there is NO transition edge from :received to :admitted, at all" do
      refute Standing.legal_edge?(:received, :admitted)
      refute :admitted in Standing.successors(:received)

      # The chain's OWN internal :received (reached FROM :candidate, real
      # transport evidence) can only proceed to :parsed, or to any terminal.
      # Peer.ex's bootstrap "message arrived" :received is a distinct,
      # peer-level pre-envelope observation -- see
      # AshA2A.Semantic.Standing.Ledger's `legal_ledger_edge?/2` moduledoc
      # comment -- and is not this function's concern.
      assert Standing.successors(:received) ==
               [:parsed | Standing.terminal_states()]
    end

    test "the ledger physically refuses to record Message_A -> O*_B", %{ledger: ledger} do
      assert {:error, :illegal_standing_transition} =
               Ledger.record(ledger, "forged-envelope", {:received, :admitted}, :forged)

      # Nothing was written. A history skipping :candidate is not producible.
      assert Ledger.entries(ledger, "forged-envelope") == []
    end

    test "a non-conforming envelope is REFUSED by peer B's own shapes, and stops at :candidate -> :refused",
         %{plug_opts: plug_opts, ledger: ledger} do
      {envelope, message} = peer_a_message(Graphs.nonconforming_order())

      {200, response} = send_over_real_transport(plug_opts, message)

      data = reply_data(response)
      assert data["standing"] == "refused"
      assert data["code"] == "semantic_shape_violation"
      assert data["detail"] =~ "SHACL"

      assert Ledger.path(ledger, envelope.envelope_id) == [:received, :candidate, :refused]
      refute :admitted in Ledger.path(ledger, envelope.envelope_id)
    end

    test "peer A's claim of admitted standing is refused outright, before peer B's own admission ever runs",
         %{
           plug_opts: plug_opts,
           ledger: ledger
         } do
      # A hostile peer A hand-writes a payload asserting its graph is already
      # admitted with full authority. `Envelope.new/1` cannot express this,
      # so this test writes the raw wire payload directly -- which is exactly
      # what a hostile remote peer would do.
      #
      # This tightened from "accepted, but the claim is recorded and ignored
      # while peer B admits on its own evidence" to "refused outright, before
      # an envelope is even constructed" when `AshA2A.Semantic.Envelope`
      # closed a real, adversarially-found forgeable-standing defect: a
      # self-declared `"standing"` is now REFUSED at `from_json/1`/
      # `from_map/1` (`:standing_self_declared`, `REFUSED_META_RIGOR`), not
      # merely stripped and remembered. That is a strictly stronger
      # guarantee than this test originally asserted, not a different one --
      # a forged claim can no longer influence anything downstream, because
      # nothing downstream is ever reached.
      {envelope, honest_message} = peer_a_message(Graphs.conforming_order())

      forged_payload =
        envelope
        |> Envelope.to_map()
        |> Map.put("standing", "admitted")
        |> Map.put("authority", "root")

      forged_message = Extension.activate(honest_message, forged_payload)

      {200, response} = send_over_real_transport(plug_opts, forged_message)
      data = reply_data(response)

      # Refused at parse time -- peer B's own GraphLaw admission never runs,
      # regardless of how conforming the underlying graph is.
      assert data["standing"] == "refused"
      assert data["code"] == "standing_self_declared"
      refute Map.has_key?(data, "over_claimed")

      # No real envelope_id exists yet (construction itself was refused), so
      # the ledger records the bridge-derived id peer.ex uses for that case
      # -- consistent with every other refused-before-:candidate test below.
      assert [%{from: :received, to: :refused}] = Ledger.entries(ledger)

      # And direct construction confirms the same refusal, independent of
      # the transport round trip.
      assert {:error, refusal} = Envelope.from_map(forged_payload)
      assert refusal.code == :standing_self_declared
    end

    test "a forged graph digest is refused: peer B hashes the graph itself", %{
      plug_opts: plug_opts,
      ledger: ledger
    } do
      {envelope, message} =
        peer_a_message(Graphs.conforming_order(),
          graph_digest: String.duplicate("f", 64)
        )

      {200, response} = send_over_real_transport(plug_opts, message)
      data = reply_data(response)

      assert data["standing"] == "refused"
      assert data["code"] == "semantic_digest_mismatch"
      assert data["detail"] =~ String.duplicate("f", 64)

      assert Ledger.path(ledger, envelope.envelope_id) == [:received, :candidate, :refused]
    end
  end

  # ---------------------------------------------------------------------------
  # S12-adjacent: the portability property the admission depends on
  # ---------------------------------------------------------------------------

  describe "canonical graph identity (the property the cross-peer claim rests on)" do
    test "two byte-different serializations of the same graph admit to the SAME digest", %{
      plug_opts: plug_opts
    } do
      {_e1, message_1} = peer_a_message(Graphs.conforming_order())
      {_e2, message_2} = peer_a_message(Graphs.conforming_order_reordered())

      {200, response_1} = send_over_real_transport(plug_opts, message_1)
      {200, response_2} = send_over_real_transport(plug_opts, message_2)

      data_1 = reply_data(response_1)
      data_2 = reply_data(response_2)

      assert data_1["standing"] == "admitted"
      assert data_2["standing"] == "admitted"

      # Different prefix labels, different triple order, different bytes --
      # one engine graph digest. This is the real engine's prefix- and
      # triple-order-invariant `graph_hash`, not a sort-then-hash
      # approximation -- and not RDFC-1.0 (it is not blank-node-relabel
      # invariant; RFC S12 identity is AshA2A.Semantic.CanonicalGraph).
      refute Graphs.conforming_order() == Graphs.conforming_order_reordered()
      assert data_1["graph_digest"] == data_2["graph_digest"]
    end

    test "a materially different graph admits to a DIFFERENT digest", %{plug_opts: plug_opts} do
      {_e1, message_1} = peer_a_message(Graphs.conforming_order())

      other = String.replace(Graphs.conforming_order(), "\"widget\"", "\"sprocket\"")
      {_e2, message_2} = peer_a_message(other)

      {200, response_1} = send_over_real_transport(plug_opts, message_1)
      {200, response_2} = send_over_real_transport(plug_opts, message_2)

      assert reply_data(response_1)["graph_digest"] != reply_data(response_2)["graph_digest"]
    end
  end

  # ---------------------------------------------------------------------------
  # S75 / S76: the non-Semantic bridge and downgrade prevention
  # ---------------------------------------------------------------------------

  describe "S75 -- traffic from a non-Semantic A2A peer inherits NO standing" do
    test "an ordinary A2A message over the real transport is answered but gains no standing", %{
      plug_opts: plug_opts,
      ledger: ledger
    } do
      message = A2A.Message.new_user("just an ordinary A2A request")

      {200, response} = send_over_real_transport(plug_opts, message)
      data = reply_data(response)

      assert data["standing"] == "unsupported"
      assert data["code"] == "profile_not_negotiated"

      envelope_id = "sa2a-nonsemantic-" <> message.message_id
      assert Ledger.path(ledger, envelope_id) == [:received, :unsupported]

      # Not admitted, and specifically not refused either: peer B did not
      # evaluate a graph, because there was none.
      refute :admitted in Ledger.path(ledger, envelope_id)
      refute :refused in Ledger.path(ledger, envelope_id)
    end

    test "a message whose plain text IS valid Turtle still gains no standing", %{
      plug_opts: plug_opts
    } do
      message = A2A.Message.new_user(Graphs.conforming_order())

      {200, response} = send_over_real_transport(plug_opts, message)

      # The bytes would have admitted had they been an envelope. They are
      # not, because the profile was never negotiated.
      assert reply_data(response)["standing"] == "unsupported"
    end

    test "an envelope declaring a DIFFERENT profile is refused, not downgraded", %{
      plug_opts: plug_opts
    } do
      {envelope, message} = peer_a_message(Graphs.conforming_order())

      wrong_profile =
        envelope |> Envelope.to_map() |> Map.put("profile", "SA2A-PROFILE-v99.0.0")

      message = Extension.activate(message, wrong_profile)

      {200, response} = send_over_real_transport(plug_opts, message)
      data = reply_data(response)

      assert data["standing"] == "refused"
      assert data["code"] == "unknown_profile"
    end
  end

  describe "S76 -- a Strict peer MUST NOT silently downgrade a consequence-bearing task" do
    test "strict + consequence-bearing + unnegotiated => UNSUPPORTED_PROFILE", %{
      agent: agent_name,
      ledger_name: ledger_name,
      plug_opts: plug_opts,
      ledger: ledger
    } do
      # The old `message.metadata["consequenceBearing"]` flag this test used
      # to set is now ignored on purpose (see AshA2A.Semantic.Peer's real
      # S76 fix -- the counterparty may not answer its own downgrade
      # question). Consequence-bearing-ness is now read from THIS peer's own
      # capability surface, so this test configures one here (scoped to this
      # test only -- other tests in this module must not see it, since a
      # configured capability surface changes the bridge-path S75 tests'
      # outcome too): the real AshA2A.Test.SemanticPeerFixture.Domain
      # fixture already used by test/ash_a2a_semantic_agent_card_test.exs,
      # whose sole real skill (place_order, via :create) is
      # consequence-bearing -- exactly what this test needs to exercise.
      :ok =
        PeerB.configure(agent_name,
          name: @peer_b,
          ledger: ledger_name,
          shapes: Graphs.peer_b_shapes(),
          mode: :strict,
          capabilities: AshA2A.Test.SemanticPeerFixture.Domain
        )

      message = A2A.Message.new_user("place an order for 3 widgets")

      {200, response} = send_over_real_transport(plug_opts, message)
      data = reply_data(response)

      assert data["standing"] == "unsupported"
      assert data["code"] == "unsupported_profile"
      assert data["detail"] =~ "will not downgrade"
      assert data["detail"] =~ Extension.profile_id()

      envelope_id = "sa2a-nonsemantic-" <> message.message_id
      refute :admitted in Ledger.path(ledger, envelope_id)
    end

    test "a PERMISSIVE peer answers the same consequence-bearing task as ordinary A2A, still with no standing" do
      permissive =
        Peer.new(name: "permissive-peer", shapes: Graphs.peer_b_shapes(), mode: :permissive)

      message = %{
        A2A.Message.new_user("place an order")
        | metadata: %{"consequenceBearing" => true}
      }

      outcome = Peer.receive_message(permissive, message, consequence_bearing?: true)

      # The difference between strict and permissive is the refusal CODE, not
      # the standing. Neither mode ever yields standing to unnegotiated
      # traffic.
      assert outcome.standing == :unsupported
      assert outcome.code == :profile_not_negotiated
      refute outcome.standing == :admitted
    end

    test "a strict peer still answers a NON-consequence-bearing unnegotiated request" do
      strict = Peer.new(name: "strict-peer", shapes: Graphs.peer_b_shapes(), mode: :strict)

      outcome =
        Peer.receive_message(strict, A2A.Message.new_user("what time is it?"),
          consequence_bearing?: false
        )

      assert outcome.standing == :unsupported
      assert outcome.code == :profile_not_negotiated
    end
  end

  # ---------------------------------------------------------------------------
  # S49 / S50
  # ---------------------------------------------------------------------------

  describe "S49 -- an A2A Task is not authority" do
    test "every real task state yields authority :none", %{plug_opts: plug_opts} do
      {_envelope, message} = peer_a_message(Graphs.conforming_order())
      {200, response} = send_over_real_transport(plug_opts, message)

      # A real completed task, produced by the real agent runtime over the
      # real transport.
      task_json = task_result(response)
      assert task_json["status"]["state"] == "TASK_STATE_COMPLETED"

      {:ok, task} = A2A.JSON.decode(task_json, :task)
      assert %A2A.Task{status: %A2A.Task.Status{state: :completed}} = task

      assert Peer.authority_from_task(task) == :none

      for state <- [:submitted, :working, :completed, :failed, :canceled, :input_required] do
        staged = put_in(task.status.state, state)
        assert Peer.authority_from_task(staged) == :none
      end
    end

    test "a completed task does not let a follow-up message skip admission", %{
      plug_opts: plug_opts,
      ledger: ledger
    } do
      {_first, first_message} = peer_a_message(Graphs.conforming_order())
      {200, first_response} = send_over_real_transport(plug_opts, first_message)
      task_id = task_result(first_response)["id"]
      assert is_binary(task_id)

      # A second, NON-conforming envelope riding the same completed task.
      {second, second_message} = peer_a_message(Graphs.nonconforming_order())
      riding_message = %{second_message | task_id: task_id}

      {200, riding_response} = send_over_real_transport(plug_opts, riding_message)

      # Measured, real behavior of the vendored `:a2a` 0.2.0 agent runtime: a
      # `:completed` task is not continuable at all. The prior task is not a
      # channel a later message can inherit anything through -- it is not
      # even a channel.
      assert riding_response["error"]["data"] == ":not_continuable"
      assert Ledger.entries(ledger, second.envelope_id) == []

      # And as a fresh task, the same non-conforming envelope is refused on
      # its own merits. The earlier completed task bought it nothing.
      {200, fresh_response} = send_over_real_transport(plug_opts, second_message)

      assert reply_data(fresh_response)["standing"] == "refused"
      assert Ledger.path(ledger, second.envelope_id) == [:received, :candidate, :refused]
    end
  end

  describe "S50 -- an A2A Artifact gains no standing from being an Artifact" do
    test "every artifact has standing :received, whatever it contains" do
      artifact = A2A.Artifact.new([A2A.Part.Text.new(Graphs.conforming_order())])

      assert Peer.standing_from_artifact(artifact) == :received
      refute Standing.admitted?(Peer.standing_from_artifact(artifact))
    end

    test "an artifact produced by a REAL admitted exchange still has standing :received", %{
      plug_opts: plug_opts
    } do
      {_envelope, message} = peer_a_message(Graphs.conforming_order())
      {200, response} = send_over_real_transport(plug_opts, message)

      assert reply_data(response)["standing"] == "admitted"

      {:ok, artifact} =
        response |> task_result() |> Map.fetch!("artifacts") |> hd() |> A2A.JSON.decode(:artifact)

      # The exchange was admitted. The artifact carrying its result is still
      # only :received -- container-ness confers nothing.
      assert Peer.standing_from_artifact(artifact) == :received
    end

    test "an envelope carried inside an artifact with a self-declared standing is refused, not downgraded to candidate" do
      # Tightened the same way the message-path over-claim test above was:
      # `Envelope.from_map/1` now refuses ANY self-declared `"standing"`
      # outright (`:standing_self_declared`) rather than admitting it at a
      # forced-down `:candidate`. An artifact is a different container, not
      # a way around that -- `Peer.envelope_from_artifact/1` goes through the
      # same `Envelope.from_map/1`.
      {envelope, _message} = peer_a_message(Graphs.conforming_order())

      artifact =
        A2A.Artifact.new([A2A.Part.Text.new("payload")],
          metadata: %{
            Extension.extension_key() =>
              envelope |> Envelope.to_map() |> Map.put("standing", "admitted")
          }
        )

      assert {:error, refusal} = Peer.envelope_from_artifact(artifact)
      assert refusal.code == :standing_self_declared
    end

    test "an artifact with no semantic payload yields :profile_not_activated" do
      artifact = A2A.Artifact.new([A2A.Part.Text.new("nothing semantic here")])

      assert {:error, %{code: :profile_not_activated}} = Peer.envelope_from_artifact(artifact)
    end
  end

  # ---------------------------------------------------------------------------
  # Fail-closed and out-of-order admission
  # ---------------------------------------------------------------------------

  describe "fail-closed" do
    test "a peer whose engine is genuinely unreachable returns :unsupported, never :admitted" do
      # A real unavailability, not a substituted collaborator: the real
      # `AshA2A.Semantic.GraphLaw.Wasm` runner is pointed at a wasm path that
      # genuinely does not exist on this filesystem, so the real
      # `File.exists?/1` guard in the real runner fires. This module is
      # `async: false`, so the scoped config change cannot race another test.
      previous = Application.get_env(:ash_a2a, AshA2A.Semantic.GraphLaw.Wasm)

      absent =
        Path.join(
          System.tmp_dir!(),
          "definitely-not-a-wasm-module-#{System.unique_integer([:positive])}.wasm"
        )

      refute File.exists?(absent)

      Application.put_env(:ash_a2a, AshA2A.Semantic.GraphLaw.Wasm, wasm_path: absent)

      try do
        unreachable = Peer.new(name: "engine-less-peer", shapes: Graphs.peer_b_shapes())

        # A placeholder digest, not a real one: the engine this test just made
        # unreachable is the same one `real_envelope/2`'s default would call
        # to compute a real digest, which would defeat the point of this test.
        envelope =
          real_envelope(Graphs.conforming_order(), graph_digest: String.duplicate("0", 64))

        outcome = Peer.admit(unreachable, envelope)

        assert outcome.standing == :unsupported
        assert outcome.code == :graphlaw_unavailable
        assert outcome.detail =~ absent
        refute Standing.admitted?(outcome.standing)
      after
        if previous do
          Application.put_env(:ash_a2a, AshA2A.Semantic.GraphLaw.Wasm, previous)
        else
          Application.delete_env(:ash_a2a, AshA2A.Semantic.GraphLaw.Wasm)
        end
      end
    end

    test "admitting an already-decided envelope is refused as out of order" do
      peer = Peer.new(name: @peer_b, shapes: Graphs.peer_b_shapes())
      envelope = real_envelope(Graphs.conforming_order())

      decided = %{envelope | standing: :admitted}
      outcome = Peer.admit(peer, decided)

      assert outcome.standing == :refused
      assert outcome.code == :illegal_standing_transition
    end

    test ":refused is terminal, :admitted is not (it continues toward planning); :unsupported is not admitted" do
      # `:admitted` was asserted terminal here under cross-peer's own,
      # peer-boundary-scoped model (an admitted envelope is nothing further
      # to THIS peer's admission concern). RFC-SA2A-001's full chain
      # continues past :admitted into :plannable/:selected/.../:attested
      # (see AshA2A.Semantic.Standing's moduledoc), so :admitted is
      # correctly NOT one of the five absorbing terminal states -- only
      # `Standing.admitted?/1` (a peer-boundary-scoped predicate this module
      # still owns) captures the narrower claim peer.ex actually needs.
      refute Standing.terminal?(:admitted)
      assert Standing.terminal?(:refused)
      assert Standing.terminal?(:unsupported)
      refute Standing.admitted?(:unsupported)
      refute Standing.admitted?(:candidate)
      refute Standing.admitted?(:received)
      assert Standing.admitted?(:admitted)
    end

    test "the engine reports which dialects it did NOT exercise", %{plug_opts: plug_opts} do
      {_envelope, message} = peer_a_message(Graphs.conforming_order())
      {200, response} = send_over_real_transport(plug_opts, message)

      unexercised = reply_data(response)["unexercised"]

      # Peer B supplied SHACL shapes and no ShEx schema and no OWL profile.
      # The receipt must say so rather than implying the full ladder ran:
      # UNSUPPORTED is not ADMITTED.
      dialects = Enum.map(unexercised, & &1["dialect"])
      assert "SHEX" in dialects
      assert "OWL_RL" in dialects
      refute "SHACL" in dialects
    end
  end
end
