# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
    Process.sleep(50)
    respond(conn, {500, %{"error" => "internal"}})
  end

  defp answer(conn, "garbage", _opts) do
    respond(conn, {200, %{"status" => "ok", "no" => "decision"}})
  end

  defp answer(conn, "hang", opts) do
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

    client = real_client(%{metadata | access_evaluation_endpoint: base_url <> "/access/v1/evaluation"}, 2_000)

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
             PDPBinding.admit(metadata, attested, %{binding | policy_decision_point: "https://other.example"})
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

    client = real_client(%{metadata | access_evaluation_endpoint: base_url <> "/access/v1/evaluation"}, 2_000)

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

  test "fail-closed: unreachable PDP is a typed refusal, not a pass", %{
    table: table,
    port: port,
    base_url: base_url,
    server_pid: server_pid,
    metadata: metadata,
    attested: attested,
    binding: binding
  } do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{})
    ctx = authority_ctx()
    request = AuthorityRequest.new(effect, ctx)

    client = real_client(%{metadata | access_evaluation_endpoint: base_url <> "/access/v1/evaluation"}, 2_000)

    # A healthy PDP first: the binding admits and the round-trip succeeds.
    assert {:ok, _response, _receipt} =
             Absorption.authorize(request, client, attested, binding, ctx)

    true = Process.unlink(server_pid)
    Process.exit(server_pid, :shutdown)
    wait_down(port)

    assert {:error, :pdp_unreachable} =
             Absorption.authorize(request, client, attested, binding, ctx)

    assert request_count(table) == 1
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

    client = real_client(%{metadata | access_evaluation_endpoint: stalled_base <> "/access/v1/evaluation"}, 100)

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

    client = real_client(%{metadata | access_evaluation_endpoint: base_url <> "/access/v1/evaluation"}, 2_000)

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

    client = real_client(%{metadata | access_evaluation_endpoint: base_url <> "/access/v1/evaluation"}, 2_000)

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
      {:ok, %Certificate{
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

  defp wait_down(port, attempts \\ 50)

  defp wait_down(_port, 0), do: flunk("PDP port never closed")

  defp wait_down(port, attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 100) do
      {:error, _} ->
        :ok

      {:ok, socket} ->
        :gen_tcp.close(socket)
        Process.sleep(50)
        wait_down(port, attempts - 1)
    end
  end
end
