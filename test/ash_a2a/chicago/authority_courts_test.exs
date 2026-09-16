defmodule AshA2A.Chicago.AuthorityCourtsTest do
  @moduledoc """
  RFC-SA2A-002 §57/§64-§67 authority courts, run end to end through the real
  `AshA2A.Chicago.Runner`: real agents, real HTTP transport pipeline, real
  brokers (InMemory process and on-disk EKV), real CommandBus, real ETS
  ledger, real OCEL artifact read back by the independent consumer.

  `async: false` -- the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier, and the courts point
  the host's `:authority_broker` at their own broker for the run.
  """

  use ExUnit.Case, async: false

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Authority.Broker.{Ekv, InMemory}
  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.{AuthorityHarness, AuthorityNonImplication, GrantLifecycle}
  alias AshA2A.Semantic.Bounds

  @moduletag :tmp_dir

  @doc false
  def forward(event, _measurements, meta, {pid, :telemetry}),
    do: send(pid, {:telemetry, event, meta})

  def forward(_event, _measurements, meta, {pid, tag}), do: send(pid, {tag, meta})

  @authority_verdicts %{
    "SA2A-AUTH-001" => :positive_control_passed,
    "SA2A-AUTH-002" => :falsifier_killed,
    "SA2A-AUTH-003" => :positive_control_passed,
    "SA2A-AUTH-004" => :falsifier_killed,
    "SA2A-AUTH-005" => :falsifier_killed,
    "SA2A-AUTH-006" => :falsifier_killed,
    "SA2A-AUTH-007" => :falsifier_killed,
    "SA2A-AUTH-008" => :positive_control_passed,
    "SA2A-AUTH-009" => :falsifier_killed,
    "SA2A-AUTH-010" => :falsifier_killed,
    "SA2A-AUTH-011" => :falsifier_killed,
    "SA2A-AUTH-012" => :falsifier_killed,
    "SA2A-AUTH-013" => :falsifier_killed,
    "SA2A-AUTH-014" => :falsifier_killed,
    "SA2A-AUTH-015" => :falsifier_killed,
    "SA2A-AUTH-016" => :falsifier_killed,
    # OPEN DEFECT (not repaired in this slice): grants are keyed on the
    # caller-supplied capability SELECTOR, not the canonical capability id,
    # so a grant for Probe's `actuate` authorizes Vault's `actuate`.
    "SA2A-AUTH-017" => :falsifier_survived,
    "SA2A-AUTH-018" => :positive_control_passed,
    "SA2A-AUTH-019" => :falsifier_killed
  }

  @grant_verdicts %{
    "SA2A-AUTH-GRANT-001" => :positive_control_passed,
    "SA2A-AUTH-GRANT-002" => :positive_control_passed,
    "SA2A-AUTH-GRANT-003" => :falsifier_killed,
    "SA2A-AUTH-GRANT-004" => :positive_control_passed,
    "SA2A-AUTH-GRANT-005" => :falsifier_killed,
    "SA2A-AUTH-GRANT-006" => :positive_control_passed,
    "SA2A-AUTH-GRANT-007" => :falsifier_killed,
    "SA2A-AUTH-GRANT-008" => :falsifier_killed,
    "SA2A-AUTH-GRANT-009" => :positive_control_passed,
    "SA2A-AUTH-GRANT-010" => :falsifier_killed,
    "SA2A-AUTH-GRANT-011" => :positive_control_passed
  }

  describe "end-to-end Chicago run" do
    test "both authority courts reach their final verdicts, every pass OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} =
               Runner.run(
                 courts: [AuthorityNonImplication, GrantLifecycle],
                 profile: :do,
                 evidence_dir: dir
               )

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      expected = Map.merge(@authority_verdicts, @grant_verdicts)

      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(expected))

      mismatches =
        for {id, verdict} <- Enum.sort(expected),
            result = by_id[id],
            result.verdict != verdict or result.ocel_corroborated? != true do
          "#{id}: expected #{verdict}, got #{result.verdict} " <>
            "(corroborated=#{inspect(result.ocel_corroborated?)}) -- #{result.detail} " <>
            "#{result.ocel_detail} #{inspect(result.evidence)}"
        end

      assert mismatches == [], Enum.join(mismatches, "\n\n")

      assert run.ocel.dropped == 0

      # Both courts declare the same authority mappings; the run must still
      # interpret each SUT event once (unique OCEL event ids).
      doc = JSON.decode!(File.read!(run.ocel.path))
      event_ids = Enum.map(doc["events"], & &1["id"])
      assert event_ids == Enum.uniq(event_ids)

      # The consumer answers from the durable artifact on disk.
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-AUTH-GRANT-008",
                 {:observed, "authority.broker.lookup", %{"outcome" => "unavailable"}}
               )

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-AUTH-GRANT-003",
                 {:observed, "authority.broker.lookup", %{"outcome" => "expired"}}
               )

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-AUTH-GRANT-007",
                 {:observed, "authority.broker.lookup", %{"outcome" => "revoked"}}
               )
    end
  end

  describe "declarations and discovery" do
    test "both courts are discoverable, :do profile, with §11-complete predicates" do
      for court <- [AuthorityNonImplication, GrantLifecycle] do
        assert court in Chicago.courts()
        assert court.profile() == :do
        assert court.gate() == nil

        for f <- court.falsifiers() do
          assert f.court_id == court.id()
          assert String.starts_with?(f.id, court.id() <> "-")
          assert f.attempt_predicate != nil, f.id
          assert f.outcome_predicate != nil, f.id
        end
      end

      assert AuthorityNonImplication.id() == "SA2A-AUTH"
      assert GrantLifecycle.id() == "SA2A-AUTH-GRANT"
    end

    test "the harness admits one mapping per authority activity" do
      mappings = AuthorityHarness.mappings(AuthorityNonImplication)
      assert length(mappings) == length(Enum.uniq_by(mappings, & &1.activity))

      assert AuthorityNonImplication.ocel_mappings() |> Enum.map(& &1.event) ==
               GrantLifecycle.ocel_mappings() |> Enum.map(& &1.event)
    end
  end

  describe "authority-boundary telemetry (narrow, real brokers)" do
    setup do
      name = :"#{__MODULE__}.Broker#{System.unique_integer([:positive])}"
      start_supervised!({InMemory, name: name})
      events = [:decision, [:broker, :lookup], [:grant, :issue], [:grant, :revoke]]
      handler = "authority-courts-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler,
        Enum.map(events, &([:ash_a2a, :authority] ++ List.wrap(&1))),
        &__MODULE__.forward/4,
        {test_pid, :telemetry}
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      %{broker: {InMemory, name: name}}
    end

    test "decisions name why they refused or granted", %{broker: broker} do
      subject = Identity.principal("telemetry-subject")

      assert Grant.authorize(nil, "cap", broker: broker) == nil

      assert_receive {:telemetry, [:ash_a2a, :authority, :decision],
                      %{outcome: :refused, reason: :unauthenticated}}

      assert Grant.authorize("telemetry-subject", "cap", broker: broker) == nil
      assert_receive {:telemetry, [:ash_a2a, :authority, :broker, :lookup], %{outcome: :absent}}

      assert_receive {:telemetry, [:ash_a2a, :authority, :decision],
                      %{outcome: :refused, reason: :no_standing_grant, capability_id: "cap"}}

      assert {:ok, %Authority{}} = Grant.grant(subject, "cap", broker: broker)
      assert_receive {:telemetry, [:ash_a2a, :authority, :grant, :issue], %{outcome: :issued}}

      assert %Authority{} =
               authority = Grant.authorize("telemetry-subject", "cap", broker: broker)

      assert authority.token_id.value == Authority.grant_token_id(subject, "cap")

      assert_receive {:telemetry, [:ash_a2a, :authority, :decision],
                      %{outcome: :granted, reason: :grant_standing, token_id: token}}

      assert token == authority.token_id.value

      assert :ok = Grant.revoke(subject, "cap", broker: broker)
      assert_receive {:telemetry, [:ash_a2a, :authority, :grant, :revoke], %{outcome: :revoked}}
      refute Grant.granted?(subject, "cap", broker: broker)
      assert_receive {:telemetry, [:ash_a2a, :authority, :broker, :lookup], %{outcome: :revoked}}
    end

    test "a stopped broker process is reported unavailable and refuses", %{
      broker: {_, opts} = broker
    } do
      subject = Identity.principal("outage-subject")
      assert {:ok, _} = Grant.grant(subject, "cap", broker: broker)
      assert Grant.granted?(subject, "cap", broker: broker)

      :ok = stop_supervised(InMemory)
      refute Process.whereis(opts[:name])

      refute Grant.granted?(subject, "cap", broker: broker)

      assert_receive {:telemetry, [:ash_a2a, :authority, :broker, :lookup],
                      %{outcome: :unavailable}}
    end

    test "the durable broker reports expired grants, and a stopped EKV refuses instead of raising" do
      unique = System.unique_integer([:positive])
      ekv = :"authority_courts_test_ekv_#{unique}"
      dir = Path.join(System.tmp_dir!(), "authority_courts_test_ekv_#{unique}")
      on_exit(fn -> File.rm_rf!(dir) end)
      start_supervised!({EKV, name: ekv, data_dir: dir, cluster_size: 1})
      broker = {Ekv, name: ekv}
      subject = Identity.principal("ekv-expiry")

      past = DateTime.add(DateTime.utc_now(), -1, :second)
      assert {:ok, _} = Grant.grant(subject, "cap", broker: broker, expires_at: past)
      refute Grant.granted?(subject, "cap", broker: broker)
      assert_receive {:telemetry, [:ash_a2a, :authority, :broker, :lookup], %{outcome: :expired}}

      standing = Identity.principal("ekv-standing")
      assert {:ok, _} = Grant.grant(standing, "cap", broker: broker)
      assert Grant.granted?(standing, "cap", broker: broker)

      # Before the SA2A-AUTH-GRANT-008 repair this raised ArgumentError
      # (EKV's reader connections live in :persistent_term, erased on stop).
      :ok = stop_supervised({EKV, ekv})
      refute Grant.granted?(standing, "cap", broker: broker)

      assert_receive {:telemetry, [:ash_a2a, :authority, :broker, :lookup],
                      %{outcome: :unavailable}}

      assert Grant.authorize("ekv-standing", "cap", broker: broker) == nil
    end
  end

  describe "transport identity guard" do
    test "a string-keyed a2a.auth (the only shape a JSON caller can forge) is unauthenticated" do
      name = AuthorityHarness.start_agent(AshA2A.Chicago.Fixtures.Authority.ProbeAgent)
      on_exit(fn -> AuthorityHarness.stop_agent(name) end)

      handler = "transport-guard-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ash_a2a, :authority, :decision],
        &__MODULE__.forward/4,
        {test_pid, :decision}
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      message = %{
        A2A.Message.new_user([A2A.Part.Data.new(%{"nonce" => "guard"})])
        | metadata: %{"skill" => "actuate"}
      }

      assert {:ok, task} =
               AshA2A.Chicago.Fixtures.Authority.ProbeAgent.call(name, message,
                 metadata: %{"a2a.auth" => %{"identity" => "someone-with-grants"}}
               )

      assert task.status.state == :failed

      assert_receive {:decision,
                      %{outcome: :refused, reason: :unauthenticated, authenticated: false}}
    end
  end

  describe "bounds delegation telemetry" do
    test "delegate emits delegated/refused and returns the unchanged result" do
      handler = "bounds-delegate-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ash_a2a, :semantic, :bounds, :delegate],
        &__MODULE__.forward/4,
        {test_pid, :delegate}
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, parent} = Bounds.new(fan_out: 1, depth: 2, parallelism: 1, capabilities: ["a", "b"])
      assert {:ok, %{child: child}} = Bounds.delegate(parent, capabilities: ["a"])
      assert_receive {:delegate, %{outcome: :delegated, requested_capabilities: "a"}}

      assert {:error, %{code: :bounds_delegation_not_narrowing}} =
               Bounds.delegate(child, capabilities: ["a", "b"])

      assert_receive {:delegate, %{outcome: :refused, code: :bounds_delegation_not_narrowing}}
    end
  end
end
