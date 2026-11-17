# NOTE: 6 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root Authority Dispatcher DSL
# Target File 2 of Worker 01
# Consolidated from 22 source files:
#   - test/ash_a2a_cancel_inflight_test.exs
#   - test/ash_a2a_castle_ocel_projection_test.exs
#   - test/ash_a2a_check_gate_test.exs
#   - test/ash_a2a_client_card_verify_test.exs
#   - test/ash_a2a_client_http_json_test.exs
#   - test/ash_a2a_command_bus_concurrency_test.exs
#   - test/ash_a2a_command_bus_crash_window_chicago_test.exs
#   - test/ash_a2a_command_bus_duplicate_action_names_test.exs
#   - test/ash_a2a_command_bus_outbox_chicago_test.exs
#   - test/ash_a2a_command_fingerprint_determinism_test.exs
#   - test/ash_a2a_commitment_telemetry_test.exs
#   - test/ash_a2a_conditional_commitment_test.exs
#   - test/ash_a2a_dispatcher_error_class_test.exs
#   - test/ash_a2a_dispatcher_fetch_record_test.exs
#   - test/ash_a2a_dispatcher_not_found_test.exs
#   - test/ash_a2a_dispatcher_skill_name_shape_test.exs
#   - test/ash_a2a_dispatcher_skills_test.exs
#   - test/ash_a2a_dispatcher_tenant_test.exs
#   - test/ash_a2a_doctest_test.exs
#   - test/ash_a2a_domain_transports_test.exs
#   - test/ash_a2a_dsl_nested_argument_test.exs
#   - test/ash_a2a_dsl_nested_hddl_operator_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a_cancel_inflight_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CancelInflightTest do
  @moduledoc """
  Real, unmocked coverage for research item #5: cancellation of a genuinely
  in-flight `AshA2A`-dispatched task, driven through a real `AshA2A.Protocol.Agent`
  GenServer under a real `AshA2A.Protocol.AgentSupervisor` -- not a bare
  `AshA2A.Dispatcher.dispatch/5` function call, and not a synthetic
  `context()` map handed straight to `AshA2A.Agent.__cancel__/2`.

  See `AshA2A.Test.Fixture.StreamItem`'s moduledoc
  (`test/support/cancel_fixture.ex`) for why a streaming `:read` skill is
  the one real mechanism that produces a task that is still `:working`
  (non-terminal, i.e. genuinely in-flight) while the agent's mailbox is
  free to accept a real concurrent `cancel/2` call -- an ordinary
  synchronous action blocks the same mailbox the cancel call would need to
  arrive through, so no real interleaving exists for it.

  No `Mock`/`mox`/`patch`/`monkeypatch` anywhere in this file: the resource,
  the agent, the supervisor, the stream, and the cancel call are all real.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.StreamItem
  alias AshA2A.Test.Fixture.StreamItemAgent

  test "a real concurrent cancel/2 interrupts a genuinely in-flight streaming dispatch" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [StreamItemAgent])

    # Seed real rows through the real Ash action (bypassing A2A entirely for
    # setup) so the streaming read below has real data to stream from --
    # irrelevant to the cancel assertion itself, but proves this is a real
    # `Ash.stream!/2` over real records, not an empty/degenerate stream.
    Ash.create!(StreamItem, %{label: "one"})
    Ash.create!(StreamItem, %{label: "two"})

    handler_id = "cancel-inflight-telemetry-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ash_a2a, :agent, :cancel],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:ash_a2a_cancel_telemetry, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Explicit `"skill" => "list_items"` metadata is required here: since
    # `fbc3213` ("derive canonical skills from public Ash actions"), the
    # capability index is compiled from *every* public Ash action on the
    # resource (`AshA2A.CapabilityIndex.Compiler.compile_resource/2`), not
    # just the `a2a do skill ... end` overrides declared in
    # `test/support/cancel_fixture.ex`. `StreamItem` has two public actions
    # (`:read`, exposed here as `:list_items`, and the default `:create`
    # used by this test's own `Ash.create!/2` setup calls above) -- both are
    # now real, legitimately-dispatchable skills, so
    # `AshA2A.Agent.default_skill_name/1`'s single-skill omission
    # convenience (`AshA2A.Info.capability_index/1` returning exactly one
    # entry) no longer applies and correctly refuses to guess
    # (`{:error, {:ambiguous_skill, resource}}`) when the caller doesn't say
    # which skill it means. This is real, intentional new admission
    # behavior, not a lifecycle regression: confirmed by driving
    # `AshA2A.Dispatcher.dispatch/3` directly with `:list_items` (bypassing
    # skill-name resolution entirely), which still returns a real
    # `{:stream, ...}` reply exactly as before -- only the *default* skill
    # inference changed, not dispatch or task-lifecycle admission.
    message = data_message(%{"stream" => true}, %{metadata: %{"skill" => "list_items"}})

    assert {:ok, task} = StreamItemAgent.call(StreamItemAgent, message)

    # Real, in-flight, non-terminal state: the GenServer already replied
    # (mailbox free), but the stream in `task.metadata[:stream]` has
    # deliberately not been consumed, so `AshA2A.Protocol.Agent.Runtime.wrap_stream/3`'s
    # `{:stream_done, ...}` finalizing cast has never fired.
    assert task.status.state == :working
    assert is_function(task.metadata[:stream])

    assert :ok = StreamItemAgent.cancel(StreamItemAgent, task.id)

    # Real evidence that `AshA2A.Agent.__cancel__/2` (not just `AshA2A.Protocol.Agent`'s
    # own state machine) actually ran: it is the one call site that emits
    # this telemetry event, and it only fires from inside
    # `AshA2A.Protocol.Agent.Runtime.run_cancel/2`, which only runs for a real
    # non-terminal task (`~/xaas/deps/a2a/lib/a2a/agent.ex:305-309`).
    # Pinned on task_id: async modules cancel concurrently and fire the same
    # global telemetry event, so the first message may belong to another test.
    task_id = task.id
    assert_receive {:ash_a2a_cancel_telemetry, %{task_id: ^task_id} = cancel_meta}, 1_000
    assert cancel_meta.task_id == task.id
    assert cancel_meta.resource_or_domain == StreamItem

    # Real terminal state, fetched back through the real agent process --
    # not inferred from the `cancel/2` return value alone.
    assert {:ok, canceled_task} = StreamItemAgent.get_task(StreamItemAgent, task.id)
    assert canceled_task.status.state == :canceled

    # Real proof the state is actually terminal now: a second cancel on the
    # same task_id is idempotent success (v1.0 §3.3.1 — the canceled task is
    # returned unchanged, no second on_cancel hook).
    assert :ok = StreamItemAgent.cancel(StreamItemAgent, task.id)
  end
end


# --- SECTION 2: Original test/ash_a2a_castle_ocel_projection_test.exs ---
defmodule AshA2A.CastleOcelProjectionTest do
  @moduledoc """
  Court for `AshA2A.Telemetry.CastleOcel`: totality over the S42 standing
  domain, the authority/provenance invariant, determinism, and the sabotage
  twin (an unknown standing refuses with a typed error, never silently).
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Refusal
  alias AshA2A.Telemetry.CastleOcel

  @time "2026-10-13T00:00:00Z"

  defp obs(standing, overrides \\ %{}) do
    Map.merge(
      %{standing: standing, subject_id: "subject-1", time: @time},
      overrides
    )
  end

  describe "standing_to_event/1 totality" do
    test "every S42 class plus :admitted projects to an event in the CastleOcel vocabulary" do
      castle_vocabulary =
        MapSet.new([
          "system_bootstrapped",
          "pod_provisioned",
          "container_started",
          "ggen_sync_observed",
          "activity_started",
          "activity_finished",
          "episode_recorded",
          "evidence_admitted",
          "episode_receipt_sealed",
          "refused_observation"
        ])

      for standing <- [:admitted | Refusal.classes()] do
        event_name = CastleOcel.standing_to_event(standing)

        assert is_binary(event_name),
               "#{inspect(standing)} has no mapping (totality violation)"

        assert MapSet.member?(castle_vocabulary, event_name),
               "#{inspect(standing)} maps to #{event_name}, outside the closed vocabulary"
      end
    end

    test "refused classes map to refused_observation; admitted to evidence_admitted" do
      assert CastleOcel.standing_to_event(:admitted) == "evidence_admitted"

      for class <- Refusal.refused_classes() do
        assert CastleOcel.standing_to_event(class) == "refused_observation"
      end
    end

    test "documented non-mapping: BLOCKED_*/UNSUPPORTED are observations, never refusals" do
      for class <- Refusal.blocked_classes() ++ Refusal.unsupported_classes() do
        assert CastleOcel.standing_to_event(class) == "ggen_sync_observed"
      end
    end

    test "unknown standings have no mapping" do
      for standing <- [:totally_unknown, :alive, :refused_not_a_class] do
        assert CastleOcel.standing_to_event(standing) == nil
        assert CastleOcel.standing_to_event(Atom.to_string(standing)) == nil
      end
    end
  end

  describe "projection" do
    test "admitted projects to evidence_admitted with the fixed attributes" do
      {:ok, event} = CastleOcel.project_event(obs(:admitted))

      assert event["event_type"] == "evidence_admitted"
      assert event["event_id"] == "ash-a2a-0001-evidence_admitted"
      assert event["event_time"] == @time

      assert event["attributes"] == %{
               "authority" => "none",
               "provenance" => "observation_only",
               "standing" => "admitted",
               "subject_id" => "subject-1",
               "tool" => "ash_a2a admission"
             }
    end

    test "a refused class projects to refused_observation carrying refusal_class/code" do
      {:ok, event} =
        CastleOcel.project_event(obs(:refused_authority, %{refusal_code: "authority_required"}))

      assert event["event_type"] == "refused_observation"
      assert event["attributes"]["refusal_class"] == "refused_authority"
      assert event["attributes"]["refusal_code"] == "authority_required"
      assert event["attributes"]["authority"] == "none"
    end

    test "refused_observation without a refusal_code gets the honest default" do
      {:ok, event} = CastleOcel.project_event(obs(:refused_bounds))
      assert event["attributes"]["refusal_code"] == "REFUSED"
    end

    test "blocked/unsupported classes project as ggen_sync_observed, not refusals" do
      for class <- Refusal.blocked_classes() ++ Refusal.unsupported_classes() do
        {:ok, event} = CastleOcel.project_event(obs(class))
        assert event["event_type"] == "ggen_sync_observed"
        assert event["attributes"]["refusal_class"] == Atom.to_string(class)
      end
    end
  end

  describe "authority invariant" do
    test "every projected event over the whole standing domain carries authority=none" do
      for standing <- [:admitted | Refusal.classes()] do
        {:ok, %{"events" => events}} = CastleOcel.project([obs(standing)])

        for event <- events do
          assert event["attributes"]["authority"] == "none"
          assert event["attributes"]["provenance"] == "observation_only"
        end
      end
    end
  end

  describe "determinism" do
    test "same inputs -> structurally identical envelope" do
      trace = [
        obs(:admitted),
        obs(:refused_identity, %{subject_id: "subject-2", refusal_code: "invalid_request_id"}),
        obs(:blocked_resource),
        obs(:admitted, %{subject_id: "subject-3"})
      ]

      {:ok, a} = CastleOcel.project(trace)
      {:ok, b} = CastleOcel.project(trace)

      assert a == b
      assert length(a["events"]) == 4
      assert a["events"] |> Enum.map(& &1["event_id"]) |> Enum.uniq() |> length() == 4

      assert a["objectTypes"] == [
               %{"name" => "container", "attributes" => []},
               %{"name" => "gym_act_episode", "attributes" => []},
               %{"name" => "system", "attributes" => []}
             ]

      objects = a["objects"]
      system = Enum.find(objects, &(&1["object_type"] == "system"))
      gym = Enum.find(objects, &(&1["object_type"] == "gym_act_episode"))
      container = Enum.find(objects, &(&1["object_type"] == "container"))

      assert system["object_id"] == "ash-a2a-admission"
      assert gym["object_id"] == "subject:subject-1"
      assert container["object_id"] == "ash-a2a-admission:blocked_resource"
    end
  end

  describe "sabotage twin" do
    test "an unknown standing -> typed error, never a silent projection" do
      assert {:error, {:unknown_class, :not_a_real_standing}} =
               CastleOcel.project_event(obs(:not_a_real_standing))

      assert {:error, {:unknown_class, "alive"}} = CastleOcel.project_event(obs("alive"))

      assert {:error, {:unknown_class, :not_a_real_standing}} =
               CastleOcel.project([obs(:admitted), obs(:not_a_real_standing)])
    end

    test "malformed observations refuse with typed errors" do
      assert {:error, {:invalid_observation, :nope}} = CastleOcel.project_event(:nope)

      assert {:error, {:missing_subject_id, :admitted}} =
               CastleOcel.project_event(%{standing: :admitted, time: @time})

      assert {:error, {:subject_id_not_binary, :admitted, 42}} =
               CastleOcel.project_event(obs(:admitted, %{subject_id: 42}))

      assert {:error, {:missing_time, :admitted}} =
               CastleOcel.project_event(%{standing: :admitted, subject_id: "s"})

      assert {:error, {:time_not_binary, :admitted, 0}} =
               CastleOcel.project_event(obs(:admitted, %{time: 0}))
    end
  end

  describe "envelope totality, declared attributes and E2O relationships" do
    test "the documented class count matches Refusal.classes/0 (15 + 2 + 1 = 18; 19 known)" do
      assert length(Refusal.refused_classes()) == 15
      assert length(Refusal.blocked_classes()) == 2
      assert length(Refusal.unsupported_classes()) == 1
      assert length(Refusal.classes()) == 18
      assert length(CastleOcel.known_standings()) == 19
    end

    test "projecting every Refusal class (blocked_*, unsupported_* included) yields a total envelope" do
      standings = [:admitted | Refusal.classes()]
      trace = Enum.map(standings, &obs(&1))

      assert {:ok, envelope} = CastleOcel.project(trace)
      assert length(envelope["events"]) == length(standings)

      for class <- Refusal.blocked_classes() ++ Refusal.unsupported_classes() do
        assert CastleOcel.standing_to_event(class) == "ggen_sync_observed"
      end
    end

    test "eventTypes declare the attributes events carry; every event attribute is declared" do
      {:ok, envelope} = CastleOcel.project(Enum.map([:admitted | Refusal.classes()], &obs(&1)))

      declared =
        Map.new(envelope["eventTypes"], fn %{"name" => n, "attributes" => attrs} ->
          {n, Enum.map(attrs, & &1["name"])}
        end)

      for %{"event_type" => type, "attributes" => attrs} <- envelope["events"] do
        for key <- Map.keys(attrs) do
          assert key in Map.fetch!(declared, type), "#{key} undeclared on #{type}"
        end
      end

      assert Enum.all?(envelope["eventTypes"], fn %{"attributes" => a} ->
               Enum.all?(a, &(is_binary(&1["name"]) and &1["type"] == "string"))
             end)
    end

    test "every relationship object_id exists in objects and project_event carries relationships" do
      {:ok, envelope} =
        CastleOcel.project([
          obs(:admitted),
          obs(:refused_identity, %{subject_id: "s-2"}),
          obs(:blocked_unknown, %{subject_id: "s-3"}),
          obs(:unsupported_profile, %{subject_id: "s-4"})
        ])

      object_ids = MapSet.new(envelope["objects"], & &1["object_id"])

      for event <- envelope["events"] do
        assert [_ | _] = event["relationships"]

        for %{"object_id" => id, "qualifier" => q} <- event["relationships"] do
          assert is_binary(q)
          assert MapSet.member?(object_ids, id), "#{id} not in objects"
        end

        {_type, bound_id} = CastleOcel.object_binding(event)
        assert bound_id in Enum.map(event["relationships"], & &1["object_id"])
      end

      assert {:ok, single} = CastleOcel.project_event(obs(:refused_rule))

      assert [%{"qualifier" => "observed_by"}, %{"qualifier" => "observed_subject"}] =
               single["relationships"]
    end
  end
