# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root Task, Telemetry, Transports, & Ports
# Target File: test/root_task_transport_ports_consolidated_test.exs
# Consolidated from 21 original test files:
#   - test/ash_a2a_semantic_refusal_receipt_test.exs
#   - test/ash_a2a_semantic_subject_command_test.exs
#   - test/ash_a2a_semantic_work_envelope_test.exs
#   - test/ash_a2a_skip_reason_discipline_test.exs
#   - test/ash_a2a_spg_identity_test.exs
#   - test/ash_a2a_sse_stream_test.exs
#   - test/ash_a2a_standing_receipt_chain_test.exs
#   - test/ash_a2a_standing_receipt_verify_test.exs
#   - test/ash_a2a_task_failed_state_test.exs
#   - test/ash_a2a_telemetry_ocel_forwarder_bounded_test.exs
#   - test/ash_a2a_telemetry_ocel_forwarder_command_bus_test.exs
#   - test/ash_a2a_telemetry_ocel_forwarder_test.exs
#   - test/ash_a2a_test.exs
#   - test/ash_a2a_trace_test.exs
#   - test/ash_a2a_transport_grpc_auth_test.exs
#   - test/ash_a2a_transport_grpc_server_test.exs
#   - test/ash_a2a_transport_grpc_test.exs
#   - test/ash_a2a_transport_http_json_test.exs
#   - test/ash_a2a_transport_plug_force_ssl_test.exs
#   - test/ash_a2a_transport_wire_compat_test.exs
#   - test/ash_a2a_two_port_gate_test.exs
# ==============================================================================

# ==============================================================================
# SECTION 1: Original test/ash_a2a_semantic_refusal_receipt_test.exs
# ==============================================================================

defmodule AshA2A.Semantic.RefusalReceiptTest do
  @moduledoc """
  L109 courts for the optional committed refusal receipt
  (`AshA2A.Semantic.Refusal.commit/2` + `receipt/4`).

  Parity provenance: strata-valve-pack `generated/refusals.ex` derivation
  (pack commit 8210f1b24, parity court seam-29-l26 verdict IDENTICAL):
  SHA-256 over `class label <> 0x00 <> term_to_binary({code, stage, subject})`.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Refusal

  @frame_seed {:frame, <<1, 2, 3>>}

  # Pinned hexes for class "malformed_frame", seed {:frame, <<1, 2, 3>>}.
  # Both computed and cross-checked Elixir-vs-python (hashlib) in this
  # session; the Elixir side is the byte-identical derivation line used by
  # strata-valve-pack's generated Strata.Valve.Refusals.MalformedFrame.
  @frame_ext_hex "83680277056672616d656d00000003010203"
  @frame_receipt_hex "5b67a27a1cce7fb134f3b1d5cda94191ac575fe94de2b174e9e4f17168fa348d"

  describe "determinism" do
    test "same refusal + subject commits the same receipt twice" do
      refusal = Refusal.new(:refused_authority, :authority_required, :authorize)
      subject = {:task, "t-1"}

      committed_a = Refusal.commit(refusal, subject)
      committed_b = Refusal.commit(refusal, subject)

      assert committed_a.receipt == committed_b.receipt
      assert is_binary(committed_a.receipt)
      assert byte_size(committed_a.receipt) == 32
    end

    test "receipt/4 alone is deterministic" do
      a = Refusal.receipt(:refused_identity, :invalid_subject, :identity, "x")
      b = Refusal.receipt(:refused_identity, :invalid_subject, :identity, "x")
      assert a == b
      assert byte_size(a) == 32
    end
  end

  describe "class-distinctness" do
    test "two classes over the same {code, stage, subject} diverge" do
      subject = {:payload, :same}

      a = Refusal.receipt(:refused_authority, :denied, :authorize, subject)
      b = Refusal.receipt(:refused_identity, :denied, :authorize, subject)

      assert a != b
      assert byte_size(a) == 32 and byte_size(b) == 32
    end
  end

  describe "tamper-evidence" do
    test "one-byte change in the subject payload flips the receipt" do
      refusal = Refusal.new(:refused_structure, :bad_term, :parse)
      base = Refusal.commit(refusal, {:frame, <<1, 2, 3>>})
      tampered = Refusal.commit(refusal, {:frame, <<1, 2, 4>>})

      refute base.receipt == tampered.receipt
    end
  end

  describe "cross-impl parity (strata-valve derivation shape)" do
    test "malformed_frame seed {:frame, <<1,2,3>>} matches the pinned strata-valve hex" do
      # The derivation-shape equivalence: this module's receipt/4 hashes
      # `Atom.to_string(:refused_structure)`... but the strata-valve class
      # label is "malformed_frame", so exercise the raw derivation with the
      # exact strata-valve line against the pinned python-verified hex.
      ext = :erlang.term_to_binary(@frame_seed)
      assert Base.encode16(ext) == String.upcase(@frame_ext_hex)

      raw = :crypto.hash(:sha256, "malformed_frame" <> <<0>> <> ext)
      assert Base.encode16(raw) == String.upcase(@frame_receipt_hex)

      # Same derivation through the module seam: the class label of the
      # strata-valve class is what the parity court pins, so assert the
      # module's derivation over the same label via receipt/4's structure
      # (label <> 0 <> ext-of-{code, stage, subject}) using matching atoms.
      via_module =
        Refusal.receipt(:refused_structure, :frame, :strata_valve_parity, @frame_seed)

      assert byte_size(via_module) == 32
      # Independent reproduction of the same shape with literal label:
      assert via_module ==
               :crypto.hash(
                 :sha256,
                 "refused_structure" <>
                   <<0>> <> :erlang.term_to_binary({:frame, :strata_valve_parity, @frame_seed})
               )
    end
  end

  describe "mint_private wiring" do
    test "incomplete term refusal carries a 32-byte receipt over the refused subject" do
      subject = %{"label" => "only_label"}

      {:error, refusal} = AshA2A.Semantic.Iri.mint_private(subject)

      assert %{code: :private_term_incomplete, receipt: receipt} = refusal
      assert is_binary(receipt) and byte_size(receipt) == 32

      expected =
        Refusal.receipt(
          :refused_namespace,
          :private_term_incomplete,
          :semantic_iri_mint_private,
          subject
        )

      assert receipt == expected
    end

    test "receipt is deterministic per subject and diverges per subject" do
      {:error, a} = AshA2A.Semantic.Iri.mint_private(%{"label" => "x"})
      {:error, b} = AshA2A.Semantic.Iri.mint_private(%{"label" => "x"})
      {:error, c} = AshA2A.Semantic.Iri.mint_private(%{"label" => "y"})

      assert a.receipt == b.receipt
      assert a.receipt != c.receipt
    end
  end

  describe "to_map additive receipt" do
    test "nil receipt serializes as nil; committed receipt serializes as uppercase hex" do
      base = Refusal.new(:refused_bounds, :max_children, :plan)
      assert %{"receipt" => nil} = Refusal.to_map(base)

      committed = Refusal.commit(base, {:child, 7})
      assert %{"receipt" => hex} = Refusal.to_map(committed)
      assert byte_size(Base.decode16!(hex)) == 32
    end
  end

  test "existing constructors stay receipt-free (no breaking change)" do
    r = Refusal.from_error(%{code: :authority_required, detail: "x"}, :authorize)
    assert %Refusal{receipt: nil} = r
    assert r.class == :refused_authority
  end
end

# ==============================================================================
# SECTION 2: Original test/ash_a2a_semantic_subject_command_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticSubjectCommandTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Command, Identity, Receipt, SemanticSubject}

  @a "sha256:" <> String.duplicate("a", 64)
  @b "sha256:" <> String.duplicate("b", 64)
  @c "sha256:" <> String.duplicate("c", 64)
  @d "sha256:" <> String.duplicate("d", 64)

  test "command fingerprint is scoped to exact semantic graph and projection" do
    assert {:ok, subject_a} =
             SemanticSubject.new(
               graph_digest: @a,
               projection_digest: @b,
               manufacturer_digest: @c
             )

    assert {:ok, subject_b} =
             SemanticSubject.new(
               graph_digest: @d,
               projection_digest: @b,
               manufacturer_digest: @c
             )

    opts = [agent_id: "agent-1", principal_id: "principal-1", input: %{"id" => 1}]

    command_a = Command.new("people.read", Keyword.put(opts, :semantic_subject, subject_a))
    command_b = Command.new("people.read", Keyword.put(opts, :semantic_subject, subject_b))

    refute command_a.fingerprint == command_b.fingerprint
  end

  test "receipt carries the same exact semantic subject without granting authority" do
    assert {:ok, subject} =
             SemanticSubject.new(
               graph_digest: @a,
               projection_digest: @b,
               manufacturer_digest: @c
             )

    command =
      Command.new("people.read",
        agent_id: "agent-1",
        principal_id: "principal-1",
        semantic_subject: subject
      )

    receipt =
      Receipt.from_reply(command, Identity.new(:execution, "execution-1"), :read, {:reply, :ok})

    assert receipt.semantic_subject == subject
    assert receipt.fingerprint == command.fingerprint
    assert receipt.standing == :observed
  end

  test "legacy commands remain valid without a semantic subject" do
    command = Command.new("people.read", agent_id: "agent-1", principal_id: "principal-1")
    assert command.semantic_subject == nil

    receipt =
      Receipt.from_reply(command, Identity.new(:execution, "execution-1"), :read, {:reply, :ok})

    assert receipt.semantic_subject == nil
  end

  test "malformed graph identity is refused" do
    assert {:error, {:refused_semantic_subject, :graph_digest}} =
             SemanticSubject.new(
               graph_digest: "not-a-digest",
               projection_digest: @b,
               manufacturer_digest: @c
             )
  end
end

# ==============================================================================
# SECTION 3: Original test/ash_a2a_semantic_work_envelope_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.WorkEnvelopeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{CanonicalGraph, WorkEnvelope}

  @ttl """
  @prefix gall: <https://semantic-a2a.dev/gall#> .
  <urn:gall:checkpoint:test:001> a gall:CodingCheckpoint .
  """

  defp descriptor(digest) do
    %{
      "work_order_iri" => "urn:gall:work-order:test:001",
      "checkpoint_iri" => "urn:gall:checkpoint:test:001",
      "repository_identity" => "seanchatmangpt/ash_a2a",
      "base_sha" => String.duplicate("b", 40),
      "graph_digest" => "sha256:" <> digest
    }
  end

  test "checkpoint envelope is bound to observed canonical graph identity" do
    {:ok, digest} = CanonicalGraph.canonical_digest(@ttl)

    input =
      descriptor(digest)
      |> Map.merge(%{
        "goal" => "transport the work subject",
        "verifier_suite" => "ash-a2a-dod",
        "standing" => "UNKNOWN",
        "required_capabilities" => ["Read", "Edit"],
        "forbidden_capabilities" => ["Push", "Publish"]
      })

    assert {:ok, envelope} = WorkEnvelope.checkpoint(@ttl, input)
    assert envelope["graph_digest"] == "sha256:" <> digest
    assert envelope["canonicalization"] == "RDFC-1.0/SHA-256/n-quads-sorted"
  end

  test "caller supplied graph identity cannot replace observed identity" do
    input = %{
      descriptor(String.duplicate("0", 64))
      | "graph_digest" => "sha256:" <> String.duplicate("0", 64)
    }

    assert {:error, %{code: :refused_graph_identity_mismatch}} =
             WorkEnvelope.checkpoint(@ttl, input)
  end

  test "capability contradiction is refused" do
    {:ok, digest} = CanonicalGraph.canonical_digest(@ttl)

    input =
      descriptor(digest)
      |> Map.merge(%{
        "required_capabilities" => ["Publish"],
        "forbidden_capabilities" => ["Publish"]
      })

    assert {:error, %{code: :refused_capability_contradiction}} =
             WorkEnvelope.checkpoint(@ttl, input)
  end

  test "lease and receipt preserve exact work subject identity without promoting standing" do
    {:ok, digest} = CanonicalGraph.canonical_digest(@ttl)
    assert {:ok, checkpoint} = WorkEnvelope.checkpoint(@ttl, descriptor(digest))

    assert {:ok, lease} =
             WorkEnvelope.work_lease(checkpoint, %{
               "epoch_id" => "123e4567-e89b-42d3-a456-426614174000",
               "worker_id" => "zcode-01",
               "worktree" => "/tmp/worktree"
             })

    assert lease["work_order_iri"] == checkpoint["work_order_iri"]
    assert lease["checkpoint_iri"] == checkpoint["checkpoint_iri"]
    assert lease["graph_digest"] == checkpoint["graph_digest"]
    assert lease["repository_identity"] == checkpoint["repository_identity"]
    assert lease["base_sha"] == checkpoint["base_sha"]
    refute Map.has_key?(lease, "standing")
    refute Map.has_key?(lease, "authority")

    assert {:ok, receipt} =
             WorkEnvelope.receipt(checkpoint, %{
               "receipt_iri" => "urn:receipt:1",
               "candidate_sha" => String.duplicate("c", 40),
               "standing" => "BUILD_BROKEN",
               "verifier" => "ash-a2a-dod"
             })

    assert receipt["standing"] == "BUILD_BROKEN"
    assert receipt["work_order_iri"] == checkpoint["work_order_iri"]
    assert receipt["checkpoint_iri"] == checkpoint["checkpoint_iri"]
    assert receipt["repository_identity"] == checkpoint["repository_identity"]
    assert receipt["base_sha"] == checkpoint["base_sha"]
  end

  test "checkpoint refuses incomplete exact work subject identity" do
    {:ok, digest} = CanonicalGraph.canonical_digest(@ttl)
    base = descriptor(digest)

    assert {:error, %{code: :refused_missing_semantic_field, field: "work_order_iri"}} =
             WorkEnvelope.checkpoint(@ttl, Map.delete(base, "work_order_iri"))

    assert {:error, %{code: :refused_invalid_semantic_field, field: "repository_identity"}} =
             WorkEnvelope.checkpoint(@ttl, %{base | "repository_identity" => "ash_a2a"})

    assert {:error, %{code: :refused_invalid_semantic_field, field: "base_sha"}} =
             WorkEnvelope.checkpoint(@ttl, %{base | "base_sha" => "main"})
  end
end

# ==============================================================================
# SECTION 4: Original test/ash_a2a_skip_reason_discipline_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SkipReasonDisciplineTest do
  @moduledoc """
  Fails closed when a `:skip`-tagged test carries no reason string, and
  lists the tags `test_helper.exs` excluded (loud census, never silent).
  A bare `@tag :skip` / `@moduletag :skip` is a skip with no stated reason.
  """
  use ExUnit.Case, async: true

  @bare ~r/^\s*@(module|describe)?tag\s+:skip\b(?!\s*,)(?!_)/
  # `skip: true` / `skip: not x` / `skip: !x` are boolean skips with no reason string.
  @boolean ~r/\bskip:\s*(true\b|not\s|!)/

  test "no bare :skip tag without a reason string" do
    offenders =
      Path.wildcard("test/**/*.{ex,exs}")
      |> Enum.reject(&(&1 == "test/ash_a2a_skip_reason_discipline_test.exs"))
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} ->
          Regex.match?(@bare, line) or Regex.match?(@boolean, line)
        end)
        |> Enum.map(fn {line, n} -> "#{file}:#{n}: #{String.trim(line)}" end)
      end)

    assert offenders == [],
           "skip tags without a reason (use `@tag skip: \"why\"`):\n" <>
             Enum.join(offenders, "\n")
  end

  test "excluded tags are a known list (printed census)" do
    excluded = ExUnit.configuration()[:exclude] |> List.wrap()
    IO.puts(:stderr, "[test_helper] excluded tags: #{inspect(excluded)}")
    assert is_list(excluded)
    assert :external_api in excluded
    assert :benchmark in excluded
  end
end

# ==============================================================================
# SECTION 5: Original test/ash_a2a_spg_identity_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SpgIdentityTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Command, Identity, Receipt, SemanticProjection, SpgIdentity}

  test "SPG identity is stable command identity and survives receipt -> OCEL projection" do
    assert {:ok, spg} =
             SpgIdentity.new(
               graph_id: "spg:sa2a-brce-first-court",
               graph_version: "26.9.25",
               node_id: "actuate",
               edge_id: "e4",
               projection_family: "sa2a"
             )

    command =
      Command.new("example.change",
        command_id: "spg-command-1",
        agent_id: "agent-1",
        principal_id: "principal-1",
        input: %{value: 1},
        spg_identity: spg
      )

    same_without_spg =
      Command.new("example.change",
        command_id: "spg-command-2",
        agent_id: "agent-1",
        principal_id: "principal-1",
        input: %{value: 1}
      )

    refute command.fingerprint == same_without_spg.fingerprint

    receipt =
      Receipt.from_reply(
        command,
        Identity.execution("spg-execution-1"),
        :observe,
        {:reply, []}
      )

    assert receipt.metadata.spg_graph_id == "spg:sa2a-brce-first-court"
    assert receipt.metadata.spg_graph_version == "26.9.25"
    assert receipt.metadata.spg_node_id == "actuate"
    assert receipt.metadata.spg_edge_id == "e4"
    assert receipt.metadata.spg_projection_family == "sa2a"

    event = SemanticProjection.ocel_event(receipt)
    assert event["attributes"]["spg_graph_id"] == "spg:sa2a-brce-first-court"
    assert event["attributes"]["spg_graph_version"] == "26.9.25"
    assert event["attributes"]["spg_node_id"] == "actuate"
    assert event["attributes"]["spg_edge_id"] == "e4"
    assert event["attributes"]["spg_projection_family"] == "sa2a"
  end

  test "invalid empty semantic identities are refused" do
    assert {:error, {:refused_spg_identity, :node_id}} =
             SpgIdentity.new(
               graph_id: "spg:test",
               graph_version: "1",
               node_id: ""
             )
  end
end

# ==============================================================================
# SECTION 6: Original test/ash_a2a_sse_stream_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ASSEStreamTest do
  @moduledoc """
  Chicago-style coverage for assignment #8: real `message/stream` content
  parsed via `AshA2A.Protocol.Client.SSE.feed/2` -- genuinely untested surface (the
  existing streaming tests, `test/ash_a2a_test.exs`'s and
  `test/ash_a2a_dispatcher_skills_test.exs`'s `:echo` cases, only assert on
  the bare Elixir `{:stream, enum}` tuple at the dispatcher level, against
  an always-empty ETS table, and never touch `AshA2A.Protocol.Client.SSE` at all).

  This file drives the real stack one level further than those:

  1. A real `AshA2A.Protocol.AgentSupervisor` starts a real
     `AshA2A.Test.Fixture.StreamingWidgetAgent` (`use AshA2A.Agent`) over a
     real, ETS-seeded `AshA2A.Test.Fixture.StreamingWidget` resource
     (seeded with real rows via `Ash.Seed.seed!/2` -- a real Ash test-data
     API, not a mock).
  2. `AshA2A.Protocol.stream/3` (the real, dependency-free public API in
     `deps/a2a/lib/a2a.ex:121-152` -- no `Plug`/`Bandit` involved) sends a
     real `AshA2A.Protocol.Message` to that real process and returns `{:ok, task,
     enum}`, where `enum` is the real lazy `Stream.map/2` built by
     `AshA2A.Dispatcher.to_reply/1`'s `{:stream_ok, stream}` clause
     (`lib/ash_a2a/dispatcher.ex:478-484`) -- each element a real
     `AshA2A.Protocol.Part.Data` wrapping one real streamed `StreamingWidget` record.
  3. Each real part is wrapped into a real `AshA2A.Protocol.Event.ArtifactUpdate`
     (`deps/a2a/lib/a2a/event.ex:51-84`) and encoded with the real
     `AshA2A.Protocol.JSON.encode/1` (`deps/a2a/lib/a2a/json.ex:195-211`) -- the exact
     two calls `AshA2A.Protocol.Plug.SSE.stream_parts/4`
     (`deps/a2a/lib/a2a/plug/sse.ex:66-79`) makes for every streamed part
     over real HTTP. `AshA2A.Protocol.Plug.SSE` itself cannot be driven directly here:
     it is gated behind `Code.ensure_loaded?(Plug)`
     (`deps/a2a/lib/a2a/plug/sse.ex:1`) and neither `plug` nor `bandit`
     appear anywhere in this project's `mix.lock` -- ash_a2a wires no HTTP
     transport (confirmed by this session's research). Wrapping each real
     `Part.Data` into `ArtifactUpdate`/`JSON.encode` here reproduces that
     exact real two-line encoding step from `AshA2A.Protocol.Plug.SSE`, not a
     hand-invented one, wire-formatted as `"data: <json>\\n\\n"` exactly as
     `AshA2A.Protocol.Plug.SSE.send_event/3` does (`deps/a2a/lib/a2a/plug/sse.ex:81-88`).
  4. Those real SSE-formatted chunks (split mid-event, to prove the parser's
     real buffering, not just whole-event feeds) are fed through the real,
     dependency-free `AshA2A.Protocol.Client.SSE.new/0` + `feed/2`
     (`deps/a2a/lib/a2a/client/sse.ex:20-34`) -- the actual target of this
     assignment.
  5. Assertions are state-based throughout: the real decoded SSE event
     payloads' artifact part data is compared against the real seeded
     `StreamingWidget` labels -- not "was `feed/2` called," an interaction
     assertion this file never makes.

  No Mock/mox/patch/monkeypatch anywhere in this file.
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.{StreamingWidget, StreamingWidgetAgent}

  test "AshA2A.Protocol.stream/3's real streamed parts round-trip through AshA2A.Protocol.Client.SSE.feed/2 unchanged" do
    # Seed real rows via the real Ash.Seed API (StreamingWidget declares no
    # :create action -- this is the same kind of direct data-layer seeding
    # a hand-rolled ETS fixture load would be, just via Ash's own real
    # helper instead of reinventing it).
    Ash.Seed.seed!(StreamingWidget, %{label: "alpha"})
    Ash.Seed.seed!(StreamingWidget, %{label: "bravo"})
    Ash.Seed.seed!(StreamingWidget, %{label: "charlie"})

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        StreamingWidgetAgent
      ])

    message = data_message(%{"stream" => true})

    assert {:ok, task, enum} = AshA2A.Protocol.stream(StreamingWidgetAgent, message, [])
    assert task.status.state == :working

    # Drain the real lazy stream -- real AshA2A.Protocol.Part.Data structs, each
    # wrapping one real streamed StreamingWidget record. The ETS data layer
    # is process-shared across this file's two tests (no per-test reset
    # hook exists for `Ash.DataLayer.Ets`), so filter down to this test's
    # own seeded labels rather than asserting on the raw total count.
    real_parts =
      enum
      |> Enum.to_list()
      |> Enum.filter(fn %AshA2A.Protocol.Part.Data{data: %{label: label}} ->
        label in ["alpha", "bravo", "charlie"]
      end)

    assert length(real_parts) == 3

    real_labels =
      real_parts
      |> Enum.map(fn %AshA2A.Protocol.Part.Data{data: %{label: label}} -> label end)
      |> Enum.sort()

    assert real_labels == ["alpha", "bravo", "charlie"]

    # Reproduce AshA2A.Protocol.Plug.SSE.stream_parts/4's exact real per-part encoding
    # (ArtifactUpdate.new/3 + AshA2A.Protocol.JSON.encode_stream_response/1
    # + the literal "data: <json>\n\n" wire format AshA2A.Protocol.Plug.SSE.send_event/3
    # emits): the v1.0 wire frame wraps the event as {"artifactUpdate": ...}.
    wire_chunks =
      Enum.map(real_parts, fn part ->
        artifact = AshA2A.Protocol.Artifact.new([part])

        event =
          AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact, context_id: task.context_id)

        {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)
        payload = AshA2A.Protocol.JSONRPC.Response.success("test-id", encoded)
        "data: #{Jason.encode!(payload)}\n\n"
      end)

    full_wire = Enum.join(wire_chunks)
    assert byte_size(full_wire) > 0

    # Split the real wire bytes at arbitrary, non-event-aligned byte
    # offsets to prove AshA2A.Protocol.Client.SSE.feed/2's real buffering across
    # partial chunks -- not just one whole-event-per-feed happy path.
    {chunk_a, rest} = String.split_at(full_wire, div(byte_size(full_wire), 3))
    {chunk_b, chunk_c} = String.split_at(rest, div(byte_size(rest), 2))

    state0 = AshA2A.Protocol.Client.SSE.new()
    {events1, state1} = AshA2A.Protocol.Client.SSE.feed(state0, chunk_a)
    {events2, state2} = AshA2A.Protocol.Client.SSE.feed(state1, chunk_b)
    {events3, _state3} = AshA2A.Protocol.Client.SSE.feed(state2, chunk_c)

    all_events = events1 ++ events2 ++ events3
    assert length(all_events) == 3

    # Every real decoded SSE event is a real JSON-RPC success envelope
    # wrapping the real encoded ArtifactUpdate, whose artifact part data
    # matches the real originally-streamed labels -- proving what a real
    # streaming A2A client actually receives and parses over the wire
    # matches the real content the agent streamed, not just that some
    # bytes were split into 3 pieces.
    decoded_labels =
      all_events
      |> Enum.map(fn %{"result" => result} ->
        # v1.0 StreamResponse frame: the result is {"artifactUpdate": ...} —
        # the wrapper key is the discriminator, with no "kind" key anywhere.
        assert %{
                 "artifactUpdate" => %{
                   "artifact" => %{"parts" => [%{"data" => %{"label" => label}} = part]}
                 }
               } =
                 result

        refute Map.has_key?(part, "kind")
        label
      end)
      |> Enum.sort()

    assert decoded_labels == ["alpha", "bravo", "charlie"]

    # Every event round-tripped as a well-formed JSON-RPC 2.0 success
    # envelope with the id this test supplied.
    assert Enum.all?(all_events, fn event ->
             event["jsonrpc"] == "2.0" and event["id"] == "test-id"
           end)
  end

  test "AshA2A.Protocol.Client.SSE.feed/2 buffers a real event split across many single-byte feeds" do
    Ash.Seed.seed!(StreamingWidget, %{label: "solo"})

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        StreamingWidgetAgent
      ])

    message = data_message(%{"stream" => true})

    assert {:ok, task, enum} = AshA2A.Protocol.stream(StreamingWidgetAgent, message, [])

    # Shared ETS table across this file's tests (see note above) -- select
    # this test's own seeded row rather than assuming it is the only one.
    [part] =
      enum
      |> Enum.to_list()
      |> Enum.filter(fn %AshA2A.Protocol.Part.Data{data: %{label: label}} -> label == "solo" end)

    artifact = AshA2A.Protocol.Artifact.new([part])

    event =
      AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact, context_id: task.context_id)

    {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)
    payload = AshA2A.Protocol.JSONRPC.Response.success(1, encoded)
    wire = "data: #{Jason.encode!(payload)}\n\n"

    # Feed the real wire bytes one byte at a time -- the real parser must
    # emit nothing until the terminating "\n\n" boundary actually arrives.
    {events, _final_state} =
      wire
      |> String.graphemes()
      |> Enum.reduce({[], AshA2A.Protocol.Client.SSE.new()}, fn byte, {acc_events, state} ->
        {new_events, new_state} = AshA2A.Protocol.Client.SSE.feed(state, byte)
        {acc_events ++ new_events, new_state}
      end)

    assert [
             %{
               "result" => %{
                 "artifactUpdate" => %{
                   "artifact" => %{"parts" => [%{"data" => %{"label" => "solo"}}]}
                 }
               }
             }
           ] =
             events
  end
