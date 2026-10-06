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