end


# --- SECTION 3: Original test/ash_a2a_check_gate_test.exs ---
defmodule AshA2A.CheckGateTest do
  @moduledoc """
  Gate for the gate: asserts `mix check` (`.check.exs`) is fully wired --
  every ash-project-bar stage declared, the default subset green-scoped,
  the alias and dev deps present, and the script itself executable (real
  `CHECK_STAGES=list` subprocess).
  """

  use ExUnit.Case, async: true

  @check_script Path.join(__DIR__, "../.check.exs") |> Path.expand()
  @credo_config Path.join(__DIR__, "../.credo.exs") |> Path.expand()
  @mix_exs Path.join(__DIR__, "../mix.exs") |> Path.expand()

  @full_stages ~w(compile test spark_formatter conformance docs credo dialyzer sobelow)
  @default_stages ~w(compile test)

  describe "check script stage wiring" do
    test "declares every stage of the ash-project bar" do
      script = File.read!(@check_script)

      for stage <- @full_stages do
        assert script =~ "{:#{stage}", message: "stage #{stage} not declared in .check.exs"
      end
    end

    test "every declared command names a real mix task or compile/test/docs entrypoint" do
      script = File.read!(@check_script)

      # conformance stage must gate on the real report task that exists on disk
      assert File.exists?(Path.join(__DIR__, "../lib/mix/tasks/ash_a2a.v1_conformance_report.ex"))

      assert script =~ "ash_a2a.v1_conformance_report" or script =~ "V1ConformanceReport"
      assert script =~ "--warnings-as-errors"
      assert script =~ "spark.formatter"
      assert script =~ "--strict"
      assert script =~ "dialyzer"
      assert script =~ "sobelow"
    end

    test "CHECK_STAGES scoping is implemented" do
      script = File.read!(@check_script)
      assert script =~ "CHECK_STAGES"
    end

    test "default set is a subset of the full set" do
      script = File.read!(@check_script)

      default_decl =
        script |> String.split("default_stages = ") |> Enum.at(1) |> String.split("\n") |> hd

      for stage <- @default_stages do
        assert default_decl =~ stage, "default stage #{stage} missing from @default_stages decl"
      end
    end

    test "script compiles and runs: CHECK_STAGES=list exits 0 and lists the full set" do
      {out, code} =
        System.cmd("mix", ["check"],
          env: %{"CHECK_STAGES" => "list", "MIX_BUILD_ROOT" => build_root()},
          stderr_to_stdout: true,
          cd: Path.join(__DIR__, "..")
        )

      assert code == 0, out

      for stage <- @full_stages do
        assert out =~ stage
      end

      assert out =~ "Default set"
    end

    test "unknown stage is refused with exit 64" do
      {out, code} =
        System.cmd("mix", ["check"],
          env: %{"CHECK_STAGES" => "compile,bogus_stage", "MIX_BUILD_ROOT" => build_root()},
          stderr_to_stdout: true,
          cd: Path.join(__DIR__, "..")
        )

      assert code == 64, out
      assert out =~ "unknown stage"
    end
  end

  describe "mix.exs wiring" do
    test "check alias dispatches to the check script" do
      assert File.read!(@mix_exs) =~ ~s(check: "run .check.exs")
    end

    test "credo and sobelow are declared dev deps" do
      mix = File.read!(@mix_exs)
      assert mix =~ ~s({:credo, "~> 1.7", only: :dev, runtime: false})
      assert mix =~ ~s({:sobelow, "~> 0.13", only: :dev, runtime: false})
    end
  end

  describe "credo config" do
    test "parses as Elixir and is strict with lib on the analysis path" do
      assert {config, _} = Code.eval_string(File.read!(@credo_config))
      assert %{configs: [cfg]} = config
      assert cfg.strict == true
      assert "lib/" in cfg.files.included
    end
  end

  defp build_root do
    System.get_env("MIX_BUILD_ROOT") || "_build"
  end
end


# --- SECTION 4: Original test/ash_a2a_client_card_verify_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.CardVerifyFixture do
  @moduledoc """
  Real ETS-backed `Ash.Resource` fixture for
  `test/ash_a2a_client_card_verify_test.exs` (lane W9) — a genuine
  `Ash.Resource` with `extensions: [AshA2A]` and one real `a2a do skill ...
  end` declaration, plus its `Ash.Domain`, so `AshA2A.Info.agent_card/2`
  builds the card from the same compiled capability index the runtime
  serves. Defined inside the test file itself (owned-file constraint);
  no mocks anywhere.
  """

  use Ash.Resource,
    domain: AshA2A.Test.CardVerifyFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:utterance, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.Test.CardVerifyFixture.Domain do
  @moduledoc """
  Real fixture domain pairing `AshA2A.Test.CardVerifyFixture` so
  `AshA2A.Info.agent_card/2` has a real, verified capability index to build
  the card from.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.CardVerifyFixture)
  end
end

defmodule AshA2A.Protocol.ClientCardVerifyTest do
  @moduledoc """
  Real end-to-end court for client-side card signature verification on the
  `AshA2A.Protocol.Client.discover/2` path (lane W9): a REAL Bandit HTTP
  server serves a REAL signed card — a card built from a real fixture
  resource's capability index and signed with
  `AshA2A.Protocol.CardSigning.sign/3` — over the wire, and the real `Req`
  client verifies it post-decode. Zero mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Protocol.CardSigning
  alias AshA2A.Protocol.Client
  alias AshA2A.Test.EphemeralHttp

  @resource AshA2A.Test.CardVerifyFixture

  @key :crypto.strong_rand_bytes(32)
  @wrong_key :crypto.strong_rand_bytes(32)

  defmodule Store do
    @moduledoc """
    Real shared server state: the serving mode (`:signed`, `:tampered`, or
    `:unsigned`) and the signed card each mode serves from.
    """

    defstruct [:signed_card, mode: :signed]
  end

  defmodule CardServer do
    @moduledoc """
    Real Plug.Router serving the agent card. In `:tampered` mode the card is
    re-encoded with one byte of its description flipped AFTER signing, so the
    wire body no longer matches the signature's digest. In `:unsigned` mode
    the `signatures` member is stripped from the wire body entirely.
    """

    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/.well-known/agent-card.json" do
      %{mode: mode, signed_card: signed_card} =
        Agent.get(AshA2A.Protocol.ClientCardVerifyTest.Store, & &1)

      body_map =
        case mode do
          :tampered ->
            [skill | rest] = signed_card.skills

            tampered = %{
              signed_card
              | description:
                  AshA2A.Protocol.ClientCardVerifyTest.flip_byte(signed_card.description),
                skills: [
                  %{
                    skill
                    | description:
                        AshA2A.Protocol.ClientCardVerifyTest.flip_byte(skill.description)
                  }
                  | rest
                ]
            }

            AshA2A.Protocol.JSON.encode_agent_card(tampered, url: tampered.url)

          :unsigned ->
            signed_card
            |> AshA2A.Protocol.JSON.encode_agent_card(url: signed_card.url)
            |> Map.drop(["signatures"])

          :signed ->
            AshA2A.Protocol.JSON.encode_agent_card(signed_card, url: signed_card.url)
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body_map))
    end

    match _ do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not_found"}))
    end
  end

  # Flips one byte (the case of the first ASCII letter) of a description
  # string — a minimal post-signing content mutation that still decodes.
  def flip_byte(<<first::utf8, rest::binary>>) do
    flipped =
      cond do
        first in ?a..?z -> first - 32
        first in ?A..?Z -> first + 32
        true -> first
      end

    <<flipped::utf8, rest::binary>>
  end

  setup do
    # NOTE (cross-lane finding): the v1.0 wire codec (`AshA2A.Protocol.JSON
    # .encode_agent_card/2` in lib/ash_a2a/protocol/json.ex) does not emit a
    # top-level `protocolVersion` member -- it lives only inside
    # `supportedInterfaces[].protocolVersion` -- so `decode_agent_card`
    # restores `protocol_version: nil` on the client. Signing the runtime
    # card with protocol_version "1.0" therefore produces a card whose
    # signature can never verify post-decode (digest_mismatch on exactly
    # that field). Until the codec preserves the member end to end, the
    # fixture signs the card in its wire-stable shape (protocol_version nil,
    # i.e. exactly the content the wire carries and the client decodes).
    card =
      @resource
      |> AshA2A.Info.agent_card(name: "card_verify_fixture_agent")
      |> then(&%{&1 | protocol_version: nil})
      |> CardSigning.sign(@key)

    assert [%{"protected" => _, "signature" => _}] = card.signatures

    start_supervised!(
      %{
        id: Store,
        start: {Agent, :start_link, [fn -> %Store{signed_card: card} end, [name: Store]]}
      },
      shutdown: 1_000
    )

    server = EphemeralHttp.start!(CardServer)

    %{card: card, server: server, url: server.base_url}
  end

  defp set_mode(mode) do
    Agent.update(Store, &%{&1 | mode: mode})
  end

  describe "discover/2 with verify_card_signature over REAL HTTP" do
    test "right key verifies the real signed card served over the wire", %{url: url} do
      assert {:ok, card} = Client.discover(url, verify_card_signature: @key)
      assert [%{"protected" => _, "signature" => _}] = card.signatures
      assert CardSigning.verify(card, @key) == :ok
    end

    test "wrong key is fail-closed {:error, {:card_signature, {:bad_signature, %{index: 0}}}}", %{
      url: url
    } do
      assert {:error, {:card_signature, {:bad_signature, %{index: 0}}}} =
               Client.discover(url, verify_card_signature: @wrong_key)
    end

    test "tampered body (description byte flipped post-signing) is {:error, {:card_signature, {:digest_mismatch, _}}}",
         %{
           url: url
         } do
      set_mode(:tampered)

      assert {:error, {:card_signature, {:digest_mismatch, %{index: 0}}}} =
               Client.discover(url, verify_card_signature: @key)
    end

    test "no opt returns {:ok, card} regardless — legacy behavior unchanged", %{url: url} do
      # Signed server: passes without verification.
      assert {:ok, card} = Client.discover(url)
      assert [%{"protected" => _, "signature" => _}] = card.signatures

      # Even a TAMPERED body is returned as-is when no verification was
      # requested (fail-open legacy contract preserved exactly).
      set_mode(:tampered)
      assert {:ok, _card} = Client.discover(url)
    end

    test "unsigned card with verification requested is fail-closed {:error, {:card_signature, {:malformed, :no_signatures}}}",
         %{
           url: url
         } do
      set_mode(:unsigned)

      assert {:error, {:card_signature, {:malformed, :no_signatures}}} =
               Client.discover(url, verify_card_signature: @key)
    end
  end

  describe "new/2 verify_card_signature default + client-targeted discover" do
    test "client configured with the right key verifies via Client.discover(client)", %{url: url} do
      client = Client.new(url, verify_card_signature: @key)
      assert {:ok, card} = Client.discover(client)
      assert CardSigning.verify(card, @key) == :ok

      # Per-call opt overrides the client default.
      assert {:error, {:card_signature, {:bad_signature, %{index: 0}}}} =
               Client.discover(client, verify_card_signature: @wrong_key)
    end

    test "client configured with the wrong key is fail-closed", %{url: url} do
      client = Client.new(url, verify_card_signature: @wrong_key)
      assert {:error, {:card_signature, {:bad_signature, %{index: 0}}}} = Client.discover(client)
    end

    test "client without the option keeps legacy behavior", %{url: url} do
      client = Client.new(url)
      assert {:ok, _card} = Client.discover(client)
    end

    test "new/2 does not leak the opt into Req options", %{url: url} do
      client = Client.new(url, verify_card_signature: @key)
      assert is_map(client.req.options)
      refute Map.has_key?(client.req.options, :verify_card_signature)
    end
  end
end


# --- SECTION 5: Original test/ash_a2a_client_http_json_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ClientHTTPJSONInteropTest.Resource do
  @moduledoc """
  Real fixture resource, private to this test file: a single real `:read`
  skill on a real ETS-backed Ash resource, so dispatch has exactly one skill
  and needs no `:skill` metadata.
  """

  use Ash.Resource,
    domain: AshA2A.ClientHTTPJSONInteropTest.Domain,
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

defmodule AshA2A.ClientHTTPJSONInteropTest.Domain do
  @moduledoc "Real fixture domain for the resource above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.ClientHTTPJSONInteropTest.Resource)
  end
end

defmodule AshA2A.ClientHTTPJSONInteropTest.EchoAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over the fixture resource above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.ClientHTTPJSONInteropTest.Resource,
    name: "client_http_json_echo_agent"
end

defmodule AshA2A.ClientHTTPJSONInteropTest.PushReceiver do
  @moduledoc false
  # Real webhook receiver: forwards (method, body) to the test pid and answers
  # 200. Its loopback URL is what the real `WebhookPolicy` admits.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test}) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:webhook, conn.method, body})
    send_resp(conn, 200, "")
  end
end

defmodule AshA2A.ClientHTTPJSONInteropTest.AuthPipeline do
  @moduledoc false
  # Real composite plug: a real `AshA2A.Protocol.Plug.Auth` (Bearer) in front
  # of the real `AshA2A.Transport.HTTPJSON` binding carrying an
  # `:extended_card` provider — the stack an operator deploys for the
  # authenticated extended card over the REST binding.
  @behaviour Plug

  @impl Plug
  def init(opts) when is_map(opts), do: opts

  def init(opts) do
    rest =
      AshA2A.Transport.HTTPJSON.init(
        agent: Keyword.fetch!(opts, :agent),
        base_url: "http://127.0.0.1/a2a",
        extended_card: Keyword.get(opts, :extended_card)
      )

    auth =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
        verify: Keyword.fetch!(opts, :verify)
      )

    %{auth: auth, rest: rest}
  end

  @impl Plug
  def call(conn, %{auth: auth, rest: rest}) do
    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.Transport.HTTPJSON.call(conn, rest)
    end)
  end
end