end

# ==============================================================================
# SECTION 7: Original test/ash_a2a_standing_receipt_chain_test.exs
# ==============================================================================

defmodule AshA2a.StandingReceiptChainTest do
  use ExUnit.Case, async: false

  alias AshA2a.StandingReceipt.Chain

  @genesis Chain.genesis()

  # --- real doc fixture: a temp file whose bytes we control fully ------------

  defp write_doc(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  defp append_revision(doc_path) do
    {out, 0} =
      run_task(["--in", doc_path, "--chain", Chain.chain_path(doc_path)])

    assert [_, head_line] = Regex.run(~r/CHAIN_HEAD:([0-9a-f]{64})/, out)
    {head_line, Chain.sha256_hex(File.read!(doc_path))}
  end

  defp run_task(args) do
    # drain any stale shell messages so the regex below can only match this run
    flush_shell()

    Mix.shell(Mix.Shell.Process)

    out =
      try do
        Mix.Tasks.AshA2a.StandingReceipt.Revision.run(args)
        collected()
      rescue
        e ->
          flunk("revision task raised: #{Exception.message(e)}")
      after
        Mix.shell(Mix.Shell.IO)
      end

    {out, 0}
  end

  defp flush_shell do
    receive do
      {:mix_shell, _, _} -> flush_shell()
      _ -> :ok
    after
      0 -> :ok
    end
  end

  defp collected do
    self()
    |> Process.info(:messages)
    |> elem(1)
    |> Enum.flat_map(fn
      {:mix_shell, :info, [msg]} -> [msg]
      {:mix_shell, :error, [msg]} -> [msg]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "l108-chain-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "fold" do
    test "empty chain folds to genesis" do
      assert {:ok, @genesis} == Chain.fold([])
    end

    test "single revision event folds off genesis" do
      event_id = Chain.sha256_hex("doc-v2")

      line =
        Jason.encode!(%{
          "event_type" => "receipt-revision",
          "event_id" => event_id,
          "commitment" => @genesis,
          "ts" => "2026-10-13T00:00:00Z"
        })

      assert {:ok, Chain.digest(@genesis, event_id)} == Chain.fold([line])
    end

    test "flipped commitment byte refuses" do
      event_id = Chain.sha256_hex("doc-v2")
      good = Chain.digest(@genesis, event_id)

      # a second event whose commitment has one nibble flipped
      tampered =
        Chain.digest(good, event_id)
        |> flip_first_byte()
        |> then(
          &Jason.encode!(%{
            "event_type" => "receipt-revision",
            "event_id" => Chain.sha256_hex("doc-v3"),
            "commitment" => &1,
            "ts" => "2026-10-13T00:00:01Z"
          })
        )

      assert {:refused, msg} = Chain.fold([tampered])
      assert msg =~ "does not match prior chain head"
    end

    test "unknown event_type refuses" do
      line =
        Jason.encode!(%{
          "event_type" => "forgery",
          "event_id" => "ff",
          "commitment" => @genesis,
          "ts" => "x"
        })

      assert {:refused, msg} = Chain.fold([line])
      assert msg =~ "unknown event_type"
    end
  end

  describe "revision flow (real mix task + real files)" do
    test "mint head, mutate doc, re-append; court refuses old head for mutated doc", %{dir: dir} do
      doc = write_doc(dir, "STANDING-RECEIPT.md", "receipt body v1")
      chain = Chain.chain_path(doc)

      # 1. mint head over v1
      {head1, _} = append_revision(doc)
      assert File.exists?(chain)
      assert {:ok, head1} == Chain.fold(chain_lines(chain))
      assert :ok == Chain.verify(doc)

      # 2. mutate the doc (edit that would pass a fresh-signature re-mint)
      File.write!(doc, "receipt body v2 -- edited")

      # 3. court refuses: head event_id no longer equals live doc sha
      assert {:refused, msg} = Chain.verify(doc)
      assert msg =~ "chain head event_id"
      assert msg =~ "re-mint"

      # 4. the documented re-mint flow: append a revision for the edited doc
      {head2, doc2_sha} = append_revision(doc)
      assert head2 == Chain.digest(head1, doc2_sha)
      assert :ok == Chain.verify(doc)
    end

    test "untouched doc verifies (multi-link chain)", %{dir: dir} do
      doc = write_doc(dir, "STANDING-RECEIPT.md", "stable body")

      {h1, _} = append_revision(doc)
      {h2, _} = append_revision(doc)
      {h3, _} = append_revision(doc)

      assert h1 != h2 and h2 != h3
      assert {:ok, h3} == Chain.fold(chain_lines(Chain.chain_path(doc)))
      assert :ok == Chain.verify(doc)
    end

    test "tampered chain file (flipped commitment byte) refuses", %{dir: dir} do
      doc = write_doc(dir, "STANDING-RECEIPT.md", "body")
      {_, _} = append_revision(doc)
      {_, _} = append_revision(doc)
      chain = Chain.chain_path(doc)

      lines = chain_lines(chain)
      flipped = flip_first_byte(Jason.decode!(hd(lines))["commitment"])

      # flip one byte inside the SECOND line's commitment
      tampered_lines =
        lines
        |> List.update_at(1, fn line ->
          String.replace(line, Jason.decode!(line)["commitment"], flipped)
        end)

      File.write!(chain, Enum.join(tampered_lines, "\n") <> "\n")

      assert {:refused, msg} = Chain.verify(doc)
      assert msg =~ "does not match prior chain head"

      # and the revision task refuses to append onto the broken chain
      Mix.shell(Mix.Shell.Process)

      assert catch_exit(append_revision_bare(doc)) != nil
      Mix.shell(Mix.Shell.IO)
    end

    test "back-compat: no chain file -> verify absent, fold not consulted", %{dir: dir} do
      doc = write_doc(dir, "STANDING-RECEIPT.md", "body")
      refute File.exists?(Chain.chain_path(doc))
      assert {:absent, path} = Chain.verify(doc)
      assert path == Chain.chain_path(doc)
    end
  end

  defp append_revision_bare(doc) do
    Mix.Tasks.AshA2a.StandingReceipt.Revision.run([
      "--in",
      doc,
      "--chain",
      Chain.chain_path(doc)
    ])
  end

  defp chain_lines(chain) do
    chain |> File.read!() |> String.split("\n", trim: true)
  end

  defp flip_first_byte(hex) when is_binary(hex) do
    first = String.at(hex, 0)
    swapped = if first == "0", do: "1", else: "0"
    swapped <> String.slice(hex, 1..-1//1)
  end
end

# ==============================================================================
# SECTION 8: Original test/ash_a2a_standing_receipt_verify_test.exs
# ==============================================================================

defmodule AshA2a.StandingReceiptVerifyTest do
  use ExUnit.Case, async: false

  @repo "/Users/sac/ash_a2a"
  @receipt Path.join(@repo, "docs/sjira/v26.10.8/STANDING-RECEIPT.md")
  # Frozen pre-blake3 fixture, signed under the documented v26.10.8 mint key:
  # d3fcc7395405739f76d7570e0804e79d6a1e4e60b42b1b93642bf033e62d239b
  # (its seed is not retained, so the fixture cannot be re-minted under that
  # identity — the happy-path court re-mints under a fresh key instead).
  @attestation Path.join(@repo, "docs/sjira/v26.10.8/STANDING-RECEIPT.attestation.json")

  @attest_bin "/Users/sac/graphlaw/target/debug/graphlaw-attest"

  # Loud skip (never a faked pass) when the sibling graphlaw build is absent.
  @happy_skip if File.exists?(@attest_bin),
                do: false,
                else: "SKIP: graphlaw-attest not built at #{@attest_bin}"

  @tag :tmp_dir
  @tag skip: @happy_skip
  test "verifies a receipt attested by the CURRENT graphlaw-attest (exit 0, VERIFIED)", context do
    %{tmp_dir: tmp} = context
    out = tmp <> "/receipt.md"
    File.cp!(@receipt, out)
    att = Path.rootname(out) <> ".attestation.json"

    # The v26.10.8 fixture attestation is a FROZEN pre-blake3 artifact (signed
    # under the documented v26.10.8 key; its seed is not retained, so it cannot
    # be re-minted under that identity). It still passes stage 1 (payload_sha256)
    # and the tamper court below, but the blake3-era graphlaw-attest structurally
    # refuses it ("missing payload_blake3"). So this happy-path court re-mints a
    # LIVE attestation over the same receipt doc with the current CLI under a
    # fresh key, then verifies through the real mix task.
    attest_bin = @attest_bin
    seed = Base.encode16(:crypto.strong_rand_bytes(32))

    {_, 0} =
      System.cmd(attest_bin, ~w(sign --key-seed-hex #{seed} --in #{out} --out #{att}),
        stderr_to_stdout: true
      )

    pk =
      case System.cmd(attest_bin, ~w(pubkey --key-seed-hex #{seed}), stderr_to_stdout: true) do
        {pk, 0} -> String.trim(pk)
      end

    {stdout, 0} =
      System.cmd(
        "mix",
        [
          "ash_a2a.standing_receipt.verify",
          "--in",
          out,
          "--attestation",
          att,
          "--trusted-key",
          pk
        ],
        cd: @repo,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    assert stdout =~ "VERIFIED"
  end

  @tag :tmp_dir
  test "refuses a tampered receipt (non-zero exit, REFUSED)", context do
    %{tmp_dir: tmp} = context
    out = tmp <> "/receipt.md"
    File.cp!(@receipt, out)
    att = Path.rootname(out) <> ".attestation.json"
    File.cp!(@attestation, att)
    # Mutate one byte of the payload.
    mutated =
      File.read!(out)
      |> String.replace("PARTIAL-ALIVE", "PARTIAL-ALIVX")
      |> tap(&File.write!(out, &1))

    {stdout, code} =
      System.cmd(
        "mix",
        [
          "ash_a2a.standing_receipt.verify",
          "--in",
          out,
          "--attestation",
          Path.rootname(out) <> ".attestation.json"
        ],
        cd: @repo,
        stderr_to_stdout: true
      )

    assert code != 0
    assert stdout =~ "REFUSED"
    assert stdout =~ "payload digest mismatch"
    # The mutated marker must actually differ from the minted file.
    assert mutated != File.read!(@receipt)
  end

  @tag :tmp_dir
  test "BLOCKED when graphlaw-attest binary is absent", context do
    %{tmp_dir: tmp} = context
    out = tmp <> "/receipt.md"
    File.cp!(@receipt, out)
    att = Path.rootname(out) <> ".attestation.json"
    File.cp!(@attestation, att)

    {stdout, code} =
      System.cmd(
        "mix",
        ~w(ash_a2a.standing_receipt.verify --in #{out} --attestation #{Path.rootname(out) <> ".attestation.json"} --attest-bin /nonexistent/graphlaw-attest),
        cd: @repo,
        stderr_to_stdout: true
      )

    # Note: explicit --attest-bin path that does not exist is treated as
    # present-but-failing by the binary stage; either non-zero REFUSED or a
    # BLOCKED exit is acceptable; it must NOT print VERIFIED.
    refute stdout =~ "VERIFIED"
    assert code != 0
  end
end

# ==============================================================================
# SECTION 9: Original test/ash_a2a_task_failed_state_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TaskFailedStateTest do
  @moduledoc """
  Real, unmocked proof that a real `AshA2A.Protocol.Agent` GenServer, generated by
  `AshA2A.Agent` over a genuinely-forbidding Ash resource, drives a real
  task through `:submitted -> :working -> :failed` -- not just `:completed`,
  which `test/ash_a2a_test.exs` and `test/ash_a2a_rap_battle_integration_test.exs`
  already cover.

  Assignment #6 (real task state machine transition to `:failed`). Existing
  coverage of the forbidden-dispatch error class
  (`test/ash_a2a_test.exs:101-137`) calls `AshA2A.Dispatcher.dispatch/3`
  directly -- bypassing the real `AshA2A.Protocol.Agent`/`AshA2A.Protocol.Agent.Runtime` state
  machine entirely, so nothing in this repo's test suite previously proved
  that a real, supervised `AshA2A.Protocol.Agent` process actually reaches the real
  `:failed` terminal state. This file closes that gap using only real,
  already-existing machinery:

  - `AshA2A.Test.Fixture.Locked` / `LockedDomain` (`test/support/fixture.ex`)
    -- a real `Ash.Resource` + `Ash.Policy.Authorizer` that always forbids.
  - `AshA2A.Test.Fixture.LockedAgent` (`test/support/failing_task_fixture.ex`)
    -- a real `AshA2A.Protocol.Agent` GenServer built with `use AshA2A.Agent` over
    `Locked`.
  - `AshA2A.Test.AgentSupervisorCase.start_supervised_agents!/2` -- the
    existing real `AshA2A.Protocol.AgentSupervisor.start_link/1` bootstrap helper.
  - `AshA2A.Test.MessageHelpers.data_message/1` -- the existing real
    `AshA2A.Protocol.Message.new_user/1` builder.

  No `Mock`/`mox`/`patch`/`monkeypatch` anywhere in this file.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Test.AgentSupervisorCase
  alias AshA2A.Test.Fixture.LockedAgent
  alias AshA2A.Test.MessageHelpers

  test "a real forbidden dispatch drives a real AshA2A.Protocol.Agent task through :submitted -> :working -> :failed" do
    {_sup, _registry} = AgentSupervisorCase.start_supervised_agents!(__MODULE__, [LockedAgent])

    agent_pid = GenServer.whereis(LockedAgent)
    assert is_pid(agent_pid)

    message = MessageHelpers.data_message(%{})

    # `LockedAgent.call/3` drives the message through the REAL
    # `AshA2A.Protocol.Agent.Runtime.process_message/5` -> `run_task/4` path
    # (`~/xaas/deps/a2a/lib/a2a/agent/runtime.ex:22-25,62-79`), which
    # unconditionally transitions the freshly-`Task.new/1`-created task
    # (born `:submitted`, `~/xaas/deps/a2a/lib/a2a/task.ex:69-77`) to
    # `:working` BEFORE calling `LockedAgent.handle_message/2` ==
    # `AshA2A.Agent.__dispatch__/3` == `AshA2A.Dispatcher.dispatch/5`. The
    # real `Ash.Policy.Authorizer` denial on `Locked`'s always-forbidding
    # policy surfaces as a real `%Ash.Error.Forbidden.Policy{}` with
    # `class: :forbidden`, which `AshA2A.Dispatcher.to_reply/1`
    # (`lib/ash_a2a/dispatcher.ex:553-556`) maps to a real
    # `{:error, "forbidden: " <> _}` reply tuple -- exactly the
    # `{:error, reason}` shape `AshA2A.Protocol.Agent.Runtime.handle_reply/2`
    # (`~/xaas/deps/a2a/lib/a2a/agent/runtime.ex:99-103`) transitions to
    # `:failed` for real, with a real `AshA2A.Protocol.Message.new_agent/1` error
    # message appended to task history.
    assert {:ok, task} = LockedAgent.call(agent_pid, message)

    assert task.status.state == :failed

    # `AshA2A.Protocol.Task.terminal?/1` (`~/xaas/deps/a2a/lib/a2a/task.ex:29-37`) --
    # real terminality check, not a hand-rolled duplicate of its state list.
    assert AshA2A.Protocol.Task.terminal?(task)

    # The real error message `handle_reply/2` builds
    # (`Message.new_agent("Error: " <> inspect(reason))`) is really stored
    # on the real task's `status.message` by `AshA2A.Protocol.Agent.State.transition/3`
    # (`~/xaas/deps/a2a/lib/a2a/agent/state.ex:21-23` --
    # `AshA2A.Protocol.Task.Status.new(new_state, message)`) -- not merely a bare
    # `:failed` atom with no accompanying, inspectable record of what
    # failed. `history` itself stays exactly `[user_message]`: unlike the
    # `:completed`/`:input_required` branches of `handle_reply/2`
    # (`~/xaas/deps/a2a/lib/a2a/agent/runtime.ex:83-98`), the real
    # `:error` branch (lines 99-103) never appends `error_msg` to
    # `task.history` -- only to `status.message`.
    # v1.1 timeline semantics: the failed branch now also records the agent
    # error message in history after the user message.
    assert [%AshA2A.Protocol.Message{role: :user}, %AshA2A.Protocol.Message{role: :agent}] =
             task.history

    assert %AshA2A.Protocol.Message{role: :agent} = agent_error_msg = task.status.message
    [%AshA2A.Protocol.Part.Text{text: error_text}] = agent_error_msg.parts
    assert error_text =~ "Error:"
    assert error_text =~ "forbidden"

    # A real terminal :failed task is really not cancelable -- proves the
    # :failed state genuinely feeds back into `AshA2A.Protocol.Agent`'s own cancel
    # guard (`~/xaas/deps/a2a/lib/a2a/agent.ex:308`), not just a status
    # label with no other real behavioral consequence.
    assert {:error, :not_cancelable} = LockedAgent.cancel(agent_pid, task.id)

    # Fetching the same task back by id from the real agent process
    # confirms the :failed state was really persisted into `AshA2A.Protocol.Agent.State`
    # (`State.put_task/2` in the real `handle_call({:message, ...})` clause),
    # not just returned transiently in the `call/3` reply.
    assert {:ok, %AshA2A.Protocol.Task{status: %AshA2A.Protocol.Task.Status{state: :failed}}} =
             LockedAgent.get_task(agent_pid, task.id)
  end
end

# ==============================================================================
# SECTION 10: Original test/ash_a2a_telemetry_ocel_forwarder_bounded_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.OcelForwarderBoundedTest do
  @moduledoc """
  Chicago-school evidence for A2A-2602: OCEL forwarding has a hard concurrent
  task ceiling, and every event that cannot enter that bounded task supervisor
  is explicitly accounted as a shed.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.Facilitator

  @max_children 2
  @burst 12
  @slow_ms 400

  defmodule SlowOcelIngest do
    use Plug.Router

    @slow_ms 400

    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      Agent.update(SlowOcelIngest.Store, fn %{active: active, max: max} = state ->
        %{state | active: active + 1, max: max(max, active + 1)}
      end)

      Process.sleep(@slow_ms)

      Agent.update(SlowOcelIngest.Store, fn %{active: active} = state ->
        %{state | active: active - 1}
      end)

      Agent.update(SlowOcelIngest.Store, fn %{served: served} = state ->
        %{state | served: served + 1}
      end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(201, Jason.encode!(%{"ok" => true}))
    end

    match(_) do
      Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  setup do
    {:ok, _} =
      Agent.start_link(fn -> %{active: 0, max: 0, served: 0} end, name: SlowOcelIngest.Store)

    %{port: port} = AshA2A.Test.EphemeralHttp.start!(SlowOcelIngest)

    supervisor_name =
      Module.concat(__MODULE__, "BoundedTaskSupervisor#{System.unique_integer([:positive])}")

    start_supervised!({Task.Supervisor, name: supervisor_name, max_children: @max_children})

    parent = self()

    :ok =
      :telemetry.attach_many(
        {__MODULE__, :shed_probe},
        [[:ash_a2a, :ocel, :shed]],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:shed_telemetry, metadata})
        end,
        nil
      )

    Application.put_env(:ash_a2a, :ocel_ingest_url, "http://127.0.0.1:#{port}")
    Application.put_env(:ash_a2a, :ocel_task_supervisor, supervisor_name)
    Application.put_env(:ash_a2a, :ocel_ingest_timeout_ms, @slow_ms * 3)
    :ok = AshA2A.Telemetry.OcelForwarder.attach!()

    on_exit(fn ->
      AshA2A.Telemetry.OcelForwarder.detach()
      :telemetry.detach({__MODULE__, :shed_probe})
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
      Application.delete_env(:ash_a2a, :ocel_task_supervisor)
      Application.delete_env(:ash_a2a, :ocel_ingest_timeout_ms)
    end)

    {:ok, supervisor_name: supervisor_name}
  end

  test "a real dispatch burst never exceeds max_children and every excess event is accounted",
       %{supervisor_name: supervisor_name} do
    baseline_sheds = AshA2A.Telemetry.OcelForwarder.shed_count()

    for i <- 1..@burst do
      message = data_message(%{phase: :"bounded_probe_#{i}", prompt_text: "burst #{i}"})
      assert {:reply, _} = AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator, [], nil)
    end

    assert %{active: active, max: observed_max} = Agent.get(SlowOcelIngest.Store, & &1)
    assert active <= @max_children
    assert observed_max <= @max_children

    counts = Supervisor.count_children(Process.whereis(supervisor_name))
    assert counts.active <= @max_children
    assert counts.workers <= @max_children

    shed_delta = AshA2A.Telemetry.OcelForwarder.shed_count() - baseline_sheds
    assert shed_delta > 0
    assert_receive {:shed_telemetry, %{reason: :max_children}}, 1_000

    wait_until(fn ->
      Agent.get(SlowOcelIngest.Store, & &1).served + shed_delta == @burst
    end)

    final = Agent.get(SlowOcelIngest.Store, & &1)
    assert final.max <= @max_children
    assert final.served + shed_delta == @burst
  end

  test "a missing task supervisor is also an accounted shed rather than a synchronous crash" do
    missing =
      Module.concat(__MODULE__, "MissingTaskSupervisor#{System.unique_integer([:positive])}")

    Application.put_env(:ash_a2a, :ocel_task_supervisor, missing)
    baseline_sheds = AshA2A.Telemetry.OcelForwarder.shed_count()

    message = data_message(%{phase: :missing_supervisor, prompt_text: "missing supervisor"})
    assert {:reply, _} = AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator, [], nil)

    assert AshA2A.Telemetry.OcelForwarder.shed_count() - baseline_sheds == 1

    assert_receive {:shed_telemetry, %{reason: {:task_supervisor_exit, _reason}}}, 1_000
  end

  defp wait_until(fun) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    unless fun.() or System.monotonic_time(:millisecond) > deadline do
      Process.sleep(50)
      wait_until(fun)
    end
  end
end

# ==============================================================================
# SECTION 11: Original test/ash_a2a_telemetry_ocel_forwarder_command_bus_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.OcelForwarderCommandBusTest do
  @moduledoc """
  Chicago-school test proving the real fix for the disclosed OCEL
  double-event-emission defect on CommandBus-routed dispatch: before this
  fix, `AshA2A.CommandBus.run/4` internally called
  `AshA2A.Dispatcher.dispatch/5` (`command_bus.ex`), whose own
  `:telemetry.span([:ash_a2a, :dispatch], ...)` (`dispatcher.ex:137`) fired
  `[:ash_a2a, :dispatch, :stop]` unconditionally, AND `CommandBus.run/4`
  separately fired `[:ash_a2a, :receipt, :committed]`
  (`command_bus.ex#emit_receipt/1`) after every commit -- and
  `AshA2A.Telemetry.OcelForwarder` had independent handlers on both events,
  each independently POSTing its own OCEL v2 event to the real ingest
  endpoint, so one CommandBus-routed dispatch produced two OCEL events for
  one logical command.

  Reuses this file's sibling `AshA2A.Telemetry.OcelForwarderTest`'s real
  Bandit `MicroBeamOcelIngest` fixture pattern and the same real FreedomGym
  `Facilitator` fixture's `:next_phase` skill (already used there, giving a
  real non-nil `object_id`/`relationships` to verify survive the merge) --
  no mocks, a real Bandit HTTP listener, a real `Req.post`, a real captured
  HTTP request body asserted on directly.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Test.Fixture.FreedomGym.Facilitator

  defmodule MicroBeamOcelIngest do
    @moduledoc """
    Same minimal real `Plug.Router` shape as
    `AshA2A.Telemetry.OcelForwarderTest.MicroBeamOcelIngest` -- duplicated
    (not shared/aliased) so this test file's real Bandit listener and Agent
    store are fully independent of the sibling test file's, avoiding any
    cross-file process-naming collision under `async: false`.
    """
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      case conn.body_params do
        %{"events" => events} when is_list(events) ->
          Agent.update(MicroBeamOcelIngest.Store, fn acc -> acc ++ events end)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(201, Jason.encode!(%{"ok" => true, "accepted" => events}))

        _ ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            422,
            Jason.encode!(%{"ok" => false, "error" => "expected events list"})
          )
      end
    end

    match(_) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        404,
        Jason.encode!(%{"ok" => false, "error" => "route_not_admitted"})
      )
    end
  end

  defp start_micro_beam_ocel_ingest! do
    {:ok, _} = Agent.start_link(fn -> [] end, name: MicroBeamOcelIngest.Store)
    %{pid: pid, base_url: base_url} = AshA2A.Test.EphemeralHttp.start!(MicroBeamOcelIngest)

    on_exit(fn ->
      Process.exit(pid, :normal)
      if Process.whereis(MicroBeamOcelIngest.Store), do: Agent.stop(MicroBeamOcelIngest.Store)
    end)

    base_url
  end

  setup do
    base_url = start_micro_beam_ocel_ingest!()
    Application.put_env(:ash_a2a, :ocel_ingest_url, base_url)
    :ok = AshA2A.Telemetry.OcelForwarder.attach!()

    # Real on-disk EKV receipt store (the receipt_store_ekv_test.exs:25-36
    # pattern: unique name + unique data_dir + cluster_size: 1 + on_exit
    # cleanup) rather than the library-default Memory store -- the OCEL
    # forwarder court's subject is event dedup on the wire, not store
    # durability, so the durable store is the honest default here and the
    # in-repo Memory consumption is one fewer legacy-default consumer.
    ekv_name = :"ash_a2a_ocel_fwd_ekv_#{System.unique_integer([:positive])}"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_ocel_fwd_ekv_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

    on_exit(fn ->
      AshA2A.Telemetry.OcelForwarder.detach()
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
    end)

    {:ok, base_url: base_url, store: AshA2A.ReceiptStore.Ekv, store_opts: [name: ekv_name]}
  end

  test "a real CommandBus-routed :next_phase dispatch produces exactly ONE OCEL event, carrying both receipt and dispatch evidence",
       %{store: store, store_opts: store_opts} do
    plan_name = :"ocel_dedupe_command_bus_test_#{System.unique_integer([:positive])}"
    capability_id = "AshA2A.Test.Fixture.FreedomGym.Facilitator.next_phase"
    principal = Identity.principal("subject-1")
    authority = Authority.new(principal, capability_id, token_id: "auth-next-phase-1")

    command =
      Command.new(capability_id,
        command_id: "next-phase-1",
        agent_id: "agent-1",
        principal_id: principal,
        authority: authority,
        input: %{plan_name: plan_name, prompt_text: "next real phase, please"}
      )

    message = data_message(%{plan_name: plan_name, prompt_text: "next real phase, please"})

    assert {:ok, receipt} =
             CommandBus.run(command, message, Facilitator,
               store: store,
               store_opts: store_opts
             )

    assert receipt.status == :completed
    assert receipt.consequence == :change

    # The durable store is real, not nominal: a committed receipt over
    # on-disk EKV stands :durable (Memory would leave it :observed).
    assert receipt.standing == :durable

    # Before the fix, two events would have landed here (one from the raw
    # `[:ash_a2a, :dispatch, :stop]` span, one from
    # `[:ash_a2a, :receipt, :committed]`) -- this proves exactly one does.
    events = wait_for_events(1, 2_000)
    assert [event] = events

    # Receipt-derived evidence (from `AshA2A.SemanticProjection.ocel_event/1`)
    # is preserved.
    assert event["attributes"]["command_id"] == Identity.external(receipt.command_id)
    assert event["attributes"]["capability_id"] == capability_id
    assert event["attributes"]["status"] == "completed"

    # Dispatch-derived evidence (from the raw `[:ash_a2a, :dispatch, :stop]`
    # span this fix merges in rather than discards) is also preserved: the
    # real object-identity relationship naming the real plan instance, and
    # the real dispatch duration.
    assert [%{"qualifier" => "acted_on", "object_id" => object_id}] = event["relationships"]
    assert object_id == Atom.to_string(plan_name)
    assert event["attributes"]["duration_native"]
    assert event["attributes"]["skill_name"] == "next_phase"
  end

  defp wait_for_events(min_count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(min_count, deadline)
  end

  defp poll_until(min_count, deadline) do
    events = Agent.get(MicroBeamOcelIngest.Store, & &1)

    cond do
      length(events) >= min_count ->
        events

      System.monotonic_time(:millisecond) >= deadline ->
        events

      true ->
        Process.sleep(25)
        poll_until(min_count, deadline)
    end
  end
end

# ==============================================================================
# SECTION 12: Original test/ash_a2a_telemetry_ocel_forwarder_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.OcelForwarderTest do
  @moduledoc """
  Chicago-school test: real `:telemetry` emission from `AshA2A.Dispatcher`'s
  own already-real `:telemetry.span([:ash_a2a, :dispatch], ...)`
  (dispatcher.ex:137-140), forwarded by the real
  `AshA2A.Telemetry.OcelForwarder` handler, landing at a REAL local HTTP
  server whose route/decode contract mirrors beam4pm's real, already-running
  `BeamPM.OcelIngest.Router` byte-for-byte (read directly from
  `~/beam4pm/lib/beam4pm_ocel_ingest.ex` before writing this fixture -- same
  `POST /ocel/events`, `{"events": [...]}`, `event_id`/`event_type`/
  `event_time`/`attributes` shape, same 201/422 status convention).

  Exercises a REAL FreedomGym fixture (`AshA2A.Test.Fixture.FreedomGym.
  Facilitator`, already-existing test capital, not invented for this test)
  dispatched through the real `AshA2A.Dispatcher.dispatch/5` -- proving the
  exact claim this module exists to satisfy: any real skill dispatch across
  any AshA2A-backed app (FreedomGym Chicago-core, LLM-backed avatars, the
  rap-battle integration, or real production A2A traffic) gets real OCEL v2
  visibility with zero new instrumentation at each call site, because the
  telemetry span already existed before this module was written.

  No mocks: a real Bandit HTTP listener, a real Req.post, a real captured
  HTTP request body, asserted on directly.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Protocol.Message
  alias AshA2A.Protocol.Part
  alias AshA2A.{Command, Identity, Receipt}
  alias AshA2A.Test.Fixture.FreedomGym.Facilitator

  defmodule MicroBeamOcelIngest do
    @moduledoc """
    Minimal real Plug.Router mirroring beam4pm's actual
    `BeamPM.OcelIngest.Router` contract for `POST /ocel/events` only (the
    one route this forwarder uses) -- captures the real decoded event(s)
    into a real Agent so the test can assert on exactly what arrived, real
    HTTP round trip, not a hand-decoded closure.
    """
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      case conn.body_params do
        %{"events" => events} when is_list(events) ->
          Agent.update(MicroBeamOcelIngest.Store, fn acc -> acc ++ events end)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(201, Jason.encode!(%{"ok" => true, "accepted" => events}))

        _ ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            422,
            Jason.encode!(%{"ok" => false, "error" => "expected events list"})
          )
      end
    end

    match(_) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        404,
        Jason.encode!(%{"ok" => false, "error" => "route_not_admitted"})
      )
    end
  end

  defp start_micro_beam_ocel_ingest! do
    {:ok, _} = Agent.start_link(fn -> [] end, name: MicroBeamOcelIngest.Store)
    %{pid: pid, base_url: base_url} = AshA2A.Test.EphemeralHttp.start!(MicroBeamOcelIngest)

    on_exit(fn ->
      Process.exit(pid, :normal)
      stop_named_agent(MicroBeamOcelIngest.Store)
    end)

    base_url
  end

  # The Agents above are `start_link`ed to the test process, so they begin
  # dying the moment the test process exits -- concurrently with this
  # `on_exit/1` callback, which ExUnit runs in a separate process afterwards.
  # A bare `if Process.whereis(name), do: Agent.stop(name)` is therefore a
  # real time-of-check/time-of-use race: `whereis` can see the dying Agent
  # and `Agent.stop/1` then exits with `:noproc` (observed, reproducible under
  # `mix test --seed 162937`). Stop by pid, tolerate it already being gone,
  # and wait for the real `:DOWN` so the name is unregistered before the next
  # test's `Agent.start_link(name: ...)` can run.
  defp stop_named_agent(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      agent ->
        ref = Process.monitor(agent)

        try do
          Agent.stop(agent)
        catch
          :exit, _already_gone -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, ^agent, _reason} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  defmodule SlowMicroBeamOcelIngest do
    @moduledoc """
    Real Plug.Router mirroring `MicroBeamOcelIngest` above, but the
    `POST /ocel/events` handler is GATED: it notifies the owning test
    process (pid read from a real Agent) that it is holding the request,
    then blocks until that test sends `:release` -- a real slow ingest
    endpoint whose slowness is controlled by the test, not by a wall-clock
    sleep (TQ-12: no race between a fixed server delay and the dispatch
    duration).
    """
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      owner = Agent.get(SlowMicroBeamOcelIngest.Owner, & &1)
      send(owner, {:slow_ingest_request_held, self()})

      receive do
        :release -> :ok
      after
        60_000 -> :ok
      end

      case conn.body_params do
        %{"events" => events} when is_list(events) ->
          Agent.update(SlowMicroBeamOcelIngest.Store, fn acc -> acc ++ events end)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(201, Jason.encode!(%{"ok" => true, "accepted" => events}))

        _ ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            422,
            Jason.encode!(%{"ok" => false, "error" => "expected events list"})
          )
      end
    end
  end

  defp start_slow_ocel_ingest!(owner) do
    {:ok, _} = Agent.start_link(fn -> [] end, name: SlowMicroBeamOcelIngest.Store)
    {:ok, _} = Agent.start_link(fn -> owner end, name: SlowMicroBeamOcelIngest.Owner)
    %{pid: pid, base_url: base_url} = AshA2A.Test.EphemeralHttp.start!(SlowMicroBeamOcelIngest)

    on_exit(fn ->
      Process.exit(pid, :normal)

      stop_named_agent(SlowMicroBeamOcelIngest.Store)
      stop_named_agent(SlowMicroBeamOcelIngest.Owner)
    end)

    base_url
  end

  defp wait_for_slow_events(min_count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_slow_until(min_count, deadline)
  end

  defp poll_slow_until(min_count, deadline) do
    events = Agent.get(SlowMicroBeamOcelIngest.Store, & &1)

    cond do
      length(events) >= min_count ->
        events

      System.monotonic_time(:millisecond) >= deadline ->
        events

      true ->
        Process.sleep(25)
        poll_slow_until(min_count, deadline)
    end
  end

  setup do
    base_url = start_micro_beam_ocel_ingest!()
    Application.put_env(:ash_a2a, :ocel_ingest_url, base_url)
    :ok = AshA2A.Telemetry.OcelForwarder.attach!()

    on_exit(fn ->
      AshA2A.Telemetry.OcelForwarder.detach()
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
    end)

    {:ok, base_url: base_url}
  end

  test "a real AshA2A skill dispatch produces a real OCEL v2 event at the ingest endpoint" do
    message =
      Message.new_user([
        Part.Data.new(%{
          "phase" => :trust_god,
          "prompt_text" => "Name one thing you trust today."
        })
      ])

    assert {:reply, _parts} = AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator)

    # Real HTTP forwarding happens on a supervised `Task` the telemetry
    # handler starts and does not await, so give it a real, generous window
    # for the async POST to land rather than asserting on the very next line
    # with zero tolerance.
    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["event_type"] == "ash_a2a.dispatch.facilitator.run_phase"
    assert event["event_id"]
    assert event["event_time"]
    assert event["attributes"]["skill_name"] == "run_phase"
    assert event["attributes"]["reply_type"] == "reply"
    refute Map.has_key?(event["attributes"], "stage")
  end

  # `:next_phase` is a `:change` skill, so it reaches the dispatcher only
  # through the real `AshA2A.CommandBus` (sole-DO fence, `AshA2A.BrceAnchor`);
  # the forwarder merges the dispatch span into the one receipt event.
  test "a real :next_phase dispatch forwards a real, non-empty OCEL relationships entry naming the real plan instance" do
    plan_name = :"ocel_forwarder_relationships_test_#{System.unique_integer([:positive])}"

    message =
      Message.new_user([
        Part.Data.new(%{plan_name: plan_name, prompt_text: "next real phase, please"})
      ])

    assert {:reply, _parts} =
             AshA2A.Test.ReceiptedDispatch.dispatch(
               :next_phase,
               message,
               Facilitator,
               [],
               nil
             )

    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["attributes"]["skill_name"] == "next_phase"
    assert [%{"qualifier" => "acted_on", "object_id" => object_id}] = event["relationships"]
    assert object_id == Atom.to_string(plan_name)
  end

  test "a real :run_phase dispatch (no real object identity available) forwards an empty relationships array, never a fabricated one" do
    message =
      Message.new_user([
        Part.Data.new(%{"phase" => :trust_god, "prompt_text" => "no plan_name here"})
      ])

    assert {:reply, _parts} = AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator)

    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["relationships"] == []
  end

  test "a real receipt-committed event reached without a preceding CommandBus-routed dispatch span (receipt_event/1's nil-dispatch branch) still carries the relationships key" do
    # `AshA2A.Telemetry.OcelForwarder.receipt_event/1`'s nil branch is taken
    # whenever `[:ash_a2a, :receipt, :committed]` fires and
    # `Process.delete(:ash_a2a_ocel_pending_dispatch)` finds nothing stashed
    # -- exactly what `AshA2A.CommandBus.run/4`'s `emit_receipt/1` call is
    # real production shape of, and exactly what a direct (non-CommandBus)
    # committer of a receipt would also produce. Firing the exact same real
    # `:telemetry.execute/3` call `emit_receipt/1` makes, with a real
    # `%AshA2A.Receipt{}` built the same way
    # `AshA2A.SemanticProjectionTest` builds one, exercises this real branch
    # directly without going through CommandBus -- no mock, a real telemetry
    # dispatch to the real attached handler, landing at the real Bandit
    # ingest fixture.
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "nil-dispatch-branch-1",
        agent_id: "agent-1",
        principal_id: "principal-1"
      )

    receipt =
      Receipt.from_reply(
        command,
        Identity.execution("exec-nil-dispatch-1"),
        :observe,
        {:reply, []}
      )

    :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: receipt})

    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["attributes"]["command_id"] == Identity.external(receipt.command_id)
    assert Map.has_key?(event, "relationships")
    assert event["relationships"] == []
  end

  test "a real refused dispatch (unknown skill) still produces real OCEL evidence -- refusals are first-class" do
    message = Message.new_user([Part.Data.new(%{})])

    assert {:error, {:skill_lookup, {:unknown_skill, :not_a_real_skill}}} =
             AshA2A.Dispatcher.dispatch(:not_a_real_skill, message, Facilitator)

    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["attributes"]["stage"] == "skill_lookup"
    assert event["attributes"]["error"] =~ "unknown_skill"
  end

  test "a real dispatch against a slow OCEL ingest endpoint returns while the endpoint is still holding the POST, proving the POST is truly offloaded" do
    # Real gated HTTP server: the /ocel/events handler holds the request
    # until this test releases it. Before the async offload, `post_event/2`'s
    # `Req.post/2` executed synchronously inside `handle_event/4`, which
    # `:telemetry.span/3` (`dispatcher.ex:137`) runs synchronously in the
    # calling process -- so `AshA2A.Dispatcher.dispatch/5` itself would have
    # blocked until the response. In the real single-mailbox `AshA2A.Protocol.Agent`
    # GenServer (`agent.ex`), that means every other caller queued behind it
    # would have blocked too.
    #
    # TQ-12: no wall-clock margin decides this test. The client
    # `receive_timeout` is raised to 60s, so a synchronous (regressed) POST
    # could not return the dispatch call before the 60s timeout; the dispatch
    # is given 10s to return while the server is provably still holding the
    # request (Store empty, response not sent). A 50x gap, not a 100ms one.
    previous_timeout = Application.get_env(:ash_a2a, :ocel_ingest_timeout_ms)
    Application.put_env(:ash_a2a, :ocel_ingest_timeout_ms, 60_000)

    on_exit(fn ->
      if previous_timeout,
        do: Application.put_env(:ash_a2a, :ocel_ingest_timeout_ms, previous_timeout),
        else: Application.delete_env(:ash_a2a, :ocel_ingest_timeout_ms)
    end)

    slow_url = start_slow_ocel_ingest!(self())
    Application.put_env(:ash_a2a, :ocel_ingest_url, slow_url)

    message =
      Message.new_user([
        Part.Data.new(%{
          "phase" => :trust_god,
          "prompt_text" => "must not block on a slow OCEL ingest endpoint"
        })
      ])

    dispatch = Task.async(fn -> AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator) end)

    assert {:ok, {:reply, _parts}} = Task.yield(dispatch, 10_000),
           "the dispatch call did not return while the OCEL endpoint was still holding " <>
             "the POST -- the POST is not actually offloaded"

    # The POST really reached the endpoint and is still being held: the
    # dispatch returned before any response existed.
    assert_receive {:slow_ingest_request_held, handler}, 10_000
    assert Agent.get(SlowMicroBeamOcelIngest.Store, & &1) == []

    send(handler, :release)

    # The event still eventually arrives -- offloading to a Task never drops
    # it, only defers the network call off the calling process.
    events = wait_for_slow_events(1, 10_000)

    assert [event] = events
    assert event["event_type"] == "ash_a2a.dispatch.facilitator.run_phase"
  end

  defp wait_for_events(min_count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(min_count, deadline)
  end

  defp poll_until(min_count, deadline) do
    events = Agent.get(MicroBeamOcelIngest.Store, & &1)

    cond do
      length(events) >= min_count ->
        events

      System.monotonic_time(:millisecond) >= deadline ->
        events

      true ->
        Process.sleep(25)
        poll_until(min_count, deadline)
    end
  end
end

# ==============================================================================
# SECTION 13: Original test/ash_a2a_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ATest do
  @moduledoc """
  Chicago-style coverage against real compiled Ash resources and the real A2A
  structs. v26.9.12 additionally proves that public Ash actions are the
  canonical capability source and that the A2A DSL is residual metadata only.
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers
  import Spark.Test, only: [assert_dsl_error: 2]

  alias AshA2A.Test.Fixture.Echo
  alias AshA2A.Test.Fixture.ZeroConfig
  alias AshA2A.Test.Fixture.ZeroConfigDomain

  test "AshA2A.Info.capability_index?/1 is true for the real compiled fixture" do
    assert AshA2A.Info.capability_index?(Echo)
  end

  test "the persisted override resolves to a derived capability for the real public :read action" do
    assert [
             %AshA2A.Skill{
               id: "AshA2A.Test.Fixture.Echo.read",
               name: :echo,
               resource: Echo,
               action: :read
             }
           ] = AshA2A.Info.capability_index(Echo)
  end

  test "the derived skill's domain is the real, statically resolved domain" do
    assert [%AshA2A.Skill{domain: AshA2A.Test.Fixture.Domain}] =
             AshA2A.Info.capability_index(Echo)

    assert Ash.Resource.Info.domain(Echo) == AshA2A.Test.Fixture.Domain
  end

  test "the built AgentCard uses canonical capability identity and residual display name" do
    agent_card = AshA2A.Info.agent_card(Echo, name: "echo_agent")

    assert %AshA2A.Protocol.AgentCard{name: "echo_agent"} = agent_card

    assert [%{id: "AshA2A.Test.Fixture.Echo.read", name: "echo"}] =
             agent_card.skills
  end

  test "zero configuration projects public Ash actions and excludes private actions" do
    assert [
             %AshA2A.Skill{
               id: "AshA2A.Test.Fixture.ZeroConfig.visible",
               name: :visible,
               resource: ZeroConfig,
               action: :visible
             }
           ] = AshA2A.Info.capability_index(ZeroConfig)

    refute Enum.any?(AshA2A.Info.capability_index(ZeroConfig), &(&1.action == :internal))
  end

  test "domain capability projection deterministically composes resource public actions" do
    assert [
             %AshA2A.Skill{
               id: "AshA2A.Test.Fixture.ZeroConfig.visible",
               resource: ZeroConfig,
               action: :visible
             }
           ] = AshA2A.Info.capability_index(ZeroConfigDomain)

    ids = Enum.map(AshA2A.Info.capability_index(AshA2A.Test.Fixture.Domain), & &1.id)
    assert ids == Enum.sort(ids)
    assert "AshA2A.Test.Fixture.Echo.read" in ids
  end

  test "the skill's own resolved domain is accepted by a real Ash.Query.for_read/3 call" do
    [%AshA2A.Skill{domain: domain} = skill] = AshA2A.Info.capability_index(Echo)
    refute is_nil(domain)

    assert {:ok, []} =
             skill.resource
             |> Ash.Query.for_read(:read, %{}, domain: domain)
             |> Ash.read(domain: domain)
  end

  test "AshA2A.Dispatcher.dispatch/3 dispatches the real :echo skill without a KeyError" do
    message = data_message(%{})

    assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{results: []}}]} =
             AshA2A.Dispatcher.dispatch(:echo, message, Echo)
  end

  test "AshA2A.Dispatcher.dispatch/3 returns {:stream, _} for a real :echo read when the caller opts in" do
    message = data_message(%{"stream" => true})

    assert {:stream, stream} = AshA2A.Dispatcher.dispatch(:echo, message, Echo)
    assert Enum.to_list(stream) == []
  end

  test "AshA2A.Dispatcher.dispatch/3 returns {:error, {:unknown_skill, _}} for an unknown skill name" do
    message = data_message(%{})

    assert {:error, {:skill_lookup, {:unknown_skill, :no_such_skill}}} =
             AshA2A.Dispatcher.dispatch(:no_such_skill, message, Echo)
  end

  test "AshA2A.Dispatcher.dispatch/3 surfaces a real forbidden error as a readable class-labeled string" do
    alias AshA2A.Test.Fixture.Locked

    message = data_message(%{})
    assert {:error, reason} = AshA2A.Dispatcher.dispatch(:list, message, Locked)

    class_reason =
      case reason do
        {_stage, inner} when is_binary(inner) -> inner
        other -> other
      end

    assert is_binary(class_reason)
    assert class_reason =~ ~r/^forbidden: /
    refute class_reason =~ "{:forbidden"
    refute match?({:forbidden, _}, class_reason)
  end

  test "AshA2A.Info.skill/2 returns a real {:error, :skill_not_found} for an unknown skill name" do
    assert AshA2A.Info.skill(Echo, :no_such_skill) == {:error, :skill_not_found}
  end

  test "AshA2A.Info.skill/2 resolves the stable canonical A2A capability id" do
    assert {:ok, %AshA2A.Skill{name: :echo, action: :read}} =
             AshA2A.Info.skill(Echo, "AshA2A.Test.Fixture.Echo.read")
  end

  test "AshA2A.Verify fails closed when an override names a nonexistent action" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.Fixture.BadAction do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          a2a do
            skill(:bogus, :not_a_real_action)
          end
        end
      end

    assert error.message =~ "REFUSED_ACTION_NOT_FOUND"
    assert error.message =~ "not_a_real_action"
  end

  test "AshA2A.Verify refuses attempts to expose a private Ash action" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.Fixture.PrivateActionOverride do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            read :secret do
              public?(false)
            end
          end

          a2a do
            skill(:secret, :secret)
          end
        end
      end

    assert error.message =~ "REFUSED_ACTION_NOT_PUBLIC"
    assert error.message =~ "secret"
  end

  test "duplicate skill override names are rejected structurally by Spark" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.Fixture.DuplicateName do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read, :destroy])
          end

          a2a do
            skill(:dup, :read)
            skill(:dup, :destroy)
          end
        end
      end

    assert error.message =~ "duplicate"
    assert error.message =~ "dup"
  end

  test "a real AshA2A.Protocol.AgentSupervisor-started AshA2A.Agent dispatches the real :echo skill" do
    alias AshA2A.Test.Fixture.EchoAgent

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    message = data_message(%{})

    assert {:ok, task} = EchoAgent.call(EchoAgent, message)
    assert task.status.state == :completed

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: %{results: []}}]}] =
             task.artifacts
  end
end

# ==============================================================================
# SECTION 14: Original test/ash_a2a_trace_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.Fixture.TraceNoteAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.TenantActorNote,
    name: "trace_note_agent"
end

defmodule AshA2A.TraceTest do
  @moduledoc """
  ZD2 court: TRACE-compliant trace export for A2A task sagas.

  Real `message/send` dispatch through the real transport plug stack
  (`AshA2A.Protocol.Plug.Auth` -> `AshA2A.Trace.Plug` ->
  `AshA2A.A2ATransport.Plug`) drives a real saga (dispatch -> authority ->
  actuation -> receipt); the exported trace must carry the full span tree
  with correct parent links and the wire task ids. Replay determinism and
  OTLP/JSON export are asserted on the same real documents. No mocks.
  """

  use ExUnit.Case, async: true

  import Plug.Conn

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Protocol.Plug.Auth
  alias AshA2A.Test.Fixture.TenantActorNote
  alias AshA2A.Test.Fixture.TraceNoteAgent

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}
  @identity %{id: "user-trace-1", tenant: "trace"}

  def verify("bearer", "trace-token", _conn), do: {:ok, @identity}
  def verify("bearer", "other-token", _conn), do: {:ok, %{id: "user-other", tenant: "other"}}
  def verify(_scheme, _token, _conn), do: {:error, "invalid token"}

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"trace_note_agent_#{uniq}"
    transport = :"a2a_transport_trace_#{uniq}"

    start_supervised!({TraceNoteAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    :ok = AshA2A.Trace.Recorder.ensure()

    AshA2A.Test.AuthorityGrantCase.grant!([{@identity, TenantActorNote, ["create_note"]}])

    %{
      agent: agent,
      transport: transport,
      auth: Auth.init(schemes: @schemes, verify: &__MODULE__.verify/3),
      trace_plug: AshA2A.Trace.Plug.init(agent: agent, transport: transport),
      transport_plug:
        TransportPlug.init(agent: agent, base_url: "http://x/a2a", transport: transport)
    }
  end

  # -- pipeline ------------------------------------------------------------------

  defp post(ctx, token, params) do
    body =
      Jason.encode!(
        Map.merge(%{"jsonrpc" => "2.0", "id" => 1, "method" => "message/send"}, %{params: params})
      )

    conn =
      Plug.Test.conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Auth.call(ctx.auth)

    refute conn.halted

    conn
    |> AshA2A.Trace.Plug.call(ctx.trace_plug)
    |> then(fn conn ->
      if conn.halted, do: conn, else: TransportPlug.call(conn, ctx.transport_plug)
    end)
  end

  defp get_trace(ctx, token, task_id, query \\ "") do
    conn =
      Plug.Test.conn(:get, "/tasks/#{task_id}/trace#{query}")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Auth.call(ctx.auth)

    refute conn.halted
    served = AshA2A.Trace.Plug.call(conn, ctx.trace_plug)
    assert served.halted
    served
  end

  defp send_create(ctx, label) do
    msg =
      %{
        AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"body" => label})])
        | metadata: %{"skill" => "create_note"}
      }

    {:ok, msg_json} = AshA2A.Protocol.JSON.encode(msg)

    conn = post(ctx, "trace-token", %{"message" => msg_json})
    assert conn.status == 200

    %{"result" => %{"task" => task}} = Jason.decode!(conn.resp_body)
    assert %{"status" => %{"state" => "TASK_STATE_COMPLETED"}} = task
    task
  end

  defp span_named(doc, name), do: Enum.find(doc["spans"], &match?(%{"name" => ^name}, &1))

  # -- the court -------------------------------------------------------------------

  test "real dispatch through the transport exports the full saga span tree", ctx do
    task = send_create(ctx, "trace-saga-1")
    task_id = task["id"]

    served = get_trace(ctx, "trace-token", task_id)
    assert served.status == 200

    doc = Jason.decode!(served.resp_body)

    # deterministic identity bound to the wire task id
    assert doc["traceId"] == AshA2A.Trace.trace_id(task_id)
    assert doc["taskId"] == task_id
    assert Regex.match?(~r/\A[0-9a-f]{32}\z/, doc["traceId"])

    # full span tree, correct parent links. The real saga nests
    # task -> actuation (the command bus's actuate span) -> dispatch
    # (the dispatcher's span inside the actuation).
    assert %{"name" => "a2a.task", "spanId" => task_sid, "parentSpanId" => ""} =
             span_named(doc, "a2a.task")

    assert %{"spanId" => actuation_sid, "parentSpanId" => ^task_sid} =
             span_named(doc, "a2a.actuation")

    assert %{"parentSpanId" => ^actuation_sid} = span_named(doc, "a2a.dispatch")

    assert Enum.map(doc["spans"], & &1["name"]) == ["a2a.task", "a2a.actuation", "a2a.dispatch"]
    assert span_named(doc, "a2a.task")["kind"] == "SPAN_KIND_SERVER"

    for span <- doc["spans"] do
      assert %{"endTimeUnixNano" => t1, "startTimeUnixNano" => t0} = span
      assert String.to_integer(t1) >= String.to_integer(t0)
    end

    # envelope attributes on the task span (from the real task record)
    task_span = span_named(doc, "a2a.task")
    assert task_span["attributes"]["a2a.task.id"] == task_id
    assert task_span["attributes"]["a2a.task.context_id"] == task["contextId"]
    assert task_span["attributes"]["a2a.task.state"] == "TASK_STATE_COMPLETED"
    assert task_span["attributes"]["a2a.principal"] == "id:user-trace-1"

    # dispatch attributes from the dispatcher telemetry
    dispatch = span_named(doc, "a2a.dispatch")
    assert dispatch["attributes"]["a2a.skill"] == "create_note"
    assert dispatch["attributes"]["a2a.reply_type"] == "reply"

    # authority/actuation/receipt saga boundaries as span events on the
    # enclosing task span (the command bus fires them outside the dispatch
    # span, before/after the actuation stage)
    event_names = Enum.map(task_span["events"], & &1["name"])

    assert "authority.decision" in event_names

    authority = Enum.find(task_span["events"], &match?(%{"name" => "authority.decision"}, &1))
    assert authority["attributes"]["authority.outcome"] == "granted"

    assert "command_bus.target" in event_names
    assert "command_bus.admission" in event_names
    assert "command_bus.claim" in event_names
    assert "command_bus.prepare" in event_names
    assert "command_bus.postcondition" in event_names
    assert "command_bus.commit" in event_names
    assert "receipt.committed" in event_names

    receipt = Enum.find(task_span["events"], &match?(%{"name" => "receipt.committed"}, &1))
    assert receipt["attributes"]["receipt.terminal_status"] == "executed"
    assert receipt["attributes"]["receipt.command_id"] =~ ~r/\Amsg-/

    # TaskEvents wire log as events on the task span, with the wire task id
    wire_events = Enum.filter(task_span["events"], &match?(%{"name" => "task"}, &1))
    assert [%{"attributes" => %{"a2a.event.seq" => 1, "a2a.event.final" => true}}] = wire_events
  end

  test "replay determinism: two sagas export identical structure; repeated export is stable",
       ctx do
    task1 = send_create(ctx, "trace-replay-a")
    task2 = send_create(ctx, "trace-replay-b")

    {:ok, doc1} = AshA2A.Trace.export(ctx.transport, task1["id"], agent: ctx.agent)
    {:ok, doc1_again} = AshA2A.Trace.export(ctx.transport, task1["id"], agent: ctx.agent)
    {:ok, doc2} = AshA2A.Trace.export(ctx.transport, task2["id"], agent: ctx.agent)

    # same saga exported twice: identical document (timestamps are recorded once)
    assert doc1 == doc1_again

    # different task, same saga shape: identical structure modulo the
    # task-derived identity and timestamps
    assert structure(doc1) == structure(doc2)
    assert doc1["taskId"] != doc2["taskId"]
    assert doc1["traceId"] != doc2["traceId"]
    assert AshA2A.Trace.trace_id(task2["id"]) == doc2["traceId"]
  end

  test "OTLP export is valid OTLP/JSON TracesData", ctx do
    task = send_create(ctx, "trace-otlp")

    {:ok, doc} = AshA2A.Trace.export(ctx.transport, task["id"], agent: ctx.agent, format: :otlp)

    assert [%{"resource" => resource, "scopeSpans" => [scope]}] = doc["resourceSpans"]

    assert %{"key" => "service.name", "value" => %{"stringValue" => "ash_a2a"}} in resource[
             "attributes"
           ]

    assert scope["scope"]["name"] == "ash_a2a.trace"
    spans = scope["spans"]
    assert Enum.map(spans, & &1["name"]) == ["a2a.task", "a2a.actuation", "a2a.dispatch"]

    trace_id = AshA2A.Trace.trace_id(task["id"])

    for span <- spans do
      assert span["traceId"] == trace_id
      assert Regex.match?(~r/\A[0-9a-f]{16}\z/, span["spanId"])
      assert Regex.match?(~r/\A\d+\z/, span["startTimeUnixNano"])
      assert Regex.match?(~r/\A\d+\z/, span["endTimeUnixNano"])

      # OTLP attribute typing: key/value objects, ints as intValue
      for %{"key" => k, "value" => v} <- span["attributes"] do
        assert is_binary(k)

        assert match?(%{"stringValue" => _}, v) or match?(%{"intValue" => _}, v) or
                 match?(%{"boolValue" => _}, v)
      end
    end

    [task_span, actuation_span, dispatch_span] = spans
    assert task_span["parentSpanId"] == ""
    assert actuation_span["parentSpanId"] == task_span["spanId"]
    assert dispatch_span["parentSpanId"] == actuation_span["spanId"]

    # wire-log events survive OTLP typing (seq as intValue)
    wire = Enum.find(task_span["events"], &match?(%{"name" => "task"}, &1))
    assert wire

    assert %{"value" => %{"intValue" => 1}} =
             Enum.find(wire["attributes"], &match?(%{"key" => "a2a.event.seq"}, &1))
  end

  test "owner scope: foreign and missing tasks are 404 with the A2A task-not-found error", ctx do
    task = send_create(ctx, "trace-owner")
    task_id = task["id"]

    served = get_trace(ctx, "other-token", task_id)
    assert served.status == 404

    assert %{"error" => %{"code" => -32001}} = Jason.decode!(served.resp_body)

    served = get_trace(ctx, "trace-token", "no-such-task")
    assert served.status == 404
    assert %{"error" => %{"code" => -32001}} = Jason.decode!(served.resp_body)
  end

  test "GET trace with format=otlp serves OTLP/JSON; POST passes through the trace plug", ctx do
    task = send_create(ctx, "trace-otlp-endpoint")

    served = get_trace(ctx, "trace-token", task["id"], "?format=otlp")
    assert served.status == 200

    otlp = Jason.decode!(served.resp_body)
    assert [%{"scopeSpans" => [_ | _]}] = otlp["resourceSpans"]

    # POST dispatch already passed through AshA2A.Trace.Plug untouched in
    # every send_create/2 above; assert the passthrough explicitly for a
    # non-trace GET too (agent card path answer comes from the transport).
    conn =
      Plug.Test.conn(:get, "/.well-known/agent-card.json")
      |> Auth.call(ctx.auth)

    refute conn.halted

    conn = AshA2A.Trace.Plug.call(conn, ctx.trace_plug)
    refute conn.halted
  end

  # -- helpers ----------------------------------------------------------------------

  defp structure(doc) do
    Enum.map(doc["spans"], fn span ->
      %{
        "name" => span["name"],
        "parent" => parent_name(doc["spans"], span["parentSpanId"]),
        "kind" => span["kind"],
        "status" => span["status"],
        "attribute_keys" => attr_keys(span["attributes"]),
        "event_names" => Enum.map(span["events"], & &1["name"])
      }
    end)
  end

  defp attr_keys(attrs) when is_map(attrs) do
    attrs |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  defp attr_keys(_other), do: []

  defp parent_name(_spans, ""), do: nil

  defp parent_name(spans, parent_span_id) do
    case Enum.find(spans, &match?(%{"spanId" => ^parent_span_id}, &1)) do
      %{"name" => name} -> name
      _ -> parent_span_id
    end
  end
end

# ==============================================================================
# SECTION 15: Original test/ash_a2a_transport_grpc_auth_test.exs
# ==============================================================================

defmodule AshA2A.Transport.GRPCAuthTest.Handler do
  @moduledoc """
  Real `AshA2A.Protocol.JSONRPC` handler over a real supervised EchoAgent —
  local copy so this court does not depend on another test file's module
  being compiled. No mocks.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Test.Fixture.EchoAgent

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, _params, %{agent: agent}) do
    AshA2A.Protocol.call(agent, message)
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, _params, %{agent: agent}) do
    case EchoAgent.get_task(agent, task_id) do
      {:ok, task} ->
        {:ok, task}

      {:error, :not_found} ->
        {:error,
         %AshA2A.Protocol.JSONRPC.Error{code: -32001, message: "task not found: #{task_id}"}}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_cancel(task_id, _params, %{agent: agent}) do
    case EchoAgent.cancel(agent, task_id) do
      :ok ->
        EchoAgent.get_task(agent, task_id)

      {:error, :not_found} ->
        {:error,
         %AshA2A.Protocol.JSONRPC.Error{code: -32001, message: "task not found: #{task_id}"}}

      {:error, reason} ->
        {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32002, message: inspect(reason)}}
    end
  end
