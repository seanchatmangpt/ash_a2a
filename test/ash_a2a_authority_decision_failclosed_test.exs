defmodule AshA2A.AuthorityDecisionFailClosedTest do
  @moduledoc """
  Regression court for three REPRODUCED fail-OPEN defects in the SA2A
  authority decision rule (RFC-SA2A-001 S28, S29, S54, S60).

  All three were reproduced before being fixed, on both hosts, with the real
  actuator really firing. The exact minimal reproducing inputs are preserved
  verbatim in `test/support/hosts/authority_decision_conformance.json` under
  the `REPRO-` names, together with the ADMITTED verdict each produced before
  the fix:

    1. **Absence bound.** `binds?/2` compared fields with `==`, so an
       authority object with *no* fields bound to an envelope with *no*
       principal -- `nil == nil` on the BEAM, `undefined === undefined` in
       Node. Minimal input: `{"consequence":"external_do","authority":{}}`.
       Both hosts returned ADMITTED and the Node host's real actuator wrote
       a real line to a real file.

    2. **The caller classified its own action.** Declaring
       `"consequence":"observe"` skipped the authority branch entirely. The
       real enforcement point, `AshA2A.CommandBus.run/4`, takes the
       classification from the resource DSL (`AshA2A.Info.skill/2`'s
       `skill.consequence`) and never from the request, so the portable
       evaluator was strictly *more permissive* than the boundary it claims
       to mirror.

    3. **The constrained party picked the clock.** Expiry was judged against
       `"evaluated_at"` carried inside the message being judged, so an
       authority that expired in the year 2000 was admitted by an envelope
       claiming to have been evaluated in 1999.

  ## Real collaborators only

  The Node host is a real separate OS process sharing no code with ash_a2a,
  and its actuator is a real file append on a real filesystem. Every "did not
  actuate" assertion below is paired with a positive control in the same run
  (the conformance spec's own ADMITTED cases really do write lines), so no
  count-zero assertion here is vacuous. No mocks, no stubs, no doubles.

  ## One specification, two hosts

  The BEAM rule (`AshA2A.Authority.Decision.verdict/1`) and the Node rule
  (`test/support/hosts/authority_host.mjs`) are independent implementations.
  They cannot be *made* identical without generating one from the other
  across the BEAM/Node boundary, so they are instead *pinned* identical: the
  conformance vector file is the single specification, both hosts execute
  every case in it, and this suite asserts BEAM == expected, node == expected
  and BEAM == node. Drift between the two rules is therefore a test failure
  rather than a silent divergence -- which is exactly how this defect class
  got mirrored verbatim across both hosts in the first place.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.{Authority, Command, Identity}
  alias AshA2A.Authority.Decision
  alias AshA2A.Test.Fixture.AuthorityProbe

  # `AshA2A.Authority.Decision`'s own `@doc` examples were never wired into
  # ExUnit by any module, so the `canonical_json/1` example shipped unexecuted.
  # They run here, including the `verdict/1` example that is the primary
  # fail-open repro in miniature.
  doctest AshA2A.Authority.Decision

  @host_script Path.expand("support/hosts/authority_host.mjs", __DIR__)
  @conformance_spec Path.expand("support/hosts/authority_decision_conformance.json", __DIR__)

  @actuate "AshA2A.Test.Fixture.AuthorityProbe.actuate"
  @peek "AshA2A.Test.Fixture.AuthorityProbe.peek"

  setup do
    dir = Path.join(System.tmp_dir!(), "sa2a-failclosed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, actuator_log: Path.join(dir, "independent_host_actuations.log")}
  end

  defp require_node! do
    unless match?({_out, 0}, System.cmd("node", ["--version"], stderr_to_stdout: true)) do
      # A named, visible failure -- never a silent substitution of a fake host.
      flunk("node is not available on this machine; the independent host cannot be exercised")
    end
  rescue
    ErlangError ->
      flunk("node is not available on this machine; the independent host cannot be exercised")
  end

  defp spec, do: @conformance_spec |> File.read!() |> JSON.decode!()

  defp repro_case(name) do
    spec()
    |> Map.fetch!("cases")
    |> Enum.find(&String.starts_with?(&1["name"], name))
    |> case do
      nil -> flunk("conformance spec has no case named #{name}")
      found -> found
    end
  end

  defp run_node_host(envelope, dir, actuator_log, label) do
    path = Path.join(dir, "envelope-#{label}.json")
    File.write!(path, Decision.canonical_json(envelope))

    {out, 0} = System.cmd("node", [@host_script, path, actuator_log], stderr_to_stdout: true)
    JSON.decode!(String.trim(out))
  end

  # ------------------------------------------------------------------
  # The three reproduced defects, each by its exact minimal input.
  # ------------------------------------------------------------------

  describe "DEFECT 1: absence must never bind" do
    test "the verifier's exact minimal input -- an authority with no fields against an envelope with no principal -- is REFUSED on both hosts and actuates nothing",
         %{dir: dir, actuator_log: actuator_log} do
      require_node!()

      %{"envelope" => envelope, "expect" => expect} = repro_case("REPRO-1 ")

      # This is literally `%{"consequence" => "external_do", "authority" => %{}}`
      # plus the version header. Before the fix: {:admitted, ...} and one real
      # actuator call.
      assert envelope["authority"] == %{}
      refute Map.has_key?(envelope, "principal")

      assert {:refused, %{code: :envelope_incomplete}} = Decision.verdict(envelope)

      result = run_node_host(envelope, dir, actuator_log, "d1")
      assert result["verdict"] == expect["verdict"]
      assert result["code"] == expect["code"]
      assert result["actuator_calls"] == 0
      refute File.exists?(actuator_log)
    end

    test "a blank-string principal and subject are absence with punctuation, not a match", %{
      dir: dir,
      actuator_log: actuator_log
    } do
      require_node!()

      %{"envelope" => envelope} = repro_case("REPRO-1c")
      assert String.trim(envelope["principal"]) == ""
      assert envelope["principal"] == envelope["authority"]["subject"]

      assert {:refused, %{code: :envelope_incomplete}} = Decision.verdict(envelope)
      assert run_node_host(envelope, dir, actuator_log, "d1c")["actuator_calls"] == 0
      refute File.exists?(actuator_log)
    end

    test "binds?/2 and expired?/2 now fail closed the SAME way on missing input", %{
      dir: dir,
      actuator_log: actuator_log
    } do
      require_node!()

      # `expired?` always failed closed on unparseable input; `binds?` failed
      # OPEN on missing input. The two are now consistent: both closed.
      for name <- ["REPRO-3b", "REPRO-3c", "unparseable expires_at"] do
        %{"envelope" => envelope, "expect" => expect} = repro_case(name)

        assert {:refused, %{code: :authority_mismatch}} = Decision.verdict(envelope),
               "#{name} must fail closed on the BEAM"

        result = run_node_host(envelope, dir, actuator_log, "closed-#{:erlang.phash2(name)}")
        assert result["code"] == expect["code"], "#{name} must fail closed on the node host"
        assert result["actuator_calls"] == 0
      end

      refute File.exists?(actuator_log)
    end
  end

  describe "DEFECT 2: the caller does not classify its own action" do
    test "the verifier's exact minimal input -- declaring observe on a consequence-bearing capability -- no longer skips the authority branch on either host",
         %{dir: dir, actuator_log: actuator_log} do
      require_node!()

      %{"envelope" => envelope, "expect" => expect} = repro_case("REPRO-2 ")

      assert envelope["consequence"] == "observe"
      assert envelope["authority"] == nil
      refute Map.has_key?(envelope, "capability_consequence")

      assert {:refused, %{code: :consequence_unattested}} = Decision.verdict(envelope)

      result = run_node_host(envelope, dir, actuator_log, "d2")
      assert result["verdict"] == expect["verdict"]
      assert result["code"] == expect["code"]
      assert result["actuator_calls"] == 0
      refute File.exists?(actuator_log)
    end

    test "a declared consequence that contradicts the DSL attestation is refused", %{
      dir: dir,
      actuator_log: actuator_log
    } do
      require_node!()

      %{"envelope" => envelope} = repro_case("REPRO-2b")
      assert envelope["consequence"] == "observe"
      assert envelope["capability_consequence"] == "external_do"

      assert {:refused, %{code: :consequence_unattested}} = Decision.verdict(envelope)
      assert run_node_host(envelope, dir, actuator_log, "d2b")["actuator_calls"] == 0
      refute File.exists?(actuator_log)
    end

    test "envelope/3 reads the consequence off the REAL resource DSL, exactly as CommandBus does" do
      principal = Identity.principal("operator-1")

      actuate_cmd =
        Command.new(@actuate, command_id: "attest-1", agent_id: "a", principal_id: principal)

      peek_cmd =
        Command.new(@peek, command_id: "attest-2", agent_id: "a", principal_id: principal)

      # The same values the real bus reads through AshA2A.Info.skill/2.
      assert {:ok, %{consequence: :external_do}} = AshA2A.Info.skill(AuthorityProbe, @actuate)
      assert {:ok, %{consequence: :observe}} = AshA2A.Info.skill(AuthorityProbe, @peek)

      attested_actuate = Decision.envelope(actuate_cmd, AuthorityProbe)
      attested_peek = Decision.envelope(peek_cmd, AuthorityProbe)

      assert attested_actuate["consequence"] == "external_do"
      assert attested_actuate["capability_consequence"] == "external_do"
      assert attested_peek["consequence"] == "observe"
      assert attested_peek["capability_consequence"] == "observe"

      # An attested external_do with no authority is refused for the real
      # reason, not misclassified away.
      assert {:refused, %{code: :authority_required}} = Decision.verdict(attested_actuate)
      # An attested observe needs no authority -- mirroring the bus.
      assert {:admitted, _} = Decision.verdict(attested_peek)

      # And a caller rewriting the declared consequence cannot undo the
      # attestation that came off the resource.
      forged = Map.put(attested_actuate, "consequence", "observe")
      assert {:refused, %{code: :consequence_unattested}} = Decision.verdict(forged)
    end

    test "an unresolvable capability produces no classification at all, and fails closed" do
      cmd =
        Command.new("AshA2A.Test.Fixture.AuthorityProbe.does_not_exist",
          command_id: "attest-3",
          agent_id: "a",
          principal_id: Identity.principal("operator-1")
        )

      envelope = Decision.envelope(cmd, AuthorityProbe)

      assert envelope["consequence"] == nil
      assert envelope["capability_consequence"] == nil
      assert {:refused, %{code: :consequence_unclassified}} = Decision.verdict(envelope)
    end
  end

  describe "DEFECT 3: the constrained party does not pick the clock" do
    test "the verifier's exact minimal input -- an authority expired in 2000 presented with evaluated_at in 1999 -- is REFUSED on both hosts",
         %{dir: dir, actuator_log: actuator_log} do
      require_node!()

      %{"envelope" => envelope, "expect" => expect} = repro_case("REPRO-3 ")

      assert envelope["evaluated_at"] == "1999-01-01T00:00:00Z"
      assert envelope["authority"]["expires_at"] == "2000-01-01T00:00:00Z"
      # The binding itself is perfect; only the clock was doctored.
      assert envelope["authority"]["subject"] == envelope["principal"]
      assert envelope["authority"]["capability_id"] == envelope["capability_id"]

      assert {:refused, %{code: :authority_mismatch}} = Decision.verdict(envelope)

      result = run_node_host(envelope, dir, actuator_log, "d3")
      assert result["verdict"] == expect["verdict"]
      assert result["code"] == expect["code"]
      assert result["actuator_calls"] == 0
      refute File.exists?(actuator_log)
    end

    test "expiry is judged against real host time, matching AshA2A.Authority.expired?/1" do
      principal = Identity.principal("operator-1")

      expired =
        Authority.new(principal, @actuate,
          token_id: "expired",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      live =
        Authority.new(principal, @actuate,
          token_id: "live",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      # The real struct-level rule this portable rule now mirrors.
      assert Authority.expired?(expired)
      refute Authority.expired?(live)

      for {authority, expected} <- [{expired, :refused}, {live, :admitted}] do
        cmd =
          Command.new(@actuate,
            command_id: "clock-#{authority.token_id.value}",
            agent_id: "a",
            principal_id: principal,
            authority: authority
          )

        # Even when the caller names an instant comfortably before expiry,
        # the host's own clock decides.
        envelope =
          Decision.envelope(cmd, AuthorityProbe,
            evaluated_at: DateTime.add(DateTime.utc_now(), -86_400, :second)
          )

        case expected do
          :refused -> assert {:refused, %{code: :authority_mismatch}} = Decision.verdict(envelope)
          :admitted -> assert {:admitted, _} = Decision.verdict(envelope)
        end
      end
    end

    test "a caller's own evaluated_at can still close the gate, never hold it open" do
      principal = Identity.principal("operator-1")

      cmd =
        Command.new(@actuate,
          command_id: "clock-self-close",
          agent_id: "a",
          principal_id: principal,
          authority:
            Authority.new(principal, @actuate,
              token_id: "future",
              expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
            )
        )

      assert {:admitted, _} = Decision.verdict(Decision.envelope(cmd, AuthorityProbe))

      # Declaring an instant AFTER expiry is an admission against interest and
      # is honoured: max(host_now, evaluated_at) decides.
      self_closed =
        Decision.envelope(cmd, AuthorityProbe,
          evaluated_at: DateTime.add(DateTime.utc_now(), 7200, :second)
        )

      assert {:refused, %{code: :authority_mismatch}} = Decision.verdict(self_closed)
    end
  end

  # ------------------------------------------------------------------
  # The anti-drift pin: one specification, executed by both hosts.
  # ------------------------------------------------------------------

  describe "the two hosts are pinned to one shared specification" do
    test "every conformance case yields the same typed verdict on the BEAM and on the independent node host, and the node host's real actuator fires exactly on the ADMITTED cases",
         %{actuator_log: actuator_log} do
      require_node!()

      cases = Map.fetch!(spec(), "cases")
      assert length(cases) >= 19

      {out, 0} =
        System.cmd("node", [@host_script, "--spec", @conformance_spec, actuator_log],
          stderr_to_stdout: true
        )

      node_results =
        out
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)
        |> Map.new(&{&1["name"], &1})

      assert map_size(node_results) == length(cases)

      for %{"name" => name, "envelope" => envelope, "expect" => expect} <- cases do
        beam =
          case Decision.verdict(envelope) do
            {:admitted, %{code: code}} ->
              %{"verdict" => "ADMITTED", "code" => to_string(code)}

            {:refused, %{code: code}} ->
              %{"verdict" => "REFUSED_AUTHORITY", "code" => to_string(code)}
          end

        node = Map.fetch!(node_results, name)

        assert beam == expect, "BEAM disagrees with the specification for #{inspect(name)}"

        assert %{"verdict" => beam["verdict"], "code" => beam["code"]} ==
                 %{"verdict" => node["verdict"], "code" => node["code"]},
               "the two hosts have drifted apart for #{inspect(name)}"
      end

      admitted = Enum.count(cases, &(&1["expect"]["verdict"] == "ADMITTED"))
      assert admitted >= 3, "the spec must contain positive controls, or every zero is vacuous"

      # The real actuator, on a real filesystem: exactly the ADMITTED cases
      # wrote, and nothing else did.
      lines = actuator_log |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == admitted

      refused_capabilities =
        cases
        |> Enum.reject(&(&1["expect"]["verdict"] == "ADMITTED"))
        |> Enum.map(&get_in(&1, ["envelope", "capability_id"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(fn capability ->
          Enum.any?(cases, fn c ->
            c["expect"]["verdict"] == "ADMITTED" and c["envelope"]["capability_id"] == capability
          end)
        end)

      for capability <- refused_capabilities do
        refute File.read!(actuator_log) =~ capability
      end
    end

    test "the specification preserves the pre-fix ADMITTED verdicts it was written to refute" do
      repros =
        spec()
        |> Map.fetch!("cases")
        |> Enum.filter(&Map.has_key?(&1, "was_before_fix"))

      # One per reproduced defect, each recording what it used to do.
      assert length(repros) == 3

      for repro <- repros do
        assert repro["was_before_fix"] == "ADMITTED, actuator_calls 1"
        assert repro["expect"]["verdict"] == "REFUSED_AUTHORITY"
      end
    end
  end
end