defmodule AshA2A.ClientHTTPJSONInteropTest do
  @moduledoc """
  REAL interop court for the `AshA2A.Protocol.Client` HTTP+JSON mode
  (`transport: :http_json`): a real Bandit server running the real
  `AshA2A.Transport.HTTPJSON` binding on a loopback ephemeral port, a real
  supervised `use AshA2A.Agent` GenServer over a real ETS Ash resource, and
  real `Req` calls driving discover/send/list/get/cancel, the
  push-notification-config CRUD and the authenticated extended card end to end
  through the client. Zero mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.A2ATransport.PushConfigStore
  alias AshA2A.ClientHTTPJSONInteropTest.AuthPipeline
  alias AshA2A.ClientHTTPJSONInteropTest.PushReceiver
  alias AshA2A.Protocol.{Client, PushNotificationConfig, Task}
  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}

  alias AshA2A.Transport.HTTPJSON, as: Binding

  @push_secret "client-httpjson-push-signing-secret"

  setup do
    agent = AshA2A.ClientHTTPJSONInteropTest.EchoAgent

    {_sup, _registry} =
      AgentSupervisorCase.start_supervised_agents!(__MODULE__, [agent])

    plug_opts =
      Binding.init(agent: agent, base_url: "http://127.0.0.1/fixture")

    server = EphemeralHttp.start!({Binding, plug_opts})

    %{server: server, client: Client.new(server.base_url, transport: :http_json)}
  end

  # -- fixtures --------------------------------------------------------------------

  # Real push stack: a real `AshA2A.A2ATransport` (whose PushConfigStore the
  # REST routes write through), a real loopback webhook receiver whose URL the
  # real `WebhookPolicy` admits, and a second real HTTPJSON binding instance
  # with push notifications enabled.
  defp start_push_stack! do
    agent = AshA2A.ClientHTTPJSONInteropTest.EchoAgent
    transport = :"a2a_transport_client_httpjson_#{System.unique_integer([:positive])}"

    start_supervised!(
      {AshA2A.A2ATransport,
       name: transport,
       push: [
         allow_http: true,
         allow_cidrs: ["127.0.0.1/32"],
         signing_secret: @push_secret,
         max_attempts: 3,
         base_backoff_ms: 10
       ]}
    )

    receiver = EphemeralHttp.start!({PushReceiver, %{test: self()}})

    server =
      EphemeralHttp.start!(
        {Binding,
         Binding.init(
           agent: agent,
           base_url: "http://127.0.0.1/fixture",
           transport: transport,
           push_notifications: true
         )}
      )

    %{
      transport: transport,
      hook: receiver.base_url <> "/hook",
      client: Client.new(server.base_url, transport: :http_json)
    }
  end

  # Extended-card provider (real public 2-arity function, the provider
  # contract) and real bearer verifier.
  def admin_card_provider(%{identity: %{sub: sub}}, card) do
    skill = %{"id" => "admin", "name" => "Admin", "description" => "for #{sub}", "tags" => []}
    {:ok, Map.update!(card, "skills", &(&1 ++ [skill]))}
  end

  defp verify(_scheme, "valid-token-42", _conn), do: {:ok, %{sub: "alice"}}

  # Real authed server: the Auth pipeline in front of the binding, with an
  # `:extended_card` provider when one is given (nil = none configured).
  defp start_authed_client!(provider) do
    opts =
      AuthPipeline.init(
        agent: AshA2A.ClientHTTPJSONInteropTest.EchoAgent,
        extended_card: provider,
        verify: &verify/3
      )

    server = EphemeralHttp.start!({AuthPipeline, opts})
    Client.new(server.base_url, transport: :http_json)
  end

  # -- discovery -----------------------------------------------------------------

  test "discover/2 fetches the real agent card (binding-independent)", %{server: server} do
    assert {:ok, card} = Client.discover(server.base_url)
    assert is_binary(card.name)
    assert is_binary(card.url)
    assert card.skills != []
  end

  # -- send_message: POST /message:send ------------------------------------------

  test "send_message/3 posts to /message:send and decodes the completed task", %{
    client: client
  } do
    assert {:ok, %Task{} = task} = Client.send_message(client, "go")
    assert "tsk-" <> _ = task.id
    assert task.status.state == :completed
    assert [%AshA2A.Protocol.Artifact{parts: [_]}] = task.artifacts
  end

  test "send_message/3 decodes a bare agent Message answer", %{client: client} do
    msg = AshA2A.Protocol.Message.new_user("hi")
    assert {:ok, _task_or_message} = Client.send_message(client, msg)
  end

  test "send_message/3 continuing a terminal task maps the 400 to :unsupported_operation", %{
    client: client
  } do
    {:ok, %Task{} = task} = Client.send_message(client, "first")

    assert {:error, :unsupported_operation} =
             Client.send_message(client, "second", task_id: task.id)
  end

  # -- get_task: GET /tasks/{id} ---------------------------------------------------

  test "get_task/3 reads the task back from /tasks/{id}", %{client: client} do
    {:ok, sent} = Client.send_message(client, "round trip")

    assert {:ok, %Task{} = fetched} = Client.get_task(client, sent.id)
    assert fetched.id == sent.id
    assert fetched.status.state == :completed
    assert fetched.context_id == sent.context_id
  end

  test "get_task/3 forwards :history_length as the historyLength query param", %{
    client: client
  } do
    {:ok, sent} = Client.send_message(client, "history")

    assert {:ok, truncated} = Client.get_task(client, sent.id, history_length: 0)
    assert truncated.history == []

    assert {:ok, with_history} = Client.get_task(client, sent.id)
    assert with_history.history != []
  end

  test "get_task/3 on an unknown task maps the 404 to :task_not_found", %{client: client} do
    assert {:error, :task_not_found} = Client.get_task(client, "tsk-does-not-exist")
  end

  # -- cancel_task: POST /tasks/{id}:cancel ----------------------------------------

  test "cancel_task/3 on an unknown task maps the 404 to :task_not_found", %{client: client} do
    assert {:error, :task_not_found} = Client.cancel_task(client, "tsk-nope")
  end

  test "cancel_task/3 on a terminal task maps the 409 to :task_not_cancelable", %{
    client: client
  } do
    {:ok, %Task{} = task} = Client.send_message(client, "cancel me")

    assert {:error, :task_not_cancelable} = Client.cancel_task(client, task.id)
  end

  # -- operations with no §5.3 REST route ------------------------------------------

  test "http_json stream_message/3 streams bare StreamResponse frames from POST /message:stream",
       %{
         client: client
       } do
    assert {:ok, stream} = Client.stream_message(client, "go")
    events = Enum.to_list(stream)

    assert events != []

    assert Enum.any?(events, &match?(%Task{}, &1)) or
             Enum.any?(events, &match?(%AshA2A.Protocol.Event.StatusUpdate{}, &1))
  end

  test "http_json resubscribe/3 on an unknown task maps the error body to :task_not_found", %{
    client: client
  } do
    assert {:error, :task_not_found} = Client.resubscribe(client, "tsk-x")
  end

  # jsonrpc-mode list_tasks/get_extended_card are exercised against a real
  # JSON-RPC server in test/client_gap_closures_test.exs.

  # -- list_tasks: GET /tasks -------------------------------------------------------

  # GET /tasks is owner-scoped (SEC-01): a listing only ever contains tasks the
  # VERIFIED caller owns (anonymous callers never list), so these tests run
  # through the real auth pipeline with a real bearer identity.
  @list_headers [{"authorization", "Bearer valid-token-42"}]

  test "list_tasks/2 lists the verified caller's tasks from GET /tasks and decodes the page envelope",
       %{
         client: _client
       } do
    client = start_authed_client!(nil)

    {:ok, %Task{} = a} = Client.send_message(client, "list one", headers: @list_headers)
    {:ok, %Task{} = b} = Client.send_message(client, "list two", headers: @list_headers)

    assert {:ok, page} = Client.list_tasks(client, headers: @list_headers)
    assert %Task{} = hd(page.tasks)
    ids = Enum.map(page.tasks, & &1.id)
    assert a.id in ids
    assert b.id in ids
    assert page.total_size >= 2
  end

  test "list_tasks/2 paginates via :page_size/:page_token and filters by :context_id", %{
    client: _client
  } do
    client = start_authed_client!(nil)
    headers = @list_headers

    {:ok, %Task{} = a} = Client.send_message(client, "page one", headers: headers)
    {:ok, _b} = Client.send_message(client, "page two", headers: headers)

    assert {:ok, page1} = Client.list_tasks(client, page_size: 1, headers: headers)
    assert length(page1.tasks) == 1
    assert page1.total_size >= 2
    assert is_binary(page1.next_page_token) and page1.next_page_token != ""

    assert {:ok, page2} =
             Client.list_tasks(client,
               page_size: 1,
               page_token: page1.next_page_token,
               headers: headers
             )

    assert [%Task{} = other] = page2.tasks
    refute other.id == hd(page1.tasks).id

    assert {:ok, filtered} = Client.list_tasks(client, context_id: a.context_id, headers: headers)
    assert Enum.all?(filtered.tasks, &(&1.context_id == a.context_id))
    assert a.id in Enum.map(filtered.tasks, & &1.id)
  end

  test "list_tasks/2 negative: a non-wire :status maps the 400 ErrorInfo to :invalid_params", %{
    client: client
  } do
    assert {:error, :invalid_params} = Client.list_tasks(client, status: "NOT_A_TASK_STATE")
  end

  # -- push-notification-config CRUD over the REST routes ----------------------------

  test "set_push_config/3 stores through the real PushConfigStore; webhook credentials are write-only",
       %{
         client: client
       } do
    {:ok, %Task{} = task} = Client.send_message(client, "push me")
    %{transport: transport, hook: hook, client: push_client} = start_push_stack!()

    config = %PushNotificationConfig{
      task_id: task.id,
      url: hook,
      token: "tok-gl-1",
      authentication: %{scheme: "Bearer", credentials: "s3cret-gl-1"}
    }

    assert {:ok, %PushNotificationConfig{} = stored} = Client.set_push_config(push_client, config)
    assert is_binary(stored.id) and stored.id != ""
    assert stored.url == hook
    assert stored.task_id == task.id
    assert stored.token == "tok-gl-1"

    # The echo never carries the webhook credentials...
    refute Map.has_key?(stored.authentication || %{}, :credentials)

    # ...but they really were stored in the real store.
    {:ok, in_store} =
      PushConfigStore.get(AshA2A.A2ATransport.push_store_name(transport), task.id, stored.id)

    # The client emits the v1 proto's singular `scheme` (proto fidelity court).
    assert in_store.authentication == %{
             "scheme" => "Bearer",
             "credentials" => "s3cret-gl-1"
           }
  end

  test "set_push_config/3 negative: an unknown task maps the 404 ErrorInfo to :task_not_found" do
    %{hook: hook, client: push_client} = start_push_stack!()

    config = %PushNotificationConfig{task_id: "tsk-does-not-exist", url: hook}

    assert {:error, :task_not_found} = Client.set_push_config(push_client, config)
  end

  test "set_push_config/3 negative: push disabled answers 400 -32003 -> :push_notification_not_supported",
       %{
         client: client
       } do
    {:ok, %Task{} = task} = Client.send_message(client, "no push here")

    config = %PushNotificationConfig{
      task_id: task.id,
      url: "https://example.com/webhook"
    }

    assert {:error, :push_notification_not_supported} = Client.set_push_config(client, config)
  end

  test "get_push_config/4 reads the config back from GET /tasks/{id}/pushNotificationConfig/{cid}",
       %{
         client: client
       } do
    {:ok, %Task{} = task} = Client.send_message(client, "get cfg")
    %{hook: hook, client: push_client} = start_push_stack!()

    config = %PushNotificationConfig{task_id: task.id, url: hook, token: "tok-gl-2"}
    {:ok, stored} = Client.set_push_config(push_client, config)

    assert {:ok, %PushNotificationConfig{} = fetched} =
             Client.get_push_config(push_client, task.id, stored.id)

    assert fetched.id == stored.id
    assert fetched.task_id == task.id
    assert fetched.url == hook
    assert fetched.token == "tok-gl-2"
  end

  test "get_push_config/4 negative: a missing config maps the 400 ErrorInfo to :invalid_params",
       %{
         client: client
       } do
    {:ok, %Task{} = task} = Client.send_message(client, "missing cfg")
    %{client: push_client} = start_push_stack!()

    assert {:error, :invalid_params} =
             Client.get_push_config(push_client, task.id, "cfg-never-registered")
  end

  test "list_push_configs/3 lists the task's configs from GET /tasks/{id}/pushNotificationConfig",
       %{
         client: client
       } do
    {:ok, %Task{} = task} = Client.send_message(client, "list cfgs")
    %{hook: hook, client: push_client} = start_push_stack!()

    config = %PushNotificationConfig{task_id: task.id, url: hook, token: "tok-gl-3"}
    {:ok, stored} = Client.set_push_config(push_client, config)

    assert {:ok, [%PushNotificationConfig{} = only]} =
             Client.list_push_configs(push_client, task.id)

    assert only.id == stored.id
    assert only.url == hook
  end

  test "list_push_configs/3 negative: an unknown task maps the 404 ErrorInfo to :task_not_found" do
    %{client: push_client} = start_push_stack!()

    assert {:error, :task_not_found} = Client.list_push_configs(push_client, "tsk-does-not-exist")
  end

  test "delete_push_config/4 deletes via DELETE /tasks/{id}/pushNotificationConfig/{cid}", %{
    client: client
  } do
    {:ok, %Task{} = task} = Client.send_message(client, "delete cfg")
    %{hook: hook, client: push_client} = start_push_stack!()

    config = %PushNotificationConfig{task_id: task.id, url: hook}

    {:ok, stored} = Client.set_push_config(push_client, config)

    assert :ok = Client.delete_push_config(push_client, task.id, stored.id)
    assert {:ok, []} = Client.list_push_configs(push_client, task.id)

    # Idempotent per TCK PUSH-DEL-002 (fb2e844d): re-deleting an already-deleted
    # config answers success, never an error — a delete outcome, not addressing.
    assert :ok = Client.delete_push_config(push_client, task.id, stored.id)
  end

  test "delete_push_config/4 negative: an unknown task maps the 404 ErrorInfo to :task_not_found" do
    %{client: push_client} = start_push_stack!()

    assert {:error, :task_not_found} =
             Client.delete_push_config(push_client, "tsk-does-not-exist", "cfg-1")
  end

  # -- get_extended_card: POST /agent -------------------------------------------------

  test "get_extended_card/2 POSTs /agent with auth and decodes the provider-extended card", %{
    client: _client
  } do
    ext_client = start_authed_client!(&__MODULE__.admin_card_provider/2)

    assert {:ok, card} =
             Client.get_extended_card(ext_client,
               headers: [{"authorization", "Bearer valid-token-42"}]
             )

    admin = Enum.find(card.skills, &(&1.id == "admin"))
    assert admin.description == "for alice"

    # The public card from the same server never carries the admin skill: the
    # extension exists only per verified call.
    {:ok, public} = Client.discover(ext_client)
    refute "admin" in Enum.map(public.skills, & &1.id)
  end

  test "get_extended_card/2 negative: no credentials maps the 401 to {:unauthorized, challenge}",
       %{
         client: _client
       } do
    ext_client = start_authed_client!(&__MODULE__.admin_card_provider/2)

    assert {:error, {:unauthorized, challenge}} = Client.get_extended_card(ext_client)
    assert is_list(challenge)
  end

  test "get_extended_card/2 negative: no provider maps the 400 ErrorInfo to :extended_card_not_configured",
       %{
         client: _client
       } do
    ext_client = start_authed_client!(nil)

    assert {:error, :extended_card_not_configured} =
             Client.get_extended_card(ext_client,
               headers: [{"authorization", "Bearer valid-token-42"}]
             )
  end

  # -- client construction ---------------------------------------------------------

  test "new/2 rejects an unknown transport", %{server: server} do
    assert_raise ArgumentError, ~r/invalid :transport/, fn ->
      Client.new(server.base_url, transport: :carrier_pigeon)
    end
  end

  test "default transport stays :jsonrpc", %{server: server} do
    assert %Client{transport: :jsonrpc} = Client.new(server.base_url)
  end
end


# --- SECTION 6: Original test/ash_a2a_command_bus_concurrency_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ACommandBusConcurrencyTest do
  @moduledoc """
  Squad H (replay/concurrency stress, agent 38) -- real BEAM concurrency
  coverage for `AshA2A.CommandBus.run/4` racing `AshA2A.ReceiptStore.Memory`.

  `AshA2A.ReceiptStore.Memory` is a real `GenServer`; its real serialized
  `handle_call({:claim, command}, ...)` is the only thing standing between
  N concurrent callers and N real duplicate `Ash.create` executions. This
  file does not assume that mutual exclusion holds from reading the source --
  it spawns real concurrent Elixir processes (`Task.async_stream/3`, real
  BEAM scheduler concurrency, `max_concurrency` pinned to the full fan-out so
  every caller is genuinely in flight at once, not batched into scheduler-
  sized chunks) and proves it against the real `AshA2A.Test.Fixture.Item`
  Ash resource (`Ash.DataLayer.Ets`, a real data layer, not a fake).

  ## A real finding this file's assertions are built around

  `AshA2A.ReceiptStore.Memory.handle_call/3`'s `{:claim, command}` clause has
  three live outcomes for a matching fingerprint, not two:

    - `entry.receipt == nil`             -> `{:error, :in_flight}`
    - `entry.receipt == %Receipt{}`      -> `{:replay, receipt}`
    - no entry yet                       -> `{:execute, execution_id}`

  A genuinely concurrent racer that reaches the GenServer's mailbox *before*
  the executing caller's real `Ash.create` dispatch finishes and calls
  `commit/2` lands in the first bucket (`:in_flight`), not the second
  (`:replay`) -- `Ash.create`'s real changeset/validation/data-layer pipeline
  takes real, non-zero wall-clock time, so under true simultaneous load most
  or all racers are observed here to land `:in_flight`, with `:replay` shown
  for real by a caller that arrives strictly after the race has settled. The
  literal invariant this file proves for the genuinely concurrent case is
  therefore the stronger, more general one that is actually true under real
  load: exactly one real execution, and every other concurrent caller gets
  either a faithful replay of that exact receipt or a clean, typed
  `:in_flight` refusal -- never a second execution, never a divergent
  receipt, never an untyped crash.

  No `Mox`/`:meck`/`Mock(`/`monkeypatch` anywhere in this file: real
  `Task.async_stream/3` processes, a real supervised `GenServer`, a real Ash
  resource and data layer throughout.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Test.Fixture.Item

  @concurrency 30

  # `Ash.DataLayer.Ets.TableManager.start/3` (deps/ash) registers the manager's
  # name before its `init/1` has created the public ETS table. When the
  # VM's *first* `Item` write is two different command_ids racing (the second
  # test below, whenever the seed orders it before any other `Item` create),
  # the loser sees `{:already_started, pid}`, calls `wrap_existing/1` before
  # the table exists, and its real `Ash.create` returns `:table_not_found` --
  # a `:failed` executor receipt that has nothing to do with the command bus
  # (reproduced on main 82237eb with `--seed 603047`, 6/6 runs). One real,
  # serialized create before any race makes the table exist; the assertions
  # below count rows by test-unique label, so this warm-up row is invisible
  # to them.
  setup_all do
    {:ok, _warmup} =
      Item
      |> Ash.Changeset.for_create(:create, %{
        label: "concurrency-warmup-#{System.unique_integer([:positive])}"
      })
      |> Ash.create(domain: AshA2A.Test.Fixture.ItemDomain)

    :ok
  end

  setup do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  # `AshA2A.Test.Fixture.Item` is backed by a single, process-global
  # `Ash.DataLayer.Ets` table that is NOT reset between tests -- every other
  # test file in the full suite that exercises `Item` (and this file's own
  # two tests, run in the same process) writes into the SAME table. A bare
  # "how many rows exist total" count would therefore silently pick up
  # unrelated rows left behind by earlier tests. Every assertion in this
  # file instead counts real rows matching a `label` unique to the specific
  # command under test (`System.unique_integer/1`-suffixed below), the same
  # real-collaborator-safe pattern `ash_a2a_agent_command_bus_test.exs`
  # already uses (`Enum.count(all_items, &(&1.id == created1.id))`) rather
  # than a raw table count.
  defp count_items_with_label(label) do
    assert {:ok, items} = Ash.read(Item, domain: AshA2A.Test.Fixture.ItemDomain)
    Enum.count(items, &(&1.label == label))
  end

  test "N real concurrent processes racing the identical command_id: exactly one real Ash create executes, never two",
       %{store_opts: store_opts} do
    capability = "AshA2A.Test.Fixture.Item.create"
    principal = Identity.principal("racer-single-#{System.unique_integer([:positive])}")
    authority = Authority.new(principal, capability, token_id: "auth-race-single")
    label = "race-widget-#{System.unique_integer([:positive])}"

    # One real `Command` struct, shared by reference across every concurrent
    # task -- guarantees byte-identical semantic content (and therefore an
    # identical `fingerprint`) without reconstructing it per process, which
    # is the real thing "identical capability_id/agent_id/principal_id/
    # input/authority" means here.
    command =
      Command.new(capability,
        command_id: "race-single-#{System.unique_integer([:positive])}",
        agent_id: "agent-race-single",
        principal_id: principal,
        authority: authority,
        input: %{label: label}
      )

    message = data_message(%{"label" => label})

    results =
      1..@concurrency
      |> Task.async_stream(
        fn _ -> CommandBus.run(command, message, Item, store_opts: store_opts) end,
        max_concurrency: @concurrency,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(results) == @concurrency

    executed = Enum.filter(results, &match?({:ok, %{replayed?: false}}, &1))
    replayed = Enum.filter(results, &match?({:ok, %{replayed?: true}}, &1))
    refused = Enum.filter(results, &match?({:error, _}, &1))

    # The core invariant: not a race that lets two concurrent callers both
    # execute. Exactly one real `Ash.create` happened.
    assert length(executed) == 1
    [{:ok, executor_receipt}] = executed
    assert executor_receipt.status == :completed
    assert executor_receipt.consequence == :change
    refute executor_receipt.replayed?

    # Every caller that did NOT execute landed in one of exactly two clean,
    # accounted-for outcomes -- a faithful replay of the SAME receipt, or a
    # typed in-flight refusal -- never a divergent receipt and never any
    # other error code (in particular never `:command_conflict`, which would
    # mean the store mistook identical content for a fingerprint mismatch).
    for {:ok, replay_receipt} <- replayed do
      assert replay_receipt.replayed?
      assert replay_receipt.receipt_id == executor_receipt.receipt_id
      assert replay_receipt.fingerprint == executor_receipt.fingerprint
      assert replay_receipt.status == :completed
    end

    for {:error, reason} <- refused do
      assert reason.code == :in_flight
    end

    assert length(executed) + length(replayed) + length(refused) == @concurrency

    # Real data-layer proof, independent of the receipts returned: exactly
    # one real `Item` row with this test's unique label exists, not
    # `@concurrency` of them.
    assert count_items_with_label(label) == 1

    # Proves the replay path is real and not merely an artifact of timing:
    # a caller arriving strictly after the race has fully settled (all
    # `@concurrency` tasks awaited) must observe a real replay of the exact
    # same receipt, and must not create a second record.
    assert {:ok, post_race_receipt} =
             CommandBus.run(command, message, Item, store_opts: store_opts)

    assert post_race_receipt.replayed?
    assert post_race_receipt.receipt_id == executor_receipt.receipt_id
    assert count_items_with_label(label) == 1
  end

  test "two different command_ids racing concurrently execute independently with zero cross-contamination",
       %{store_opts: store_opts} do
    capability = "AshA2A.Test.Fixture.Item.create"
    principal = Identity.principal("racer-multi-#{System.unique_integer([:positive])}")

    authority_a = Authority.new(principal, capability, token_id: "auth-race-a")
    authority_b = Authority.new(principal, capability, token_id: "auth-race-b")
    label_a = "widget-a-#{System.unique_integer([:positive])}"
    label_b = "widget-b-#{System.unique_integer([:positive])}"

    command_a =
      Command.new(capability,
        command_id: "race-a-#{System.unique_integer([:positive])}",
        agent_id: "agent-race-a",
        principal_id: principal,
        authority: authority_a,
        input: %{label: label_a}
      )

    command_b =
      Command.new(capability,
        command_id: "race-b-#{System.unique_integer([:positive])}",
        agent_id: "agent-race-b",
        principal_id: principal,
        authority: authority_b,
        input: %{label: label_b}
      )

    message_a = data_message(%{"label" => label_a})
    message_b = data_message(%{"label" => label_b})

    half = div(@concurrency, 2)

    # Interleave (shuffle) the two command's tasks so real scheduling does
    # not happen to group all of A's callers before all of B's -- both
    # command_ids are genuinely racing each other concurrently, not merely
    # running two separate serial batches back to back.
    tasks =
      (List.duplicate({:a, command_a, message_a}, half) ++
         List.duplicate({:b, command_b, message_b}, half))
      |> Enum.shuffle()

    results =
      tasks
      |> Task.async_stream(
        fn {tag, command, message} ->
          {tag, CommandBus.run(command, message, Item, store_opts: store_opts)}
        end,
        max_concurrency: length(tasks),
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    results_a = for {:a, result} <- results, do: result
    results_b = for {:b, result} <- results, do: result

    assert length(results_a) == half
    assert length(results_b) == half

    executor_a = assert_single_real_execution!(results_a)
    executor_b = assert_single_real_execution!(results_b)

    # No cross-contamination: the two command_ids produced two genuinely
    # distinct receipts/executions, correctly keyed to their own command.
    refute executor_a.receipt_id == executor_b.receipt_id
    assert executor_a.command_id == command_a.command_id
    assert executor_b.command_id == command_b.command_id

    for {:ok, receipt} <- results_a, receipt.replayed? do
      assert receipt.receipt_id == executor_a.receipt_id
      assert receipt.command_id == command_a.command_id
      refute receipt.receipt_id == executor_b.receipt_id
    end

    for {:ok, receipt} <- results_b, receipt.replayed? do
      assert receipt.receipt_id == executor_b.receipt_id
      assert receipt.command_id == command_b.command_id
      refute receipt.receipt_id == executor_a.receipt_id
    end

    # Two independent real records -- one per distinct command_id, each
    # identified by its own test-unique label -- proven against the real
    # Ets data layer, not inferred from receipts alone.
    assert count_items_with_label(label_a) == 1
    assert count_items_with_label(label_b) == 1

    assert {:ok, replay_a} = CommandBus.run(command_a, message_a, Item, store_opts: store_opts)
    assert replay_a.replayed?
    assert replay_a.receipt_id == executor_a.receipt_id

    assert {:ok, replay_b} = CommandBus.run(command_b, message_b, Item, store_opts: store_opts)
    assert replay_b.replayed?
    assert replay_b.receipt_id == executor_b.receipt_id

    assert count_items_with_label(label_a) == 1
    assert count_items_with_label(label_b) == 1
  end

  # Same per-command invariant as the single-command_id test above, reused
  # for each of the two racing command_ids: exactly one real execution,
  # every other real outcome a faithful replay or a clean `:in_flight`
  # refusal, nothing else. Returns the real executor receipt.
  defp assert_single_real_execution!(results) do
    executed = Enum.filter(results, &match?({:ok, %{replayed?: false}}, &1))
    replayed = Enum.filter(results, &match?({:ok, %{replayed?: true}}, &1))
    refused = Enum.filter(results, &match?({:error, _}, &1))

    assert length(executed) == 1
    [{:ok, executor_receipt}] = executed
    assert executor_receipt.status == :completed
    assert executor_receipt.consequence == :change

    for {:ok, replay_receipt} <- replayed do
      assert replay_receipt.receipt_id == executor_receipt.receipt_id
    end

    for {:error, reason} <- refused do
      assert reason.code == :in_flight
    end

    assert length(executed) + length(replayed) + length(refused) == length(results)

    executor_receipt
  end
end


# --- SECTION 7: Original test/ash_a2a_command_bus_crash_window_chicago_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CommandBusCrashWindowChicagoTest do
  @moduledoc """
  Chicago-school falsifier for the remaining A2A-2601 crash window.

  A separate OS BEAM performs one real HTTP consequence and is killed after
  the receiver acknowledges it but before CommandBus can finalize the pending
  receipt. This BEAM then reconciles the persisted anchor into a fresh primary
  store and proves replay cannot perform the external consequence a second
  time.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{CommandBus, Receipt, ReceiptOutbox, ReceiptStore}
  alias AshA2A.Test.Fixture.ReceiptCrashWindow.{ExternalDo, Runner}

  defmodule Receiver do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/do" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"operation_id" => operation_id} = Jason.decode!(body)

      Agent.update(Receiver.Store, fn operation_ids ->
        [operation_id | operation_ids]
      end)

      Plug.Conn.send_resp(conn, 204, "")
    end

    match(_) do
      Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  setup do
    {:ok, _agent} = Agent.start_link(fn -> [] end, name: Receiver.Store)

    %{port: port} = AshA2A.Test.EphemeralHttp.start!(Receiver)

    outbox_dir =
      Path.join(
        System.tmp_dir!(),
        "ash-a2a-crash-window-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox_dir)

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_outbox_dir)
      File.rm_rf!(outbox_dir)
    end)

    {:ok,
     url: "http://127.0.0.1:#{port}",
     outbox_dir: outbox_dir,
     command_id: "receipt-crash-window-#{System.unique_integer([:positive])}"}
  end

  test "acknowledged external DO survives runner death as pending evidence and replay cannot DO twice",
       %{url: url, outbox_dir: outbox_dir, command_id: command_id} do
    expression =
      "AshA2A.Test.Fixture.ReceiptCrashWindow.Runner.run!(" <>
        "#{inspect(url)}, #{inspect(outbox_dir)}, #{inspect(command_id)})"

    {_output, exit_code} =
      System.cmd("mix", ["run", "-e", expression],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    refute exit_code == 0
    assert Agent.get(Receiver.Store, &Enum.reverse/1) == [command_id]

    assert [
             %Receipt{
               status: :pending,
               consequence: :external_do,
               command_id: anchor_command_id
             } = anchor
           ] = ReceiptOutbox.entries()

    assert anchor_command_id == Runner.command(url, command_id).command_id

    store_name =
      Module.concat(__MODULE__, "RestartedStore#{System.unique_integer([:positive])}")

    {:ok, _pid} = GenServer.start(ReceiptStore.Memory, %{}, name: store_name)
    store_opts = [name: store_name]

    assert {:ok, %{committed: 1, remaining: 0}} =
             CommandBus.reconcile_outboxed_receipts(ReceiptStore.Memory, store_opts)

    assert ReceiptOutbox.count() == 0
    assert {:ok, stored} = ReceiptStore.Memory.fetch(anchor.command_id, store_opts)
    assert stored.receipt_id == anchor.receipt_id
    assert stored.status == :pending

    assert {:ok, replayed} =
             CommandBus.run(
               Runner.command(url, command_id),
               Runner.message(url, command_id),
               ExternalDo,
               store: ReceiptStore.Memory,
               store_opts: store_opts
             )

    assert replayed.replayed? == true
    assert replayed.status == :pending
    assert replayed.receipt_id == anchor.receipt_id

    assert Agent.get(Receiver.Store, &Enum.reverse/1) == [command_id]
  end
end


# --- SECTION 8: Original test/ash_a2a_command_bus_duplicate_action_names_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# b4p-f5-10 (wave finding, beam4pm capability sweep 2026-09-18): on a
# multi-resource domain -- the DEFAULT surface since every public Ash action
# is exposed as a skill -- same-named `:change` skills (e.g. `create` on 597
# resources) resolved the CommandBus re-dispatch by bare display `skill.name`,
# so `Dispatcher.fetch_skill/2` index-first-matched a DIFFERENT resource's
# namesake and `AshA2A.BrceAnchor.admit/2` refused the exact-skill anchor with
# `:capability_mismatch`. Fail-safe (typed refusal, nothing mis-admitted), but
# the entire `:change` half of the card beyond the index-first namesake was
# inoperable. This file pins the law: the addressed capability actuates, an
# ambiguous bare display name refuses typed, an unambiguous display name keeps
# resolving.






# --- SECTION 9: Original test/ash_a2a_command_bus_outbox_chicago_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT



# --- SECTION 10: Original test/ash_a2a_command_fingerprint_determinism_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CommandFingerprintDeterminismTest do
  @moduledoc """
  Regression coverage for `AshA2A.Command.fingerprint/1`'s cross-node/replay
  stability (RFC-SA2A-002 §41, CHI-REPLAY-001).

  `Command.fingerprint/1` hashes via
  `:erlang.term_to_binary(term, [:deterministic])`. Per the Erlang/OTP
  `:erlang.term_to_binary/2` documentation, the plain (no-option) encoding
  gives *no* guarantee that the same term encodes to the same bytes across
  separate runtime-system instances -- only `[:deterministic]` gives that
  guarantee (within one OTP major release). `ReceiptStore.claim/2` keys its
  replay/conflict decision on `Command.fingerprint/1`, so a caller that
  reconstructs the identical semantic command with its atom-keyed `input`
  map built via a different code path -- a different node in a multi-node
  deployment, a different decode path, a fresh replay process -- must still
  fingerprint identically, or a legitimate retry could be spuriously refused
  as a `:command_conflict`, or a real conflict could be masked.

  This mirrors the existing `AshA2A.Actuation.digest/1` doctest pattern
  (`lib/ash_a2a/actuation.ex:58-73`) and the fix already applied there,
  at `AshA2A.Authority`'s and `AshA2A.Receipt.Binding`'s digests, and at
  `AshA2A.Semantic.MetaAdmission`/`HookReactor.Hook`/`HookReactor.Intent` --
  applied here to `Command.fingerprint/1`, the single most load-bearing
  stable-command-identity hash in the system.

  Real collaborators throughout: real `AshA2A.Command` structs, real
  `Command.fingerprint/1` calls, state-based equality assertions on the
  real returned hash strings. No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Command

  @capability "AshA2A.Test.Fixture.CountingActuator.actuate"

  defp base_opts(input) do
    [
      command_id: "cmd-#{System.unique_integer([:positive])}",
      agent_id: "s41-agent",
      principal_id: "s41-principal",
      input: input,
      submitted_at: ~U[2026-01-01 00:00:00Z]
    ]
  end

  test "fingerprint is identical for atom-keyed input maps built in different key-insertion order" do
    forward =
      Map.new(a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7)

    reversed =
      Enum.reduce([{:g, 7}, {:f, 6}, {:e, 5}, {:d, 4}, {:c, 3}, {:b, 2}, {:a, 1}], %{}, fn {k, v},
                                                                                           acc ->
        Map.put(acc, k, v)
      end)

    assert forward == reversed

    command_forward = Command.new(@capability, base_opts(forward))
    command_reversed = Command.new(@capability, base_opts(reversed))

    assert Command.fingerprint(command_forward) == Command.fingerprint(command_reversed)
  end

  test "fingerprint is identical across a small-map/large-map representation boundary" do
    keys = for i <- 1..40, do: String.to_atom("k#{i}")
    pairs = Enum.map(keys, fn k -> {k, Atom.to_string(k)} end)

    # Built directly as a 40-entry map (large/HAMT-representation path).
    direct = Map.new(pairs)

    # Built by growing past the flatmap/HAMT threshold with an extra key,
    # then deleting it back down -- a value-equal map that may carry a
    # different internal representation depending on runtime/version.
    grown = pairs |> Kernel.++([{:k_extra, "extra"}]) |> Map.new() |> Map.delete(:k_extra)

    assert direct == grown

    command_direct = Command.new(@capability, base_opts(direct))
    command_grown = Command.new(@capability, base_opts(grown))

    assert Command.fingerprint(command_direct) == Command.fingerprint(command_grown)
  end

  test "fingerprint is a stable, reproducible lowercase-hex sha256 digest for the same command" do
    command = Command.new(@capability, base_opts(%{effect_key: "e-1"}))

    assert Command.fingerprint(command) == Command.fingerprint(command)
    assert String.length(Command.fingerprint(command)) == 64
    assert Command.fingerprint(command) =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "the implementation encodes with the :deterministic option, matching Command.fingerprint/1's own contract" do
    command = Command.new(@capability, base_opts(%{effect_key: "e-2"}))

    expected =
      {
        AshA2A.Identity.external(command.agent_id),
        AshA2A.Identity.external(command.principal_id),
        command.task_id && AshA2A.Identity.external(command.task_id),
        command.capability_id,
        command.input,
        nil,
        AshA2A.SemanticSubject.fingerprint_token(command.semantic_subject),
        AshA2A.SpgIdentity.fingerprint_token(command.spg_identity),
        nil
      }
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert Command.fingerprint(command) == expected
  end

  test "canonical candidate_digest aliases the legacy GALL-029 spelling without replay drift" do
    opts = base_opts(%{effect_key: "e-candidate"})

    canonical =
      Command.new(
        @capability,
        Keyword.put(opts, :metadata, %{candidate_digest: "sha256:candidate"})
      )

    legacy =
      Command.new(
        @capability,
        Keyword.put(opts, :metadata, %{gall_029_candidate_digest: "sha256:candidate"})
      )

    assert Command.candidate_digest(canonical) == "sha256:candidate"
    assert Command.candidate_digest(legacy) == "sha256:candidate"
    assert Command.fingerprint(canonical) == Command.fingerprint(legacy)
  end

  test "work-order binding is semantic identity and provider metadata is not" do
    opts = base_opts(%{effect_key: "e-work-order"})

    left =
      Command.new(
        @capability,
        Keyword.put(opts, :metadata, %{
          candidate_digest: "sha256:candidate",
          work_order_digest: "sha256:work-a",
          provider: "provider-a",
          transport: "wss"
        })
      )

    provider_changed =
      Command.new(
        @capability,
        Keyword.put(opts, :metadata, %{
          candidate_digest: "sha256:candidate",
          work_order_digest: "sha256:work-a",
          provider: "provider-b",
          transport: "http"
        })
      )

    work_changed =
      Command.new(
        @capability,
        Keyword.put(opts, :metadata, %{
          candidate_digest: "sha256:candidate",
          work_order_digest: "sha256:work-b",
          provider: "provider-a",
          transport: "wss"
        })
      )

    assert Command.work_order_digest(left) == "sha256:work-a"
    assert Command.fingerprint(left) == Command.fingerprint(provider_changed)
    refute Command.fingerprint(left) == Command.fingerprint(work_changed)
  end

  test "a different effect (different capability_id) is NOT deduplicated by the fingerprint" do
    command_a = Command.new(@capability, base_opts(%{effect_key: "e-3"}))

    command_b =
      Command.new("AshA2A.Test.Fixture.CountingActuator.other", base_opts(%{effect_key: "e-3"}))

    refute Command.fingerprint(command_a) == Command.fingerprint(command_b)
  end
end


# --- SECTION 11: Original test/ash_a2a_commitment_telemetry_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ACommitmentTelemetryTest do
  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Test.Fixture.{Echo, Item}

  setup do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})

    handler_id = {:conditional_commitment, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ash_a2a, :command_bus, :commitment],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:commitment, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{store_opts: [name: name]}
  end

  test "consequential command emits authorized then prepared standing before DO", %{
    store_opts: store_opts
  } do
    principal = Identity.principal("commitment-telemetry-user")
    capability = "AshA2A.Test.Fixture.Item.create"
    authority = Authority.new(principal, capability, token_id: "commitment-telemetry-grant")

    command =
      Command.new(capability,
        command_id: "commitment-telemetry-command",
        agent_id: "commitment-telemetry-agent",
        principal_id: principal,
        authority: authority,
        input: %{label: "commitment-telemetry"}
      )

    assert {:ok, receipt} =
             CommandBus.run(
               command,
               data_message(%{"label" => "commitment-telemetry"}),
               Item,
               store_opts: store_opts
             )

    assert receipt.status == :completed
    assert receipt.consequence == :change

    assert_receive {:commitment, admitted}, 1_000
    assert admitted.transition == :admission
    assert admitted.consequence == :change
    assert admitted.commitment_standing == :authorized
    assert admitted.commitment_authorized
    refute admitted.commitment_prepared
    refute admitted.commitment_ready_for_do
    assert is_binary(admitted.commitment_digest)
    assert admitted.prepared_receipt_id == nil

    assert_receive {:commitment, prepared}, 1_000
    assert prepared.transition == :prepare
    assert prepared.consequence == :change
    assert prepared.commitment_standing == :prepared
    assert prepared.commitment_authorized
    assert prepared.commitment_prepared
    assert prepared.commitment_ready_for_do
    assert is_binary(prepared.prepared_receipt_id)
    refute prepared.commitment_digest == admitted.commitment_digest
  end

  test "observe commands do not emit consequential commitment standing", %{
    store_opts: store_opts
  } do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "commitment-observe-command",
        agent_id: "commitment-observe-agent",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

    assert receipt.consequence == :observe
    refute_receive {:commitment, _metadata}, 50
  end