end

defmodule AshA2A.Transport.GRPCAuthTest do
  @moduledoc """
  Court for the gRPC auth-interceptor seam (BIND-EQUIV-004): with the
  interceptor configured, a valid JWT passes and missing/invalid credentials
  surface as real over-the-wire UNAUTHENTICATED(16) refusals carrying the
  same typed body the HTTP binding emits on its 401
  (`{"error":"Unauthorized"}`); with the seam unconfigured, anonymous traffic
  still passes (backward compatibility with the anonymous gRPC subset).

  Every collaborator is real: a real cowboy HTTP/2 listener, a real gRPC
  client (Mint), the real `AshA2A.Protocol.Plug.Auth` pipeline, and a real
  HS256 JWT minted/verified with :crypto HMAC (the repo's JWTVerifier is
  compile-gated on :joken, which is not a dependency here). Zero mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Test.Fixture.EchoAgent
  alias Lf.A2a.V1, as: Pb

  @endpoint AshA2A.Transport.GRPC.Server.Endpoint
  @secret "grpc-auth-court-hs256-secret"

  defmodule Verify do
    @moduledoc """
    Real HS256 JWT verification in the verify/3 callback — header check,
    constant-time HMAC-SHA256 signature comparison, required/issuer claims.
    (The repo's JWTVerifier is compile-gated on :joken, absent here; this is
    the same JOSE HS256 math, real :crypto, no mocks.)
    """

    @secret "grpc-auth-court-hs256-secret"

    def secret, do: @secret

    def verify(_scheme, credential, _conn) do
      with [header_b64, payload_b64, sig_b64] <- String.split(credential, ".", parts: 3),
           {:ok, %{"alg" => "HS256"}} <- Jason.decode(Base.url_decode64!(header_b64)),
           {:ok, claims} <- Jason.decode(Base.url_decode64!(payload_b64)),
           signing_input = header_b64 <> "." <> payload_b64,
           :ok <- check_sig(signing_input, sig_b64) do
        if is_binary(claims["sub"]) and claims["sub"] != "" do
          {:ok, %{id: claims["sub"]}}
        else
          {:error, "missing sub claim"}
        end
      else
        _ -> {:error, "invalid JWT"}
      end
    end

    defp check_sig(signing_input, sig_b64) do
      expected = :crypto.mac(:hmac, :sha256, @secret, signing_input)
      sig = Base.url_decode64!(sig_b64, padding: false)

      if Plug.Crypto.secure_compare(sig, expected) do
        :ok
      else
        {:error, "signature verification failed"}
      end
    end
  end

  setup context do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: AshA2A.Transport.GRPCAuthTest.Handler,
      ctx: %{agent: EchoAgent, opts: [], transport: transport}
    )

    on_exit(fn -> Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server) end)

    if context[:auth_config] != :none do
      auth_opts =
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
          verify: &Verify.verify/3
        )

      Application.put_env(:ash_a2a, @endpoint, auth: {AshA2A.Transport.GRPC.Auth, auth_opts})

      on_exit(fn -> Application.delete_env(:ash_a2a, @endpoint) end)
    end

    {:ok, _client_sup} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: Module.concat(__MODULE__, ClientSup)
      )

    {:ok, _endpoint_pid, port} = GRPC.Server.start_endpoint(@endpoint, 0)

    on_exit(fn ->
      try do
        GRPC.Server.stop_endpoint(@endpoint)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, channel} =
      GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)

    {:ok, %{channel: channel}}
  end

  # Real HS256 JWT minted with :crypto HMAC — no JWT library needed for the
  # court; the verifier side (JWTVerifier) does its Joken-style verification
  # against this real token.
  defp token(sub, secret \\ @secret) do
    b64 = fn bin -> Base.url_encode64(bin, padding: false) end

    header = b64.(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}))
    payload = b64.(Jason.encode!(%{"sub" => sub, "iss" => "grpc-auth-court"}))

    signing_input = header <> "." <> payload
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)

    signing_input <> "." <> b64.(signature)
  end

  defp rogue_token(sub) do
    token(sub, "wrong-secret")
  end

  defp request do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("grpc-auth"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, "authenticated hello"}}]
      }
    }
  end

  defp opts_with_token(token) do
    metadata = %{"authorization" => "Bearer " <> token}
    [metadata: metadata]
  end

  test "verify callback accepts a court-minted HS256 token (real state assertion)" do
    assert {:ok, %{id: "alice"}} = Verify.verify(nil, token("alice"), nil)
    assert {:error, _} = Verify.verify(nil, token("alice", "wrong-secret"), nil)
    assert {:error, _} = Verify.verify(nil, "not-a-jwt", nil)
  end

  test "valid JWT passes the interceptor and creates a real task", %{channel: channel} do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               request(),
               opts_with_token(token("alice"))
             )

    assert task.status.state == :TASK_STATE_COMPLETED
    assert task.id != ""
  end

  test "missing authorization metadata is UNAUTHENTICATED(16) with the typed HTTP body", %{
    channel: channel
  } do
    assert {:error, %GRPC.RPCError{status: 16} = error} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, request())

    assert error.message == ~s({"error":"Unauthorized"})
  end

  test "invalid JWT signature is UNAUTHENTICATED(16) with the typed HTTP body", %{
    channel: channel
  } do
    # Signed with the WRONG secret — real signature verification failure.
    rogue = rogue_token("mallory")

    assert {:error, %GRPC.RPCError{status: 16} = error} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               request(),
               opts_with_token(rogue)
             )

    assert error.message == ~s({"error":"Unauthorized"})
  end

  test "garbage credential (not a JWT at all) is UNAUTHENTICATED(16)", %{channel: channel} do
    assert {:error, %GRPC.RPCError{status: 16}} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               request(),
               opts_with_token("not-a-jwt")
             )
  end

  @tag auth_config: :none
  test "unconfigured seam keeps the anonymous behavior (backward compatible)", %{channel: channel} do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, request())

    assert task.status.state == :TASK_STATE_COMPLETED
    assert task.id != ""
  end
end

# ==============================================================================
# SECTION 16: Original test/ash_a2a_transport_grpc_server_test.exs
# ==============================================================================

defmodule AshA2A.Transport.GRPCServerTestHandler do
  @moduledoc """
  Real `AshA2A.Protocol.JSONRPC` behaviour implementation wired to a real,
  supervised `AshA2A.Test.Fixture.EchoAgent` — the same agent fixture the
  HTTP-binding tests drive. No mocks.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Test.Fixture.EchoAgent

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, _params, %{agent: agent}) do
    AshA2A.Protocol.call(agent, message)
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, _params, %{agent: agent}) do
    case EchoAgent.get_task(agent, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, :not_found} -> {:error, Error.task_not_found(task_id)}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_cancel(task_id, _params, %{agent: agent}) do
    case EchoAgent.cancel(agent, task_id) do
      :ok ->
        EchoAgent.get_task(agent, task_id)

      {:error, :not_found} ->
        {:error, Error.task_not_found(task_id)}

      {:error, reason} ->
        {:error, Error.task_not_cancelable(inspect(reason))}
    end
  end
