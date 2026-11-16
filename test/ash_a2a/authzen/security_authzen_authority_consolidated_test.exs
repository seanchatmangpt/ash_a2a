# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Security, AuthZEN & Authority
# Contains 20 original test files:
#   - test/ash_a2a/authority/allow_all_guard_test.exs
#   - test/ash_a2a/authority/dispatch_hooks_test.exs
#   - test/ash_a2a/authority/security_preflight_test.exs
#   - test/ash_a2a/authzen/absorption_test.exs
#   - test/ash_a2a/authzen/authority_policy_test.exs
#   - test/ash_a2a/authzen/chicago_canonical_examples_test.exs
#   - test/ash_a2a/authzen/decision_gate_test.exs
#   - test/ash_a2a/authzen/metadata_test.exs
#   - test/ash_a2a/authzen/projection_test.exs
#   - test/ash_a2a/authzen/search_binding_test.exs
#   - test/ash_a2a/cs2/cs2_contract_test.exs
#   - test/ash_a2a/identity/canonical_errata_test.exs
#   - test/ash_a2a/security_profile/boot_durable_stores_test.exs
#   - test/ash_a2a/security_profile/boot_test.exs
#   - test/ash_a2a/security_profile/security_profile_test.exs
#   - test/ash_a2a/spiffe/identity_test.exs
#   - test/ash_a2a/spiffe/pdp_binding_test.exs
#   - test/authority/graph_pin_test.exs
#   - test/authority/pep_hardening_test.exs
#   - test/authority/pep_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/authority/allow_all_guard_test.exs ---
defmodule AshA2A.Authority.AllowAllGuardTest do
  use ExUnit.Case, async: false

  alias AshA2A.Authority.Source.AllowAll

  test "prod env is denied, other envs allowed" do
    assert {:deny, :allow_all_in_prod} = AllowAll.__check__(:prod, "a", :x, %{}, [])
    assert :ok = AllowAll.__check__(:test, "a", :x, %{}, [])
  end

  test "runtime release marker denies even in a non-prod compile" do
    old = System.get_env("RELEASE_NAME")
    System.put_env("RELEASE_NAME", "ash_a2a")

    on_exit(fn ->
      if old, do: System.put_env("RELEASE_NAME", old), else: System.delete_env("RELEASE_NAME")
    end)

    assert {:deny, :allow_all_in_prod} = AllowAll.check("a", :x, %{}, [])
  end
end

# --- SECTION 2: Original test/ash_a2a/authority/dispatch_hooks_test.exs ---
defmodule AshA2A.DispatchHooksFixtures.Item do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.DispatchHooksFixtures.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :ping, :string do
      run(fn _input, _context -> {:ok, "pong"} end)
    end
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end

  a2a do
    skill(:ping, :ping, consequence: :observe)
  end

  authority do
    gate(:disabled)
  end

  hooks do
    pre_dispatch([:pre_hook])
    post_dispatch([:post_hook])
  end
end

defmodule AshA2A.DispatchHooksFixtures.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DispatchHooksFixtures.Item)
  end
end

defmodule AshA2A.DispatchHooksFixtures.Hooks do
  @moduledoc false
  def pre(event), do: relay(:pre, event)
  def post(event), do: relay(:post, event)
  def deny(_event), do: {:error, :nope}

  defp relay(tag, event) do
    send(:dispatch_hooks_sink, {tag, event.phase, event.skill_id})
    :ok
  end
end

defmodule AshA2A.DispatchHooksTest do
  use ExUnit.Case, async: false

  alias AshA2A.DispatchHooksFixtures.{Hooks, Item}

  setup do
    Process.register(self(), :dispatch_hooks_sink)
    old = Application.get_env(:ash_a2a, :dispatch_hooks)

    on_exit(fn ->
      if old,
        do: Application.put_env(:ash_a2a, :dispatch_hooks, old),
        else: Application.delete_env(:ash_a2a, :dispatch_hooks)
    end)

    :ok
  end

  defp msg, do: AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

  test "gate and both hooks are read by the dispatcher and fire" do
    assert AshA2A.Info.authority_gate(Item) == :disabled

    Application.put_env(:ash_a2a, :dispatch_hooks, %{
      pre_hook: {Hooks, :pre},
      post_hook: {Hooks, :post}
    })

    assert {:reply, _} = AshA2A.Dispatcher.dispatch(:ping, msg(), Item)
    assert_received {:pre, :pre_dispatch, _}
    assert_received {:post, :post_dispatch, _}
  end

  test "pre hook denial refuses before execution; unresolved hook fails closed" do
    Application.put_env(:ash_a2a, :dispatch_hooks, %{
      pre_hook: {Hooks, :deny},
      post_hook: {Hooks, :post}
    })

    assert {:error, {:pre_dispatch_hook, {:pre_hook, :nope}}} =
             AshA2A.Dispatcher.dispatch(:ping, msg(), Item)

    refute_received {:post, _, _}

    Application.delete_env(:ash_a2a, :dispatch_hooks)

    assert {:error, {:pre_dispatch_hook, {:pre_hook, :hook_unresolved}}} =
             AshA2A.Dispatcher.dispatch(:ping, msg(), Item)
  end
end

defmodule AshA2A.DisabledGateTopologyTest do
  use ExUnit.Case, async: false

  # gate(:disabled) is enforced at compile time for exposed :change/:external_do skills
  # (AshA2A.Verify topology) and at dispatch for anchored skills; a compile-valid
  # :disabled resource can therefore only host :observe skills, so the refusal that
  # is reachable and observable is the compile-time one.
  test "gate :disabled with a :change skill is refused at compile time" do
    src = """
    defmodule AshA2A.DisabledGateTopologyTest.Bad do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshA2A]

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:read])
        action :mutate, :string do
          run(fn _i, _c -> {:ok, "x"} end)
        end
      end

      a2a do
        skill(:mutate, :mutate, consequence: :change)
      end

      authority do
        gate(:disabled)
      end
    end
    """

    # The refusal surfaces either as a raised error or (Spark verifiers run in
    # after_verify) as a compiler diagnostic; collect both channels.
    {result, diagnostics} =
      Code.with_diagnostics([log: false], fn ->
        try do
          Code.compile_string(src)
          nil
        rescue
          e -> Exception.message(e)
        end
      end)

    err =
      [result | Enum.map(diagnostics, & &1.message)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    assert err =~ "requires an active gate"
  end
end

# --- SECTION 3: Original test/ash_a2a/authority/security_preflight_test.exs ---
defmodule AshA2A.Authority.SecurityPreflightTest do
  @moduledoc """
  SEC-07 court for `AshA2A.Authority.SecurityPreflight`: every insecure
  production setting is a named violation, and `check!/0` raises in strict
  mode. Real application env, real filesystem paths; no doubles.
  `async: false` because it mutates `:ash_a2a` application env.
  """
  use ExUnit.Case, async: false

  alias AshA2A.Authority.SecurityPreflight

  @keys [
    :authority_policy,
    :authority_broker,
    :receipt_store,
    :receipt_store_ekv_opts,
    :strict_security,
    :allow_legacy_authority_policy
  ]

  setup do
    prior = Map.new(@keys, &{&1, Application.fetch_env(:ash_a2a, &1)})

    on_exit(fn ->
      Enum.each(prior, fn
        {k, {:ok, v}} -> Application.put_env(:ash_a2a, k, v)
        {k, :error} -> Application.delete_env(:ash_a2a, k)
      end)
    end)

    Enum.each(@keys, &Application.delete_env(:ash_a2a, &1))
    :ok
  end

  defp codes do
    case SecurityPreflight.check() do
      :ok -> []
      {:error, violations} -> violations |> Enum.map(& &1.code) |> Enum.sort()
    end
  end

  # Never created on disk: only the path's location is judged.
  defp durable_dir, do: Path.join(File.cwd!(), "_build_preflight_probe")

  test "library defaults are two named violations" do
    assert codes() == [:authority_broker_missing, :receipt_store_non_durable]
  end

  test "a secure configuration passes and check!/1 returns :ok even when forced" do
    Application.put_env(
      :ash_a2a,
      :authority_broker,
      {AshA2A.Authority.Broker.Ekv, data_dir: durable_dir()}
    )

    Application.put_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv)
    Application.put_env(:ash_a2a, :receipt_store_ekv_opts, data_dir: durable_dir())

    assert SecurityPreflight.check() == :ok
    assert SecurityPreflight.check!(force: true) == :ok
  end

  test "the legacy escalation policy is a violation unless acknowledged" do
    Application.put_env(:ash_a2a, :authority_policy, :transport_verified_grants_capability)
    assert :legacy_authority_policy_unacknowledged in codes()

    Application.put_env(
      :ash_a2a,
      :allow_legacy_authority_policy,
      :i_accept_privilege_escalation
    )

    refute :legacy_authority_policy_unacknowledged in codes()
  end

  test "InMemory broker and EKV data_dir under tmp are violations" do
    Application.put_env(:ash_a2a, :authority_broker, AshA2A.Authority.Broker.InMemory)
    Application.put_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv)
    # No :data_dir -> AshA2A.Application's own default under System.tmp_dir!/0.
    assert codes() == [:authority_broker_non_durable, :receipt_store_ekv_data_dir_in_tmp]

    Application.put_env(:ash_a2a, :authority_broker, AshA2A.Authority.Broker.Ekv)
    assert :authority_broker_ekv_data_dir_in_tmp in codes()

    Application.put_env(
      :ash_a2a,
      :receipt_store_ekv_opts,
      data_dir: Path.join(System.tmp_dir!(), "explicit/receipts")
    )

    assert :receipt_store_ekv_data_dir_in_tmp in codes()
  end

  test "system-wide /tmp is volatile even when $TMPDIR points elsewhere" do
    Application.put_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv)
    Application.put_env(:ash_a2a, :receipt_store_ekv_opts, data_dir: "/tmp/ash_a2a/receipts")

    Application.put_env(
      :ash_a2a,
      :authority_broker,
      {AshA2A.Authority.Broker.Ekv, data_dir: "/dev/shm/ash_a2a_broker"}
    )

    assert codes() == [
             :authority_broker_ekv_data_dir_in_tmp,
             :receipt_store_ekv_data_dir_in_tmp
           ]
  end

  test "strict mode raises listing every violation; non-strict is a no-op" do
    Application.put_env(:ash_a2a, :strict_security, false)
    assert SecurityPreflight.check!() == :ok

    Application.put_env(:ash_a2a, :strict_security, true)

    error = assert_raise SecurityPreflight.Error, fn -> SecurityPreflight.check!() end
    assert error.message =~ "authority_broker_missing"
    assert error.message =~ "receipt_store_non_durable"
    assert length(error.violations) == 2
  end

  test "legacy_policy_allowed?/0 is closed in strict mode without the ack" do
    Application.put_env(:ash_a2a, :strict_security, false)
    assert SecurityPreflight.legacy_policy_allowed?()

    Application.put_env(:ash_a2a, :strict_security, true)
    refute SecurityPreflight.legacy_policy_allowed?()

    Application.put_env(:ash_a2a, :allow_legacy_authority_policy, :yes)
    refute SecurityPreflight.legacy_policy_allowed?()

    Application.put_env(
      :ash_a2a,
      :allow_legacy_authority_policy,
      :i_accept_privilege_escalation
    )

    assert SecurityPreflight.legacy_policy_allowed?()
  end

  test "every violation code is S42-classified" do
    Application.put_env(:ash_a2a, :authority_policy, :transport_verified_grants_capability)
    Application.put_env(:ash_a2a, :authority_broker, AshA2A.Authority.Broker.Ekv)
    Application.put_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv)
    classified = SecurityPreflight.__sa2a_refusal_codes__()
    assert codes() != []
    assert Enum.all?(codes(), &Map.has_key?(classified, &1))
  end