end


# --- SECTION 12: Original test/ash_a2a_conditional_commitment_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AConditionalCommitmentTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Command, ConditionalCommitment, Identity, Receipt}

  defp command(opts \\ []) do
    capability = "AshA2A.Test.Fixture.Item.create"
    principal = Identity.principal("conditional-user")

    authority =
      if Keyword.get(opts, :authorized, false) do
        Authority.new(principal, capability, token_id: "conditional-grant")
      end

    Command.new(capability,
      command_id: Keyword.get(opts, :command_id, "conditional-command"),
      agent_id: "conditional-agent",
      principal_id: principal,
      authority: authority,
      input: %{label: "conditional"}
    )
  end

  defp pending_receipt(command) do
    Receipt.pending(
      command,
      Identity.execution("conditional-execution"),
      :change
    )
  end

  test "proposal is not authority and cannot cross DO boundary" do
    decision = command() |> ConditionalCommitment.classify()

    assert decision.standing == :proposed
    refute decision.authorized?
    refute decision.prepared?
    refute decision.ready_for_do?
  end

  test "authority alone is not a prepared consequence" do
    decision = command(authorized: true) |> ConditionalCommitment.classify()

    assert decision.standing == :authorized
    assert decision.authorized?
    refute decision.prepared?
    refute decision.ready_for_do?
  end

  test "matching authority plus exact pending receipt is prepared for BRCE" do
    command = command(authorized: true)
    receipt = pending_receipt(command)

    decision = ConditionalCommitment.classify(command, receipt)

    assert decision.standing == :prepared
    assert decision.authorized?
    assert decision.prepared?
    assert decision.ready_for_do?
    assert ConditionalCommitment.ready_for_do?(command, receipt)
  end

  test "prepared receipt never manufactures missing authority" do
    command = command()
    receipt = pending_receipt(command)

    decision = ConditionalCommitment.classify(command, receipt)

    assert decision.standing == :refused
    assert decision.refusal_code == :authority_required
    refute decision.ready_for_do?
  end

  test "receipt for another command is a typed refusal" do
    command = command(authorized: true)
    other = command(authorized: true, command_id: "other-command")
    receipt = pending_receipt(other)

    decision = ConditionalCommitment.classify(command, receipt)

    assert decision.standing == :refused
    assert decision.refusal_code == :command_id_mismatch
    refute decision.ready_for_do?
  end

  test "commitment digest is deterministic and changes at preparation" do
    command = command(authorized: true)
    receipt = pending_receipt(command)

    authorized_digest = ConditionalCommitment.digest(command)
    prepared_digest = ConditionalCommitment.digest(command, receipt)

    assert authorized_digest == ConditionalCommitment.digest(command)
    assert prepared_digest == ConditionalCommitment.digest(command, receipt)
    refute authorized_digest == prepared_digest
    assert String.length(authorized_digest) == 64
    assert String.length(prepared_digest) == 64
  end

  test "metadata is bounded and exposes no raw command input or authority evidence" do
    command = command(authorized: true)
    receipt = pending_receipt(command)

    metadata = ConditionalCommitment.metadata(command, receipt)

    assert metadata.commitment_standing == :prepared
    assert metadata.commitment_authorized
    assert metadata.commitment_prepared
    assert metadata.commitment_ready_for_do
    assert is_binary(metadata.commitment_digest)
    assert is_binary(metadata.prepared_receipt_id)
    refute Map.has_key?(metadata, :input)
    refute Map.has_key?(metadata, :authority)
  end