end

defmodule AshA2A.Transport.GRPCServerTest.MessageOnlyAgent do
  @moduledoc """
  Real `AshA2A.Protocol.Agent` whose only skill answers with a bare
  `{:message, parts}` reply — so `AshA2A.Protocol.stream/3` returns
  `{:ok, %AshA2A.Protocol.Message{}}` (no task, no stream). That is a real
  reason term `start_message_stream/1`'s else-branch receives (the branch
  whose redacted reason is interpolated into the refusal message); a plain
  task-backed agent streams fine over gRPC, so it cannot drive this branch.
  No mocks: the agent is a real supervised process.
  """

  use AshA2A.Protocol.Agent,
    name: "grpc_message_only",
    description: "Answers every message with a bare Message reply (no task, no stream)",
    skills: [
      %{
        id: "ack",
        name: "ack",
        description: "Acknowledges the message without creating a task"
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:message, [AshA2A.Protocol.Part.Text.new("acknowledged, no task")]}
  end
end

defmodule AshA2A.Transport.GRPCServerTest.FullHandler do
  @moduledoc """
  Real `AshA2A.Protocol.JSONRPC` handler implementing EVERY optional callback
  over a real `:ets` table, so the wire tests can drive `ListTasks` and the
  full `tasks/pushNotificationConfig` CRUD surface with real state
  assertions. No mocks: the store is a real ETS table, the tasks are real
  tasks created by the real `EchoAgent` through `handle_send/3`.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Test.Fixture.EchoAgent

  @table :ash_a2a_grpc_server_full_handler

  @doc "Idempotently creates the backing ETS table and clears it."
  def reset do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :public])
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, _params, %{agent: agent}) do
    case AshA2A.Protocol.call(agent, message) do
      {:ok, %AshA2A.Protocol.Task{} = task} = ok ->
        :ets.insert(@table, {{:task, task.id}, task})
        ok

      other ->
        other
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, _params, %{agent: agent}) do
    case EchoAgent.get_task(agent, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, :not_found} -> {:error, Error.task_not_found(task_id)}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_cancel(task_id, _params, %{agent: agent}) do
    case EchoAgent.cancel(agent, task_id) do
      :ok ->
        EchoAgent.get_task(agent, task_id)

      {:error, :not_found} ->
        {:error, Error.task_not_found(task_id)}

      {:error, reason} ->
        {:error, Error.task_not_cancelable(inspect(reason))}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_list(_params, _ctx) do
    tasks =
      @table
      |> :ets.tab2list()
      |> Enum.filter(&match?({{:task, _}, _}, &1))
      |> Enum.map(fn {{:task, _}, task} -> task end)
      |> Enum.sort_by(& &1.id)

    {:ok,
     %{tasks: tasks, total_size: length(tasks), page_size: length(tasks), next_page_token: nil}}
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_set_push_config(config, _params, _ctx) do
    key = {:push, config.task_id, config.id || "default"}
    :ets.insert(@table, {key, config})
    {:ok, config}
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get_push_config(task_id, config_id, _params, _ctx) do
    case :ets.lookup(@table, {:push, task_id, config_id}) do
      [{_, config}] -> {:ok, config}
      [] -> {:error, Error.task_not_found(config_id || "default")}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_list_push_configs(task_id, _params, _ctx) do
    configs =
      @table
      |> :ets.tab2list()
      |> Enum.filter(&match?({{:push, ^task_id, _}, _}, &1))
      |> Enum.map(fn {{:push, _, _}, config} -> config end)

    {:ok, configs}
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_delete_push_config(task_id, config_id, _params, _ctx) do
    :ets.delete(@table, {:push, task_id, config_id})
    :ok
  end
end

defmodule AshA2A.Transport.GRPCServerTest do
  @moduledoc """
  REAL gRPC-over-the-wire tests for `AshA2A.Transport.GRPC.Server`: a real
  cowboy HTTP/2 listener on a loopback port, driven by a real gRPC client
  (Mint adapter) through the generated `Lf.A2a.V1.A2AService.Stub`.

  SendMessage creates a real task in a real agent, GetTask reads it back,
  an unknown task surfaces as a real `grpc-status: 5` NOT_FOUND trailer, and
  `SendStreamingMessage` delivers the task snapshot plus live events until
  the final status update. Zero mocks: every collaborator is real.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Test.Fixture.EchoAgent
  alias Lf.A2a.V1, as: Pb

  @endpoint AshA2A.Transport.GRPC.Server.Endpoint

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        EchoAgent,
        AshA2A.Test.Fixture.StreamingWidgetAgent
      ])

    # Real rows for the streaming agent's real read stream (same seeding the
    # SSE streaming test uses; the ETS data layer is process-shared).
    Ash.Seed.seed!(AshA2A.Test.Fixture.StreamingWidget, %{label: "grpc-alpha"})
    Ash.Seed.seed!(AshA2A.Test.Fixture.StreamingWidget, %{label: "grpc-bravo"})

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: AshA2A.Transport.GRPCServerTestHandler,
      ctx: %{agent: EchoAgent, opts: [], transport: transport}
    )

    on_exit(fn -> Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server) end)

    {:ok, _client_sup} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: Module.concat(__MODULE__, ClientSup)
      )

    {:ok, _endpoint_pid, port} = GRPC.Server.start_endpoint(@endpoint, 0)

    on_exit(fn ->
      try do
        GRPC.Server.stop_endpoint(@endpoint)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, channel} =
      GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)

    {:ok, %{channel: channel}}
  end

  defp transport_name, do: Module.concat(__MODULE__, Transport)

  # A server-streaming stub call may surface the server's refusal either at
  # call time ({:error, %GRPC.RPCError{}}) or lazily when the returned stream
  # is enumerated, depending on when the trailers arrive — handle both.
  defp rpc_error_from_stream({:error, %GRPC.RPCError{} = error}), do: error

  defp rpc_error_from_stream({:ok, stream}) do
    try do
      _ = Enum.to_list(stream)
      flunk("expected the server-streaming call to fail")
    rescue
      e in GRPC.RPCError -> e
    end
  end

  defp data_request do
    value = Protobuf.JSON.decode!(~s({"stream": true}), Google.Protobuf.Value)

    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("grpc"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:data, value}}]
      }
    }
  end

  defp user_message_request(text) do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("grpc"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      }
    }
  end

  defp send_and_get_task_id(channel, text) do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, user_message_request(text))

    assert task.status.state == :TASK_STATE_COMPLETED
    assert is_binary(task.id) and task.id != ""
    task.id
  end

  test "SendMessage creates a real task over the wire", %{channel: channel} do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, user_message_request("hello grpc"))

    assert task.status.state == :TASK_STATE_COMPLETED
    assert task.id != ""
    assert task.context_id != ""

    assert Enum.any?(task.history, fn
             %Pb.Message{parts: [%Pb.Part{content: {:text, "hello grpc"}}]} -> true
             _ -> false
           end)
  end

  test "GetTask reads the created task back over the wire", %{channel: channel} do
    task_id = send_and_get_task_id(channel, "echo round trip")

    assert {:ok, %Pb.Task{} = got} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, %Pb.GetTaskRequest{id: task_id})

    assert got.id == task_id
    assert got.status.state == :TASK_STATE_COMPLETED

    assert Enum.any?(got.history, fn
             %Pb.Message{parts: [%Pb.Part{content: {:text, "echo round trip"}}]} -> true
             _ -> false
           end)
  end

  test "GetTask with an unknown id surfaces a real grpc-status NOT_FOUND trailer", %{
    channel: channel
  } do
    assert {:error, %GRPC.RPCError{} = error} =
             Lf.A2a.V1.A2AService.Stub.get_task(
               channel,
               %Pb.GetTaskRequest{id: "no-such-task"}
             )

    assert error.status == 5
    assert error.message == "Task not found"

    # GRPC-ERR-001 (spec §10.6): an A2A error carries its google.rpc.ErrorInfo
    # (reason TASK_NOT_FOUND, domain a2a-protocol.org) in the
    # grpc-status-details-bin trailer.
    assert [%Google.Protobuf.Any{type_url: "type.googleapis.com/google.rpc.ErrorInfo"} = any] =
             error.details

    assert %Google.Rpc.ErrorInfo{reason: "TASK_NOT_FOUND", domain: "a2a-protocol.org"} =
             Google.Rpc.ErrorInfo.decode(any.value)
  end

  test "SendStreamingMessage streams the snapshot and events until the final status", %{
    channel: channel
  } do
    # The streaming RPC drives the real streaming-capable agent fixture (the
    # Echo agent is not streamable); point the transport's ctx at it for this
    # test and restore after.
    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: AshA2A.Transport.GRPCServerTestHandler,
      ctx: %{
        agent: AshA2A.Test.Fixture.StreamingWidgetAgent,
        opts: [],
        transport: transport_name()
      }
    )

    on_exit(fn ->
      Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server)
    end)

    assert {:ok, stream} =
             channel |> Lf.A2a.V1.A2AService.Stub.send_streaming_message(data_request())

    replies =
      stream
      |> Enum.map(fn {:ok, %Pb.StreamResponse{} = resp} -> resp end)
      |> Enum.to_list()

    assert [%Pb.StreamResponse{payload: {:task, %Pb.Task{}}} = _snapshot | events] = replies

    kinds =
      Enum.map(events, fn
        %Pb.StreamResponse{payload: {:artifact_update, _}} -> :artifact
        %Pb.StreamResponse{payload: {:status_update, _}} -> :status
        %Pb.StreamResponse{payload: {:task, _}} -> :task
        %Pb.StreamResponse{payload: {:message, _}} -> :message
      end)

    assert kinds != []
    assert [last_event | _] = Enum.reverse(events)

    assert match?(
             %Pb.StreamResponse{
               payload: {:status_update, %{status: %{state: :TASK_STATE_COMPLETED}}}
             },
             last_event
           )
  end

  # -- G-E pinned gRPC TCK-failure closures (lane G-Q) -----------------------

  test "SubscribeToTask of a terminal task is UNIMPLEMENTED(12) with UNSUPPORTED_OPERATION", %{
    channel: channel
  } do
    task_id = send_and_get_task_id(channel, "terminal resubscribe")

    error =
      rpc_error_from_stream(
        Lf.A2a.V1.A2AService.Stub.subscribe_to_task(channel, %Pb.SubscribeToTaskRequest{
          id: task_id
        })
      )

    assert error.status == 12

    # Pinned TCK (STREAM-SUB-003) binds UnsupportedOperationError (-32004)
    # to UNIMPLEMENTED with reason UNSUPPORTED_OPERATION.
    assert error.message == "This operation is not supported"

    assert [%Google.Protobuf.Any{type_url: "type.googleapis.com/google.rpc.ErrorInfo"} = any] =
             error.details

    assert %Google.Rpc.ErrorInfo{reason: "UNSUPPORTED_OPERATION", domain: "a2a-protocol.org"} =
             Google.Rpc.ErrorInfo.decode(any.value)
  end

  test "SendStreamingMessage to a non-streamable agent is FAILED_PRECONDITION(9) with a string message",
       %{
         channel: channel
       } do
    # The refusal may surface at call time or at enumeration time (the client
    # stream is lazy), so enumerate under rescue. The MessageOnlyAgent drives
    # the same else-branch `{:not_streaming, %Task{}}` lands in: any non-
    # `{:ok, task, enum}` reply is refused here.
    agent_name = :"grpc_message_only_#{System.unique_integer([:positive])}"
    start_supervised!({AshA2A.Transport.GRPCServerTest.MessageOnlyAgent, name: agent_name})

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: AshA2A.Transport.GRPCServerTestHandler,
      ctx: %{agent: agent_name, opts: [], transport: transport_name()}
    )

    error =
      rpc_error_from_stream(
        Lf.A2a.V1.A2AService.Stub.send_streaming_message(
          channel,
          user_message_request("no stream please")
        )
      )

    assert error.status == 9
    assert error.message =~ "Task is not streamable:"

    # A binary message: the redacted term was rendered with inspect/1 before
    # interpolation, so no crash-and-INTERNAL detour.
    assert is_binary(error.message)
  end

  test "unsupported A2A-Version metadata is refused UNIMPLEMENTED(12) with a VERSION_NOT_SUPPORTED ErrorInfo",
       %{
         channel: channel
       } do
    assert {:error, %GRPC.RPCError{status: 12} = error} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               user_message_request("bad version"),
               metadata: %{"a2a-version" => "99.0"}
             )

    assert error.message == "Version not supported"

    assert [%Google.Protobuf.Any{type_url: "type.googleapis.com/google.rpc.ErrorInfo"} = any] =
             error.details

    assert %Google.Rpc.ErrorInfo{reason: "VERSION_NOT_SUPPORTED", domain: "a2a-protocol.org"} =
             info = Google.Rpc.ErrorInfo.decode(any.value)

    assert info.metadata == %{"detail" => "99.0"}

    # Absent header: default tolerance (§3.6.2 — missing version means "0.3"),
    # the request processes normally.
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{}}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               user_message_request("no version header")
             )
  end

  # -- full-surface wire tests (lane G1): ListTasks, push-config CRUD,
  #    GetExtendedAgentCard ----------------------------------------------------

  defp with_full_handler(ctx_tests) do
    AshA2A.Transport.GRPCServerTest.FullHandler.reset()

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: AshA2A.Transport.GRPCServerTest.FullHandler,
      ctx: %{agent: EchoAgent, opts: [], transport: transport_name()}
    )

    try do
      ctx_tests.()
    after
      Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
        handler: AshA2A.Transport.GRPCServerTestHandler,
        ctx: %{agent: EchoAgent, opts: [], transport: transport_name()}
      )
    end
  end

  test "ListTasks over the wire returns the tasks real sends created", %{channel: channel} do
    with_full_handler(fn ->
      id_a = send_and_get_task_id(channel, "list me alpha")
      id_b = send_and_get_task_id(channel, "list me bravo")

      assert {:ok,
              %Pb.ListTasksResponse{
                tasks: tasks,
                total_size: total,
                page_size: size
              }} =
               Lf.A2a.V1.A2AService.Stub.list_tasks(channel, %Pb.ListTasksRequest{})

      ids = Enum.map(tasks, & &1.id)
      assert id_a in ids and id_b in ids
      assert total >= 2 and size >= 2
      assert Enum.all?(tasks, &(&1.status.state == :TASK_STATE_COMPLETED))
    end)
  end

  test "push-notification-config CRUD round-trips over the wire with real state", %{
    channel: channel
  } do
    with_full_handler(fn ->
      task_id = send_and_get_task_id(channel, "push config host task")

      create_req = %Pb.TaskPushNotificationConfig{
        id: "cfg-1",
        task_id: task_id,
        url: "https://hooks.example.com/a2a",
        token: "tok-1"
      }

      assert {:ok, %Pb.TaskPushNotificationConfig{} = created} =
               Lf.A2a.V1.A2AService.Stub.create_task_push_notification_config(
                 channel,
                 create_req
               )

      assert created.id == "cfg-1"
      assert created.url == "https://hooks.example.com/a2a"
      assert created.token == "tok-1"

      assert {:ok, %Pb.TaskPushNotificationConfig{} = got} =
               Lf.A2a.V1.A2AService.Stub.get_task_push_notification_config(
                 channel,
                 %Pb.GetTaskPushNotificationConfigRequest{
                   task_id: task_id,
                   id: "cfg-1"
                 }
               )

      assert got.id == "cfg-1" and got.url == "https://hooks.example.com/a2a"

      assert {:ok, %Pb.ListTaskPushNotificationConfigsResponse{configs: configs}} =
               Lf.A2a.V1.A2AService.Stub.list_task_push_notification_configs(
                 channel,
                 %Pb.ListTaskPushNotificationConfigsRequest{
                   task_id: task_id
                 }
               )

      assert [%{id: "cfg-1"}] = configs

      assert {:ok, %Google.Protobuf.Empty{}} =
               Lf.A2a.V1.A2AService.Stub.delete_task_push_notification_config(
                 channel,
                 %Pb.DeleteTaskPushNotificationConfigRequest{
                   task_id: task_id,
                   id: "cfg-1"
                 }
               )

      # Real state: the row is gone, so a get now refuses NOT_FOUND(5).
      assert {:error, %GRPC.RPCError{status: 5} = err} =
               Lf.A2a.V1.A2AService.Stub.get_task_push_notification_config(
                 channel,
                 %Pb.GetTaskPushNotificationConfigRequest{
                   task_id: task_id,
                   id: "cfg-1"
                 }
               )

      assert err.message == "Task not found"
    end)
  end

  test "GetExtendedAgentCard with no provider is FAILED_PRECONDITION(9) over the wire (-32007)",
       %{channel: channel} do
    assert {:error, %GRPC.RPCError{status: 9} = err} =
             Lf.A2a.V1.A2AService.Stub.get_extended_agent_card(
               channel,
               %Pb.GetExtendedAgentCardRequest{}
             )

    assert err.message == "Authenticated Extended Card is not configured"
  end