end

# --- SECTION 4: Original test/ash_a2a/authzen/absorption_test.exs ---
defmodule AshA2A.AuthZEN.AbsorptionTest do
  use ExUnit.Case, async: true

  alias AshA2A.AuthZEN.{Absorption, Client, Metadata}
  alias AshA2A.C2.{AuthorityRequest, Certificate, PreparedEffect}
  alias AshA2A.SPIFFE.{AttestedIdentity, PDPBinding}

  defmodule LocalIssuer do
    def issue(request, _ctx) do
      {:ok,
       %Certificate{
         version: 1,
         effect_digest: request.effect_digest,
         principal: request.principal,
         policy_epoch: request.policy_epoch,
         revocation_epoch: request.revocation_epoch,
         generation: request.generation,
         nonce: "0123456789abcdef",
         not_before_ms: 0,
         expires_at_ms: 10_000,
         audience: request.audience,
         threshold: 1,
         signatures: []
       }}
    end
  end

  test "external policy and workload identity still terminate at local certificate issuance" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{"amount" => 100})

    ctx = %{
      policy_epoch: 1,
      revocation_epoch: 2,
      generation: 3,
      audience: "actuator:payments",
      local_certificate_issuer: LocalIssuer
    }

    request = AuthorityRequest.new(effect, ctx)

    {:ok, metadata} = Metadata.decode(%{"policy_decision_point" => "https://pdp.example"})

    client = %Client{
      metadata: metadata,
      transport: fn "https://pdp.example/access/v1/evaluation", body ->
        assert body["subject"]["id"] == "principal:alice"
        assert body["resource"]["id"] == effect.digest
        {:ok, %{"decision" => true, "context" => %{"reason" => "policy"}}}
      end
    }

    {:ok, attested} =
      AttestedIdentity.from_verified("spiffe://prod.example/pdp/authzen",
        svid_type: :x509,
        bundle_digest: "sha256:bundle",
        observed_at: 1
      )

    binding = %PDPBinding{
      policy_decision_point: "https://pdp.example",
      spiffe_id: "spiffe://prod.example/pdp/authzen",
      trust_domain: "prod.example"
    }

    assert {:ok, response, receipt} =
             Absorption.authorize(request, client, attested, binding, ctx)

    assert response.decision == :admit
    assert %Certificate{} = response.certificate
    assert response.certificate.effect_digest == effect.digest
    assert receipt.authority == :none
    assert receipt.consequence == :evidence_only
  end

  test "PDP allow cannot bypass a SPIFFE binding mismatch" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{})

    ctx = %{
      policy_epoch: 1,
      revocation_epoch: 2,
      generation: 3,
      audience: "a",
      local_certificate_issuer: LocalIssuer
    }

    request = AuthorityRequest.new(effect, ctx)
    {:ok, metadata} = Metadata.decode(%{"policy_decision_point" => "https://pdp.example"})
    client = %Client{metadata: metadata, transport: fn _, _ -> {:ok, %{"decision" => true}} end}

    {:ok, attested} =
      AttestedIdentity.from_verified("spiffe://other.example/pdp",
        svid_type: :x509,
        bundle_digest: "sha256:bundle",
        observed_at: 1
      )

    binding = %PDPBinding{
      policy_decision_point: "https://pdp.example",
      spiffe_id: "spiffe://prod.example/pdp/authzen",
      trust_domain: "prod.example"
    }

    assert {:error, :spiffe_pdp_binding_mismatch} =
             Absorption.authorize(request, client, attested, binding, ctx)
  end
end

# --- SECTION 5: Original test/ash_a2a/authzen/authority_policy_test.exs ---
defmodule AshA2A.AuthZEN.AuthorityPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.AuthZEN.{AuthorityPolicy, PolicyEvidence}
  alias AshA2A.C2.{AuthorityRequest, Certificate, PreparedEffect}

  defmodule LocalIssuer do
    def issue(request, _ctx) do
      {:ok,
       %Certificate{
         version: 1,
         effect_digest: request.effect_digest,
         principal: request.principal,
         policy_epoch: request.policy_epoch,
         revocation_epoch: request.revocation_epoch,
         generation: request.generation,
         nonce: "0123456789abcdef",
         not_before_ms: 0,
         expires_at_ms: 10_000,
         audience: request.audience,
         threshold: 1,
         signatures: []
       }}
    end
  end

  test "external allow only unlocks a local authority-domain issuer" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 1}, %{})
    ctx = %{policy_epoch: 1, revocation_epoch: 2, generation: 3, audience: "actuator:payments"}
    request = AuthorityRequest.new(effect, ctx)

    evidence = %PolicyEvidence{
      decision: true,
      policy_decision_point: "https://pdp.example",
      principal: effect.principal,
      effect_digest: effect.digest,
      observed_at: 1
    }

    policy_ctx =
      Map.merge(ctx, %{
        authzen_evidence: evidence,
        authzen_expected_pdp: "https://pdp.example",
        local_certificate_issuer: LocalIssuer
      })

    assert :ok = AuthorityPolicy.admit(request, policy_ctx)
    assert {:ok, %Certificate{effect_digest: digest}} = AuthorityPolicy.issue(request, policy_ctx)
    assert digest == effect.digest
  end
end

# --- SECTION 6: Original test/ash_a2a/authzen/chicago_canonical_examples_test.exs ---
defmodule AshA2A.AuthZEN.ChicagoCanonicalExamplesTest do
  use ExUnit.Case, async: true

  alias AshA2A.AuthZEN.{Metadata, Types, Wire}
  alias AshA2A.SPIFFE.{AttestedIdentity, Identity, PDPBinding}

  @authzen_figure_14 %{
    "subject" => %{
      "type" => "user",
      "id" => "alice@example.com"
    },
    "resource" => %{
      "type" => "account",
      "id" => "123"
    },
    "action" => %{
      "name" => "can_read",
      "properties" => %{
        "method" => "GET"
      }
    },
    "context" => %{
      "time" => "1985-10-26T01:22-07:00"
    }
  }

  test "AuthZEN 1.0 Figure 14 survives the internal model and wire boundary byte-for-shape" do
    request = %Types.Request{
      subject: %Types.Entity{type: "user", id: "alice@example.com"},
      resource: %Types.Entity{type: "account", id: "123"},
      action: %Types.Action{name: "can_read", properties: %{"method" => "GET"}},
      context: %{"time" => "1985-10-26T01:22-07:00"}
    }

    assert Wire.request(request) == @authzen_figure_14
  end

  test "AuthZEN decisions remain strict booleans and preserve decision context" do
    assert {:ok, decision} =
             Wire.decode_decision(%{
               "decision" => false,
               "context" => %{"reason" => "resource not found"}
             })

    refute decision.decision
    assert decision.context == %{"reason" => "resource not found"}
    assert {:error, :invalid_decision} = Wire.decode_decision(%{"decision" => "false"})
  end

  test "SPIFFE published workload identity example preserves trust-domain and path identity" do
    assert {:ok, identity} = Identity.parse("spiffe://prod.acme.com/billing/api")
    assert identity.uri == "spiffe://prod.acme.com/billing/api"
    assert identity.trust_domain == "prod.acme.com"
    assert identity.path == "/billing/api"
  end

  test "verified X509-SVID identity can bind a PDP but still contributes no authority by itself" do
    assert {:ok, metadata} =
             Metadata.decode(%{"policy_decision_point" => "https://pdp.example.com"})

    assert {:ok, attested} =
             AttestedIdentity.from_verified("spiffe://prod.acme.com/billing/api",
               svid_type: :x509,
               bundle_digest: "sha256:canonical-example-bundle",
               observed_at: 1
             )

    binding = %PDPBinding{
      policy_decision_point: "https://pdp.example.com",
      spiffe_id: "spiffe://prod.acme.com/billing/api",
      trust_domain: "prod.acme.com"
    }

    assert :ok = PDPBinding.admit(metadata, attested, binding)

    jwt = %{attested | svid_type: :jwt}
    assert {:error, :spiffe_pdp_binding_mismatch} = PDPBinding.admit(metadata, jwt, binding)
  end