end


# --- SECTION 13: Original test/ash_a2a_dispatcher_error_class_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ADispatcherErrorClassTest do
  @moduledoc """
  Assignment #9: real dispatcher error-class -> wire-message-text mapping.

  `AshA2A.Dispatcher.to_reply/1` has distinct clauses for Ash's
  `:forbidden`/`:framework`/`:unknown`/`:invalid` (non-tenant) error
  classes, each producing a class-prefixed message string via
  `class_message/2` (`lib/ash_a2a/dispatcher.ex:564-582`). The ORIGINAL
  framing of this assignment ("verify the real resulting JSON-RPC error
  response uses the correct real error code") does not correspond to
  anything ash_a2a actually does: `AshA2A.Protocol.Agent.Runtime.handle_reply/2`
  (`~/xaas/deps/a2a/lib/a2a/agent/runtime.ex:96-99`) never produces a
  top-level JSON-RPC error from a dispatch failure -- it always builds a
  real `TASK_STATE_FAILED` task with `Message.new_agent("Error:
  \#{inspect(reason)}")`, confirmed empirically via
  `test/ash_a2a_plug_tenant_actor_test.exs`. There is no real JSON-RPC
  error-CODE distinction per dispatcher error class today; only a real,
  distinct class-prefixed TEXT message inside a real failed task. This test
  verifies the real behavior instead of the incorrect original premise.

  `:invalid_config` (the `TenantRequired`/`NoPrimaryAction` carve-out) is
  already covered by `test/ash_a2a_dispatcher_tenant_test.exs` -- not
  duplicated here. `:forbidden` had zero coverage anywhere in this suite;
  this test closes that gap via a real `Ash.Policy.Authorizer` denial (not
  a hand-constructed error term). `:framework` and `:unknown` are Splode
  error classes reserved for genuine internal/unexpected faults
  (`Ash.Error.Framework`/`Ash.Error.Unknown`) -- there is no real,
  legitimate Ash usage pattern that raises either from a correctly
  configured resource; fabricating one would mean hand-constructing the
  exact error struct this test is supposed to prove arises from real
  usage, which is the fabrication this session's own discipline forbids.
  Left honestly untested for that reason, not silently skipped: see the
  moduledoc note on `class_message/2`'s catch-all coverage below.

  Chicago-style: a real `Ash.Policy.Authorizer`-guarded resource, a real
  `AshA2A.Dispatcher.dispatch/3` call, real state-based assertions on the
  real returned error tuple. No Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.ErrorClassProbe

  test "a real Ash.Policy.Authorizer denial maps to a real class-tagged :forbidden message" do
    message = data_message(%{})

    assert {:error, {:execution, reason}} =
             AshA2A.Dispatcher.dispatch(:list, message, ErrorClassProbe)

    assert reason =~ "forbidden:"
  end

  test "the real class-tagged message is real text, not opaque Elixir tuple syntax on the wire" do
    message = data_message(%{})

    assert {:error, {:execution, reason}} =
             AshA2A.Dispatcher.dispatch(:list, message, ErrorClassProbe)

    # A real A2A client can only ever receive plain text (`AshA2A.Protocol.Part.Text.new/1`
    # inside `Message.new_agent/1`) -- confirm the real reason is a legible
    # string, never literal `{:forbidden, ...}` tuple syntax a remote caller
    # could not parse into a structured class.
    assert is_binary(reason)
    refute reason =~ "{:forbidden"
  end
end


# --- SECTION 14: Original test/ash_a2a_dispatcher_fetch_record_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ADispatcherFetchRecordTest.Ticket do
  @moduledoc """
  Real fixture resource, private to this test file (kept out of the shared
  `test/support/fixture.ex` to avoid collisions with concurrent edits to that
  file): a genuine `Ash.Resource` whose primary key attribute is deliberately
  named `:ticket_ref` -- not `:id` -- so `AshA2A.Dispatcher`'s update/destroy
  dispatch path is exercised against a resource `Ash.get/3` (via
  `Ash.Resource.Info.primary_key/1`) resolves generically, exactly as it
  would for any resource not named `id`.
  """

  use Ash.Resource,
    domain: AshA2ADispatcherFetchRecordTest.TicketDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    attribute(:ticket_ref, :string,
      primary_key?: true,
      allow_nil?: false,
      writable?: true,
      public?: true
    )

    attribute(:status, :string, public?: true, default: "open")
  end

  actions do
    defaults([:read, :destroy, create: [:ticket_ref, :status], update: [:ticket_ref, :status]])
  end

  a2a do
    skill(:close, :update)
    skill(:remove, :destroy)
  end
end

defmodule AshA2ADispatcherFetchRecordTest.TicketDomain do
  @moduledoc "Real fixture domain for `AshA2ADispatcherFetchRecordTest.Ticket` above."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2ADispatcherFetchRecordTest.Ticket)
  end
end

defmodule AshA2ADispatcherFetchRecordTest.LineItem do
  @moduledoc """
  Real fixture resource, private to this test file, with a *composite*
  primary key (`:order_id` + `:line_no`, neither named `id`), for
  `fetch_record_for_update/3` composite-key regression coverage -- the
  second identity shape `Ash.Filter.get_filter/2` supports generically via
  `Ash.Resource.Info.primary_key/1` (a map/keyword of every key field).
  """

  use Ash.Resource,
    domain: AshA2ADispatcherFetchRecordTest.LineItemDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    attribute(:order_id, :string,
      primary_key?: true,
      allow_nil?: false,
      writable?: true,
      public?: true
    )

    attribute(:line_no, :integer,
      primary_key?: true,
      allow_nil?: false,
      writable?: true,
      public?: true
    )

    attribute(:sku, :string, public?: true)
  end

  actions do
    defaults([
      :read,
      :destroy,
      create: [:order_id, :line_no, :sku],
      update: [:order_id, :line_no, :sku]
    ])
  end

  a2a do
    skill(:update_sku, :update)
  end
end

defmodule AshA2ADispatcherFetchRecordTest.LineItemDomain do
  @moduledoc "Real fixture domain for `AshA2ADispatcherFetchRecordTest.LineItem` above."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2ADispatcherFetchRecordTest.LineItem)
  end
end

defmodule AshA2ADispatcherFetchRecordTest do
  @moduledoc """
  Chicago-style regression coverage for the reviewed
  `fetch_record_for_update/3` finding: dispatcher.ex's update/destroy
  dispatch path used to only recognize a literal `"id"`/`:id` input key
  before calling `Ash.get/3`, failing closed with
  `{:error, {:missing_argument, :id}}` for any resource whose real primary
  key is named something else, or is composite.

  Uses two real fixture resources defined above, private to this file (kept
  out of `test/support/fixture.ex` to avoid collisions with unrelated
  concurrent edits to that shared file):

    * `Ticket` -- single-attribute primary key named `:ticket_ref`, not `:id`.
    * `LineItem` -- composite primary key (`:order_id`, `:line_no`), neither
      named `id`.

  All records are inserted via real `Ash.create!/2` calls against the real
  ETS data layer and dispatched through the real
  `AshA2A.Dispatcher.dispatch/3` -- no Mock/mox/patch anywhere in this file.
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2ADispatcherFetchRecordTest.LineItem
  alias AshA2ADispatcherFetchRecordTest.Ticket
  alias AshA2A.Test.ReceiptedDispatch

  test "update dispatch resolves a non-`id`-named single primary key by its real attribute name" do
    ticket =
      Ticket
      |> Ash.Changeset.for_create(:create, %{ticket_ref: "TCK-1", status: "open"})
      |> Ash.create!()

    message =
      AshA2A.Protocol.Message.new_user([
        AshA2A.Protocol.Part.Data.new(%{"ticket_ref" => ticket.ticket_ref, "status" => "closed"})
      ])

    assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{status: "closed"}}]} =
             ReceiptedDispatch.dispatch(:close, message, Ticket)

    assert Ash.get!(Ticket, ticket.ticket_ref).status == "closed"
  end

  test "update dispatch resolves the primary key from atom-keyed input, not only string keys" do
    ticket =
      Ticket
      |> Ash.Changeset.for_create(:create, %{ticket_ref: "TCK-2", status: "open"})
      |> Ash.create!()

    message =
      AshA2A.Protocol.Message.new_user([
        AshA2A.Protocol.Part.Data.new(%{ticket_ref: ticket.ticket_ref, status: "closed"})
      ])

    assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{status: "closed"}}]} =
             ReceiptedDispatch.dispatch(:close, message, Ticket)
  end

  test "update dispatch still fails closed (missing_argument) when the real primary key is absent" do
    message = data_message(%{"status" => "closed"})

    assert {:input_required, [%AshA2A.Protocol.Part.Text{text: text}]} =
             ReceiptedDispatch.dispatch(:close, message, Ticket)

    assert text =~ "ticket_ref"
  end

  test "destroy dispatch resolves a non-`id`-named primary key the same way" do
    ticket =
      Ticket
      |> Ash.Changeset.for_create(:create, %{ticket_ref: "TCK-3", status: "open"})
      |> Ash.create!()

    message = data_message(%{"ticket_ref" => ticket.ticket_ref})

    assert {:reply, [%AshA2A.Protocol.Part.Data{}]} =
             ReceiptedDispatch.dispatch(:remove, message, Ticket)

    assert match?({:error, _}, Ash.get(Ticket, ticket.ticket_ref))
  end

  test "update dispatch resolves a composite primary key supplied as a map, no field named `id`" do
    line_item =
      LineItem
      |> Ash.Changeset.for_create(:create, %{order_id: "ORD-1", line_no: 1, sku: "WIDGET-A"})
      |> Ash.create!()

    message =
      AshA2A.Protocol.Message.new_user([
        AshA2A.Protocol.Part.Data.new(%{
          "order_id" => line_item.order_id,
          "line_no" => line_item.line_no,
          "sku" => "WIDGET-B"
        })
      ])

    assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{sku: "WIDGET-B"}}]} =
             ReceiptedDispatch.dispatch(:update_sku, message, LineItem)

    assert Ash.get!(LineItem, %{order_id: line_item.order_id, line_no: line_item.line_no}).sku ==
             "WIDGET-B"
  end

  test "update dispatch fails closed when only part of a composite primary key is supplied" do
    message =
      AshA2A.Protocol.Message.new_user([
        AshA2A.Protocol.Part.Data.new(%{"order_id" => "ORD-2", "sku" => "WIDGET-C"})
      ])

    assert {:input_required, [%AshA2A.Protocol.Part.Text{text: text}]} =
             ReceiptedDispatch.dispatch(:update_sku, message, LineItem)

    assert text =~ "order_id"
    assert text =~ "line_no"
  end
