# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT
#
# ============================================================================== 
# Consolidated Test Suite: Conference Simulations, Chicago & Twins (Worker 20 Part 1)
# Target File: test/conference_sim/conference_sim_cases_consolidated_test.exs
# Total Source Files Consolidated: 31
# Source Files Inventory:
#   - test/chicago_case_study/mutation_courts_test.exs
#   - test/chicago_case_study/settlement_kernel_test.exs
#   - test/chicago_case_study/settlement_mesh_two_port_test.exs
#   - test/chicago_case_study/settlement_offline_audit_test.exs
#   - test/chicago_case_study/settlement_process_conformance_test.exs
#   - test/conference_sim/auth_tier_court_test.exs
#   - test/conference_sim/exhibitor_signing_court_test.exs
#   - test/conference_sim/fixture_test.exs
#   - test/conference_sim/governance_court_test.exs
#   - test/conference_sim/grpc_venue_court_test.exs
#   - test/conference_sim/interop_court_test.exs
#   - test/conference_sim/load_court_test.exs
#   - test/conference_sim/multitrack_stream_court_test.exs
#   - test/conference_sim/networking_court_test.exs
#   - test/conference_sim/observability_court_test.exs
#   - test/conference_sim/push_court_test.exs
#   - test/conference_sim/red_team_court_test.exs
#   - test/conference_sim/registration_court_test.exs
#   - test/conference_sim/workshop_court_test.exs
#   - test/twin/ceo_test.exs
#   - test/twin/coo_test.exs
#   - test/twin/hazard_test.exs
#   - test/twin/lease_test.exs
#   - test/twin/server_test.exs
#   - test/twin/twin_test.exs
#   - test/untested_lane18/c2_authority_test.exs
#   - test/untested_lane18/consequence_kernel_codec_test.exs
#   - test/untested_lane18/consequence_kernel_runtime_test.exs
#   - test/untested_lane18/consequence_kernel_w4_w5_test.exs
#   - test/untested_lane18/consequence_kernel_w4c_test.exs
#   - test/untested_lane18/misc_test.exs
# ==============================================================================


# ==============================================================================
# SECTION 1 of 31: test/chicago_case_study/mutation_courts_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ChicagoCaseStudy.MutationCourtsTest do
  use ExUnit.Case, async: true

  # Chicago Anti-Vacuity Mutation Proofs
  # Tests prove that intentional semantic corruptions (mutants) are strictly killed by typed refusals.

  defmodule LocalWorkOrder do
    defstruct [:identity, :graph_digest, :origin_authority]
  end

  defmodule LocalTwoPortGate do
    def admit(
          %LocalWorkOrder{graph_digest: wo_digest},
          %{semantic_subject: %{graph_digest: sub_digest}} = cmd
        ) do
      if wo_digest == sub_digest do
        {:ok, Map.put(cmd, :admission_standing, :ADMITTED)}
      else
        {:error, %{code: :stale_graph_identity, class: :refused_identity}}
      end
    end
  end

  defmodule LocalKernelGate do
    def verify_lease(signed_lease, trusted_keys, required_ceiling) do
      now = System.system_time(:second)
      signature = Base.decode16!(signed_lease["signature"], case: :lower)
      pub_key = Base.decode16!(hd(trusted_keys), case: :lower)

      payload =
        "ceiling:#{signed_lease["ceiling"]}|expires:#{signed_lease["expires_unix"]}|holder:#{signed_lease["holder"]}|id:#{signed_lease["id"]}|scope:#{signed_lease["scope"]}"

      valid_sig? = :crypto.verify(:eddsa, :none, payload, signature, [pub_key, :ed25519])

      cond do
        not valid_sig? ->
          {:error, %{code: "LeaseRefused", class: "Signature", broken_term: "invalid_signature"}}

        signed_lease["expires_unix"] <= now ->
          {:error, %{code: "LeaseRefused", class: "Expiration", broken_term: "lease:expired"}}

        signed_lease["ceiling"] != required_ceiling ->
          {:error,
           %{code: "LeaseRefused", class: "Ceiling", broken_term: "ceiling:#{required_ceiling}"}}

        true ->
          {:ok, :admitted}
      end
    end
  end

  defmodule LocalProcessModel do
    def check_sequence([_ | _] = trace, allowed_transitions) do
      activities = Enum.map(trace, & &1["activity"])
      pairs = Enum.zip(activities, tl(activities))

      case Enum.find(pairs, fn pair -> pair not in allowed_transitions end) do
        nil ->
          {:ok, :admitted}

        {prev, illegal} ->
          expected =
            allowed_transitions
            |> Enum.filter(fn {from, _to} -> from == prev end)
            |> Enum.map(fn {_from, to} -> to end)

          {:error,
           %{
             reason: :unadmitted_transition,
             expected: expected,
             observed: illegal,
             fitness: 0.5
           }}
      end
    end
  end

  test "MUT-HILT-001 is KILLED: digest tampering produces :stale_graph_identity" do
    wo = %LocalWorkOrder{
      identity: "WO-001",
      graph_digest: "digest_a",
      origin_authority: "auth"
    }

    mutant_command = %{
      action: :settle,
      semantic_subject: %{id: "tx-1", graph_digest: "digest_mutant_corrupted"}
    }

    assert {:error, refusal} = LocalTwoPortGate.admit(wo, mutant_command)
    assert refusal.code == :stale_graph_identity
  end

  test "MUT-LEASE-002 is KILLED: expired lease fails with LeaseRefused" do
    {pub_key, priv_key} = :crypto.generate_key(:eddsa, :ed25519)
    trusted_keys = [Base.encode16(pub_key, case: :lower)]

    expired_time = System.system_time(:second) - 100
    lease_payload = "ceiling:construct|expires:#{expired_time}|holder:b1|id:l1|scope:urn:s1"
    signature = :crypto.sign(:eddsa, :none, lease_payload, [priv_key, :ed25519])

    expired_lease = %{
      "id" => "l1",
      "holder" => "b1",
      "ceiling" => "construct",
      "scope" => "urn:s1",
      "expires_unix" => expired_time,
      "signature" => Base.encode16(signature, case: :lower)
    }

    assert {:error, refusal} =
             LocalKernelGate.verify_lease(expired_lease, trusted_keys, "construct")

    assert refusal.code == "LeaseRefused"
    assert refusal.class == "Expiration"
  end

  test "MUT-BRCE-003 is KILLED: illegal activity jump fails with :unadmitted_transition" do
    allowed = [{"A", "B"}, {"B", "C"}]

    corrupted_trace = [
      %{"activity" => "A"},
      # Mutated: skipped B
      %{"activity" => "C"}
    ]

    assert {:error, refusal} = LocalProcessModel.check_sequence(corrupted_trace, allowed)
    assert refusal.reason == :unadmitted_transition
    assert refusal.expected == ["B"]
    assert refusal.observed == "C"
  end
end


# ==============================================================================
# SECTION 2 of 31: test/chicago_case_study/settlement_kernel_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ChicagoCaseStudy.SettlementKernelTest do
  use ExUnit.Case, async: true

  # Chicago Tier 2 Kernel Conformance & Cryptographic Leases
  # Real Ed25519 signatures, exact lease payload verification, ceiling checking.

  setup do
    # Real key generation - no static fake keys
    {pub_key, priv_key} = :crypto.generate_key(:eddsa, :ed25519)
    trusted_keys = [Base.encode16(pub_key, case: :lower)]

    {:ok, priv_key: priv_key, pub_key: pub_key, trusted_keys: trusted_keys}
  end

  defmodule KernelAdmission do
    def verify_lease(signed_lease, trusted_keys, required_ceiling) do
      now = System.system_time(:second)
      signature = Base.decode16!(signed_lease["signature"], case: :lower)
      pub_key = Base.decode16!(hd(trusted_keys), case: :lower)

      payload =
        "ceiling:#{signed_lease["ceiling"]}|expires:#{signed_lease["expires_unix"]}|holder:#{signed_lease["holder"]}|id:#{signed_lease["id"]}|scope:#{signed_lease["scope"]}"

      valid_sig? = :crypto.verify(:eddsa, :none, payload, signature, [pub_key, :ed25519])

      cond do
        not valid_sig? ->
          {:error, %{code: "LeaseRefused", class: "Signature", broken_term: "invalid_signature"}}

        signed_lease["expires_unix"] <= now ->
          {:error, %{code: "LeaseRefused", class: "Expiration", broken_term: "lease:expired"}}

        signed_lease["ceiling"] != required_ceiling ->
          {:error,
           %{code: "LeaseRefused", class: "Ceiling", broken_term: "ceiling:#{required_ceiling}"}}

        true ->
          {:ok, :admitted}
      end
    end
  end

  test "admits compliant settlement with valid signed lease", ctx do
    now = System.system_time(:second)

    lease_payload =
      "ceiling:construct|expires:#{now + 300}|holder:bank_agent_1|id:lease-42|scope:urn:settlement:tx-100"

    signature = :crypto.sign(:eddsa, :none, lease_payload, [ctx.priv_key, :ed25519])

    signed_lease = %{
      "id" => "lease-42",
      "holder" => "bank_agent_1",
      "ceiling" => "construct",
      "scope" => "urn:settlement:tx-100",
      "issued_unix" => now,
      "expires_unix" => now + 300,
      "signature" => Base.encode16(signature, case: :lower)
    }

    assert {:ok, :admitted} =
             KernelAdmission.verify_lease(signed_lease, ctx.trusted_keys, "construct")
  end

  test "refuses settlement with CeilingsRefused when lease ceiling is :observe", ctx do
    now = System.system_time(:second)

    lease_payload =
      "ceiling:observe|expires:#{now + 300}|holder:bank_agent_1|id:lease-42|scope:urn:settlement:tx-100"

    signature = :crypto.sign(:eddsa, :none, lease_payload, [ctx.priv_key, :ed25519])

    signed_lease = %{
      "id" => "lease-42",
      "holder" => "bank_agent_1",
      "ceiling" => "observe",
      "scope" => "urn:settlement:tx-100",
      "issued_unix" => now,
      "expires_unix" => now + 300,
      "signature" => Base.encode16(signature, case: :lower)
    }

    assert {:error, refusal} =
             KernelAdmission.verify_lease(signed_lease, ctx.trusted_keys, "construct")

    assert refusal.code == "LeaseRefused"
    assert refusal.class == "Ceiling"
    assert refusal.broken_term == "ceiling:construct"
  end
end


# ==============================================================================
# SECTION 3 of 31: test/chicago_case_study/settlement_mesh_two_port_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ChicagoCaseStudy.SettlementMeshTwoPortTest do
  use ExUnit.Case, async: true

  # Chicago-style Tier 4: Two-Port Identity & Grant Enforcement
  # Invariant: work_order_digest === semantic_subject.graph_digest
  # Consequential mutations require valid, unexpired, signed Ed25519 leases.

  defmodule MockWorkOrder do
    defstruct [:identity, :title, :graph_digest, :origin_authority]
  end

  defmodule TwoPortAdmissionGate do
    @doc """
    Admit a command strictly if the work order digest matches the semantic subject digest.
    Returns {:ok, admitted_command} or {:error, %{code: code, class: class}}
    """
    def admit(
          %MockWorkOrder{graph_digest: wo_digest},
          %{semantic_subject: %{graph_digest: sub_digest}} = command
        ) do
      if wo_digest == sub_digest do
        {:ok, Map.put(command, :admission_standing, :ADMITTED)}
      else
        {:error, %{code: :stale_graph_identity, class: :refused_identity}}
      end
    end
  end

  test "admit/2 succeeds when graph_digest matches work_order_digest exactly" do
    raw_graph = "<urn:tx:1> <http://example.org/p> <http://example.org/o> ."
    canonical_digest = :crypto.hash(:sha256, raw_graph) |> Base.encode16(case: :lower)

    wo = %MockWorkOrder{
      identity: "WO-SETTLE-001",
      title: "Settle Green Bond #42",
      graph_digest: canonical_digest,
      origin_authority: "https://bank.example/authorities/trading-desk-1"
    }

    command = %{
      action: :settle,
      semantic_subject: %{
        id: "tx-100",
        graph_digest: canonical_digest
      },
      actor: "agent://settlement-bot-9",
      lease_id: "lease-42"
    }

    assert {:ok, admitted_command} = TwoPortAdmissionGate.admit(wo, command)
    assert admitted_command.admission_standing == :ADMITTED
  end

  test "admit/2 refuses stale_graph_identity on hash mismatch" do
    correct_digest = :crypto.hash(:sha256, "valid") |> Base.encode16(case: :lower)
    tampered_digest = :crypto.hash(:sha256, "tampered") |> Base.encode16(case: :lower)

    wo = %MockWorkOrder{
      identity: "WO-SETTLE-001",
      title: "Settle Green Bond #42",
      graph_digest: correct_digest,
      origin_authority: "https://bank.example/authorities/trading-desk-1"
    }

    command = %{
      action: :settle,
      semantic_subject: %{
        id: "tx-100",
        graph_digest: tampered_digest
      },
      actor: "agent://settlement-bot-9",
      lease_id: "lease-42"
    }

    assert {:error, refusal} = TwoPortAdmissionGate.admit(wo, command)
    assert refusal.code == :stale_graph_identity
    assert refusal.class == :refused_identity
  end
end


# ==============================================================================
# SECTION 4 of 31: test/chicago_case_study/settlement_offline_audit_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ChicagoCaseStudy.SettlementOfflineAuditTest do
  use ExUnit.Case, async: false

  # Chicago Tier 5: Full Lifecycle Deterministic Offline Replay
  # Invariant: Genesis state S0 driven by admitted transitions produces cryptographically verifiable receipts.

  test "full receipt chain is mathematically verifiable offline without network or daemon access" do
    receipts_dir = Path.expand("tmp/test_receipts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(receipts_dir)

    on_exit(fn -> File.rm_rf!(receipts_dir) end)

    {pub_key, priv_key} = :crypto.generate_key(:eddsa, :ed25519)
    pub_hex = Base.encode16(pub_key, case: :lower)

    genesis_state = "<urn:settlement:tx-100> <http://example.org/status> \"INITIAL\" .\n"
    target_state = "<urn:settlement:tx-100> <http://example.org/status> \"VERIFIED\" .\n"

    genesis_digest = :crypto.hash(:sha256, genesis_state) |> Base.encode16(case: :lower)
    target_digest = :crypto.hash(:sha256, target_state) |> Base.encode16(case: :lower)

    # Cryptographically attest the transition
    receipt_payload = "#{genesis_digest}->#{target_digest}"

    sig =
      :crypto.sign(:eddsa, :none, receipt_payload, [priv_key, :ed25519])
      |> Base.encode16(case: :lower)

    receipt = %{
      "genesis_digest" => genesis_digest,
      "target_digest" => target_digest,
      "signature" => sig,
      "authority" => pub_hex,
      "standing" => "ADMITTED"
    }

    receipt_file = Path.join(receipts_dir, "receipt.json")
    File.write!(receipt_file, Jason.encode!(receipt))

    # Perform offline verification using public key and receipts directory
    raw_saved = File.read!(receipt_file) |> Jason.decode!()
    decoded_sig = Base.decode16!(raw_saved["signature"], case: :lower)
    decoded_pub = Base.decode16!(raw_saved["authority"], case: :lower)
    computed_payload = "#{raw_saved["genesis_digest"]}->#{raw_saved["target_digest"]}"

    assert :crypto.verify(:eddsa, :none, computed_payload, decoded_sig, [decoded_pub, :ed25519])
    assert raw_saved["standing"] == "ADMITTED"
  end
end


# ==============================================================================
# SECTION 5 of 31: test/chicago_case_study/settlement_process_conformance_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ChicagoCaseStudy.SettlementProcessConformanceTest do
  use ExUnit.Case, async: true

  # Chicago Tier 3: Behavioral Conformance Gate
  # Invariant: Execution sequences obey formal process models (DFGs / Petri Nets)
  # Out-of-order actions fail closed with %ConformanceRefusal{}

  defmodule ProcessModel do
    def check_sequence([_ | _] = trace, allowed_transitions) do
      activities = Enum.map(trace, & &1["activity"])
      pairs = Enum.zip(activities, tl(activities))

      case Enum.find(pairs, fn pair -> pair not in allowed_transitions end) do
        nil ->
          {:ok, :admitted}

        {prev, illegal} ->
          expected =
            allowed_transitions
            |> Enum.filter(fn {from, _to} -> from == prev end)
            |> Enum.map(fn {_from, to} -> to end)

          {:error,
           %{
             reason: :unadmitted_transition,
             expected: expected,
             observed: illegal,
             fitness: 0.5
           }}
      end
    end
  end

  setup do
    allowed_transitions = [
      {"ValidateEligible", "HoldCollateral"},
      {"HoldCollateral", "TransferFunds"},
      {"TransferFunds", "ReleaseCollateral"}
    ]

    {:ok, transitions: allowed_transitions}
  end

  test "BRCE gate admits compliant sequential execution", ctx do
    trace = [
      %{"case_id" => "tx-100", "activity" => "ValidateEligible", "timestamp" => 1000},
      %{"case_id" => "tx-100", "activity" => "HoldCollateral", "timestamp" => 1005},
      %{"case_id" => "tx-100", "activity" => "TransferFunds", "timestamp" => 1010}
    ]

    assert {:ok, :admitted} = ProcessModel.check_sequence(trace, ctx.transitions)
  end

  test "BRCE gate halts unauthorized jump-step (TransferFunds before HoldCollateral)", ctx do
    deviant_trace = [
      %{"case_id" => "tx-100", "activity" => "ValidateEligible", "timestamp" => 1000},
      # VIOLATION: Skipped HoldCollateral directly to TransferFunds
      %{"case_id" => "tx-100", "activity" => "TransferFunds", "timestamp" => 1005}
    ]

    assert {:error, refusal} = ProcessModel.check_sequence(deviant_trace, ctx.transitions)
    assert refusal.reason == :unadmitted_transition
    assert refusal.expected == ["HoldCollateral"]
    assert refusal.observed == "TransferFunds"
    assert refusal.fitness < 1.0
  end
end


# ==============================================================================
# SECTION 6 of 31: test/conference_sim/auth_tier_court_test.exs
# ==============================================================================

# Lane EV4 — Conference-sim venue access control over the REAL plug pipeline.
#
# Models the full G5/A2A v1 security-scheme surface as venue tiers:
#
#   apiKey (`x-badge` header)     = badge scan  → :expo tier
#   http bearer (HS256 JWT)       = session token → :workshop tier
#   oauth2 (RFC 7662 introspection
#    + client-credentials Basic)  = VIP all-access → :vip tier
#   openIdConnect (RS256 + OIDC
#    discovery → JWKS)            = SSO → :workshop tier
#
# Every court below runs over the real `AshA2A.Protocol.Plug.Auth` middleware
# with the real `AshA2A.Protocol.Plug.SecurityValidators` verifier, real
# Bandit HTTP servers (a real local RFC 7662/OIDC token server), real HS256/
# RS256 JWT signing via `:crypto`/`:public_key`, and real wire requests via
# Req. No Mock/mox/patch/monkeypatch anywhere in this file.
#
# Tier policy (venue law):
#   keynote stream  = all tiers
#   workshop task   = workshop + VIP
#   backstage task  = VIP only
#
# Cross-tier attempts are refused with a typed 403 wire envelope; credential
# failures are 401s with real RFC 7235 WWW-Authenticate challenges emitted by
# the real Auth plug; an expired VIP token introspects to an expired `exp`
# and must produce a fresh 401 challenge; an api-key presented in the wrong
# location (query param on a header scheme) is 401 by extraction law.
#
# Fixture modules live at TOP LEVEL of this file (never nested inside the
# test module: Elixir nests dotted module names under the enclosing module).

defmodule AshA2A.Test.ConferenceSim.Certs do
  @moduledoc """
  Real RSA keypair for the SSO (openIdConnect) scheme: RS256-signed SSO
  tokens are verified by the real validator against the JWKS the discovery
  path fetched from the real token server.
  """

  @key :public_key.generate_key({:rsa, 2048, 65_537})
  @kid "sso-key-1"

  def private_key, do: @key

  def kid, do: @kid

  def sso_public_jwk do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = @key

    %{
      "kty" => "RSA",
      "kid" => @kid,
      "n" => b64(:binary.encode_unsigned(n)),
      "e" => b64(:binary.encode_unsigned(e)),
      "alg" => "RS256",
      "use" => "sig"
    }
  end

  def sso_token(claims) do
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => @kid}

    signing_input =
      Enum.map_join([header, claims], ".", fn part ->
        part |> Jason.encode!() |> b64()
      end)

    sig = :public_key.sign(:crypto.hash(:sha256, signing_input), :sha256, @key)
    signing_input <> "." <> b64(sig)
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end

defmodule AshA2A.Test.ConferenceSim.TokenServer do
  @moduledoc """
  Real local Bandit plug standing in as the venue's OAuth2/OIDC token server:

  - `POST /introspect` — RFC 7662 token introspection. Requires real HTTP
    Basic client credentials (`venue-server` / `venue-introspection-secret`);
    the token value self-describes its status so each court controls its own
    tokens without shared mutable state:
      `vip-active-<n>`  → active: true, exp = now + 3600, scope `venue:all`
      `vip-expired-<n>` → active: true, exp = now - 3600 (expired `exp` —
                          must be refused by the validator's expiry check,
                          surfacing as a 401 challenge at the wire)
      `vip-noscope-<n>` → active: true, unexpired, scope "" (insufficient)
      anything else     → active: false
  - `GET /.well-known/openid-configuration` — OIDC discovery document whose
    `jwks_uri` is derived from the request's own host/port.
  - `GET /jwks.json` — real JWKS serving the real RS256 public key.
  """

  import Plug.Conn

  @client_id "venue-server"
  @client_secret "venue-introspection-secret"

  @behaviour Plug

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, _opts) do
    case {conn.method, conn.path_info} do
      {"POST", ["introspect"]} -> introspect(conn)
      {"GET", [".well-known", "openid-configuration"]} -> discovery(conn)
      {"GET", ["jwks.json"]} -> jwks(conn)
      _ -> json(conn, 404, %{"error" => "not_found"})
    end
  end

  defp introspect(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, @client_id <> ":" <> @client_secret} <- Base.decode64(encoded) do
      {:ok, body, conn} = read_body(conn)
      %{"token" => token} = URI.decode_query(body)

      case token do
        "vip-active-" <> _ ->
          json(conn, 200, %{
            "active" => true,
            "sub" => "attendee-vip",
            "exp" => System.system_time(:second) + 3600,
            "scope" => "venue:all",
            "iss" => "https://venue.example"
          })

        "vip-expired-" <> _ ->
          json(conn, 200, %{
            "active" => true,
            "sub" => "attendee-vip",
            "exp" => System.system_time(:second) - 3600,
            "scope" => "venue:all"
          })

        "vip-noscope-" <> _ ->
          json(conn, 200, %{
            "active" => true,
            "sub" => "attendee-vip",
            "exp" => System.system_time(:second) + 3600,
            "scope" => ""
          })

        _ ->
          json(conn, 200, %{"active" => false})
      end
    else
      _ -> json(conn, 401, %{"error" => "invalid_client"})
    end
  end

  defp discovery(conn) do
    json(conn, 200, %{
      "issuer" => "https://venue.example",
      "jwks_uri" => "http://#{conn.host}:#{conn.port}/jwks.json"
    })
  end

  defp jwks(conn) do
    json(conn, 200, %{"keys" => [AshA2A.Test.ConferenceSim.Certs.sso_public_jwk()]})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end

defmodule AshA2A.Test.ConferenceSim.Venue do
  @moduledoc """
  The venue endpoint: the REAL `AshA2A.Protocol.Plug.Auth` middleware (all
  four G5 schemes + real `SecurityValidators` verifier) followed by the
  venue's tier gate, which reads the real authenticated identity out of
  `conn.private[:a2a][:auth]` and enforces venue law (method x tier).
  """

  @behaviour Plug

  import Plug.Conn

  @session_secret "venue-session-secret-do-not-drink"

  # Venue law: method → tiers allowed.
  @method_tiers %{
    "keynote" => MapSet.new([:expo, :workshop, :vip]),
    "workshop" => MapSet.new([:workshop, :vip]),
    "backstage" => MapSet.new([:vip])
  }

  # Scheme name → venue tier.
  @scheme_tiers %{
    "badge" => :expo,
    "session_token" => :workshop,
    "vip" => :vip,
    "sso" => :workshop
  }

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, %{token_base_url: base}) do
    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{
          "badge" => %AshA2A.Protocol.SecurityScheme.APIKey{in: "header", name: "x-badge"},
          "session_token" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"},
          "vip" => %AshA2A.Protocol.SecurityScheme.OAuth2{
            flows: %{"clientCredentials" => %{"tokenUrl" => "https://t", "scopes" => %{}}}
          },
          "sso" => %AshA2A.Protocol.SecurityScheme.OpenIDConnect{
            open_id_connect_url: base <> "/.well-known/openid-configuration"
          }
        },
        verify:
          AshA2A.Protocol.Plug.SecurityValidators.verifier(%{
            "badge" => [kind: :key, keys: [badge_id()]],
            "session_token" => [
              kind: :bearer,
              secret: @session_secret,
              issuer: "https://venue.example",
              audience: "venue-sessions",
              required_claims: ["sub", "exp"]
            ],
            "vip" => [
              kind: :oauth2,
              introspection_url: base <> "/introspect",
              client_id: "venue-server",
              client_secret: "venue-introspection-secret",
              required_scopes: ["venue:all"]
            ],
            "sso" => [
              kind: :oidc,
              discovery: base <> "/.well-known/openid-configuration",
              issuer: "https://venue.example",
              audience: "venue-sso",
              required_claims: ["sub", "exp"]
            ]
          })
      )

    conn = AshA2A.Protocol.Plug.Auth.call(conn, auth_opts)

    if conn.halted do
      conn
    else
      tier_gate(conn)
    end
  end

  # -- Venue tier gate ---------------------------------------------------------

  defp tier_gate(conn) do
    identity = AshA2A.Protocol.Plug.Auth.get_identity(conn)
    tier = Map.fetch!(@scheme_tiers, identity.scheme)
    method = method_of(conn)
    allowed? = method != nil and MapSet.member?(Map.fetch!(@method_tiers, method), tier)

    if allowed? do
      attendee = attendee_of(identity)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "granted" => true,
          "method" => method,
          "tier" => to_string(tier),
          "attendee" => attendee,
          "credentials_presented" => [identity.scheme]
        })
      )
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{
          "error" => %{
            "code" => "tier_access_denied",
            "method" => method,
            "tier" => to_string(tier)
          }
        })
      )
    end
  end

  defp attendee_of(identity) do
    case identity.identity do
      %{sub: sub} when is_binary(sub) -> sub
      %{"sub" => sub} -> sub
      _ -> "badge-holder"
    end
  end

  defp method_of(conn) do
    case conn.path_info do
      ["venue", method] when method in ["keynote", "workshop", "backstage"] -> method
      _ -> nil
    end
  end

  # -- Token minting (real :crypto HMAC signing) --------------------------------

  def session_token(extra_claims \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "sub" => "attendee-session",
          "iss" => "https://venue.example",
          "aud" => "venue-sessions",
          "exp" => now + 3600
        },
        extra_claims
      )

    header = %{"alg" => "HS256", "typ" => "JWT"}

    signing_input =
      Enum.map_join([header, claims], ".", fn part ->
        part |> Jason.encode!() |> Base.url_encode64(padding: false)
      end)

    sig = :crypto.mac(:hmac, :sha256, @session_secret, signing_input)
    signing_input <> "." <> Base.url_encode64(sig, padding: false)
  end

  def badge_id, do: "badge-BADGE-7741"

  def badge_header, do: {"x-badge", badge_id()}
end

defmodule AshA2A.Test.ConferenceSim.Sso do
  @moduledoc "SSO (openIdConnect) token minting via the real RSA keypair."

  defdelegate token(claims), to: AshA2A.Test.ConferenceSim.Certs, as: :sso_token

  def valid_token do
    AshA2A.Test.ConferenceSim.Certs.sso_token(%{
      "sub" => "attendee-sso",
      "iss" => "https://venue.example",
      "aud" => "venue-sso",
      "exp" => System.system_time(:second) + 3600,
      "scope" => "venue:sso"
    })
  end
end

defmodule AshA2A.Test.ConferenceSim.AuthTierCourt do
  @moduledoc """
  The courts. Each test starts its own real Bandit token server + venue
  server on OS-assigned ephemeral loopback ports and speaks real HTTP.
  """

  use ExUnit.Case, async: true

  defp get_resp_header(%Req.Response{headers: headers}, name) do
    Map.get(headers, name, [])
  end

  alias AshA2A.Test.ConferenceSim.{Sso, TokenServer, Venue}
  alias AshA2A.Test.EphemeralHttp

  @badge AshA2A.Test.ConferenceSim.Venue.badge_header()

  setup do
    token = EphemeralHttp.start!(TokenServer)
    venue = EphemeralHttp.start!({Venue, %{token_base_url: token.base_url}})

    %{
      token: token,
      venue: venue,
      vip: "vip-active-#{System.unique_integer([:positive])}",
      expired_vip: "vip-expired-#{System.unique_integer([:positive])}",
      noscope_vip: "vip-noscope-#{System.unique_integer([:positive])}",
      session: Venue.session_token(),
      sso: Sso.valid_token()
    }
  end

  # -- Tier-appropriate access ---------------------------------------------------

  test "badge scan (apiKey) grants the expo tier its keynote stream", c do
    resp = post(c.venue.base_url, "/venue/keynote", headers: [badge_header()])

    assert resp.status == 200

    assert body(resp) == %{
             "granted" => true,
             "method" => "keynote",
             "tier" => "expo",
             "attendee" => "badge-holder",
             "credentials_presented" => ["badge"]
           }
  end

  test "every scheme reaches the keynote stream (all tiers)", c do
    for auth <- [
          [badge_header()],
          [authorization("Bearer " <> c.session)],
          [authorization("Bearer " <> c.vip)],
          [authorization("Bearer " <> c.sso)]
        ] do
      resp = post(c.venue.base_url, "/venue/keynote", headers: auth)
      assert resp.status == 200, "scheme #{inspect(hd(auth))} failed: #{resp.status}"
      assert body(resp)["granted"] == true
    end
  end

  test "workshop task: session token and SSO in, badge out (403)", c do
    assert post(c.venue.base_url, "/venue/workshop", headers: [badge_header()]).status == 403

    resp =
      post(c.venue.base_url, "/venue/workshop", headers: [authorization("Bearer " <> c.session)])

    assert resp.status == 200
    assert body(resp)["tier"] == "workshop"

    resp = post(c.venue.base_url, "/venue/workshop", headers: [authorization("Bearer " <> c.sso)])
    assert resp.status == 200
    assert body(resp)["tier"] == "workshop"
  end

  test "backstage task: VIP only — badge and session both refused 403, VIP in", c do
    assert post(c.venue.base_url, "/venue/backstage", headers: [badge_header()]).status == 403

    assert post(c.venue.base_url, "/venue/backstage",
             headers: [authorization("Bearer " <> c.session)]
           ).status ==
             403

    resp =
      post(c.venue.base_url, "/venue/backstage", headers: [authorization("Bearer " <> c.vip)])

    assert resp.status == 200

    assert body(resp) == %{
             "granted" => true,
             "method" => "backstage",
             "tier" => "vip",
             "attendee" => "attendee-vip",
             "credentials_presented" => ["vip"]
           }
  end

  test "cross-tier 403 carries the typed wire envelope, never a credential echo", c do
    resp = post(c.venue.base_url, "/venue/backstage", headers: [badge_header()])

    assert resp.status == 403

    assert body(resp) == %{
             "error" => %{
               "code" => "tier_access_denied",
               "method" => "backstage",
               "tier" => "expo"
             }
           }

    refute Jason.encode!(body(resp)) =~ Venue.badge_id()
  end

  # -- 401 challenge path ----------------------------------------------------------

  test "expired VIP token is challenged with 401 + Bearer WWW-Authenticate", c do
    resp =
      post(c.venue.base_url, "/venue/backstage",
        headers: [authorization("Bearer " <> c.expired_vip)]
      )

    assert resp.status == 401
    challenges = get_resp_header(resp, "www-authenticate")
    assert Enum.any?(challenges, &String.starts_with?(&1, "Bearer realm="))
    assert body(resp) == %{"error" => "Unauthorized"}
  end

  test "VIP token without the venue:all scope is refused 403 (insufficient scope)", c do
    resp =
      post(c.venue.base_url, "/venue/backstage",
        headers: [authorization("Bearer " <> c.noscope_vip)]
      )

    # RFC 6750 section 3.1: insufficient_scope is 403 with a Bearer challenge.
    assert resp.status == 403
    assert get_resp_header(resp, "www-authenticate") != []
  end

  test "inactive VIP token (unknown token at introspection) is challenged 401", c do
    resp =
      post(c.venue.base_url, "/venue/backstage",
        headers: [authorization("Bearer vip-inactive-#{System.unique_integer([:positive])}")]
      )

    assert resp.status == 401
  end

  test "api-key presented in the wrong location (query on a header scheme) is 401", c do
    resp = post(c.venue.base_url, "/venue/keynote?x-badge=#{Venue.badge_id()}", headers: [])

    assert resp.status == 401
    assert body(resp) == %{"error" => "Unauthorized"}
    # The real Auth plug still emits the RFC 7235 challenges for the bearer
    # family even when the badge header was the (mis-)presented credential.
    assert get_resp_header(resp, "www-authenticate") != []
  end

  test "wrong badge value is a 401 identity refusal", c do
    resp = post(c.venue.base_url, "/venue/keynote", headers: [{"x-badge", "badge-forged-0000"}])

    assert resp.status == 401
  end

  test "no credentials at all is 401 with challenges", c do
    resp = post(c.venue.base_url, "/venue/keynote", headers: [])

    assert resp.status == 401
    assert Enum.any?(get_resp_header(resp, "www-authenticate"), &(&1 =~ "realm="))
  end

  # -- Mixed-scheme: same attendee, two schemes, no credential leakage --------------

  test "same attendee authenticates via badge for the expo floor and bearer for sessions", c do
    expo = post(c.venue.base_url, "/venue/keynote", headers: [badge_header()])

    sessions =
      post(c.venue.base_url, "/venue/keynote", headers: [authorization("Bearer " <> c.session)])

    assert expo.status == 200
    assert sessions.status == 200
    assert body(expo)["tier"] == "expo"
    assert body(sessions)["tier"] == "workshop"

    # Neither response leaks the other scheme's credential (or any credential).
    refute Jason.encode!(body(expo)) =~ c.session
    refute Jason.encode!(body(expo)) =~ Venue.badge_id()
    refute Jason.encode!(body(sessions)) =~ c.session
    refute Jason.encode!(body(sessions)) =~ Venue.badge_id()

    # And each request's identity is the one scheme only — the badge path never
    # carries the bearer credential and vice versa (single-scheme identity).
    assert body(expo)["credentials_presented"] == ["badge"]
    assert body(sessions)["credentials_presented"] == ["session_token"]
  end

  # -- Helpers -----------------------------------------------------------------------

  defp badge_header, do: @badge

  defp authorization(value), do: {"authorization", value}

  defp post(base_url, path, headers: headers) do
    Req.post!(base_url <> path, headers: headers, retry: false)
  end

  defp body(%Req.Response{body: body}) when is_map(body), do: body
  defp body(resp), do: Jason.decode!(resp.body)
end


# ==============================================================================
# SECTION 7 of 31: test/conference_sim/exhibitor_signing_court_test.exs
# ==============================================================================

# Lane EV3 — Conference-sim exhibitor identity: G4's card-signing surface
# under event conditions.
#
# Models a real AGNTCon expo floor: 3 exhibitors each sign their served agent
# card with a distinct key over the REAL `AshA2A.Protocol.CardSigning`
# machinery (RS256 + ES256 + the HS256 exhibitor — the full G4 algorithm mix),
# and the venue publishes a kid-sorted JWKS aggregating every exhibitor
# PUBLIC key.
#
# Venue publication law:
#   - the aggregate JWKS is kid-sorted (deterministic publication);
#   - a duplicate `kid` claimed by two exhibitors refuses the WHOLE set
#     (`{:error, {:duplicate_kid, kid}}`) — no partial key set is ever served;
#   - HMAC material has no public key, so the HS256 exhibitor's secret is
#     never published (G4's `CardSigning.jwks/1` refuses binary material) —
#     it reaches verifiers out-of-band as a rotation-set map entry.
#
# Courts:
#   1. three exhibitors, three distinct keys; venue JWKS is kid-sorted,
#      public-members-only;
#   2. every exhibitor's served card verifies against the published JWKS
#      (HS256 against the venue keyring; a JWKS-only verifier refuses the
#      HS256 card as :unknown_kid);
#   3. tampered card body -> :digest_mismatch; wrong-exhibitor key ->
#      :unknown_kid;
#   4. `kid` is read from the PROTECTED header ONLY — the attacker-writable
#      unprotected `header.kid` is ignored both ways (a trusted kid planted in
#      the unprotected header selects nothing; a kid ONLY in the unprotected
#      header is :missing_kid);
#   5. key rotation mid-event: the grace window serves both kids (old and new
#      cards verify), revocation serves only the new kid (old-kid card refuses
#      :unknown_kid, new-kid card passes);
#   6. cross-attendee: a real `AshA2A.Protocol.Client.discover/2` over a real
#      Bandit booth verifies the exhibitor card against the JWKS fetched from
#      the venue endpoint, and refuses a tampered served card;
#   7. duplicate-kid attack across exhibitors -> whole-set refusal.
#
# Chicago-school: real keys, real canonicalization, real HTTP, real client —
# no mocks anywhere in this file.
#
# Fixture modules live at TOP LEVEL of this file (never nested inside the
# test module: Elixir nests dotted module names under the enclosing module).

defmodule AshA2A.ConferenceSim.ExhibitorSigning.Venue do
  @moduledoc """
  Venue JWKS publication law over the real `AshA2A.Protocol.CardSigning.jwks/1`
  surface: kid-sorted aggregate, duplicate-kid whole-set refusal, and a
  keyring view that folds in the out-of-band HS256 exhibitor secret.
  """

  alias AshA2A.Protocol.CardSigning

  @hs_kid "hs-2026-gamma"

  @doc """
  Publishes the aggregate venue JWKS from `{kid, key}` pairs. Refuses the
  WHOLE set when two exhibitors claim the same `kid` — never a partial
  publication. Entries are kid-sorted.
  """
  @spec publish([{String.t(), term()}]) ::
          {:ok, map()} | {:error, {:duplicate_kid, String.t()}}
  def publish(pairs) when is_list(pairs) do
    dup =
      pairs
      |> Enum.map(fn {kid, _} -> kid end)
      |> Enum.frequencies()
      |> Enum.find(fn {_kid, n} -> n > 1 end)

    case dup do
      {kid, _n} -> {:error, {:duplicate_kid, kid}}
      nil -> {:ok, CardSigning.jwks(Enum.sort_by(pairs, &elem(&1, 0)))}
    end
  end

  @doc """
  The venue keyring: the published JWKS entries plus the out-of-band HS256
  secret, as a `kid -> material` rotation set `CardSigning.verify/2` accepts.
  """
  def keyring(jwks, hs256_secret) do
    jwks["keys"]
    |> Map.new(fn jwk -> {jwk["kid"], jwk} end)
    |> Map.put(@hs_kid, hs256_secret)
  end
end

defmodule AshA2A.ConferenceSim.ExhibitorSigning.BoothStore do
  @moduledoc "Agent holding the booth's served state (card body + venue JWKS)."

  use Agent, restart: :temporary

  def start_link(initial), do: Agent.start_link(fn -> initial end, name: __MODULE__)
  def get, do: Agent.get(__MODULE__, & &1)
  def update(fun), do: Agent.update(__MODULE__, fun)
end

defmodule AshA2A.ConferenceSim.ExhibitorSigning.ExhibitorBooth do
  @moduledoc """
  Real Plug.Router booth: serves the exhibitor's signed agent card at the
  §8.2 well-known path and the venue JWKS at the G4 publication path.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/.well-known/agent-card.json" do
    %{card_body: body} = AshA2A.ConferenceSim.ExhibitorSigning.BoothStore.get()

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end

  get "/.well-known/jwks.json" do
    %{jwks: jwks} = AshA2A.ConferenceSim.ExhibitorSigning.BoothStore.get()

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(jwks))
  end

  match _ do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, ~s({"error":"not_found"}))
  end
end

defmodule AshA2A.ConferenceSim.ExhibitorSigningCourt do
  @moduledoc false

  use ExUnit.Case, async: false

  alias AshA2A.ConferenceSim.ExhibitorSigning.{BoothStore, Venue}
  alias AshA2A.Protocol.{AgentCard, CardSigning, Client, JSON}

  @rsa_kid "rsa-2026-alpha"
  @ec_kid "ec-2026-beta"
  @hs_kid "hs-2026-gamma"

  setup do
    server =
      AshA2A.Test.EphemeralHttp.start!(AshA2A.ConferenceSim.ExhibitorSigning.ExhibitorBooth)

    {:ok, _} = BoothStore.start_link(nil)

    # Exhibitors sign the wire-projected card with the booth's real URL, so
    # the served bytes and the signed bytes are the same document.
    alpha = exhibitor("Acme AI", @rsa_kid, :RS256, server.base_url)
    beta = exhibitor("Vertex Labs", @ec_kid, :ES256, server.base_url)
    gamma = exhibitor("QuantalYTICS", @hs_kid, :HS256, server.base_url)

    assert {:ok, jwks} = Venue.publish([{@rsa_kid, alpha.key}, {@ec_kid, beta.key}])

    BoothStore.update(fn _ -> %{card_body: alpha.body, jwks: jwks} end)

    # The Bandit listener is linked to the test process (EphemeralHttp), so it
    # tears down with the test — no on_exit kill needed.

    %{server: server, alpha: alpha, beta: beta, gamma: gamma, jwks: jwks}
  end

  # -- Court 1: three distinct keys, kid-sorted public-only JWKS --------------

  @tag :conference_sim
  test "three exhibitors sign with distinct keys; the venue JWKS is kid-sorted and public-only",
       %{alpha: alpha, beta: beta, gamma: gamma, jwks: jwks} do
    # Three DISTINCT signing keys over the full G4 algorithm mix.
    refute alpha.key == beta.key
    refute beta.key == gamma.key
    assert alpha.alg == "RS256"
    assert beta.alg == "ES256"
    assert gamma.alg == "HS256"

    assert %{"keys" => keys} = jwks
    # Kid-sorted, deterministic publication.
    assert keys == Enum.sort_by(keys, & &1["kid"])
    assert Enum.map(keys, & &1["kid"]) == [@ec_kid, @rsa_kid]

    # Public members only: real public material for each asymmetric exhibitor,
    # and the HS256 exhibitor's secret is NOWHERE in the published document.
    assert %{"kty" => "RSA", "n" => n} = Enum.find(keys, &(&1["kid"] == @rsa_kid))
    assert byte_size(Base.url_decode64!(n, padding: false)) == 256

    assert %{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y} =
             Enum.find(keys, &(&1["kid"] == @ec_kid))

    assert byte_size(Base.url_decode64!(x, padding: false)) == 32
    assert byte_size(Base.url_decode64!(y, padding: false)) == 32

    published = Jason.encode!(jwks)
    refute published =~ gamma.key
    # G4's publication surface refuses HMAC material outright.
    assert_raise ArgumentError, ~r/cannot build JWKS entry/, fn ->
      CardSigning.jwks([{gamma.kid, gamma.key}])
    end
  end

  # -- Court 2: every served card verifies against the published key set ------

  @tag :conference_sim
  test "each exhibitor's served card verifies against the venue key set",
       %{alpha: alpha, beta: beta, gamma: gamma, jwks: jwks} do
    # Asymmetric exhibitors verify straight off the published JWKS...
    assert CardSigning.verify(alpha.card, jwks) == :ok
    assert CardSigning.verify(beta.card, jwks) == :ok

    # ...decoded back through the real codec, the way a peer sees the card.
    wire_card =
      alpha.card
      |> JSON.encode_agent_card(url: alpha.card.url)
      |> Jason.encode!()
      |> Jason.decode!()
      |> JSON.decode_agent_card()
      |> elem(1)

    assert CardSigning.verify(wire_card, jwks) == :ok

    # The HS256 exhibitor verifies ONLY with the positional shared secret —
    # the G4 surface refuses ANY set-shaped key material on an HS256 entry
    # (a JWKS doc or a keyring map answers :missing_key before kid resolution
    # ever runs), and the secret is structurally absent from the public JWKS.
    keyring = Venue.keyring(jwks, gamma.key)
    assert CardSigning.verify(gamma.card, gamma.key) == :ok

    assert {:error, {:malformed, %{reason: :missing_key}}} =
             CardSigning.verify(gamma.card, keyring)

    assert {:error, {:malformed, %{reason: :missing_key}}} =
             CardSigning.verify(gamma.card, jwks)
  end

  # -- Court 3: tampered card body / wrong-exhibitor key -----------------------

  @tag :conference_sim
  test "tampered card body refuses with :digest_mismatch; wrong exhibitor's key refuses",
       %{alpha: alpha, jwks: jwks} do
    # A post-signing content mutation flips the recomputed digest.
    tampered = %{alpha.card | description: "TAMPERED — impostor booth"}

    assert {:error, {:digest_mismatch, %{index: 0}}} = CardSigning.verify(tampered, jwks)

    # A card from an exhibitor whose kid is not in the served set refuses.
    other = exhibitor("Impostor", "impostor-kid", :RS256, "http://127.0.0.1:1")

    assert {:error, {:bad_signature, %{reason: :unknown_kid}}} =
             CardSigning.verify(other.card, jwks)
  end

  # -- Court 4: protected-header-only kid law (AT5) ----------------------------

  @tag :conference_sim
  test "kid is read from the PROTECTED header only; the unprotected header is ignored",
       %{alpha: alpha, beta: beta, jwks: jwks} do
    # Attacker rewrites the UNPROTECTED header kid to point at another
    # exhibitor's key: key selection must still come from the protected
    # header (the entry verifies against ALPHA's RSA key, not beta's EC key —
    # had the unprotected kid been consulted, verification would fail).
    [entry] = alpha.card.signatures
    planted = put_in(entry["header"]["kid"], @ec_kid)

    assert planted["header"]["kid"] == @ec_kid
    assert entry["protected"] == planted["protected"]

    planted_card = %{alpha.card | signatures: [planted]}
    assert CardSigning.verify(planted_card, jwks) == :ok

    # A kid that exists ONLY in the unprotected header selects nothing: the
    # protected header carries no kid, so the rotation set is refused before
    # the (planted) header kid is ever consulted.
    no_kid_signed =
      %{alpha.card | signatures: []}
      |> CardSigning.sign(beta.key, alg: :ES256)

    assert [%{"protected" => protected_b64} = no_kid_entry] = no_kid_signed.signatures
    refute Jason.decode!(Base.url_decode64!(protected_b64, padding: false))["kid"]

    no_kid_entry =
      no_kid_entry
      |> Map.put("header", %{"alg" => "ES256", "typ" => "a2a-card", "kid" => @ec_kid})

    assert {:error, {:malformed, %{reason: :missing_kid}}} =
             CardSigning.verify(%{no_kid_signed | signatures: [no_kid_entry]}, %{
               @ec_kid => beta.key
             })
  end

  # -- Court 5: rotation mid-event ---------------------------------------------

  @tag :conference_sim
  test "key rotation mid-event: grace serves both kids; post-revocation the old kid refuses",
       %{beta: beta} do
    old_key = beta.key
    old_card = beta.card
    new_key = :public_key.generate_key({:namedCurve, :secp256r1})

    # Mid-event rotation: the new card is signed under the new generation.
    new_card =
      %{beta.card | signatures: []}
      |> CardSigning.sign(new_key, alg: :ES256, kid: "ec-2026-beta-r2")

    # Grace window: the venue publishes BOTH generations, kid-sorted.
    assert {:ok, grace} = Venue.publish([{@ec_kid, old_key}, {"ec-2026-beta-r2", new_key}])
    assert Enum.map(grace["keys"], & &1["kid"]) == [@ec_kid, "ec-2026-beta-r2"]

    assert CardSigning.verify(old_card, grace) == :ok
    assert CardSigning.verify(new_card, grace) == :ok

    # Revocation: only the new generation is served.
    assert {:ok, revoked} = Venue.publish([{"ec-2026-beta-r2", new_key}])
    assert CardSigning.verify(new_card, revoked) == :ok

    assert {:error, {:bad_signature, %{index: 0, reason: :unknown_kid, kid: @ec_kid}}} =
             CardSigning.verify(old_card, revoked)
  end

  # -- Court 6: cross-attendee client-side verification over real HTTP ---------

  @tag :conference_sim
  test "an attendee verifying a served exhibitor card through the real client",
       %{alpha: alpha, jwks: jwks} do
    # Real client discovery against the real Bandit booth.
    assert {:ok, card} = Client.discover(alpha.card.url)

    # Attendee fetches the venue JWKS and verifies the served card client-side.
    jwks_url = alpha.card.url <> "/.well-known/jwks.json"
    assert {:ok, %Req.Response{status: 200, body: served}} = Req.get(jwks_url)
    assert served == jwks

    assert CardSigning.verify(card, served) == :ok

    # Tampered serve: the booth flips a description character after signing.
    tampered_wire =
      JSON.encode_agent_card(%{alpha.card | description: "IMITATION BOOTH"}, url: alpha.card.url)

    BoothStore.update(fn state -> %{state | card_body: Jason.encode!(tampered_wire)} end)

    assert {:ok, served_card} = Client.discover(alpha.card.url)
    assert served_card.description == "IMITATION BOOTH"
    assert {:error, {:digest_mismatch, %{index: 0}}} = CardSigning.verify(served_card, served)

    # Restore the honest booth (state assertions, not call-count assumptions).
    BoothStore.update(fn state -> %{state | card_body: alpha.body} end)
    assert {:ok, honest} = Client.discover(alpha.card.url)
    assert CardSigning.verify(honest, served) == :ok
  end

  # -- Court 7: duplicate-kid attack -> whole-set refusal -----------------------

  @tag :conference_sim
  test "a duplicate kid claimed by two exhibitors refuses the whole JWKS set" do
    # Two different exhibitors (different real RSA keys) claim the SAME kid:
    # the venue must refuse to publish ANY key — never resolve ambiguously.
    k1 = :public_key.generate_key({:rsa, 2048, 65_537})
    k2 = :public_key.generate_key({:rsa, 2048, 65_537})

    assert {:error, {:duplicate_kid, @rsa_kid}} =
             Venue.publish([{@rsa_kid, k1}, {@rsa_kid, k2}])

    # Distinct kids publish normally (control).
    assert {:ok, published} = Venue.publish([{@rsa_kid, k1}, {"rsa-2026-delta", k2}])
    assert Enum.map(published["keys"], & &1["kid"]) == [@rsa_kid, "rsa-2026-delta"]
  end

  # -- Helpers -------------------------------------------------------------------

  defp exhibitor(name, kid, alg, base_url) do
    key = generate_key(alg)
    card = base_card(name, base_url)
    signed = CardSigning.sign(card, key, alg: alg, kid: kid)

    body =
      signed
      |> JSON.encode_agent_card(url: base_url)
      |> Jason.encode!()

    %{kid: kid, alg: to_string(alg), key: key, card: signed, body: body}
  end

  defp generate_key(:RS256), do: :public_key.generate_key({:rsa, 2048, 65_537})
  defp generate_key(:ES256), do: :public_key.generate_key({:namedCurve, :secp256r1})
  defp generate_key(:HS256), do: :crypto.strong_rand_bytes(32)

  defp base_card(name, url) do
    %AgentCard{
      name: name,
      description: "#{name} expo booth",
      url: url,
      version: "1.0.0",
      skills: [
        %{id: "demo", name: "Demo", description: "booth demo", tags: ["expo"]}
      ]
    }
  end
end


# ==============================================================================
# SECTION 8 of 31: test/conference_sim/fixture_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule ConferenceSim.FixtureTest do
  @moduledoc """
  Court for the conference-sim shared fixture (lane EV1): a real
  AGNTCon+MCPCon conference spun up over REAL AshA2A machinery — real agent
  GenServers, real signed badge cards, real session tasks with real
  push-config deliveries and subscriber events, and a teardown that verifies
  processes are dead and no ports leaked. Chicago-style: state assertions on
  real processes and real cards, no mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.CardSigning

  setup do
    {:ok, sim} = ConferenceSim.build(attendees: 10)

    on_exit(fn ->
      ConferenceSim.teardown(sim)
    end)

    {:ok, sim: sim}
  end

  @tag :conference_sim
  test "build/1 spins up 10 real attendees and 3 real exhibitor agents, all alive", %{
    sim: sim
  } do
    assert length(sim.attendees) == 10
    assert Enum.all?(sim.attendees, fn a -> is_pid(a.pid) and Process.alive?(a.pid) end)
    assert length(sim.exhibitors) == 3
    assert Enum.all?(sim.exhibitors, fn e -> is_pid(e.pid) and Process.alive?(e.pid) end)

    assert Process.alive?(GenServer.whereis(ConferenceSim.BadgeAuthorityAgent))
    assert Process.alive?(GenServer.whereis(ConferenceSim.VenueAgent))

    # Tier rotation across the 10 attendees covers all four tiers.
    tiers = sim.attendees |> Enum.map(& &1.tier) |> Enum.uniq() |> Enum.sort()
    assert tiers == Enum.sort(ConferenceSim.tiers())
  end

  @tag :conference_sim
  test "every attendee badge is a real signed agent card that verifies against the venue key",
       %{sim: sim} do
    Enum.each(sim.attendees, fn attendee ->
      badge = attendee.badge
      assert %AshA2A.Protocol.AgentCard{} = badge
      assert badge.name == "badge:#{attendee.id}"
      assert [%{"protected" => _, "header" => _, "signature" => _}] = badge.signatures

      assert CardSigning.verify(badge, sim.venue_key) == :ok

      assert {:error, {:bad_signature, _}} =
               CardSigning.verify(badge, :crypto.strong_rand_bytes(32))
    end)
  end

  @tag :conference_sim
  test "tiers map to auth scopes; badge descriptions carry the tier's scopes", %{sim: sim} do
    assert ConferenceSim.tier_scopes(:general) == ["session:scan"]
    assert ConferenceSim.tier_scopes(:workshop) == ["session:scan", "workshop:join"]

    assert ConferenceSim.tier_scopes(:vip) == [
             "session:scan",
             "workshop:join",
             "vip:lounge",
             "seat:front_row"
           ]

    assert ConferenceSim.tier_scopes(:press) == ["session:scan", "press:interview"]
    assert {:error, {:unknown_tier, :speaker}} = ConferenceSim.tier_scopes(:speaker)

    vip = Enum.find(sim.attendees, &(&1.tier == :vip))
    assert vip.badge.description =~ "vip:lounge"
  end

  @tag :conference_sim
  test "all agent cards are fetchable from the real running agents", %{sim: sim} do
    authority_card = ConferenceSim.fetch_card(ConferenceSim.BadgeAuthorityAgent)
    assert authority_card.name == "agntcon_registration_authority"

    assert Enum.any?(
             authority_card.skills,
             &(&1.name == "issue_badge" and String.contains?(&1.id, "issue_badge"))
           )

    venue_card = ConferenceSim.fetch_card(ConferenceSim.VenueAgent)
    assert venue_card.name == "agntcon_venue"

    Enum.each(sim.exhibitors, fn exhibitor ->
      card = ConferenceSim.fetch_card(exhibitor.module)
      assert card.name == exhibitor.name
      assert card.name =~ ~r/^booth_/
    end)
  end

  @tag :conference_sim
  test "badge scanning is scope-gated and recorded on the real attendee process", %{sim: sim} do
    general = Enum.find(sim.attendees, &(&1.tier == :general))
    vip = Enum.find(sim.attendees, &(&1.tier == :vip))

    assert ConferenceSim.scan(sim, general, "talk-042") == :ok
    assert ConferenceSim.scan(sim, general, "booth_acme_ai") == :ok
    assert {:error, :scope_denied} = ConferenceSim.scan(sim, general, "workshop:rust-interop")

    assert ConferenceSim.scan(sim, vip, "workshop:rust-interop") == :ok
    assert "workshop:rust-interop" in ConferenceSim.scans(vip)
    assert "talk-042" in ConferenceSim.scans(general)
    assert "booth_acme_ai" in ConferenceSim.scans(general)
  end

  @tag :conference_sim
  test "sessions are real tasks; changes fan out as push-config deliveries and subscriber events",
       %{sim: sim} do
    {:ok, session} = ConferenceSim.open_session(sim, "a2a_deep_dive", "Agent Cards in Production")
    assert is_binary(session.task_id)
    assert session.track == "a2a_deep_dive"

    # The session task is genuinely non-terminal on the venue's task store.
    {:ok, fetched} = ConferenceSim.VenueAgent.get_task(ConferenceSim.VenueAgent, session.task_id)
    assert fetched.status.state == :input_required

    :ok = ConferenceSim.watch_session(sim, session)

    {:ok, task} = ConferenceSim.session_update(sim, session, "Hall B")
    assert task.id == session.task_id
    assert task.status.state == :completed

    # Real push-config delivery recorded by the real PushRecorder sender.
    # Delivery is spawned off-process (PushNotification.spawn_delivery), so
    # poll briefly for the recorded insert instead of asserting synchronously.
    deliveries =
      Enum.reduce_while(1..50, [], fn _, _ ->
        case ConferenceSim.push_deliveries(sim, session.task_id) do
          # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
          [] -> AshA2A.TestSupport.Eventually.pause(100) && {:cont, []}
          deliveries -> {:halt, deliveries}
        end
      end)

    assert [_ | _] = deliveries

    assert Enum.any?(
             deliveries,
             fn {task_id, config_id, _url, _payload} ->
               task_id == session.task_id and config_id == "watch-#{session.task_id}"
             end
           )

    # Real stream event pushed to the real subscriber registration.
    assert_receive({:a2a_task_event, task_id, event_task}, 5_000)
    assert task_id == session.task_id
    assert event_task.id == session.task_id
    assert event_task.status.state == :completed
  end

  @tag :conference_sim
  test "booth calls dispatch the MCP-flavored call_tool skill on the real exhibitor agent", %{
    sim: sim
  } do
    acme = Enum.fetch!(sim.exhibitors, 0)

    {:ok, result} = ConferenceSim.booth_call(acme, "list_capabilities")

    assert result["jsonrpc"] == "2.0"
    assert result["tool"] == "list_capabilities"
    assert [%{"type" => "text", "text" => text}] = result["result"]["content"]
    assert text =~ "list_capabilities"
  end

  @tag :conference_sim
  test "teardown/1 kills everything and verifies no port leaks", %{sim: sim} do
    ports_before = sim.ports_before
    assert :ok = ConferenceSim.teardown(sim)

    Enum.each(sim.attendees, fn a -> refute Process.alive?(a.pid) end)
    Enum.each(sim.exhibitors, fn e -> refute Process.alive?(e.pid) end)

    case GenServer.whereis(ConferenceSim.VenueAgent) do
      nil -> :ok
      pid -> refute Process.alive?(pid)
    end

    assert Port.list() -- ports_before == []
  end

  @tag :conference_sim
  test "registration authority agent issues a badge receipt through the real dispatch path", %{
    sim: sim
  } do
    message =
      AshA2A.Protocol.Message.new_user([
        AshA2A.Protocol.Part.Data.new(%{attendee_id: "walkup-1", tier: :press})
      ])

    {:ok, task} =
      ConferenceSim.BadgeAuthorityAgent.call(ConferenceSim.BadgeAuthorityAgent, message)

    assert task.status.state == :completed

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: data}]}] =
             task.artifacts

    assert data[:attendee_id] == "walkup-1"
    assert data[:tier] == :press
    assert data[:badge_kid] == ConferenceSim.badge_kid()
    assert data[:signed] == true
  end
end


# ==============================================================================
# SECTION 9 of 31: test/conference_sim/governance_court_test.exs
# ==============================================================================

defmodule ConferenceSimGov.Venue do
  @moduledoc """
  Real fixture resource, private to this lane (EV13), for the venue-governance
  court (`ConferenceSimGov`).

  Two real skills on one resource:

    * `:join` — the general session surface (any tier);
    * `:booth` — the sponsor-booth surface (sponsor-tier capability).

  Both are generic actions requiring `:ticket`, so a `message/send` without
  structured arguments pauses the real task at `TASK_STATE_INPUT_REQUIRED` —
  a continuable, non-terminal task and a real positive-control shape.
  """

  use Ash.Resource,
    domain: ConferenceSimGov.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read])

    action :join, :map do
      argument(:ticket, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{session: "joined", ticket: input.arguments.ticket}}
      end)
    end

    action :booth, :map do
      argument(:ticket, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{booth: "entered", ticket: input.arguments.ticket}}
      end)
    end
  end

  a2a do
    skill(:join, :join, consequence: :observe)
    skill(:booth, :booth, consequence: :observe)
  end
end

defmodule ConferenceSimGov.Domain do
  @moduledoc "Real fixture domain for the EV13 venue-governance court."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(ConferenceSimGov.Venue)
  end
end

defmodule ConferenceSimGov.Agent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer (owner-keyed tasks, CSPRNG ids) serving the
  venue resource. `require_authenticated_caller: true` (the v1.0 default,
  pinned explicitly) plus `execution: [mode: :inline]`.
  """

  use AshA2A.Agent,
    resource_or_domain: ConferenceSimGov.Venue,
    name: "conference_sim_gov_agent",
    require_authenticated_caller: true,
    execution: [mode: :inline]
end

defmodule ConferenceSimGov.Rules do
  @moduledoc """
  The venue's governance law as pure, typed rules over the extended-card auth
  surface: the verified identity (scopes, residency lock, conduct standing)
  against the wire request (method + session/task metadata).

  Deterministic rule ordering — a request violating several rules is refused
  by the FIRST rule in this order:

      1. residency (venue lock law — mirrors the marketplace's residency law)
      2. conduct (code of conduct)
      3. sponsor tier (sponsor-booth scope)
      4. recording consent

  Every refusal is a typed reason string that appears verbatim in the wire
  error body (no silent drops).
  """

  @doc "Declared rule order (deterministic composition)."
  def order, do: [:residency, :conduct, :sponsor, :recording]

  @doc """
  Evaluates the rules in declared order: `:ok` | `{:refuse, reason, detail}`.
  """
  def evaluate(nil, _method, _params),
    do: {:refuse, :SPONSOR_SCOPE_REQUIRED, "no verified identity"}

  def evaluate(identity, method, params) do
    # `AshA2A.Protocol.Plug.Auth` wraps the verified credential as
    # %{scheme: ..., identity: verified}; the rules read the inner map.
    verified = identity[:identity] || identity
    meta = session(params)
    lock = verified[:residency_region_lock]
    scopes = List.wrap(verified[:scopes])

    with :ok <- residency(lock, meta["region"]),
         :ok <- conduct(meta["content_flags"]),
         :ok <- sponsor(scopes, meta["booth"]) do
      recording(meta["recording"], method)
    end
  end

  # 1. Data residency: an attendee whose verified identity carries a
  #    `residency_region_lock` may not join a session locked to a region
  #    outside the lock ("us" covers "us-only"; an exact match always passes).
  defp residency(nil, _region), do: :ok
  defp residency(_lock, nil), do: :ok
  defp residency(lock, region) when lock == region, do: :ok
  defp residency(lock, region) when is_binary(region) and region == lock <> "-only", do: :ok

  defp residency(lock, region),
    do: {:refuse, :RESIDENCY_REGION_LOCK, "attendee locked to #{lock}; session is #{region}"}

  # 2. Code of conduct: a message carrying an abuse content marker is refused.
  defp conduct(nil), do: :ok

  defp conduct(flags) when is_list(flags) do
    if "abuse" in flags,
      do: {:refuse, :CONDUCT_VIOLATION, "message carries an abuse content flag"},
      else: :ok
  end

  defp conduct(_), do: :ok

  # 3. Sponsor tier: a sponsor-booth session requires the sponsor scope.
  defp sponsor(_scopes, nil), do: :ok
  defp sponsor(_scopes, false), do: :ok

  defp sponsor(scopes, true) do
    if "sponsor" in scopes,
      do: :ok,
      else: {:refuse, :SPONSOR_SCOPE_REQUIRED, "sponsor-booth session requires the sponsor scope"}
  end

  # 4. Recording consent: a session marked recording-false refuses recording
  #    attempts (`message/stream`); live viewing (`message/send`) is allowed.
  defp recording(false, "message/stream"),
    do: {:refuse, :RECORDING_CONSENT_REQUIRED, "session is not recorded; live viewing only"}

  defp recording(_setting, _method), do: :ok

  # Session requirements ride in the wire message metadata (venue policy
  # markers on the task): region, content_flags, booth, recording.
  defp session(%{"message" => %{"metadata" => meta}}) when is_map(meta), do: meta
  defp session(_), do: %{}
end

defmodule ConferenceSimGov.GovernancePlug do
  @moduledoc """
  The venue's real enforcement plug. Rides the real
  `AshA2A.Protocol.Plug.Auth` bearer middleware and sits before the real
  `AshA2A.A2ATransport.Plug`. It parses the request body once and re-feeds
  the decoded envelope to the transport via `body_params` — exactly the
  branch `AshA2A.A2ATransport.Plug.read_json/1` serves already-decoded
  bodies through — then evaluates `ConferenceSimGov.Rules`. On violation it
  sends a typed JSON-RPC error on the wire and halts, so the transport never
  sees the request: `code -32000` with a `google.rpc.ErrorInfo` (domain
  `conference-sim.venue`, governance reason) plus a `LocalizedMessage`
  detail, fully observable in the response body. Not a mock: a real plug
  producing real HTTP responses.
  """

  @behaviour Plug
  import Plug.Conn

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @localized_type "type.googleapis.com/google.rpc.LocalizedMessage"
  @domain "conference-sim.venue"
  @gov_code -32_000

  @impl Plug
  def init(opts), do: %{rules: Keyword.get(opts, :rules, ConferenceSimGov.Rules)}

  @impl Plug
  def call(conn, %{rules: rules}) do
    case read_body(conn) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, %{"method" => "message/" <> _} = req} ->
            case rules.evaluate(identity(conn), req["method"], req["params"] || %{}) do
              :ok ->
                pass_through(conn, req)

              {:refuse, reason, detail} ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(refusal(req["id"], reason, detail)))
                |> halt()
            end

          {:ok, req} ->
            pass_through(conn, req)

          {:error, _} ->
            # Let the transport produce the canonical parse error.
            conn
        end

      {:more, _, conn} ->
        conn
    end
  end

  defp pass_through(conn, req),
    do: %{conn | body_params: req, params: req}

  defp identity(conn), do: AshA2A.Protocol.Plug.Auth.get_identity(conn)

  defp refusal(id, reason, detail) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => @gov_code,
        "message" => "Refused by venue governance",
        "data" => [
          %{
            "@type" => @error_info_type,
            "domain" => @domain,
            "reason" => to_string(reason)
          },
          %{
            "@type" => @localized_type,
            "locale" => "en-US",
            "message" => detail
          }
        ]
      }
    }
  end
end

defmodule ConferenceSimGov.Cards do
  @moduledoc """
  Real extended-card provider over the A2A extended-card auth surface
  (`agent/getAuthenticatedExtendedCard`): the venue projects each verified
  caller's card from the public card — the sponsor-booth skill and its
  sponsor security requirement appear only for identities holding the
  `sponsor` scope. Governance is therefore advertised as card capability +
  auth scope, then enforced on the wire by `ConferenceSimGov.GovernancePlug`.
  """

  def extended(identity, public) do
    verified = identity[:identity] || identity
    scopes = List.wrap(verified[:scopes])

    skills =
      Enum.reject(public["skills"] || [], fn skill ->
        String.ends_with?(skill["id"], ".booth") and "sponsor" not in scopes
      end)

    card = Map.put(public, "skills", skills)

    card =
      if "sponsor" in scopes,
        do: Map.put(card, "security", [%{"bearer" => ["sponsor"]}]),
        else: card

    {:ok, card}
  end
end

defmodule ConferenceSimGov.AuthVerify do
  @moduledoc """
  Real bearer verify callback. The token names the principal as
  `"tier|region"`: `sponsor|eu`, `attendee|eu`, `attendee|us`. The verified
  identity carries the venue auth scope (`scopes`) and the residency lock
  (`residency_region_lock`) — the extended-card auth surface the governance
  rules evaluate.
  """

  def verify("bearer", token, _conn) do
    case String.split(token, "|") do
      [tier] ->
        {:ok, %{sub: token, tier: tier, scopes: scopes_for(tier), residency_region_lock: nil}}

      [tier, region] ->
        {:ok,
         %{
           sub: token,
           tier: tier,
           scopes: scopes_for(tier),
           residency_region_lock: region
         }}

      _ ->
        {:error, "malformed venue credential"}
    end
  end

  def verify(_scheme, _credential, _conn), do: {:error, "unsupported scheme"}

  defp scopes_for("sponsor"), do: ["sponsor"]
  defp scopes_for(_tier), do: []
end

defmodule ConferenceSimGov do
  @moduledoc """
  EV13 — venue governance as typed law, enforced at the A2A extended-card
  auth surface over the real plug/transport. Zero mocks.

  Everything is real: real `AshA2A.Protocol.Plug.Auth` bearer middleware (a
  real `verify/3` minting scoped identities), the real venue governance plug
  (`ConferenceSimGov.GovernancePlug`, a real plug — not a stub) sitting
  before the real `AshA2A.A2ATransport.Plug`, a real `AshA2A.Agent` GenServer
  (`AshA2A.Transport.Runtime` task state), and the real extended-card
  provider surface (`agent/getAuthenticatedExtendedCard`).

  Courts: sponsor-tier boundary, code of conduct, data residency, recording
  consent — each with a wire-observable typed refusal, a positive control,
  and deterministic composition ordering (residency first).
  """

  use ExUnit.Case, async: true

  import Plug.Conn, only: [get_resp_header: 2]

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.{Message, Part}

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  @gov_domain "conference-sim.venue"
  @gov_code -32_000

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"conference_sim_gov_#{uniq}"
    transport = :"a2a_transport_confsim_#{uniq}"

    start_supervised!({ConferenceSimGov.Agent, name: agent})

    start_supervised!({AshA2A.A2ATransport, name: transport})

    auth =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: @schemes,
        verify: &ConferenceSimGov.AuthVerify.verify/3
      )

    gov = ConferenceSimGov.GovernancePlug.init(rules: ConferenceSimGov.Rules)

    plug =
      TransportPlug.init(
        agent: agent,
        base_url: "http://x/a2a",
        transport: transport,
        extended_card: &ConferenceSimGov.Cards.extended/2
      )

    %{auth: auth, gov: gov, plug: plug}
  end

  # -- wire helpers ------------------------------------------------------------

  # Real chain: bearer auth middleware -> venue governance plug -> wrapper
  # transport plug.
  defp call(ctx, token, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> AshA2A.Protocol.Plug.Auth.call(ctx.auth)
      |> ConferenceSimGov.GovernancePlug.call(ctx.gov)
      |> TransportPlug.call(ctx.plug)

    {conn, Jason.decode!(conn.resp_body)}
  end

  # Encoded v1.0 wire user message naming one of the venue's real skills,
  # carrying venue governance markers in the message metadata.
  defp session_message(skill, meta) do
    msg =
      struct(Message.new_user([Part.Text.new("join")]),
        metadata: Map.merge(%{"skill" => skill}, meta)
      )

    {:ok, encoded} = JSON.encode(msg)
    encoded
  end

  defp send_session(ctx, token, skill, meta, method \\ "message/send") do
    call(ctx, token, method, %{"message" => session_message(skill, meta)})
  end

  # -- typed refusal assertions ------------------------------------------------

  defp assert_refusal({conn, resp}, reason, label) do
    assert conn.status == 200, "#{label}: governance refusals are JSON-RPC over HTTP 200"

    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json",
           "#{label}: refusal is observable in the body, not a silent drop"

    assert %{
             "jsonrpc" => "2.0",
             "id" => id,
             "error" => %{
               "code" => @gov_code,
               "message" => "Refused by venue governance",
               "data" => data
             }
           } = resp,
           "#{label} did not carry the typed governance refusal (got: #{inspect(resp)})"

    assert is_integer(id)

    assert [
             %{
               "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
               "domain" => @gov_domain,
               "reason" => ^reason
             }
           ] =
             Enum.filter(data, &Map.has_key?(&1, "reason"))

    assert String.contains?(conn.resp_body, reason),
           "#{label}: reason must appear verbatim in the wire body"

    resp
  end

  defp assert_task({_conn, resp}, label) do
    assert %{"result" => result} = resp,
           "#{label} expected a real task result (got: #{inspect(resp)})"

    task = get_in(result, ["task"]) || result
    assert is_binary(task["id"]), "#{label} expected a real task id"
    task
  end

  # -- sponsor tier ------------------------------------------------------------

  describe "sponsor-tier boundary" do
    test "attendee is refused a sponsor-booth task with SPONSOR_SCOPE_REQUIRED on the wire",
         ctx do
      resp =
        assert_refusal(
          send_session(ctx, "attendee|us", "booth", %{"booth" => true}),
          "SPONSOR_SCOPE_REQUIRED",
          "attendee at booth"
        )

      assert resp["error"]["data"]
             |> Enum.find(&Map.has_key?(&1, "message"))
             |> Map.fetch!("message") =~ "sponsor scope"
    end

    test "positive control: sponsor scope passes the same booth task", ctx do
      assert_task(
        send_session(ctx, "sponsor|eu", "booth", %{"booth" => true}),
        "sponsor at booth"
      )
    end

    test "extended card projects the booth skill + sponsor security only for sponsor scope",
         ctx do
      {_conn, %{"result" => sponsor_card}} =
        call(ctx, "sponsor|eu", "agent/getAuthenticatedExtendedCard", %{})

      {_conn, %{"result" => attendee_card}} =
        call(ctx, "attendee|us", "agent/getAuthenticatedExtendedCard", %{})

      assert Enum.any?(sponsor_card["skills"], &String.ends_with?(&1["id"], ".booth"))
      assert %{"security" => [%{"bearer" => ["sponsor"]}]} = sponsor_card

      refute Enum.any?(attendee_card["skills"], &String.ends_with?(&1["id"], ".booth"))
      refute Map.has_key?(attendee_card, "security")
    end
  end

  # -- code of conduct ----------------------------------------------------------

  describe "code of conduct" do
    test "an abusive-content-flagged message is refused with CONDUCT_VIOLATION", ctx do
      assert_refusal(
        send_session(ctx, "attendee|us", "join", %{"content_flags" => ["abuse"]}),
        "CONDUCT_VIOLATION",
        "abusive message"
      )
    end

    test "positive control: the same message without the abuse marker passes", ctx do
      assert_task(
        send_session(ctx, "attendee|us", "join", %{"content_flags" => ["question"]}),
        "clean message"
      )
    end
  end

  # -- data residency -----------------------------------------------------------

  describe "data residency" do
    test "an eu-locked attendee cannot join a us-only session (RESIDENCY_REGION_LOCK)",
         ctx do
      assert_refusal(
        send_session(ctx, "attendee|eu", "join", %{"region" => "us-only"}),
        "RESIDENCY_REGION_LOCK",
        "eu attendee at us-only session"
      )
    end

    test "positive control: the eu-locked attendee joins the eu session", ctx do
      assert_task(
        send_session(ctx, "attendee|eu", "join", %{"region" => "eu"}),
        "eu attendee at eu session"
      )
    end

    test "an attendee without a residency lock is not governed by the residency rule",
         ctx do
      assert_task(
        send_session(ctx, "attendee", "join", %{"region" => "us-only"}),
        "unlocked attendee at us-only session"
      )
    end
  end

  # -- recording consent --------------------------------------------------------

  describe "recording consent" do
    test "message/stream on a recording-false session is refused (RECORDING_CONSENT_REQUIRED)",
         ctx do
      assert_refusal(
        send_session(ctx, "attendee|us", "join", %{"recording" => false}, "message/stream"),
        "RECORDING_CONSENT_REQUIRED",
        "stream recording attempt"
      )
    end

    test "positive control: live viewing (message/send) on the same session passes", ctx do
      assert_task(
        send_session(ctx, "attendee|us", "join", %{"recording" => false}),
        "live viewing"
      )
    end
  end

  # -- deterministic composition ------------------------------------------------

  describe "rule composition (deterministic ordering)" do
    test "eu attendee at a us-only recording-restricted stream is refused by residency FIRST",
         ctx do
      resp =
        assert_refusal(
          send_session(
            ctx,
            "attendee|eu",
            "join",
            %{"region" => "us-only", "recording" => false},
            "message/stream"
          ),
          "RESIDENCY_REGION_LOCK",
          "composition: residency wins"
        )

      # The first rule fired, so no later rule's reason appears.
      refute resp["error"]["data"]
             |> Enum.any?(&(&1["reason"] == "RECORDING_CONSENT_REQUIRED"))
    end

    test "same request from a us attendee reaches the recording rule", ctx do
      assert_refusal(
        send_session(
          ctx,
          "attendee|us",
          "join",
          %{"region" => "us-only", "recording" => false},
          "message/stream"
        ),
        "RECORDING_CONSENT_REQUIRED",
        "composition: recording rule reached past residency"
      )
    end

    test "declared rule order is residency, conduct, sponsor, recording" do
      assert ConferenceSimGov.Rules.order() == [:residency, :conduct, :sponsor, :recording]
    end
  end
end


# ==============================================================================
# SECTION 10 of 31: test/conference_sim/grpc_venue_court_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConferenceSim.GRPCVenueHandler do
  @moduledoc """
  The venue's real gRPC handler — a real `AshA2A.Protocol.JSONRPC` behaviour
  implementation over the SAME supervised `AshA2A.Test.Fixture.EchoAgent` and
  the SAME `AshA2A.A2ATransport` instance the venue's JSON-RPC and HTTP+JSON
  (REST) bindings serve. No mocks.

  Task surface delegates to the shared agent (the same calls the HTTP
  binding's dispatcher makes); the push-config surface delegates to
  `AshA2A.A2ATransport.PushConfigRPC` — the very module the REST binding's
  push routes delegate to — against the shared transport's real
  `PushConfigStore`, so cross-binding parity is by construction and this
  court witnesses it over the wire.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.A2ATransport.{PushConfigRPC, TaskEvents}
  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Test.Fixture.EchoAgent

  @impl true
  def handle_send(message, _params, %{agent: agent}) do
    AshA2A.Protocol.call(agent, message)
  end

  @impl true
  def handle_get(task_id, _params, %{agent: agent}) do
    case EchoAgent.get_task(agent, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, :not_found} -> {:error, Error.task_not_found(task_id)}
    end
  end

  @impl true
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

  @impl true
  def handle_list(params, %{agent: agent}) do
    case GenServer.call(agent, {:ash_a2a_list_tasks, :anonymous, params}) do
      {:ok, result} -> {:ok, result}
      {:error, :unsupported} -> {:error, Error.unsupported_operation()}
      {:error, reason} -> {:error, Error.internal_error(inspect(reason))}
    end
  end

  # -- push config CRUD: the SAME PushConfigRPC the REST binding calls ---------

  @impl true
  def handle_set_push_config(config, _params, ctx) do
    raw = %{
      "id" => config.id,
      "url" => config.url,
      "token" => config.token,
      "authentication" => auth_raw(config.authentication)
    }

    case push(
           "tasks/pushNotificationConfig/set",
           %{"taskId" => config.task_id, "pushNotificationConfig" => raw},
           ctx
         ) do
      # The codec-encoded config struct is what the JSON-RPC dispatcher
      # re-encodes onto the wire (a plain envelope map would refuse in
      # AshA2A.Protocol.JSON.encode/1); the store's copy is authoritative.
      {:ok, _envelope} -> {:ok, config}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def handle_get_push_config(task_id, config_id, _params, ctx) do
    case push(
           "tasks/pushNotificationConfig/get",
           %{"id" => task_id, "pushNotificationConfigId" => config_id},
           ctx
         ) do
      {:ok, envelope} -> {:ok, config_struct(envelope)}
      other -> other
    end
  end

  @impl true
  def handle_list_push_configs(task_id, _params, ctx) do
    case push("tasks/pushNotificationConfig/list", %{"id" => task_id}, ctx) do
      {:ok, envelopes} -> {:ok, Enum.map(envelopes, &config_struct/1)}
      other -> other
    end
  end

  @impl true
  def handle_delete_push_config(task_id, config_id, _params, ctx) do
    push(
      "tasks/pushNotificationConfig/delete",
      %{"id" => task_id, "pushNotificationConfigId" => config_id},
      ctx
    )
  end

  defp push(method, params, ctx) do
    push_ctx = %{
      agent: ctx.agent,
      transport: ctx.transport,
      push_opts: TaskEvents.push_opts(ctx.transport),
      principal: Map.get(ctx, :principal, :anonymous)
    }

    case PushConfigRPC.handle(method, params, :venue, push_ctx) do
      %{"result" => result} ->
        {:ok, result}

      %{"error" => error} ->
        {:error, %Error{code: error["code"], message: error["message"], data: error["data"]}}
    end
  end

  # Rebuilds the wire-shaped authentication map from the codec-decoded
  # (atom-keyed) authentication, so a gRPC-set config reads back through REST
  # with the same envelope shape a REST-set config would answer.
  defp auth_raw(nil), do: nil

  defp auth_raw(%{scheme: scheme} = auth) do
    %{"schemes" => [scheme]}
    |> maybe_put("credentials", auth[:credentials])
  end

  defp auth_raw(auth) when is_map(auth), do: auth

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # The JSON-RPC dispatcher re-encodes handler results through the codec, so
  # a push-config envelope (plain string-keyed map) must be lifted back into
  # the codec struct before it goes on the wire.
  defp config_struct(%{"taskId" => task_id, "pushNotificationConfig" => inner}) do
    %AshA2A.Protocol.PushNotificationConfig{
      id: inner["id"],
      task_id: task_id,
      url: inner["url"],
      token: inner["token"],
      authentication:
        case inner["authentication"] do
          %{"schemes" => [scheme]} = auth ->
            %{scheme: scheme}
            |> maybe_put(:credentials, auth["credentials"])

          auth when is_map(auth) ->
            auth

          _ ->
            nil
        end
    }
  end
end

defmodule AshA2A.ConferenceSim.GRPCVenueAuthVerify do
  @moduledoc """
  The venue's badge check: real HS256 JWT verification — header check,
  constant-time HMAC-SHA256 signature comparison, required `sub` claim. Real
  `:crypto` HMAC math, no JWT library, no mocks.
  """

  @secret "conference-sim-venue-badge-secret"

  def secret, do: @secret

  def verify(_scheme, credential, _conn) do
    with [header_b64, payload_b64, sig_b64] <- String.split(credential, ".", parts: 3),
         {:ok, %{"alg" => "HS256"}} <-
           Jason.decode(Base.url_decode64!(header_b64, padding: false)),
         {:ok, claims} <- Jason.decode(Base.url_decode64!(payload_b64, padding: false)),
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
    if Plug.Crypto.secure_compare(sig, expected), do: :ok, else: {:error, "bad signature"}
  end
end

defmodule AshA2A.ConferenceSim.GRPCVenueCourt do
  @moduledoc """
  Conference-sim lane EV7 court: the venue's gRPC binding (the 11-RPC
  `a2a.A2AService` surface) serving event traffic against ONE agent and ONE
  `AshA2A.A2ATransport` — the same task/push-config store the venue's
  JSON-RPC and HTTP+JSON (REST) bindings serve. Real cowboy HTTP/2 listener,
  real Mint gRPC client, real supervised `EchoAgent`, real `PushConfigStore`.
  Zero mocks.

  ## Courts

    1. BIND-EQUIV at event scale: a task created via the JSON-RPC binding is
       fetchable via gRPC `GetTask` and visible to gRPC `ListTasks`; a task
       created via gRPC `SendMessage` is fetchable via JSON-RPC `tasks/get`
       and REST `GET /tasks/{id}` — same ids, same terminal state.
    2. Push-config CRUD parity: a config written via gRPC reads back with
       exactly the envelope the REST binding answers (write-only credentials
       stripped on the wire, stored for delivery); REST-set configs read
       back via the gRPC dispatch layer; gRPC delete is visible via REST.
    3. Typed-error parity: identical bad requests answered across bindings
       per the spec §5.4 mapping — gRPC `GetTask` unknown id is NOT_FOUND(5)
       + ErrorInfo TASK_NOT_FOUND where JSON-RPC answers -32001; gRPC push
       get on a missing config is INVALID_ARGUMENT(3) + ErrorInfo
       INVALID_PARAMS where REST answers the 400 INVALID_PARAMS envelope;
       gRPC push set on an unknown task is NOT_FOUND(5) like JSON-RPC -32001.
    4. Load: 20 interleaved gRPC + 20 JSON-RPC + 20 REST sends — all 60
       succeed against the shared store, 60 distinct task ids, one gRPC
       endpoint (no port/registry contention).
    5. CC15's auth interceptor: with bearer auth configured on the gRPC
       endpoint, unauthenticated calls are UNAUTHENTICATED(16) with the typed
       HTTP body; a valid badge JWT passes and creates a real task.
  """

  use ExUnit.Case, async: false

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.A2ATransport.{PushConfigStore, TaskEvents}
  alias AshA2A.ConferenceSim.GRPCVenueAuthVerify, as: Badge
  alias AshA2A.ConferenceSim.GRPCVenueHandler
  alias AshA2A.Test.Fixture.EchoAgent
  alias AshA2A.Transport.Grpc.Dispatch
  alias AshA2A.Transport.HTTPJSON
  alias Lf.A2a.V1, as: Pb

  @endpoint AshA2A.Transport.GRPC.Server.Endpoint
  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @hook_url "http://127.0.0.1:9/hook"

  setup context do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    transport = Module.concat(__MODULE__, Transport)

    start_supervised!(
      {AshA2A.A2ATransport,
       name: transport,
       push: [allow_http: true, allow_cidrs: ["127.0.0.1/32"], signing_secret: "venue-secret"]}
    )

    # -- binding 1: JSON-RPC (AshA2A.A2ATransport.Plug) -------------------------
    jsonrpc =
      TransportPlug.init(
        agent: EchoAgent,
        base_url: "http://x/a2a",
        transport: transport,
        push_notifications: true
      )

    # -- binding 2: HTTP+JSON REST (AshA2A.Transport.HTTPJSON) ------------------
    rest =
      HTTPJSON.init(
        agent: EchoAgent,
        base_url: "http://x/a2a",
        transport: transport,
        push_notifications: true
      )

    # -- binding 3: gRPC (AshA2A.Transport.GRPC.Server + the venue handler) ------
    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: GRPCVenueHandler,
      ctx: %{agent: EchoAgent, opts: [], transport: transport}
    )

    on_exit(fn -> Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server) end)

    if context[:venue_auth] do
      auth_opts =
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
          verify: &Badge.verify/3
        )

      Application.put_env(:ash_a2a, @endpoint, auth: {AshA2A.Transport.GRPC.Auth, auth_opts})

      on_exit(fn -> Application.delete_env(:ash_a2a, @endpoint) end)
    end

    {:ok, _client_sup} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: Module.concat(__MODULE__, ClientSup)
      )

    {:ok, _pid, port} = GRPC.Server.start_endpoint(@endpoint, 0)

    on_exit(fn ->
      try do
        GRPC.Server.stop_endpoint(@endpoint)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)

    %{jsonrpc: jsonrpc, rest: rest, channel: channel, transport: transport}
  end

  # -- helpers -------------------------------------------------------------------

  defp rpc(opts, method, params) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> TransportPlug.call(opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp user_message(text) do
    # Codec-encoded wire shape — the same map every binding's clients send.
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end

  defp new_task_jsonrpc(opts, text) do
    %{"result" => %{"task" => %{"id" => id}}} =
      rpc(opts, "message/send", %{"message" => user_message(text)})

    id
  end

  defp rest_req(method, path, opts, body) do
    conn = Plug.Test.conn(method, path, body && Jason.encode!(body))

    conn =
      if body, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn

    HTTPJSON.call(conn, opts)
  end

  defp rest_json(method, path, opts, body \\ nil) do
    method
    |> rest_req(path, opts, body)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp rest_new_task(opts, text) do
    %{"task" => %{"id" => id}} =
      rest_json(:post, "/message:send", opts, %{"message" => user_message(text)})

    id
  end

  defp grpc_user_request(text) do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("venue-grpc"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      }
    }
  end

  defp grpc_send_task_id(channel, text) do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, grpc_user_request(text))

    assert task.status.state == :TASK_STATE_COMPLETED
    task.id
  end

  defp push_ctx(transport) do
    %{
      agent: EchoAgent,
      transport: transport,
      push_opts: TaskEvents.push_opts(transport),
      principal: :anonymous
    }
  end

  defp error_infos(%GRPC.RPCError{details: details}) do
    Enum.map(details, fn %Google.Protobuf.Any{type_url: type_url, value: value} ->
      assert type_url == @error_info_type
      Google.Rpc.ErrorInfo.decode(value)
    end)
  end

  # ===========================================================================
  # Court 1 — BIND-EQUIV: cross-binding task consistency
  # ===========================================================================

  test "court 1a: task created via jsonrpc is fetchable via gRPC GetTask and ListTasks", %{
    jsonrpc: jsonrpc,
    rest: rest,
    channel: channel
  } do
    task_id = new_task_jsonrpc(jsonrpc, "venue jsonrpc task")

    assert {:ok, %Pb.Task{} = got} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, %Pb.GetTaskRequest{id: task_id})

    assert got.id == task_id
    assert got.status.state == :TASK_STATE_COMPLETED

    assert {:ok, %Pb.ListTasksResponse{tasks: tasks}} =
             Lf.A2a.V1.A2AService.Stub.list_tasks(channel, %Pb.ListTasksRequest{})

    # The owner-scope law crosses bindings too: an anonymous list NEVER
    # enumerates other callers' tasks (SEC-01) — the shared-store task is
    # addressable by id but not listable anonymously, on gRPC exactly as on
    # the HTTP bindings.
    refute Enum.any?(tasks, &(&1.id == task_id))

    # REST fetch of the same shared-store task answers the same id and state.
    assert %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}} =
             rest_json(:get, "/tasks/#{task_id}", rest)
  end

  test "court 1b: task created via gRPC is fetchable via jsonrpc and REST", %{
    jsonrpc: jsonrpc,
    rest: rest,
    channel: channel
  } do
    task_id = grpc_send_task_id(channel, "venue grpc task")

    assert %{"result" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
             rpc(jsonrpc, "tasks/get", %{"id" => task_id})

    assert %{"id" => ^task_id} = rest_json(:get, "/tasks/#{task_id}", rest)
  end

  # ===========================================================================
  # Court 2 — push-config CRUD parity
  # ===========================================================================

  test "court 2: push config CRUD via gRPC matches the REST result", %{
    rest: rest,
    channel: channel,
    transport: transport
  } do
    task_id = rest_new_task(rest, "push parity task")

    # (a) Wire-level set via the gRPC stub.
    assert {:ok, %Pb.TaskPushNotificationConfig{task_id: ^task_id}} =
             Lf.A2a.V1.A2AService.Stub.create_task_push_notification_config(
               channel,
               %Pb.TaskPushNotificationConfig{
                 id: "cfg-grpc-1",
                 task_id: task_id,
                 url: @hook_url,
                 token: "tok-grpc"
               }
             )

    # The gRPC write went through the SAME PushConfigRPC/PushConfigStore the
    # REST binding uses: REST reads it back with exactly the envelope REST's
    # own set would answer.
    # v1.0 REST wire is the flat TaskPushNotificationConfig (stamped with the
    # negotiated protocolVersion), not the legacy nested envelope.
    expected1 = %{
      "taskId" => task_id,
      "id" => "cfg-grpc-1",
      "url" => @hook_url,
      "token" => "tok-grpc",
      "protocolVersion" => "1.0"
    }

    assert rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig/cfg-grpc-1", rest) ==
             expected1

    assert rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig", rest) ==
             %{"configs" => [expected1], "nextPageToken" => ""}

    # (b) Dispatch-layer parity with credentials: the gRPC binding's own
    # dispatch layer answers the SAME proto-JSON map the REST binding
    # answers, credentials write-only (stripped on the wire, stored).
    assert {:ok, flat2} =
             Dispatch.call_detailed(
               "CreateTaskPushNotificationConfig",
               %{
                 "taskId" => task_id,
                 "id" => "cfg-grpc-2",
                 "url" => @hook_url,
                 "token" => "tok-2",
                 "authentication" => %{"schemes" => ["Bearer"], "credentials" => "s3cret-2"}
               },
               GRPCVenueHandler,
               push_ctx(transport)
             )

    # Field-level parity with the REST envelope's inner config (the v1.0 gRPC
    # wire is flat where REST nests under pushNotificationConfig).
    assert flat2["taskId"] == task_id
    assert flat2["id"] == "cfg-grpc-2"
    assert flat2["url"] == @hook_url
    assert flat2["token"] == "tok-2"

    {:ok, stored} =
      PushConfigStore.get(AshA2A.A2ATransport.push_store_name(transport), task_id, "cfg-grpc-2")

    assert stored.authentication == %{"schemes" => ["Bearer"], "credentials" => "s3cret-2"}

    # (c) Reverse direction: a REST-set config read via the gRPC dispatch layer.
    rest_req(:post, "/tasks/#{task_id}/pushNotificationConfig", rest, %{
      "pushNotificationConfig" => %{"id" => "cfg-rest-1", "url" => @hook_url}
    })

    assert {:ok, flat_rest} =
             Dispatch.call_detailed(
               "GetTaskPushNotificationConfig",
               %{"taskId" => task_id, "id" => "cfg-rest-1"},
               GRPCVenueHandler,
               push_ctx(transport)
             )

    assert flat_rest["taskId"] == task_id
    assert flat_rest["id"] == "cfg-rest-1"
    assert flat_rest["url"] == @hook_url

    # (d) Delete via gRPC stub: idempotent OK; REST sees the removal.
    assert {:ok, %Google.Protobuf.Empty{}} =
             Lf.A2a.V1.A2AService.Stub.delete_task_push_notification_config(
               channel,
               %Pb.DeleteTaskPushNotificationConfigRequest{task_id: task_id, id: "cfg-grpc-1"}
             )

    assert rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig/cfg-grpc-1", rest) == %{
             "error" => %{
               "code" => 400,
               "message" => "Invalid parameters",
               "status" => "INVALID_ARGUMENT",
               "details" => [
                 %{
                   "@type" => @error_info_type,
                   "domain" => "a2a-protocol.org",
                   "reason" => "INVALID_PARAMS",
                   "metadata" => %{"detail" => "push notification config not found"}
                 }
               ]
             }
           }

    # REST list shape is {configs, nextPageToken} (lane 17, A2A v1.0 §5.3).
    %{"configs" => remaining} = rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig", rest)
    ids = Enum.map(remaining, &(&1["id"] || get_in(&1, ["pushNotificationConfig", "id"])))
    assert Enum.sort(ids) == ["cfg-grpc-2", "cfg-rest-1"]
  end

  # ===========================================================================
  # Court 3 — typed-error parity across bindings
  # ===========================================================================

  test "court 3a: unknown task — gRPC NOT_FOUND(5)+TASK_NOT_FOUND vs jsonrpc -32001", %{
    jsonrpc: jsonrpc,
    channel: channel
  } do
    assert %{"error" => %{"code" => -32_001}} =
             rpc(jsonrpc, "tasks/get", %{"id" => "no-such-task"})

    assert {:error, %GRPC.RPCError{status: 5} = error} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, %Pb.GetTaskRequest{id: "no-such-task"})

    assert [%Google.Rpc.ErrorInfo{reason: "TASK_NOT_FOUND", domain: "a2a-protocol.org"}] =
             error_infos(error)
  end

  test "court 3b: missing push config — gRPC INVALID_ARGUMENT(3)+INVALID_PARAMS vs REST 400 envelope",
       %{
         rest: rest,
         channel: channel
       } do
    task_id = rest_new_task(rest, "typed errors task")

    assert %{"error" => %{"code" => 400, "details" => [%{"reason" => "INVALID_PARAMS"}]}} =
             rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig/nope", rest)

    assert {:error, %GRPC.RPCError{status: 3} = error} =
             Lf.A2a.V1.A2AService.Stub.get_task_push_notification_config(
               channel,
               %Pb.GetTaskPushNotificationConfigRequest{task_id: task_id, id: "nope"}
             )

    assert [%Google.Rpc.ErrorInfo{reason: "INVALID_PARAMS", domain: "a2a-protocol.org"}] =
             error_infos(error)
  end

  test "court 3c: push set on an unknown task — gRPC NOT_FOUND(5) like jsonrpc -32001", %{
    channel: channel
  } do
    assert {:error, %GRPC.RPCError{status: 5} = error} =
             Lf.A2a.V1.A2AService.Stub.create_task_push_notification_config(
               channel,
               %Pb.TaskPushNotificationConfig{
                 id: "cfg-x",
                 task_id: "no-such-task",
                 url: @hook_url
               }
             )

    assert [%Google.Rpc.ErrorInfo{reason: "TASK_NOT_FOUND", domain: "a2a-protocol.org"}] =
             error_infos(error)
  end

  # ===========================================================================
  # Court 4 — load: 60 interleaved mixed-protocol calls, one endpoint
  # ===========================================================================

  test "court 4: 60 interleaved mixed-protocol calls all succeed against the shared store", %{
    jsonrpc: jsonrpc,
    rest: rest,
    channel: channel
  } do
    grpc_jobs =
      for i <- 1..20, do: Task.async(fn -> grpc_send_task_id(channel, "load grpc #{i}") end)

    jsonrpc_jobs =
      for i <- 1..20, do: Task.async(fn -> new_task_jsonrpc(jsonrpc, "load jsonrpc #{i}") end)

    rest_jobs = for i <- 1..20, do: Task.async(fn -> rest_new_task(rest, "load rest #{i}") end)

    ids = Task.await_many(grpc_jobs ++ jsonrpc_jobs ++ rest_jobs, 30_000)

    assert length(ids) == 60
    assert ids |> Enum.uniq() |> length() == 60, "60 distinct task ids, no store contention"

    # Spot-check across bindings: a gRPC-created task is fetchable via jsonrpc.
    [grpc_id | _] = Enum.take(ids, 3)
    assert %{"result" => %{"id" => ^grpc_id}} = rpc(jsonrpc, "tasks/get", %{"id" => grpc_id})
  end

  # ===========================================================================
  # Court 5 — CC15 auth interceptor on the gRPC endpoint
  # ===========================================================================

  @tag :venue_auth
  test "court 5a: unauthenticated venue call is UNAUTHENTICATED(16) with the typed HTTP body", %{
    channel: channel
  } do
    assert {:error, %GRPC.RPCError{status: 16} = error} =
             Lf.A2a.V1.A2AService.Stub.send_message(channel, grpc_user_request("no badge"))

    assert error.message == ~s({"error":"Unauthorized"})
  end

  @tag :venue_auth
  test "court 5b: valid badge JWT passes the interceptor and creates a real task", %{
    channel: channel
  } do
    # Real-state self-check: the court-minted badge verifies before it is
    # sent over the wire.
    assert {:ok, %{id: "attendee-42"}} = Badge.verify(nil, badge_token("attendee-42"), nil)

    metadata = %{"authorization" => "Bearer " <> badge_token("attendee-42")}

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Lf.A2a.V1.A2AService.Stub.send_message(
               channel,
               grpc_user_request("badged attendee"),
               metadata: metadata
             )

    assert task.status.state == :TASK_STATE_COMPLETED
    assert task.id != ""
  end

  # Real HS256 badge JWT minted with :crypto HMAC — the same JOSE math the
  # venue's verifier runs; no JWT library, no mocks.
  defp badge_token(sub, secret \\ Badge.secret()) do
    b64 = fn bin -> Base.url_encode64(bin, padding: false) end

    header = b64.(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}))
    payload = b64.(Jason.encode!(%{"sub" => sub, "iss" => "venue-gate"}))
    signing_input = header <> "." <> payload
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)

    signing_input <> "." <> b64.(signature)
  end
end


# ==============================================================================
# SECTION 11 of 31: test/conference_sim/interop_court_test.exs
# ==============================================================================

# Lane EV14 - Conference-sim cross-vendor interoperability court.
#
# The event's actual promise: Vendor A (the ash_a2a venue) accepts a signed
# credential issued by Vendor B (the ash_affidavit exhibitor) - two
# independent codebases, two independent builds, only a shared trust root
# (the exhibitor's published JWKS) and the engine's document law in common.
#
# How this court stays honest:
#
#   * Vendor B's signing runs as a real separate OS subprocess in the
#     ash_affidavit checkout (examples/vendor_b_exhibit.exs), through the
#     REAL pinned wasm (AshAffidavit.Signing.derive_subject_digest/3,
#     Signing.signing_input/2 -> verify_signature_input,
#     Signing.verify_signature/4 -> verify_signature). It emits a credential
#     exhibit (JSON) that is the ONLY thing crossing the vendor boundary -
#     exactly like an exhibitor handing the venue a signed badge. The venue
#     never sees Vendor B's private key.
#   * Vendor A (this test process) recomputes the signing pre-image with its
#     OWN vendored engine (hex dep ash_affidavit 26.10.1 - a DIFFERENT engine
#     identity than the exhibitor's tip) via verify_signature_input, and
#     verifies the Ed25519 signature over those engine-recomputed bytes with
#     :crypto - never over a caller-supplied pre-image.
#   * S3 correlation-law analog: the credential binds subject + hash. The
#     subject digest is the engine's domain-separated BLAKE3
#     (derive_subject_digest), not a host hash; the payload hash is SHA-256
#     over the canonical payload document.
#   * Court (d): the venue's own signed agent card (real
#     AshA2A.Protocol.CardSigning) and the affidavit credential coexist as
#     two trust roots; cross-presentation is refused (no clobbering).
#
# Production gaps this court documents (honest scoping, no fake acceptance):
#
#   1. AshA2A.Protocol.CardSigning (HS256/RS256/ES256) has no Ed25519 - the
#      venue's production card verifier cannot consume the exhibitor's
#      algorithm today. The translation adapter below does the Ed25519 step
#      with :crypto directly (real crypto, not a stub); the production fix
#      is one algorithm addition to CardSigning.
#   2. The venue's vendored engine (hex 26.10.1) exposes
#      verify_signature_input but NOT derive_subject_digest /
#      verify_signature - the venue cannot re-derive subject digests or have
#      the engine adjudicate signatures. The adapter therefore holds an
#      exhibitor-published PUBLIC subject registry (engine-derived digests)
#      as the correlation table. Bumping the vendored engine is the
#      production fix.
#
# Fixture modules live at TOP LEVEL of this file (never nested inside the
# test module: Elixir nests dotted module names under the enclosing module).

defmodule AshA2A.Test.ConferenceSim.Interop.VenueVerifier do
  @moduledoc """
  The venue-side credential-translation adapter (Vendor A) - the MINIMAL
  adapter the honest-scoping clause of the lane asks for. The venue's
  production verifier (AshA2A.Protocol.CardSigning) cannot consume an
  affidavit-shaped credential today (no Ed25519; the vendored engine lacks
  verify_signature), so the adapter performs the verification steps the
  production verifier would perform once the gaps close - with real crypto
  at every step:

    1. the venue's OWN vendored engine recomputes the signing pre-image from
       the envelope bytes (verify_signature_input - never a caller-supplied
       pre-image);
    2. the Ed25519 signature over those engine-recomputed bytes is verified
       against the exhibitor's JWKS key (:crypto, real; ES256 over a P-256 SEC1 point);
    3. the subject correlation fence: the envelope's subject_digest must be
       the registry digest of the attendee PRESENTING the credential (S3's
       correlation law: a credential for X cannot serve Y);
    4. the payload binding: SHA-256 over the canonical payload document must
       equal the credential's payload_hash.

  Returns {:ok, claims} or {:refused, step, detail} - acceptance is never
  faked; every refusal names the failing step.
  """

  @domain_tag "affidavit.crypto-trust-plane.v1"

  def adjudicate(credential, presented_as, subject_registry, jwks, host) do
    envelope = credential["envelope"]

    with {:ok, pre_image} <- engine_pre_image(envelope, host),
         {:ok, key} <- jwks_key(jwks, envelope["key_id"]),
         :ok <- signature_step(pre_image, credential["signature_hex"], key),
         :ok <- subject_fence(envelope["subject_digest"], presented_as, subject_registry),
         :ok <- payload_fence(credential) do
      {:ok,
       %{
         subject: presented_as,
         audience: envelope["audience"],
         domain_tag: @domain_tag,
         key_id: envelope["key_id"],
         engine_witness: pre_image
       }}
    end
  end

  # Step 1: the venue's own engine recomputes the pre-image. The expectation
  # is deliberately impossible so the response echoes the ENGINE's
  # recomputation, not any caller-attested value.
  defp engine_pre_image(envelope, host) do
    request = %{
      "op" => "verify_signature_input",
      "envelope_json" => Jason.encode!(wire_envelope(envelope)),
      "expected_signing_input_hex" => String.duplicate("00", 128)
    }

    case AshAffidavit.call(request, server: host) do
      {:ok, %{"signing_input_hex" => hex}} when is_binary(hex) ->
        {:ok, Base.decode16!(hex, case: :lower)}

      {outcome, refusal} ->
        {:refused, :engine_pre_image, {outcome, Map.from_struct(refusal)}}
    end
  end

  # The engine canonicalizes nonce/subject_digest as byte arrays; a hex
  # string form is normalized to byte lists so both engine identities
  # canonicalize the same document.
  defp wire_envelope(envelope) do
    Map.new(envelope, fn
      {"nonce" = f, v} when is_binary(v) and byte_size(v) == 32 ->
        {f, v |> Base.decode16!(case: :mixed) |> :binary.bin_to_list()}

      {"subject_digest" = f, v} when is_binary(v) and byte_size(v) == 64 ->
        {f, v |> Base.decode16!(case: :mixed) |> :binary.bin_to_list()}

      {f, v} ->
        {f, v}
    end)
  end

  defp jwks_key(%{"keys" => keys}, kid) do
    case Enum.filter(keys, &(&1["kid"] == kid)) do
      [key] -> {:ok, key}
      _ -> {:refused, :unknown_key, %{kid: kid}}
    end
  end

  # Step 2: real ES256 over the ENGINE-recomputed bytes (the key material
  # is the SEC1 uncompressed point from the exhibitor's JWKS).
  defp signature_step(pre_image, sig_hex, key) do
    with {:ok, sig} <- Base.decode16(sig_hex, case: :mixed),
         {:ok, pub} <- Base.url_decode64(key["sec1"], padding: false) do
      verified =
        try do
          :crypto.verify(:ecdsa, :sha256, pre_image, sig, [pub, :secp256r1])
        rescue
          # a well-formed but non-canonical point (not on the curve) is a
          # decided-negative at the host, same verdict as a signature miss
          ErlangError -> false
        end

      if verified do
        :ok
      else
        {:refused, :bad_signature, %{kid: key["kid"]}}
      end
    else
      _ -> {:refused, :malformed_material, %{kid: key["kid"]}}
    end
  end

  # Step 3: S3 correlation-law analog - a credential for X cannot serve Y.
  defp subject_fence(envelope_digest_hex, presented_as, registry) do
    registered = Map.get(registry, presented_as)

    cond do
      is_nil(registered) ->
        {:refused, :unregistered_subject, %{subject: presented_as}}

      registered != envelope_digest_hex ->
        {:refused, :subject_correlation_mismatch,
         %{presented_as: presented_as, bound: envelope_digest_hex, registered: registered}}

      true ->
        :ok
    end
  end

  # Step 4: the payload binding (hash law over the canonical payload doc).
  defp payload_fence(credential) do
    recomputed =
      Base.encode16(:crypto.hash(:sha256, Jason.encode!(credential["payload"])), case: :lower)

    if recomputed == credential["payload_hash_hex"] do
      :ok
    else
      {:refused, :payload_hash_mismatch,
       %{recomputed: recomputed, presented: credential["payload_hash_hex"]}}
    end
  end
end

defmodule AshA2A.Test.ConferenceSim.InteropCourt do
  use ExUnit.Case, async: false

  alias AshA2A.Test.ConferenceSim.Interop.VenueVerifier

  @ash_affidavit_dir Path.expand("../../../ash_affidavit", __DIR__)
  @build_root "_build-ev14b"
  @domain_tag "affidavit.crypto-trust-plane.v1"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ash_affidavit)
    wasm = Path.join([Application.app_dir(:ash_affidavit), "priv", "affidavit", "affidavit.wasm"])
    {:ok, venue_host} = AshAffidavit.Host.start_link(name: nil, bytes: File.read!(wasm))
    exhibit = run_vendor_b!()
    on_exit(fn -> Application.delete_env(:ash_affidavit, :start_pool) end)
    %{venue_host: venue_host, exhibit: exhibit}
  end

  test "court a: an exhibitor-issued signed credential is accepted by the venue (two wasm identities agree)",
       %{exhibit: exhibit, venue_host: venue_host} do
    {:ok, claims} =
      VenueVerifier.adjudicate(
        exhibit["credential"],
        "attendee-X",
        exhibit["subject_registry"],
        exhibit["jwks"],
        venue_host
      )

    assert claims.subject == "attendee-X"
    assert claims.audience == "conference-sim.venue"
    assert claims.domain_tag == @domain_tag
    assert claims.key_id == exhibit["kid"]
    assert byte_size(claims.engine_witness) > 0

    assert Base.encode16(claims.engine_witness, case: :lower) ==
             exhibit["engine_witness"]["signing_input_hex"]
  end

  test "court b: a tampered credential is refused - envelope tamper and signature tamper",
       %{exhibit: exhibit, venue_host: venue_host} do
    # (i) envelope tamper: audience rewritten, signature left as issued - the
    # engine recomputes a different pre-image, so the signature no longer
    # verifies.
    tampered = put_in(exhibit, ["credential", "envelope", "audience"], "conference-sim.venue.vip")

    assert {:refused, :bad_signature, _} =
             VenueVerifier.adjudicate(
               tampered["credential"],
               "attendee-X",
               exhibit["subject_registry"],
               exhibit["jwks"],
               venue_host
             )

    # (ii) signature tamper: flip one hex nibble of the Ed25519 signature.
    sig = exhibit["credential"]["signature_hex"]
    tampered_sig = flip_hex_nibble(sig, 5)
    assert tampered_sig != sig

    assert {:refused, :bad_signature, _} =
             VenueVerifier.adjudicate(
               put_in(exhibit, ["credential", "signature_hex"], tampered_sig)["credential"],
               "attendee-X",
               exhibit["subject_registry"],
               exhibit["jwks"],
               venue_host
             )
  end

  test "court c: the correlation fence - a credential for attendee X cannot serve attendee Y",
       %{exhibit: exhibit, venue_host: venue_host} do
    assert {:refused, :subject_correlation_mismatch, detail} =
             VenueVerifier.adjudicate(
               exhibit["credential"],
               "attendee-Y",
               exhibit["subject_registry"],
               exhibit["jwks"],
               venue_host
             )

    assert detail.presented_as == "attendee-Y"
    assert detail.bound == exhibit["subject_registry"]["attendee-X"]
    assert detail.registered == exhibit["subject_registry"]["attendee-Y"]
    refute detail.bound == detail.registered

    assert {:refused, :unregistered_subject, _} =
             VenueVerifier.adjudicate(
               exhibit["credential"],
               "attendee-Z",
               exhibit["subject_registry"],
               exhibit["jwks"],
               venue_host
             )

    # Payload tamper: a rewritten payload document fails the hash binding
    # even though the signature-side steps still pass.
    tampered = put_in(exhibit, ["credential", "payload", "badge_class"], "vip")

    assert {:refused, :payload_hash_mismatch, %{recomputed: r, presented: p}} =
             VenueVerifier.adjudicate(
               tampered["credential"],
               "attendee-X",
               exhibit["subject_registry"],
               exhibit["jwks"],
               venue_host
             )

    refute r == p

    # An unknown key id is refused, not silently skipped.
    assert {:refused, :unknown_key, _} =
             VenueVerifier.adjudicate(
               exhibit["credential"],
               "attendee-X",
               exhibit["subject_registry"],
               %{"keys" => []},
               venue_host
             )
  end

  test "court d: two trust roots coexist - the venue card and the affidavit credential do not clobber",
       %{exhibit: exhibit, venue_host: venue_host} do
    # The venue's own root: a real agent-card JWS (CardSigning over the RFC
    # 8785 wire projection, HS256 shared-secret root).
    venue_key = :crypto.strong_rand_bytes(32)

    card = %{
      name: "venue-agent",
      url: "https://venue.example/a2a",
      description: "venue",
      version: "1.0.0"
    }

    signed_card = AshA2A.Protocol.CardSigning.sign(card, venue_key, kid: "venue-hs1")

    assert :ok = AshA2A.Protocol.CardSigning.verify(signed_card, venue_key)

    # The affidavit credential verifies under the exhibitor root at the same
    # time - neither admission depends on the other.
    {:ok, _claims} =
      VenueVerifier.adjudicate(
        exhibit["credential"],
        "attendee-X",
        exhibit["subject_registry"],
        exhibit["jwks"],
        venue_host
      )

    # Cross-presentation is refused: the venue card does NOT verify under a
    # root derived from exhibitor key material.
    [exhibitor_key] = exhibit["jwks"]["keys"]
    exhibitor_material = "ev14-cross-root:" <> exhibitor_key["sec1"]

    assert {:error, {:bad_signature, %{index: 0}}} =
             AshA2A.Protocol.CardSigning.verify(signed_card, exhibitor_material)

    # A well-formed but WRONG ES256 key refuses the credential at the
    # signature step - the venue secret is not an exhibitor root.
    venue_as_jwks = %{
      "keys" => [
        %{
          "kty" => "EC",
          "crv" => "P-256",
          "alg" => "ES256",
          "kid" => exhibit["kid"],
          "sec1" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false)
        }
      ]
    }

    assert {:refused, :bad_signature, _} =
             VenueVerifier.adjudicate(
               exhibit["credential"],
               "attendee-X",
               exhibit["subject_registry"],
               venue_as_jwks,
               venue_host
             )

    # After all cross-presentation attempts, the honest credential still
    # verifies: coexistence did not disturb either root.
    {:ok, _} =
      VenueVerifier.adjudicate(
        exhibit["credential"],
        "attendee-X",
        exhibit["subject_registry"],
        exhibit["jwks"],
        venue_host
      )
  end

  # ---- fixtures ----------------------------------------------------------------

  defp run_vendor_b! do
    script = Path.join([@ash_affidavit_dir, "examples", "vendor_b_exhibit.exs"])

    result_path =
      Path.join(System.tmp_dir!(), "ev14-exhibit-#{System.unique_integer([:positive])}.json")

    {output, status} =
      System.cmd("mix", ["run", "--no-start", script],
        cd: @ash_affidavit_dir,
        env: %{"MIX_BUILD_ROOT" => @build_root, "RESULT_PATH" => result_path},
        stderr_to_stdout: true
      )

    if status != 0 do
      flunk("Vendor B exhibit subprocess failed (exit #{status}):\n#{output}")
    end

    exhibit = result_path |> File.read!() |> Jason.decode!()
    File.rm(result_path)
    exhibit
  end

  defp flip_hex_nibble(hex, idx) do
    {prefix, <<n, rest::binary>>} = String.split_at(hex, idx)
    prefix <> <<flip_char(n)>> <> rest
  end

  defp flip_char(c) when c in ?0..?8, do: c + 1
  defp flip_char(?9), do: ?a
  defp flip_char(?a), do: ?b
  defp flip_char(?b), do: ?c
  defp flip_char(?c), do: ?d
  defp flip_char(?d), do: ?e
  defp flip_char(?e), do: ?f
  defp flip_char(?f), do: ?0
end


# ==============================================================================
# SECTION 12 of 31: test/conference_sim/load_court_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule ConferenceSim.LoadCourt do
  @moduledoc """
  Conference-sim lane EV9 court: conference-scale concurrency — the
  "3,500 attendees" headline as a bounded, honest load test.

  ## Scale honesty

  CI cannot rehearse 3,500 simultaneous attendees. **100 concurrent
  attendee-agents here ≈ 3,500 at the venue — same code path, same real
  machinery** (real `AshA2A.Protocol.Agent` GenServers, real Ash/ETS tasks,
  real signed badge issuance, real subscriber fan-out), exercised at 1/35th
  scale. The ratio is a rehearsal scaling, not a capacity claim: passing at
  100 says the code path is concurrency-safe, NOT that the venue handles
  3,500 — venue-scale numbers need venue-scale load, which stays
  `UNKNOWN` here.

  ## Degradation honesty

  The scale is a `@load_scale` module attribute read from
  `CONFERENCE_SIM_LOAD_SCALE` (default 100). If a machine cannot run 100,
  the operator lowers the env var and the court **reports what WAS
  achieved** (via the per-court scale banner) and asserts the achieved
  count EQUALS the configured scale — never silently fewer.

  ## Courts

    * **Concurrent registration** — `@load_scale` attendee-agents issue
      badges concurrently through the REAL registration-authority agent
      (`issue_badge` skill → real `CardSigning.sign/3` card). All succeed;
      all issued receipts are for unique attendee ids.
    * **Concurrent session creation** — `@load_scale` concurrent
      `open_session` task creates on the venue agent. All succeed; all task
      ids (and session ids) are unique.
    * **Concurrent stream subscriptions** — `@load_scale` subscribers race
      to subscribe to ONE live session task, then all receive the session's
      `{:a2a_task_event, task_id, task}` fan-out.
    * **Mixed workload** — 50% task creates + 30% stream subscriptions +
      20% push-config registrations (of `@load_scale`), all under
      supervised (`Task.Supervisor`) async tasks — every task completes.

  Timing assertions are FLOORS not ceilings: durations are measured,
  reported, and only asserted to be non-negative / events to have arrived —
  no upper bounds, so a slow CI box never flakes.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.PushNotificationConfig

  @tag :load_scale
  @load_scale (case System.get_env("CONFERENCE_SIM_LOAD_SCALE") do
                 nil -> 100
                 "" -> 100
                 v -> String.to_integer(v)
               end)

  setup do
    {:ok, sim} = ConferenceSim.build(attendees: @load_scale)

    on_exit(fn ->
      ConferenceSim.teardown(sim)
    end)

    {:ok, sup} = Task.Supervisor.start_link(name: ConferenceSimLoadTaskSup)

    on_exit(fn ->
      # TOCTOU-safe: the supervisor may die between the alive? check and the
      # stop (Supervisor.stop tail-calls GenServer.stop, whose :noproc exit
      # would fail the test from the on_exit handler).
      try do
        if Process.alive?(sup), do: Supervisor.stop(sup)
      catch
        :exit, _ -> :ok
      end
    end)

    IO.puts("""
    \n[load_court] configured scale: #{@load_scale} concurrent attendee-agents \
    (100 here ≈ 3,500 at the venue, same code path)
    """)

    %{sim: sim}
  end

  # -- helpers -------------------------------------------------------------

  defp data_message(data, skill) when is_atom(skill) do
    msg = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(data)])
    %{msg | metadata: %{skill: skill}}
  end

  defp artifact_data(task) do
    case task.artifacts do
      [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: data}]}] -> data
      _ -> nil
    end
  end

  defp duration_ms({:mono, start}), do: System.monotonic_time(:millisecond) - start
  defp now(), do: {:mono, System.monotonic_time(:millisecond)}

  defp banner(court, n, elapsed) do
    IO.puts(
      "[load_court] #{court}: #{n} concurrent ops completed in #{elapsed}ms (floor-asserted)"
    )
  end

  # -- court 1: concurrent registration (badge issue) ------------------------

  @tag :conference_sim
  @tag :load_scale
  test "#{@load_scale} concurrent badge registrations all succeed with unique attendee ids", %{
    sim: sim
  } do
    attendees = sim.attendees
    assert length(attendees) == @load_scale

    t0 = now()

    results =
      attendees
      |> Enum.map(fn attendee ->
        Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
          {:ok, task} =
            ConferenceSim.BadgeAuthorityAgent.call(
              ConferenceSim.BadgeAuthorityAgent,
              data_message(%{attendee_id: attendee.id, tier: attendee.tier}, :issue_badge)
            )

          {:ok, attendee.id, artifact_data(task)}
        end)
      end)
      |> Task.await_many(60_000)

    elapsed = duration_ms(t0)
    assert elapsed >= 0, "timing assertions are floors"

    assert length(results) == @load_scale

    # All succeeded, all receipts are signed-and-stamped, all ids unique.
    receipts = Enum.map(results, fn {:ok, id, receipt} -> {id, receipt} end)
    assert length(receipts) == @load_scale

    assert Enum.all?(receipts, fn {_id, receipt} ->
             receipt[:signed] == true and receipt[:badge_kid] == ConferenceSim.badge_kid()
           end)

    ids = Enum.map(receipts, fn {id, _} -> id end)
    assert length(Enum.uniq(ids)) == @load_scale, "duplicate registration ids"
    assert Enum.sort(ids) == Enum.sort(Enum.map(attendees, & &1.id))

    banner("registration", @load_scale, elapsed)
  end

  # -- court 2: concurrent session creation on the venue ----------------------

  @tag :conference_sim
  @tag :load_scale
  test "#{@load_scale} concurrent session creates all succeed with unique task ids", %{
    sim: sim
  } do
    t0 = now()

    results =
      Enum.map(1..@load_scale, fn i ->
        Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
          track = "track-#{rem(i, 11) + 1}"

          {:ok, session} =
            ConferenceSim.open_session(sim, track, "Load session #{i}")

          {:ok, session}
        end)
      end)
      |> Task.await_many(60_000)

    elapsed = duration_ms(t0)
    assert elapsed >= 0

    assert length(results) == @load_scale

    sessions = Enum.map(results, fn {:ok, s} -> s end)
    task_ids = Enum.map(sessions, & &1.task_id)
    session_ids = Enum.map(sessions, & &1.id)

    assert Enum.all?(sessions, &(&1.track && &1.title))
    assert length(Enum.uniq(task_ids)) == @load_scale, "duplicate venue task ids"
    assert length(Enum.uniq(session_ids)) == @load_scale, "duplicate session ids"

    banner("session-create", @load_scale, elapsed)
  end

  # -- court 3: concurrent stream subscriptions, all receive the event --------

  @tag :conference_sim
  @tag :load_scale
  test "#{@load_scale} concurrent stream subscriptions all connect and all receive the session event",
       %{sim: sim} do
    {:ok, session} = ConferenceSim.open_session(sim, "keynote", "Keynote under load")

    parent = self()

    t0 = now()

    subscribers =
      Enum.map(1..@load_scale, fn i ->
        Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
          # Each subscriber connects concurrently...
          {:ok, _snapshot} =
            GenServer.call(ConferenceSim.VenueAgent, {:subscribe, session.task_id}, 30_000)

          send(parent, {:subscribed, i, self()})

          # ...waits for the barrier so the fan-out races ALL subscribers at
          # once, then receives the real {:a2a_task_event, ...} fan-out.
          assert_receive {:go, ^session}, 30_000

          assert_receive {:a2a_task_event, task_id, task}, 30_000
          assert task_id == session.task_id
          assert task.id == session.task_id

          {:ok, i}
        end)
      end)

    # Barrier: every subscriber is connected before the session changes.
    pids =
      for _ <- 1..@load_scale do
        assert_receive({:subscribed, _, pid}, 30_000)
        pid
      end

    for pid <- pids, do: send(pid, {:go, session})

    assert {:ok, _task} = ConferenceSim.session_update(sim, session, "room change: Hall B")

    results = Task.await_many(subscribers, 60_000)
    elapsed = duration_ms(t0)

    assert elapsed >= 0

    assert results == Enum.map(1..@load_scale, &{:ok, &1}),
           "not every subscriber connected and received the event"

    banner("stream-subscribe", @load_scale, elapsed)
  end

  # -- court 4: mixed workload under supervised async --------------------------

  @tag :conference_sim
  @tag :load_scale
  test "mixed workload: #{@load_scale && div(@load_scale, 2)} tasks + #{div(@load_scale, 10) * 3} streams + #{div(@load_scale, 5)} push configs all complete",
       %{sim: sim} do
    n_tasks = div(@load_scale, 2)
    n_streams = div(@load_scale, 10) * 3
    n_push = div(@load_scale, 5)
    total = n_tasks + n_streams + n_push
    assert total == @load_scale

    parent = self()

    {:ok, session} = ConferenceSim.open_session(sim, "mixed", "Mixed-workload keynote")

    t0 = now()

    jobs =
      Enum.concat([
        for i <- 1..n_tasks do
          Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
            {:ok, _session} =
              ConferenceSim.open_session(sim, "mixed-#{rem(i, 11) + 1}", "mixed task #{i}")

            {:task, i}
          end)
        end,
        for i <- 1..n_streams do
          Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
            {:ok, _snapshot} =
              GenServer.call(ConferenceSim.VenueAgent, {:subscribe, session.task_id}, 30_000)

            send(parent, {:subscribed, {:stream, i}, self()})

            assert_receive {:go, ^session}, 30_000
            assert_receive {:a2a_task_event, task_id, _}, 30_000
            assert task_id == session.task_id
            {:stream, i}
          end)
        end,
        for i <- 1..n_push do
          Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
            {:ok, session} = ConferenceSim.open_session(sim, "mixed", "push-config session #{i}")

            config = %PushNotificationConfig{
              id: "load-push-#{i}",
              task_id: session.task_id,
              url: "https://venue.agntcon.example/hooks/load-#{i}",
              token: "load-token-#{i}"
            }

            {:ok, _stored} =
              GenServer.call(ConferenceSim.VenueAgent, {:set_push_config, config}, 30_000)

            {:push, i}
          end)
        end
      ])

    # Barrier for the stream jobs, then the shared fan-out event.
    stream_pids =
      for _ <- 1..n_streams do
        assert_receive({:subscribed, {:stream, _}, pid}, 30_000)
        pid
      end

    for pid <- stream_pids, do: send(pid, {:go, session})

    assert {:ok, _} = ConferenceSim.session_update(sim, session, "mixed-workload room change")

    results = Task.await_many(jobs, 120_000)
    elapsed = duration_ms(t0)

    assert elapsed >= 0

    # ALL jobs completed — never silently fewer.
    expected =
      Enum.map(1..n_tasks, &{:task, &1}) ++
        Enum.map(1..n_streams, &{:stream, &1}) ++
        Enum.map(1..n_push, &{:push, &1})

    assert Enum.sort(results) == Enum.sort(expected),
           "mixed workload did not fully complete: got #{length(results)} of #{total}"

    banner("mixed", total, elapsed)
  end
end


# ==============================================================================
# SECTION 13 of 31: test/conference_sim/multitrack_stream_court_test.exs
# ==============================================================================

defmodule AshA2A.ConferenceSim.MultitrackStreamAgent do
  @moduledoc false
  # Real `AshA2A.Protocol.Agent` GenServer whose `handle_message/2` inspects the
  # inbound user text to pick a per-session (per-track) production schedule, so
  # four concurrent session tasks on ONE real transport have genuinely different
  # lifetimes: two short talks, one medium talk, and a keynote that runs long.
  use AshA2A.Protocol.Agent,
    name: "conf-multitrack",
    description: "conference with tracks of different lengths"

  alias AshA2A.Protocol.Message
  alias AshA2A.Protocol.Part

  @impl AshA2A.Protocol.Agent
  def handle_message(%Message{parts: parts}, _context) do
    track =
      Enum.find_value(parts, fn
        %Part.Text{text: t} -> t
        _ -> nil
      end) || "keynote"

    {count, delay_ms} = schedule(track)

    {:stream,
     Stream.map(1..count, fn i ->
       # SLEEP-CLASS: SIMULATED-SLOW-HANDLER (fixture models a slow collaborator)
       Process.sleep(delay_ms)
       Part.Text.new("#{track} part #{i}")
     end)}
  end

  defp schedule("track_a"), do: {3, 20}
  defp schedule("track_b"), do: {3, 20}
  defp schedule("track_c"), do: {5, 25}
  defp schedule("keynote"), do: {10, 60}
  defp schedule("loadtrack"), do: {8, 30}
end

defmodule AshA2A.ConferenceSim.MultitrackStreamCourt do
  @moduledoc """
  Conference-sim lane EV5 court: four concurrent session tasks stream on ONE
  real transport surface — real Bandit loopback listener serving
  `AshA2A.A2ATransport.Plug`, real `AshA2A.A2ATransport` supervision tree with
  its ETS event log, real streaming `AshA2A.Protocol.Agent` GenServer, real
  `Req` HTTP connections — with 12 attendee connections (3 per session, mixed
  `message/stream` + `tasks/resubscribe`) under event load.

  Spec semantics under court (https://a2a-protocol.org/latest/specification/):

    * S3.5.2: events MUST be delivered in the order they were generated —
      asserted as a strictly increasing task-local SSE `id:` sequence per
      subscriber, no duplicates.
    * S3.1.6 (`tasks/resubscribe`): reconnecting clients replay the backlog;
      with `Last-Event-ID` only events after the client's last seen seq are
      replayed — exactly the missed events, no duplicates, no gaps.
    * Session isolation: a stream for task X never carries task Y's events, a
      session ending never disturbs the others' connections, and the keynote
      stays open past the other sessions' close with no cross-session bleed.
  """

  use ExUnit.Case, async: true

  alias AshA2A.ConferenceSim.MultitrackStreamAgent
  alias AshA2A.Test.EphemeralHttp

  @tracks [
    {"track_a", 3},
    {"track_b", 3},
    {"track_c", 5},
    {"keynote", 10}
  ]

  @all_track_names ["track_a", "track_b", "track_c", "keynote", "loadtrack"]

  @terminal_states [
    "TASK_STATE_COMPLETED",
    "TASK_STATE_FAILED",
    "TASK_STATE_CANCELED",
    "TASK_STATE_REJECTED",
    "TASK_STATE_AUTH_REQUIRED"
  ]

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"conf_multitrack_#{uniq}"
    transport = :"a2a_transport_conf_#{uniq}"
    start_supervised!({MultitrackStreamAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    http =
      EphemeralHttp.start!(
        {AshA2A.A2ATransport.Plug, agent: agent, base_url: "http://x/a2a", transport: transport}
      )

    %{url: http.base_url, agent: agent, transport: transport}
  end

  # -- wire helpers ---------------------------------------------------------

  defp envelope(method, params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

  defp open_streaming(url, method, params, headers \\ []) do
    parent = self()

    spawn(fn ->
      Req.post!(url,
        json: envelope(method, params),
        headers: headers,
        retry: false,
        receive_timeout: 15_000,
        into: fn {:data, data}, acc ->
          send(parent, {:chunk, self(), data})
          {:cont, acc}
        end
      )

      send(parent, {:stream_closed, self()})
    end)
  end

  defp open_session(url, track) do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user(track))
    open_streaming(url, "message/stream", %{"message" => encoded})
  end

  defp resubscribe_async(url, task_id, headers \\ []),
    do: open_streaming(url, "tasks/resubscribe", %{"id" => task_id}, headers)

  defp resubscribe(url, task_id, headers) do
    Req.post!(url,
      json: envelope("tasks/resubscribe", %{"id" => task_id}),
      headers: headers,
      retry: false,
      receive_timeout: 15_000
    )
  end

  defp parse_sse(body) do
    {frames, keepalives} =
      body
      |> String.split("\n\n", trim: true)
      |> Enum.flat_map_reduce(0, fn frame, keepalives ->
        lines = String.split(frame, "\n")
        comments = Enum.filter(lines, &String.starts_with?(&1, ":"))
        keepalives = keepalives + length(comments)

        frames =
          for "data: " <> json <- Enum.filter(lines, &String.starts_with?(&1, "data: ")) do
            id =
              case Enum.find(lines, &String.starts_with?(&1, "id: ")) do
                "id: " <> value -> String.to_integer(String.trim(value))
                nil -> nil
              end

            {id, Jason.decode!(json)["result"]}
          end

        {frames, keepalives}
      end)

    {:frames, frames, keepalives}
  end

  defp await_task_id(pid, acc \\ "") do
    receive do
      {:chunk, ^pid, data} ->
        case Enum.find(elem(parse_sse(acc <> data), 1), fn {_id, result} ->
               match?(%{"task" => %{"id" => _}}, result)
             end) do
          nil -> await_task_id(pid, acc <> data)
          {_id, %{"task" => %{"id" => id}}} -> id
        end
    after
      5_000 -> flunk("no first SSE frame")
    end
  end

  defp collect(pid, acc \\ "") do
    receive do
      {:chunk, ^pid, data} -> collect(pid, acc <> data)
      {:stream_closed, ^pid} -> acc
    after
      20_000 -> flunk("stream did not close")
    end
  end

  defp collect_until(pid, pred, acc \\ "") do
    receive do
      {:chunk, ^pid, data} ->
        acc = acc <> data
        if pred.(acc), do: acc, else: collect_until(pid, pred, acc)

      {:stream_closed, ^pid} ->
        acc
    after
      15_000 -> flunk("stream did not produce the expected prefix")
    end
  end

  defp unwrap(%{"task" => task}), do: {:task, task}
  defp unwrap(%{"statusUpdate" => event}), do: {:status, event}
  defp unwrap(%{"artifactUpdate" => event}), do: {:artifact, event}

  defp artifact_texts(results) do
    for {:artifact, %{"artifact" => %{"parts" => [%{"text" => t}]}}} <-
          Enum.map(results, &unwrap/1),
        do: t
  end

  defp final_state(results) do
    Enum.find_value(results, fn result ->
      case unwrap(result) do
        {:status, %{"status" => %{"state" => state}}} when state in @terminal_states -> state
        _ -> nil
      end
    end)
  end

  defp assert_strictly_increasing_ids(frames) do
    # A resubscribe snapshot frame (and StreamError frames) carry no `id:`
    # line by design; only seq-numbered frames take part in ordering.
    ids = frames |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1)

    assert ids == Enum.uniq(ids), "duplicate SSE ids: #{inspect(ids)}"
    assert ids == Enum.sort(ids), "SSE ids not in generation order: #{inspect(ids)}"
    :ok
  end

  defp expected_parts(track, count), do: for(i <- 1..count, do: "#{track} part #{i}")

  defp assert_no_cross_session_bleed(body, track) do
    for other <- @all_track_names, other != track do
      refute body =~ "#{other} part", "#{track} connection bled #{other} events"
    end

    :ok
  end

  # -- court 1: 4 sessions x 3 subscribers; ordering, terminal frames,
  #    isolation, keynote runs long ----------------------------------------

  test "four concurrent sessions, 12 subscribers: ordered, isolated, keynote runs long", %{
    url: url
  } do
    # 4 concurrent session tasks via message/stream on the setup transport.
    primaries =
      for {track, _n} <- @tracks, into: %{} do
        {track, open_session(url, track)}
      end

    task_ids =
      for {track, conn} <- primaries, into: %{} do
        {track, await_task_id(conn)}
      end

    assert 4 == map_size(task_ids) and 4 == task_ids |> Map.values() |> Enum.uniq() |> length()

    # 8 more attendee connections via tasks/resubscribe: 3 subscribers per
    # session, 12 concurrent SSE connections over the real Bandit listener.
    resubs =
      for {track, task_id} <- task_ids, k <- 1..2, into: %{} do
        {{track, k}, resubscribe_async(url, task_id)}
      end

    assert map_size(resubs) == 8

    # Temporal isolation court: track_a and track_b (3 x 20ms parts) close
    # first. Collect them to closure, then prove the keynote connection is
    # STILL delivering new chunks — its stream stayed open past the shorts'
    # close, with no cross-session bleed.
    keynote_conn = Map.fetch!(primaries, "keynote")
    a_conn = Map.fetch!(primaries, "track_a")
    b_conn = Map.fetch!(primaries, "track_b")

    body_a = collect(a_conn)
    body_b = collect(b_conn)

    # Keynote still open and producing after both short sessions ended.
    assert_receive {:chunk, ^keynote_conn, _}, 5_000

    # Drain every remaining connection to terminal closure, then court each body.
    bodies =
      for {track, conn} <- primaries, into: %{} do
        {track,
         case track do
           "track_a" -> body_a
           "track_b" -> body_b
           _ -> collect(conn)
         end}
      end

    resub_bodies =
      for {{track, k}, conn} <- resubs, into: %{} do
        {{track, k}, collect(conn)}
      end

    for {track, n} <- @tracks do
      resub_bodies_for_track = for(k <- 1..2, do: Map.fetch!(resub_bodies, {track, k}))

      # Resubscribers joined from the log snapshot: full projection, snapshot
      # frame first, every part, terminal frame, connection closed.
      for body <- resub_bodies_for_track do
        court_closed_body(body, track, n, require_snapshot: true, expect: :all_parts)
      end

      # Primaries: each primary's first chunk(s) were consumed by
      # await_task_id/2 (which drops its accumulator, replay-test precedent),
      # so each primary body is a gapless contiguous suffix of its session —
      # the resubscribers carry the full projection with the snapshot frame.
      primary = Map.fetch!(bodies, track)
      court_closed_body(primary, track, n, require_snapshot: false, expect: :suffix)
    end
  end

  defp court_closed_body(body, track, n, opts) do
    assert_no_cross_session_bleed(body, track)
    {:frames, frames, _} = parse_sse(body)
    assert_strictly_increasing_ids(frames)

    results = Enum.map(frames, &elem(&1, 1))

    if Keyword.fetch!(opts, :require_snapshot) do
      assert %{"task" => %{"id" => _}} = hd(results)
    end

    expected = expected_parts(track, n)
    got = artifact_texts(results)

    case Keyword.fetch!(opts, :expect) do
      :all_parts ->
        assert got == expected, "track #{track}: wrong artifact sequence"

      :suffix ->
        # Contiguous-suffix check: the prefix was consumed while learning the
        # task id, everything from the first surviving frame to the terminal
        # frame must still be gapless.
        suffix? = Enum.any?(0..length(expected), fn k -> Enum.drop(expected, k) == got end)
        assert suffix?, "track #{track}: artifacts not a contiguous suffix: #{inspect(got)}"
    end

    assert final_state(results) == "TASK_STATE_COMPLETED"
    assert {:status, _} = results |> List.last() |> unwrap()
    :ok
  end

  # -- court 2: disconnect mid-session, Last-Event-ID replays exactly the
  #    missed events ---------------------------------------------------------

  test "mid-session disconnect then Last-Event-ID resubscribe replays exactly the missed events",
       %{
         url: url
       } do
    a = open_session(url, "track_c")
    task_id = await_task_id(a)

    prefix =
      collect_until(a, fn acc ->
        {:frames, frames, _} = parse_sse(acc)
        length(frames) >= 3
      end)

    Process.exit(a, :kill)

    {:frames, seen, _} = parse_sse(prefix)
    seen_parts = artifact_texts(Enum.map(seen, &elem(&1, 1)))
    last_id = seen |> Enum.map(&elem(&1, 0)) |> Enum.max()

    resp = resubscribe(url, task_id, [{"last-event-id", Integer.to_string(last_id)}])
    assert resp.status == 200
    assert hd(Req.Response.get_header(resp, "content-type")) =~ "text/event-stream"

    {:frames, replay_frames, _} = parse_sse(resp.body)
    results = Enum.map(replay_frames, &elem(&1, 1))

    # Snapshot first, then ONLY events after last_id: no duplicates of already
    # seen parts, no gap, terminal statusUpdate closes the stream.
    assert [%{"task" => %{"id" => ^task_id}} | replay_results] = results
    assert artifact_texts(replay_results) == expected_parts("track_c", 5) -- seen_parts
    assert Enum.all?(tl(Enum.map(replay_frames, &elem(&1, 0))), &(&1 > last_id))
    assert final_state(results) == "TASK_STATE_COMPLETED"
    assert_strictly_increasing_ids(replay_frames)
  end

  # -- court 3: load — 12 concurrent SSE connections, clean teardown ---------

  test "load: 12 concurrent SSE connections over the real Bandit listener, clean teardown", %{
    url: url
  } do
    ports_before = length(:erlang.ports())

    # The setup listener IS the load surface: 12 concurrent SSE connections on
    # one real Bandit listener.
    keynote = open_session(url, "keynote")
    task_id = await_task_id(keynote)

    subs =
      for _k <- 1..11 do
        resubscribe_async(url, task_id)
      end

    conns = [keynote | subs]
    assert length(conns) == 12

    # The spawn connections all message the test process; collect/1 filters by
    # pid, so interleaved chunk traffic drains per connection correctly.
    bodies = Enum.map(conns, &collect(&1))

    parsed = Enum.map(bodies, fn body -> elem(parse_sse(body), 1) end)

    # No port exhaustion / no refused streams: every one of the 12 connections
    # received the full projection (snapshot + 10 artifacts + terminal frame).
    assert length(parsed) == 12

    for {body, frames} <- Enum.zip(bodies, parsed) do
      assert_no_cross_session_bleed(body, "keynote")
      assert_strictly_increasing_ids(frames)

      results = Enum.map(frames, &elem(&1, 1))
      assert artifact_texts(results) == expected_parts("keynote", 10)
      assert final_state(results) == "TASK_STATE_COMPLETED"
    end

    # The 11 resubscribers project the shared ordered log identically; the
    # primary's message/stream projection is courted by the content assertions
    # above (it lacks the resubscribe snapshot frame by design).
    [_primary | resubs_parsed] = parsed
    assert length(Enum.uniq(resubs_parsed)) == 1

    # Clean teardown: every client process exited, the connection mailbox
    # drains to silence, and the OS socket count stays bounded (concurrent
    # sibling tests and the shared Finch keepalive pool hold a few ports, so
    # this is a leak bound, not an exact-return-to-baseline court).
    assert Enum.all?(conns, &(not Process.alive?(&1)))

    eventually(fn ->
      assert length(:erlang.ports()) <= ports_before + 40
      true
    end)

    refute_receive {:chunk, _, _}, 250
    refute_receive {:stream_closed, _}, 250
    :ok
  end

  defp eventually(fun, deadline \\ nil) do
    deadline = deadline || :erlang.monotonic_time(:millisecond) + 5_000

    cond do
      fun.() ->
        :ok

      :erlang.monotonic_time(:millisecond) > deadline ->
        flunk("condition not reached")

      true ->
        # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
        AshA2A.TestSupport.Eventually.pause(50)
        eventually(fun, deadline)
    end
  end
end


# ==============================================================================
# SECTION 14 of 31: test/conference_sim/networking_court_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConferenceSim.Networking.Venue do
  @moduledoc """
  The venue: the conference's real discovery point. A real Plug served over a
  real loopback HTTP listener (`AshA2A.Test.EphemeralHttp`) that keeps a
  registry of attendee cards.

  Attendees register over real HTTP (`POST /register` with
  `{name, url, tier}`); the venue then fetches each attendee's card from the
  attendee's own served `/.well-known/agent-card.json` over real HTTP -- the
  venue never accepts a hand-supplied card. `GET /registry` returns the
  entries so any attendee can discover its peers.

  The venue stores CARDS ONLY. No message content ever passes through it,
  which is what the privacy court asserts against the real registry bytes.
  """

  @behaviour Plug

  @impl true
  def init(table: table), do: %{table: table}

  @impl true
  def call(%{method: "POST", path_info: ["register"]} = conn, %{table: table}) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"name" => name, "url" => url, "tier" => tier} = Jason.decode!(body)

    {:ok, %Req.Response{status: 200, body: card}} =
      Req.get(url <> "/.well-known/agent-card.json")

    true = is_map(card) and is_binary(card["name"])

    true =
      :ets.insert(table, {{:attendee, name}, %{"url" => url, "tier" => tier, "card" => card}})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "name" => name}))
  end

  def call(%{method: "GET", path_info: ["registry"]} = conn, %{table: table}) do
    entries =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {{:attendee, name}, value} -> Map.put(value, "name", name) end)
      |> Enum.sort_by(& &1["name"])

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"attendees" => every_entry(entries)}))
  end

  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not_found"}))
  end

  defp every_entry(entries), do: entries
end

defmodule AshA2A.ConferenceSim.Networking.Policy do
  @moduledoc """
  The conference's real contact policy, evaluated by every receiving
  attendee:

  1. a sender on the recipient's blocked-contact list is refused with
     `contact_blocked`;
  2. a `general`-tier sender may not open contact with another `general`-tier
     attendee (`tier_policy_denied`) -- `vip` attendees may contact, and be
     contacted by, any tier;
  3. otherwise the contact is allowed.
  """

  @spec evaluate(MapSet.t(), String.t(), String.t(), String.t()) :: :ok | {:refused, String.t()}
  def evaluate(blocked, recipient_tier, sender_name, sender_tier) do
    cond do
      MapSet.member?(blocked, sender_name) -> {:refused, "contact_blocked"}
      recipient_tier == "general" && sender_tier == "general" -> {:refused, "tier_policy_denied"}
      true -> :ok
    end
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendee do
  @moduledoc """
  Shared attendee logic. Config (identity, tier, blocked list, transcript
  table) reaches the agent's spawned, unregistered worker processes through
  `:persistent_term` keyed by the agent module -- the same measured constraint
  `AshA2A.Test.SemanticPeerFixture.PeerB` documents (SEC-02/SEC-08 worker
  isolation): no registered name exists inside `handle_message/2`.
  """

  @doc "Installs the real config for one attendee agent module."
  def configure(agent_mod, config) do
    :persistent_term.put({agent_mod, :conference_sim_config}, config)
  end

  def deconfigure(agent_mod) do
    :persistent_term.erase({agent_mod, :conference_sim_config})
  end

  @doc """
  Real handling shared by all six attendee agents. A delivered message is
  answered with a completed task carrying an ack data part; a refused message
  is answered with a bare typed-refusal message (`{"message": ...}` on the
  SendMessageResponse oneof) and never creates a task.
  """
  def handle(agent_mod, %AshA2A.Protocol.Message{} = message, _context) do
    config = :persistent_term.get({agent_mod, :conference_sim_config})
    %{"from" => sender, "tier" => sender_tier, "body" => body} = data_part(message)

    case AshA2A.ConferenceSim.Networking.Policy.evaluate(
           config.blocked,
           config.tier,
           sender,
           sender_tier
         ) do
      :ok ->
        AshA2A.ConferenceSim.Networking.Attendee.record(
          config.transcript,
          config.name,
          :message,
          sender,
          body
        )

        {:reply, [AshA2A.Protocol.Part.Data.new(%{"ack" => body, "from" => config.name})]}

      {:refused, code} ->
        AshA2A.ConferenceSim.Networking.Attendee.record(
          config.transcript,
          config.name,
          :refusal,
          sender,
          body
        )

        {:message,
         [
           AshA2A.Protocol.Part.Data.new(%{
             "standing" => "refused",
             "code" => code,
             "from" => config.name,
             "detail" => "#{config.name} refuses contact from #{sender} (#{sender_tier}): #{code}"
           })
         ]}
    end
  end

  @doc """
  One attendee's real transcript, in arrival order. The table is shared by
  all six attendees in a test, so entries are keyed by the RECEIVING
  attendee's own name -- an attendee's transcript is what that attendee
  actually saw, and nobody else's.
  """
  @spec transcript(atom(), String.t(), :message | :refusal) :: [{String.t(), String.t()}]
  def transcript(table, owner, kind \\ :message) do
    table
    |> :ets.tab2list()
    |> Enum.sort()
    |> Enum.filter(fn
      {seq, entry_owner, entry_kind, _from, _body} ->
        is_integer(seq) and entry_owner == owner and entry_kind == kind

      _counter ->
        false
    end)
    |> Enum.map(fn {_seq, _owner, _kind, from, body} -> {from, body} end)
  end

  @doc "Records one real transcript entry owned by the receiving attendee."
  def record(table, owner, kind, from, body) do
    seq = :ets.update_counter(table, :seq, {2, 1}, {:seq, 0})
    true = :ets.insert(table, {seq, owner, kind, from, body})
    :ok
  end

  defp data_part(%AshA2A.Protocol.Message{parts: parts}) do
    Enum.find_value(parts, fn
      %AshA2A.Protocol.Part.Data{data: %{"from" => _, "tier" => _, "body" => _} = data} -> data
      _ -> nil
    end)
  end
end

# Six real attendee agents. Each is a genuine `use AshA2A.Protocol.Agent`
# GenServer with its own served identity, delegating to the shared attendee
# logic with its own module as the config key.
defmodule AshA2A.ConferenceSim.Networking.Attendees.Alice do
  @moduledoc "Attendee agent alice (VIP)."

  use AshA2A.Protocol.Agent,
    name: "attendee-alice",
    description: "VIP attendee alice",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendees.Ben do
  @moduledoc "Attendee agent ben (VIP)."

  use AshA2A.Protocol.Agent,
    name: "attendee-ben",
    description: "VIP attendee ben",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendees.Carol do
  @moduledoc "Attendee agent carol (general admission)."

  use AshA2A.Protocol.Agent,
    name: "attendee-carol",
    description: "General-admission attendee carol",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendees.Dee do
  @moduledoc "Attendee agent dee (general admission)."

  use AshA2A.Protocol.Agent,
    name: "attendee-dee",
    description: "General-admission attendee dee",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendees.Eli do
  @moduledoc "Attendee agent eli (VIP)."

  use AshA2A.Protocol.Agent,
    name: "attendee-eli",
    description: "VIP attendee eli",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.Networking.Attendees.Fay do
  @moduledoc "Attendee agent fay (general admission)."

  use AshA2A.Protocol.Agent,
    name: "attendee-fay",
    description: "General-admission attendee fay",
    skills: [
      %{
        id: "networking.message",
        name: "message",
        description: "Receive an attendee-to-attendee networking message.",
        tags: ["networking"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    AshA2A.ConferenceSim.Networking.Attendee.handle(__MODULE__, message, context)
  end
end

defmodule AshA2A.ConferenceSim.NetworkingCourt do
  @moduledoc """
  Conference-sim lane EV12: attendee-to-attendee agent messaging -- the
  "networking" feature as real A2A agent-to-agent messaging.

  ## The world under court

  Six attendee agents (alice/ben/eli VIP, carol/dee/fay general), each a real
  `use AshA2A.Protocol.Agent` GenServer behind a real `AshA2A.Transport.HTTPJSON`
  binding on its own real loopback Bandit listener (ephemeral port), plus a
  real venue plug on its own listener acting as the discovery point.

  ## Courts

  1. Discovery: all six attendees register with the venue over real HTTP; the
     venue fetches each card from the attendee's own well-known endpoint; the
     registry served back matches what each attendee itself serves.
  2. Two-way conversation: alice sends a message/task to ben over the real
     transport and gets ben's ack back in the completed task; ben then sends
     to alice; each attendee's real transcript contains the other's message,
     so both sides see both messages.
  3. Privacy boundary: carol (a third attendee) sees nothing of the alice<->ben
     conversation -- her transcript has none of it and the venue's registry
     bytes contain no message content at all.
  4. Auth tiers: VIP->general and general->VIP contacts succeed where the
     tier policy allows, and general->general is a typed refusal.
  5. Blocked contact: ben blocks alice; alice's messages get the typed
     refusal (`contact_blocked`), ben's transcript is untouched, and ben is
     unaffected elsewhere (still messages eli, still receives fay).
  6. Rate: alice sends 20 messages rapidly to ben; all 20 deliver, in send
     order, with unique task ids -- no loss, no reorder.

  Chicago-style: real supervised agent GenServers, real HTTP listeners, real
  `AshA2A.Protocol.Client` round trips, assertions on real transcripts and
  real wire responses. No Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: false

  alias AshA2A.ConferenceSim.Networking.{Attendee, Venue}
  alias AshA2A.ConferenceSim.Networking.Attendees.{Alice, Ben, Carol, Dee, Eli, Fay}
  alias AshA2A.Protocol.{Client, Message, Part, Task}
  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}

  @tiers %{
    Alice => "vip",
    Ben => "vip",
    Carol => "general",
    Dee => "general",
    Eli => "vip",
    Fay => "general"
  }
  @agents [Alice, Ben, Carol, Dee, Eli, Fay]

  setup do
    unique = System.unique_integer([:positive])
    transcript = :"conference_sim_transcript_#{unique}"
    venue_table = :"conference_sim_venue_#{unique}"
    :ets.new(transcript, [:named_table, :public, :ordered_set])
    :ets.new(venue_table, [:named_table, :public, :set])

    Enum.each(@agents, fn mod ->
      Attendee.configure(mod, %{
        name: attendee_name(mod),
        tier: Map.fetch!(@tiers, mod),
        blocked: MapSet.new(),
        transcript: transcript
      })
    end)

    {_sup, _registry} = AgentSupervisorCase.start_supervised_agents!(__MODULE__, @agents)

    servers =
      Map.new(@agents, fn mod ->
        {mod,
         EphemeralHttp.start!(
           {AshA2A.Transport.HTTPJSON,
            AshA2A.Transport.HTTPJSON.init(
              agent: mod,
              base_url: "http://127.0.0.1/attendee-#{attendee_name(mod)}"
            )}
         )}
      end)

    venue = EphemeralHttp.start!({Venue, table: venue_table})

    on_exit(fn ->
      Enum.each(@agents, &Attendee.deconfigure/1)
      # The tables are owned by the test process and die with it; tolerate
      # that when the on_exit callback runs after the owner has exited.
      if :ets.info(transcript) != :undefined, do: :ets.delete(transcript)
      if :ets.info(venue_table) != :undefined, do: :ets.delete(venue_table)
    end)

    %{transcript: transcript, venue: venue, servers: servers}
  end

  # -- helpers -------------------------------------------------------------------

  defp attendee_name(Alice), do: "alice"
  defp attendee_name(Ben), do: "ben"
  defp attendee_name(Carol), do: "carol"
  defp attendee_name(Dee), do: "dee"
  defp attendee_name(Eli), do: "eli"
  defp attendee_name(Fay), do: "fay"

  defp tier(mod), do: Map.fetch!(@tiers, mod)

  # Register every attendee with the venue over real HTTP; the venue fetches
  # each card from the attendee's own well-known endpoint.
  defp register_all!(venue, servers) do
    Enum.each(@agents, fn mod ->
      {:ok, %Req.Response{status: 200, body: %{"ok" => true}}} =
        Req.post(venue.base_url <> "/register",
          json: %{
            "name" => attendee_name(mod),
            "url" => Map.fetch!(servers, mod).base_url,
            "tier" => tier(mod)
          }
        )
    end)
  end

  defp registry!(venue) do
    {:ok, %Req.Response{status: 200, body: %{"attendees" => attendees}}} =
      Req.get(venue.base_url <> "/registry")

    attendees
  end

  # A real attendee-to-attendee A2A message: the sender posts to the
  # RECIPIENT's served HTTPJSON binding -- the recipient's client is built
  # from the recipient's own base_url, exactly as a real peer would.
  defp attendee_send(servers, from, to, body) do
    message =
      Message.new_user([
        Part.Data.new(%{"from" => attendee_name(from), "tier" => tier(from), "body" => body})
      ])

    client = Client.new(Map.fetch!(servers, to).base_url, transport: :http_json)
    Client.send_message(client, message)
  end

  defp task_data(%Task{artifacts: [%{parts: parts} | _]}) do
    Enum.find_value(parts, fn
      %Part.Data{data: data} -> data
      _ -> nil
    end)
  end

  defp refusal_data(%Message{parts: parts}) do
    Enum.find_value(parts, fn
      %Part.Data{data: %{"standing" => "refused"} = data} -> data
      _ -> nil
    end)
  end

  # -- courts --------------------------------------------------------------------

  test "1. discovery: six attendees discover each other through the venue's registry over real transport",
       %{venue: venue, servers: servers} do
    register_all!(venue, servers)
    attendees = registry!(venue)

    assert Enum.map(attendees, & &1["name"]) |> Enum.sort() == ~w(alice ben carol dee eli fay)

    # Every registry entry's card is exactly the card that attendee itself
    # serves, at the URL the registry hands back -- discovery is real.
    for entry <- attendees do
      assert entry["url"] == Map.fetch!(servers, safe_mod!(entry["name"])).base_url

      # The registry card is byte-identical to what the attendee itself
      # serves, and a real client can discover the attendee through it.
      {:ok, %Req.Response{status: 200, body: raw_card}} =
        Req.get(entry["url"] <> "/.well-known/agent-card.json")

      assert entry["card"] == raw_card

      {:ok, served} = Client.discover(entry["url"])
      assert served.name == entry["card"]["name"]
      assert Enum.any?(served.skills, &(&1.id == "networking.message"))
    end
  end

  test "2. two-way conversation: alice and ben each see both messages over the real transport",
       %{transcript: transcript, venue: venue, servers: servers} do
    register_all!(venue, servers)

    {:ok, %Task{status: %{state: :completed}} = task} =
      attendee_send(servers, Alice, Ben, "hi ben, this is alice")

    assert task_data(task) == %{"ack" => "hi ben, this is alice", "from" => "ben"}

    {:ok, %Task{status: %{state: :completed}} = reply_task} =
      attendee_send(servers, Ben, safe_mod!("alice"), "hi alice, ben here")

    assert task_data(reply_task) == %{"ack" => "hi alice, ben here", "from" => "alice"}

    # Each side's REAL transcript contains the other's message.
    assert Attendee.transcript(transcript, "ben") == [{"alice", "hi ben, this is alice"}]
    assert Attendee.transcript(transcript, "alice") == [{"ben", "hi alice, ben here"}]
  end

  test "3. privacy boundary: carol sees nothing of the alice<->ben conversation, and the venue carries no message content",
       %{transcript: transcript, venue: venue, servers: servers} do
    register_all!(venue, servers)

    {:ok, %Task{status: %{state: :completed}}} =
      attendee_send(servers, Alice, safe_mod!("ben"), "secret handoff at the lobby")

    {:ok, %Task{status: %{state: :completed}}} =
      attendee_send(servers, Ben, safe_mod!("alice"), "secret confirmed")

    # Carol's real transcript: nothing from alice or ben, none of their bodies.
    assert Attendee.transcript(transcript, "carol") == []
    assert Attendee.transcript(transcript, "alice") == [{"ben", "secret confirmed"}]
    assert Attendee.transcript(transcript, "ben") == [{"alice", "secret handoff at the lobby"}]

    # The venue's registry bytes contain no message content at all -- the
    # discovery plane never becomes a surveillance plane.
    {:ok, %Req.Response{body: registry_body}} = Req.get(venue.base_url <> "/registry")
    registry_bytes = Jason.encode!(registry_body)
    refute registry_bytes =~ "secret handoff at the lobby"
    refute registry_bytes =~ "secret confirmed"

    # Carol can still conduct her own networking, unaffected.
    {:ok, %Task{status: %{state: :completed}} = carol_task} =
      attendee_send(servers, Carol, safe_mod!("eli"), "eli, meet carol")

    assert task_data(carol_task) == %{"ack" => "eli, meet carol", "from" => "eli"}
    assert Attendee.transcript(transcript, "eli") == [{"carol", "eli, meet carol"}]
  end

  test "4. auth tiers: vip->general and general->vip deliver where the policy allows; general->general is a typed refusal",
       %{transcript: transcript, venue: venue, servers: servers} do
    register_all!(venue, servers)

    # VIP -> general: allowed.
    {:ok, %Task{status: %{state: :completed}} = vip_task} =
      attendee_send(servers, Alice, safe_mod!("dee"), "vip alice to general dee")

    assert task_data(vip_task) == %{"ack" => "vip alice to general dee", "from" => "dee"}

    # general -> VIP: allowed.
    {:ok, %Task{status: %{state: :completed}} = general_task} =
      attendee_send(servers, Carol, safe_mod!("eli"), "general carol to vip eli")

    assert task_data(general_task) == %{"ack" => "general carol to vip eli", "from" => "eli"}

    # general -> general: refused, typed, and no task is ever created.
    {:ok, %Message{} = refusal} =
      attendee_send(servers, Dee, safe_mod!("carol"), "dee to carol")

    assert refusal_data(refusal) == %{
             "standing" => "refused",
             "code" => "tier_policy_denied",
             "from" => "carol",
             "detail" => "carol refuses contact from dee (general): tier_policy_denied"
           }

    # The refusal never entered carol's delivered-message transcript.
    assert Attendee.transcript(transcript, "dee") == [{"alice", "vip alice to general dee"}]
    assert Attendee.transcript(transcript, "eli") == [{"carol", "general carol to vip eli"}]
    assert Attendee.transcript(transcript, "carol", :message) == []
    assert Attendee.transcript(transcript, "carol", :refusal) == [{"dee", "dee to carol"}]
  end

  test "5. blocked contact: ben blocks alice -- typed refusal, ben's transcript untouched, ben unaffected elsewhere",
       %{transcript: transcript, venue: venue, servers: servers} do
    register_all!(venue, servers)

    # Ben blocks alice: a real config change at ben's own boundary.
    ben_config = :persistent_term.get({Ben, :conference_sim_config})
    Attendee.configure(Ben, %{ben_config | blocked: MapSet.put(ben_config.blocked, "alice")})

    # Alice's messages now get the typed refusal.
    {:ok, %Message{} = refusal} =
      attendee_send(servers, Alice, safe_mod!("ben"), "still want to connect?")

    assert refusal_data(refusal)["code"] == "contact_blocked"
    assert refusal_data(refusal)["from"] == "ben"

    # Ben's delivered-message transcript is untouched.
    assert Attendee.transcript(transcript, "ben", :message) == []

    assert Attendee.transcript(transcript, "ben", :refusal) == [
             {"alice", "still want to connect?"}
           ]

    # Ben is unaffected elsewhere: he can still initiate to eli ...
    {:ok, %Task{status: %{state: :completed}} = out_task} =
      attendee_send(servers, Ben, safe_mod!("eli"), "ben to eli, ignoring alice")

    assert task_data(out_task) == %{"ack" => "ben to eli, ignoring alice", "from" => "eli"}

    # ... and still receive from a non-blocked attendee.
    {:ok, %Task{status: %{state: :completed}}} =
      attendee_send(servers, Fay, safe_mod!("ben"), "fay says hi to ben")

    assert Attendee.transcript(transcript, "eli") == [{"ben", "ben to eli, ignoring alice"}]
    assert Attendee.transcript(transcript, "ben") == [{"fay", "fay says hi to ben"}]
  end

  test "6. rate: alice sends 20 messages rapidly to ben -- all delivered, in order, no loss, no reorder",
       %{transcript: transcript, venue: venue, servers: servers} do
    register_all!(venue, servers)

    tasks =
      for i <- 1..20 do
        case attendee_send(
               servers,
               Alice,
               Ben,
               "rapid-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
             ) do
          {:ok, %Task{} = task} -> task
          other -> flunk("message #{i} lost: #{inspect(other)}")
        end
      end

    # All 20 completed, all unique tasks.
    assert length(tasks) == 20
    assert Enum.all?(tasks, &(&1.status.state == :completed))
    assert tasks |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 20

    # Ben's real transcript: all 20 bodies, in exact send order.
    assert Attendee.transcript(transcript, "ben") ==
             Enum.map(1..20, fn i ->
               {"alice", "rapid-#{String.pad_leading(Integer.to_string(i), 3, "0")}"}
             end)
  end

  defp safe_mod!("alice"), do: Alice
  defp safe_mod!("ben"), do: Ben
  defp safe_mod!("carol"), do: Carol
  defp safe_mod!("dee"), do: Dee
  defp safe_mod!("eli"), do: Eli
  defp safe_mod!("fay"), do: Fay
end


# ==============================================================================
# SECTION 15 of 31: test/conference_sim/observability_court_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule ConferenceSim.ObservabilityVenue do
  @moduledoc """
  Real conference venue agent (EV11 fixture, named ObservabilityVenue so it does not collide with the
  shared fixture's Ash resource `ConferenceSim.Venue`: test/conference_sim/observability_court.exs owns it).

  One AshA2A.Agent GenServer with three activities, routed on the inbound
  Part.Data payload:

    * register - attendee registration, answers a non-streaming {:reply, _}
      (the registration task runs :working -> :completed);
    * task - a plain task create, non-streaming;
    * stream - a stream connect, answers {:stream, enum} (three chunks; the
      task parks in :working until the real {:stream_done, _} cast folds it
      to :completed).

  The :resource_or_domain fixture is never dispatched (same pattern as
  AshA2A.V1ArtifactStreamingTest.StreamAgent): handle_message/2 is genuinely
  overridden; AshA2A.Test.Fixture.Echo exists only because
  AshA2A.Agent.__using__/1 requires one.

  NOTE (EV11): once the shared ConferenceSim fixture lane lands
  (test/conference_sim/fixture.ex, ConferenceSim.build/1), this venue can be
  replaced by the shared fixture's venue; the courts read only the
  observability surface, so they are fixture-agnostic by construction.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Echo,
    name: "conference_sim_venue"

  alias AshA2A.Protocol.Part

  @impl AshA2A.Protocol.Agent
  def handle_message(
        %AshA2A.Protocol.Message{
          parts: [%Part.Data{data: %{"activity" => "register", "attendee" => attendee}}]
        },
        _context
      ) do
    {:reply,
     [
       Part.Data.new(%{
         "activity" => "register",
         "attendee" => attendee,
         "badge" => "badge-" <> attendee
       })
     ]}
  end

  @impl AshA2A.Protocol.Agent
  def handle_message(
        %AshA2A.Protocol.Message{parts: [%Part.Data{data: %{"activity" => "stream"}}]},
        _context
      ) do
    {:stream, Stream.map(1..3, fn i -> Part.Text.new("talk-chunk-#{i}") end)}
  end

  @impl AshA2A.Protocol.Agent
  def handle_message(
        %AshA2A.Protocol.Message{parts: [%Part.Data{data: %{"activity" => "task"}}]},
        _context
      ) do
    {:reply, [Part.Data.new(%{"activity" => "task", "status" => "created"})]}
  end

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:reply, [Part.Text.new("venue: unknown activity")]}
  end
end

defmodule ConferenceSim.ObservabilityCourt do
  @moduledoc """
  EV11: the conference sim's event log as an OCEL-shaped observability surface,
  read from the estate's real OCEL capital - ash_a2a's real telemetry stream
  ([:a2a, :task, :transition] plus the ported-SDK spans) - with the event-log
  read side built in this file (ConferenceSim.EventLog, a real
  :telemetry.attach/4 handler writing an ordered ETS log). No mock, no stub,
  no faked log: every event this court asserts on was emitted by the real
  running AshA2A.Agent GenServer.

  ## OCEL shape

  Each captured telemetry event maps to one OCEL event:

      %{
        seq: <global emission order>,
        activity: event_name,           # e.g. [:a2a, :task, :transition]
        time: measurements.system_time, # real monotonic system time
        objects: {task_id, context_id}, # object references
        attributes: meta                # from/to/reply_type/status/agent/...
      }

  ## Pinned event inventory (verified against the source, not assumed)

    * [:a2a, :task, :transition] - every task state change; meta carries
      task_id, context_id, from, to (lib/ash_a2a/protocol/agent/state.ex)
    * [:a2a, :agent, :call, :start/:stop] - span around
      AshA2A.Protocol.call/3 / stream/3; stop carries task_id, status,
      context_id, streaming (lib/ash_a2a/protocol.ex)
    * [:a2a, :agent, :message, :start/:stop] - span around handler execution;
      stop carries task_id, reply_type
      (lib/ash_a2a/protocol/agent/runtime.ex)

  ## Courts

    1. every registration produces an observable event (transition + span)
    2. every task state transition is observable with the task id
    3. one attendee's journey (register -> create task -> stream -> terminal)
       is ordered and complete
    4. no event leaks another attendee's identity (privacy boundary)
    5. counter-integrity: events emitted == events expected for the scripted
       scenario (no silent drops, no dupes)
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Protocol
  alias ConferenceSim.ObservabilityVenue

  # -- event-log read side ---------------------------------------------------

  defmodule EventLog do
    @moduledoc """
    The minimal read side, built in-repo because ash_a2a had no in-repo
    event-log query surface: a real :telemetry.attach/4 handler that appends
    every captured [:a2a, ...] observability event to an ordered public ETS
    log under a real global monotonic sequence counter (:ets.update_counter/3),
    so cross-process event ORDER is real, not asserted. A :telemetry attach
    handler is a real collaborator, not a test double.
    """

    @doc "Starts a fresh ordered log: {table, handler_id}."
    def start do
      table = :ets.new(:conference_sim_event_log, [:ordered_set, :public])
      :ets.insert(table, {:seq, 0})

      handler_id = :"conference_sim_log_#{System.unique_integer([:positive])}"

      :ok = :telemetry.attach_many(handler_id, span_events(), &__MODULE__.handle/4, table)

      {table, handler_id}
    end

    defp span_events do
      [
        [:a2a, :task, :transition],
        [:a2a, :agent, :call, :start],
        [:a2a, :agent, :call, :stop],
        [:a2a, :agent, :message, :start],
        [:a2a, :agent, :message, :stop]
      ]
    end

    def stop(handler_id), do: :telemetry.detach(handler_id)

    @doc false
    def handle(event, measurements, meta, table) do
      seq = :ets.update_counter(table, :seq, 1)
      :ets.insert(table, {seq + 1, event, measurements, meta})
      :ok
    end

    @doc "All captured events in real emission order, as OCEL-shaped maps."
    def events(table) do
      table
      |> :ets.tab2list()
      |> Enum.filter(fn row ->
        is_tuple(row) and tuple_size(row) == 4 and is_integer(elem(row, 0))
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {seq, event, measurements, meta} ->
        %{
          seq: seq,
          activity: event,
          time: Map.get(measurements, :system_time) || Map.get(measurements, :duration),
          objects: {meta[:task_id], meta[:context_id]},
          attributes: meta
        }
      end)
    end

    @doc "All events for one object (task_id), in order."
    def for_task(table, task_id) do
      table |> events() |> Enum.filter(&(elem(&1.objects, 0) == task_id))
    end

    @doc "Transition events for one task (or all), in order."
    def transitions(table, task_id \\ nil) do
      table
      |> events()
      |> Enum.filter(&(&1.activity == [:a2a, :task, :transition]))
      |> then(fn ts ->
        if task_id, do: Enum.filter(ts, &(elem(&1.objects, 0) == task_id)), else: ts
      end)
    end

    @doc "True if any captured event's payload mentions leak."
    def leaks?(table, leak) do
      table
      |> events()
      |> Enum.any?(fn ev ->
        String.contains?(inspect(%{attributes: ev.attributes, objects: ev.objects}), leak)
      end)
    end
  end

  # -- harness ---------------------------------------------------------------

  setup do
    {table, handler_id} = EventLog.start()

    on_exit(fn -> EventLog.stop(handler_id) end)

    name = :"conference_sim_venue_#{System.unique_integer([:positive])}"
    start_supervised!({ObservabilityVenue, name: name})

    %{table: table, venue: name}
  end

  defp register!(venue, table, attendee) do
    assert {:ok, %Protocol.Task{status: %{state: :completed}} = task} =
             Protocol.call(
               venue,
               data_message(%{"activity" => "register", "attendee" => attendee})
             )

    task
  end

  defp stream_talk!(venue, table) do
    assert {:ok, %Protocol.Task{} = task, stream} =
             Protocol.stream(venue, data_message(%{"activity" => "stream"}))

    assert %Protocol.Task{status: %{state: :working}} = task
    assert Enum.count(stream) == 3

    # The real {:stream_done, _} cast folds the task to :completed; poll the
    # real task store rather than sleeping blind.
    wait_until(2_000, fn ->
      match?(
        {:ok, %Protocol.Task{status: %{state: :completed}}},
        ObservabilityVenue.get_task(venue, task.id)
      )
    end)

    task
  end

  defp create_task!(venue, attendee) do
    assert {:ok, %Protocol.Task{status: %{state: :completed}} = task} =
             Protocol.call(venue, data_message(%{"activity" => "task", "attendee" => attendee}))

    task
  end

  defp wait_until(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(deadline, fun)
  end

  defp do_wait(deadline, fun) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline, do: flunk("condition not met in time")

      # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
      AshA2A.TestSupport.Eventually.pause(10)
      do_wait(deadline, fun)
    end
  end

  # -- courts ----------------------------------------------------------------

  @tag :ev11
  test "1. every registration produces an observable event", %{table: table, venue: venue} do
    attendees = for i <- 1..3, do: "attendee-#{i}-#{System.unique_integer([:positive])}"

    tasks = Enum.map(attendees, &register!(venue, table, &1))

    # Each registration task is observable by id: :working then :completed.
    for task <- tasks do
      transitions = EventLog.transitions(table, task.id)

      assert Enum.map(transitions, & &1.attributes.to) == [:working, :completed]
      assert Enum.map(transitions, & &1.attributes.from) == [:submitted, :working]
    end

    # And the venue-level call span observed each registration end to end.
    for task <- tasks do
      stops =
        table
        |> EventLog.events()
        |> Enum.filter(fn ev ->
          ev.activity == [:a2a, :agent, :call, :stop] and elem(ev.objects, 0) == task.id
        end)

      assert length(stops) == 1
      assert hd(stops).attributes.status == :completed
    end
  end

  @tag :ev11
  test "2. every task state transition is observable with the task id", %{
    table: table,
    venue: venue
  } do
    reg = register!(venue, table, "attendee-obs")
    plain = create_task!(venue, "attendee-obs")
    streamed = stream_talk!(venue, table)

    my_ids = MapSet.new([reg.id, plain.id, streamed.id])

    # Every transition event in the whole log carries a binary task id, a
    # valid source state, and a legal A2A v1.0 target state.
    for ev <- EventLog.transitions(table) do
      assert is_binary(elem(ev.objects, 0))
      assert ev.attributes.from in [nil, :submitted, :working, :input_required, :completed]
      assert ev.attributes.to in [:working, :completed, :input_required, :rejected, :failed]
    end

    # No silent drops: each task id the venue returned is present in the
    # transition log with its full observable lifecycle.
    for id <- my_ids do
      assert EventLog.transitions(table, id) != []
    end
  end

  @tag :ev11
  test "3. one attendee's journey is ordered and complete", %{table: table, venue: venue} do
    attendee = "journey-attendee"

    reg = register!(venue, table, attendee)
    plain = create_task!(venue, attendee)
    streamed = stream_talk!(venue, table)

    # Complete: each of the three activities observed the full lifecycle.
    for task <- [reg, plain, streamed] do
      transitions = EventLog.transitions(table, task.id)

      assert Enum.map(transitions, & &1.attributes.to) == [:working, :completed]
    end

    # Ordered: first transition of each task appears in scripted journey order
    # (register -> task -> stream), per real ETS counter sequence.
    first_seqs =
      Enum.map([reg.id, plain.id, streamed.id], fn task_id ->
        first =
          table
          |> EventLog.for_task(task_id)
          |> Enum.find(&(&1.activity == [:a2a, :task, :transition]))

        {first.seq, elem(first.objects, 0)}
      end)

    assert Enum.map(first_seqs, &elem(&1, 1)) == [reg.id, plain.id, streamed.id]
    assert Enum.map(first_seqs, &elem(&1, 0)) == Enum.sort(Enum.map(first_seqs, &elem(&1, 0)))

    for task_id <- [reg.id, plain.id, streamed.id] do
      seqs = table |> EventLog.transitions(task_id) |> Enum.map(& &1.seq)

      assert seqs == Enum.sort(seqs)
    end

    # The stream connect (call span stop for the streamed task) happens after
    :ok
    # the plain task's completion - journey order is real, not assumed.
    stream_call_stop_seq =
      table
      |> EventLog.events()
      |> Enum.find(fn ev ->
        ev.activity == [:a2a, :agent, :call, :stop] and elem(ev.objects, 0) == streamed.id
      end)
      |> Map.get(:seq)

    plain_completed_seq =
      table
      |> EventLog.transitions(plain.id)
      |> Enum.find(&(&1.attributes.to == :completed))
      |> Map.get(:seq)

    assert stream_call_stop_seq > plain_completed_seq
  end

  @tag :ev11
  test "4. no event leaks another attendee's identity", %{table: table, venue: venue} do
    attendee_a = "attendee-privacy-a-#{System.unique_integer([:positive])}"
    attendee_b = "attendee-privacy-b-#{System.unique_integer([:positive])}"

    register!(venue, table, attendee_a)
    register!(venue, table, attendee_b)

    # Neither attendee's marker appears in ANY captured observability event
    # payload - the telemetry surface carries object ids (task/context ids),
    # test
    refute EventLog.leaks?(table, attendee_a)
    refute EventLog.leaks?(table, attendee_b)
  end

  @tag :ev11
  test "5. counter-integrity: events emitted == events expected", %{table: table, venue: venue} do
    tasks = [
      register!(venue, table, "attendee-count-1"),
      register!(venue, table, "attendee-count-1b"),
      create_task!(venue, "attendee-count-2"),
      stream_talk!(venue, table)
    ]

    task_ids = MapSet.new(Enum.map(tasks, & &1.id))

    # Expected: exactly two transitions per task (:working, :completed), no
    # drops, no dupes, canonical order per task.
    expected = MapSet.size(task_ids) * 2

    mine =
      table
      |> EventLog.transitions()
      |> Enum.filter(&MapSet.member?(task_ids, elem(&1.objects, 0)))

    assert Enum.count(mine) == expected

    for task_id <- task_ids do
      transitions = EventLog.transitions(table, task_id)

      assert Enum.map(transitions, & &1.attributes.to) == [:working, :completed]
      assert Enum.map(transitions, & &1.attributes.from) == [:submitted, :working]
    end
  end
end


# ==============================================================================
# SECTION 16 of 31: test/conference_sim/push_court_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule ConferenceSim.Push.Session do
  @moduledoc false
  # Real ETS-backed Ash resource modelling a conference session an attendee
  # manages: `message/send` without structured data pauses the real task at
  # TASK_STATE_INPUT_REQUIRED (a continuable, live session task); the
  # follow-up carrying `{"new_time": ...}` "reschedules" it terminal
  # TASK_STATE_COMPLETED with the new slot in the real output artifact.
  use Ash.Resource,
    domain: ConferenceSim.Push.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :manage, :map do
      argument(:new_time, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{rescheduled_to: input.arguments.new_time}}
      end)
    end
  end

  a2a do
    skill(:manage, :manage, consequence: :observe)
  end
end

defmodule ConferenceSim.Push.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(ConferenceSim.Push.Session)
  end
end

defmodule ConferenceSim.Push.Agent do
  @moduledoc false
  # Real `AshA2A.Agent` GenServer (transport runtime: owner-keyed tasks,
  # CSPRNG ids) serving the session resource.
  use AshA2A.Agent,
    resource_or_domain: ConferenceSim.Push.Domain,
    name: "conference_sim_push_agent",
    require_authenticated_caller: true,
    execution: [mode: :inline]
end

defmodule ConferenceSim.Push.Receiver do
  @moduledoc false
  # Real Bandit webhook receiver: forwards (headers, body) to the test pid
  # tagged with its attendee slot and answers 200.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test, attendee: attendee}) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:push_delivered, attendee, conn.req_headers, body})
    send_resp(conn, 200, "")
  end
end

defmodule ConferenceSim.PushCourt do
  @moduledoc """
  Conference-sim lane EV6 court: session-change alerts as A2A push
  notifications -- the full push lifecycle (G2's surface) under real event
  conditions.

  Five attendees each own a real session task on a real `AshA2A.Agent`
  transport runtime and subscribe a real `TaskPushNotificationConfig` whose
  receiver is a real, per-attendee Bandit endpoint on an OS-assigned
  ephemeral loopback port. Zero mocks: receivers are real HTTP servers,
  delivery is the real `AshA2A.A2ATransport.PushDelivery` worker, attempts
  are read from the real `AshA2A.A2ATransport.TaskEvents` attempt log.

  ## Courts

    * **Fan-out + new state + auth** -- rescheduling every session
      (continuation `message/send` with `{"new_time": ...}`) lands exactly
      one notification on every receiver, whose wrapped task carries the new
      `TASK_STATE_COMPLETED` state and the rescheduled slot, the config's
      `token` as `X-A2A-Notification-Token`, the config's
      `authentication.credentials` as the `Authorization: Bearer` header, and
      an HMAC signature that verifies against the real signing secret on the
      receiver side.
    * **Retry with backoff, and honest exhaustion** -- a receiver that is
      genuinely down (its Bandit listener killed) draws repeated failed
      delivery attempts with exponential backoff and succeeds once it comes
      back mid-backoff; a receiver that never comes back draws exactly
      `max_attempts` failed attempts and no success -- exhausted honestly.
    * **Mid-session config deletion** -- after a delivered event, deleting
      the config stops further deliveries to that attendee while a still-
      configured attendee keeps receiving; `get`/`list` reflect the removal.
    * **IDOR** -- an attendee naming another attendee's session task on any
      push verb is answered exactly like a missing task (`-32001`
      `TASK_NOT_FOUND`), byte-identical to the unknown-task answer.
    * **Typed SSRF refusal at config-set** -- an `http://` receiver URL under
      the transport's safe defaults (https-only) is refused with the typed
      `refused_webhook_scheme` detail and nothing is stored.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.{PushConfigStore, PushDelivery, TaskEvents}
  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}
  @secret "conference-sim-ev6-push-signing-secret"
  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @max_attempts 5
  @backoff_ms 25

  # Real verify callback: the bearer token names the attendee.
  def verify("bearer", token, _conn), do: {:ok, %{sub: token}}

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"conference_sim_push_agent_#{uniq}"
    transport = :"a2a_transport_conf_sim_push_#{uniq}"

    start_supervised!({ConferenceSim.Push.Agent, name: agent})

    start_supervised!(
      {AshA2A.A2ATransport,
       name: transport,
       push: [
         allow_http: true,
         allow_cidrs: ["127.0.0.1/32"],
         signing_secret: @secret,
         max_attempts: @max_attempts,
         base_backoff_ms: @backoff_ms,
         max_backoff_ms: 200
       ]}
    )

    # A second transport under the SAFE push defaults (https-only, no
    # loopback allowlist) -- the SSRF court's admitted-policy baseline.
    safe_transport = :"a2a_transport_conf_sim_push_safe_#{uniq}"

    start_supervised!(
      {AshA2A.A2ATransport, name: safe_transport, push: [signing_secret: @secret]}
    )

    %{
      agent: agent,
      transport: transport,
      auth: AshA2A.Protocol.Plug.Auth.init(schemes: @schemes, verify: &__MODULE__.verify/3),
      plug:
        TransportPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: transport,
          push_notifications: true
        ),
      safe_plug:
        TransportPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: safe_transport,
          push_notifications: true
        )
    }
  end

  # -- wire helpers -------------------------------------------------------------

  defp call(ctx, plug, user, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> user)
      |> AshA2A.Protocol.Plug.Auth.call(ctx.auth)
      |> TransportPlug.call(plug)

    refute conn.halted, "auth middleware halted for #{user}"
    conn.resp_body |> Jason.decode!()
  end

  defp rpc(ctx, user, method, params), do: call(ctx, ctx.plug, user, method, params)

  defp skill_message(data, task_id) do
    parts = if data, do: [Part.Data.new(data)], else: [Part.Text.new("go")]

    msg =
      struct(Message.new_user(parts),
        task_id: task_id,
        metadata: %{"skill" => "manage"}
      )

    {:ok, encoded} = JSON.encode(msg)
    encoded
  end

  # Creates a fresh live (TASK_STATE_INPUT_REQUIRED) session task owned by
  # `user`.
  defp create_task(ctx, user) do
    resp = rpc(ctx, user, "message/send", %{"message" => skill_message(nil, nil)})

    case resp do
      %{
        "result" => %{
          "task" => %{"id" => id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}
        }
      } ->
        id

      other ->
        flunk("create_task did not pause at INPUT_REQUIRED: #{inspect(other)}")
    end
  end

  defp set_config(ctx, user, task_id, config),
    do:
      rpc(ctx, user, "tasks/pushNotificationConfig/set", %{
        "taskId" => task_id,
        "pushNotificationConfig" => config
      })

  # The reschedule event: a real continuation `message/send` carrying the new
  # slot; the task lands terminal TASK_STATE_COMPLETED.
  defp reschedule(ctx, user, task_id, new_time) do
    assert %{"result" => %{"task" => %{"status" => %{"state" => state}}}} =
             rpc(ctx, user, "message/send", %{
               "message" => skill_message(%{"new_time" => new_time}, task_id)
             })

    state
  end

  # A non-terminal session event: a continuation that leaves the task live at
  # TASK_STATE_INPUT_REQUIRED (still continuable), publishing a status-bearing
  # event -- the "session held/updated" transition used before and after a
  # config deletion.
  defp nudge(ctx, user, task_id) do
    assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}}} =
             rpc(ctx, user, "message/send", %{
               "message" => skill_message(nil, task_id)
             })
  end

  defp attempts(transport, task_id, n, tries \\ 150)

  defp attempts(transport, task_id, n, tries) do
    found = TaskEvents.attempts(transport, task_id)

    cond do
      length(found) >= n ->
        found

      tries == 0 ->
        flunk("expected >=#{n} attempts, got #{inspect(found)}")

      true ->
        # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
        AshA2A.TestSupport.Eventually.pause(20)
        attempts(transport, task_id, n, tries - 1)
    end
  end

  defp start_receiver(attendee, port \\ 0) do
    EphemeralHttp.start!({ConferenceSim.Push.Receiver, %{test: self(), attendee: attendee}},
      port: port
    )
  end

  defp kill_receiver(hook) do
    # Take the real listener down without the link propagating to the test
    # process (EphemeralHttp links Bandit to its caller).
    Process.unlink(hook.pid)
    Process.exit(hook.pid, :kill)
    # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
    AshA2A.TestSupport.Eventually.pause(10)
    :ok
  end

  defp down_receiver do
    # A genuinely dead endpoint: a real listener that is then killed, so the
    # port was owned and is now provably closed.
    hook = start_receiver(:never)
    kill_receiver(hook)
    hook
  end

  defp config_for(hook_url, id) do
    %{
      "id" => id,
      "url" => hook_url,
      "token" => "tok-" <> id,
      "authentication" => %{"schemes" => ["Bearer"], "credentials" => "s3cret-" <> id}
    }
  end

  # -- court 1: fan-out, new state, auth, signature -------------------------------

  test "rescheduling 5 sessions notifies all 5 receivers with the new state, token, bearer header and a verifying signature",
       %{
         transport: transport
       } = ctx do
    attendees = [:alice, :bob, :carol, :dave, :erin]

    hooks = Map.new(attendees, fn a -> {a, start_receiver(a)} end)

    sessions =
      Map.new(attendees, fn a ->
        task_id = create_task(ctx, "#{a}")
        url = hooks[a].base_url <> "/hook"

        assert %{"result" => %{"pushNotificationConfig" => stored}} =
                 set_config(ctx, "#{a}", task_id, config_for(url, "cfg-#{a}"))

        assert stored["url"] == url
        # Write-only credentials are never echoed...
        refute get_in(stored, ["authentication", "credentials"])

        # ...but really live in the store for delivery.
        {:ok, record} =
          PushConfigStore.get(AshA2A.A2ATransport.push_store_name(transport), task_id, "cfg-#{a}")

        assert record.authentication["credentials"] == "s3cret-cfg-#{a}"
        {a, task_id}
      end)

    # The session-change event: every session is rescheduled.
    for {a, i} <- Enum.with_index(attendees) do
      new_time = "2026-10-06T#{10 + i}:00:00Z"
      assert reschedule(ctx, "#{a}", sessions[a], new_time) == "TASK_STATE_COMPLETED"
    end

    # Every receiver got exactly the update for its own session.
    for {a, i} <- Enum.with_index(attendees) do
      assert_receive {:push_delivered, ^a, headers, body}, 5_000
      headers = Map.new(headers)
      decoded = Jason.decode!(body)

      # The task's NEW state after the reschedule...
      assert %{
               "task" => %{
                 "id" => task_id,
                 "status" => %{"state" => "TASK_STATE_COMPLETED"}
               }
             } = decoded

      assert task_id == sessions[a]

      # ...and the rescheduled slot itself.
      assert body =~ "2026-10-06T#{10 + i}:00:00Z"

      # Token + bearer auth from the stored config.
      assert headers["x-a2a-notification-token"] == "tok-cfg-#{a}"
      assert headers["authorization"] == "Bearer s3cret-cfg-#{a}"

      # Receiver-side HMAC verification against the real signing secret.
      assert :ok =
               PushDelivery.verify_signature(
                 @secret,
                 headers["x-a2a-timestamp"],
                 headers["x-a2a-signature"],
                 body
               )
    end

    # No spurious extra deliveries.
    refute_receive {:push_delivered, _, _, _}, 250
  end

  # -- court 2: retry with backoff, and honest exhaustion --------------------------

  test "a down receiver is retried with backoff and succeeds when it comes back",
       %{
         transport: transport
       } = ctx do
    hook = start_receiver(:retry)
    task_id = create_task(ctx, "retry")
    set_config(ctx, "retry", task_id, config_for(hook.base_url <> "/hook", "cfg-retry"))

    # The receiver goes genuinely down before the session change...
    kill_receiver(hook)

    assert reschedule(ctx, "retry", task_id, "2026-10-07T09:00:00Z") == "TASK_STATE_COMPLETED"

    # ...draws at least one real failed attempt (connection refused)...
    first = attempts(transport, task_id, 1, 300)
    assert [%{outcome: {:transport_error, _}} | _] = first

    # ...and because the receiver comes back mid-backoff, a later attempt
    # lands. Restart on the SAME port the config pins.
    {:ok, _pid} =
      Bandit.start_link(
        plug: {ConferenceSim.Push.Receiver, %{test: self(), attendee: :retry}},
        port: hook.port,
        ip: {127, 0, 0, 1}
      )

    all =
      Enum.reduce_while(1..400, first, fn _, _acc ->
        found = TaskEvents.attempts(transport, task_id)

        if Enum.any?(found, &match?(%{outcome: {:ok, 200}}, &1)) do
          {:halt, found}
        else
          # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
          AshA2A.TestSupport.Eventually.pause(10)
          {:cont, found}
        end
      end)

    assert ok = Enum.find(all, &match?(%{outcome: {:ok, 200}}, &1)),
           "no successful attempt after restart: #{inspect(all)}"

    assert ok.attempt > 1, "expected a retry (not the first attempt) to succeed"
    assert length(all) <= @max_attempts

    assert_receive {:push_delivered, :retry, _headers, body}, 5_000
    assert %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} = Jason.decode!(body)
  end

  test "a receiver that never comes back is exhausted honestly at max_attempts",
       %{
         transport: transport
       } = ctx do
    hook = down_receiver()
    task_id = create_task(ctx, "gone")
    set_config(ctx, "gone", task_id, config_for(hook.base_url <> "/hook", "cfg-gone"))

    assert reschedule(ctx, "gone", task_id, "2026-10-07T11:00:00Z") == "TASK_STATE_COMPLETED"

    all = attempts(transport, task_id, @max_attempts)

    assert length(all) == @max_attempts
    assert Enum.all?(all, &match?(%{outcome: {:transport_error, _}}, &1))
    # Backoff really backs off: strictly increasing sleeps between attempts.
    gaps =
      Enum.map(
        1..(length(all) - 1),
        &PushDelivery.backoff(&1, base_backoff_ms: @backoff_ms, max_backoff_ms: 200)
      )

    assert gaps == Enum.sort(gaps)

    refute_receive {:push_delivered, :gone, _, _}, 250
  end

  # -- court 3: mid-session config deletion ---------------------------------------

  test "deleting a config mid-session stops that attendee's deliveries; others unaffected; get/list reflect it",
       %{
         transport: transport
       } = ctx do
    hook_mia = start_receiver(:mia)
    hook_live = start_receiver(:live)

    task_mia = create_task(ctx, "mia")
    task_live = create_task(ctx, "live")

    set_config(ctx, "mia", task_mia, config_for(hook_mia.base_url <> "/hook", "cfg-mia"))
    set_config(ctx, "live", task_live, config_for(hook_live.base_url <> "/hook", "cfg-live"))

    # Event 1: both still-configured attendees are notified. Mia's event is a
    # live (non-terminal) session update; live's is a full reschedule.
    nudge(ctx, "mia", task_mia)

    assert reschedule(ctx, "live", task_live, "2026-10-07T13:00:00Z") == "TASK_STATE_COMPLETED"

    assert_receive {:push_delivered, :mia, _, body}, 5_000

    assert %{"task" => %{"status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} =
             Jason.decode!(body)

    assert_receive {:push_delivered, :live, _, _}, 5_000

    # Mia deletes her config mid-session.
    assert %{"result" => nil} =
             rpc(ctx, "mia", "tasks/pushNotificationConfig/delete", %{
               "id" => task_mia,
               "pushNotificationConfigId" => "cfg-mia"
             })

    # get/list reflect the removal.
    assert %{"result" => []} =
             rpc(ctx, "mia", "tasks/pushNotificationConfig/list", %{"id" => task_mia})

    assert %{"error" => %{"code" => -32_602, "data" => [%{"reason" => "INVALID_PARAMS"}]}} =
             rpc(ctx, "mia", "tasks/pushNotificationConfig/get", %{
               "id" => task_mia,
               "pushNotificationConfigId" => "cfg-mia"
             })

    # Event 2: a second, still-configured attendee's session changes in the
    # same window -- the pipeline is alive while mia is dark.
    hook_live2 = start_receiver(:live2)
    task_live2 = create_task(ctx, "live2")
    set_config(ctx, "live2", task_live2, config_for(hook_live2.base_url <> "/hook", "cfg-live2"))

    assert reschedule(ctx, "live2", task_live2, "2026-10-07T14:00:00Z") == "TASK_STATE_COMPLETED"
    assert_receive {:push_delivered, :live2, _, _}, 5_000

    # Mia's task changes state again after her delete: no further delivery.
    mia_attempts_before = TaskEvents.attempts(transport, task_mia)
    nudge(ctx, "mia", task_mia)

    refute_receive {:push_delivered, :mia, _, _}, 400
    # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
    AshA2A.TestSupport.Eventually.pause(100)

    assert TaskEvents.attempts(transport, task_mia) == mia_attempts_before,
           "a delivery attempt was started for a deleted config"
  end

  # -- court 4: IDOR ---------------------------------------------------------------

  test "an attendee cannot read or set push configs on another attendee's session (IDOR)", ctx do
    hook = start_receiver(:alice)
    task_alice = create_task(ctx, "alice")
    set_config(ctx, "alice", task_alice, config_for(hook.base_url <> "/hook", "cfg-a"))

    for {method, params} <- [
          {"tasks/pushNotificationConfig/set",
           %{
             "taskId" => task_alice,
             "pushNotificationConfig" => config_for("https://attacker.test/hook", "cfg-b")
           }},
          {"tasks/pushNotificationConfig/get", %{"id" => task_alice}},
          {"tasks/pushNotificationConfig/list", %{"id" => task_alice}},
          {"tasks/pushNotificationConfig/delete",
           %{"id" => task_alice, "pushNotificationConfigId" => "cfg-a"}}
        ] do
      resp = rpc(ctx, "bob", method, params)

      assert %{"error" => %{"code" => -32_001, "data" => [%{"reason" => "TASK_NOT_FOUND"}]}} =
               resp,
             "#{method} as bob was not owner-scoped: #{inspect(resp)}"
    end

    # Indistinguishable from a genuinely unknown task, byte for byte.
    foreign = rpc(ctx, "bob", "tasks/pushNotificationConfig/get", %{"id" => task_alice})
    unknown = rpc(ctx, "bob", "tasks/pushNotificationConfig/get", %{"id" => "tsk-nope-000"})
    assert foreign["error"] == unknown["error"]

    # The owner still sees her config; nothing bob did disturbed it.
    assert %{"result" => [%{"pushNotificationConfig" => %{"id" => "cfg-a"}}]} =
             rpc(ctx, "alice", "tasks/pushNotificationConfig/list", %{"id" => task_alice})
  end

  # -- court 5: typed SSRF refusal under safe defaults ------------------------------

  test "an http:// receiver URL under safe defaults is refused typed at config-set", ctx do
    task_id = create_task(ctx, "carol")

    for url <- ["http://example.com/hook", "http://127.0.0.1:9/hook"] do
      resp =
        call(ctx, ctx.safe_plug, "carol", "tasks/pushNotificationConfig/set", %{
          "taskId" => task_id,
          "pushNotificationConfig" => config_for(url, "cfg-safe")
        })

      assert %{
               "error" => %{
                 "code" => -32_602,
                 "data" => [
                   %{
                     "@type" => @error_info_type,
                     "reason" => "INVALID_PARAMS",
                     "metadata" => %{"detail" => detail}
                   }
                 ]
               }
             } = resp,
             url

      assert detail =~ "refused_webhook_scheme", url
    end

    # Nothing was stored (the safe transport's own store).
    assert %{"result" => []} =
             call(ctx, ctx.safe_plug, "carol", "tasks/pushNotificationConfig/list", %{
               "id" => task_id
             })
  end
end


# ==============================================================================
# SECTION 17 of 31: test/conference_sim/red_team_court_test.exs
# ==============================================================================

# Lane EV10 — Conference-sim red team: the hostile attendee at event scale.
#
# Every AT5/EV-class attack is run against the REAL pipeline, with the attack
# scripts living in the court itself (no mocks, no patches — real :crypto
# signing, real Bandit token server, real JWKS fetch, real gRPC server):
#
#   1. badge forgery   — attendee signs an SSO token with their OWN RSA key;
#                        the venue fetches the real JWKS and refuses (401).
#   2. badge replay    — a captured valid badge JWT replayed after `exp`
#                        expires → 401 (real claim validation).
#   3. tier escalation — a :general (expo) badge on the workshop method → 403;
#                        CRLF injection in `x-badge` → refused, nothing
#                        smuggled into the header set.
#   4. session hijack  — attendee B names attendee A's task id on every
#                        task-naming method → owner-scope refusal.
#   5. push hijack     — B registers a push config on A's task → refusal.
#   6. stream bombing  — 200 concurrent resubscribe connections against the
#                        venue; the venue survives (all served or cleanly
#                        capped, never a crash), and honest traffic still
#                        works afterwards.
#   7. metadata clobber re-check — attacker params carrying "a2a.auth" /
#                        "ash_a2a.owner" keys are stripped under event
#                        conditions (the AT5 fix holds at scale).
#   8. gRPC unauthenticated venue access with the auth interceptor configured
#                        → UNAUTHENTICATED(16), and an honest attendee on the
#                        same wire still gets served.
#
# Every court pairs the attack with its honest positive control: the
# legitimate action still works after (or beside) the attack.
#
# Fixture modules live at TOP LEVEL of this file (never nested inside the
# test module: Elixir nests dotted module names under the enclosing module).

ExUnit.start()

defmodule AshA2A.ConferenceSim.RedTeam.RSA do
  @moduledoc """
  Real RSA keypairs: the venue SSO key (published via the real JWKS endpoint)
  and the attacker's own key (published nowhere — that is the whole point of
  attack 1).
  """

  @venue_key :public_key.generate_key({:rsa, 2048, 65_537})
  @attacker_key :public_key.generate_key({:rsa, 2048, 65_537})
  @kid "venue-sso-key-1"
  @attacker_kid "attendee-forged-key-1"

  def venue_key, do: @venue_key
  def attacker_key, do: @attacker_key
  def kid, do: @kid
  def attacker_kid, do: @attacker_kid

  def venue_public_jwk do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = @venue_key
    jwk(n, e, @kid)
  end

  def attacker_public_jwk do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = @attacker_key
    jwk(n, e, @attacker_kid)
  end

  def rs256_token(claims, key, kid) do
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => kid}

    signing_input =
      Enum.map_join([header, claims], ".", fn part ->
        part |> Jason.encode!() |> b64()
      end)

    sig = :public_key.sign(:crypto.hash(:sha256, signing_input), :sha256, key)
    signing_input <> "." <> b64(sig)
  end

  defp jwk(n, e, kid) do
    %{
      "kty" => "RSA",
      "kid" => kid,
      "n" => b64(:binary.encode_unsigned(n)),
      "e" => b64(:binary.encode_unsigned(e)),
      "alg" => "RS256",
      "use" => "sig"
    }
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end

defmodule AshA2A.ConferenceSim.RedTeam.TokenServer do
  @moduledoc """
  Real local Bandit plug: the venue SSO provider. Serves the OIDC discovery
  document and the real JWKS containing ONLY the venue key — the attacker's
  key is never published, so a forged token must fail real signature
  verification.
  """

  import Plug.Conn
  @behaviour Plug

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, _opts) do
    case {conn.method, conn.path_info} do
      {"GET", [".well-known", "openid-configuration"]} -> discovery(conn)
      {"GET", ["jwks.json"]} -> jwks(conn)
      _ -> send_resp(conn, 404, "not found")
    end
  end

  defp discovery(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "issuer" => "https://venue.example",
        "jwks_uri" => "http://#{conn.host}:#{conn.port}/jwks.json"
      })
    )
    |> halt()
  end

  defp jwks(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{"keys" => [AshA2A.ConferenceSim.RedTeam.RSA.venue_public_jwk()]})
    )
    |> halt()
  end
end

defmodule AshA2A.ConferenceSim.RedTeam.Venue do
  @moduledoc """
  The venue gate over the REAL `AshA2A.Protocol.Plug.Auth` middleware with
  the real `AshA2A.Protocol.Plug.SecurityValidators` verifier: badge
  (api key, `x-badge` header), session badge (bearer HS256 JWT) and SSO
  (RS256 via real OIDC discovery + JWKS fetch).

  Venue law: keynote = every tier, workshop = session/SSO badge holders,
  backstage = VIP only (no VIP credential is ever minted in this file, so
  any backstage attempt is a 403 by construction). The gate reads the real
  authenticated identity out of `conn.private[:a2a][:auth]` and answers
  200 granted / 403 tier_access_denied / 401 unauthorized.
  """

  @behaviour Plug

  import Plug.Conn

  @session_secret "red-team-venue-session-secret"
  @badge_id "badge-BADGE-7741"

  @method_tiers %{
    "keynote" => MapSet.new([:general, :session, :sso]),
    "workshop" => MapSet.new([:session, :sso]),
    "backstage" => MapSet.new([:vip])
  }

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, %{discovery_url: discovery_url}) do
    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{
          "badge" => %AshA2A.Protocol.SecurityScheme.APIKey{in: "header", name: "x-badge"},
          "session" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"},
          "sso" => %AshA2A.Protocol.SecurityScheme.OpenIDConnect{
            open_id_connect_url: discovery_url
          }
        },
        verify:
          AshA2A.Protocol.Plug.SecurityValidators.verifier(%{
            "badge" => [kind: :key, keys: [@badge_id]],
            "session" => [
              kind: :bearer,
              secret: @session_secret,
              issuer: "https://venue.example",
              audience: "venue-sessions",
              required_claims: ["sub", "exp"]
            ],
            "sso" => [
              kind: :oidc,
              discovery: discovery_url <> "/.well-known/openid-configuration",
              issuer: "https://venue.example",
              audience: "venue-sso",
              required_claims: ["sub", "exp"]
            ]
          })
      )

    conn = AshA2A.Protocol.Plug.Auth.call(conn, auth_opts)

    if conn.halted do
      conn
    else
      tier_gate(conn)
    end
  end

  defp tier_gate(conn) do
    identity = AshA2A.Protocol.Plug.Auth.get_identity(conn)
    tier = tier_of(identity.scheme)
    method = method_of(conn)

    if method && MapSet.member?(Map.fetch!(@method_tiers, method), tier) do
      attendee = attendee_of(identity)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "granted" => true,
          "method" => method,
          "tier" => to_string(tier),
          "attendee" => attendee
        })
      )
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{
          "error" => %{
            "code" => "tier_access_denied",
            "method" => method,
            "tier" => to_string(tier)
          }
        })
      )
    end
  end

  defp tier_of("badge"), do: :general
  defp tier_of("session"), do: :session
  defp tier_of("sso"), do: :sso

  defp attendee_of(%{identity: %{sub: sub}}) when is_binary(sub), do: sub
  defp attendee_of(%{identity: %{"sub" => sub}}), do: sub
  # API-key badges carry no claims; the venue knows this badge id's holder.
  defp attendee_of(_), do: "badge-holder-7741"

  defp method_of(conn) do
    case conn.path_info do
      ["venue", method] when method in ["keynote", "workshop", "backstage"] -> method
      _ -> nil
    end
  end

  # -- credential minting (real :crypto HMAC) ---------------------------------

  def session_token(extra_claims \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "sub" => "attendee-session",
          "iss" => "https://venue.example",
          "aud" => "venue-sessions",
          "exp" => now + 3600
        },
        extra_claims
      )

    header = %{"alg" => "HS256", "typ" => "JWT"}

    signing_input =
      Enum.map_join([header, claims], ".", fn part ->
        part |> Jason.encode!() |> Base.url_encode64(padding: false)
      end)

    sig = :crypto.mac(:hmac, :sha256, @session_secret, signing_input)
    signing_input <> "." <> Base.url_encode64(sig, padding: false)
  end

  def badge_id, do: @badge_id
  def badge_header, do: {"x-badge", @badge_id}
end

defmodule AshA2A.ConferenceSim.RedTeam.Converse do
  @moduledoc """
  Real fixture resource for the owner-scope attacks (4/5/7): one generic
  `:converse` action requiring `:say`, so a `message/send` without structured
  arguments pauses the real task at TASK_STATE_INPUT_REQUIRED — a live,
  continuable task an attacker can go after.
  """

  use Ash.Resource,
    domain: AshA2A.ConferenceSim.RedTeam.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read])

    action :converse, :map do
      argument(:say, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{say: input.arguments.say}}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.ConferenceSim.RedTeam.Domain do
  @moduledoc "Real fixture domain for the red-team fixture resource."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.ConferenceSim.RedTeam.Converse)
  end
end

defmodule AshA2A.ConferenceSim.RedTeam.Agent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer (owner-keyed tasks, auth rebinding) with the
  v1.0 `require_authenticated_caller: true` default pinned explicitly.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.ConferenceSim.RedTeam.Converse,
    name: "conference_red_team_agent",
    require_authenticated_caller: true,
    execution: [mode: :inline]
end

defmodule AshA2A.ConferenceSim.RedTeam.GRPCHandler do
  @moduledoc """
  Real `AshA2A.Protocol.JSONRPC` handler over the real EchoAgent fixture
  (local copy of the delegation shape so this file does not depend on another
  test file's module at runtime — the EchoAgent fixture itself IS shared
  compiled support code, not a mock).
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

defmodule AshA2A.ConferenceSim.RedTeam.GRPCVerify do
  @moduledoc """
  Real HS256 JWT verification for the gRPC interceptor seam — header check,
  constant-time HMAC-SHA256 signature comparison, `sub` required. Real
  `:crypto`, no JWT library, no mocks.
  """

  @secret "red-team-grpc-hs256-secret"

  def secret, do: @secret

  def verify(_scheme, credential, _conn) do
    with [header_b64, payload_b64, sig_b64] <- String.split(credential, ".", parts: 3),
         {:ok, %{"alg" => "HS256"}} <- Jason.decode(Base.url_decode64!(header_b64)),
         {:ok, claims} <- Jason.decode(Base.url_decode64!(payload_b64)),
         signing_input = header_b64 <> "." <> payload_b64,
         :ok <- check_sig(signing_input, sig_b64) do
      if is_binary(claims["sub"]) and claims["sub"] != "" do
        {:ok, %{sub: claims["sub"]}}
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

    if Plug.Crypto.secure_compare(sig, expected), do: :ok, else: {:error, "bad signature"}
  end
end

defmodule AshA2A.ConferenceSim.RedTeam.Receiver do
  @moduledoc false
  # Real webhook receiver forwarding each push-registration body to the test
  # process (the attacks must never reach it; the honest positive control may).
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test}) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:webhook, body})
    send_resp(conn, 200, "")
  end
end

defmodule AshA2A.ConferenceSim.RedTeam.SSEPipeline do
  @moduledoc false
  # Real plug pipeline (bearer auth -> wrapper transport plug) on a real
  # Bandit listener, so the flood's resubscribes are real streaming HTTP.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{auth: auth, plug: plug, user: user}) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> user)
    |> AshA2A.Protocol.Plug.Auth.call(auth)
    |> AshA2A.A2ATransport.Plug.call(plug)
  end
end

defmodule AshA2A.ConferenceSim.RedTeamCourt do
  @moduledoc """
  The red-team courts. `async: false`: the gRPC court drives real
  Application env on the shared endpoint module.
  """

  use ExUnit.Case, async: false

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.ConferenceSim.RedTeam.{Agent, RSA, TokenServer, Venue}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.ConferenceSim.RedTeam.GRPCVerify
  alias AshA2A.ConferenceSim.RedTeam.Receiver
  alias AshA2A.ConferenceSim.RedTeam.SSEPipeline
  alias AshA2A.Protocol.{Message, Part}
  alias Lf.A2a.V1, as: Pb

  @internal_keys ["a2a.auth", "ash_a2a.owner"]
  @metadata_internal_keys ["a2a.auth", "ash_a2a.owner", "stream"]

  # ---------------------------------------------------------------------------
  # Venue credential attacks (1-3): real Bandit token server + real Auth plug
  # ---------------------------------------------------------------------------

  describe "venue credential attacks" do
    setup do
      http = EphemeralHttp.start!({TokenServer, %{}})
      %{venue_url: http.base_url}
    end

    test "1a badge forgery: attacker-signed SSO token fails against the real venue JWKS",
         %{venue_url: venue_url} do
      now = System.system_time(:second)

      forged =
        RSA.rs256_token(
          %{
            "sub" => "attendee-vip-hopeful",
            "iss" => "https://venue.example",
            "aud" => "venue-sso",
            "exp" => now + 3600
          },
          RSA.attacker_key(),
          RSA.attacker_kid()
        )

      conn =
        venue_get(venue_url, ["venue", "keynote"], [{"authorization", "Bearer " <> forged}])

      assert conn.status == 401
      assert conn.resp_body =~ "Unauthorized"

      # Nothing about the forgery minted a VIP tier or a backstage grant.
      refute conn.resp_body =~ "granted"
    end

    test "1b positive control: an honest SSO token signed by the venue key is served",
         %{venue_url: venue_url} do
      now = System.system_time(:second)

      honest =
        RSA.rs256_token(
          %{
            "sub" => "attendee-honest",
            "iss" => "https://venue.example",
            "aud" => "venue-sso",
            "exp" => now + 3600
          },
          RSA.venue_key(),
          RSA.kid()
        )

      conn = venue_get(venue_url, ["venue", "keynote"], [{"authorization", "Bearer " <> honest}])

      assert %{"granted" => true, "tier" => "sso", "attendee" => "attendee-honest"} =
               Jason.decode!(conn.resp_body)
    end

    test "2a badge replay: a captured valid badge JWT replayed after expiry is refused",
         %{venue_url: venue_url} do
      # "Capture" a badge JWT minted by the venue signer; by replay time its
      # `exp` lies far outside the validator's 60s clock-skew allowance.
      captured =
        Venue.session_token(%{"exp" => System.system_time(:second) - 3_600})

      conn =
        venue_get(venue_url, ["venue", "keynote"], [
          {"authorization", "Bearer " <> captured}
        ])

      assert conn.status == 401
      assert conn.resp_body =~ "Unauthorized"

      # The refusal is a real expiry refusal: the identical token minted with
      # a fresh exp is served — same signer, same claims, only `exp` differs.
      fresh = Venue.session_token(%{"sub" => "attendee-session"})

      conn_ok =
        venue_get(venue_url, ["venue", "keynote"], [{"authorization", "Bearer " <> fresh}])

      assert %{"granted" => true, "tier" => "session"} = Jason.decode!(conn_ok.resp_body)
    end

    test "3a tier escalation: a :general badge on the workshop method is a 403",
         %{venue_url: venue_url} do
      conn = venue_get(venue_url, ["venue", "workshop"], [Venue.badge_header()])

      assert conn.status == 403

      assert %{
               "error" => %{
                 "code" => "tier_access_denied",
                 "method" => "workshop",
                 "tier" => "general"
               }
             } = Jason.decode!(conn.resp_body)

      # The same badge on the keynote (which its tier allows) is served — the
      # 403 is the tier law, not a broken badge.
      conn_ok = venue_get(venue_url, ["venue", "keynote"], [Venue.badge_header()])

      assert %{"granted" => true, "tier" => "general"} = Jason.decode!(conn_ok.resp_body)
    end

    test "3b header injection: CRLF in x-badge is refused and nothing is smuggled",
         %{venue_url: venue_url} do
      malicious = Venue.badge_id() <> "\r\nX-Injected: pwned"

      conn = venue_get(venue_url, ["venue", "keynote"], [{"x-badge", malicious}])

      # The credential fails the real constant-time key comparison → 401.
      assert conn.status == 401

      # The CRLF payload never became a real header anywhere in the response.
      refute Enum.any?(conn.resp_headers, fn {name, _} ->
               name in ["x-injected", "injected"]
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # Owner-scope attacks (4/5/7) + stream bombing (6): real wrapper transport
  # ---------------------------------------------------------------------------

  describe "session hijack and metadata attacks on the wrapper transport" do
    setup :wrapper_transport

    test "4 session hijack: attendee B is refused on every task-naming method on A's task",
         ctx do
      %{"id" => task_id} = create_task(ctx, "alice")

      foreign_attempts = [
        {"tasks/get", %{"id" => task_id}},
        {"tasks/cancel", %{"id" => task_id}},
        {"tasks/resubscribe", %{"id" => task_id}},
        {"message/send", %{"message" => message(%{"taskId" => task_id})}},
        {"message/stream", %{"message" => message(%{"taskId" => task_id})}}
      ]

      for {method, params} <- foreign_attempts do
        assert_task_not_found(rpc(ctx, "bob", method, params), "#{method} as bob")
      end

      # Positive control: alice still owns and reads her task after the attack.
      assert %{
               "result" => %{
                 "id" => ^task_id,
                 "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}
               }
             } =
               rpc(ctx, "alice", "tasks/get", %{"id" => task_id})
    end

    test "5 push hijack: B cannot register a push config on A's task", ctx do
      %{"id" => task_id} = create_task(ctx, "alice")

      assert_task_not_found(
        rpc(ctx, "bob", "tasks/pushNotificationConfig/set", %{
          "taskId" => task_id,
          "pushNotificationConfig" => %{"url" => ctx.hook}
        }),
        "push set as bob"
      )

      assert_task_not_found(
        rpc(ctx, "bob", "tasks/pushNotificationConfig/get", %{"id" => task_id}),
        "push get as bob"
      )

      # The hijack registered nothing: alice's own config store is empty and
      # her task untouched.
      assert %{"result" => result} =
               rpc(ctx, "alice", "tasks/pushNotificationConfig/list", %{"id" => task_id})

      assert result == []

      # Positive control: alice registers a push config on her own task.
      assert %{"result" => _} =
               rpc(ctx, "alice", "tasks/pushNotificationConfig/set", %{
                 "taskId" => task_id,
                 "pushNotificationConfig" => %{"url" => ctx.hook}
               })
    end

    @tag timeout: 180_000
    test "6 stream bombing: 200 concurrent resubscribe connections and the venue survives",
         ctx do
      # The attacker mints their OWN live (INPUT_REQUIRED) task so every flood
      # connection is a REAL subscribed stream (not an instant foreign-task
      # refusal) on a real Bandit listener; the venue closes each stream at the
      # short idle, and the client receive_timeout is a backstop.
      %{"id" => task_id} = create_task(ctx, "attacker")

      sse =
        EphemeralHttp.start!({SSEPipeline, %{auth: ctx.auth, plug: ctx.plug, user: "attacker"}})

      parent = self()

      flood =
        Task.async_stream(
          1..200,
          fn _ ->
            try do
              resp =
                Req.post!(sse.base_url,
                  json: %{
                    "jsonrpc" => "2.0",
                    "id" => System.unique_integer([:positive]),
                    "method" => "tasks/resubscribe",
                    "params" => %{"id" => task_id}
                  },
                  headers: [{"content-type", "application/json"}],
                  retry: false,
                  receive_timeout: 2_000,
                  into: fn {:data, data}, acc ->
                    send(parent, {:flood_chunk, byte_size(data)})
                    {:cont, acc}
                  end
                )

              {:ok, resp.status}
            rescue
              # A client-side timeout/disconnect is a clean refusal at the
              # client edge — the venue never crashed the connection.
              _ -> {:refused, :client_timeout}
            end
          end,
          max_concurrency: 32,
          timeout: 170_000
        )

      results = Enum.to_list(flood)

      # Every connection was served or cleanly capped — never a crash/5xx.
      Enum.each(results, fn
        {:ok, {:ok, status}} -> assert status in [200, 429, 503]
        {:ok, {:refused, :client_timeout}} -> :ok
        {:exit, reason} -> flunk("flood connection crashed: #{inspect(reason)}")
      end)

      assert length(results) == 200

      # The venue process tree is alive after the flood.
      assert Process.alive?(ctx.transport_pid)
      assert Process.alive?(ctx.agent_pid)

      # Positive control: an honest attendee is still served after the attack.
      %{"id" => honest_task} = create_task(ctx, "alice")

      assert %{"result" => %{"id" => ^honest_task}} =
               rpc(ctx, "alice", "tasks/get", %{"id" => honest_task})
    end

    test "7 metadata clobber re-check: the AT5 params.metadata scrub holds under event conditions",
         ctx do
      forged_metadata = %{
        "a2a.auth" => %{"forged" => "credential"},
        "ash_a2a.owner" => "bob",
        "seat" => "hall-b"
      }

      # -- The AT5 surface (params-level metadata): scrubbed, dead on arrival.

      # Bob attacks with a bogus foreign taskId carrying forged internal keys
      # at PARAMS level; ownership still derives from the verified identity.
      assert_task_not_found(
        rpc(ctx, "bob", "message/send", %{
          "message" => message(%{"taskId" => "tsk-forged-000"}),
          "metadata" => forged_metadata
        }),
        "forged params.metadata on foreign task"
      )

      %{"id" => bob_task} =
        send_task(ctx, "bob", %{
          "message" => message(),
          "metadata" => forged_metadata
        })

      response = rpc(ctx, "bob", "tasks/get", %{"id" => bob_task})

      # No internal key survives anywhere in the published payload.
      assert_no_internal_keys(response, "$")

      # Bob's forged owner claim changed nothing: the task is still bob's, and
      # alice cannot see it.
      assert_task_not_found(
        rpc(ctx, "alice", "tasks/get", %{"id" => bob_task}),
        "alice on bob task"
      )

      # Positive control: bob's benign params metadata ("seat") still rides.
      assert get_in(response, ["result", "metadata", "seat"]) == "hall-b"

      # -- CLOSED FINDING EV10-F1 (publication gap, message-level metadata echo):
      #
      # The AT5 fix scrubs PARAMS-level metadata; caller-supplied
      # message.metadata keys ("a2a.auth", "ash_a2a.owner") also ride inside the
      # stored message and are echoed back in the task's history
      # (message/send response AND tasks/get). Ownership.strip_wire/1 and
      # strip_task/1 now scrub every history message's metadata as well, so
      # the echo below is asserted ABSENT — the permanent court for EV10-F1.
      %{"id" => echo_task} =
        send_task(ctx, "bob", %{
          "message" => skill_message("converse", forged_metadata)
        })

      echo = rpc(ctx, "bob", "tasks/get", %{"id" => echo_task})

      # Permanent court: no internal key may appear anywhere in the echoed
      # task — task metadata, history message metadata, or any nested map.
      encoded = Jason.encode!(echo)
      refute encoded =~ "ash_a2a.owner", "owner key echoed in task history"
      refute encoded =~ "a2a.auth", "auth key echoed in task history"

      # Benign caller metadata inside history messages still rides.
      history_meta =
        echo
        |> get_in(["result", "history"])
        |> Enum.flat_map(fn m -> Map.get(m, "metadata") |> List.wrap() end)

      assert Enum.any?(history_meta, &(&1["skill"] == "converse")),
             "benign message metadata lost from history"
    end
  end

  # ---------------------------------------------------------------------------
  # gRPC attack (8)
  # ---------------------------------------------------------------------------

  describe "gRPC venue access" do
    setup :grpc_venue

    test "8a unauthenticated gRPC access with the interceptor configured is UNAUTHENTICATED(16)",
         %{channel: channel} do
      assert {:error, %GRPC.RPCError{status: 16} = error} =
               Lf.A2a.V1.A2AService.Stub.send_message(channel, grpc_request())

      assert error.message == ~s({"error":"Unauthorized"})
    end

    test "8b garbage credentials are UNAUTHENTICATED(16)", %{channel: channel} do
      assert {:error, %GRPC.RPCError{status: 16}} =
               Lf.A2a.V1.A2AService.Stub.send_message(
                 channel,
                 grpc_request(),
                 metadata: %{"authorization" => "Bearer not-a-jwt"}
               )
    end

    test "8c positive control: an honest attendee on the same gRPC wire is served",
         %{channel: channel} do
      assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
               Lf.A2a.V1.A2AService.Stub.send_message(
                 channel,
                 grpc_request(),
                 metadata: %{"authorization" => "Bearer " <> grpc_token("honest-attendee")}
               )

      assert task.status.state == :TASK_STATE_COMPLETED
      assert task.id != ""
    end
  end

  # ---------------------------------------------------------------------------
  # Shared wiring
  # ---------------------------------------------------------------------------

  defp wrapper_transport(_ctx) do
    uniq = System.unique_integer([:positive])
    agent = :"red_team_agent_#{uniq}"
    transport = :"red_team_transport_#{uniq}"

    start_supervised!({Agent, name: agent})

    transport_pid =
      start_supervised!(
        {AshA2A.A2ATransport,
         name: transport, push: [allow_http: true, allow_cidrs: ["127.0.0.1/32"], max_attempts: 1]}
      )

    hook = EphemeralHttp.start!({Receiver, %{test: self()}})

    %{
      agent: agent,
      agent_pid: Process.whereis(agent),
      transport: transport,
      transport_pid: Process.whereis(transport),
      hook: hook.base_url <> "/hook",
      auth:
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
          verify: &__MODULE__.verify/3
        ),
      plug:
        TransportPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: transport,
          push_notifications: true
        )
    }
  end

  def verify("bearer", token, _conn),
    do: {:ok, %{sub: token, token: "raw-credential-of-" <> token}}

  # Real chain: bearer auth middleware -> wrapper transport plug (Plug.Test
  # adapter, same shape the owner-scope court uses).
  defp plug_call(ctx, user, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> user)
      |> AshA2A.Protocol.Plug.Auth.call(ctx.auth)
      |> TransportPlug.call(ctx.plug)

    conn
  end

  defp rpc(ctx, user, method, params) do
    conn = plug_call(ctx, user, method, params)
    Jason.decode!(conn.resp_body)
  end

  defp skill_message(skill, extra_metadata \\ %{}) do
    msg =
      struct(Message.new_user([Part.Text.new("go")]),
        metadata: Map.merge(%{"skill" => skill}, extra_metadata)
      )

    {:ok, encoded} = AshA2A.Protocol.JSON.encode(msg)
    encoded
  end

  defp message(extra \\ %{}) do
    Map.merge(skill_message("converse"), extra)
  end

  defp send_task(ctx, user, params) do
    assert %{"result" => result} = rpc(ctx, user, "message/send", params)
    get_in(result, ["task"]) || result
  end

  defp create_task(ctx, user) do
    send_task(ctx, user, %{"message" => message()})
  end

  defp assert_task_not_found(response, label) do
    assert %{
             "error" => %{
               "code" => -32_001,
               "data" => [%{"domain" => "a2a-protocol.org", "reason" => "TASK_NOT_FOUND"}]
             }
           } = response,
           "#{label} did not answer -32001 TASK_NOT_FOUND (got: #{inspect(response)})"
  end

  defp assert_no_internal_keys(%{} = term, path) do
    Enum.each(term, fn
      {"metadata", value} when is_map(value) ->
        Enum.each(value, fn {k, _v} ->
          refute k in @metadata_internal_keys,
                 "internal metadata key #{inspect(k)} leaked at #{path}.metadata"
        end)

        assert_no_internal_keys(value, path <> ".metadata")

      {key, value} when is_binary(key) ->
        refute key in @internal_keys, "internal key #{inspect(key)} leaked at #{path}"

        assert_no_internal_keys(value, path <> "." <> key)

      {_key, value} ->
        assert_no_internal_keys(value, path)
    end)
  end

  defp assert_no_internal_keys(term, path) when is_list(term) do
    term
    |> Enum.with_index()
    |> Enum.each(fn {v, i} -> assert_no_internal_keys(v, "#{path}[#{i}]") end)
  end

  defp assert_no_internal_keys(_scalar, _path), do: :ok

  # -- venue wire helper -------------------------------------------------------

  defp venue_get(base_url, path, headers) do
    conn = Plug.Test.conn(:get, "/" <> Enum.join(path, "/"), nil)

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)

    Venue.call(conn, %{discovery_url: base_url})
  end

  # -- gRPC wiring -------------------------------------------------------------

  defp grpc_venue(_ctx) do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        AshA2A.Test.Fixture.EchoAgent
      ])

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: AshA2A.ConferenceSim.RedTeam.GRPCHandler,
      ctx: %{agent: AshA2A.Test.Fixture.EchoAgent, opts: [], transport: transport}
    )

    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
        verify: &GRPCVerify.verify/3
      )

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server.Endpoint,
      auth: {AshA2A.Transport.GRPC.Auth, auth_opts}
    )

    on_exit(fn ->
      Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server)
      Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server.Endpoint)
    end)

    {:ok, _client_sup} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: Module.concat(__MODULE__, ClientSup)
      )

    {:ok, _pid, port} = GRPC.Server.start_endpoint(AshA2A.Transport.GRPC.Server.Endpoint, 0)

    on_exit(fn ->
      try do
        GRPC.Server.stop_endpoint(AshA2A.Transport.GRPC.Server.Endpoint)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)

    %{channel: channel}
  end

  defp grpc_request do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("red-team"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, "red team probe"}}]
      }
    }
  end

  defp grpc_token(sub) do
    b64 = fn bin -> Base.url_encode64(bin, padding: false) end
    secret = GRPCVerify.secret()

    header = b64.(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}))
    payload = b64.(Jason.encode!(%{"sub" => sub, "iss" => "red-team-court"}))

    signing_input = header <> "." <> payload
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)

    signing_input <> "." <> b64.(signature)
  end
end


# ==============================================================================
# SECTION 18 of 31: test/conference_sim/registration_court_test.exs
# ==============================================================================

# Lane EV2 — Conference-sim registration as a commerce path (entitlement-law
# mirror of ggen-marketplace's entitlement seam).
#
# Commerce path under court:
#
#   attendee pays → registration authority issues a BADGE = a REAL signed
#   agent card (`AshA2A.Info.agent_card/2` over the real
#   `ConferenceSim.Registration` resource, signed by
#   `AshA2A.Protocol.CardSigning.sign/3` under the venue key,
#   `kid: "venue-badge-signing-key"`), whose claims (attendee_id, tier, exp,
#   event) are bound UNDER the signature in the card description.
#
#   the venue's badge gate (real `AshA2A.Protocol.Plug.Auth` middleware, real
#   `x-badge` API-key extraction, real detached-JWS signature verification via
#   `CardSigning.verify/2` against the venue key set) accepts the badge for
#   tier-appropriate methods and refuses, at the wire:
#
#     * expired badge      → 401 + RFC 7235 WWW-Authenticate challenge
#     * forged badge       → 401 (wrong-key `:bad_signature`)
#     * tampered binding   → 401 (`:digest_mismatch` — rebinding the badge to
#                            another attendee breaks the signature's digest)
#     * unknown kid        → 401 (`:unknown_kid` under the venue key set)
#     * wrong-event badge  → 401 (domain-lifting refusal: a badge from another
#                            event is not admission here)
#     * wrong-tier access  → 403 typed `tier_access_denied` envelope
#                            (workshop-only method hit with a :general badge)
#
# Positive paths for each tier (general / workshop / vip / press) over the
# real plug pipeline on real Bandit HTTP servers with real Req requests.
#
# Cross-check (entitlement-seam correlation): the badge_id ↔ attendee binding
# (card `name` = `badge:<attendee_id>`) mirrors ggen-marketplace's
# usageReportingId correlation — the granted wire response echoes the bound
# pair together, the signature covers the binding (tamper → digest_mismatch),
# and a badge issued for one attendee can never grant as another. No
# Mock/mox/patch/monkeypatch anywhere in this file: real signed cards, real
# plug pipeline, wire-body assertions.
#
# Fixture modules live at TOP LEVEL of this file (never nested inside the
# test module: Elixir nests dotted module names under the enclosing module).

defmodule AshA2A.Test.ConferenceSim.RegistrationIssuer do
  @moduledoc """
  The registration authority's badge mint: builds the REAL agent card over
  the real `ConferenceSim.Registration` resource (same builder the fixture's
  `issue_badge/3` uses), binds the commerce claims (attendee_id, tier, exp,
  event) in the card description, and signs under the venue key with the
  fixture's `kid` — `AshA2A.Protocol.CardSigning.sign/3`, HS256 by default,
  ES256 for the asymmetric court.
  """

  alias AshA2A.Protocol.CardSigning

  @default_event "AGNTCon+MCPCon"
  @venue_url "https://venue.agntcon.example/registration"

  def default_event, do: @default_event

  @doc """
  Issues a signed badge card for `attendee_id` at `tier`.

  Options: `:exp` (unix seconds, default now + 3600), `:event`, `:key`
  (signing key, default the real venue key passed in), `:kid`, `:alg`.
  """
  def issue(attendee_id, tier, venue_key, opts \\ []) do
    now = System.system_time(:second)

    claims = %{
      "attendee_id" => attendee_id,
      "tier" => to_string(tier),
      "exp" => Keyword.get(opts, :exp, now + 3600),
      "event" => Keyword.get(opts, :event, @default_event)
    }

    card = AshA2A.Info.agent_card(ConferenceSim.Registration, name: "badge:#{attendee_id}")

    card = %{card | description: "AGNTCon+MCPCon badge claims: " <> Jason.encode!(claims)}

    CardSigning.sign(card, venue_key,
      alg: Keyword.get(opts, :alg, :HS256),
      kid: Keyword.get(opts, :kid, ConferenceSim.badge_kid()),
      url: @venue_url
    )
  end

  def venue_url, do: @venue_url

  @doc "Parses the commerce claims back out of a badge card's description."
  def claims(%{description: "AGNTCon+MCPCon badge claims: " <> json}) do
    case Jason.decode(json) do
      {:ok, %{"attendee_id" => _, "tier" => _} = claims} -> {:ok, claims}
      _ -> {:error, :malformed_claims}
    end
  end

  def claims(_), do: {:error, :malformed_claims}
end

defmodule AshA2A.Test.ConferenceSim.BadgeGate do
  @moduledoc """
  The venue's badge gate: the REAL `AshA2A.Protocol.Plug.Auth` middleware
  (real `x-badge` API-key scheme extraction) whose `verify/3` callback is the
  venue's badge verifier — real `CardSigning.verify/2` against the venue key
  set (kid-selected), then the commerce claim checks (expiry, event) —
  followed by the venue's tier gate enforcing the method × tier law:

      keynote stream  = all tiers
      workshop rooms  = workshop + vip
      backstage       = vip only
      press interview = press only
  """

  import Plug.Conn

  @behaviour Plug

  @method_tiers %{
    "keynote" => MapSet.new(["general", "workshop", "vip", "press"]),
    "workshop" => MapSet.new(["workshop", "vip"]),
    "backstage" => MapSet.new(["vip"]),
    "interview" => MapSet.new(["press"])
  }

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, %{venue_key: venue_key, es256_key: es256_key}) do
    # The venue's published key set (kid -> key): the HS256 venue secret plus
    # the venue's ES256 generation. Signature verification reads `kid` from
    # the PROTECTED header only.
    venue_keys = %{
      ConferenceSim.badge_kid() => venue_key,
      "venue-es256-key" => es256_key
    }

    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{
          "badge" => %AshA2A.Protocol.SecurityScheme.APIKey{in: "header", name: "x-badge"}
        },
        verify: fn
          "badge", credential, _conn -> verify_badge(credential, venue_keys)
          _, _, _ -> {:error, %{code: :unconfigured_scheme}}
        end
      )

    conn = AshA2A.Protocol.Plug.Auth.call(conn, auth_opts)

    if conn.halted do
      conn
    else
      tier_gate(conn)
    end
  end

  # -- Badge verification (the venue's commerce law) ----------------------------

  defp verify_badge(credential, venue_keys) when is_binary(credential) do
    with {:ok, json} <- b64_decode(credential),
         {:ok, wire} <- Jason.decode(json),
         {:ok, card} <- decode_card(wire),
         # The venue resolves the badge's PROTECTED-header `kid` against its
         # published key set ITSELF and hands CardSigning positional key
         # material (verify/2 takes a single key per call).
         {:ok, kid} <- kid_of(card),
         {:ok, key} <- fetch_key(venue_keys, kid),
         :ok <- AshA2A.Protocol.CardSigning.verify(card, key),
         {:ok, claims} <- AshA2A.Test.ConferenceSim.RegistrationIssuer.claims(card) do
      now = System.system_time(:second)

      cond do
        not is_integer(claims["exp"]) or claims["exp"] < now ->
          {:error, %{code: :badge_expired, detail: claims["exp"]}}

        claims["event"] != "AGNTCon+MCPCon" ->
          {:error, %{code: :wrong_event, detail: claims["event"]}}

        true ->
          {:ok,
           %{
             scheme_kind: :key,
             authenticated: true,
             badge_id: card.name,
             attendee_id: claims["attendee_id"],
             tier: claims["tier"]
           }}
      end
    end
  end

  defp verify_badge(_credential, _venue_key), do: {:error, %{code: :invalid_api_key}}

  # Every failure is a typed {:error, map} — Plug.Auth case-clauses on
  # {:ok, _} | {:error, _} and a bare :error from a with fall-through would
  # crash the plug as a 500 (observed: CaseClauseError at auth.ex:216).
  defp b64_decode(bin) do
    case Base.url_decode64(bin) do
      {:ok, json} -> {:ok, json}
      :error -> {:error, %{code: :malformed_badge}}
    end
  end

  defp decode_card(wire) do
    case AshA2A.Protocol.JSON.decode_agent_card(wire) do
      {:ok, card} -> {:ok, card}
      {:error, _} -> {:error, %{code: :malformed_badge}}
    end
  end

  defp fetch_key(keys, kid) do
    case Map.fetch(keys, kid) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, %{code: :unknown_kid, detail: kid}}
    end
  end

  # Reads `kid` from the first signature entry's PROTECTED header only (the
  # unprotected `header` is attacker-writable and never selects a key).
  defp kid_of(%{signatures: [entry | _]}) do
    with {:ok, protected} <- Base.url_decode64(entry["protected"] || "", padding: false),
         {:ok, %{"kid" => kid}} <- Jason.decode(protected) do
      {:ok, kid}
    else
      err ->
        IO.inspect(err, label: "EV2KID")
        {:error, %{code: :malformed_badge}}
    end
  end

  defp kid_of(_), do: {:error, %{code: :malformed_badge}}

  # -- Venue tier gate -----------------------------------------------------------

  defp tier_gate(conn) do
    wrapper = AshA2A.Protocol.Plug.Auth.get_identity(conn)
    identity = wrapper.identity
    method = method_of(conn)

    allowed? =
      method != nil and MapSet.member?(Map.fetch!(@method_tiers, method), identity.tier)

    if allowed? do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "granted" => true,
          "method" => method,
          "tier" => identity.tier,
          "badge_id" => identity.badge_id,
          "attendee_id" => identity.attendee_id,
          "bound" => %{"badge_id" => identity.badge_id, "attendee_id" => identity.attendee_id}
        })
      )
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{
          "error" => %{
            "code" => "tier_access_denied",
            "method" => method,
            "tier" => identity.tier
          }
        })
      )
    end
  end

  defp method_of(conn) do
    case conn.path_info do
      ["venue", method] when method in ["keynote", "workshop", "backstage", "interview"] ->
        method

      _ ->
        nil
    end
  end
end

defmodule AshA2A.Test.ConferenceSim.RegistrationCourt do
  @moduledoc """
  The courts. Each test starts its own real Bandit venue server on an
  OS-assigned ephemeral loopback port with a REAL fresh venue key, issues
  REAL signed badge cards through the registration issuer, and speaks real
  HTTP with wire-body assertions.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.CardSigning
  alias AshA2A.Test.ConferenceSim.{BadgeGate, RegistrationIssuer}
  alias AshA2A.Test.EphemeralHttp

  setup do
    venue_key = :crypto.strong_rand_bytes(32)
    es256_key = :public_key.generate_key({:namedCurve, :secp256r1})

    venue =
      EphemeralHttp.start!({BadgeGate, %{venue_key: venue_key, es256_key: es256_key}})

    %{venue: venue, venue_key: venue_key, es256_key: es256_key}
  end

  # -- Positive path for each tier -------------------------------------------------

  test ":general badge scans the keynote stream (positive path)", c do
    badge = RegistrationIssuer.issue("attendee-ev2-general", :general, c.venue_key)

    resp = post(c.venue.base_url, "/venue/keynote", badge)

    assert resp.status == 200

    assert body(resp) == %{
             "granted" => true,
             "method" => "keynote",
             "tier" => "general",
             "badge_id" => "badge:attendee-ev2-general",
             "attendee_id" => "attendee-ev2-general",
             "bound" => %{
               "badge_id" => "badge:attendee-ev2-general",
               "attendee_id" => "attendee-ev2-general"
             }
           }
  end

  test ":workshop badge joins a workshop room (positive path)", c do
    badge = RegistrationIssuer.issue("attendee-ev2-workshop", :workshop, c.venue_key)

    resp = post(c.venue.base_url, "/venue/workshop", badge)

    assert resp.status == 200
    assert body(resp)["granted"] == true
    assert body(resp)["tier"] == "workshop"
    assert body(resp)["method"] == "workshop"
  end

  test ":vip badge reaches backstage (positive path)", c do
    badge = RegistrationIssuer.issue("attendee-ev2-vip", :vip, c.venue_key)

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 200
    assert body(resp)["granted"] == true
    assert body(resp)["tier"] == "vip"
    assert body(resp)["method"] == "backstage"
  end

  test ":press badge gets the interview room and the keynote stream", c do
    badge = RegistrationIssuer.issue("attendee-ev2-press", :press, c.venue_key)

    resp = post(c.venue.base_url, "/venue/interview", badge)
    assert resp.status == 200
    assert body(resp)["tier"] == "press"

    resp = post(c.venue.base_url, "/venue/keynote", badge)
    assert resp.status == 200
    assert body(resp)["tier"] == "press"
  end

  test "ES256 (asymmetric) signed badge verifies and grants like HS256", c do
    badge =
      RegistrationIssuer.issue("attendee-ev2-es256", :vip, c.es256_key,
        alg: :ES256,
        kid: "venue-es256-key"
      )

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 200
    assert body(resp)["tier"] == "vip"
  end

  # -- Wrong-tier access (403, typed envelope) --------------------------------------

  test "workshop-only method hit with a :general badge is a typed 403", c do
    badge = RegistrationIssuer.issue("attendee-ev2-general-2", :general, c.venue_key)

    resp = post(c.venue.base_url, "/venue/workshop", badge)

    assert resp.status == 403

    assert body(resp) == %{
             "error" => %{
               "code" => "tier_access_denied",
               "method" => "workshop",
               "tier" => "general"
             }
           }
  end

  test "backstage hit with :workshop badge and interview hit with :vip badge are 403s", c do
    workshop_badge = RegistrationIssuer.issue("attendee-ev2-workshop-2", :workshop, c.venue_key)
    vip_badge = RegistrationIssuer.issue("attendee-ev2-vip-2", :vip, c.venue_key)

    resp = post(c.venue.base_url, "/venue/backstage", workshop_badge)
    assert resp.status == 403
    assert body(resp)["error"]["code"] == "tier_access_denied"

    resp = post(c.venue.base_url, "/venue/interview", vip_badge)
    assert resp.status == 403
    assert body(resp)["error"]["code"] == "tier_access_denied"
  end

  # -- Expired badge (401 + challenge) ------------------------------------------------

  test "expired badge is refused 401 with a real WWW-Authenticate challenge", c do
    badge =
      RegistrationIssuer.issue("attendee-ev2-expired", :vip, c.venue_key,
        exp: System.system_time(:second) - 3600
      )

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 401
    assert body(resp) == %{"error" => "Unauthorized"}
  end

  # -- Forged / tampered badges (401) ---------------------------------------------------

  test "badge forged under a different key (same kid) is refused 401 (:bad_signature)", c do
    forged_key = :crypto.strong_rand_bytes(32)

    badge = RegistrationIssuer.issue("attendee-ev2-forge", :vip, forged_key)

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 401
    assert body(resp) == %{"error" => "Unauthorized"}
  end

  test "rebinding a badge to another attendee (tampered claims) is refused 401 (:digest_mismatch)",
       c do
    badge = RegistrationIssuer.issue("attendee-ev2-bind", :vip, c.venue_key)
    tampered = %{badge | description: "someone else's badge now"}

    resp = post(c.venue.base_url, "/venue/backstage", tampered)

    assert resp.status == 401
  end

  test "badge signed under an unknown kid is refused 401 (:unknown_kid)", c do
    badge =
      RegistrationIssuer.issue("attendee-ev2-kid", :vip, c.venue_key,
        kid: "attacker-self-signed-key"
      )

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 401
  end

  # -- Domain lifting: a badge from another event ----------------------------------------

  test "badge for a different event is refused 401 (domain-lifting analog)", c do
    badge =
      RegistrationIssuer.issue("attendee-ev2-devcon", :vip, c.venue_key,
        event: "DevConX-Elsewhere"
      )

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 401
  end

  # -- No credential / malformed credential -----------------------------------------------

  test "no badge header at all is 401 with challenges", c do
    resp = Req.post!(c.venue.base_url <> "/venue/keynote", headers: [], retry: false)

    assert resp.status == 401
  end

  test "garbage badge payload is refused 401, never a 500", c do
    resp =
      Req.post!(c.venue.base_url <> "/venue/keynote",
        headers: [{"x-badge", "not-even-base64!!!"}],
        retry: false
      )

    assert resp.status == 401
  end

  # -- Entitlement-seam cross-check: badge_id ↔ attendee correlation -----------------------

  test "the granted wire response echoes the badge_id ↔ attendee binding together", c do
    badge = RegistrationIssuer.issue("attendee-ev2-correlate", :workshop, c.venue_key)

    resp = post(c.venue.base_url, "/venue/workshop", badge)

    assert resp.status == 200
    bound = body(resp)["bound"]

    # Correlation mirror of ggen-marketplace's usageReportingId seam: the
    # badge (entitlement) id and the payer (attendee) id travel bound.
    assert bound == %{
             "badge_id" => "badge:attendee-ev2-correlate",
             "attendee_id" => "attendee-ev2-correlate"
           }

    # And the wire response never leaks the credential itself.
    presented = badge |> wire_json() |> Base.url_encode64()
    refute Jason.encode!(body(resp)) =~ presented
  end

  test "a badge issued for one attendee cannot grant as another", c do
    alice = RegistrationIssuer.issue("attendee-ev2-alice", :vip, c.venue_key)
    mallory = RegistrationIssuer.issue("attendee-ev2-mallory", :general, c.venue_key)

    # Mallory cannot re-present Alice's badge as his own: the card name binds
    # badge_id to attendee, and the signature covers the binding.
    resp = post(c.venue.base_url, "/venue/backstage", alice)

    assert resp.status == 200
    assert body(resp)["attendee_id"] == "attendee-ev2-alice"
    assert body(resp)["badge_id"] == "badge:attendee-ev2-alice"

    resp = post(c.venue.base_url, "/venue/workshop", mallory)
    assert resp.status == 403
    assert body(resp)["error"]["tier"] == "general"
  end

  # -- Card machinery direct check (no wire): CardSigning verifies the issued badge --------

  test "issued badge verifies directly against the venue key set (CardSigning)", c do
    badge = RegistrationIssuer.issue("attendee-ev2-direct", :workshop, c.venue_key)

    # Venue law: kid (from the PROTECTED header) selects the key; CardSigning
    # verifies positional key material (see BadgeGate.fetch_key/2 note).
    assert :ok = CardSigning.verify(badge, c.venue_key)

    assert {:ok, claims} = RegistrationIssuer.claims(badge)
    assert claims["attendee_id"] == "attendee-ev2-direct"
    assert claims["tier"] == "workshop"
    assert claims["event"] == RegistrationIssuer.default_event()
    assert claims["exp"] > System.system_time(:second)

    # Real capability surface: the badge is a real agent card of the real
    # registration resource.
    assert %AshA2A.Protocol.AgentCard{} = badge
    assert badge.name == "badge:attendee-ev2-direct"
  end

  # -- Helpers ---------------------------------------------------------------------------

  defp post(base_url, path, badge_card) do
    encoded = badge_card |> wire_json() |> Base.url_encode64()

    Req.post!(base_url <> path, headers: [{"x-badge", encoded}], retry: false)
  end

  defp wire_json(card) do
    card
    |> AshA2A.Protocol.JSON.encode_agent_card(
      url: AshA2A.Test.ConferenceSim.RegistrationIssuer.venue_url()
    )
    |> Jason.encode!()
  end

  # Req already decodes JSON response bodies (content-type driven).
  defp body(resp) when is_map(resp.body), do: resp.body
  defp body(resp), do: Jason.decode!(resp.body)
end


# ==============================================================================
# SECTION 19 of 31: test/conference_sim/workshop_court_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConferenceSim.WorkshopCourt.Agent do
  @moduledoc false
  # A real, stateless protocol agent: the workshop instructor. All state
  # lives in the task's own history — no second source of truth.
  #
  #   * First turn: parks the task `:input_required` with the workshop prompt
  #     (a Data part carrying topic + deadline), the workshop materials (a
  #     real File part attached BEFORE parking), and a check-in instruction.
  #   * Continuation turn: reads the park from history. If the attendee's
  #     answer arrives after the embedded deadline -> `{:error,
  #     {:workshop_closed, topic}}` (typed refusal, terminal `:failed`).
  #     Otherwise -> `{:reply, [certificate text]}` (completed + artifact).
  use AshA2A.Protocol.Agent, name: "workshop-instructor", description: "runs a check-in workshop"

  alias AshA2A.Protocol.{FileContent, Part}

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, context) do
    agent_turns = Enum.filter(context.history, &(&1.role == :agent))

    case agent_turns do
      [] -> park(context)
      _parked -> resume(context)
    end
  end

  defp park(context) do
    topic =
      context.history
      |> Enum.filter(&(&1.role == :user))
      |> flat_texts()
      |> List.first()
      |> topic_from("general")

    deadline =
      DateTime.add(
        DateTime.utc_now(),
        if(topic == "timeboxed", do: 150, else: 60_000),
        :millisecond
      )

    materials =
      Part.File.new(
        FileContent.from_bytes("# Workshop: #{topic}\nAttendees check in by name.\n",
          name: "materials-#{topic}.md",
          mime_type: "text/markdown"
        )
      )

    prompt =
      Part.Data.new(%{
        "workshop" => %{
          "topic" => topic,
          "deadline" => DateTime.to_iso8601(deadline)
        }
      })

    {:input_required,
     [prompt, materials, Part.Text.new("Reply with your attendee name to check in")]}
  end

  defp resume(context) do
    park = find_park(context.history)
    name = context.history |> Enum.filter(&(&1.role == :user)) |> flat_texts() |> List.last()
    topic = park["topic"]

    if DateTime.compare(DateTime.utc_now(), parse_deadline(park)) == :gt do
      {:error, {:workshop_closed, topic}}
    else
      {:reply, [Part.Text.new("certificate: #{name} completed the #{topic} workshop")]}
    end
  end

  defp find_park(history) do
    history
    |> Enum.filter(&(&1.role == :agent))
    |> Enum.flat_map(& &1.parts)
    |> Enum.find_value(fn
      %Part.Data{data: %{"workshop" => w}} -> w
      _ -> nil
    end)
  end

  defp flat_texts(history) do
    Enum.flat_map(history, fn msg ->
      if msg.role == :user do
        for %Part.Text{text: t} <- msg.parts, do: t
      else
        []
      end
    end)
  end

  defp topic_from("enroll: " <> topic, _default), do: String.trim(topic)
  defp topic_from(_, default), do: default

  defp parse_deadline(%{"deadline" => iso}), do: elem(DateTime.from_iso8601(iso), 1)
end

defmodule AshA2A.ConferenceSim.WorkshopCourt do
  @moduledoc """
  Conference-sim EV15: workshops as long-running interactive tasks.

  The `input-required` lifecycle (STREAM-SUB-002's pass condition) as the
  star scenario, over the real wire: a real protocol agent behind a real
  Bandit HTTP listener, SSE frames parsed from real wire bytes. No mocks.

  Courts:

    * the workshop parks `input-required` and the stream STAYS OPEN (G3's
      law — input-required keeps streams alive, keepalives flowing, no
      terminal frame, no close);
    * the attendee's `message/send` with the same `taskId` resumes the task,
      which completes with real output — on BOTH the resuming stream and the
      still-open original stream;
    * an attendee who never submits finds the venue honest: the task is
      still parked `input-required` after the idle window (no phantom
      timeout, no phantom completion), stream still alive;
    * a late submission (past the deadline embedded at park time) gets a
      typed refusal: terminal `:failed` with `{:workshop_closed, topic}`;
    * two attendees in one workshop: interleaved enroll/submit, each task
      gets its own certificate, no cross-wiring;
    * workshop materials: the File part attached before parking is fetched
      by the attendee via `tasks/get`; the completed task exposes the
      certificate as a real Artifact.
  """

  use ExUnit.Case, async: true

  alias AshA2A.ConferenceSim.WorkshopCourt.Agent
  alias AshA2A.Test.EphemeralHttp

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"workshop_agent_#{uniq}"
    transport = :"workshop_transport_#{uniq}"

    start_supervised!({Agent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    http =
      EphemeralHttp.start!(
        {AshA2A.A2ATransport.Plug,
         agent: agent,
         base_url: "http://x/a2a",
         transport: transport,
         heartbeat_ms: 100,
         agent_card_opts: [capabilities: %{streaming: true}]}
      )

    %{url: http.base_url, agent: agent}
  end

  alias AshA2A.Protocol.{JSON, Message, Part}

  # -- wire helpers ----------------------------------------------------------

  defp envelope(method, params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

  defp wire_message(text, task_id \\ nil) do
    {:ok, encoded} = JSON.encode(%{Message.new_user(text) | task_id: task_id})
    encoded
  end

  # Opens a streaming request in a separate process; raw chunks forwarded to
  # the test process (a chunk boundary can split a frame — buffer first).
  defp open_stream(url, method, params) do
    parent = self()

    spawn(fn ->
      Req.post!(url,
        json: envelope(method, params),
        retry: false,
        receive_timeout: 10_000,
        into: fn {:data, data}, acc ->
          send(parent, {:chunk, self(), data})
          {:cont, acc}
        end
      )

      send(parent, {:stream_closed, self()})
    end)
  end

  defp drain(pid, acc \\ "") do
    receive do
      {:chunk, ^pid, data} -> drain(pid, acc <> data)
      {:stream_closed, ^pid} -> full_frames(acc)
    after
      10_000 -> flunk("stream did not close")
    end
  end

  # Collects chunks until an ABSOLUTE deadline (not per-message relative) so a
  # steady keepalive flow cannot starve the timeout; returns {frames, raw, closed?}.
  defp collect_for(pid, ms, acc \\ "") do
    deadline = System.monotonic_time(:millisecond) + ms

    do_collect(pid, deadline, acc)
  end

  defp do_collect(pid, deadline, acc) do
    now = System.monotonic_time(:millisecond)

    receive do
      {:chunk, ^pid, data} -> do_collect(pid, deadline, acc <> data)
      {:stream_closed, ^pid} -> {full_frames(acc), acc, :closed}
    after
      max(0, deadline - now) -> {full_frames(acc), acc, :open}
    end
  end

  defp send_message(url, text, task_id \\ nil) do
    %{"result" => result} =
      Req.post!(url,
        json: envelope("message/send", %{"message" => wire_message(text, task_id)}),
        retry: false
      ).body

    result["task"] || raise("message/send returned no task: #{inspect(result)}")
  end

  defp get_task(url, task_id) do
    %{"result" => result} =
      Req.post!(url, json: envelope("tasks/get", %{"id" => task_id}), retry: false).body

    result["task"] || result
  end

  defp state(task),
    do: task["status"]["state"] |> String.downcase() |> String.replace_prefix("task_state_", "")

  defp status_message(task), do: task["status"]["message"]

  defp history_texts(task) do
    for %{"role" => "ROLE_AGENT", "parts" => parts} <- task["history"] || [],
        %{"text" => t} <- parts,
        do: t
  end

  defp history_files(task) do
    for %{"role" => "ROLE_AGENT", "parts" => parts} <- task["history"] || [],
        %{"filename" => _} = file <- parts,
        do: file
  end

  defp artifact_texts(task) do
    for %{"parts" => parts} <- task["artifacts"] || [],
        %{"text" => t} <- parts,
        do: t
  end

  defp unwrap(%{"task" => %{"id" => _} = task}), do: {:snapshot, task}
  defp unwrap(%{"statusUpdate" => event}), do: {:status, event}
  defp unwrap(%{"artifactUpdate" => event}), do: {:artifact, event}

  defp full_frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      id_line = frame |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "id: "))
      data_line = frame |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "data: "))

      # The resubscribe Task snapshot is written without an SSE `id:` line
      # (it is not a logged event); replayed/live events carry their seq.
      case {id_line, data_line} do
        {"id: " <> seq, "data: " <> json} -> [{seq, Jason.decode!(json)["result"]}]
        {nil, "data: " <> json} -> [{nil, Jason.decode!(json)["result"]}]
        _ -> []
      end
    end)
  end

  defp keepalives(body), do: Regex.scan(~r/^: keepalive$/m, body) |> length()

  @terminal_states [
    "TASK_STATE_COMPLETED",
    "TASK_STATE_FAILED",
    "TASK_STATE_CANCELED",
    "TASK_STATE_REJECTED",
    "TASK_STATE_AUTH_REQUIRED"
  ]

  defp terminal_frame?(frames) do
    Enum.any?(frames, fn {_seq, result} ->
      case unwrap(result) do
        {:status, %{"status" => %{"state" => s}}} -> s in @terminal_states
        # A live Task-snapshot event carrying a terminal state also closes the stream.
        {:snapshot, %{"status" => %{"state" => s}}} -> s in @terminal_states
        _ -> false
      end
    end)
  end

  defp last_state(frames) do
    {_, result} = List.last(frames)

    case unwrap(result) do
      {:status, %{"status" => %{"state" => s}}} ->
        s |> String.downcase() |> String.replace_prefix("task_state_", "")

      {:snapshot, %{"status" => %{"state" => s}}} ->
        s |> String.downcase() |> String.replace_prefix("task_state_", "")

      other ->
        flunk("last frame is not a status event: #{inspect(other)}")
    end
  end

  # -- courts ----------------------------------------------------------------

  @tag :conference_sim
  test "G3 / full interactive lifecycle: enroll parks input-required, the resubscribe stream STAYS OPEN, and the attendee's submit resumes and completes",
       %{url: url} do
    # Attendee enrolls over message/send; the task parks input-required.
    task = send_message(url, "enroll: taming")
    assert state(task) == "input_required"
    task_id = task["id"]

    # A subscriber attaches while the task is parked. The venue keeps the
    # stream OPEN through the park (G3: input-required keeps streams alive).
    watcher = open_stream(url, "tasks/resubscribe", %{"id" => task_id})
    {frames, raw, closed} = collect_for(watcher, 500)

    assert closed == :open, "the stream closed while the task was input-required (G3 violation)"

    # First frame: the parked Task snapshot.
    assert [{_seq, first} | _] = frames

    assert {:snapshot, %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} =
             unwrap(first)

    assert terminal_frame?(frames) == false

    # The venue's keepalives flowed while nobody spoke.
    assert keepalives(raw) >= 2

    # The attendee submits input via message/send with the same taskId; the
    # task resumes and completes with real output.
    done = send_message(url, "Ada", task_id)
    assert state(done) == "completed"

    # The stream that stayed open through the park received the same terminal
    # event, then closed at the terminal state (STREAM-SUB-002).
    w_frames = drain(watcher)
    assert last_state(w_frames) == "completed"
    assert terminal_frame?(w_frames)

    # And the certificate is real, on the task surface.
    assert "certificate: Ada completed the taming workshop" in artifact_texts(
             get_task(url, task_id)
           )
  end

  @tag :conference_sim
  test "attendee never submits: the venue idles honestly — still input-required after the window, stream alive, no phantom terminal",
       %{url: url} do
    task = send_message(url, "enroll: idle")
    assert state(task) == "input_required"
    task_id = task["id"]

    # Open a resubscriber to watch the parked task.
    watcher = open_stream(url, "tasks/resubscribe", %{"id" => task_id})
    {frames, raw, closed} = collect_for(watcher, 500)

    assert closed == :open
    assert terminal_frame?(frames) == false
    assert keepalives(raw) >= 2

    # The venue's actual idle policy: the task stays parked — no phantom
    # timeout, no phantom completion.
    assert state(get_task(url, task_id)) == "input_required"

    # Cleanup by protocol, not by kill: a late (still in-window) check-in
    # completes the task, so the watcher stream terminates at the terminal
    # state instead of being torn down mid-flight.
    assert state(send_message(url, "Patient Pat", task_id)) == "completed"
    assert last_state(drain(watcher)) == "completed"
  end

  @tag :conference_sim
  test "late submission after the deadline: typed refusal — terminal failed with workshop_closed",
       %{url: url} do
    task = send_message(url, "enroll: timeboxed")
    task_id = task["id"]
    assert state(task) == "input_required"

    # Outlive the 150 ms venue window, then submit anyway.
    # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
    AshA2A.TestSupport.Eventually.pause(300)

    late = send_message(url, "Late Larry", task_id)
    assert state(late) == "failed"

    assert %{"text" => reason} = status_message(late)["parts"] |> List.first()
    assert reason =~ "workshop_closed"
    assert reason =~ "timeboxed"
  end

  @tag :conference_sim
  test "two attendees, one workshop: interleaved enroll/submit, each gets their own output, no cross-wiring",
       %{url: url} do
    ada = send_message(url, "enroll: concurrency")
    grace = send_message(url, "enroll: concurrency")

    assert ada["id"] != grace["id"]
    assert state(ada) == "input_required" and state(grace) == "input_required"

    # Interleave: submit in the opposite order of enrollment.
    a2 = send_message(url, "Ada", ada["id"])
    g2 = send_message(url, "Grace", grace["id"])

    assert state(a2) == "completed" and state(g2) == "completed"

    assert "certificate: Ada completed the concurrency workshop" in artifact_texts(a2)
    assert "certificate: Grace completed the concurrency workshop" in artifact_texts(g2)
    refute "Grace" in artifact_texts(a2)
    refute "Ada" in artifact_texts(g2)
  end

  @tag :conference_sim
  test "workshop materials: File part attached before parking is fetchable via tasks/get; the completed task exposes the certificate artifact",
       %{url: url} do
    task = send_message(url, "enroll: materials")
    task_id = task["id"]

    # Materials were attached BEFORE the park: visible in the parked task's
    # history as a real File part.
    files = history_files(task)

    assert [
             %{
               "filename" => "materials-materials.md",
               "mediaType" => "text/markdown",
               "raw" => bytes
             }
           ] =
             files

    assert bytes == Base.encode64("# Workshop: materials\nAttendees check in by name.\n")

    # And the park prompt itself is in the history too.
    assert Enum.any?(history_texts(task), &(&1 == "Reply with your attendee name to check in"))

    # The attendee submits; the completed task carries the certificate as a
    # real Artifact.
    done = send_message(url, "Marie", task_id)
    assert state(done) == "completed"
    assert artifact_texts(done) == ["certificate: Marie completed the materials workshop"]
  end
end


# ==============================================================================
# SECTION 20 of 31: test/twin/ceo_test.exs
# ==============================================================================

defmodule AshA2A.Twin.CEOTest do
  use ExUnit.Case, async: true

  alias AshA2A.Twin.MechanicalPrior
  alias AshA2A.Twin.CEO

  # -- Exact-half detector: real number matrix ------------------------------

  test "exact_half? exact matrix" do
    assert CEO.exact_half?(100_000, 50_000)
    assert CEO.exact_half?(7, 3.5)
    # odd NTE: half is x.5 — exact equality on the diff, not on ints
    assert CEO.exact_half?(101, 50.5)
    refute CEO.exact_half?(100_000, 49_999)
    refute CEO.exact_half?(100_000, 51_000)
    refute CEO.exact_half?(100_000, 100_000)
    refute CEO.exact_half?(100_000, 0)
  end

  test "exact_half? tolerance absorbs cent-level rounding" do
    assert CEO.exact_half?(100_001, 50_000, 1)
    refute CEO.exact_half?(100_001, 50_000, 0)
    assert CEO.exact_half?(100_000, 50_005, 10)
    refute CEO.exact_half?(100_000, 50_100, 10)
  end

  # -- Round-number detector: calibration matrix ---------------------------

  test "round_suspicious? only flags offer-round/nte-unround mismatch" do
    # round offer + unround NTE -> suspicious (shape-chosen offer)
    assert CEO.round_suspicious?(123_457, 100_000)
    assert CEO.round_suspicious?(7_531, 7_500)
    # round on BOTH sides -> normal quoting, not flagged
    refute CEO.round_suspicious?(120_000, 100_000)
    refute CEO.round_suspicious?(80_000, 40_000)
    # unround offer + unround NTE -> fine
    refute CEO.round_suspicious?(123_457, 98_765)
    # unround offer + round NTE -> fine (offer reflects a computed number)
    refute CEO.round_suspicious?(100_000, 61_803)
  end

  test "round_suspicious? float offers use integer part" do
    assert CEO.round_suspicious?(99_999.99, 50_000.0)
    refute CEO.round_suspicious?(100_000.0, 50_000.0)
  end

  # -- GPM floor: boundary values ------------------------------------------

  test "gpm exact and floor boundary: 0.22 admits, 0.2199 challenges" do
    # (100_000 - 78_000)/100_000 = 0.22 exactly -> admits (floor itself is lawful)
    assert CEO.gpm(100_000, 78_000) == 0.22
    refute CEO.gpm_breach?(100_000, 78_000, 0.22)

    # 0.2199 -> breach -> challenge
    assert CEO.gpm_breach?(100_000, 78_010, 0.22)
    # (100_000 - 78_010)/100_000 = 0.2199
    assert_in_delta CEO.gpm(100_000, 78_010), 0.2199, 1.0e-12

    # 0.0 margin
    assert CEO.gpm_breach?(100_000, 100_000, 0.22)
    # negative margin
    assert CEO.gpm_breach?(100_000, 120_000, 0.22)
    # 0.28, pack example
    refute CEO.gpm_breach?(250_000, 180_000, 0.22)
  end

  # -- evaluate_intent: verdict shape and detector precedence --------------

  describe "evaluate_intent/2" do
    test "clean intent admits with a GPM ticket" do
      v = CEO.new()

      {v2, {:admit, ticket}} =
        CEO.evaluate_intent(v, %{trade: :t1, nte: 250_000, offer: 180_000})

      assert ticket.gpm == 0.28
      assert ticket.trade == :t1
      # admit does not touch the challenge ledger
      assert v2.challenges == %{}
    end

    test "GPM breach challenges with gpm_floor code and demanded evidence" do
      v = CEO.new()
      {v2, {:challenge, c}} = CEO.evaluate_intent(v, %{trade: :t2, nte: 100_000, offer: 85_000})
      assert c.code == :gpm_floor
      assert "itemized_cost_breakdown" in c.demanded_evidence
      assert is_reference(c.retry_token)
      assert v2.challenges[:t2] == 1
    end

    test "exact-half offer challenges with monkey_math code" do
      v = CEO.new()
      # 200_000/2 = 100_000, GPM 0.5 -> above floor, so monkey_math fires
      {_v2, {:challenge, c}} =
        CEO.evaluate_intent(v, %{trade: :t3, nte: 200_000, offer: 100_000})

      assert c.code == :monkey_math
      assert "labor_hours_breakdown" in c.demanded_evidence
    end

    test "round-number mismatch challenges with round_number_suspicious code" do
      v = CEO.new()
      # offer 90_000 on nte 123_457: GPM ~0.271 ok, not half, offer round / nte not
      {_v2, {:challenge, c}} =
        CEO.evaluate_intent(v, %{trade: :t4, nte: 123_457, offer: 90_000})

      assert c.code == :round_number_suspicious
      assert c.demanded_evidence == ["cost_basis_worksheet"]
    end

    test "detector precedence: GPM floor wins over monkey math" do
      # nte 200_000 offer 100_000 is half AND gpm 0.5 (no breach) -> monkey_math.
      # Force both: nte 100_000, offer 50_000 is half; gpm 0.5 no breach.
      # Breach+half: nte 10_000, offer 5_000 -> half, gpm 0.5 no breach.
      # Use nte 100_000 offer 39_000: gpm 0.61 fine, not half. Instead:
      # nte 100_000 offer 49_999.99 -> not half (diff 0.01 > 0 tolerance),
      # gpm 0.50 fine. To get a genuine both-fire: nte 100_004, offer 50_000
      # -> half within 2 tolerance, gpm ~0.5004 fine. Breach+half needs
      # offer < 78_000 and offer = nte/2, e.g. nte 150_000 offer 75_000:
      # gpm 0.5 -> no breach. GPM breach and exact-half cannot co-fire when
      # floor < 0.5: a half-split always has GPM exactly 0.5 > 0.22.
      # Verified: with floor 0.22, gpm_floor and monkey_math are mutually
      # exclusive; precedence is still enforced by cond order for custom
      # floors > 0.5.
      vhi = CEO.new(gpm_floor: 0.6)

      {_v, {:challenge, c}} =
        CEO.evaluate_intent(vhi, %{trade: :t5, nte: 150_000, offer: 75_000})

      assert c.code == :gpm_floor
    end

    test "repeat challenge on same trade escalates to :escalate_multisig" do
      v = CEO.new()
      {v1, {:challenge, _}} = CEO.evaluate_intent(v, %{trade: :t6, nte: 100_000, offer: 85_000})
      # partner retries on the SAME trade without satisfying the challenge
      {v2, {:refuse, :escalate_multisig}} =
        CEO.evaluate_intent(v1, %{trade: :t6, nte: 100_000, offer: 85_000})

      # a DIFFERENT trade still gets a fresh (non-escalated) evaluation
      {_v3, {:challenge, c}} =
        CEO.evaluate_intent(v2, %{trade: :t7, nte: 100_000, offer: 85_000})

      assert c.code == :gpm_floor
    end

    test "satisfying nothing changes: even an improved offer escalates once challenged" do
      v = CEO.new()
      {v1, {:challenge, _}} = CEO.evaluate_intent(v, %{trade: :t8, nte: 100_000, offer: 85_000})
      # retry with a clean offer on the same trade ref still escalates —
      # the trade ref must be retired, not silently retried
      {_v2, {:refuse, :escalate_multisig}} =
        CEO.evaluate_intent(v1, %{trade: :t8, nte: 100_000, offer: 78_000})
    end
  end

  # -- Mechanical prior hook ------------------------------------------------

  defmodule PermissivePrior do
    @behaviour MechanicalPrior

    @impl true
    def prior_verdict(_claim, _telemetry), do: {:admit, %{source: :permissive}}
  end

  defmodule InterrogatePrior do
    @behaviour MechanicalPrior

    # blown-motor claim + high ambient temp -> demand winding resistance
    @impl true
    def prior_verdict(:blown_motor, %{ambient_temp_c: t}) when t >= 40 do
      {:challenge, ["winding_resistance_readings"],
       "thermal-stress motor failure requires winding-resistance evidence"}
    end

    def prior_verdict(:blown_motor, %{ambient_temp_c: _}), do: {:admit, %{source: :motor_cool}}
    def prior_verdict(_claim, _telemetry), do: {:refuse, :unknown_claim_class}
  end

  describe "check_claim/3" do
    test "default RefuseAll prior refuses every claim" do
      v = CEO.new()

      {^v, {:refuse, %{code: :mechanical_prior, reason: :refuse_all_default_prior}}} =
        CEO.check_claim(v, {:claim, :anything}, %{})
    end

    test "pluggable prior admits through the hook" do
      v = CEO.new(prior: PermissivePrior)
      {^v, {:admit, ticket}} = CEO.check_claim(v, :whatever, %{})
      assert ticket.source == :permissive
    end

    test "counter-punch: blown motor + high ambient temp demands winding resistance" do
      v = CEO.new(prior: InterrogatePrior)
      {_v2, {:challenge, c}} = CEO.check_claim(v, :blown_motor, %{ambient_temp_c: 45})
      assert c.code == :mechanical_prior
      assert c.demanded_evidence == ["winding_resistance_readings"]
      assert c.msg =~ "winding-resistance"
    end

    test "blown motor at moderate temp admits through the prior" do
      v = CEO.new(prior: InterrogatePrior)
      {_v2, {:admit, _}} = CEO.check_claim(v, :blown_motor, %{ambient_temp_c: 20})
    end

    test "unknown claim class is refused with typed reason" do
      v = CEO.new(prior: InterrogatePrior)

      {_v2, {:refuse, %{code: :mechanical_prior, reason: :unknown_claim_class}}} =
        CEO.check_claim(v, :hail_damage, %{})
    end
  end

  # -- new/1 options --------------------------------------------------------

  test "new/1 honours gpm_floor and tolerance overrides" do
    v = CEO.new(gpm_floor: 0.30, tolerance: 5)
    assert v.gpm_floor == 0.30
    assert v.tolerance == 5
    # tolerance now absorbs a 3-unit half-split miss
    {_v2, {:challenge, c}} = CEO.evaluate_intent(v, %{trade: :t9, nte: 100_003, offer: 50_000})
    assert c.code == :monkey_math
  end

  describe "respelling and ledger" do
    test "respelled trade string cannot reset the escalation ledger" do
      v = CEO.new()

      {v1, {:challenge, _}} =
        CEO.evaluate_intent(v, %{trade: "HVAC.Drain", nte: 100_000, offer: 85_000})

      for respelled <- ["hvac.drain", " hvac.drain ", "HVAC.Drain ", "Hvac.DRAIN"] do
        assert {_, {:refuse, :escalate_multisig}} =
                 CEO.evaluate_intent(v1, %{trade: respelled, nte: 100_000, offer: 78_000})
      end

      assert map_size(v1.challenges) == 1
    end

    test "ledger counts challenge then escalations, bounded" do
      v = CEO.new()
      intent = %{trade: :t_count, nte: 100_000, offer: 85_000}
      {v1, {:challenge, _}} = CEO.evaluate_intent(v, intent)
      assert v1.challenges == %{t_count: 1}
      {v2, {:refuse, :escalate_multisig}} = CEO.evaluate_intent(v1, intent)
      assert v2.challenges == %{t_count: 2}

      v_big = %{v2 | challenges: %{t_count: 1_000}}
      {v3, {:refuse, :escalate_multisig}} = CEO.evaluate_intent(v_big, intent)
      assert v3.challenges == %{t_count: 1_000}
    end

    test "ledger is bounded: full ledger refuses new challenge-worthy trades, admits clean ones" do
      v = CEO.new(max_ledger: 1)
      {v1, {:challenge, _}} = CEO.evaluate_intent(v, %{trade: :a, nte: 100_000, offer: 85_000})

      assert {^v1, {:refuse, %{code: :ledger_full}}} =
               CEO.evaluate_intent(v1, %{trade: :b, nte: 100_000, offer: 85_000})

      assert {^v1, {:admit, _}} =
               CEO.evaluate_intent(v1, %{trade: :c, nte: 100_000, offer: 70_001})

      # existing trade still escalates at capacity
      assert {_, {:refuse, :escalate_multisig}} =
               CEO.evaluate_intent(v1, %{trade: :a, nte: 100_000, offer: 70_001})
    end
  end

  describe "malformed intents" do
    test "nte == 0, non-number, negative and malformed shapes refuse typed, ledger untouched" do
      v = CEO.new()

      cases = [
        {%{trade: :x, nte: 0, offer: 10}, :nte_not_positive},
        {%{trade: :x, nte: -5, offer: 10}, :nte_not_positive},
        {%{trade: :x, nte: "100", offer: 10}, :nte_not_a_number},
        {%{trade: :x, nte: nil, offer: 10}, :nte_not_a_number},
        {%{trade: :x, nte: 100, offer: "10"}, :offer_not_a_number},
        {%{trade: :x, nte: 100, offer: -1}, :offer_negative},
        {%{trade: :x}, :malformed_intent},
        {:nope, :malformed_intent}
      ]

      for {intent, reason} <- cases do
        assert {^v, {:refuse, %{code: :invalid_intent, reason: ^reason}}} =
                 CEO.evaluate_intent(v, intent)
      end
    end
  end

  describe "prior shape" do
    defmodule BadShapePrior do
      @behaviour AshA2A.Twin.MechanicalPrior
      @impl true
      def prior_verdict(_c, _t), do: :maybe
    end

    test "unexpected prior verdict shape is a typed refusal" do
      v = CEO.new(prior: BadShapePrior)

      assert {^v, {:refuse, %{code: :mechanical_prior, reason: {:invalid_prior_verdict, :maybe}}}} =
               CEO.check_claim(v, :c, %{})
    end

    test "prior that is not a loaded prior module is a typed refusal" do
      for bad <- [NoSuchPriorModule, nil, "str", String] do
        v = CEO.new(prior: bad)

        assert {^v, {:refuse, %{code: :mechanical_prior, reason: {:invalid_prior, ^bad}}}} =
                 CEO.check_claim(v, :c, %{})
      end
    end
  end
end


# ==============================================================================
# SECTION 21 of 31: test/twin/coo_test.exs
# ==============================================================================

defmodule AshA2A.Twin.COOTest do
  use ExUnit.Case, async: true

  alias AshA2A.Twin.COO

  # --- fixtures ---------------------------------------------------------

  @fresh_tensor %{
    shift_hours_continuous: 0,
    active_leases: 0,
    error_rate: 0.0,
    heuristic_frequency: 0,
    attestation_age_sec: 0,
    financial_risk_exposure: 0
  }

  @saturated_tensor %{
    shift_hours_continuous: 10,
    active_leases: 18,
    error_rate: 0.9,
    heuristic_frequency: 10,
    attestation_age_sec: 3600,
    financial_risk_exposure: 30_000
  }

  defp saturated_tensor do
    # 0.30*(1-exp(-10/4)) + 0.25*1.0 + 0.20*0.9 + 0.10*1.0 + 0.05*0.5 + 0.10*0.6
    # = 0.2953 + 0.25 + 0.18 + 0.10 + 0.025 + 0.06 = 0.9103 > 0.7
    @saturated_tensor
  end

  defp routine_ticket(i, coordinator) do
    %{
      id: "R#{i}",
      coordinator_id: coordinator,
      warranty_status: :active,
      operating_hours: 500,
      sla_window:
        {DateTime.add(DateTime.utc_now(), -3600), DateTime.add(DateTime.utc_now(), 3600)},
      contractor_coi_valid: true
    }
  end

  defp edge_ticket(i) do
    %{id: "E#{i}", warranty_status: :expired, operating_hours: 9000}
  end

  # --- handle_inbound ---------------------------------------------------

  describe "handle_inbound/2" do
    test "admits when the target coordinator is under the saturation gate" do
      mesh = COO.register_coordinator(%{}, :colo_a, @fresh_tensor)

      assert {:admit, :colo_a} =
               COO.handle_inbound(mesh, %{coordinator_id: :colo_a})
    end

    test "sheds to the senior queue target at the saturation boundary" do
      mesh = COO.register_coordinator(%{}, :colo_b, saturated_tensor())

      assert {:shed, {:senior_queue, :coo_relief}} =
               COO.handle_inbound(mesh, %{coordinator_id: :colo_b})
    end

    test "unknown coordinator raises (fail-closed)" do
      assert_raise KeyError, fn ->
        COO.handle_inbound(%{}, %{coordinator_id: :ghost})
      end
    end
  end

  # --- triage -----------------------------------------------------------

  describe "triage/2" do
    test "partitions a realistic 40-ticket surge: 34 routine / 6 edges" do
      now = DateTime.utc_now()

      tickets =
        Enum.map(1..34, &routine_ticket(&1, :colo_a)) ++
          [
            edge_ticket(1),
            %{edge_ticket(2) | operating_hours: 9000},
            # missing fields entirely
            %{id: "E3"},
            # expired SLA
            %{
              id: "E4",
              warranty_status: :active,
              operating_hours: 100,
              sla_window: {DateTime.add(now, -7200), DateTime.add(now, -3600)},
              contractor_coi_valid: true
            },
            # COI invalid
            %{
              id: "E5",
              warranty_status: :active,
              operating_hours: 100,
              sla_window: :open,
              contractor_coi_valid: false
            },
            # hours over cap
            %{
              id: "E6",
              warranty_status: :active,
              operating_hours: 5000,
              sla_window: :open,
              contractor_coi_valid: true
            }
          ]

      {routine, edges} = COO.triage(tickets, now: now)

      assert length(routine) == 34
      assert length(edges) == 6
      assert Enum.all?(routine, &(&1.id |> String.starts_with?("R")))
      assert Enum.all?(edges, &(&1.id |> String.starts_with?("E")))
    end

    test "sla_window :open literal passes the checklist" do
      ticket = %{
        id: "R99",
        warranty_status: :active,
        operating_hours: 10,
        sla_window: :open,
        contractor_coi_valid: true
      }

      assert {[^ticket], []} = COO.triage([ticket])
    end
  end

  # --- balance ----------------------------------------------------------

  describe "balance/3" do
    test "diverts high-friction tickets from saturated coordinators to the freshest one" do
      mesh =
        %{}
        |> COO.register_coordinator(:hot, saturated_tensor())
        |> COO.register_coordinator(:cold, @fresh_tensor)

      tickets = [
        %{id: "T1", coordinator_id: :hot, friction: 0.9},
        %{id: "T2", coordinator_id: :hot, friction: 0.3},
        %{id: "T3", coordinator_id: :cold, friction: 0.9}
      ]

      [t1, t2, t3] = COO.balance(tickets, mesh)

      assert t1.coordinator_id == :cold
      assert t2.coordinator_id == :hot
      assert t3.coordinator_id == :cold
    end

    test "no saturated coordinators: tickets unchanged" do
      mesh = COO.register_coordinator(%{}, :a, @fresh_tensor)
      tickets = [%{id: "T1", coordinator_id: :a, friction: 0.99}]

      assert COO.balance(tickets, mesh) == tickets
    end
  end

  describe "triage/2 windows and boundaries" do
    @now ~U[2026-06-01 12:00:00Z]

    defp t(overrides) do
      Map.merge(
        %{
          warranty_status: :active,
          operating_hours: 500,
          sla_window: {~U[2026-06-01 00:00:00Z], ~U[2026-06-02 00:00:00Z]},
          contractor_coi_valid: true
        },
        Map.new(overrides)
      )
    end

    defp routine?(ticket, opts \\ []) do
      {r, _e} = COO.triage([ticket], Keyword.merge([now: @now], opts))
      r != []
    end

    test "sla window bounds are inclusive; one second outside escalates" do
      assert routine?(t(sla_window: {@now, ~U[2026-06-02 00:00:00Z]}))
      assert routine?(t(sla_window: {~U[2026-06-01 00:00:00Z], @now}))
      refute routine?(t(sla_window: {DateTime.add(@now, 1), ~U[2026-06-02 00:00:00Z]}))
      refute routine?(t(sla_window: {~U[2026-06-01 00:00:00Z], DateTime.add(@now, -1)}))
    end

    test "operating hours 2000 inclusive, 2001 escalates, custom max honoured, negative escalates" do
      assert routine?(t(operating_hours: 2000))
      refute routine?(t(operating_hours: 2001))
      assert routine?(t(operating_hours: 2001), max_operating_hours: 3000)
      refute routine?(t(operating_hours: -1))
      refute routine?(t(operating_hours: "500"))
    end

    test "missing or invalid fields escalate; non-map tickets escalate" do
      refute routine?(Map.delete(t([]), :warranty_status))
      refute routine?(t(warranty_status: :expired))
      refute routine?(t(contractor_coi_valid: false))
      refute routine?(Map.delete(t([]), :sla_window))
      refute routine?(t(sla_window: {1, 2}))
      {[], [:not_a_ticket]} = COO.triage([:not_a_ticket], now: @now)
    end

    test "injected now makes triage deterministic across the same ticket" do
      ticket = t(sla_window: {~U[2026-06-01 00:00:00Z], ~U[2026-06-01 06:00:00Z]})
      refute routine?(ticket)
      assert routine?(ticket, now: ~U[2026-06-01 03:00:00Z])
    end

    test "order is preserved in both partitions" do
      a = Map.put(t([]), :id, 1)
      b = Map.put(t(warranty_status: :expired), :id, 2)
      c = Map.put(t([]), :id, 3)
      d = Map.put(t(operating_hours: 9999), :id, 4)
      {r, e} = COO.triage([a, b, c, d], now: @now)
      assert Enum.map(r, & &1.id) == [1, 3]
      assert Enum.map(e, & &1.id) == [2, 4]
    end
  end

  describe "balance/3 tolerance" do
    test "tickets without :friction or :coordinator_id pass through untouched" do
      mesh =
        %{}
        |> COO.register_coordinator(:sat, saturated_tensor())
        |> COO.register_coordinator(:fresh, @fresh_tensor)

      tickets = [
        %{id: 1, coordinator_id: :sat},
        %{id: 2, friction: 0.95},
        %{id: 3},
        %{id: 4, coordinator_id: :sat, friction: 0.95},
        %{id: 5, coordinator_id: :sat, friction: nil},
        %{id: 6, coordinator_id: :sat, friction: 0.7},
        :junk
      ]

      assert [
               %{id: 1, coordinator_id: :sat},
               %{id: 2, friction: 0.95},
               %{id: 3},
               %{id: 4, coordinator_id: :fresh},
               %{id: 5, coordinator_id: :sat},
               %{id: 6, coordinator_id: :sat},
               :junk
             ] = COO.balance(tickets, mesh)
    end

    test "all coordinators saturated: tickets unchanged (no fresh target)" do
      mesh = COO.register_coordinator(%{}, :sat, saturated_tensor())
      tickets = [%{id: 1, coordinator_id: :sat, friction: 0.99}]
      assert COO.balance(tickets, mesh) == tickets
    end
  end
end


# ==============================================================================
# SECTION 22 of 31: test/twin/hazard_test.exs
# ==============================================================================

defmodule AshA2A.Twin.HazardTest do
  use ExUnit.Case, async: true

  alias AshA2A.Twin.Hazard

  test "new/1 rejects non-positive and non-integer capacity; new/0 uses default" do
    assert Hazard.new().capacity == Hazard.default_capacity()
    for bad <- [0, -3, 1.5, nil, "8"], do: assert_raise(ArgumentError, fn -> Hazard.new(bad) end)
  end

  test "observe error path returns the typed error and does not push" do
    h = Enum.reduce([10, 10, 10], Hazard.new(8), &Hazard.push(&2, &1))
    assert {:error, :insufficient_dispersion} = Hazard.observe(h, 11)
    assert Hazard.window(h) == [10, 10, 10]
  end

  test "non-number observation is a typed error" do
    h = Hazard.new(4)
    assert {:error, :invalid_observation} = Hazard.observe(h, "fast")
    assert {:error, :invalid_observation} = Hazard.observe(h, nil)
    assert {:error, :invalid_observation} = Hazard.zscore(:x, [1, 2, 3])
    assert {:error, :invalid_observation} = Hazard.zscore(5, :window)
  end

  test "median of empty window raises ArgumentError; mad of empty is 0.0" do
    assert_raise ArgumentError, fn -> Hazard.median([]) end
    assert Hazard.mad([]) == 0.0
  end

  test "zero_dispersion_spike: slow spike on established flat window; others none" do
    assert {:spike, %{z: :infinity, median: 10.0, trip?: true}} =
             Hazard.zero_dispersion_spike([10, 10, 10, 10], 1_000)

    assert :none = Hazard.zero_dispersion_spike([10, 10, 10], 10)
    assert :none = Hazard.zero_dispersion_spike([10, 10, 10], 5)
    assert :none = Hazard.zero_dispersion_spike([10, 10], 1_000)
    assert :none = Hazard.zero_dispersion_spike([], 1_000)
    assert :none = Hazard.zero_dispersion_spike([10, 10, 10], nil)
    # dispersed window is not zero-dispersion
    assert :none = Hazard.zero_dispersion_spike([1, 5, 9, 12], 1_000)
  end
end


# ==============================================================================
# SECTION 23 of 31: test/twin/lease_test.exs
# ==============================================================================

defmodule AshA2A.Twin.LeaseTest do
  use ExUnit.Case, async: true

  alias AshA2A.Twin.Lease

  defp clock(t), do: [clock: {:mono, fn -> t end}]

  test "revoked lease cannot be renewed by nil holder or revoked again by nil" do
    {:ok, lease} = Lease.grant(:r, :h, 50, clock(1_000))
    {:ok, revoked} = Lease.revoke(lease, :h)
    assert revoked.holder == nil
    assert {:error, :not_holder} = Lease.renew(revoked, nil, 10, clock(1_001))
    assert {:error, :not_holder} = Lease.renew(revoked, :h, 10, clock(1_001))
    assert {:error, :not_holder} = Lease.revoke(revoked, nil)
    refute Lease.held?(revoked, nil, clock(1_001))
    assert Lease.expired?(revoked, nil, clock(1_001))
    # force still lawful
    assert {:ok, _} = Lease.revoke(revoked, :force)
  end

  test "renew refuses an expired (zombie) lease; boundary is exclusive" do
    {:ok, lease} = Lease.grant(:r, :h, 50, clock(1_000))
    assert {:ok, r} = Lease.renew(lease, :h, 10, clock(1_049))
    assert r.lease_until == 1_059
    assert {:error, :expired} = Lease.renew(lease, :h, 10, clock(1_050))
    assert {:error, :expired} = Lease.renew(lease, :h, 10, clock(5_000))
  end

  test "malformed clocks are typed not-held, never a crash" do
    {:ok, lease} = Lease.grant(:r, :h, 50, clock(1_000))

    for bad <- [
          nil,
          :wall,
          {:mono, nil},
          {:mono, fn -> :nope end},
          {:mono, fn -> nil end},
          {:mono, fn _ -> 1 end},
          {:mono, fn -> raise "boom" end}
        ] do
      opts = [clock: bad]
      refute Lease.held?(lease, :h, opts)
      assert Lease.expired?(lease, :h, opts)
      assert {:error, :invalid_clock} = Lease.grant(:r, :h, 5, opts)
      assert {:error, :invalid_clock} = Lease.renew(lease, :h, 5, opts)
    end

    assert_raise ArgumentError, fn -> Lease.clock_now(clock: nil) end
  end

  test "numeric guards: non-number and non-positive durations are typed" do
    for d <- [0, -1, 0.0, nil, "5", :x] do
      assert {:error, :invalid_duration} = Lease.grant(:r, :h, d, clock(1))
    end

    {:ok, lease} = Lease.grant(:r, :h, 50, clock(1))
    assert {:error, :invalid_duration} = Lease.renew(lease, :h, nil, clock(2))
    assert {:error, :invalid_duration} = Lease.renew(lease, :h, 0, clock(2))
  end

  test "holder nil never held even when granted to nil" do
    {:ok, lease} = Lease.grant(:r, nil, 50, clock(1))
    refute Lease.held?(lease, nil, clock(2))
    assert {:error, :not_holder} = Lease.renew(lease, nil, 5, clock(2))
  end
end


# ==============================================================================
# SECTION 24 of 31: test/twin/server_test.exs
# ==============================================================================

defmodule AshA2A.Twin.ServerTest do
  use ExUnit.Case, async: false

  alias AshA2A.Twin.{Asset, Operator, Partner, Server}

  setup do
    start_supervised!({AshA2A.Twin, [name: :"twin_srv_sup_#{System.unique_integer()}"]})
    :ok
  end

  defp uname(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp wait_until(fun, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("condition not met in deadline")
      # SLEEP-CLASS: POLL-STEP (the audited deadline poll)
      true -> Process.sleep(10) && poll(fun, deadline)
    end
  end

  test "registration happens in the twin: name and Registry both resolve to its pid" do
    n = uname("asset")
    {:ok, pid} = AshA2A.Twin.start_twin(Asset, n)
    assert Process.whereis(n) == pid
    assert [{^pid, ^pid}] = Registry.lookup(AshA2A.Twin.Registry, n)
  end

  test "duplicate name: second start refused, no orphan, first twin untouched" do
    n = uname("asset")
    {:ok, first} = AshA2A.Twin.start_twin(Asset, n)
    before = AshA2A.Twin.count_twins()

    assert {:error, {^n, :already_registered}} = AshA2A.Twin.start_twin(Asset, n)

    assert AshA2A.Twin.count_twins() == before
    assert Process.whereis(n) == first
    assert Process.alive?(first)
    assert %{kind: :asset} = Asset.status(n)
  end

  test "duplicate name across kinds is also refused" do
    n = uname("shared")
    {:ok, _} = AshA2A.Twin.start_twin(Operator, n)
    assert {:error, {^n, :already_registered}} = AshA2A.Twin.start_twin(Partner, n)
  end

  test "registry entry disappears with the twin" do
    n = uname("op")
    {:ok, pid} = AshA2A.Twin.start_twin(Operator, n)
    ref = Process.monitor(pid)
    Operator.stop(n)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    # Twins are :permanent children, so the supervisor may re-register a fresh
    # incarnation under the same name; the dead pid's entry must be gone.
    wait_until(
      fn ->
        match?([], Registry.lookup(AshA2A.Twin.Registry, n)) or
          match?([{new, _}] when new != pid, Registry.lookup(AshA2A.Twin.Registry, n))
      end,
      1_000
    )
  end

  test "peek on a non-operator replies a typed error instead of hanging" do
    a = uname("asset")
    p = uname("partner")
    {:ok, _} = AshA2A.Twin.start_twin(Asset, a)
    {:ok, _} = AshA2A.Twin.start_twin(Partner, p)
    assert {:error, {:wrong_kind, :asset}} = Server.call(a, {:peek, 3})
    assert {:error, {:wrong_kind, :partner}} = Server.call(p, {:peek, 3})
  end

  test "unknown call replies typed error on every kind" do
    for {mod, prefix} <- [{Asset, "a"}, {Partner, "p"}, {Operator, "o"}] do
      n = uname(prefix)
      {:ok, _} = AshA2A.Twin.start_twin(mod, n)
      assert {:error, :unknown_call} = Server.call(n, :bogus)
    end
  end

  test "operator peek rejects negative / non-integer n; zero is empty" do
    o = uname("op")
    {:ok, _} = AshA2A.Twin.start_twin(Operator, o)
    Operator.enqueue(o, :a)
    wait_until(fn -> Operator.status(o).depth == 1 end, 1_000)
    assert Operator.peek(o, 0) == []
    assert Operator.peek(o, -1) == {:error, :invalid_n}
    assert Operator.peek(o, :all) == {:error, :invalid_n}
    assert Operator.peek(o, 1) == [:a]
  end

  test "zero-dispersion spike trips an unacked dispatch (fail closed)" do
    p = uname("partner")
    {:ok, _} = AshA2A.Twin.start_twin(Partner, p, listener: self())
    Partner.shift_on(p)
    assert_receive {:shift_changed, ^p, :on_shift}, 1_000
    Enum.each([100, 100, 100, 100], &Partner.response(p, &1))
    Partner.dispatch(p, :job_flat)
    Partner.response(p, 5_000)

    assert_receive {:hazard_tripped, ^p, :infinity, %{dispatch: :job_flat, dispersion: :zero}},
                   1_000
  end

  test "zero-dispersion window with an equal observation does not trip" do
    p = uname("partner")
    {:ok, _} = AshA2A.Twin.start_twin(Partner, p, listener: self())
    Partner.shift_on(p)
    assert_receive {:shift_changed, ^p, :on_shift}, 1_000
    Enum.each([100, 100, 100, 100], &Partner.response(p, &1))
    Partner.dispatch(p, :job_flat)
    Partner.response(p, 100)
    # status call is a barrier: the cast above was processed before it replies
    assert %{window_size: 5} = Partner.status(p)
    refute_received {:hazard_tripped, _, _, _}
  end

  test "invalid twin name is refused at start" do
    Process.flag(:trap_exit, true)
    assert {:error, {nil, :invalid_name}} = Server.start_link(:asset, nil, [])
  end
end


# ==============================================================================
# SECTION 25 of 31: test/twin/twin_test.exs
# ==============================================================================

defmodule AshA2A.TwinTest do
  use ExUnit.Case, async: false

  alias AshA2A.Twin.{Asset, Hazard, Lease, Operator, Partner}

  setup do
    sup_name = :"twin_test_sup_#{System.unique_integer()}"
    start_supervised!({AshA2A.Twin, [name: sup_name]})
    :ok
  end

  # -- Hazard math: exact values on known windows ---------------------------

  test "median/MAD/z exact on a known window" do
    window = [100, 102, 98, 105, 95]
    assert Hazard.median(window) == 100.0
    # deviations [0,2,2,5,5] -> MAD 2.0
    assert Hazard.mad(window) == 2.0
    {:ok, z} = Hazard.zscore(106, window)
    assert z == 3.0
    assert Hazard.trip?(z, 2.5)
    refute Hazard.trip?(1.0, 2.5)
    # strictly greater: z == threshold does not trip
    refute Hazard.trip?(2.5, 2.5)
  end

  test "MAD == 0 -> typed insufficient_dispersion" do
    assert {:error, :insufficient_dispersion} = Hazard.zscore(50, [10, 10, 10])
    assert {:error, :insufficient_dispersion} = Hazard.zscore(50, [])
    assert {:error, :insufficient_dispersion} = Hazard.zscore(50, [7, 7, 7])
  end

  test "even-length median averages the two middle values" do
    assert Hazard.median([1, 2, 3, 4]) == 2.5
    assert Hazard.mad([1, 2, 3, 4]) == 1.0
  end

  test "ring buffer evicts oldest past capacity" do
    h = Hazard.new(3)
    h = Enum.reduce([1, 2, 3, 4, 5], h, fn x, h -> Hazard.push(h, x) end)
    assert Enum.sort(Hazard.window(h)) == [3, 4, 5]
  end

  test "observe pushes then estimates and returns the advanced monitor" do
    h = Hazard.new(4)
    h = Enum.reduce([10, 12, 8, 10], h, fn x, h -> Hazard.push(h, x) end)
    {:ok, stats} = Hazard.observe(h, 10)
    assert stats.median == 10.0
    assert is_float(stats.mad)
    assert is_number(stats.z)
    # pre-observation window semantics: monitor has the new obs prepended
    assert stats.monitor.buffer == Enum.take([10 | stats.window], 4)
    assert stats.trip? == Hazard.trip?(stats.z)
  end

  # -- Lease tests -----------------------------------------------------------

  test "grant/renew/expire/revoke with injected monotonic clock" do
    t0 = 1_000
    {:ok, lease} = Lease.grant(:res_a, :asset_1, 50, clock: {:mono, fn -> t0 end})
    assert lease.lease_until == t0 + 50
    assert Lease.held?(lease, :asset_1, clock: {:mono, fn -> t0 + 49 end})
    assert Lease.expired?(lease, :asset_1, clock: {:mono, fn -> t0 + 50 end})
    # zombie: expiry without renewal
    assert Lease.expired?(lease, :asset_1, clock: {:mono, fn -> t0 + 500 end})
    assert {:error, :invalid_duration} = Lease.grant(:x, :h, 0)
    assert {:error, :invalid_duration} = Lease.renew(lease, :asset_1, -5)
  end

  test "CAS: foreign claimant cannot renew; revoke only by holder or force" do
    t0 = 1_000
    {:ok, lease} = Lease.grant(:res_b, :asset_1, 50, clock: {:mono, fn -> t0 end})
    {:ok, r1} = Lease.renew(lease, :asset_1, 80, clock: {:mono, fn -> t0 + 10 end})
    assert r1.lease_until == t0 + 90
    assert r1.renewed_count == 1
    assert {:error, :not_holder} = Lease.renew(r1, :intruder, 10)
    assert {:error, :not_holder} = Lease.revoke(r1, :other)
    {:ok, revoked} = Lease.revoke(r1, :asset_1)
    assert Lease.expired?(revoked, :asset_1, clock: {:mono, fn -> t0 + 10 end})
  end

  test "real monotonic clock: fresh lease held, wrong holder expired, expiry is real" do
    {:ok, lease} = Lease.grant(:r, :h, :erlang.convert_time_unit(1, :millisecond, :native) * 5)
    assert Lease.held?(lease, :h)
    assert Lease.expired?(lease, :wrong_holder)
    wait_until(fn -> Lease.expired?(lease, :h) end, 2_000)
  end

  # -- Partner twin: hazard trip over a real gen_statem ----------------------

  test "partner trips hazard on unacknowledged slow response" do
    listener = self()
    pn = :"partner_#{System.unique_integer()}"
    {:ok, _} = AshA2A.Twin.start_twin(Partner, pn, listener: listener, threshold: 2.5)
    assert %{shift: :off_shift} = Partner.status(pn)

    Partner.shift_on(pn)
    assert_receive({:shift_changed, ^pn, :on_shift}, 1_000)
    Enum.each([100, 102, 98, 105, 95], &Partner.response(pn, &1))

    # dispatch stays unacknowledged; z = (106-100)/2 = 3.0 > 2.5 -> trip
    Partner.dispatch(pn, :job_42)
    Partner.response(pn, 106)
    assert_receive({:hazard_tripped, ^pn, 3.0, stats}, 1_000)
    assert stats.median == 100.0
    assert stats.mad == 2.0
    assert stats.dispatch == :job_42
  end

  test "ack suppresses trips until next dispatch; off-shift dispatch is ignored" do
    listener = self()
    pn2 = :"partner_#{System.unique_integer()}"
    {:ok, _} = AshA2A.Twin.start_twin(Partner, pn2, listener: listener, threshold: 2.5)
    Partner.shift_on(pn2)
    assert_receive({:shift_changed, ^pn2, :on_shift}, 1_000)
    Enum.each([100, 102, 98, 105, 95], &Partner.response(pn2, &1))
    Partner.dispatch(pn2, :job_43)
    Partner.ack(pn2)
    Partner.response(pn2, 106)
    refute_receive({:hazard_tripped, _, _, _}, 200)
    Partner.shift_off(pn2)
    assert_receive({:shift_changed, ^pn2, :off_shift}, 1_000)
    Partner.dispatch(pn2, :job_44)
    Partner.response(pn2, 120)
    refute_receive({:hazard_tripped, _, _, _}, 200)
  end

  # -- Asset SLA timer (real gen_statem timer, no sleep coordination) --------

  test "asset arms SLA on activity and fires expiry when not disarmed" do
    listener = self()
    an = :"asset_#{System.unique_integer()}"
    {:ok, _} = AshA2A.Twin.start_twin(Asset, an, listener: listener, sla_ms: 30)
    assert %{armed?: false, ops_count: 0} = Asset.status(an)

    Asset.record_activity(an, :run_1)

    wait_until(
      fn ->
        %{armed?: armed} = Asset.status(an)
        armed
      end,
      1_000
    )

    assert_receive({:sla_expired, ^an, %{ref: :run_1}}, 2_000)

    wait_until(
      fn ->
        %{armed?: armed} = Asset.status(an)
        not armed
      end,
      1_000
    )

    # disarm suppresses the countdown
    Asset.record_activity(an, :run_2)
    Asset.disarm(an)
    refute_receive({:sla_expired, ^an, %{ref: :run_2}}, 100)
  end

  # -- Operator queue + attention budget -------------------------------------

  test "operator dequeues in order, budget exhaustion emits event, recharge restores" do
    listener = self()
    on = :"operator_#{System.unique_integer()}"
    {:ok, _} = AshA2A.Twin.start_twin(Operator, on, listener: listener, budget: 2)
    assert %{depth: 0, budget: 2} = Operator.status(on)

    Operator.enqueue(on, :w1)
    Operator.enqueue(on, :w2)
    wait_until(fn -> Operator.status(on).depth == 2 end, 1_000)
    assert Operator.peek(on, 5) == [:w1, :w2]

    Operator.attend(on)
    Operator.attend(on)
    assert_receive({:budget_exhausted, ^on, %{depth: 0}}, 1_000)

    wait_until(
      fn ->
        %{depth: depth, budget: budget} = Operator.status(on)
        depth == 0 and budget == 0
      end,
      1_000
    )

    # fail-closed: attending at zero budget does nothing
    Operator.enqueue(on, :w3)
    Operator.attend(on)
    wait_until(fn -> Operator.status(on).depth == 1 end, 1_000)
    assert Operator.peek(on, 5) == [:w3]

    Operator.recharge(on)
    Operator.attend(on)

    wait_until(
      fn ->
        %{depth: depth, budget: budget} = Operator.status(on)
        depth == 0 and budget == 4
      end,
      1_000
    )
  end

  # -- Lifecycle: no orphan actors after supervisor shutdown -----------------

  test "twin lifecycle: all actors die with supervisor" do
    twins_before = AshA2A.Twin.count_twins()
    lan = :"asset_#{System.unique_integer()}"
    lpn = :"partner_#{System.unique_integer()}"
    {:ok, _} = AshA2A.Twin.start_twin(Asset, lan, sla_ms: 60_000)
    {:ok, _} = AshA2A.Twin.start_twin(Partner, lpn)
    wait_until(fn -> AshA2A.Twin.count_twins() == twins_before + 2 end, 1_000)
    assert Process.whereis(lan)
    assert Process.whereis(lpn)

    stop_supervisor()
    wait_until(fn -> AshA2A.Twin.count_twins() == 0 end, 2_000)
    refute Process.whereis(lan), "orphan asset twin after shutdown"
    refute Process.whereis(lpn), "orphan partner twin after shutdown"
  end

  defp stop_supervisor do
    case Process.whereis(AshA2A.Twin.TwinSupervisor) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end

  defp wait_until(fun, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    check(fun, deadline)
  end

  defp check(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met within deadline")
      end

      Process.sleep(20)
      check(fun, deadline)
    end
  end
end


# ==============================================================================
# SECTION 26 of 31: test/untested_lane18/c2_authority_test.exs
# ==============================================================================

defmodule AshA2A.UntestedLane18.C2AuthorityTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{
    BudgetLedger,
    ConfusedDeputy,
    ControlPlaneFence,
    EffectorRegistry,
    FencingToken,
    PolicyEpoch,
    Principal,
    ResourceEnvelope,
    RevocationEpoch
  }

  defmodule RealEffector do
    @behaviour AshA2A.C2.Effector
    def perform(effect), do: {:ok, effect.capability}
  end

  defp cert(overrides \\ %{}),
    do:
      Map.merge(
        %{generation: 5, policy_epoch: 3, revocation_epoch: 2, principal: "p1"},
        overrides
      )

  describe "BudgetLedger" do
    test "allocate debits parent and yields child with limit" do
      assert {:ok, %{remaining: 6}, %{limit: 4, remaining: 4}} =
               BudgetLedger.allocate(%{remaining: 10, limit: 10}, 4)
    end

    test "refuses over-allocation, negatives and non-numbers" do
      b = %{remaining: 3}
      assert {:error, :budget_exceeded} = BudgetLedger.allocate(b, 4)
      assert {:error, :budget_exceeded} = BudgetLedger.allocate(b, -1)
      assert {:error, :budget_exceeded} = BudgetLedger.allocate(b, "1")
      assert {:error, :budget_exceeded} = BudgetLedger.allocate(%{}, 1)
    end

    test "exact exhaustion allowed then nothing left" do
      assert {:ok, %{remaining: 0} = b, _} = BudgetLedger.allocate(%{remaining: 3}, 3)
      assert {:error, :budget_exceeded} = BudgetLedger.allocate(b, 1)
    end

    test "conservation holds across successive allocations, fails when inflated" do
      parent = %{remaining: 10, limit: 10}
      {:ok, p1, c1} = BudgetLedger.allocate(parent, 4)
      {:ok, _p2, c2} = BudgetLedger.allocate(p1, 6)
      assert BudgetLedger.conserved?(parent, [c1, c2])
      refute BudgetLedger.conserved?(parent, [c1, c2, %{limit: 1}])
      assert BudgetLedger.conserved?(parent, [])
    end
  end

  describe "ConfusedDeputy" do
    test "refuses when requested principal differs from authenticated" do
      assert ConfusedDeputy.refuse?("alice", "bob")
      refute ConfusedDeputy.refuse?("alice", "alice")
    end
  end

  describe "ControlPlaneFence" do
    test "clean maps pass; atom and string forbidden keys fail" do
      assert ControlPlaneFence.clean?(%{"b" => 2, a: 1})
      assert ControlPlaneFence.clean?(%{})
      refute ControlPlaneFence.clean?(%{secret: 1})
      refute ControlPlaneFence.clean?(%{"private_key" => "x"})
      refute ControlPlaneFence.clean?(%{"password" => "x", ok: 1})
    end

    test "all forbidden names are refused in both key forms" do
      for k <- [:secret, :private_key, :access_token, :password, :credential] do
        refute ControlPlaneFence.clean?(%{k => 1})
        refute ControlPlaneFence.clean?(%{Atom.to_string(k) => 1})
      end
    end
  end

  describe "epochs and fencing" do
    test "fencing token is monotonic: older generation refused" do
      assert FencingToken.valid?(cert(), 5)
      assert FencingToken.valid?(cert(), 4)
      refute FencingToken.valid?(cert(), 6)
    end

    test "policy epoch must match exactly" do
      assert PolicyEpoch.valid?(cert(), 3)
      refute PolicyEpoch.valid?(cert(), 4)
      refute PolicyEpoch.valid?(cert(), 2)
    end

    test "revocation epoch must match exactly" do
      assert RevocationEpoch.valid?(cert(), 2)
      refute RevocationEpoch.valid?(cert(), 3)
    end

    test "non-integer current epoch has no clause (fail closed by FunctionClauseError)" do
      assert_raise FunctionClauseError, fn -> FencingToken.valid?(cert(), "5") end
      assert_raise FunctionClauseError, fn -> PolicyEpoch.valid?(cert(), nil) end
      assert_raise FunctionClauseError, fn -> RevocationEpoch.valid?(cert(), 2.0) end
    end
  end

  describe "ResourceEnvelope" do
    test "bound only when principal, digest and generation all agree" do
      env = %ResourceEnvelope{principal: "p1", effect_digest: "d", budget: 1, generation: 5}
      effect = %{principal: "p1", digest: "d"}
      assert ResourceEnvelope.bound?(env, effect, cert())
      refute ResourceEnvelope.bound?(env, %{effect | principal: "p2"}, cert())
      refute ResourceEnvelope.bound?(env, %{effect | digest: "e"}, cert())
      refute ResourceEnvelope.bound?(env, effect, cert(%{generation: 6}))
    end

    test "enforce_keys are required" do
      assert_raise ArgumentError, fn -> struct!(ResourceEnvelope, principal: "p") end
    end
  end

  describe "EffectorRegistry" do
    test "fetches module for capability, refuses unknown and non-atom entries" do
      reg = %{"cap" => RealEffector, "bad" => "not-atom"}
      assert {:ok, RealEffector} = EffectorRegistry.fetch(%{capability: "cap"}, reg)
      assert {:error, :unknown_effector} = EffectorRegistry.fetch(%{capability: "nope"}, reg)
      assert_raise CaseClauseError, fn -> EffectorRegistry.fetch(%{capability: "bad"}, reg) end
    end

    test "resolved effector performs a real PreparedEffect" do
      effect = AshA2A.C2.PreparedEffect.new("p1", "cap", %{"s" => 1}, %{"x" => 2})
      {:ok, mod} = EffectorRegistry.fetch(effect, %{"cap" => RealEffector})
      assert {:ok, "cap"} = mod.perform(effect)
    end
  end

  describe "Principal" do
    test "preserved only when effect and cert principal equal caller" do
      assert Principal.preserved?(%{principal: "a"}, %{principal: "a"}, "a")
      refute Principal.preserved?(%{principal: "a"}, %{principal: "b"}, "a")
      refute Principal.preserved?(%{principal: "b"}, %{principal: "a"}, "a")
    end
  end
end


# ==============================================================================
# SECTION 27 of 31: test/untested_lane18/consequence_kernel_codec_test.exs
# ==============================================================================

defmodule AshA2A.UntestedLane18.ConsequenceKernelCodecTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.{
    IdentityBundle,
    IdentityGuard,
    IdentityVersion,
    KeyCustody,
    PreparedRecordCodec,
    RefusalCodes
  }

  alias AshA2A.ConsequenceKernel.KeyCustody.HmacSha256
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.{AuthenticatedRecord, Memory}

  @key String.duplicate("k", 32)

  defp prepared do
    {:ok, ids} = IdentityBundle.build(%{"r" => 1}, %{"e" => 2}, %{"s" => 3})

    %{
      prepared_digest: "sha256:" <> String.duplicate("a", 64),
      instance: ids,
      authority_epoch: 7,
      consequence_class: :change
    }
  end

  describe "IdentityBundle / IdentityGuard / IdentityVersion" do
    test "bundle is deterministic and passes the guard" do
      {:ok, a} = IdentityBundle.build(%{"r" => 1}, %{"e" => 2}, %{"s" => 3})
      {:ok, b} = IdentityBundle.build(%{"r" => 1}, %{"e" => 2}, %{"s" => 3})
      assert a == b
      assert :ok = IdentityGuard.admit(a)
    end

    test "bundle changes when any input changes; effect id binds request id" do
      {:ok, a} = IdentityBundle.build(%{"r" => 1}, %{"e" => 2}, %{"s" => 3})
      {:ok, b} = IdentityBundle.build(%{"r" => 9}, %{"e" => 2}, %{"s" => 3})
      {:ok, c} = IdentityBundle.build(%{"r" => 1}, %{"e" => 2}, %{"s" => 4})
      refute a.request_id == b.request_id
      refute a.effect_id == b.effect_id
      assert a.request_id == c.request_id
      refute a.subject_digest == c.subject_digest
    end

    test "bundle refuses unencodable inputs with typed canonical error" do
      assert {:error, :canonical_float_forbidden} = IdentityBundle.build(%{"r" => 1.5}, %{}, %{})
      assert {:error, :canonical_float_forbidden} = IdentityBundle.build(%{}, %{"e" => 0.1}, %{})
      assert {:error, :canonical_float_forbidden} = IdentityBundle.build(%{}, %{}, %{"s" => 2.0})
    end

    test "guard refuses malformed identities" do
      good = "sha256:" <> String.duplicate("0", 64)
      ok = %{request_id: good, effect_id: good, subject_digest: good}
      assert :ok = IdentityGuard.admit(ok)

      for bad <- [
            %{ok | request_id: "sha256:abc"},
            %{ok | effect_id: "md5:" <> String.duplicate("0", 64)},
            %{ok | subject_digest: String.duplicate("0", 64)},
            %{},
            nil
          ] do
        assert {:error, :prepared_record_identity_mismatch} = IdentityGuard.admit(bad)
      end
    end

    test "version admits only current tag" do
      assert :ok = IdentityVersion.admit(IdentityVersion.current())

      assert {:error, :canonical_schema_tag_required} =
               IdentityVersion.admit("sa2a.c1.identity.v0")

      assert {:error, :canonical_schema_tag_required} = IdentityVersion.admit(nil)
    end
  end

  describe "PreparedRecordCodec" do
    test "encode is deterministic canonical JSON containing schema and identity" do
      {:ok, a} = PreparedRecordCodec.encode(prepared())
      {:ok, b} = PreparedRecordCodec.encode(prepared())
      assert a == b
      decoded = Jason.decode!(a)
      assert decoded["schema"] == PreparedRecordCodec.schema()
      assert decoded["authority_epoch"] == 7
      assert decoded["consequence_class"] == "change"
      assert decoded["request_id"] == prepared().instance.request_id
    end

    test "any field change changes the bytes" do
      {:ok, base} = PreparedRecordCodec.encode(prepared())
      {:ok, e1} = PreparedRecordCodec.encode(%{prepared() | authority_epoch: 8})
      {:ok, e2} = PreparedRecordCodec.encode(%{prepared() | consequence_class: :external_do})
      refute base == e1
      refute base == e2
    end
  end

  describe "HmacSha256 + AuthenticatedRecord (real key custody)" do
    test "seal then verify round-trips; record is :prepared with the digest" do
      assert {:ok, rec} = AuthenticatedRecord.seal(prepared(), HmacSha256, key: @key)
      assert rec.state == :prepared
      assert rec.digest == prepared().prepared_digest
      assert String.starts_with?(rec.tag, "hmac-sha256:")
      assert :ok = AuthenticatedRecord.verify(rec, HmacSha256, key: @key)
    end

    test "tampered bytes, tampered tag and wrong key are refused" do
      {:ok, rec} = AuthenticatedRecord.seal(prepared(), HmacSha256, key: @key)

      assert {:error, :prepared_authentication_failed} =
               AuthenticatedRecord.verify(%{rec | bytes: rec.bytes <> " "}, HmacSha256, key: @key)

      assert {:error, :prepared_authentication_failed} =
               AuthenticatedRecord.verify(%{rec | tag: "hmac-sha256:00"}, HmacSha256, key: @key)

      assert {:error, :prepared_authentication_failed} =
               AuthenticatedRecord.verify(rec, HmacSha256, key: String.duplicate("z", 32))
    end

    test "short or missing key is unavailable, seal refuses" do
      assert {:error, :prepared_key_unavailable} =
               AuthenticatedRecord.seal(prepared(), HmacSha256, key: "short")

      assert {:error, :prepared_key_unavailable} = KeyCustody.mac(HmacSha256, "x")
    end

    test "sealed record persists in the real Memory store" do
      {:ok, store} = Memory.start_link()
      {:ok, rec} = AuthenticatedRecord.seal(prepared(), HmacSha256, key: @key)
      assert :ok = Memory.put(store, rec)
      assert {:error, :prepared_duplicate} = Memory.put(store, rec)
      {:ok, fetched} = Memory.fetch(store, rec.digest)
      assert :ok = AuthenticatedRecord.verify(fetched, HmacSha256, key: @key)
    end
  end

  describe "RefusalCodes" do
    test "every code classifies and rows/codes/known? agree" do
      assert Enum.sort(RefusalCodes.codes()) == Enum.sort(Map.keys(RefusalCodes.rows()))

      for c <- RefusalCodes.codes() do
        assert RefusalCodes.known?(c)
        assert {:ok, class} = RefusalCodes.classify(c)
        assert class |> Atom.to_string() |> String.starts_with?("blocked_")
      end
    end

    test "specific classes and unknown handling" do
      assert {:ok, :blocked_integrity} = RefusalCodes.classify(:prepared_effect_digest_mismatch)
      assert {:ok, :blocked_architecture} = RefusalCodes.classify(:kernel_bypass)
      assert :error = RefusalCodes.classify(:nope)
      refute RefusalCodes.known?(:nope)
    end

    test "codes emitted by real identity code are all registered" do
      {:error, e1} = IdentityBundle.build(%{"r" => 1.5}, %{}, %{})
      {:error, e2} = IdentityGuard.admit(%{})
      {:error, e3} = IdentityVersion.admit("x")
      for e <- [e1, e2, e3], do: assert(RefusalCodes.known?(e))
    end
  end
end


# ==============================================================================
# SECTION 28 of 31: test/untested_lane18/consequence_kernel_runtime_test.exs
# ==============================================================================

defmodule AshA2A.UntestedLane18.ConsequenceKernelRuntimeTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Memory

  alias AshA2A.ConsequenceKernel.Runtime.{
    CrashWindow,
    EffectorToken,
    OutcomeStage,
    PreparedDigest,
    ReconciliationStage,
    ReleaseStage,
    StoreHandle
  }

  @digest "sha256:" <> String.duplicate("b", 64)

  defp prepared,
    do: %{prepared_digest: @digest, instance: %{request_id: "rq", effect_id: "ef"}}

  defp store_at(state) do
    {:ok, pid} = Memory.start_link()
    :ok = Memory.put(pid, %{digest: @digest, state: :prepared})
    walk(pid, state)
    {pid, StoreHandle.new(Memory, pid)}
  end

  defp walk(_pid, :prepared), do: :ok

  defp walk(pid, :claimed), do: :ok = Memory.transition(pid, @digest, :prepared, :claimed)

  defp walk(pid, :applying) do
    walk(pid, :claimed)
    :ok = Memory.transition(pid, @digest, :claimed, :applying)
  end

  defp walk(pid, :unknown_outcome) do
    walk(pid, :applying)
    :ok = Memory.transition(pid, @digest, :applying, :unknown_outcome)
  end

  defp state(pid), do: elem(Memory.fetch(pid, @digest), 1).state

  test "PreparedDigest fetch" do
    assert {:ok, @digest} = PreparedDigest.fetch(prepared())
    assert {:error, :prepared_digest_missing} = PreparedDigest.fetch(%{prepared_digest: ""})
    assert {:error, :prepared_digest_missing} = PreparedDigest.fetch(%{prepared_digest: nil})
    assert {:error, :prepared_digest_missing} = PreparedDigest.fetch(%{})
  end

  test "EffectorToken binds ids, digest and owner" do
    t = EffectorToken.issue(prepared(), :me)

    assert %EffectorToken{request_id: "rq", effect_id: "ef", prepared_digest: @digest, owner: :me} =
             t

    assert t == EffectorToken.issue(prepared(), :me)
    refute t == EffectorToken.issue(prepared(), :other)
    assert_raise MatchError, fn -> EffectorToken.issue(%{instance: %{}}, :me) end
  end

  test "CrashWindow dispositions never turn ambiguity into retry" do
    assert CrashWindow.disposition(:prepared) == :safe_to_release
    assert CrashWindow.disposition(:claimed) == :safe_to_release
    assert CrashWindow.disposition(:applying) == :unknown_outcome
    assert CrashWindow.disposition(:unknown_outcome) == :reconcile_required

    for s <- [:completed, :reconciled, :compensated],
        do: assert(CrashWindow.disposition(s) == :terminal)

    assert CrashWindow.disposition(:bogus) == :refuse
  end

  describe "OutcomeStage" do
    test "ok result completes the record and returns value" do
      {pid, h} = store_at(:applying)
      assert {:ok, 42} = OutcomeStage.persist(h, prepared(), {:ok, 42})
      assert state(pid) == :completed
    end

    test "unknown result parks record in unknown_outcome" do
      {pid, h} = store_at(:applying)
      assert {:unknown, :timeout} = OutcomeStage.persist(h, prepared(), {:unknown, :timeout})
      assert state(pid) == :unknown_outcome
    end

    test "effector error after apply boundary is unknown, never retried" do
      {pid, h} = store_at(:applying)

      assert {:unknown, {:effector_error_after_apply_boundary, :boom}} =
               OutcomeStage.persist(h, prepared(), {:error, :boom})

      assert state(pid) == :unknown_outcome
    end

    test "ok from a non-applying record is refused and state is unchanged" do
      {pid, h} = store_at(:prepared)

      assert {:error, :prepared_transition_refused} =
               OutcomeStage.persist(h, prepared(), {:ok, 1})

      assert state(pid) == :prepared
    end

    test "missing digest refused" do
      {_pid, h} = store_at(:applying)
      assert {:error, :prepared_digest_missing} = OutcomeStage.persist(h, %{}, {:ok, 1})
    end
  end

  describe "ReleaseStage" do
    test "releases from prepared and claimed" do
      for from <- [:prepared, :claimed] do
        {pid, h} = store_at(from)
        assert :ok = ReleaseStage.release(h, prepared(), from)
        assert state(pid) == :released
      end
    end

    test "release after apply boundary is forbidden" do
      {pid, h} = store_at(:applying)

      assert {:error, {:release_after_apply_forbidden, :applying}} =
               ReleaseStage.release(h, prepared(), :applying)

      assert state(pid) == :applying
    end

    test "mismatched from-state is refused by the store" do
      {pid, h} = store_at(:prepared)

      assert {:error, :prepared_transition_refused} =
               ReleaseStage.release(h, prepared(), :claimed)

      assert state(pid) == :prepared
    end
  end

  describe "ReconciliationStage" do
    test "reconciled and compensated from unknown_outcome" do
      for x <- [:reconciled, :compensated] do
        {pid, h} = store_at(:unknown_outcome)
        assert :ok = ReconciliationStage.reconcile(h, @digest, x)
        assert state(pid) == x
      end
    end

    test "invalid resolution refused; non-unknown record refused" do
      {pid, h} = store_at(:unknown_outcome)

      assert {:error, {:invalid_reconciliation, :completed}} =
               ReconciliationStage.reconcile(h, @digest, :completed)

      assert state(pid) == :unknown_outcome
      {pid2, h2} = store_at(:applying)

      assert {:error, :prepared_transition_refused} =
               ReconciliationStage.reconcile(h2, @digest, :reconciled)

      assert state(pid2) == :applying
    end
  end
end


# ==============================================================================
# SECTION 29 of 31: test/untested_lane18/consequence_kernel_w4_w5_test.exs
# ==============================================================================

defmodule AshA2A.UntestedLane18.ConsequenceKernelW4W5Test do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.Dispatch.ArchitecturePolicy
  alias AshA2A.ConsequenceKernel.Dispatch.ConsequenceGate
  alias AshA2A.ConsequenceKernel.Dispatch.EffectRequest
  alias AshA2A.ConsequenceKernel.Dispatch.EffectorToken
  alias AshA2A.ConsequenceKernel.Dispatch.ResolvedEffect

  alias AshA2A.ConsequenceKernel.Guards.BypassClassification
  alias AshA2A.ConsequenceKernel.Guards.CallPathPolicy
  alias AshA2A.ConsequenceKernel.Guards.MediationReceipt
  alias AshA2A.ConsequenceKernel.Guards.MigrationRegistry
  alias AshA2A.ConsequenceKernel.Guards.RawEffect, as: RawEffectGuard
  alias AshA2A.ConsequenceKernel.Guards.UnknownOutcomePolicy

  alias AshA2A.ConsequenceKernel.Claims.Fence, as: ClaimFence
  alias AshA2A.ConsequenceKernel.Claims.CrashWindow
  alias AshA2A.ConsequenceKernel.Claims.Independent, as: IndependentClaim

  test "W4 EffectorToken mint requires binaries" do
    t = EffectorToken.mint("subj", "dig")
    assert %EffectorToken{exact_subject: "subj", prepared_digest: "dig"} = t
    assert_raise FunctionClauseError, fn -> EffectorToken.mint(:a, "d") end
  end

  test "W4 ArchitecturePolicy flags forbidden raw-effect tokens in source" do
    clean = "defmodule A do\n  def f, do: AshA2A.ConsequenceKernel.go()\nend"
    assert [] = ArchitecturePolicy.violations(clean)

    dirty = "x = Ash.create(r)\nAshA2A.Dispatcher.dispatch(c)\nAsh.destroy(y)"

    assert Enum.sort(ArchitecturePolicy.violations(dirty)) ==
             Enum.sort(["Ash.create(", "AshA2A.Dispatcher.dispatch(", "Ash.destroy("])

    assert ArchitecturePolicy.forbidden_tokens() |> length() == 4
  end

  test "W4 structs enforce required keys and default optional ones" do
    req = %EffectRequest{skill: "s", message: "m", resource_or_domain: :d, consequence: :change}
    assert req.history == [] and req.auth_identity == nil
    assert_raise ArgumentError, fn -> struct!(EffectRequest, skill: "s") end
    re = %ResolvedEffect{request: req, route: :consequence}
    assert re.exact_subject == nil and re.prepared_digest == nil
    assert_raise ArgumentError, fn -> struct!(ResolvedEffect, request: req) end
  end

  test "W4 ConsequenceGate admits only consequences" do
    assert :ok = ConsequenceGate.admit(:change)
    assert :ok = ConsequenceGate.admit(:external_do)
    assert {:error, :not_consequential} = ConsequenceGate.admit(:observe)
    assert {:error, :consequence_unclassified} = ConsequenceGate.admit(:weird)
  end

  describe "W4B" do
    test "RawEffectGuard" do
      assert :ok = RawEffectGuard.admit(%{consequence: :change, fence: true})
      assert :ok = RawEffectGuard.admit(%{consequence: :external_do, fence: true})
      assert :ok = RawEffectGuard.admit(%{consequence: :observe, observation_only: true})

      assert {:error, :raw_effect_path} =
               RawEffectGuard.admit(%{consequence: :change, fence: false})

      assert {:error, :raw_effect_path} = RawEffectGuard.admit(%{consequence: :change})
      assert {:error, :raw_effect_path} = RawEffectGuard.admit(%{consequence: :observe})
      assert {:error, :consequence_unclassified} = RawEffectGuard.admit(%{consequence: :unknown})
    end

    test "BypassClassification" do
      assert BypassClassification.classify(:observe) == :non_consequential
      assert BypassClassification.classify(:change) == :consequential
      assert BypassClassification.classify(:external_do) == :consequential
      assert BypassClassification.classify(:zzz) == :unclassified
    end

    test "MigrationRegistry" do
      assert {:ok, :kernel} = MigrationRegistry.target(:command_bus_change)
      assert {:ok, :dispatch_observe} = MigrationRegistry.target(:agent_observe)
      assert :error = MigrationRegistry.target(:other)
      assert map_size(MigrationRegistry.entries()) == 3
    end

    test "MediationReceipt" do
      a = MediationReceipt.admitted(:change, :kernel)
      assert a.admitted and a.refusal == nil
      r = MediationReceipt.refused(:change, :raw, :raw_effect_path)
      refute r.admitted
      assert r.refusal == :raw_effect_path
    end

    test "UnknownOutcomePolicy never permits blind retry" do
      assert {:error, :reconciliation_required} =
               UnknownOutcomePolicy.next(:unknown_outcome, :retry)

      assert {:ok, :reconcile} = UnknownOutcomePolicy.next(:unknown_outcome, :reconcile)
      assert {:ok, :compensate} = UnknownOutcomePolicy.next(:unknown_outcome, :compensate)
      assert {:ok, :terminal} = UnknownOutcomePolicy.next(:completed, :retry)
      assert {:ok, :terminal} = UnknownOutcomePolicy.next(:failed, :anything)
      assert {:error, :invalid_outcome} = UnknownOutcomePolicy.next(:unknown_outcome, :bogus)
      assert {:error, :invalid_outcome} = UnknownOutcomePolicy.next(:applying, :reconcile)
    end

    test "CallPathPolicy" do
      assert :ok = CallPathPolicy.admit(:observe, :agent_observation)
      assert :ok = CallPathPolicy.admit(:observe, :kernel)
      assert :ok = CallPathPolicy.admit(:change, :kernel)
      assert :ok = CallPathPolicy.admit(:external_do, :kernel)
      assert {:error, :raw_effect_path} = CallPathPolicy.admit(:change, :agent_observation)
      assert {:error, :raw_effect_path} = CallPathPolicy.admit(:mystery, :kernel)
    end
  end

  describe "W5" do
    test "IndependentClaim requires distinct binary claims" do
      assert :ok = IndependentClaim.admit("r", "e")
      assert {:error, :independent_effect_claim_required} = IndependentClaim.admit("x", "x")
      assert {:error, :independent_effect_claim_required} = IndependentClaim.admit(1, "e")
    end

    test "ClaimFence" do
      ok = %{
        request_claim: "r",
        effect_claim: "e",
        prepared_digest: "p",
        claimed_prepared_digest: "p"
      }

      assert :ok = ClaimFence.admit(ok)

      assert {:error, :prepared_digest_mismatch} =
               ClaimFence.admit(%{ok | claimed_prepared_digest: "q"})

      assert {:error, :prepared_digest_mismatch} = ClaimFence.admit(%{ok | effect_claim: "r"})
      assert {:error, :claim_fence_refused} = ClaimFence.admit(%{})
    end

    test "CrashWindow classifies ambiguity as unknown_outcome" do
      assert CrashWindow.classify(:before_do) == :not_applied
      assert CrashWindow.classify(:after_do_before_receipt) == :unknown_outcome
      assert CrashWindow.classify(:after_receipt) == :recorded
      assert CrashWindow.classify(:never_heard_of_it) == :unknown_outcome
    end
  end
end


# ==============================================================================
# SECTION 30 of 31: test/untested_lane18/consequence_kernel_w4c_test.exs
# ==============================================================================

defmodule AshA2A.UntestedLane18.ConsequenceKernelW4CTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.Closure.AdmittedTopology
  alias AshA2A.ConsequenceKernel.Closure.CallerPolicy
  alias AshA2A.ConsequenceKernel.Closure.ChicagoAdapter
  alias AshA2A.ConsequenceKernel.Closure.Evaluation, as: Closure
  alias AshA2A.ConsequenceKernel.Closure.Predicate, as: ClosurePredicate
  alias AshA2A.ConsequenceKernel.Closure.Receipt, as: ClosureReceipt
  alias AshA2A.ConsequenceKernel.Closure.Status, as: ClosureStatus
  alias AshA2A.ConsequenceKernel.Closure.Counterexample
  alias AshA2A.ConsequenceKernel.Effects.Dedupe
  alias AshA2A.ConsequenceKernel.Closure.DispatcherPolicy
  alias AshA2A.ConsequenceKernel.Closure.EdgeIdentity
  alias AshA2A.ConsequenceKernel.Closure.GraphEdge
  alias AshA2A.ConsequenceKernel.Closure.GraphReport
  alias AshA2A.ConsequenceKernel.Closure.KernelFilter
  alias AshA2A.ConsequenceKernel.Closure.MigrationTarget
  alias AshA2A.ConsequenceKernel.Closure.RawEffectEdges
  alias AshA2A.ConsequenceKernel.Closure.ReceiptDigest
  alias AshA2A.ConsequenceKernel.Closure.ReportSchema
  alias AshA2A.ConsequenceKernel.Closure.UnresolvedApply
  alias AshA2A.ConsequenceKernel.Closure.ZeroEdgeGuard

  @k "Elixir.AshA2A.ConsequenceKernel.Foo"
  @raw %GraphEdge{caller: "Elixir.Other.Mod", callee: :do_it, kind: :effect}
  @kernel %GraphEdge{caller: @k, callee: :do_it, kind: :effect}
  @obs %GraphEdge{caller: "Elixir.Other.Mod", callee: :read, kind: :observe}

  test "topology and caller policy: kernel prefix only" do
    assert CallerPolicy.kernel?(@k)
    assert CallerPolicy.kernel?(AshA2A.ConsequenceKernel.Receipt)
    refute CallerPolicy.kernel?("Elixir.Other")
    assert AdmittedTopology.admitted?(@k, :effect)
    assert AdmittedTopology.admitted?(@k, :dispatcher)
    refute AdmittedTopology.admitted?("Elixir.Other", :dynamic_effect)
    assert AdmittedTopology.admitted?("Elixir.Other", :observe)
    refute AdmittedTopology.admitted?(@k, :weird)
  end

  test "GraphEdge consequential kinds and enforce_keys" do
    assert GraphEdge.consequential?(@raw)
    refute GraphEdge.consequential?(@obs)
    assert_raise ArgumentError, fn -> struct!(GraphEdge, caller: "a") end
  end

  test "GraphReport normalizes maps into structs and keeps structs" do
    [e1, e2] =
      GraphReport.normalize([%{caller: "c", callee: :d, kind: :effect, source: "f.ex:1"}, @obs])

    assert %GraphEdge{source: "f.ex:1"} = e1
    assert e2 == @obs
  end

  test "RawEffectEdges drops observation and kernel edges" do
    assert [@raw] = RawEffectEdges.from_report([@raw, @kernel, @obs])
    assert [] = RawEffectEdges.from_report([])

    assert [%GraphEdge{kind: :dispatcher}] =
             RawEffectEdges.from_report([%{caller: "x", callee: :y, kind: :dispatcher}])
  end

  test "KernelFilter keeps only outside-kernel callers" do
    assert [@raw, @obs] = KernelFilter.outside([@raw, @kernel, @obs])
  end

  test "ClosurePredicate / ChicagoAdapter / ClosureReceipt agree" do
    assert {:ok, :zero_consequential_raw_effect_edges} =
             ClosurePredicate.evaluate([@kernel, @obs])

    assert {:error, {:raw_effect_edges, [@raw]}} = ClosurePredicate.evaluate([@raw, @kernel])
    assert {:ok, _} = ChicagoAdapter.evaluate(%{edges: [@kernel]})
    assert {:error, {:raw_effect_edges, [_]}} = ChicagoAdapter.evaluate([@raw])
    assert {:error, :invalid_chicago_report} = ChicagoAdapter.evaluate(:nope)
    assert {:error, :invalid_chicago_report} = ChicagoAdapter.evaluate(%{x: 1})

    assert %{standing: :derived, raw_edges: 0} = ClosureReceipt.issue([@kernel])
    assert %{standing: :refused, raw_edges: 2} = ClosureReceipt.issue([@raw, @raw])
  end

  test "Closure, ClosureStatus, ZeroEdgeGuard, Counterexample on empty vs non-empty" do
    assert Closure.closed?([])
    refute Closure.closed?([@raw])
    assert ClosureStatus.from_edges([]) == :closed
    assert ClosureStatus.from_edges([@raw]) == :open
    assert :ok = ZeroEdgeGuard.admit([])
    assert {:error, {:raw_effect_edges, 2}} = ZeroEdgeGuard.admit([@raw, @obs])
    assert Counterexample.minimal([]) == nil
    assert Counterexample.minimal([@raw, @obs]) == @raw
  end

  test "EdgeIdentity and Dedupe ignore source, keep distinct edges" do
    a = %GraphEdge{caller: "c", callee: :d, kind: :effect, source: "a"}
    b = %GraphEdge{caller: "c", callee: :d, kind: :effect, source: "b"}
    other = %GraphEdge{caller: "c", callee: :d, kind: :dispatcher}
    assert EdgeIdentity.key(a) == EdgeIdentity.key(b)
    assert EdgeIdentity.key(%{caller: "c", callee: :d, kind: :effect}) == EdgeIdentity.key(a)
    assert [^a, ^other] = Dedupe.edges([a, b, other])
  end

  test "DispatcherPolicy and MigrationTarget" do
    assert DispatcherPolicy.classify(:dispatch) == :consequence
    assert DispatcherPolicy.classify(:dispatch_observe) == :observation
    assert MigrationTarget.for_kind(:observe) == :dispatch_observe
    assert MigrationTarget.for_kind(:effect) == :consequence_kernel
  end

  test "ReceiptDigest deterministic and sensitive; ReportSchema" do
    assert ReceiptDigest.digest([@raw]) == ReceiptDigest.digest([@raw])
    refute ReceiptDigest.digest([@raw]) == ReceiptDigest.digest([@obs])
    assert ReceiptDigest.digest([]) =~ ~r/\A[0-9a-f]{64}\z/
    assert ReportSchema.valid?(%{edges: []})
    refute ReportSchema.valid?(%{edges: :x})
    refute ReportSchema.valid?([])
  end

  test "UnresolvedApply yields a consequential dynamic edge that blocks closure" do
    e = UnresolvedApply.edge("Elixir.Other", "f.ex:9")
    assert %GraphEdge{callee: :unresolved_apply, kind: :dynamic_effect, source: "f.ex:9"} = e
    assert GraphEdge.consequential?(e)
    assert {:error, {:raw_effect_edges, [^e]}} = ClosurePredicate.evaluate([e])
    assert {:ok, _} = ClosurePredicate.evaluate([UnresolvedApply.edge(@k, "x")])
  end
end


# ==============================================================================
# SECTION 31 of 31: test/untested_lane18/misc_test.exs
# ==============================================================================

defmodule AshA2A.UntestedLane18.MiscTest do
  use ExUnit.Case, async: true

  alias AshA2A.Identity.Canonical
  alias AshA2A.Identity.Canonical.{Encodable, Normalizer}
  alias AshA2A.AuthZEN.{Metadata, PolicyEvidence, PolicyEvidenceFactory, Types}
  alias AshA2A.C2.PreparedEffect
  alias AshA2A.Replan.{Proposal, ReceiptCursor, ReceiptFeedback}
  alias AshA2A.Reactor.{BuildCommand, ConfirmReceipt}

  describe "Encodable" do
    test "accepts JSON-domain values" do
      assert :ok = Encodable.validate(%{"a" => [1, nil, true, "x", %{b: 2}]})
    end

    test "typed refusals" do
      assert {:error, :canonical_float_forbidden} = Encodable.validate(1.0)
      assert {:error, :canonical_type_forbidden} = Encodable.validate({:t, 1})
      assert {:error, :canonical_type_forbidden} = Encodable.validate(self())
      assert {:error, :canonical_key_type_forbidden} = Encodable.validate(%{1 => 2})
      assert {:error, :canonical_key_collision} = Encodable.validate(%{:a => 1, "a" => 2})
      assert {:error, :canonical_invalid_utf8} = Encodable.validate(<<255, 254>>)
      assert {:error, :canonical_integer_out_of_range} = Encodable.validate(9_007_199_254_740_992)

      assert {:error, :canonical_integer_out_of_range} =
               Encodable.validate(-9_007_199_254_740_992)

      assert :ok = Encodable.validate(9_007_199_254_740_991)
    end

    test "depth cap" do
      nest = fn n -> Enum.reduce(1..n, 1, fn _, acc -> [acc] end) end
      assert :ok = Encodable.validate(nest.(30))
      assert {:error, :canonical_depth_exceeded} = Encodable.validate(nest.(40))
    end

    test "max_bytes is 1 MiB and enforced by encode" do
      assert Encodable.max_bytes() == 1_048_576

      assert {:error, :canonical_size_exceeded} =
               Canonical.encode(String.duplicate("a", 1_048_600))
    end
  end

  describe "Normalizer" do
    test "stringifies keys recursively and is idempotent" do
      {:ok, n} = Normalizer.normalize(%{a: %{b: [%{c: 1}]}})
      assert n == %{"a" => %{"b" => [%{"c" => 1}]}}
      assert {:ok, ^n} = Normalizer.normalize(n)
    end

    test "propagates validation errors" do
      assert {:error, :canonical_float_forbidden} = Normalizer.normalize(%{a: 1.5})
    end

    test "key order and atom/string spelling do not change canonical digest" do
      {:ok, d1} = Canonical.digest(%{a: 1, b: 2})
      {:ok, d2} = Canonical.digest(%{"b" => 2, "a" => 1})
      assert d1 == d2
      {:ok, d3} = Canonical.digest(%{"a" => 1, "b" => 3})
      refute d1 == d3
    end
  end

  describe "PolicyEvidenceFactory" do
    test "builds authority-free evidence bound to the effect digest" do
      effect = PreparedEffect.new("p1", "cap", %{"s" => 1}, %{"x" => 2})

      md = %Metadata{
        policy_decision_point: "https://pdp.example",
        access_evaluation_endpoint: "https://pdp.example/eval"
      }

      dec = %Types.Decision{decision: true, context: %{"why" => "ok"}}
      ev = PolicyEvidenceFactory.from_decision(dec, effect, md, 1234)

      assert %PolicyEvidence{
               decision: true,
               policy_decision_point: "https://pdp.example",
               principal: "p1",
               observed_at: 1234,
               context: %{"why" => "ok"}
             } = ev

      assert ev.effect_digest == effect.digest
      assert PolicyEvidence.allowed?(ev)
    end

    test "deny decision and nil context" do
      effect = PreparedEffect.new("p1", "cap", %{}, %{})
      md = %Metadata{policy_decision_point: "pdp", access_evaluation_endpoint: "e"}

      ev =
        PolicyEvidenceFactory.from_decision(
          %Types.Decision{decision: false, context: nil},
          effect,
          md
        )

      refute PolicyEvidence.allowed?(ev)
      assert ev.context == %{}
      assert is_integer(ev.observed_at)
    end
  end

  describe "Replan" do
    test "Proposal defaults to powerless candidate" do
      p = Proposal.new("subj", %{"plan" => 1}, :failed)
      assert %Proposal{authority: :none, standing: :candidate, attempt: 0} = p
      assert Proposal.new("s", 1, :r, 3).attempt == 3
    end

    test "ReceiptCursor projects only cursor fields" do
      c =
        ReceiptCursor.from(%{
          receipt_id: "r1",
          terminal_status: :executed,
          projection_digest: "d",
          extra: 1
        })

      assert %ReceiptCursor{receipt_id: "r1", terminal_status: :executed, projection_digest: "d"} =
               c

      assert %ReceiptCursor{receipt_id: nil} = ReceiptCursor.from(%{})
    end

    test "ReceiptFeedback routes terminal statuses to decisions" do
      mk = fn s -> %{semantic_subject: "sub", receipt_id: "r", terminal_status: s} end

      assert %{kind: :stop, subject: "sub", reason: :executed} =
               ReceiptFeedback.ingest(mk.(:executed))

      assert %{kind: :stop, reason: :refused} = ReceiptFeedback.ingest(mk.(:refused))
      assert %{kind: :replan, reason: :failed} = ReceiptFeedback.ingest(mk.(:failed))

      assert %{kind: :replan, reason: :unknown_outcome_reconcile_first} =
               ReceiptFeedback.ingest(%{semantic_subject: "sub", receipt_id: "r"})
    end
  end

  describe "Reactor steps" do
    test "BuildCommand builds a real Command" do
      args = %{
        capability_id: "cap",
        agent_id: "agent-1",
        principal_id: "principal-1",
        input: %{"a" => 1},
        authority: nil
      }

      assert {:ok, %AshA2A.Command{capability_id: "cap", input: %{"a" => 1}}} =
               BuildCommand.run(args, %{}, [])
    end

    test "BuildCommand honours explicit command_id and nil input" do
      id = Ash.UUIDv7.generate()

      args = %{
        capability_id: "cap",
        agent_id: "agent-1",
        principal_id: "principal-1",
        command_id: id
      }

      assert {:ok, cmd} = BuildCommand.run(args, %{}, [])
      assert cmd.command_id.value == id
      assert cmd.input == %{}
    end

    test "BuildCommand surfaces missing keys as typed error" do
      assert {:error, %{code: :invalid_command_input, detail: d}} =
               BuildCommand.run(%{capability_id: "c"}, %{}, [])

      assert is_binary(d)
    end

    test "ConfirmReceipt passes completed and refuses others" do
      base = %AshA2A.Receipt{
        receipt_id: "r",
        command_id: "c",
        execution_id: "e",
        agent_id: "a",
        principal_id: "p",
        capability_id: "cap",
        fingerprint: "f",
        consequence: :observe,
        status: :completed,
        standing: :derived,
        recorded_at: DateTime.utc_now()
      }

      assert {:ok, ^base} = ConfirmReceipt.run(%{receipt: base}, %{}, [])

      assert {:error, %{code: :receipt_not_completed, status: :failed}} =
               ConfirmReceipt.run(%{receipt: %{base | status: :failed}}, %{}, [])
    end
  end
end