end

# --- SECTION 7: Original test/ash_a2a/authzen/decision_gate_test.exs ---
defmodule AshA2A.AuthZEN.DecisionGateTest do
  use ExUnit.Case, async: true
  alias AshA2A.AuthZEN.{DecisionGate, PolicyEvidence}
  alias AshA2A.C2.PreparedEffect

  defp evidence(effect, overrides \\ %{}) do
    struct!(
      PolicyEvidence,
      Map.merge(
        %{
          decision: true,
          policy_decision_point: "https://pdp.example",
          principal: effect.principal,
          effect_digest: effect.digest,
          observed_at: 1,
          context: %{}
        },
        overrides
      )
    )
  end

  test "allow is evidence only and must bind exact effect" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 1}, %{})
    assert :ok = DecisionGate.admit(evidence(effect), effect, "https://pdp.example")

    assert {:error, :effect_digest_mismatch} =
             DecisionGate.admit(
               evidence(effect, %{effect_digest: "sha256:wrong"}),
               effect,
               "https://pdp.example"
             )
  end

  test "denial remains denial" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 1}, %{})

    assert {:error, :denied} =
             DecisionGate.admit(
               evidence(effect, %{decision: false}),
               effect,
               "https://pdp.example"
             )
  end
end

# --- SECTION 8: Original test/ash_a2a/authzen/metadata_test.exs ---
defmodule AshA2A.AuthZEN.MetadataTest do
  use ExUnit.Case, async: true
  alias AshA2A.AuthZEN.Metadata

  test "retains unknown metadata and binds exact PDP identifier" do
    assert {:ok, metadata} =
             Metadata.decode(%{
               "policy_decision_point" => "https://pdp.example",
               "vendor_extension" => %{"v" => 1}
             })

    assert metadata.access_evaluation_endpoint == "https://pdp.example/access/v1/evaluation"
    assert metadata.extensions["vendor_extension"] == %{"v" => 1}
    assert :ok = Metadata.bind_expected(metadata, "https://pdp.example")
    assert {:error, :pdp_mixup} = Metadata.bind_expected(metadata, "https://evil.example")
  end

  test "rejects non HTTPS PDP identity" do
    assert {:error, _} = Metadata.decode(%{"policy_decision_point" => "http://pdp.example"})
  end
end

# --- SECTION 9: Original test/ash_a2a/authzen/projection_test.exs ---
defmodule AshA2A.AuthZEN.ProjectionTest do
  use ExUnit.Case, async: true
  alias AshA2A.AuthZEN.Projection
  alias AshA2A.C2.PreparedEffect

  test "projects exact principal capability and digest into SARC" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{"amount" => 100})
    assert {:ok, request} = Projection.from_effect(effect, %{"ip" => "127.0.0.1"})
    assert request.subject.id == "principal:alice"
    assert request.action.name == "payments"
    assert request.resource.id == effect.digest
    assert request.context["sa2a"]["effect_digest"] == effect.digest
    assert request.context["sa2a"]["principal"] == "principal:alice"
  end
end

# --- SECTION 10: Original test/ash_a2a/authzen/search_binding_test.exs ---
defmodule AshA2A.AuthZEN.SearchBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.AuthZEN.SearchBinding

  test "pagination preserves the initial request identity" do
    initial = %{"subject" => %{"type" => "user"}, "resource" => %{"type" => "doc"}}
    assert {:ok, state} = SearchBinding.start(initial)
    assert {:ok, state} = SearchBinding.next(state, initial, "page-2")
    assert state.page_token == "page-2"

    mutated = put_in(initial, ["resource", "type"], "payment")

    assert {:error, :pagination_request_mutated} =
             SearchBinding.next(state, mutated, "page-3")
  end
end

# --- SECTION 11: Original test/ash_a2a/cs2/cs2_contract_test.exs ---
defmodule AshA2A.CS2.ContractTest do
  use ExUnit.Case, async: true

  alias AshA2A.CS2.{Contract, ConsumerContract, FleetAdapter, FleetContract, XaasBridge}

  test "fleet contract wraps payload under a CONSTRUCT ceiling" do
    assert FleetContract.wrap(%{a: 1}) == %{
             schema: "cs2.fleet-contract.v1",
             subject: "RFC-CS2-001",
             work_id: "CS2-WRK-012",
             authority_ceiling: :construct,
             payload: %{a: 1}
           }
  end

  test "xaas bridge carries the exact fleet envelope" do
    packet = XaasBridge.packet(%{a: 1})
    assert packet.contract == FleetContract.wrap(%{a: 1})
    assert packet.consumer == "xaas"
    assert packet.subject == "RFC-CS2-001"
  end

  test "contract evidence and triage packets carry kind, provenance and novelty" do
    ev = Contract.evidence_packet(%{f: 1}, %{sha: "abc"})
    assert ev.kind == :cs2_evidence_packet
    assert ev.provenance == %{sha: "abc"}
    assert ev.payload == %{f: 1}

    tr = Contract.triage_packet(%{f: 1}, :novel, %{sha: "abc"})
    assert tr.kind == :cs2_triage_packet
    assert tr.novelty == :novel
    assert Contract.authority_ceiling() == :construct
    assert Contract.consumers() == ["xaas"]
  end

  test "fleet adapter triages without claiming novelty" do
    out = FleetAdapter.xaas_packet(%{f: 1}, %{sha: "abc"})
    assert out.contract == "cs2-fleet-contract/26.9.26"
    assert out.destination == "xaas.engineer_workflow"
    assert out.subject == "RFC-CS2-001"
    assert out.packet.kind == :cs2_triage_packet
    assert out.packet.novelty == :unassessed
    assert out.packet.provenance == %{sha: "abc"}
    assert ConsumerContract.subject() == "RFC-CS2-001"
  end
end

# --- SECTION 12: Original test/ash_a2a/identity/canonical_errata_test.exs ---
defmodule AshA2A.Identity.CanonicalErrataTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical

  @max 9_007_199_254_740_991

  test "ERR7-F-1 vectors are byte-equal to an independent python3 recompute" do
    case System.find_executable("python3") do
      nil ->
        IO.puts("[SKIP] python3 not on PATH; ERR7-F-1 independent recompute not run")

      py ->
        vectors = [
          %{"b" => 1, "a" => [1, 2, %{"z" => nil, "y" => true}], "é" => "x"},
          %{"" => "", "10" => 1, "9" => 2, "a" => "€\"\\\n"},
          [@max, -@max, 0]
        ]

        for v <- vectors do
          {:ok, ours} = Canonical.encode(v)
          path = Path.join(System.tmp_dir!(), "lane19_#{System.unique_integer([:positive])}.json")
          File.write!(path, Jason.encode!(v))
          {out, 0} = run_py(py, path)
          File.rm(path)
          assert out == ours
        end
    end
  end

  defp run_py(py, path) do
    code =
      "import sys,json;sys.stdout.write(json.dumps(json.load(open(sys.argv[1],encoding='utf-8'))," <>
        "sort_keys=True,separators=(',',':'),ensure_ascii=False))"

    System.cmd(py, ["-c", code, path])
  end

  test "ERR7-F-2 floats are rejected with a typed error" do
    assert {:error, :canonical_float_forbidden} = Canonical.encode(%{"a" => 1.5})
    assert {:error, :canonical_float_forbidden} = Canonical.digest([1.0])
  end

  test "ERR7-F-3 2^53 integer as number refused, as string accepted" do
    assert {:error, :canonical_integer_out_of_range} = Canonical.encode(%{"n" => @max + 1})
    assert {:error, :canonical_integer_out_of_range} = Canonical.encode(%{"n" => -@max - 1})
    assert {:ok, _} = Canonical.encode(%{"n" => @max})
    assert {:ok, ~s({"n":"9007199254740992"})} = Canonical.encode(%{"n" => "9007199254740992"})
  end

  test "ERR7-F-2 atom/string key collision rejected" do
    assert {:error, :canonical_key_collision} = Canonical.encode(%{:a => 1, "a" => 2})
  end

  test "ERR7-F-2 non-JSON terms rejected" do
    assert {:error, :canonical_type_forbidden} = Canonical.encode(%{"a" => {1, 2}})
    assert {:error, :canonical_type_forbidden} = Canonical.encode(%{"a" => self()})
  end

  test "ERR7-F-4 over-deep input refused" do
    deep = Enum.reduce(1..40, 1, fn _, acc -> [acc] end)
    assert {:error, :canonical_depth_exceeded} = Canonical.encode(deep)
    ok = Enum.reduce(1..20, 1, fn _, acc -> [acc] end)
    assert {:ok, _} = Canonical.encode(ok)
  end

  test "ERR7-F-4 oversize input refused before hashing" do
    big = %{"p" => String.duplicate("a", 1_048_577)}
    assert {:error, :canonical_size_exceeded} = Canonical.encode(big)
    assert {:error, :canonical_size_exceeded} = Canonical.digest(big)
  end
end