end


# --- SECTION 15: Original test/ash_a2a_dispatcher_not_found_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ADispatcherNotFoundTest.Case do
  @moduledoc """
  Real fixture resource, private to this test file: a genuine `Ash.Resource`
  on the real ETS data layer whose `:update` and `:destroy` actions are
  exposed as A2A skills, so a dispatch against a primary key that names no
  stored record runs the real `Ash.get/3` not-found path inside
  `AshA2A.Dispatcher.fetch_record_for_update/3`.
  """

  use Ash.Resource,
    domain: AshA2ADispatcherNotFoundTest.CaseDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    attribute(:case_ref, :string,
      primary_key?: true,
      allow_nil?: false,
      writable?: true,
      public?: true
    )

    attribute(:status, :string, public?: true, default: "open")
    attribute(:priority, :integer, public?: true, default: 1)
  end

  actions do
    defaults([
      :read,
      :destroy,
      create: [:case_ref, :status, :priority],
      update: [:status, :priority]
    ])
  end

  a2a do
    skill(:resolve_case, :update)
    skill(:drop_case, :destroy)
  end
end

defmodule AshA2ADispatcherNotFoundTest.CaseDomain do
  @moduledoc "Real fixture domain for `AshA2ADispatcherNotFoundTest.Case` above."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2ADispatcherNotFoundTest.Case)
  end
end

