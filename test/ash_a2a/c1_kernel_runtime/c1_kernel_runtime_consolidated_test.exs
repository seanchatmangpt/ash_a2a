# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: c1_kernel_runtime
# Consolidated from 22 source files
# ==============================================================================


# ------------------------------------------------------------------------------
# Section 1: test/ash_a2a/c1_closure/certificate_strict_json_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Closure.CertificateStrictJsonTest do
  @moduledoc """
  Control-plane certificate decode refuses duplicate JSON object keys (last-wins /
  first-wins parser differentials let two verifiers read different certificates from one
  byte string). Real bytes, no doubles.
  """
  use ExUnit.Case, async: true

  alias AshA2A.C2.{Certificate, Wire}

  defp wire_map do
    %{
      "version" => 1,
      "effect_digest" => "sha256:" <> String.duplicate("a", 64),
      "principal" => "agent:alice",
      "policy_epoch" => 3,
      "revocation_epoch" => 0,
      "generation" => 1,
      "nonce" => "cert-nonce",
      "not_before_ms" => 1_800_000_000_000,
      "expires_at_ms" => 1_800_000_300_000,
      "audience" => "actuator:x",
      "threshold" => 1,
      "signatures" => [%{"signer" => "k1", "kid" => "k1", "signature" => "AAECAw"}]
    }
  end

  test "Certificate.decode/1 accepts a well-formed certificate JSON binary" do
    assert {:ok, %Certificate{threshold: 1, audience: "actuator:x"}} =
             Certificate.decode(Jason.encode!(wire_map()))
  end

  test "top-level duplicate key is refused (threshold 1 vs 0)" do
    json = ~s({"threshold":0,) <> String.trim_leading(Jason.encode!(wire_map()), "{")
    assert %{} = Jason.decode!(json)
    assert {:error, :duplicate_json_key} = Certificate.decode(json)
    assert {:error, :duplicate_json_key} = Wire.decode_certificate(json)
  end

  test "nested duplicate key inside a signature entry is refused" do
    json =
      String.replace(
        Jason.encode!(wire_map()),
        ~s("kid":"k1"),
        ~s("kid":"k1","kid":"evil")
      )

    assert {:error, :duplicate_json_key} = Certificate.decode(json)
  end

  test "malformed JSON and non-object roots are refused, maps still decode" do
    assert {:error, :invalid_certificate_wire} = Certificate.decode("{nope")
    assert {:error, :invalid_certificate_wire} = Certificate.decode("[1,2]")
    assert {:ok, %Certificate{}} = Certificate.decode(wire_map())
  end

  describe "RFC 8259 trailing whitespace only (space, tab, LF, CR)" do
    test "insignificant trailing whitespace is accepted" do
      json = Jason.encode!(wire_map())
      assert {:ok, %Certificate{}} = Certificate.decode(json <> " \t\r\n")
    end

    test "trailing non-JSON whitespace (NBSP, VT, FF, U+2003) is refused" do
      json = Jason.encode!(wire_map())

      for tail <- [<<0xC2, 0xA0>>, "\v", "\f", <<0xE2, 0x80, 0x83>>, "\0"] do
        assert {:error, :invalid_certificate_wire} = Certificate.decode(json <> tail),
               inspect(tail)

        assert {:error, :invalid_certificate_wire} = Wire.strict_json(~s({"a":1}) <> tail)
      end
    end
  end
end


# ------------------------------------------------------------------------------
# Section 2: test/ash_a2a/c1_closure/closure_court_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Closure.ClosureCourtTest do
  @moduledoc """
  Kernel-only DO closure court over the real compiled application (BEAM abstract code), plus
  anti-vacuity: a mutant module compiled to a real `.beam` that calls a DO entry directly must
  turn the court red. No doubles.
  """
  use ExUnit.Case, async: false

  alias AshA2A.Chicago.Fixtures.Brce.Ledger
  alias AshA2A.ConsequenceKernel.ClosureCourt
  alias AshA2A.ConsequenceKernel.Closure.Exceptions

  @moduletag timeout: 600_000

  defp mutant(name, body), do: mutant_named(Module.concat(AshA2A.C1Closure.Mutants, name), body)

  defp mutant_named(module, body) do
    dir = Path.join(System.tmp_dir!(), "c1_closure_mutants_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    previous = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    [{^module, bin}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        def go(msg), do: #{body}
      end
      """)

    Code.put_compiler_option(:debug_info, previous)
    path = Path.join(dir, "#{module}.beam")
    File.write!(path, bin)
    {:module, ^module} = :code.load_binary(module, String.to_charlist(path), bin)
    on_exit(fn -> File.rm_rf(dir) end)
    module
  end

  @core [
    AshA2A.Agent,
    AshA2A.CommandBus,
    AshA2A.Dispatcher,
    AshA2A.ConsequenceKernel.Dispatch.Inversion
  ]

  describe "whole application" do
    test "report/0 has zero violating edges and every exception is observed" do
      report = ClosureCourt.report()
      assert report.violating_edges == [], inspect(report.violating_edges, limit: 20)
      assert report.verdict == "closed"
      assert report.sole_path == "AshA2A.ConsequenceKernel.Runtime.Pipeline"
      assert report.kernel_gateways == ["AshA2A.ConsequenceKernel.Dispatch.Inversion.execute/2"]
      assert length(report.typed_exceptions) >= length(Exceptions.edges())
    end

    test "c1.closure_report conformance check passes on the real court" do
      assert {:pass, _} = AshA2A.SA2A.Conformance.Checks.C1.closure_report(%{})
    end

    test "every typed exception names an existing court file" do
      for exc <- Exceptions.edges() ++ Exceptions.dynamic_sites() do
        assert File.exists?(exc.court), "#{exc.id}: missing court #{exc.court}"
      end
    end

    test "CommandBus has no direct Dispatcher edge (routes through the kernel inversion)" do
      report = ClosureCourt.report(modules: [AshA2A.CommandBus])
      refute Enum.any?(report.violating_edges, &(&1[:callee] =~ "AshA2A.Dispatcher"))
    end
  end

  describe "anti-vacuity mutations" do
    test "a direct Dispatcher.dispatch from a random module is a violating edge" do
      m = mutant("DirectDispatch", "AshA2A.Dispatcher.dispatch(:record, msg, Elixir.Nope)")
      report = ClosureCourt.report(modules: @core, extra_modules: [m])
      assert report.verdict == "violations"

      assert Enum.any?(report.violating_edges, fn e ->
               e[:caller] == "#{inspect(m)}.go/1" and e[:callee] =~ "Dispatcher.dispatch/3"
             end)
    end

    test "a direct dispatch_observe, BrceAnchor.put, C2 actuator and Ash write are each caught" do
      for {name, body, callee} <- [
            {"Observe", "AshA2A.Dispatcher.dispatch_observe(:x, msg, Nope)", "dispatch_observe"},
            {"Anchor", "AshA2A.BrceAnchor.put(msg)", "BrceAnchor.put"},
            {"C2", "AshA2A.C2.Actuator.execute(msg, msg, msg, msg, msg)", "C2.Actuator.execute"},
            {"Ash", "Ash.create(msg)", "Ash.create"}
          ] do
        m = mutant(name, body)
        report = ClosureCourt.report(modules: @core, extra_modules: [m])
        assert report.verdict == "violations", name
        assert Enum.any?(report.violating_edges, &((&1[:callee] || "") =~ callee)), name
      end
    end

    test "a function reference to the entry point is an edge" do
      m = mutant("FunRef", "&AshA2A.Dispatcher.dispatch/3")
      report = ClosureCourt.report(modules: @core, extra_modules: [m])
      assert report.verdict == "violations"
    end

    test "a module without debug info cannot hide an edge: it is a violation, not skipped" do
      module = Module.concat(AshA2A.C1Closure.Mutants, "NoDebug")
      previous = Code.get_compiler_option(:debug_info)
      Code.put_compiler_option(:debug_info, false)

      [{^module, bin}] =
        Code.compile_string(
          "defmodule #{inspect(module)} do\n def go(m), do: AshA2A.Dispatcher.dispatch(:x, m, N)\nend"
        )

      Code.put_compiler_option(:debug_info, previous)
      dir = Path.join(System.tmp_dir!(), "c1_nodebug_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "#{module}.beam")
      File.write!(path, bin)
      {:module, ^module} = :code.load_binary(module, String.to_charlist(path), bin)
      on_exit(fn -> File.rm_rf(dir) end)

      report = ClosureCourt.report(modules: @core, extra_modules: [module])
      assert Enum.any?(report.violating_edges, &(&1.violation == "unanalyzable_module"))
    end

    test "a stale exception is a violation (dead exceptions cannot stay listed)" do
      report = ClosureCourt.report(modules: [AshA2A.C2.Actuator], stale_check: true)
      assert Enum.any?(report.violating_edges, &(&1.violation == "stale_exception"))
    end

    test "removing the mutant restores the closed verdict on the same module set" do
      report = ClosureCourt.report(modules: @core)
      assert report.violating_edges == []
    end
  end

  describe "prefix exemptions are not blanket trust (D1/D2/D3)" do
    @do_bodies [
      {"C2Actuator", "AshA2A.C2.Actuator.execute(msg, msg, msg, msg, msg)"},
      {"Anchor", "AshA2A.BrceAnchor.put(msg)"},
      {"AshWrite", "Ash.create(msg)"},
      {"Dispatch", "AshA2A.Dispatcher.dispatch(:x, msg, N)"}
    ]

    test "a module under the AshA2A.ConsequenceKernel prefix is not exempt from any DO entry" do
      for {name, body} <- @do_bodies do
        m = mutant_named(Module.concat(AshA2A.ConsequenceKernel, "Evil" <> name), body)
        report = ClosureCourt.report(modules: @core, extra_modules: [m])
        assert report.verdict == "violations", name
        assert Enum.any?(report.violating_edges, &(&1[:caller] == "#{inspect(m)}.go/1")), name
      end
    end

    test "the pinned gateway alone is still the kernel's only Dispatcher caller" do
      report = ClosureCourt.report(modules: @core)
      assert report.violating_edges == []
      assert report.kernel_gateways == ["AshA2A.ConsequenceKernel.Dispatch.Inversion.execute/2"]
    end

    test "a non-resource module under a fixture prefix cannot perform an Ash effect" do
      for prefix <- [
            AshA2A.Chicago.Fixtures,
            AshA2A.Test.Fixture,
            AshA2A.ArchitectureVerifier.Fixture
          ] do
        m = mutant_named(Module.concat(prefix, "EvilD"), "Ash.create(msg)")
        report = ClosureCourt.report(modules: @core, extra_modules: [m])
        assert report.verdict == "violations", inspect(prefix)
        assert Enum.any?(report.violating_edges, &(&1[:caller] == "#{inspect(m)}.go/1"))
      end
    end

    test "a dynamic call to a DO entry from any module is a violation" do
      for {name, body} <- [
            {"DynDispatch",
             ~s|(fn m -> m.dispatch(:x, msg, N) end).(Module.concat(["AshA2A", "Dispatcher"]))|},
            {"DynExecute", ~s|(fn m -> m.execute(msg, msg, msg, msg, msg) end).(msg)|},
            {"DynApply", ~s|apply(msg, :whatever, [msg])|}
          ] do
        m = mutant_named(Module.concat(AshA2A.Evil, name), body)
        report = ClosureCourt.report(modules: @core, extra_modules: [m])
        assert report.verdict == "violations", name

        assert Enum.any?(
                 report.violating_edges,
                 &(&1[:caller] == "#{inspect(m)}.go/1" and
                     &1.violation == "unlisted_dynamic_site_in_do_adjacent_module")
               ),
               name
      end
    end

    test "a dynamic call with a non-DO function name from an unrelated module is not flagged" do
      m =
        mutant_named(Module.concat(AshA2A.Evil, "DynBenign"), "(fn m -> m.render(msg) end).(msg)")

      report = ClosureCourt.report(modules: @core, extra_modules: [m])
      assert report.verdict == "closed"
    end
  end

  describe "legacy observe path stays fenced" do
    test "dispatch_observe refuses a consequence-bearing skill and performs no effect" do
      label = "c1-observe-#{System.unique_integer([:positive])}"

      msg = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"label" => label})])

      assert {:error, _} = AshA2A.Dispatcher.dispatch_observe(:record, msg, Ledger)
      refute label in AshA2A.Chicago.Fixtures.Brce.ledger_labels()
    end
  end
end


# ------------------------------------------------------------------------------
# Section 3: test/ash_a2a/c1_kernel_runtime/applying_before_do_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.ApplyingBeforeDoTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/applying_before_do.json",
            __DIR__
          )
  test "applying_before_do portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 4: test/ash_a2a/c1_kernel_runtime/authority_before_apply_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.AuthorityBeforeApplyTest do
  @moduledoc """
  `authority_before_apply` is a same-state step (claimed -> claimed): authority revalidation
  happens while the record is claimed and changes nothing, so `Transition.admit/2` (which
  refuses self-loops, as the refusal vectors require) is not its oracle. It is asserted
  through the real store and stages: the record is `claimed` before and after a successful
  revalidation, and only then may it move to `applying`.
  """
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Memory

  alias AshA2A.ConsequenceKernel.Runtime.{
    ApplyingStage,
    AuthorityStage,
    ClaimStage,
    PrepareStage,
    StoreHandle
  }

  defmodule Auth do
    def revalidate("p", _), do: :ok
    def revalidate(_, _), do: {:error, :authority_revoked}
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/authority_before_apply.json",
            __DIR__
          )
  test "authority_before_apply portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
    assert v["decision"] == "admit" and v["from"] == v["to"]

    {:ok, store} = Memory.start_link()
    handle = StoreHandle.new(Memory, store)
    p = %{prepared_digest: "sha256:auth", instance: %{request_id: "r", effect_id: "e"}}
    :ok = PrepareStage.run(handle, p)
    :ok = ClaimStage.run(handle, p, self())

    assert {:ok, %{state: state}} = Memory.fetch(store, p.prepared_digest)
    assert Atom.to_string(state) == v["from"]
    assert :ok = AuthorityStage.run(Auth, "p", p)
    assert {:ok, %{state: ^state}} = Memory.fetch(store, p.prepared_digest)
    assert {:error, :authority_revoked} = AuthorityStage.run(Auth, "q", p)
    assert {:ok, %{state: ^state}} = Memory.fetch(store, p.prepared_digest)
    assert :ok = ApplyingStage.run(handle, p)
  end
end


# ------------------------------------------------------------------------------
# Section 5: test/ash_a2a/c1_kernel_runtime/authority_refusal_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.AuthorityRefusalTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/authority_refusal.json",
            __DIR__
          )
  test "authority_refusal portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 6: test/ash_a2a/c1_kernel_runtime/claims_independent_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.ClaimsIndependentTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/claims_independent.json",
            __DIR__
          )
  test "claims_independent portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 7: test/ash_a2a/c1_kernel_runtime/class_refusal_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.ClassRefusalTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand("../../../priv/sa2a/c1/kernel_runtime_vectors/class_refusal.json", __DIR__)
  test "class_refusal portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 8: test/ash_a2a/c1_kernel_runtime/compensate_unknown_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.CompensateUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/compensate_unknown.json",
            __DIR__
          )
  test "compensate_unknown portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 9: test/ash_a2a/c1_kernel_runtime/double_effect_claim_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.DoubleEffectClaimTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/double_effect_claim.json",
            __DIR__
          )
  test "double_effect_claim portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 10: test/ash_a2a/c1_kernel_runtime/duplicate_prepare_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.DuplicatePrepareTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/duplicate_prepare.json",
            __DIR__
          )
  test "duplicate_prepare portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 11: test/ash_a2a/c1_kernel_runtime/effect_claim_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.EffectClaimTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand("../../../priv/sa2a/c1/kernel_runtime_vectors/effect_claim.json", __DIR__)
  test "effect_claim portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 12: test/ash_a2a/c1_kernel_runtime/error_unknown_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.ErrorUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand("../../../priv/sa2a/c1/kernel_runtime_vectors/error_unknown.json", __DIR__)
  test "error_unknown portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 13: test/ash_a2a/c1_kernel_runtime/prepare_persists_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.PreparePersistsTest do
  @moduledoc """
  `prepare_persists` is a same-state step (prepared -> prepared): persisting the prepared record
  is not a state transition, so `Transition.admit/2` (which refuses self-loops, as
  `duplicate_prepare` requires) cannot be its oracle. It is asserted through the real store:
  the record persists in the vector's state, and a second put of the same digest is refused.
  """
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Memory
  alias AshA2A.ConsequenceKernel.Runtime.{PrepareStage, StoreHandle}

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/prepare_persists.json",
            __DIR__
          )
  test "prepare_persists portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
    assert v["decision"] == "admit" and v["from"] == v["to"]

    {:ok, store} = Memory.start_link()
    handle = StoreHandle.new(Memory, store)
    p = %{prepared_digest: "sha256:prep", instance: %{request_id: "r", effect_id: "e"}}

    assert :ok = PrepareStage.run(handle, p)
    assert {:ok, %{state: state, prepared: ^p}} = Memory.fetch(store, p.prepared_digest)
    assert Atom.to_string(state) == v["from"]
    assert {:error, :prepared_duplicate} = PrepareStage.run(handle, p)
  end
end


# ------------------------------------------------------------------------------
# Section 14: test/ash_a2a/c1_kernel_runtime/reconcile_unknown_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.ReconcileUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/reconcile_unknown.json",
            __DIR__
          )
  test "reconcile_unknown portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 15: test/ash_a2a/c1_kernel_runtime/release_applying_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.ReleaseApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/release_applying.json",
            __DIR__
          )
  test "release_applying portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 16: test/ash_a2a/c1_kernel_runtime/release_claimed_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.ReleaseClaimedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/release_claimed.json",
            __DIR__
          )
  test "release_claimed portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 17: test/ash_a2a/c1_kernel_runtime/release_prepared_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.ReleasePreparedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/release_prepared.json",
            __DIR__
          )
  test "release_prepared portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 18: test/ash_a2a/c1_kernel_runtime/request_claim_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.RequestClaimTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand("../../../priv/sa2a/c1/kernel_runtime_vectors/request_claim.json", __DIR__)
  test "request_claim portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 19: test/ash_a2a/c1_kernel_runtime/retry_unknown_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.RetryUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand("../../../priv/sa2a/c1/kernel_runtime_vectors/retry_unknown.json", __DIR__)
  test "retry_unknown portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 20: test/ash_a2a/c1_kernel_runtime/success_completed_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.SuccessCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/success_completed.json",
            __DIR__
          )
  test "success_completed portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 21: test/ash_a2a/c1_kernel_runtime/token_exact_subject_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.TokenExactSubjectTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/token_exact_subject.json",
            __DIR__
          )
  test "token_exact_subject portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end


# ------------------------------------------------------------------------------
# Section 22: test/ash_a2a/c1_kernel_runtime/unknown_persisted_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1KernelRuntime.UnknownPersistedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/unknown_persisted.json",
            __DIR__
          )
  test "unknown_persisted portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end