# --- SECTION 13: Original test/ash_a2a/security_profile/boot_durable_stores_test.exs ---
defmodule AshA2A.SecurityProfile.BootDurableStoresTest do
  @moduledoc """
  RFC-SA2A-007 boot court for the durable claim store and keyed journal:
  `:strict` refuses a missing/in-memory/tmp-backed claim store and a weak
  HMAC key, and the real application start path calls the boot enforcement.
  Real snapshots and real compiled BEAM imports; no doubles.
  """
  use ExUnit.Case, async: false

  alias AshA2A.SA2A.Conformance.Checks.C1
  alias AshA2A.SecurityProfile.Boot

  defp durable, do: Path.join(File.cwd!(), "_build_boot_probe")

  defp good do
    %{
      outbox_key: String.duplicate("k", 32),
      outbox_dir: durable(),
      receipt_store: AshA2A.ReceiptStore.Ekv,
      capability_release_mode: :strict,
      authority_broker: AshA2A.Authority.Broker.Ekv,
      kill_switch_class: "prod",
      authority_policy: :broker,
      claim_store: AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile,
      claim_store_dir: durable()
    }
  end

  defp codes(cfg), do: cfg |> then(&Boot.violations(:strict, &1)) |> Enum.map(& &1.code)

  test "a fully configured snapshot with the durable claim store has no violations" do
    assert codes(good()) == []
  end

  for {label, patch, code} <- [
        {"no claim store", %{claim_store: nil}, :claim_store_missing},
        {"in-memory claim store", %{claim_store: AshA2A.C2.MemoryClaimStore},
         :claim_store_not_durable},
        {"ETS claim store", %{claim_store: AshA2A.C2.ClaimStoreETS}, :claim_store_not_durable},
        {"tmp claim store dir", %{claim_store_dir: "/tmp/claims"}, :claim_store_dir_not_durable},
        {"unset claim store dir", %{claim_store_dir: nil}, :claim_store_dir_not_durable},
        {"short HMAC key", %{outbox_key: "short"}, :outbox_key_weak}
      ] do
    test "strict refuses #{label}" do
      assert unquote(code) in codes(Map.merge(good(), unquote(Macro.escape(patch))))
    end
  end

  test "the real snapshot/0 carries the claim-store facts" do
    snap = Boot.snapshot()
    assert Map.has_key?(snap, :claim_store)
    assert Map.has_key?(snap, :claim_store_dir)
  end

  test "Application.start/2 calls Boot.run!/0, which runs SecurityPreflight.check! and ReceiptStore.boot_check" do
    assert {:ok, app} = C1.imports(%{beam_binaries: %{}}, AshA2A.Application)
    assert {AshA2A.SecurityProfile.Boot, :run!, 0} in app
    assert {:ok, boot} = C1.imports(%{beam_binaries: %{}}, AshA2A.SecurityProfile.Boot)
    assert {AshA2A.Authority.SecurityPreflight, :check!, 1} in boot
    assert {AshA2A.ReceiptStore, :boot_check, 0} in boot
  end

  test "new refusal codes are declared with valid classes" do
    for mod <- [
          Boot,
          AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile,
          AshA2A.ConsequenceKernel.PreparedEffectStore.Journal
        ] do
      for {code, class} <- mod.__sa2a_refusal_codes__() do
        assert is_atom(code)
        assert class in [:refused_receipt, :refused_authority, :refused_bounds]
      end
    end
  end
end