end

# ==============================================================================
# SECTION 17: Original test/ash_a2a_transport_grpc_test.exs
# ==============================================================================

defmodule AshA2A.GrpcLane.Probe do
  @moduledoc false

  use Ash.Resource,
    domain: AshA2A.GrpcLane.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :whoami, :map do
      run(fn _input, _context ->
        {:ok, %{"subject" => nil}}
      end)
    end
  end

  a2a do
    skill(:whoami, :whoami, consequence: :observe)
  end
end

defmodule AshA2A.GrpcLane.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.GrpcLane.Probe)
  end
end

defmodule AshA2A.GrpcLane.Agent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.GrpcLane.Probe,
    name: "grpc_lane_agent",
    public_skills: [:whoami]
end

defmodule AshA2A.TransportGrpcTest do
  use ExUnit.Case, async: false

  alias AshA2A.Transport.Grpc.{Dispatch, Framing}

  # The SAME handler the HTTP binding uses, driven Plug-free: a bare
  # handler/ctx pair, no socket, no server.
  setup do
    name = :"grpc_lane_agent_#{System.unique_integer([:positive])}"
    agent = start_supervised!({AshA2A.GrpcLane.Agent, name: name}, id: name)

    opts = AshA2A.Transport.Plug.init(agent: name, base_url: "http://127.0.0.1/a2a")
    ctx = %{agent: name, opts: opts, conn: %Plug.Conn{}, principal: :anonymous}

    %{agent: agent, name: name, ctx: ctx, handler: AshA2A.Transport.Plug}
  end

  defp wire_message do
    msg = %{
      AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])
      | metadata: %{"skill" => "whoami"}
    }

    {:ok, json} = AshA2A.Protocol.JSON.encode(msg)
    json
  end

  defp send_message(ctx, handler) do
    assert {:ok, %{"task" => %{"id" => task_id} = task}} =
             Dispatch.call("SendMessage", %{"message" => wire_message()}, handler, ctx)

    assert "tsk-" <> _ = task_id
    assert %{"status" => %{"state" => "TASK_STATE_COMPLETED"}} = task
    task_id
  end

  # -- Framing ----------------------------------------------------------------

  describe "Framing length-prefixed codec" do
    test "round-trips a payload through the 5-byte header" do
      frame = Framing.encode_frame("hello")

      assert <<0::size(8), 5::unsigned-big-integer-size(32), "hello">> = frame
      assert {:ok, ["hello"], ""} = Framing.decode_frames(frame)
    end

    test "splits and reassembles multi-frame buffers" do
      bytes =
        ["a", "bb", "ccc"]
        |> Enum.map(&Framing.encode_frame/1)
        |> IO.iodata_to_binary()

      assert {:ok, ["a", "bb", "ccc"], ""} = Framing.decode_frames(bytes)
    end

    test "buffers a partial frame until its bytes arrive" do
      frame = Framing.encode_frame("hello")
      <<prefix::binary-size(3), tail::binary>> = frame

      assert {:ok, [], ^prefix} = Framing.decode_frames(prefix)
      assert {:ok, ["hello"], ""} = Framing.decode_frames(prefix <> tail)
    end

    test "returns early frames alongside an incomplete tail" do
      bytes = Framing.encode_frame("a") <> Framing.encode_frame("bcd")
      <<head::binary-size(7), rest::binary>> = bytes

      assert {:ok, ["a"], buffered} = Framing.decode_frames(head)
      assert byte_size(buffered) < 5

      # The host resumes the stream: buffered tail + the next chunk received.
      # Frame "a" was already delivered by the first decode call.
      assert {:ok, ["bcd"], ""} = Framing.decode_frames(buffered <> rest)
    end

    test "refuses oversized declared lengths" do
      frame = Framing.encode_frame(String.duplicate("x", 10))

      assert {:error, {:frame_too_large, 10}} =
               Framing.decode_frames(frame, max_frame_bytes: 5)
    end

    test "refuses compressed frames without a negotiated decompressor" do
      frame = Framing.encode_frame("hello", compressed: true)
      assert {:error, :compression_unsupported} = Framing.decode_frames(frame)
    end

    test "decompresses compressed frames when the host supplies the encoding" do
      payload = :zlib.compress("hello")
      frame = <<1::size(8), byte_size(payload)::unsigned-big-integer-size(32), payload::binary>>

      assert {:ok, ["hello"], ""} = Framing.decode_frames(frame, decompress: &:zlib.uncompress/1)
    end

    test "refuses an unknown compressed flag" do
      frame = <<2::size(8), 0::unsigned-big-integer-size(32)>>
      assert {:error, :bad_compressed_flag} = Framing.decode_frames(frame)
    end

    test "trailer maps round-trip with grpc-status as integer" do
      trailers = %{"grpc-status" => 5, "grpc-message" => "Task not found"}
      encoded = Framing.encode_trailers(trailers) |> IO.iodata_to_binary()

      assert encoded =~ "grpc-status: 5\r\n"
      assert encoded =~ "grpc-message: Task not found\r\n"
      assert {:ok, ^trailers} = Framing.parse_trailers(encoded)
    end

    test "non-integer grpc-status is a typed refusal" do
      assert {:error, {:bad_grpc_status, "five"}} =
               Framing.parse_trailers("grpc-status: five\r\n")
    end
  end

  # -- Dispatch ---------------------------------------------------------------

  describe "Dispatch method table" do
    test "exposes the a2a.A2AService method table" do
      names = Enum.map(Dispatch.methods(), & &1.name)

      assert names == [
               "SendMessage",
               "SendStreamingMessage",
               "GetTask",
               "CancelTask",
               "ListTasks",
               "SubscribeToTask",
               "CreateTaskPushNotificationConfig",
               "GetTaskPushNotificationConfig",
               "ListTaskPushNotificationConfigs",
               "DeleteTaskPushNotificationConfig",
               "GetExtendedAgentCard"
             ]

      assert Dispatch.service() == "a2a.A2AService"
      assert Enum.all?(Dispatch.methods(), &is_binary(&1.internal))
    end
  end

  describe "Dispatch over a real agent, Plug-free" do
    test "SendMessage creates a real task; GetTask reads it back", %{ctx: ctx, handler: handler} do
      task_id = send_message(ctx, handler)

      assert {:ok, %{"id" => ^task_id}} =
               Dispatch.call("GetTask", %{"id" => task_id}, handler, ctx)
    end

    test "a real -32001 maps to NOT_FOUND(5)", %{ctx: ctx, handler: handler} do
      assert {:error, 5, "Task not found"} =
               Dispatch.call("GetTask", %{"id" => "tsk-does-not-exist"}, handler, ctx)
    end

    test "CancelTask of a terminal task maps -32002 to FAILED_PRECONDITION(9)", %{
      ctx: ctx,
      handler: handler
    } do
      task_id = send_message(ctx, handler)

      assert {:error, 9, "Task cannot be canceled"} =
               Dispatch.call("CancelTask", %{"id" => task_id}, handler, ctx)
    end

    test "missing params map to INVALID_ARGUMENT(3)", %{ctx: ctx, handler: handler} do
      assert {:error, 3, "Invalid parameters"} =
               Dispatch.call("GetTask", %{}, handler, ctx)
    end

    test "an unknown RPC name maps to UNIMPLEMENTED(12)", %{handler: handler} do
      assert {:error, 12, message} = Dispatch.call("a2a.A2AService/Nope", %{}, handler, %{})
      assert message =~ "Nope"
    end

    test "push config CRUD without handler callbacks maps -32003 to UNIMPLEMENTED(12)", %{
      ctx: ctx,
      handler: handler
    } do
      task_id = send_message(ctx, handler)

      assert {:error, 12, "Push Notification is not supported"} =
               Dispatch.call(
                 "CreateTaskPushNotificationConfig",
                 %{
                   "taskId" => task_id,
                   "pushNotificationConfig" => %{"url" => "https://example.com/hook"}
                 },
                 handler,
                 ctx
               )
    end

    test "GetExtendedAgentCard maps -32007 to FAILED_PRECONDITION(9)", %{
      ctx: ctx,
      handler: handler
    } do
      assert {:error, 9, "Authenticated Extended Card is not configured"} =
               Dispatch.call("GetExtendedAgentCard", %{}, handler, ctx)
    end

    test "SendStreamingMessage returns the stream intent, message already validated", %{
      ctx: ctx,
      handler: handler
    } do
      assert {:stream, "message/stream", params, id} =
               Dispatch.call("SendStreamingMessage", %{"message" => wire_message()}, handler, ctx)

      assert %AshA2A.Protocol.Message{} = params["message"]
      assert is_binary(id)
    end

    test "ListTasks is served owner-scoped: anonymous lists nothing", %{
      ctx: ctx,
      handler: handler
    } do
      task_id = send_message(ctx, handler)

      assert {:ok, %{"tasks" => tasks, "totalSize" => 0}} =
               Dispatch.call("ListTasks", %{}, handler, ctx)

      refute Enum.any?(tasks, &(&1["id"] == task_id))
    end

    test "trailers/1 and status_name/1 cover the mapped statuses" do
      assert %{"grpc-status" => 0} = Dispatch.trailers({:ok, %{}})

      assert %{"grpc-status" => 5, "grpc-message" => "Task not found"} =
               Dispatch.trailers({:error, 5, "Task not found"})

      assert Dispatch.status_name(3) == "INVALID_ARGUMENT"
      assert Dispatch.status_name(5) == "NOT_FOUND"
      assert Dispatch.status_name(9) == "FAILED_PRECONDITION"
      assert Dispatch.status_name(12) == "UNIMPLEMENTED"
      assert Dispatch.status_name(13) == "INTERNAL"
    end
  end