defmodule AshA2ADispatcherNotFoundTest do
  @moduledoc """
  Chicago-school coverage for the `Ash.Error.Query.NotFound` reply class
  carried forward from `preserve/v26.9.22/stash-4` (unique hunk U1).

  An update/destroy dispatch whose primary key names no stored record used to
  fall into `AshA2A.Dispatcher.to_reply/1`'s generic `class: :invalid` clause
  and come back as `{:input_required, _}` -- telling a well-behaved A2A client
  to resubmit identical input forever. It must instead be the non-retryable
  `"not_found: ..."` error class (main's `class_message/2` shape), stage-tagged
  `:execution` by `dispatch/6` like every other execution-stage error.

  Everything is real: records are written with `Ash.create!/2` to the real ETS
  data layer, and every dispatch goes through the real `AshA2A.CommandBus`
  (via `AshA2A.Test.ReceiptedDispatch`) into the real dispatcher. No
  Mock/Mox/patch anywhere in this file. The positive controls (existing
  record replies; a genuinely malformed argument still asks for input) keep
  the not-found assertion from being satisfiable by a dispatcher that maps
  every `:invalid` error to `:not_found`.
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.ReceiptedDispatch
  alias AshA2ADispatcherNotFoundTest.Case

  defp create_case!(ref) do
    Case
    |> Ash.Changeset.for_create(:create, %{case_ref: ref, status: "open"})
    |> Ash.create!()
  end

  defp missing_ref, do: "CASE-MISSING-" <> Ash.UUIDv7.generate()

  test "update dispatch against a nonexistent primary key returns the not_found class" do
    message = data_message(%{"case_ref" => missing_ref(), "status" => "closed"})

    assert {:error, {:execution, "not_found: " <> detail}} =
             ReceiptedDispatch.dispatch(:resolve_case, message, Case)

    assert detail =~ "not found"
  end

  test "destroy dispatch against a nonexistent primary key returns the not_found class" do
    message = data_message(%{"case_ref" => missing_ref()})

    assert {:error, {:execution, "not_found: " <> detail}} =
             ReceiptedDispatch.dispatch(:drop_case, message, Case)

    assert detail =~ "not found"
  end

  test "a record destroyed before an update dispatch is not_found, never input_required" do
    ref = "CASE-GONE-" <> Ash.UUIDv7.generate()
    record = create_case!(ref)
    :ok = Ash.destroy!(record)

    message = data_message(%{"case_ref" => ref, "status" => "closed"})
    result = ReceiptedDispatch.dispatch(:resolve_case, message, Case)

    refute match?({:input_required, _}, result)
    assert {:error, {:execution, "not_found: " <> detail}} = result
    assert detail =~ ref
  end

  test "positive control: an existing record still updates and replies" do
    ref = "CASE-LIVE-" <> Ash.UUIDv7.generate()
    create_case!(ref)

    message = data_message(%{"case_ref" => ref, "status" => "closed"})

    assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{status: "closed"}}]} =
             ReceiptedDispatch.dispatch(:resolve_case, message, Case)

    assert Ash.get!(Case, ref).status == "closed"
  end

  test "control: a malformed argument on an existing record still asks for input" do
    ref = "CASE-BADARG-" <> Ash.UUIDv7.generate()
    create_case!(ref)

    message = data_message(%{"case_ref" => ref, "priority" => "not-an-integer"})

    assert {:input_required, [%AshA2A.Protocol.Part.Text{}]} =
             ReceiptedDispatch.dispatch(:resolve_case, message, Case)

    assert Ash.get!(Case, ref).priority == 1
  end
end


# --- SECTION 16: Original test/ash_a2a_dispatcher_skill_name_shape_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ADispatcherSkillNameShapeTest do
  @moduledoc """
  Chicago-style regression coverage for the ERRC "Raise" finding:
  `AshA2A.Dispatcher.to_skill_name/1` had no catch-all clause, contradicting
  its own documented fail-closed contract. `skill_name` reaches
  `AshA2A.Dispatcher.dispatch/5` from `AshA2A.Agent.resolve_skill_name/2`,
  which pulls it out of an unauthenticated, unschema'd `AshA2A.Protocol.Message.metadata`
  map with zero type checking -- so a remote caller can make `skill_name` any
  term at all (integer, list, map, ...), not just `atom()` or `String.t()`.

  Before the fix, `to_skill_name(123)` / `to_skill_name([1, 2])` /
  `to_skill_name(%{})` would raise `FunctionClauseError` instead of returning
  the documented `{:error, {:unknown_skill, skill_name}}`, crashing the
  calling `AshA2A.Protocol.Agent` process.

  No Mock/mox/patch/monkeypatch: this dispatches a real `AshA2A.Protocol.Message` through
  the real `AshA2A.Dispatcher.dispatch/5` against the real
  `AshA2A.Test.Fixture.Item` resource and asserts on the real returned reply
  tuple (state-based), not on any mocked interaction.
  """

  use ExUnit.Case

  alias AshA2A.Test.Fixture.Item

  for {label, bad_skill_name} <- [
        {"an integer", 123},
        {"a list", [1, 2]},
        {"a map", %{}},
        {"a tuple", {:foo, :bar}},
        {"a float", 1.5}
      ] do
    test "dispatch/5 fails closed (no raise) for a skill_name that is #{label}" do
      message =
        AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"label" => "widget"})])

      bad_skill_name = unquote(Macro.escape(bad_skill_name))

      assert {:error, {:skill_lookup, {:unknown_skill, ^bad_skill_name}}} =
               AshA2A.Dispatcher.dispatch(bad_skill_name, message, Item)
    end
  end

  # Name-shape resolution is exercised on `Item`'s `:observe` skill: a
  # `:change` skill dispatched directly is refused by the sole-DO fence
  # (`AshA2A.BrceAnchor`) after -- and independently of -- skill lookup.
  test "dispatch/5 still resolves a real atom skill_name to a normal reply" do
    message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

    assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{result: "pong"}}]} =
             AshA2A.Dispatcher.dispatch(:ping, message, Item)
  end

  test "dispatch/5 still resolves a real binary skill_name to a normal reply" do
    message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

    assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{result: "pong"}}]} =
             AshA2A.Dispatcher.dispatch("ping", message, Item)
  end
end


# --- SECTION 17: Original test/ash_a2a_dispatcher_skills_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ADispatcherSkillsTest do
  @moduledoc """
  Chicago-style coverage for `AshA2A.Dispatcher.dispatch/3` branches that had
  no real fixture exercising them before this file: `:create`, `:update`,
  `:destroy`, and a generic `:action` skill (previously only `:read`-shaped
  skills existed as fixtures -- `Echo`, `Widget`), plus `to_reply/1`'s
  error-class mapping for a real `{:missing_argument, :id}` and a real
  `Ash.Error.Invalid` from a missing required create argument, and both
  branches of `pop_stream_flag/1` (string-keyed `"stream"` and atom-keyed
  `:stream`).

  Uses the real `AshA2A.Test.Fixture.Item` resource (`test/support/fixture.ex`),
  a genuine `Ash.Resource` with `extensions: [AshA2A]`, dispatched through the
  real `AshA2A.Dispatcher.dispatch/3` -- no Mock/mox/patch, no stubbed Ash or
  A2A behavior anywhere in this file.

  NOTE on scope: this file exercises the *:missing_argument* id branch of
  `:update`/`:destroy` (real `fetch_record_for_update/3` -> `{:error,
  {:missing_argument, :id}}` -> `to_reply/1` -> `:input_required`), which is
  what tasks #3 and #4 (below) actually require. The *successful* id-resolved
  update/destroy dispatch (string-keyed and atom-keyed id present) is a real,
  already-verified case in `test/ash_a2a_dispatcher_fetch_record_test.exs`
  against `AshA2A.Test.Fixture.Ticket`/`LineItem` -- deliberately not
  duplicated against a literally-`:id`-named resource here, because a real
  Ash constraint discovered while writing this file makes that specific
  combination impossible: Ash unconditionally strips an attribute literally
  named `:id` from every `accept` list (confirmed with a standalone probe --
  `Ash.Resource.Info.action(resource, :destroy).accept == []` even when the
  action explicitly declares `accept([:id])`), so a resource whose primary
  key attribute is named `:id` can never accept it back as changeset input --
  `AshA2A.Dispatcher.run_update/4`/`run_destroy/4` pass the *full* inbound
  input map (id included) into `Ash.Changeset.for_update/3`/`for_destroy/3`,
  so this always surfaces as a real `Ash.Error.Invalid` ("No such input
  `id`"), regardless of dispatcher logic. This is a genuine Ash/dispatcher
  interaction, not a test artifact -- `Ticket`'s non-`id`-named primary key
  (`:ticket_ref`) is what makes its equivalent success-path tests pass.
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.Item
  alias AshA2A.Test.ReceiptedDispatch

  test "dispatch/3 runs a real :create skill end to end" do
    message = data_message(%{"label" => "widget"})

    assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{label: "widget", id: id}}]} =
             ReceiptedDispatch.dispatch(:create_item, message, Item)

    refute is_nil(id)
    assert {:ok, record} = Ash.get(Item, id, domain: AshA2A.Test.Fixture.ItemDomain)
    assert record.label == "widget"
  end

  test "dispatch/3's :update skill maps a real missing id to {:input_required, _} (to_reply/1)" do
    message = data_message(%{"label" => "no id here"})

    assert {:input_required, [%AshA2A.Protocol.Part.Text{text: text}]} =
             ReceiptedDispatch.dispatch(:update_item, message, Item)

    assert text =~ "id"
  end

  test "dispatch/3's :update skill still fails closed for a real missing atom-keyed id" do
    message = data_message(%{label: "no id here either"})

    assert {:input_required, [%AshA2A.Protocol.Part.Text{text: text}]} =
             ReceiptedDispatch.dispatch(:update_item, message, Item)

    assert text =~ "id"
  end

  test "dispatch/3's :destroy skill maps a real missing id to {:input_required, _} (to_reply/1)" do
    message = data_message(%{})

    assert {:input_required, [%AshA2A.Protocol.Part.Text{text: text}]} =
             ReceiptedDispatch.dispatch(:destroy_item, message, Item)

    assert text =~ "id"
  end

  test "dispatch/3 runs a real generic :action skill" do
    message = data_message(%{})

    assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{result: "pong"}}]} =
             AshA2A.Dispatcher.dispatch(:ping, message, Item)
  end

  test "to_reply/1 maps a real Ash.Error.Invalid (missing required create argument) to {:input_required, _}" do
    # `Item`'s `:create` action requires `:label` (allow_nil?: false) --
    # omitting it produces a genuine `Ash.Error.Invalid` from
    # `Ash.Changeset.for_create/3`/`Ash.create/2`, not a hand-built error.
    message = data_message(%{})

    assert {:input_required, [%AshA2A.Protocol.Part.Text{text: text}]} =
             ReceiptedDispatch.dispatch(:create_item, message, Item)

    assert is_binary(text)
  end

  test "dispatch/3 streams a real :echo read when the caller opts in with an atom-keyed :stream flag" do
    # Companion to `ash_a2a_test.exs`'s string-keyed (`"stream" => true`)
    # streaming test: exercises `pop_stream_flag/1`'s other real branch,
    # `%{stream: true}`, against the same real compiled `Echo` fixture and
    # the real `Ash.stream!/2` API.
    message = data_message(%{stream: true})

    assert {:stream, stream} =
             AshA2A.Dispatcher.dispatch(:echo, message, AshA2A.Test.Fixture.Echo)

    assert Enum.to_list(stream) == []
  end
end