# --- SECTION 14: Original test/ash_a2a/security_profile/boot_test.exs ---
defmodule AshA2A.SecurityProfile.BootTest do
  @moduledoc """
  RFC-SA2A-007 boot court: what each profile refuses at boot. The strict
  rule set is a pure function of a config snapshot, so it is exercised on
  real snapshots; `run!/0` is exercised against the real (test-env,
  dev_bypass) profile. No doubles.

  Non-vacuity: every violation code has its own test asserting that a single
  deliberate defect yields exactly that one code (so deleting the check, or
  making it over-broad, fails). `:legacy_compat` is asserted to log every code
  as a warning and emit telemetry; `:dev_bypass` is asserted to log none.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias AshA2A.Authority.SecurityPreflight.Error
  alias AshA2A.SecurityProfile.Boot

  defp durable, do: Path.join(File.cwd!(), "_build_boot_probe")

  defp good do
    %{
      outbox_key: String.duplicate("k", 32),
      outbox_dir: durable(),
      receipt_store: AshA2A.ReceiptStore.Ekv,
      capability_release_mode: :strict,
      authority_broker: AshA2A.Authority.Broker.Ekv,
      kill_switch_class: "prod",
      authority_policy: :broker,
      claim_store: AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile,
      claim_store_dir: durable()
    }
  end

  defp codes(cfg), do: cfg |> then(&Boot.violations(:strict, &1)) |> Enum.map(& &1.code)

  # {code, label, patch}: one deliberate defect on top of `good/0`.
  @cases [
    {:outbox_key_missing, "unkeyed outbox", %{outbox_key: nil}},
    {:outbox_key_weak, "31-byte HMAC key", %{outbox_key: String.duplicate("k", 31)}},
    {:claim_store_missing, "no claim store", %{claim_store: nil}},
    {:claim_store_not_durable, "in-memory claim store",
     %{claim_store: AshA2A.C2.MemoryClaimStore}},
    {:claim_store_dir_not_durable, "tmp claim store dir", %{claim_store_dir: "/tmp/claims"}},
    {:outbox_dir_not_durable, "tmp outbox dir", %{outbox_dir: "/tmp/outbox"}},
    {:receipt_store_in_memory, "memory receipt store",
     %{receipt_store: AshA2A.ReceiptStore.Memory}},
    {:capability_release_mode_legacy, "legacy release mode", %{capability_release_mode: :legacy}},
    {:authority_broker_missing, "missing broker", %{authority_broker: nil}},
    {:kill_switch_class_missing, "nil kill switch class", %{kill_switch_class: nil}},
    {:transport_verified_policy_forbidden, "transport verified policy",
     %{authority_policy: :transport_verified_grants_capability}}
  ]

  # Non-conflicting subset (weak vs missing key, memory vs nil claim store
  # patch the same field) that can be applied to one snapshot at once.
  # (a nil claim store short-circuits the claim-store dir check too).
  @multi_skip [:outbox_key_weak, :claim_store_not_durable, :claim_store_dir_not_durable]

  defp multi_bad do
    for({code, _, patch} <- @cases, code not in @multi_skip, do: patch)
    |> Enum.reduce(good(), &Map.merge(&2, &1))
  end

  defp restore_env(key) do
    case Application.fetch_env(:ash_a2a, key) do
      {:ok, v} -> fn -> Application.put_env(:ash_a2a, key, v) end
      :error -> fn -> Application.delete_env(:ash_a2a, key) end
    end
  end

  test "a fully configured snapshot has no strict violations" do
    assert codes(good()) == []
  end

  test "the case table covers all 11 documented strict codes" do
    assert length(@cases) == 11
    assert Enum.map(@cases, &elem(&1, 0)) |> Enum.uniq() |> length() == 11

    for {code, _, _} <- @cases,
        do: assert(Map.has_key?(Boot.__sa2a_refusal_codes__(), code))
  end

  for {code, label, patch} <- @cases do
    test "strict yields exactly #{code} for #{label}" do
      assert codes(Map.merge(good(), unquote(Macro.escape(patch)))) == [unquote(code)]
    end

    test "legacy_compat logs #{code} as a warning and emits telemetry" do
      snap = Map.merge(good(), unquote(Macro.escape(patch)))
      id = {__MODULE__, make_ref()}
      me = self()

      :telemetry.attach(
        id,
        [:ash_a2a, :security_profile, :legacy_compat],
        fn event, m, meta, _ -> send(me, {:tele, event, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      log =
        capture_log([level: :warning], fn ->
          assert :ok = Boot.enforce!(:legacy_compat, snap)
        end)

      assert log =~ "legacy_compat profile: #{unquote(code)}:"

      assert_received {:tele, [:ash_a2a, :security_profile, :legacy_compat], %{system_time: _},
                       %{profile: :legacy_compat}}
    end

    test "dev_bypass does not log or return #{code}" do
      snap = Map.merge(good(), unquote(Macro.escape(patch)))
      assert Boot.violations(:dev_bypass, snap) == []
      assert Boot.violations(:legacy_compat, snap) == []
    end
  end

  test "empty outbox key is refused as missing, not weak" do
    assert codes(%{good() | outbox_key: ""}) == [:outbox_key_missing]
  end

  test "a 32-byte key is not weak" do
    refute :outbox_key_weak in codes(%{good() | outbox_key: String.duplicate("k", 32)})
  end

  test "unset outbox dir and unset claim store dir are refused" do
    assert codes(%{good() | outbox_dir: nil}) == [:outbox_dir_not_durable]
    assert codes(%{good() | claim_store_dir: nil}) == [:claim_store_dir_not_durable]
  end

  test "system tmp dir outbox is refused" do
    assert codes(%{
             good()
             | outbox_dir: Path.join(System.tmp_dir!(), "ash_a2a_receipt_outbox")
           }) == [:outbox_dir_not_durable]
  end

  test "legacy_compat logs every violation of a multiply-broken snapshot" do
    log =
      capture_log([level: :warning], fn ->
        assert :ok = Boot.enforce!(:legacy_compat, multi_bad())
      end)

    for {code, _, _} <- @cases, code not in @multi_skip do
      assert log =~ "legacy_compat profile: #{code}:"
    end
  end

  test "legacy_compat on a clean snapshot logs no violation warnings" do
    log =
      capture_log([level: :warning], fn -> assert :ok = Boot.enforce!(:legacy_compat, good()) end)

    refute log =~ "legacy_compat profile:"
  end

  test "receipt_store_boot_check_failed: strict-less profile logs it, production raises it" do
    restores = Enum.map([:receipt_store, :receipt_outbox_dir, :production], &restore_env/1)
    on_exit(fn -> Enum.each(restores, & &1.()) end)

    Application.put_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv)
    Application.put_env(:ash_a2a, :receipt_outbox_dir, "/tmp/boot_test_outbox")
    Application.put_env(:ash_a2a, :production, false)

    assert {:error, {:non_durable_outbox_dir, "/tmp/boot_test_outbox"}} =
             AshA2A.ReceiptStore.boot_check()

    log =
      capture_log([level: :warning], fn ->
        assert :ok = Boot.enforce!(:legacy_compat, good())
      end)

    assert log =~ "AshA2A boot_check:"
    assert log =~ "non_durable_outbox_dir"

    Application.put_env(:ash_a2a, :production, true)

    err = assert_raise Error, fn -> Boot.enforce!(:legacy_compat, good()) end
    assert [:receipt_store_boot_check_failed] == Enum.map(err.violations, & &1.code)
  end

  test "enforce!(:strict) raises listing every violation; dev_bypass/legacy do not raise" do
    bad = %{good() | outbox_key: nil, kill_switch_class: nil}
    err = assert_raise Error, fn -> Boot.enforce!(:strict, bad) end
    listed = Enum.map(err.violations, & &1.code)
    assert :outbox_key_missing in listed and :kill_switch_class_missing in listed

    capture_log([level: :warning], fn ->
      assert :ok = Boot.enforce!(:legacy_compat, bad)
    end)
  end

  test "dev_bypass prints a loud banner and emits telemetry at boot" do
    ref = make_ref()
    me = self()
    id = {__MODULE__, ref}

    :telemetry.attach(
      id,
      [:ash_a2a, :security_profile, :dev_bypass],
      fn event, m, meta, _ -> send(me, {:tele, event, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    out = capture_io(:stderr, fn -> assert :ok = Boot.run!() end)
    assert out =~ "DEV_BYPASS"
    assert_receive {:tele, [:ash_a2a, :security_profile, :dev_bypass], %{system_time: _}, _}
  end

  test "codes are classified for refusal totality" do
    classes = Boot.__sa2a_refusal_codes__()

    emitted = codes(multi_bad())
    assert length(emitted) == 8

    for {code, _, _} <- @cases, do: assert(Map.has_key?(classes, code))
    for code <- emitted, do: assert(Map.has_key?(classes, code))
  end
end

# --- SECTION 15: Original test/ash_a2a/security_profile/security_profile_test.exs ---
defmodule AshA2A.SecurityProfileTest do
  @moduledoc """
  RFC-SA2A-007 profile court. Real modules, real compilation, real BEAM
  inspection; no doubles. `async: false` because it mutates `:ash_a2a` env.

  Prod-mode behaviour is exercised by really compiling fixture modules from
  `AshA2A.SecurityProfile.Template` with `env: :prod`, because the suite
  itself runs under `MIX_ENV=test` and the real `AshA2A.SecurityProfile` is
  compiled as `:dev_bypass` there (config/config.exs).
  """
  use ExUnit.Case, async: false

  alias AshA2A.SecurityProfile

  defp compile_fixture(env, requested) do
    name = "AshA2A.SecurityProfileTest.Fixture#{System.unique_integer([:positive])}"

    src = """
    defmodule #{name} do
      use AshA2A.SecurityProfile.Template, env: #{inspect(env)}, requested: #{inspect(requested)}
    end
    """

    # The BEAM scan reads debug_info, which the test env may compile without.
    prior = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    [{mod, bin}] =
      try do
        Code.compile_string(src, "security_profile_fixture.ex")
      after
        Code.put_compiler_option(:debug_info, prior)
      end

    on_exit(fn -> :code.purge(mod) && :code.delete(mod) end)
    {mod, bin}
  end

  # Every atom appearing in the module's compiled definitions (Elixir
  # debug_info: function heads, bodies and specs after macro expansion).
  defp atom_literals(bin) do
    {:ok, {mod, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(bin, [:debug_info])

    {:ok, forms} = backend.debug_info(:elixir_v1, mod, data, [])
    collect(forms, MapSet.new())
  end

  defp collect(a, acc) when is_atom(a), do: MapSet.put(acc, a)
  defp collect(m, acc) when is_map(m), do: m |> Map.to_list() |> collect(acc)
  defp collect(t, acc) when is_tuple(t), do: t |> Tuple.to_list() |> collect(acc)
  defp collect(l, acc) when is_list(l), do: Enum.reduce(l, acc, &collect/2)
  defp collect(_, acc), do: acc

  describe "the real module under MIX_ENV=test" do
    test "selects dev_bypass from build config and reports it consistently" do
      assert SecurityProfile.current() == :dev_bypass
      assert SecurityProfile.dev_bypass?()
      refute SecurityProfile.strict?()
      assert SecurityProfile.dev_bypass_compiled?()
    end

    test "stamp/1 adds the profile and overwrites caller-supplied values" do
      assert %{a: 1, security_profile: :dev_bypass} = SecurityProfile.stamp(%{a: 1})

      forged =
        SecurityProfile.stamp(%{"security_profile" => "strict", :security_profile => :strict})

      assert forged.security_profile == :dev_bypass
      refute Map.has_key?(forged, "security_profile")
    end

    test "no call-site knob exists: current is arity 0 and runtime env cannot switch it" do
      refute function_exported?(SecurityProfile, :current, 1)
      refute function_exported?(SecurityProfile, :strict?, 1)

      prior = Application.fetch_env(:ash_a2a, :security_profile)
      on_exit(fn -> restore(:security_profile, prior) end)

      Application.put_env(:ash_a2a, :security_profile, :strict)
      assert SecurityProfile.current() == :dev_bypass
    end

    test "request data cannot switch the profile through stamp/1" do
      meta = %{"security_profile" => "strict", :security_profile => :strict, :profile => :strict}
      assert SecurityProfile.stamp(meta).security_profile == SecurityProfile.current()
    end
  end

  describe "template profiles" do
    test "default-less strict build" do
      {m, _} = compile_fixture(:dev, :strict)
      assert m.current() == :strict
      assert m.strict?()
      refute m.dev_bypass?()
      assert m.stamp(%{}) == %{security_profile: :strict}
    end

    test "legacy_compat is explicit and not strict" do
      {m, _} = compile_fixture(:prod, :legacy_compat)
      assert m.current() == :legacy_compat
      assert m.legacy_compat?()
      refute m.strict?()
    end

    test "an unknown profile is a compile error" do
      err =
        assert_raise CompileError, fn -> compile_fixture(:dev, :yolo) end

      assert err.description =~ "unknown security profile"
    end
  end

  describe "dev_bypass is compiled out of prod" do
    test "requesting dev_bypass in a prod build raises CompileError with a clear message" do
      err = assert_raise CompileError, fn -> compile_fixture(:prod, :dev_bypass) end
      assert err.description =~ "dev_bypass"
      assert err.description =~ "prod"
    end

    test "BEAM scan: prod build has no dev_bypass functions, literals or banner" do
      {prod, prod_bin} = compile_fixture(:prod, :strict)
      {dev, dev_bin} = compile_fixture(:dev, :dev_bypass)

      # Positive control: the scan can see dev_bypass when it exists.
      assert function_exported?(dev, :announce_dev_bypass, 0)
      assert function_exported?(dev, :dev_bypass_banner, 0)
      assert MapSet.member?(atom_literals(dev_bin), :dev_bypass)

      # Prod: functions absent, atom literal absent, predicate constant false.
      refute function_exported?(prod, :announce_dev_bypass, 0)
      refute function_exported?(prod, :dev_bypass_banner, 0)
      refute MapSet.member?(atom_literals(prod_bin), :dev_bypass)
      refute prod.dev_bypass?()
      refute prod.dev_bypass_compiled?()
    end
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:ash_a2a, key, v)
  defp restore(key, :error), do: Application.delete_env(:ash_a2a, key)
end

# --- SECTION 16: Original test/ash_a2a/spiffe/identity_test.exs ---
defmodule AshA2A.SPIFFE.IdentityTest do
  use ExUnit.Case, async: true
  alias AshA2A.SPIFFE.{AttestedIdentity, Identity}

  test "parses trust-domain qualified SPIFFE identity" do
    assert {:ok, identity} = Identity.parse("spiffe://prod.example/pdp/authzen")
    assert identity.trust_domain == "prod.example"
    assert identity.path == "/pdp/authzen"
  end

  test "rejects query and fragment confusion" do
    assert {:error, :spiffe_query_fragment_forbidden} =
             Identity.parse("spiffe://prod.example/pdp?role=admin")
  end

  test "attested identity requires verifier-produced bundle evidence" do
    assert {:ok, attested} =
             AttestedIdentity.from_verified("spiffe://prod.example/pdp/authzen",
               svid_type: :x509,
               bundle_digest: "sha256:bundle",
               observed_at: 10
             )

    assert attested.svid_type == :x509
  end
end

# --- SECTION 17: Original test/ash_a2a/spiffe/pdp_binding_test.exs ---
defmodule AshA2A.SPIFFE.PDPBindingCourt.PDP do
  @moduledoc """
  Real Bandit-served PDP stub for the `AshA2A.SPIFFE.PDPBinding` court.

  Two real surfaces:

    * `GET /.well-known/authzen-configuration` — the OpenID AuthZEN discovery
      document carrying the PDP identity `https://court-pdp.example`. The court
      fetches this over real loopback HTTP and decodes it through
      `AshA2A.AuthZEN.Metadata.decode/1`, so every binding below is admitted
      against an identity that came off the wire, not a hand-built struct.
    * `POST /access/v1/evaluation` — the AuthZEN evaluation contract: real JSON
      in, real decision out. Every request increments a real ETS counter, so
      "the binding refused before any HTTP" is witnessed by a frozen counter
      and "the PDP was consulted" by a moving one. Adversarial fixtures route
      on the prepared effect's subject id (surfaced at
      `resource.properties.subject.id`): `"boom"` answers 500, `"garbage"`
      answers 200 with an undecodable payload, `"hang"` stalls
      (receive-timeout path).
  """

  @behaviour Plug

  @pdp "https://court-pdp.example"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    case {conn.method, conn.path_info} do
      {"GET", [".well-known", "authzen-configuration"]} ->
        discovery(conn)

      {"POST", ["access", "v1", "evaluation"]} ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case Jason.decode(body) do
          {:ok, %{"subject" => _subject, "resource" => resource} = req} ->
            :ets.update_counter(opts.table, :request_count, {2, 1}, {:request_count, 0})
            :ets.insert(opts.table, {:last_request, req})

            # The projection carries the prepared effect's subject id at
            # resource.properties.subject.id; adversarial fixtures route there
            # (the top-level resource id is always the effect digest).
            adversarial_id =
              get_in(resource, ["properties", "subject", "id"]) || resource["id"]

            answer(conn, adversarial_id, opts)

          _ ->
            respond(conn, {400, %{"error" => "invalid_request"}})
        end

      _ ->
        respond(conn, {404, %{"error" => "not_found"}})
    end
  end

  defp answer(conn, "boom", _opts) do
    # SLEEP-CLASS: SIMULATED-SLOW-HANDLER (fixture models a slow collaborator)
    Process.sleep(50)
    respond(conn, {500, %{"error" => "internal"}})
  end

  defp answer(conn, "garbage", _opts) do
    respond(conn, {200, %{"status" => "ok", "no" => "decision"}})
  end

  defp answer(conn, "hang", opts) do
    # SLEEP-CLASS: SIMULATED-SLOW-HANDLER (fixture models a slow collaborator)
    Process.sleep(Map.get(opts, :stall_ms, 5_000))
    respond(conn, {200, %{"decision" => true, "context" => %{}}})
  end

  defp answer(conn, _resource_id, _opts) do
    respond(conn, {200, %{"decision" => true, "context" => %{}}})
  end

  defp discovery(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "policy_decision_point" => @pdp,
        "capabilities" => ["access-evaluation-v1"]
      })
    )
  end

  defp respond(conn, {status, payload}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end
end

defmodule AshA2A.SPIFFE.PDPBindingTest do
  @moduledoc """
  V4-21 thickened court for `AshA2A.SPIFFE.PDPBinding.admit/3` — a fail-closed
  security seam. Real collaborators throughout: a Bandit-served AuthZEN PDP
  (discovery + evaluation), a real HTTP fetch of the discovery document, and
  the real composed surface `AshA2A.AuthZEN.Absorption.authorize/5` for the
  fail-closed modes. Kills:

    1. happy-path binding resolution against a PDP identity served over real
       HTTP and decoded through `AshA2A.AuthZEN.Metadata.decode/1`;
    2. every typed refusal the module defines — `:spiffe_pdp_binding_mismatch`
       (pdp_binding.ex:26) triggered by wrong SPIFFE uri, wrong trust domain,
       and a JWT SVID without `allow_jwt`; the `{:error, _}` passthrough from
       `AshA2A.AuthZEN.Metadata.bind_expected/2` (`:pdp_mixup`,
       metadata.ex:50);
    3. fail-closed: unreachable PDP, stalled PDP (receive timeout), non-200,
       and a malformed 200 body each collapse to a typed refusal through the
       real HTTP stack, never a silent pass and never a minted certificate;
    4. admission ordering: a binding mismatch refuses before the PDP is
       consulted (frozen ETS request counter).
  """

  use ExUnit.Case, async: true

  alias AshA2A.AuthZEN.{Absorption, Client, DecisionPool, Metadata}
  alias AshA2A.C2.{AuthorityRequest, Certificate, PreparedEffect}
  alias AshA2A.SPIFFE.{AttestedIdentity, PDPBinding}
  alias AshA2A.SPIFFE.PDPBindingCourt.PDP
  alias AshA2A.Test.EphemeralHttp

  @pdp "https://court-pdp.example"

  setup do
    # Absorption evaluates through the real named DecisionPool; it must be up
    # before any client posts (same requirement as the FR-01.3 AuthZEN court).
    :ok = DecisionPool.ensure_started([])

    table = :ets.new(:"pdp_binding_court_#{System.unique_integer()}", [:set, :public])
    :ets.insert(table, {:request_count, 0})

    %{port: port, base_url: base_url, pid: server_pid} =
      EphemeralHttp.start!({PDP, %{table: table}})

    metadata = fetch_metadata!(base_url)

    {:ok, attested} =
      AttestedIdentity.from_verified("spiffe://prod.example/pdp/authzen",
        svid_type: :x509,
        bundle_digest: "sha256:bundle",
        observed_at: 1
      )

    binding = %PDPBinding{
      policy_decision_point: @pdp,
      spiffe_id: "spiffe://prod.example/pdp/authzen",
      trust_domain: "prod.example"
    }

    %{
      table: table,
      port: port,
      base_url: base_url,
      server_pid: server_pid,
      metadata: metadata,
      attested: attested,
      binding: binding
    }
  end

  ## (a) happy path over the real PDP stub

  test "happy path: binding resolves against the discovery document served over real HTTP", %{
    metadata: metadata,
    attested: attested,
    binding: binding
  } do
    # The metadata under test was decoded from the real wire document, and the
    # served identity is exactly what the binding pins.
    assert metadata.policy_decision_point == @pdp
    assert metadata.capabilities == ["access-evaluation-v1"]
    assert :ok = PDPBinding.admit(metadata, attested, binding)
  end

  test "happy path: a passing binding admits end-to-end through Absorption over the real PDP", %{
    table: table,
    base_url: base_url,
    metadata: metadata,
    attested: attested,
    binding: binding
  } do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{"amount" => 100})
    ctx = authority_ctx()
    request = AuthorityRequest.new(effect, ctx)

    client =
      real_client(
        %{metadata | access_evaluation_endpoint: base_url <> "/access/v1/evaluation"},
        2_000
      )

    assert {:ok, response, receipt} =
             Absorption.authorize(request, client, attested, binding, ctx)

    assert %Certificate{} = response.certificate
    assert response.certificate.effect_digest == effect.digest

    # The real AuthZEN request the PDP received is the projected effect.
    assert %{
             "subject" => %{"type" => "sa2a-principal", "id" => "principal:alice"},
             "action" => %{"name" => "payments"},
             "resource" => %{"type" => "sa2a-prepared-effect", "id" => resource_id}
           } = :ets.lookup_element(table, :last_request, 2)

    assert resource_id == effect.digest

    # Evidence only: a PDP allow never mints actuation authority.
    assert receipt.authority == :none
    assert receipt.consequence == :evidence_only
  end

  ## (b) every typed refusal the module defines

  test "refusal: wrong SPIFFE uri in the attested identity", %{
    metadata: metadata,
    binding: binding
  } do
    {:ok, wrong_uri} =
      AttestedIdentity.from_verified("spiffe://prod.example/pdp/other",
        svid_type: :x509,
        bundle_digest: "sha256:bundle",
        observed_at: 1
      )

    assert {:error, :spiffe_pdp_binding_mismatch} = PDPBinding.admit(metadata, wrong_uri, binding)
  end

  test "refusal: wrong trust domain in the attested identity", %{
    metadata: metadata,
    binding: binding
  } do
    {:ok, wrong_td} =
      AttestedIdentity.from_verified("spiffe://staging.example/pdp/authzen",
        svid_type: :x509,
        bundle_digest: "sha256:bundle",
        observed_at: 1
      )

    assert {:error, :spiffe_pdp_binding_mismatch} = PDPBinding.admit(metadata, wrong_td, binding)
  end

  test "refusal: jwt SVID is refused unless the binding opts in", %{
    metadata: metadata,
    binding: binding
  } do
    {:ok, jwt} =
      AttestedIdentity.from_verified("spiffe://prod.example/pdp/authzen",
        svid_type: :jwt,
        bundle_digest: "sha256:bundle",
        observed_at: 1
      )

    assert {:error, :spiffe_pdp_binding_mismatch} = PDPBinding.admit(metadata, jwt, binding)
  end

  test "opt-in: allow_jwt: true admits a jwt SVID", %{metadata: metadata} do
    {:ok, jwt} =
      AttestedIdentity.from_verified("spiffe://prod.example/pdp/authzen",
        svid_type: :jwt,
        bundle_digest: "sha256:bundle",
        observed_at: 1
      )

    binding = %PDPBinding{
      policy_decision_point: @pdp,
      spiffe_id: "spiffe://prod.example/pdp/authzen",
      trust_domain: "prod.example",
      allow_jwt: true
    }

    assert :ok = PDPBinding.admit(metadata, jwt, binding)
  end

  test "refusal: pdp_mixup passes through from Metadata.bind_expected/2", %{
    metadata: metadata,
    attested: attested,
    binding: binding
  } do
    assert {:error, :pdp_mixup} =
             PDPBinding.admit(metadata, attested, %{
               binding
               | policy_decision_point: "https://other.example"
             })
  end

  ## ordering: binding refusals precede any HTTP

  test "fail-closed: a binding mismatch refuses before the PDP is consulted", %{
    table: table,
    base_url: base_url,
    metadata: metadata,
    binding: binding
  } do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{})
    ctx = authority_ctx()
    request = AuthorityRequest.new(effect, ctx)

    client =
      real_client(
        %{metadata | access_evaluation_endpoint: base_url <> "/access/v1/evaluation"},
        2_000
      )

    {:ok, imposter} =
      AttestedIdentity.from_verified("spiffe://prod.example/pdp/other",
        svid_type: :x509,
        bundle_digest: "sha256:bundle",
        observed_at: 1
      )

    assert {:error, :spiffe_pdp_binding_mismatch} =
             Absorption.authorize(request, client, imposter, binding, ctx)

    assert request_count(table) == 0
  end

  ## (c) fail-closed over the real HTTP stack: PDP failure never becomes an allow

  test "fail-closed: an unreachable PDP is a typed refusal, not a pass", %{
    table: table,
    base_url: base_url,
    metadata: metadata,
    attested: attested,
    binding: binding
  } do
    effect = PreparedEffect.new("principal:alive-pdp", :payments, %{"id" => 42}, %{})
    ctx = authority_ctx()
    request = AuthorityRequest.new(effect, ctx)

    client =
      real_client(
        %{metadata | access_evaluation_endpoint: base_url <> "/access/v1/evaluation"},
        2_000
      )

    # A healthy PDP first: the binding admits and the round-trip succeeds.
    assert {:ok, _response, _receipt} =
             Absorption.authorize(request, client, attested, binding, ctx)

    assert request_count(table) == 1

    # Deterministic dead PDP: we hold a bound-but-silent listener on a FRESH
    # ephemeral port — the kernel cannot hand it to another test's stub, and
    # the connection blackholes to a real Finch receive timeout, one of the
    # transport-failure classes `DecisionPool.post/4` collapses to
    # `:pdp_unreachable` (decision_pool.ex:83-85). Unlike the kill-the-server
    # flow, no other async test's Bandit can inherit the port and silently
    # answer.
    {:ok, latch} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false, backlog: 1)
    {:ok, dead_port} = :inet.port(latch)

    dead_client =
      real_client(
        %{
          metadata
          | access_evaluation_endpoint: "http://127.0.0.1:#{dead_port}/access/v1/evaluation"
        },
        150
      )

    assert {:error, :pdp_unreachable} =
             Absorption.authorize(request, dead_client, attested, binding, ctx)

    # The dead PDP was consulted zero times; no silent pass, no receipt.
    assert request_count(table) == 1

    :gen_tcp.close(latch)
  end

  test "fail-closed: a stalled PDP hits the receive timeout and is a typed refusal", %{
    metadata: metadata,
    attested: attested,
    binding: binding
  } do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => "hang"}, %{})
    ctx = authority_ctx()
    request = AuthorityRequest.new(effect, ctx)

    table = :ets.new(:"pdp_binding_court_stall_#{System.unique_integer()}", [:set, :public])
    :ets.insert(table, {:request_count, 0})

    %{pid: stalled_pid, base_url: stalled_base} =
      EphemeralHttp.start!({PDP, %{table: table, stall_ms: 5_000}})

    client =
      real_client(
        %{metadata | access_evaluation_endpoint: stalled_base <> "/access/v1/evaluation"},
        100
      )

    assert {:error, :pdp_unreachable} =
             Absorption.authorize(request, client, attested, binding, ctx)

    assert request_count(table) == 1

    true = Process.unlink(stalled_pid)
    Process.exit(stalled_pid, :shutdown)
  end

  test "fail-closed: a non-200 PDP answer is a typed refusal", %{
    base_url: base_url,
    metadata: metadata,
    attested: attested,
    binding: binding
  } do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => "boom"}, %{})
    request = AuthorityRequest.new(effect, authority_ctx())

    client =
      real_client(
        %{metadata | access_evaluation_endpoint: base_url <> "/access/v1/evaluation"},
        2_000
      )

    assert {:error, {:pdp_error, 500}} =
             Absorption.authorize(request, client, attested, binding, authority_ctx())
  end

  test "fail-closed: a malformed 200 body is a typed refusal", %{
    base_url: base_url,
    metadata: metadata,
    attested: attested,
    binding: binding
  } do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => "garbage"}, %{})
    request = AuthorityRequest.new(effect, authority_ctx())

    client =
      real_client(
        %{metadata | access_evaluation_endpoint: base_url <> "/access/v1/evaluation"},
        2_000
      )

    assert {:error, :invalid_decision} =
             Absorption.authorize(request, client, attested, binding, authority_ctx())
  end

  ## helpers

  # DEFECT (reported, not fixed — lib/ is not this lane's file):
  # `AshA2A.AuthZEN.Client.new/2`'s default transport (client.ex:39-43) is
  # doubly incompatible with its only caller, `Client.evaluate/2`
  # (client.ex:51-58, the path `AshA2A.AuthZEN.Absorption.authorize/5` uses):
  #
  #   1. inbound: evaluate/2 hands the transport the RAW `Wire.request/1` map,
  #      but the default transport passes it unchanged to
  #      `DecisionPool.post/4` → Finch requires iodata, so every real-PDP
  #      Absorption evaluation raises `(ArgumentError) not an iodata term` in
  #      Mint instead of returning a decision or a typed refusal;
  #   2. outbound: even with the body encoded, `DecisionPool.post/4` returns
  #      `{:ok, status, body_binary}`, while evaluate/2 feeds the transport
  #      result straight to `decode_and_stamp/2`, which requires a DECODED
  #      map — every real 2xx answer would collapse to
  #      `{:error, :invalid_decision}`.
  #
  # The path is only exercisable today with a hand-injected transport (as in
  # absorption_test.exs). This court composes the real DecisionPool HTTP stack
  # with the two missing seams (Jason.encode!/1 out, Jason.decode!/1 in,
  # non-2xx/transport failures preserved as DecisionPool's typed errors) — the
  # shim exists to make the defect visible; every Absorption case here
  # re-proves the real stack works once the seam is closed.
  defp real_client(metadata, timeout) do
    %Client{
      metadata: metadata,
      transport: fn endpoint, wire_map ->
        case DecisionPool.post(
               endpoint,
               Jason.encode!(wire_map),
               [{"content-type", "application/json"}, {"accept", "application/json"}],
               receive_timeout: timeout
             ) do
          {:ok, _status, body} ->
            case Jason.decode(body) do
              {:ok, raw} -> {:ok, raw}
              :error -> {:error, :invalid_decision}
            end

          error ->
            error
        end
      end
    }
  end

  defp authority_ctx do
    %{
      policy_epoch: 1,
      revocation_epoch: 2,
      generation: 3,
      audience: "actuator:payments",
      local_certificate_issuer: __MODULE__.LocalIssuer
    }
  end

  defmodule LocalIssuer do
    @moduledoc """
    Real hand-written certificate issuer (same pattern as
    `AshA2A.AuthZEN.AbsorptionTest.LocalIssuer`): a real interface
    implementation, not a mock.
    """

    def issue(request, _ctx) do
      {:ok,
       %Certificate{
         version: 1,
         effect_digest: request.effect_digest,
         principal: request.principal,
         policy_epoch: request.policy_epoch,
         revocation_epoch: request.revocation_epoch,
         generation: request.generation,
         nonce: "0123456789abcdef",
         not_before_ms: 0,
         expires_at_ms: 10_000,
         audience: request.audience,
         threshold: 1,
         signatures: []
       }}
    end
  end

  defp fetch_metadata!(base_url) do
    {:ok, %Req.Response{status: 200, body: body}} =
      Req.get(base_url <> "/.well-known/authzen-configuration", receive_timeout: 2_000)

    assert {:ok, %Metadata{} = metadata} = Metadata.decode(body)
    metadata
  end

  defp request_count(table), do: :ets.lookup_element(table, :request_count, 2)
end

# --- SECTION 18: Original test/authority/graph_pin_test.exs ---
defmodule AshA2A.Authority.GraphPinTest do
  @moduledoc """
  Court for the AshA2A.Authority.GraphPin seam (lane Z12).

  Ladder: pin -> fresh :ok -> mutate digest -> stale refused -> re-pin
  recovers. Also: fail-closed unpinned, invalid-digest refuse, format
  parity with the HILT WorkOrder carried digest, and a pluggable-store
  proof (real second implementation, not a mock).
  """

  use ExUnit.Case, async: true

  alias AshA2A.Authority.GraphPin
  alias AshA2A.Authority.GraphPin.Store

  @digest "sha256:" <> String.duplicate("ab", 32)
  @other_digest "sha256:" <> String.duplicate("cd", 32)

  defmodule EtsStore do
    @moduledoc "Real second store implementation: proves the behaviour seam."
    @behaviour Store

    def init, do: :ets.new(__MODULE__, [:set, :public, :named_table])

    @impl Store
    def get(order_id) do
      case :ets.lookup(__MODULE__, order_id) do
        [{_, d}] -> d
        [] -> nil
      end
    end

    @impl Store
    def put(order_id, digest), do: :ets.insert(__MODULE__, {order_id, digest}) && :ok
  end

  setup do
    EtsStore.init()
    :ok
  end

  test "pin -> fresh :ok -> mutate -> :stale_graph_identity -> re-pin recovers" do
    assert :ok = GraphPin.pin("order-1", @digest)
    assert :ok = GraphPin.assert_fresh("order-1", @digest)

    # graph mutated under the order
    assert {:error, :stale_graph_identity} = GraphPin.assert_fresh("order-1", @other_digest)

    # re-pin recovers
    assert :ok = GraphPin.pin("order-1", @other_digest)
    assert :ok = GraphPin.assert_fresh("order-1", @other_digest)
    assert {:error, :stale_graph_identity} = GraphPin.assert_fresh("order-1", @digest)
  end

  test "unpinned order is fail-closed :unpinned, never :ok" do
    assert {:error, :unpinned} = GraphPin.assert_fresh("never-admitted", @digest)
  end

  test "invalid digests are refused on both ports" do
    assert {:error, :invalid_digest} = GraphPin.pin("order-2", "not-a-digest")
    assert {:error, :invalid_digest} = GraphPin.pin("order-2", "sha256:ZZ")

    assert :ok = GraphPin.pin("order-2", @digest)
    assert {:error, :invalid_digest} = GraphPin.assert_fresh("order-2", nil)
    assert {:error, :invalid_digest} = GraphPin.assert_fresh("order-2", "sha256:ZZ")
  end

  test "digest format matches HILT WorkOrder carried digests" do
    order =
      AshA2A.Hilt.WorkOrder.new!(
        work_order_id: "wo-z12",
        task_id: "task-z12",
        exact_subject_digest: "subj",
        candidate_digest: "cand",
        capability_id: "cap-z12",
        observation_bounds_digest: "ob",
        action_bounds_digest: "ab",
        authority_ceiling: :observe,
        consequence_class: :observe,
        process_evidence_digest: "pe",
        falsifier_digest: "f",
        graph_digest: @digest
      )

    assert order.graph_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert :ok = GraphPin.pin(order.work_order_id, order.graph_digest)
    assert :ok = GraphPin.assert_fresh(order.work_order_id, order.graph_digest)
  end

  test "pluggable store: ETS backend preserves the same contract" do
    assert :ok = GraphPin.pin("order-ets", @digest, store: EtsStore)
    assert :ok = GraphPin.assert_fresh("order-ets", @digest, store: EtsStore)

    assert {:error, :stale_graph_identity} =
             GraphPin.assert_fresh("order-ets", @other_digest, store: EtsStore)

    assert {:error, :unpinned} = GraphPin.assert_fresh("order-ets", @digest)
  end

  test "pins are order-keyed: one order's mutation does not affect another" do
    assert :ok = GraphPin.pin("order-a", @digest)
    assert :ok = GraphPin.pin("order-b", @other_digest)
    assert :ok = GraphPin.assert_fresh("order-a", @digest)
    assert :ok = GraphPin.assert_fresh("order-b", @other_digest)
  end
end

# --- SECTION 19: Original test/authority/pep_hardening_test.exs ---
defmodule AshA2A.Authority.PEPHardeningTest do
  use ExUnit.Case, async: true

  alias AshA2A.Authority.{GraphPin, PEP, Source}

  defmodule Raiser do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: raise("boom")
  end

  defmodule Thrower do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: throw(:nope)
  end

  defmodule Exiter do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: exit(:gone)
  end

  defmodule Extra do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: {:ok, %{extra: 1}}
  end

  defmodule Denier do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: {:deny, :why}
  end

  defmodule Garbage do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: String.duplicate("secret", 100)
  end

  defmodule NotASource do
    def check(_, _, _, _), do: :ok
  end

  defp run(src, scope \\ "a2a:x"), do: PEP.assert_standing("a", scope, %{}, source: src)

  test "raise/throw/exit become typed refusals" do
    assert {:refused, :insufficient_authority, %{reason: :source_raised}} = run(Raiser)
    assert {:refused, :insufficient_authority, %{reason: :source_threw}} = run(Thrower)
    assert {:refused, :insufficient_authority, %{reason: :source_exited}} = run(Exiter)
  end

  test "unloaded module refused" do
    assert {:refused, :insufficient_authority, %{reason: :source_raised}} =
             run(Does.Not.Exist)
  end

  test "malformed :source values refused" do
    for bad <- [nil, "str", {Raiser}, {Extra, :nope}, 42, [Extra]] do
      assert {:refused, :insufficient_authority, %{reason: :invalid_source}} = run(bad)
    end
  end

  test "non-list opts and bad actor refused" do
    assert {:refused, :insufficient_authority, %{reason: :invalid_opts}} =
             PEP.assert_standing("a", "s", %{}, :bad)

    assert {:refused, :insufficient_authority, %{reason: :invalid_actor_id}} =
             PEP.assert_standing(nil, "s", %{}, [])
  end

  test "{:ok, extra} admits; {:deny, r} refuses" do
    assert :ok = run(Extra)
    assert {:refused, _, %{reason: :source_deny, deny_reason: ":why"}} = run(Denier)
  end

  test "scope shapes: string-key map and struct refused, atom-key map ok" do
    assert {:refused, _, %{reason: {:invalid_scope_missing_action, _}}} =
             run(Extra, %{"action" => "a"})

    assert {:refused, _, %{reason: :invalid_scope}} = run(Extra, URI.parse("x"))
    assert :ok = run(Extra, %{action: "a"})
  end

  test "raw return is redacted and bounded" do
    {:refused, _, %{got: got}} = run(Garbage)
    assert is_binary(got) and byte_size(got) < 100
  end

  test "delegate enforces Source behaviour" do
    assert :ok = PEP.delegate("a", "s", %{}, Extra)

    assert {:refused, _, %{reason: :delegate_not_a_source}} =
             PEP.delegate("a", "s", %{}, NotASource)

    assert {:refused, _, %{reason: :invalid_source}} = PEP.delegate("a", "s", %{}, nil)
  end

  test "Source.resolve single implementation" do
    assert {:ok, {Extra, []}} = Source.resolve(Extra)
    assert {:error, :invalid_source} = Source.resolve(nil)
  end

  test "AllowAll refuses in prod" do
    assert {:deny, :allow_all_in_prod} = Source.AllowAll.__check__(:prod, "a", "s", %{}, [])
    assert :ok = Source.AllowAll.__check__(:test, "a", "s", %{}, [])
  end

  describe "GraphPin" do
    @d "sha256:" <> String.duplicate("a", 64)

    test "typed errors for bad inputs" do
      assert {:error, :invalid_digest} = GraphPin.pin("o", nil)
      assert {:error, :invalid_digest} = GraphPin.pin("o", "x")
      assert {:error, :invalid_order_id} = GraphPin.pin(nil, @d)
      assert {:error, :invalid_order_id} = GraphPin.assert_fresh(1, @d)
    end

    defmodule BadStore do
      def put(_, _), do: :weird
      def get(_), do: nil
    end

    test "store.put return validated" do
      assert {:error, {:store_error, {:invalid_return, :weird}}} =
               GraphPin.pin("o", @d, store: BadStore)
    end

    test "concurrent first start tolerated" do
      if pid = Process.whereis(GraphPin.Store.Memory), do: Agent.stop(pid)

      results =
        1..20
        |> Task.async_stream(fn i -> GraphPin.pin("order-#{i}", @d) end)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &(&1 == :ok))
      assert :ok = GraphPin.assert_fresh("order-1", @d)
    end
  end
end

# --- SECTION 20: Original test/authority/pep_test.exs ---
defmodule AshA2A.Authority.PEPTest do
  use ExUnit.Case, async: true

  alias AshA2A.Authority.PEP

  describe "default DenyAll" do
    test "refuses everything with typed refusal" do
      assert {:refused, :insufficient_authority,
              %{reason: :source_deny, actor_id: "actor-1", action: "a2a:task.send"}} =
               PEP.assert_standing("actor-1", "a2a:task.send", %{})
    end
  end

  describe "AllowAll (tests only)" do
    test "admits" do
      assert :ok =
               PEP.assert_standing("actor-1", "a2a:task.send", %{},
                 source: AshA2A.Authority.Source.AllowAll
               )
    end
  end

  describe "custom Source" do
    defmodule ScopeAllow do
      @behaviour AshA2A.Authority.Source

      @impl true
      def check("admin", "a2a:kill", _ctx, _opts), do: :ok
      def check(_a, _act, _ctx, _opts), do: :deny
    end

    test "honors the custom source decision" do
      assert :ok = PEP.assert_standing("admin", "a2a:kill", %{}, source: ScopeAllow)

      assert {:refused, :insufficient_authority, _} =
               PEP.assert_standing("pleb", "a2a:kill", %{}, source: ScopeAllow)
    end

    test "{module, opts} form is honored" do
      defmodule OptsEcho do
        @behaviour AshA2A.Authority.Source

        @impl true
        def check(_a, _act, _ctx, opts), do: if(opts[:mode] == :open, do: :ok, else: :deny)
      end

      assert :ok = PEP.assert_standing("x", "s", %{}, source: {OptsEcho, mode: :open})

      assert {:refused, :insufficient_authority, _} =
               PEP.assert_standing("x", "s", %{}, source: {OptsEcho, mode: :closed})
    end

    test "unexpected source return is typed refusal, never raise" do
      defmodule Broken do
        @behaviour AshA2A.Authority.Source

        @impl true
        def check(_a, _act, _ctx, _opts), do: :garbage
      end

      assert {:refused, :insufficient_authority, %{reason: :invalid_source_return}} =
               PEP.assert_standing("x", "s", %{}, source: Broken)
    end
  end

  describe "scope normalization (fail-closed, never raise)" do
    test "binary scope ok" do
      assert :ok =
               PEP.assert_standing("a", "x:y", %{}, source: AshA2A.Authority.Source.AllowAll)
    end

    test "map with binary :action ok" do
      assert :ok =
               PEP.assert_standing("a", %{action: "x:y", resource: "r"}, %{},
                 source: AshA2A.Authority.Source.AllowAll
               )
    end

    test "nil scope -> typed refusal" do
      assert {:refused, :insufficient_authority, %{reason: :invalid_scope}} =
               PEP.assert_standing("a", nil, %{}, source: AshA2A.Authority.Source.AllowAll)
    end

    test "atom/integer/list scope -> typed refusal" do
      for bad <- [:atom_scope, 42, ["list"]] do
        assert {:refused, :insufficient_authority, %{reason: :invalid_scope}} =
                 PEP.assert_standing("a", bad, %{}, source: AshA2A.Authority.Source.AllowAll)
      end
    end

    test "empty binary scope -> typed refusal" do
      assert {:refused, :insufficient_authority, %{reason: :invalid_scope}} =
               PEP.assert_standing("a", "", %{}, source: AshA2A.Authority.Source.AllowAll)
    end

    test "map missing :action -> typed refusal" do
      assert {:refused, :insufficient_authority, %{reason: {:invalid_scope_missing_action, _}}} =
               PEP.assert_standing("a", %{resource: "r"}, %{},
                 source: AshA2A.Authority.Source.AllowAll
               )
    end

    test "map with non-binary :action -> typed refusal" do
      assert {:refused, :insufficient_authority, %{reason: {:invalid_scope_action, :atom}}} =
               PEP.assert_standing("a", %{action: :atom}, %{},
                 source: AshA2A.Authority.Source.AllowAll
               )
    end
  end

  describe "pin_graph_digest/2 passthrough" do
    test "pins the Hilt.WorkOrder identity digest" do
      wo =
        AshA2A.Hilt.WorkOrder.new!(
          work_order_id: "wo-1",
          task_id: "t-1",
          exact_subject_digest: "sha256:" <> String.duplicate("a", 64),
          candidate_digest: "sha256:" <> String.duplicate("b", 64),
          capability_id: "cap-1",
          observation_bounds_digest: "sha256:" <> String.duplicate("c", 64),
          action_bounds_digest: "sha256:" <> String.duplicate("d", 64),
          authority_ceiling: :observe,
          consequence_class: :observe,
          process_evidence_digest: "sha256:" <> String.duplicate("e", 64),
          falsifier_digest: "sha256:" <> String.duplicate("f", 64)
        )

      assert {:ok, digest} = PEP.pin_graph_digest(wo)
      assert digest == AshA2A.Hilt.WorkOrder.identity_digest(wo)
    end
  end

  describe "delegate/4" do
    test "typed refusal carries the same vocabulary" do
      assert {:refused, :insufficient_authority, _} =
               PEP.delegate("a", "s", %{}, AshA2A.Authority.Source.DenyAll)
    end
  end
end