end

# ==============================================================================
# SECTION 18: Original test/ash_a2a_transport_http_json_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.HTTPJSONTest.Resource do
  @moduledoc """
  Real fixture resource, private to this test file: a single real `:read`
  skill on a real ETS-backed Ash resource, so dispatch has exactly one skill
  and needs no `:skill` metadata.
  """

  use Ash.Resource,
    domain: AshA2A.Transport.HTTPJSONTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.Transport.HTTPJSONTest.Domain do
  @moduledoc "Real fixture domain for the resource above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Transport.HTTPJSONTest.Resource)
  end
end

defmodule AshA2A.Transport.HTTPJSONTest.EchoAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over the fixture resource above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Transport.HTTPJSONTest.Resource,
    name: "http_json_echo_agent"
end

defmodule AshA2A.Transport.HTTPJSONTest do
  @moduledoc """
  End-to-end court for the A2A v1.0 HTTP+JSON/REST transport binding
  (`AshA2A.Transport.HTTPJSON`).

  A real Bandit server on a loopback ephemeral port, a real supervised
  `use AshA2A.Agent` GenServer over a real ETS Ash resource, real `Req`
  HTTP calls for the full round trip: card fetch -> `message:send` ->
  `tasks/get` -> error cases. No mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.EphemeralHttp

  alias AshA2A.Transport.HTTPJSON, as: Binding

  @error_info "type.googleapis.com/google.rpc.ErrorInfo"

  setup do
    agent = AshA2A.Transport.HTTPJSONTest.EchoAgent

    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [agent])

    plug_opts =
      Binding.init(agent: agent, base_url: "http://127.0.0.1/fixture")

    %{server: EphemeralHttp.start!({Binding, plug_opts})}
  end

  # -- helpers ----------------------------------------------------------------

  defp message_map(text) do
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end

  defp get!(server, path) do
    Req.get!(url: server.base_url <> path)
  end

  defp post_json!(server, path, body) do
    Req.post!(url: server.base_url <> path, json: body)
  end

  defp send_message!(server, text) do
    resp = post_json!(server, "/message:send", %{"message" => message_map(text)})
    assert resp.status == 200
    resp
  end

  defp assert_json_content_type(resp) do
    [content_type] = Enum.map(resp.headers["content-type"], &String.downcase/1)
    assert String.starts_with?(content_type, "application/json")
  end

  # -- agent card ---------------------------------------------------------------

  test "serves the agent card at the spec's well-known path", %{server: server} do
    resp = get!(server, "/.well-known/agent-card.json")

    assert resp.status == 200
    assert_json_content_type(resp)

    assert %{
             "capabilities" => %{"streaming" => true} = capabilities,
             "supportedInterfaces" => [%{"url" => url, "protocolBinding" => _} | _]
           } = resp.body

    assert is_binary(url)
    assert is_binary(resp.body["name"])
    assert Map.has_key?(capabilities, "pushNotifications")
  end

  # -- the happy path: card -> message:send -> tasks/get -----------------------

  test "end-to-end: message:send creates a completed task, tasks/get reads it back", %{
    server: server
  } do
    resp = send_message!(server, "go")

    assert_json_content_type(resp)

    assert %{"task" => task} = resp.body

    assert %{
             "id" => "tsk-" <> _,
             "contextId" => context_id,
             "status" => %{"state" => "TASK_STATE_COMPLETED"}
           } = task

    assert is_binary(context_id)
    assert [%{"parts" => _}] = task["artifacts"]

    # The wire task carries no transport-internal metadata.
    refute Map.has_key?(task["metadata"] || %{}, "a2a.auth")

    fetched = get!(server, "/tasks/#{task["id"]}")
    assert fetched.status == 200
    assert fetched.body["id"] == task["id"]
    assert fetched.body["status"]["state"] == "TASK_STATE_COMPLETED"
    assert fetched.body["contextId"] == context_id
  end

  test "message:send with a terminal task's taskId is 400 task-is-terminal", %{server: server} do
    %{"task" => %{"id" => task_id}} = send_message!(server, "first").body

    continuation = message_map("second") |> Map.put("taskId", task_id)
    resp = post_json!(server, "/message:send", %{"message" => continuation})

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"@type" => @error_info, "reason" => "UNSUPPORTED_OPERATION"}]
             }
           } = resp.body
  end

  test "historyLength parses, truncates, and rejects non-integer query values", %{
    server: server
  } do
    %{"task" => %{"id" => task_id}} = send_message!(server, "go").body

    resp = get!(server, "/tasks/#{task_id}?historyLength=1")
    assert resp.status == 200
    assert length(resp.body["history"]) <= 1

    resp = get!(server, "/tasks/#{task_id}?historyLength=bogus")
    assert resp.status == 400
    assert %{"error" => %{"code" => 400, "status" => "INVALID_ARGUMENT"}} = resp.body
  end

  # -- error cases (status codes + google.rpc ErrorInfo bodies) ----------------

  test "tasks/get on an unknown task is 404 with a TASK_NOT_FOUND ErrorInfo", %{server: server} do
    resp = get!(server, "/tasks/tsk-does-not-exist")

    assert resp.status == 404
    assert_json_content_type(resp)

    assert %{
             "error" => %{
               "code" => 404,
               "status" => "NOT_FOUND",
               "message" => "Task not found",
               "details" => [
                 %{
                   "@type" => @error_info,
                   "domain" => "a2a-protocol.org",
                   "reason" => "TASK_NOT_FOUND"
                 }
               ]
             }
           } = resp.body
  end

  test "cancelling a terminal task is 409 with TASK_NOT_CANCELABLE ErrorInfo", %{server: server} do
    %{"task" => %{"id" => task_id}} = send_message!(server, "go").body

    resp = post_json!(server, "/tasks/#{task_id}:cancel", %{})

    assert resp.status == 409

    assert %{
             "error" => %{
               "code" => 409,
               "status" => "FAILED_PRECONDITION",
               "details" => [%{"@type" => @error_info, "reason" => "TASK_NOT_CANCELABLE"}]
             }
           } = resp.body
  end

  test "cancel on an unknown task is 404", %{server: server} do
    resp = post_json!(server, "/tasks/tsk-nope:cancel", %{})
    assert resp.status == 404
    assert %{"error" => %{"code" => 404}} = resp.body
  end

  test "malformed JSON body is 400 parse error", %{server: server} do
    resp =
      Req.post!(
        url: server.base_url <> "/message:send",
        headers: [{"content-type", "application/json"}],
        body: "definitely not json"
      )

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "status" => "INVALID_ARGUMENT",
               "message" => "Invalid JSON payload"
             }
           } =
             resp.body
  end

  test "missing message is 400 invalid params with INVALID_PARAMS ErrorInfo", %{server: server} do
    resp = post_json!(server, "/message:send", %{"configuration" => %{}})

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"@type" => @error_info, "reason" => "INVALID_PARAMS"}]
             }
           } = resp.body
  end

  test "an over-cap body is refused 413 before parse", %{server: _server} do
    # A second real server, same binding, tiny body cap.
    small =
      EphemeralHttp.start!(
        {Binding,
         Binding.init(
           agent: AshA2A.Transport.HTTPJSONTest.EchoAgent,
           base_url: "http://127.0.0.1/fixture",
           max_body_bytes: 16
         )}
      )

    resp =
      post_json!(small, "/message:send", %{
        "message" => message_map("this is much longer than sixteen bytes")
      })

    assert resp.status == 413
    assert %{"error" => %{"code" => 413, "details" => "Body too large"}} = resp.body
  end

  test "recognized-but-unsupported REST ops answer 400 UNSUPPORTED_OPERATION", %{server: server} do
    # message:stream streams (see the SSE court in the TCK-closure file); an
    # OWNED task's :subscribe has no resubscribe stream to attach and answers
    # the -32004 envelope, mirroring AshA2A.Transport.Plug.resubscribe/4.
    %{"task" => %{"id" => task_id}} = send_message!(server, "go").body

    resp = post_json!(server, "/tasks/#{task_id}:subscribe", %{})

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"@type" => @error_info, "reason" => "UNSUPPORTED_OPERATION"}]
             }
           } = resp.body
  end

  # -- routing -------------------------------------------------------------------

  test "known paths with the wrong method answer 405 with an allow header", %{server: server} do
    resp =
      Req.post!(
        url: server.base_url <> "/.well-known/agent-card.json",
        json: %{},
        decode_body: false
      )

    assert resp.status == 405
    assert resp.headers["allow"] == ["GET"]

    resp = Req.get!(url: server.base_url <> "/message:send", decode_body: false)
    assert resp.status == 405
    assert resp.headers["allow"] == ["POST"]

    resp = Req.delete!(url: server.base_url <> "/tasks/tsk-x", decode_body: false)
    assert resp.status == 405
  end

  test "unknown paths answer 404", %{server: server} do
    assert %{status: 404} = get!(server, "/nope")
    assert %{status: 404} = get!(server, "/tasks/tsk-x/extra-segment")
  end

  test "GET /tasks/tsk-x:cancel (cancel verb with wrong method) answers 405", %{server: server} do
    resp = Req.get!(url: server.base_url <> "/tasks/tsk-x:cancel")
    assert resp.status == 405
    assert resp.headers["allow"] == ["POST"]
  end
end

# ==============================================================================
# SECTION 19: Original test/ash_a2a_transport_plug_force_ssl_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TransportPlugForceSslTest do
  @moduledoc """
  Prod hardening for the HTTP transport (sobelow Config.HTTPS): a
  `AshA2A.Transport.Plug` mount with `force_ssl: [rewrite_on:
  [:x_forwarded_proto]]` refuses plaintext-behind-proxy requests
  (`x-forwarded-proto: http`) with 400 + HSTS, and serves
  `strict-transport-security` on allowed requests too. Real `Plug.Test`
  conns, direct `call/2` invocation; no mocks.
  """

  use ExUnit.Case, async: true

  @force_ssl [rewrite_on: [:x_forwarded_proto], hsts: true, hsts_include_subdomains: true]

  defp mounted(opts \\ []) do
    AshA2A.Transport.Plug.init(Keyword.merge([agent: __MODULE__.NeverStartedAgent], opts))
  end

  test "init defaults :force_ssl to nil" do
    assert %{force_ssl: nil} = AshA2A.Transport.Plug.init(agent: Foo)
  end

  test "plaintext behind proxy is refused with 400 + HSTS" do
    opts = mounted(force_ssl: @force_ssl)

    conn =
      :get
      |> Plug.Test.conn("/.well-known/agent-card.json")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "http")
      |> AshA2A.Transport.Plug.call(opts)

    assert conn.status == 400
    assert conn.halted

    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") == [
             "max-age=63072000; includeSubDomains"
           ]
  end

  test "https-forwarded request passes through with HSTS" do
    opts = mounted(force_ssl: @force_ssl)
    conn = request("/no/such/path", opts, [{"x-forwarded-proto", "https"}])

    assert conn.status == 404

    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") == [
             "max-age=63072000; includeSubDomains"
           ]
  end

  test "no x-forwarded-proto header passes through (direct TLS termination)" do
    opts = mounted(force_ssl: @force_ssl)
    conn = request("/no/such/path", opts, [])
    assert conn.status == 404
    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") != []
  end

  test "direct mount without :force_ssl keeps legacy behavior (no HSTS)" do
    opts = mounted()
    conn = request("/no/such/path", opts, [{"x-forwarded-proto", "http"}])
    assert conn.status == 404
    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") == []
  end

  test "hsts without include_subdomains omits the suffix" do
    opts = mounted(force_ssl: [rewrite_on: [:x_forwarded_proto]])
    conn = request("/no/such/path", opts, [{"x-forwarded-proto", "https"}])
    assert conn.status == 404
    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") == ["max-age=63072000"]
  end

  defp request(path, opts, headers) do
    conn =
      :get
      |> Plug.Test.conn(path)
      |> then(fn c ->
        Enum.reduce(headers, c, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
      end)

    AshA2A.Transport.Plug.call(conn, opts)
  end
end

# ==============================================================================
# SECTION 20: Original test/ash_a2a_transport_wire_compat_test.exs
# ==============================================================================

# Lane V8-Q6-f (2026-11-08): Q6 wire-conversion boundary test.
#
# Chicago discipline: real structs, real conversion calls, final-state
# assertions — no doubles. ash_a2a does not depend on the `a2a` hex
# package, so the test defines the minimal real mirror structs
# (field-identical to `a2a` 0.3.0) at the TOP LEVEL under the real module
# names (`A2A.*`) and drives the real conversion functions against them.

defmodule A2A.Part.Text do
  defstruct text: "", metadata: %{}
end

defmodule A2A.Part.Data do
  defstruct data: %{}, metadata: %{}
end

defmodule A2A.Part.File do
  defstruct file: nil, metadata: %{}
end

defmodule A2A.FileContent do
  defstruct [:name, :mime_type, :bytes, :uri]
end

defmodule A2A.Task.Status do
  defstruct [:state, :message, :timestamp]
end

defmodule A2A.Message do
  @enforce_keys [:role, :parts]
  defstruct [
    :message_id,
    :role,
    :task_id,
    :context_id,
    parts: [],
    reference_task_ids: [],
    metadata: %{},
    extensions: %{}
  ]
end

defmodule A2A.Task do
  @enforce_keys [:id, :status]
  defstruct [
    :id,
    :context_id,
    :status,
    history: [],
    artifacts: [],
    metadata: %{}
  ]
end

defmodule A2A.Artifact do
  @enforce_keys [:parts]
  defstruct [
    :artifact_id,
    :name,
    :description,
    parts: [],
    extensions: [],
    metadata: %{}
  ]
end

defmodule AshA2A.Transport.WireCompatTest do
  use ExUnit.Case, async: true

  alias AshA2A.Transport.WireCompat

  # -- wire_message?/1 ---------------------------------------------------------

  test "detects a wire-shaped A2A.Message and not a protocol message" do
    wire = %A2A.Message{message_id: "m1", role: :user, parts: []}
    proto = %AshA2A.Protocol.Message{role: :user, parts: []}

    assert WireCompat.wire_message?(wire)
    refute WireCompat.wire_message?(proto)
    refute WireCompat.wire_message?(%{role: :user})
  end

  # -- inbound: wire -> protocol -------------------------------------------------

  test "to_protocol converts a wire message with data part to protocol" do
    wire =
      %A2A.Message{
        message_id: "msg-1",
        role: :user,
        parts: [%A2A.Part.Data{data: %{"x" => 1}}],
        metadata: %{"skill" => "some_skill"}
      }

    converted = WireCompat.to_protocol(wire)

    assert %AshA2A.Protocol.Message{} = converted
    assert converted.message_id == "msg-1"
    assert converted.role == :user
    assert converted.metadata == %{"skill" => "some_skill"}

    assert [%AshA2A.Protocol.Part.Data{data: %{"x" => 1}}] = converted.parts
  end

  test "to_protocol passes protocol messages through unchanged" do
    proto = %AshA2A.Protocol.Message{
      role: :user,
      parts: [AshA2A.Protocol.Part.Text.new("hi")],
      message_id: "m-2"
    }

    assert WireCompat.to_protocol(proto) == proto
  end

  test "to_protocol recurses into text and file parts" do
    wire =
      %A2A.Message{
        role: :user,
        parts: [
          %A2A.Part.Text{text: "hello"},
          %A2A.Part.File{file: %A2A.FileContent{name: "a.txt", mime_type: "text/plain"}}
        ]
      }

    converted = WireCompat.to_protocol(wire)

    assert [
             %AshA2A.Protocol.Part.Text{text: "hello"},
             %AshA2A.Protocol.Part.File{
               file: %AshA2A.Protocol.FileContent{name: "a.txt", mime_type: "text/plain"}
             }
           ] = converted.parts
  end

  # -- outbound: protocol -> wire (encode clause) ---------------------------------

  test "to_wire converts {:ok, task} to wire task with wire status and history" do
    agent_message = %AshA2A.Protocol.Message{
      role: :agent,
      parts: [AshA2A.Protocol.Part.Text.new("done")],
      message_id: "m-3"
    }

    task = %AshA2A.Protocol.Task{
      id: "tsk-1",
      status: AshA2A.Protocol.Task.Status.new(:completed),
      history: [agent_message],
      artifacts: [AshA2A.Protocol.Artifact.new([AshA2A.Protocol.Part.Text.new("r")])]
    }

    {:ok, converted} = WireCompat.to_wire({:ok, task})

    assert %A2A.Task{} = converted
    assert converted.id == "tsk-1"
    assert %A2A.Task.Status{state: :completed} = converted.status

    assert [
             %A2A.Message{role: :agent, parts: [%A2A.Part.Text{text: "done"}]}
           ] = converted.history

    assert [%A2A.Artifact{parts: [%A2A.Part.Text{text: "r"}]}] = converted.artifacts
  end

  test "to_wire converts {:ok, message} and passes errors through" do
    proto = %AshA2A.Protocol.Message{
      role: :agent,
      parts: [AshA2A.Protocol.Part.Text.new("hi")],
      message_id: "m-4"
    }

    assert {:ok, %A2A.Message{}} = WireCompat.to_wire({:ok, proto})
    assert {:error, :whatever} = WireCompat.to_wire({:error, :whatever})
    assert WireCompat.to_wire(:bare) == :bare
  end

  # -- mirror round-trip: wire -> protocol -> wire ----------------------------------

  test "wire -> protocol -> wire round-trips a full message tree" do
    wire =
      %A2A.Message{
        message_id: "m-5",
        role: :user,
        parts: [%A2A.Part.Data{data: %{"k" => [1, 2]}}]
      }

    round_tripped =
      wire
      |> WireCompat.to_protocol()
      |> then(&{:ok, &1})
      |> WireCompat.to_wire()
      |> elem(1)

    assert round_tripped == wire
  end
end

# ==============================================================================
# SECTION 21: Original test/ash_a2a_two_port_gate_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TwoPortGateTest do
  @moduledoc """
  The algebraic two-port lease gate (loops-of-loops spec §1 Loop 1, lane L1):
  real Ed25519 keys, real signed leases, the real gate, the real CommandBus
  with a real ReceiptStore.Memory — Chicago discipline, no doubles.

  Covers: conjunct masks (single-bit tampers 0x1/0x2/0x4/0x8, all-four 0xF),
  the hybrid clock law (same-VM monotonic window; cross-VM wall fallback,
  both directions), fail-closed missing-key, the RDFC-1.0 root recomputation
  path, the branchless witness, e2e opt-in wiring in `CommandBus.run/4`
  (admit / refuse-before-claim / silent skip), and the ≤10ms budget
  measurement (assert a generous CI bound; the measured number is printed).
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Authority.Lease
  alias AshA2A.Authority.TwoPortGate
  alias AshA2A.{Command, CommandBus, ReceiptStore, SemanticSubject}
  alias AshA2A.Semantic.CanonicalGraph
  alias AshA2A.Test.Fixture.Echo

  @ga "sha256:" <> String.duplicate("a", 64)
  @gb "sha256:" <> String.duplicate("b", 64)
  @gc "sha256:" <> String.duplicate("c", 64)
  @gd "sha256:" <> String.duplicate("d", 64)
  @ge "sha256:" <> String.duplicate("e", 64)

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  # --- real collaborators -----------------------------------------------------

  defp subject do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: @ga,
        projection_digest: @gb,
        manufacturer_digest: @gc,
        ephemeral?: false
      )

    subject
  end

  defp command do
    Command.new("AshA2A.Test.Fixture.Echo.read",
      command_id: "two-port-1",
      agent_id: "test",
      principal_id: "p-1",
      task_id: "task-1",
      semantic_subject: subject(),
      input: %{},
      metadata: %{candidate_digest: "sha256:two-port-candidate"}
    )
  end

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  defp signed_lease(cmd, opts \\ []) do
    {pub, priv} = keypair()
    {:ok, signed} = cmd |> Lease.for_command(opts) |> Lease.sign(priv)
    {pub, signed}
  end

  defp flip_byte(%Lease{signature: <<b, rest::binary>>} = lease),
    do: %{lease | signature: <<Bitwise.bxor(b, 1), rest::binary>>}

  defp expired_wall(cmd) do
    Lease.for_command(cmd, issued_monotonic_ms: nil)
    |> struct(not_before: ~U[2020-01-01 00:00:00Z], expires_at: ~U[2020-01-02 00:00:00Z])
  end

  defp future_wall(cmd) do
    Lease.for_command(cmd, issued_monotonic_ms: nil)
    |> struct(not_before: DateTime.add(DateTime.utc_now(), 3600, :second))
  end

  # --- conjunct masks ---------------------------------------------------------

  describe "TwoPortGate.evaluate/3 conjunct masks" do
    test "valid same-VM lease admits with the null mask" do
      {pub, signed} = signed_lease(command())
      assert :admitted = TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "scope tamper refuses with exactly 0x1" do
      {pub, priv} = keypair()

      {:ok, signed} =
        command() |> Lease.for_command() |> struct(scope_digest: @gd) |> Lease.sign(priv)

      assert {:error, {:refused_lease, 0x1, %{codes: [:lease_scope_mismatch]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "root tamper refuses with exactly 0x2" do
      {pub, priv} = keypair()

      {:ok, signed} =
        command() |> Lease.for_command() |> struct(root_digest: @gd) |> Lease.sign(priv)

      assert {:error, {:refused_lease, 0x2, %{codes: [:lease_root_mismatch]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "cross-VM expired lease refuses with exactly 0x4" do
      {pub, priv} = keypair()
      {:ok, signed} = Lease.sign(expired_wall(command()), priv)

      assert {:error, {:refused_lease, 0x4, %{codes: [:lease_expired]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "cross-VM future not_before refuses with 0x4 (wall path only)" do
      {pub, priv} = keypair()
      {:ok, signed} = Lease.sign(future_wall(command()), priv)

      assert {:error, {:refused_lease, 0x4, %{codes: [:lease_expired]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "same-VM future not_before does NOT bite (window opens at issuance)" do
      # Documented consequence of the hybrid law: on the same-VM path the
      # monotonic window is [issued_monotonic, issued_monotonic + duration];
      # not_before bounds only the cross-VM wall path.
      {pub, priv} = keypair()

      nb = DateTime.add(DateTime.utc_now(), 3600, :second)

      future =
        Lease.for_command(command())
        |> struct(not_before: nb, expires_at: DateTime.add(nb, 60, :second))

      {:ok, signed} = Lease.sign(future, priv)

      assert :admitted = TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "zero-duration window refuses with 0x4" do
      {pub, priv} = keypair()

      zero =
        Lease.new(
          lease_id: "lease-zero",
          scope_digest: Lease.scope_digest_for(command()),
          root_digest: @ga,
          not_before: ~U[2026-01-02 00:00:00Z],
          expires_at: ~U[2026-01-01 00:00:00Z],
          issued_monotonic_ms: System.monotonic_time(:millisecond)
        )

      {:ok, signed} = Lease.sign(zero, priv)

      assert {:error, {:refused_lease, 0x4, %{codes: [:lease_expired]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "flipped signature byte refuses with exactly 0x8" do
      {pub, signed} = signed_lease(command())
      forged = flip_byte(signed)

      assert {:error, {:refused_lease, 0x8, %{codes: [:lease_signature_invalid]}}} =
               TwoPortGate.evaluate(command(), forged, lease_public_key: pub)
    end

    test "missing public key fails closed with 0x8" do
      {_pub, signed} = signed_lease(command())

      assert {:error, {:refused_lease, 0x8, %{codes: [:lease_signature_invalid]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: nil)
    end

    test "all four broken refuses with 0xF and all four codes" do
      {pub, priv} = keypair()

      broken =
        Lease.for_command(command())
        |> struct(
          scope_digest: @gd,
          root_digest: @ge,
          issued_monotonic_ms: nil,
          not_before: ~U[2020-01-01 00:00:00Z],
          expires_at: ~U[2020-01-02 00:00:00Z]
        )
        |> Lease.sign(priv)
        |> elem(1)
        |> flip_byte()

      assert {:error, {:refused_lease, 0xF, %{codes: code_list}}} =
               TwoPortGate.evaluate(command(), broken, lease_public_key: pub)

      assert code_list == [
               :lease_scope_mismatch,
               :lease_root_mismatch,
               :lease_expired,
               :lease_signature_invalid
             ]
    end
  end

  # --- decode / refusal code map ----------------------------------------------

  describe "mask decode and refusal-code map" do
    test "decode(0) is empty; each bit decodes to its code" do
      assert [] = TwoPortGate.decode(0x0)
      assert [%{code: :lease_scope_mismatch, bit: 1}] = TwoPortGate.decode(0x1)
      assert [%{code: :lease_root_mismatch, bit: 2}] = TwoPortGate.decode(0x2)
      assert [%{code: :lease_expired, bit: 4}] = TwoPortGate.decode(0x4)
      assert [%{code: :lease_signature_invalid, bit: 8}] = TwoPortGate.decode(0x8)

      assert [_, _, _, _] = TwoPortGate.decode(0xF)
    end

    test "gate refusal codes are refused_authority class" do
      codes = TwoPortGate.__sa2a_refusal_codes__()

      assert codes == %{
               lease_scope_mismatch: :refused_authority,
               lease_root_mismatch: :refused_authority,
               lease_expired: :refused_authority,
               lease_signature_invalid: :refused_authority
             }
    end
  end

  # --- hybrid clock law -------------------------------------------------------

  describe "hybrid clock law" do
    test "cross-VM lease (nil monotonic) admits inside the wall window" do
      {pub, priv} = keypair()
      {:ok, signed} = Lease.sign(Lease.for_command(command(), issued_monotonic_ms: nil), priv)

      assert :admitted = TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end
  end

  # --- RDFC-1.0 root path -----------------------------------------------------

  describe "RDF state root recomputation" do
    @ttl "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\n"

    test "matching RDFC-1.0 digest admits" do
      {:ok, root} = CanonicalGraph.canonical_digest(@ttl)
      {pub, priv} = keypair()
      lease = Lease.for_command(command(), root_digest: root)
      {:ok, signed} = Lease.sign(lease, priv)

      assert :admitted =
               TwoPortGate.evaluate(command(), signed,
                 lease_public_key: pub,
                 rdf_state: @ttl
               )
    end

    test "mismatching RDF root refuses 0x2" do
      {pub, priv} = keypair()
      lease = Lease.for_command(command(), root_digest: @ga)
      {:ok, signed} = Lease.sign(lease, priv)

      assert {:error, {:refused_lease, 0x2, %{codes: [:lease_root_mismatch]}}} =
               TwoPortGate.evaluate(command(), signed,
                 rdf_state: @ttl,
                 lease_public_key: pub
               )
    end

    test "unparseable RDF state fails closed with 0x2" do
      {pub, priv} = keypair()
      lease = Lease.for_command(command(), root_digest: @ga)
      {:ok, signed} = Lease.sign(lease, priv)

      assert {:error, {:refused_lease, 0x2, %{codes: [:lease_root_mismatch]}}} =
               TwoPortGate.evaluate(command(), signed,
                 rdf_state: <<0xFF>>,
                 lease_public_key: pub
               )
    end
  end

  # --- Lease unit law ---------------------------------------------------------

  describe "Lease sign/verify" do
    test "roundtrip verifies; foreign key refuses" do
      {pub, priv} = keypair()
      {:ok, signed} = Lease.for_command(command()) |> Lease.sign(priv)

      assert :ok = Lease.verify(signed, signed.signature, pub)
      assert {:error, :bad_signature} = Lease.verify(signed, signed.signature, elem(keypair(), 0))
    end

    test "payload tamper invalidates the signature" do
      {pub, priv} = keypair()
      {:ok, signed} = Lease.for_command(command()) |> Lease.sign(priv)

      assert {:error, :bad_signature} =
               Lease.verify(%{signed | payload_map: %{"x" => 1}}, signed.signature, pub)
    end

    test "missing signature or key fails closed" do
      lease = Lease.for_command(command())

      assert {:error, :bad_signature} = Lease.verify(lease, nil, elem(keypair(), 0))
      assert {:error, :bad_key} = Lease.verify(lease, <<0::256>>, nil)
    end
  end

  # --- branchless witness -----------------------------------------------------

  describe "branchless witness" do
    test "hook sees exactly four conjunct evaluations on both tails" do
      {pub, priv} = keypair()
      cmd = command()

      hook = fn name, failed? -> send(self(), {:conjunct, name, failed?}) end

      {:ok, valid} = Lease.for_command(cmd) |> Lease.sign(priv)

      assert :admitted =
               TwoPortGate.evaluate(cmd, valid, lease_public_key: pub, conjunct_hook: hook)

      admitted_calls = drain([])

      broken = Lease.for_command(cmd) |> struct(scope_digest: @gd, root_digest: @ge)
      {:ok, broken_signed} = Lease.sign(broken, priv)

      assert {:error, {:refused_lease, _, _}} =
               TwoPortGate.evaluate(cmd, broken_signed,
                 lease_public_key: pub,
                 conjunct_hook: hook
               )

      refused_calls = drain([])

      assert [:scope, :root, :clock, :signature] = Enum.map(admitted_calls, &elem(&1, 0))
      assert [false, false, false, false] = Enum.map(admitted_calls, &elem(&1, 1))
      assert [:scope, :root, :clock, :signature] = Enum.map(refused_calls, &elem(&1, 0))
      assert [true, true, false, false] = Enum.map(refused_calls, &elem(&1, 1))
    end
  end

  defp drain(acc) do
    receive do
      {:conjunct, name, failed?} -> drain([{name, failed?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # --- e2e through the real CommandBus ----------------------------------------

  describe "e2e through CommandBus.run/4 (opt-in lease gate)" do
    test "valid lease admitted before claim; receipt minted and replayed", %{
      store_opts: store_opts
    } do
      cmd = command()
      {pub, signed} = signed_lease(cmd)

      assert {:ok, first} =
               CommandBus.run(cmd, data_message(%{}), Echo,
                 store_opts: store_opts,
                 lease: signed,
                 lease_public_key: pub
               )

      assert first.status == :completed

      assert {:ok, replay} =
               CommandBus.run(cmd, data_message(%{}), Echo,
                 store_opts: store_opts,
                 lease: signed,
                 lease_public_key: pub
               )

      assert replay.replayed?
      assert replay.receipt_id == first.receipt_id
    end

    test "tampered lease refused before claim; no receipt minted", %{store_opts: store_opts} do
      cmd = command()
      {pub, priv} = keypair()

      {:ok, tampered} =
        cmd |> Lease.for_command() |> struct(scope_digest: @gd) |> Lease.sign(priv)

      assert {:error, %{code: :refused_lease, mask: 0x1}} =
               CommandBus.run(cmd, data_message(%{}), Echo,
                 store_opts: store_opts,
                 lease: tampered,
                 lease_public_key: pub
               )

      assert :error = ReceiptStore.Memory.fetch(cmd.command_id, store_opts)
    end

    test "opt-in skip: no lease, run completes, lease_gate telemetry never fires", %{
      store_opts: store_opts
    } do
      handler_id = "two-port-skip-#{System.unique_integer()}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:ash_a2a, :command_bus, :lease_gate],
          fn _, _, _, _ ->
            send(self(), :lease_gate_fired)
          end,
          %{}
        )

      assert {:ok, receipt} =
               CommandBus.run(command(), data_message(%{}), Echo, store_opts: store_opts)

      assert receipt.status == :completed
      refute_received :lease_gate_fired
      :telemetry.detach(handler_id)
    end
  end

  # --- budget ------------------------------------------------------------------

  describe "budget (loops-of-loops §1 Loop 1 gate budget)" do
    test "admission path with a real signed lease measures inside the CI bound" do
      cmd = command()
      {pub, signed} = signed_lease(cmd)

      for _ <- 1..10, do: TwoPortGate.evaluate(cmd, signed, lease_public_key: pub)

      samples =
        for _ <- 1..25 do
          {us, :admitted} =
            :timer.tc(fn -> TwoPortGate.evaluate(cmd, signed, lease_public_key: pub) end)

          us
        end

      sorted = Enum.sort(samples)
      median = Enum.at(sorted, div(length(sorted), 2))
      max_us = Enum.max(sorted)

      IO.puts("""
      [two-port gate budget] admission path, real Ed25519 verify, 25 samples:
        median #{median}us
        max    #{max_us}us
      """)

      assert median < 50_000, "gate admission median #{median}us exceeded the 50ms CI bound"
    end
  end
end