# --- SECTION 18: Original test/ash_a2a_dispatcher_tenant_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ADispatcherTenantTest do
  @moduledoc """
  Chicago-style regression coverage for the Zach-Daniel-review finding:
  `AshA2A.Dispatcher.to_reply/1`'s `TenantRequired` carve-out (routing a
  missing-tenant error to `{:error, {:invalid_config, _}}` instead of the
  generic `:input_required` "supply more input" signal) previously only
  matched `Ash.Error.Invalid.TenantRequired`/`NoPrimaryAction`, which only
  `:read` ever raises. `:create`/`:update`/`:destroy` enforce multitenancy
  through a different path (`Ash.Actions.Helpers
  .validate_changeset_multitenancy/1`) that raises a generic
  `Ash.Error.Changes.InvalidChanges` wrapped in a top-level
  `Ash.Error.Invalid{errors: [...]}`, which fell through to the generic
  `%{class: :invalid}` clause and told the caller "supply more input" --
  exactly the wrong signal, since no input the caller could supply fixes a
  missing tenant.

  Uses the real `AshA2A.Test.Fixture.TenantedItem` multitenant resource
  (`test/support/fixture.ex`), dispatched through the real
  `AshA2A.Dispatcher.dispatch/3` with no tenant in context -- no Mock/mox/
  patch, no stubbed Ash or A2A behavior anywhere in this file. Every error
  asserted on here is a genuine error Ash's own multitenancy enforcement
  raised, not a hand-built term.
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.TenantedItem
  alias AshA2A.Test.ReceiptedDispatch

  test "dispatch/3 maps a real missing-tenant :create error to a class-tagged :invalid_config error, not :input_required" do
    message = data_message(%{"label" => "widget"})

    assert {:error, {:execution, reason}} =
             ReceiptedDispatch.dispatch(:create_tenanted_item, message, TenantedItem)

    assert reason =~ "invalid_config:"
    assert reason =~ "tenant"
  end

  test "dispatch/3 maps a real missing-tenant :update error to a class-tagged :invalid_config error, not :input_required" do
    {:ok, record} =
      TenantedItem
      |> Ash.Changeset.for_create(:create, %{label: "before"}, tenant: "acme")
      |> Ash.create(domain: AshA2A.Test.Fixture.TenantedItemDomain)

    message =
      data_message(%{"id" => record.id, "label" => "after"})

    assert {:error, {:execution, reason}} =
             ReceiptedDispatch.dispatch(:update_tenanted_item, message, TenantedItem)

    assert reason =~ "invalid_config:"
    assert reason =~ "tenant"
  end

  test "dispatch/3 maps a real missing-tenant :destroy error to a class-tagged :invalid_config error, not :input_required" do
    {:ok, record} =
      TenantedItem
      |> Ash.Changeset.for_create(:create, %{label: "before"}, tenant: "acme")
      |> Ash.create(domain: AshA2A.Test.Fixture.TenantedItemDomain)

    message = data_message(%{"id" => record.id})

    assert {:error, {:execution, reason}} =
             ReceiptedDispatch.dispatch(:destroy_tenanted_item, message, TenantedItem)

    assert reason =~ "invalid_config:"
    assert reason =~ "tenant"
  end

  test "dispatch/3 still returns :input_required for a genuine caller-fixable :invalid error (unrelated to tenancy)" do
    # Regression guard for the fix itself: an ordinary missing-required-
    # attribute error on a *non*-multitenant resource must still be
    # caller-actionable (`:input_required`), not swept into
    # `:invalid_config` by an overly broad tenant-message match.
    message = data_message(%{})

    assert {:input_required, _parts} =
             ReceiptedDispatch.dispatch(:create_item, message, AshA2A.Test.Fixture.Item)
  end
end


# --- SECTION 19: Original test/ash_a2a_doctest_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DoctestTest do
  @moduledoc """
  Wires every public module's `@doc` doctest examples into ExUnit via
  `doctest/1`. Every example runs against the real, compiled code (and, where
  referenced, the real `AshA2A.Test.Fixture.*` fixtures from
  `test/support/fixture.ex`) -- no Mock/mox/patch, no fabricated data.

  Modules whose `@doc` examples live in other test files (e.g.
  `AshA2A.Semantic.Envelope` in `test/ash_a2a/semantic_envelope_doctest_test.exs`,
  `AshA2A.Transport.Principal` in `test/ash_a2a/transport/transport_court_test.exs`)
  are wired there, not duplicated here.
  """

  use ExUnit.Case, async: true

  doctest AshA2A.Info
  doctest AshA2A.CapabilityIndex
  doctest AshA2A.CapabilityIndex.AgentCardBuilder
  doctest AshA2A.ContextResolver
  doctest AshA2A.Schema
  doctest AshA2A.ToA2AError

  doctest AshA2A.Actuation
  doctest AshA2A.Authority
  doctest AshA2A.Receipt
  doctest AshA2A.TaskLifecycle

  doctest AshA2A.Protocol.Version
  doctest AshA2A.Protocol.JSON
  doctest AshA2A.Protocol.JSONRPC.Error
  doctest AshA2A.Protocol.CardSigning
  doctest AshA2A.Protocol.CardCache
  doctest AshA2A.Protocol.Extensions.Schema

  doctest AshA2A.Gall.Capability
  doctest AshA2A.Gall.Fields
  doctest AshA2A.Gall.Message

  doctest AshA2A.GraphLaw.WasmDriver
  doctest AshA2A.GraphLaw.WasmexHost

  doctest AshA2A.Chicago.Observer.EvidenceBounds

  doctest AshA2A.Semantic.Serialize
  doctest AshA2A.Semantic.LogicClosure.RuleDocument
end


# --- SECTION 20: Original test/ash_a2a_domain_transports_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DomainTransportsTest.Resource do
  @moduledoc """
  Real fixture resource: one real `:read` skill (`:echo`), so each mounted
  agent has exactly one skill and dispatch needs no `:skill` metadata.
  """

  use Ash.Resource,
    domain: AshA2A.DomainTransportsTest.HomeDomain,
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

defmodule AshA2A.DomainTransportsTest.HomeDomain do
  @moduledoc "Real fixture home domain for the fixture resource above."
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DomainTransportsTest.Resource)
  end
end

defmodule AshA2A.DomainTransportsTest.EchoAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over the fixture resource (JSON-RPC mount)."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.DomainTransportsTest.Resource,
    name: "domain_transports_echo_agent",
    public_skills: [:echo]
end

defmodule AshA2A.DomainTransportsTest.RestAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over the fixture resource (REST mount)."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.DomainTransportsTest.Resource,
    name: "domain_transports_rest_agent",
    public_skills: [:echo]
end

defmodule AshA2A.DomainTransportsTest.MountedDomain do
  @moduledoc """
  Real domain-level transport surface (lane G-I): two real agents mounted
  at declared paths over declared bindings, plus one `:grpc` mount.
  """

  use Ash.Domain, extensions: [AshA2A.Domain]

  agent do
    name "mounted-domain"
    description "Domain-level mounts court domain"
  end

  transport do
    base_url "https://agents.example.com"

    mount agent: AshA2A.DomainTransportsTest.EchoAgent,
          path: "/echo",
          binding: :jsonrpc

    mount agent: AshA2A.DomainTransportsTest.RestAgent,
          path: "/greeter",
          binding: :rest

    mount agent: AshA2A.DomainTransportsTest.EchoAgent,
          path: "/echo-grpc",
          binding: :grpc
  end
end

defmodule AshA2A.DomainTransportsTest.LegacyDefaultMountDomain do
  @moduledoc "Domain declaring only the path-only default mount (`default_mount`)."

  use Ash.Domain, extensions: [AshA2A.Domain]

  agent do
    name "legacy-default-mount"
  end

  transport do
    base_url "https://legacy.example.com"
    default_mount "/legacy"
  end
end

defmodule AshA2A.DomainTransportsTest.CardDomain do
  @moduledoc """
  Domain carrying both the capability (`AshA2A`) and transport
  (`AshA2A.Domain`) extensions, with three declared mounts over the three
  bindings -- the declared-transport `supported_interfaces` court subject.
  """

  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DomainTransportsTest.Resource)
  end

  agent do
    name "card-domain"
    version "1.0.0"
  end

  transport do
    base_url "https://cards.example.com"

    mount agent: AshA2A.DomainTransportsTest.EchoAgent,
          path: "/echo",
          binding: :jsonrpc

    mount agent: AshA2A.DomainTransportsTest.RestAgent,
          path: "/greeter",
          binding: :rest

    mount agent: AshA2A.DomainTransportsTest.EchoAgent,
          path: "/echo-grpc",
          binding: :grpc
  end
end

defmodule AshA2A.DomainTransportsTest.OneMountDomain do
  @moduledoc "Card court subject declaring exactly one per-agent mount."

  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DomainTransportsTest.Resource)
  end

  agent do
    name "one-mount-domain"
  end

  transport do
    base_url "https://one.example.com"

    mount agent: AshA2A.DomainTransportsTest.EchoAgent, path: "/only", binding: :jsonrpc
  end
end

defmodule AshA2A.DomainTransportsTest do
  @moduledoc """
  Court for domain-level transport definition (Workstream3 G5, lane G-I):
  the verified ash_json_api pattern -- domain-level route definition as the
  documented default -- applied to `AshA2A.Domain`.

  Real domain with two real agents + declared mounts -> `AshA2A.Domain.Router`
  serves both agents' cards and dispatch at their paths (real Bandit server,
  real supervised agent GenServers, real `Req` calls); a misdeclared agent is
  a compile-time verifier refusal (`Spark.Error.DslError`). No mocks.
  """

  use ExUnit.Case, async: false

  import Spark.Test, only: [assert_dsl_error: 2]

  @moduletag :serial_shard

  alias AshA2A.Domain.Info
  alias AshA2A.Domain.Mount
  alias AshA2A.Domain.Router
  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}

  setup do
    {_sup, _registry} =
      AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        AshA2A.DomainTransportsTest.EchoAgent,
        AshA2A.DomainTransportsTest.RestAgent
      ])

    %{
      server: EphemeralHttp.start!({Router, domain: AshA2A.DomainTransportsTest.MountedDomain})
    }
  end

  # -- persisted mount specs ---------------------------------------------------

  test "mounts/1 records every declared per-agent mount" do
    mounts = Info.mounts(AshA2A.DomainTransportsTest.MountedDomain)

    assert length(mounts) == 3

    assert Enum.map(mounts, &{&1.agent, &1.path, &1.binding}) == [
             {AshA2A.DomainTransportsTest.EchoAgent, "/echo", :jsonrpc},
             {AshA2A.DomainTransportsTest.RestAgent, "/greeter", :rest},
             {AshA2A.DomainTransportsTest.EchoAgent, "/echo-grpc", :grpc}
           ]

    assert Enum.all?(mounts, &match?(%Mount{}, &1))
  end

  test "default_mount/1 and mount/1 keep the path-only default semantics" do
    assert Info.default_mount(AshA2A.DomainTransportsTest.LegacyDefaultMountDomain) == "/legacy"
    assert Info.mount(AshA2A.DomainTransportsTest.LegacyDefaultMountDomain) == "/legacy"

    # no path-only declaration -> historical default
    assert Info.default_mount(AshA2A.DomainTransportsTest.MountedDomain) == "/a2a"
    assert Info.mount(AshA2A.DomainTransportsTest.MountedDomain) == "/a2a"
  end

  # -- declared-transport supported_interfaces default (lane ZD4) ---------------

  describe "declared-transport supported_interfaces default" do
    @version AshA2A.Protocol.Version.protocol_version()

    test "a domain with three declared mounts projects three supported_interfaces entries" do
      card = AshA2A.Info.agent_card(AshA2A.DomainTransportsTest.CardDomain)

      assert card.supported_interfaces == [
               %{
                 url: "https://cards.example.com/echo",
                 protocol_binding: "JSONRPC",
                 protocol_version: @version
               },
               %{
                 url: "https://cards.example.com/greeter",
                 protocol_binding: "HTTP+JSON",
                 protocol_version: @version
               },
               %{
                 url: "https://cards.example.com/echo-grpc",
                 protocol_binding: "GRPC",
                 protocol_version: @version
               }
             ]
    end

    test "a domain with one declared mount projects exactly one supported_interfaces entry" do
      card = AshA2A.Info.agent_card(AshA2A.DomainTransportsTest.OneMountDomain)

      assert card.supported_interfaces == [
               %{
                 url: "https://one.example.com/only",
                 protocol_binding: "JSONRPC",
                 protocol_version: @version
               }
             ]
    end

    test "an explicit :supported_interfaces opt still overrides the declared transports" do
      override = [%{url: "https://manual.example.com/rpc", protocol_binding: "JSONRPC"}]

      card =
        AshA2A.Info.agent_card(AshA2A.DomainTransportsTest.CardDomain,
          supported_interfaces: override
        )

      assert card.supported_interfaces == [
               %{
                 url: "https://manual.example.com/rpc",
                 protocol_binding: "JSONRPC",
                 protocol_version: @version
               }
             ]
    end

    test "a domain with no declared transports keeps the legacy single-JSONRPC default" do
      # HomeDomain declares the capability extension but no `transport`
      # section: no mounts -> the historical single-entry default at the
      # builder url.
      card = AshA2A.Info.agent_card(AshA2A.DomainTransportsTest.HomeDomain)

      assert card.supported_interfaces == [
               %{
                 url: "http://localhost:4000",
                 protocol_binding: "JSONRPC",
                 protocol_version: @version
               }
             ]
    end
  end

  # -- router serves both agents at their paths ----------------------------------

  test "jsonrpc mount serves the agent card and dispatch at its path", %{server: server} do
    card = Req.get!(url: server.base_url <> "/echo/.well-known/agent-card.json")
    assert card.status == 200
    assert %{"name" => "domain_transports_echo_agent"} = card.body

    resp =
      Req.post!(
        url: server.base_url <> "/echo",
        json: %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "message/send",
          "params" => %{"message" => message_map("hello from the domain router")}
        }
      )

    assert resp.status == 200
    assert %{"result" => %{"task" => %{"id" => task_id}}} = resp.body
    assert is_binary(task_id)
  end

  test "rest mount serves the agent card and dispatch at its path", %{server: server} do
    card = Req.get!(url: server.base_url <> "/greeter/.well-known/agent-card.json")
    assert card.status == 200
    assert %{"name" => "domain_transports_rest_agent"} = card.body

    resp =
      Req.post!(
        url: server.base_url <> "/greeter/message:send",
        headers: [{"content-type", "application/json"}],
        json: %{"message" => message_map("hello over rest")}
      )

    assert resp.status == 200
    assert %{"task" => %{"id" => task_id}} = resp.body
    assert is_binary(task_id)
  end

  test "grpc mount answers a typed 501 refusal naming the gRPC endpoint", %{server: server} do
    resp = Req.post!(url: server.base_url <> "/echo-grpc", json: %{"any" => "body"})

    assert resp.status == 501

    assert %{"error" => %{"code" => "grpc_not_served_over_http", "details" => details}} =
             resp.body

    assert details["reason"] == "GRPC_BINDING_NOT_ROUTABLE"
    assert details["metadata"]["endpoint"] =~ "GRPC.Server.Endpoint"
  end

  test "an undeclared path is a typed 404", %{server: server} do
    resp = Req.get!(url: server.base_url <> "/not-declared")

    assert resp.status == 404
  end

  # -- compile-time refusal ------------------------------------------------------

  test "kill: a mount naming a nonexistent agent fails compilation with a real DslError" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.DomainTransports.Misdeclared do
          @moduledoc false

          use Ash.Domain, extensions: [AshA2A.Domain]

          agent do
            name "misdeclared"
          end

          transport do
            base_url "https://misdeclared.example.com"

            mount agent: This.Agent.Does.Not.Exist,
                  path: "/nowhere",
                  binding: :jsonrpc
          end
        end
      end

    assert error.message =~ "This.Agent.Does.Not.Exist"
    assert error.message =~ "does not exist"
  end

  test "kill: a duplicate mount path fails compilation with a real DslError" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.DomainTransports.DuplicatePath do
          @moduledoc false

          use Ash.Domain, extensions: [AshA2A.Domain]

          agent do
            name "duplicate-path"
          end

          transport do
            base_url "https://duplicate.example.com"

            mount agent: AshA2A.DomainTransportsTest.EchoAgent, path: "/same", binding: :jsonrpc

            mount agent: AshA2A.DomainTransportsTest.RestAgent, path: "/same", binding: :rest
          end
        end
      end

    assert error.message =~ "/same"
    assert error.message =~ "more than once"
  end

  test "kill: an agent mounted twice over one binding fails compilation with a real DslError" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.DomainTransports.DuplicateBinding do
          @moduledoc false

          use Ash.Domain, extensions: [AshA2A.Domain]

          agent do
            name "duplicate-binding"
          end

          transport do
            base_url "https://duplicate-binding.example.com"

            mount agent: AshA2A.DomainTransportsTest.EchoAgent, path: "/one", binding: :jsonrpc

            mount agent: AshA2A.DomainTransportsTest.EchoAgent, path: "/two", binding: :jsonrpc
          end
        end
      end

    assert error.message =~ "more than once over the `jsonrpc` binding"
  end

  # -- helpers ----------------------------------------------------------------

  defp message_map(text) do
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end
end


# --- SECTION 21: Original test/ash_a2a_dsl_nested_argument_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DslNestedArgumentTest do
  use ExUnit.Case, async: true

  import Spark.Test

  @moduledoc """
  ERRC Create finding: the `:skill` `Spark.Dsl.Entity` had no `entities:`
  key, so no nested `do...end` block was structurally possible at all
  (`Spark.Dsl.Entity` requires `entities:` on the parent before it accepts a
  child entity block). `lib/ash_a2a/dsl.ex`'s `:skill` entity now declares
  `entities: [arguments: [@argument]]`, backed by a real `AshA2A.Argument`
  entity target (`lib/ash_a2a/argument.ex`).

  This test compiles a real fixture resource
  (`AshA2A.Test.NestedArg.EchoWithArgument`) that actually writes
  `skill :echo, :read do argument :query, :string end` and asserts on the
  real compiled DSL entity state via `Spark.Dsl.Extension.get_entities/2` --
  no mocked parser, no hand-built struct standing in for compilation.
  """

  # The fixture is compiled inside the test (not in test/support) because
  # `AshA2A.Verify` warns on a dead nested argument, and a
  # support-compiled fixture would fail `mix compile --warnings-as-errors`.
  # `assert_dsl_warning` collects that real warning, so the same compile also
  # proves the verifier fires.
  test "a skill entity accepts a nested argument block and compiles it for real" do
    {message, _location} =
      assert_dsl_warning {_, _} do
        defmodule Elixir.AshA2A.Test.NestedArg.EchoWithArgumentDomain do
          @moduledoc false
          use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

          resources do
            resource(Elixir.AshA2A.Test.NestedArg.EchoWithArgument)
          end
        end

        defmodule Elixir.AshA2A.Test.NestedArg.EchoWithArgument do
          @moduledoc false
          use Ash.Resource,
            domain: Elixir.AshA2A.Test.NestedArg.EchoWithArgumentDomain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
            attribute(:message, :string, public?: true)
          end

          actions do
            defaults([:read])
          end

          a2a do
            skill :echo, :read do
              argument(:query, :string)
            end
          end
        end
      end

    assert message =~ ":echo"

    [skill] = Spark.Dsl.Extension.get_entities(AshA2A.Test.NestedArg.EchoWithArgument, [:a2a])

    assert %AshA2A.Skill{name: :echo, action: :read, arguments: [argument]} = skill
    assert %AshA2A.Argument{name: :query, type: :string} = argument
  end

  test "a skill entity with no nested block still compiles with an empty arguments list" do
    [skill] = Spark.Dsl.Extension.get_entities(AshA2A.Test.Fixture.Echo, [:a2a])

    assert %AshA2A.Skill{name: :echo, action: :read, arguments: []} = skill
  end
end


# --- SECTION 22: Original test/ash_a2a_dsl_nested_hddl_operator_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DslNestedHddlOperatorTest do
  use ExUnit.Case, async: true

  @moduledoc """
  HDDL deterministic-planning-path Task 1: the `:skill` entity now also
  declares `entities: [arguments: [@argument], hddl_operators:
  [@hddl_operator]]` (`lib/ash_a2a/dsl.ex`), backed by a real
  `AshA2A.HddlOperator` entity target (`lib/ash_a2a/hddl_operator.ex`).

  Unlike the pre-existing `argument` nested entity -- accepted but
  deliberately dead at capability-compilation time
  (`AshA2A.Verify.dead_argument_warning/1`) -- `hddl_operator` is a *live*
  override field: `AshA2A.CapabilityIndex.Compiler.project/3` copies it
  through into the real compiled `AshA2A.Skill.hddl_operators`, because HDDL
  operator metadata has no equivalent to derive from Ash introspection
  instead. This test compiles a real fixture resource
  (`AshA2A.Test.Fixture.EchoWithHddlOperator`) that actually writes a
  `hddl_operator do ... end` block and asserts both on the raw compiled DSL
  entity state (`Spark.Dsl.Extension.get_entities/2`) and on the real
  compiled capability index (`AshA2A.Info.capability_index/1`) -- no mocked
  parser, no hand-built struct standing in for compilation.
  """

  test "a skill entity accepts a nested hddl_operator block and compiles it for real" do
    [skill] =
      Spark.Dsl.Extension.get_entities(AshA2A.Test.Fixture.EchoWithHddlOperator, [:a2a])

    assert %AshA2A.Skill{name: :advance, action: :read, hddl_operators: [operator]} = skill

    assert %AshA2A.HddlOperator{
             parameters: [:from, :to],
             preconditions: [{:current_phase, [:from]}],
             add_effects: [{:current_phase, [:to]}],
             delete_effects: [{:current_phase, [:from]}]
           } = operator
  end

  test "the declared hddl_operator is a live field: it round-trips into the real compiled capability index" do
    {:ok, skill} = AshA2A.Info.skill(AshA2A.Test.Fixture.EchoWithHddlOperator, :advance)

    assert %AshA2A.Skill{hddl_operators: [operator]} = skill

    assert %AshA2A.HddlOperator{
             parameters: [:from, :to],
             preconditions: [{:current_phase, [:from]}],
             add_effects: [{:current_phase, [:to]}],
             delete_effects: [{:current_phase, [:from]}]
           } = operator
  end

  test "a skill with no nested hddl_operator block still compiles with an empty hddl_operators list, in both the DSL entity and the compiled index" do
    [skill] = Spark.Dsl.Extension.get_entities(AshA2A.Test.Fixture.Echo, [:a2a])
    assert %AshA2A.Skill{name: :echo, action: :read, hddl_operators: []} = skill

    {:ok, compiled} = AshA2A.Info.skill(AshA2A.Test.Fixture.Echo, :echo)
    assert %AshA2A.Skill{hddl_operators: []} = compiled
  end
end

