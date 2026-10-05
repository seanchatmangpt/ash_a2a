# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.Pipeline do
  @moduledoc """
  The ARD v26.10.4 §2 inbound execution pipeline: one configurable, ordered
  plug composing the landed enterprise gates around any existing ash_a2a
  transport plug (mounted before it, via `:inner`). The pipeline *wires* the
  gates; it never modifies them.

  Fixed order (ARD §2): SVID validation -> AuthZEN DecisionGate (incl.
  monotonic narrowing for delegated tasks) -> DLPFilter inbound ->
  DataResidency -> FinOps budget gate -> dispatch (inner plug) -> DLPFilter
  outbound -> CMEK envelope -> Affidavit receipt -> OcelForwarder.

  Fail-closed: any enabled stage's refusal halts with THAT stage's typed
  wire error; later stages and dispatch never run. No enabled stage is
  silently skipped (a missing budget-gate module refuses 503; an unavailable
  affidavit engine refuses the response 500; a KMS-less CMEK stage refuses
  the response with the KeyManager's typed refusal). The order is
  structural — config toggles stages, never reorders them. Disabled stages
  pass through untouched.

  Each stage key takes `false`/absent (off), `true` (on with defaults), or
  its options; `config :ash_a2a, AshA2A.Enterprise.Pipeline, svid: [...],
  ...` is the fallback (plug opts win).

  Stage options:

    * `:inner` — `{plug, opts}` or module (default `AshA2A.A2ATransport.Plug`
      with remaining opts forwarded).
    * `:svid` — `AshA2A.SPIFFE.SvidValidator` opts (`:trust_domain`,
      `:bundle_source`, `:assign`); the real plug answers its own 401s.
    * `:authzen` — requires `:client` (`AshA2A.AuthZEN.Client`); optional
      `:expected_pdp` (default: the client metadata's policy_decision_point)
      and `:principal` (a `conn -> binary | nil` resolver; default: the
      `:spiffe_identity` assign stamped by the SVID stage).
    * `:dlp` — `AshA2A.Security.DLPFilter` opts; drives both directions.
    * `:residency` — `AshA2A.Security.DataResidency.admit/2` opts.
    * `:budget` — `[store: AshA2A.FinOps.BudgetStore, estimated_tokens: n]`
      (the landed FR-05 gate: `AshA2A.FinOps.BudgetEnforcer.authorize/3`
      over the request view `params ∪ request headers`) or `{module, opts}`
      implementing `check(params, opts) :: :ok | {:error, code, detail}`.
    * `:cmek` — `AshA2A.Security.KeyManager.encrypt/2` opts; requires
      `config :ash_a2a, :cmek_kms_client` — fail-closed when absent.
    * `:affidavit` — no options; refuses the response fail-closed when the
      `AshAffidavit` engine is unavailable.
    * `:ocel` — attaches `AshA2A.Telemetry.OcelForwarder` at init so real
      dispatch telemetry forwards to `config :ash_a2a, :ocel_ingest_url`.

  Wire shape: requests without JSON-RPC params (e.g. GET agent card) pass
  the authzen/residency/budget stages. Outbound stages run in a
  before-send hook on 2xx JSON responses (DLP outbound also on non-2xx
  JSON); a refused outbound stage REPLACES the response with its typed 500.
  The request body is read once, DLP-rewritten, and re-served to the inner
  plug through an adapter shim, so dispatch sees tokenized params.

  Telemetry: `[:ash_a2a, :enterprise, :pipeline, :completed]`
  `%{duration_ns}, %{stages, dlp_findings, cmek, affidavit}` and
  `[:ash_a2a, :enterprise, :pipeline, :refused]` `%{duration_ns},
  %{stage, code}`.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshA2A.AuthZEN.{Client, DecisionGate, Monotonic, PolicyEvidence, Types}
  alias AshA2A.C2.PreparedEffect
  alias AshA2A.Evidence.Affidavit
  alias AshA2A.Security.{DataResidency, DLPFilter, KeyManager}
  alias AshA2A.SPIFFE.SvidValidator
  alias AshA2A.Telemetry.OcelForwarder

  @pipeline_keys [:inner, :svid, :authzen, :dlp, :residency, :budget, :cmek, :affidavit, :ocel]
  @assign :ash_a2a_enterprise
  @affidavit_header "x-a2a-affidavit-digest"
  @max_body 64_000_000
  @inbound_order [:svid, :authzen, :dlp, :residency, :budget]

  # -- plug callbacks -----------------------------------------------------------

  @impl Plug
  def init(opts) when is_list(opts) do
    app = Application.get_env(:ash_a2a, __MODULE__, [])

    # The OcelForwarder is wired at init, not per request: real dispatch
    # telemetry fires inside the inner plug, BEFORE any before-send hook of
    # the same request could attach it.
    ocel = kw_cfg(value(:ocel, opts, app))
    if ocel, do: :ok = OcelForwarder.attach!()

    %{
      svid: svid_cfg(value(:svid, opts, app)),
      authzen: authzen_cfg(value(:authzen, opts, app)),
      dlp: kw_cfg(value(:dlp, opts, app)),
      residency: kw_cfg(value(:residency, opts, app)),
      budget: budget_cfg(value(:budget, opts, app)),
      cmek: kw_cfg(value(:cmek, opts, app)),
      affidavit: kw_cfg(value(:affidavit, opts, app)),
      ocel: ocel,
      inner: inner_cfg(opts)
    }
  end

  def init(other) do
    raise ArgumentError,
          "AshA2A.Enterprise.Pipeline.init expects a keyword list, got #{inspect(other)}"
  end

  @impl Plug
  def call(conn, cfg) do
    started = System.monotonic_time()

    case collect_request(conn) do
      {:refuse, status, body} ->
        emit_refused(started, :pipeline, body["error"])
        refuse(conn, status, body)

      {conn, request} ->
        case inbound(conn, request, cfg) do
          {:answered, conn} ->
            conn

          {:refuse, stage, status, body} ->
            emit_refused(started, stage, body["error"])
            refuse(conn, status, body)

          {:cont, conn, ctx} ->
            conn
            |> register_before_send(fn c -> finish(c, ctx, cfg, started) end)
            |> call_inner(cfg.inner)
        end
    end
  end

  defp call_inner(conn, {mod, state}), do: mod.call(conn, state)

  # -- stage configuration --------------------------------------------------------

  defp value(key, opts, app) do
    case Keyword.fetch(opts, key) do
      {:ok, v} -> v
      :error -> Keyword.get(app, key, false)
    end
  rescue
    ArgumentError -> Keyword.get(app, key, false)
  end

  defp svid_cfg(false), do: nil
  defp svid_cfg(nil), do: nil
  defp svid_cfg(true), do: svid_cfg([])

  defp svid_cfg(opts) when is_list(opts), do: %{validator: SvidValidator.init(opts)}
  defp svid_cfg(other), do: bad_stage!(:svid, other)

  defp authzen_cfg(false), do: nil
  defp authzen_cfg(nil), do: nil
  defp authzen_cfg(true), do: raise(ArgumentError, "authzen stage requires :client")

  defp authzen_cfg(opts) when is_list(opts) do
    client = Keyword.fetch!(opts, :client)

    unless match?(%Client{}, client) do
      raise ArgumentError,
            "authzen stage :client must be an AshA2A.AuthZEN.Client, got #{inspect(client)}"
    end

    %{
      client: client,
      expected_pdp: Keyword.get(opts, :expected_pdp, client.metadata.policy_decision_point),
      principal: Keyword.get(opts, :principal)
    }
  end

  defp authzen_cfg(other), do: bad_stage!(:authzen, other)

  defp kw_cfg(false), do: nil
  defp kw_cfg(nil), do: nil
  defp kw_cfg(true), do: []
  defp kw_cfg(opts) when is_list(opts), do: opts

  defp budget_cfg(false), do: nil
  defp budget_cfg(nil), do: nil

  defp budget_cfg(true) do
    raise ArgumentError, "budget stage requires :store or {module, opts}"
  end

  defp budget_cfg(opts) when is_list(opts) do
    unless Keyword.has_key?(opts, :store) do
      raise ArgumentError,
            "budget stage keyword config requires :store (AshA2A.FinOps.BudgetStore)"
    end

    {:finops, opts}
  end

  defp budget_cfg(mod) when is_atom(mod), do: {mod, []}
  defp budget_cfg({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
  defp budget_cfg(other), do: bad_stage!(:budget, other)

  defp inner_cfg(opts) do
    case Keyword.get(opts, :inner) do
      nil ->
        {AshA2A.A2ATransport.Plug,
         AshA2A.A2ATransport.Plug.init(Keyword.drop(opts, @pipeline_keys))}

      {mod, inner_opts} when is_atom(mod) ->
        {mod, mod.init(inner_opts)}

      mod when is_atom(mod) ->
        {mod, mod.init([])}
    end
  end

  defp bad_stage!(stage, other) do
    raise ArgumentError,
          "AshA2A.Enterprise.Pipeline stage #{inspect(stage)}: bad configuration #{inspect(other)}"
  end

  # -- request collection ---------------------------------------------------------

  defp collect_request(conn) do
    cond do
      conn.method != "POST" ->
        {conn, %{envelope: nil, params: nil, method: conn.method}}

      match?(%Plug.Conn.Unfetched{}, conn.body_params) ->
        case read_bounded(conn) do
          {:ok, body, conn} ->
            case Jason.decode(body) do
              {:ok, %{} = envelope} ->
                {serve(conn, body),
                 %{
                   envelope: envelope,
                   params: envelope["params"],
                   body: body,
                   method: conn.method
                 }}

              _ ->
                # Undecodable: re-serve the original bytes; the inner
                # transport answers the canonical -32700 parse error.
                {serve(conn, body),
                 %{envelope: nil, params: nil, body: body, method: conn.method}}
            end

          {:error, :body_too_large} ->
            {:refuse, 413,
             %{
               "error" => "refused_pipeline_body_too_large",
               "stage" => "pipeline",
               "detail" => "request body exceeds #{@max_body} bytes; refusing fail-closed"
             }}

          {:error, {:unreadable, reason}} ->
            {:refuse, 400,
             %{
               "error" => "refused_pipeline_body_unreadable",
               "stage" => "pipeline",
               "detail" => inspect(reason)
             }}
        end

      :else ->
        # An upstream parser already decoded the body.
        params = if is_map(conn.body_params), do: conn.body_params, else: nil
        {conn, %{envelope: conn.body_params, params: params, body: nil, method: conn.method}}
    end
  end

  defp read_bounded(conn, acc \\ "", size \\ 0) do
    case read_body(conn, length: 1_000_000, read_length: 64_000) do
      {:ok, chunk, conn} ->
        {:ok, acc <> chunk, conn}

      {:more, chunk, conn} ->
        if size + byte_size(chunk) > @max_body do
          {:error, :body_too_large}
        else
          read_bounded(conn, acc <> chunk, size + byte_size(chunk))
        end

      {:error, reason} ->
        # Fail-closed: a body we cannot fully read is a refusal, not a pass.
        {:error, {:unreadable, reason}}
    end
  end

  defp serve(conn, body) do
    %{conn | adapter: __MODULE__.BodyAdapter.init(conn.adapter, body)}
  end

  # -- inbound chain ---------------------------------------------------------------

  defp inbound(conn, request, cfg) do
    ctx = %{request: request, trace: [], findings: [], authzen: nil, residency: nil, budget: nil}

    Enum.reduce_while(@inbound_order, {:cont, conn, ctx}, fn stage, {:cont, conn, ctx} ->
      case run_stage(stage, conn, ctx, cfg) do
        {:cont, conn, ctx} -> {:cont, {:cont, conn, ctx}}
        {:answered, conn} -> {:halt, {:answered, conn}}
        {:refuse, status, body} -> {:halt, {:refuse, stage, status, body}}
      end
    end)
  end

  # SVID is the only stage that receives (and may answer) the conn.
  defp run_stage(:svid, conn, ctx, %{svid: nil}), do: {:cont, conn, ctx}

  defp run_stage(:svid, conn, ctx, %{svid: %{validator: validator}}) do
    case SvidValidator.call(conn, validator) do
      %{halted: true} = answered -> {:answered, answered}
      conn -> {:cont, conn, ctx}
    end
  end

  defp run_stage(:authzen, conn, ctx, %{authzen: nil}), do: {:cont, conn, ctx}

  defp run_stage(:authzen, conn, ctx, %{authzen: cfg}) do
    case authorize(conn, ctx.request, cfg) do
      {:cont, info} -> {:cont, conn, %{ctx | authzen: info}}
      {:refuse, status, body} -> {:refuse, status, body}
    end
  end

  # DLP may rewrite the conn (tokenized body re-served to the inner plug).
  defp run_stage(:dlp, conn, ctx, %{dlp: nil}), do: {:cont, conn, ctx}

  defp run_stage(:dlp, conn, ctx, %{dlp: dlp_opts}) do
    {conn, findings} = dlp_inbound(conn, ctx.request, dlp_opts)
    {:cont, conn, %{ctx | findings: findings}}
  end

  defp run_stage(:residency, conn, ctx, %{residency: nil}), do: {:cont, conn, ctx}

  defp run_stage(:residency, conn, ctx, %{residency: opts}) do
    workload = ctx.request.params || %{}

    case DataResidency.admit(workload, opts) do
      {:ok, _pass} ->
        {:cont, conn, %{ctx | residency: DataResidency.receipt(workload, opts)}}

      {:error, code, detail} ->
        {:refuse, 403, stage_refusal(:residency, code, detail)}
    end
  end

  defp run_stage(:budget, conn, ctx, %{budget: nil}), do: {:cont, conn, ctx}

  defp run_stage(:budget, conn, ctx, %{budget: cfg}) do
    if ctx.request.params in [nil, %{}] do
      {:cont, conn, ctx}
    else
      case budget_check(cfg, conn, ctx.request.params) do
        {:cont, info} -> {:cont, conn, %{ctx | budget: info}}
        {:refuse, status, body} -> {:refuse, status, body}
      end
    end
  end

  # -- authzen ----------------------------------------------------------------------

  defp authorize(conn, request, cfg) do
    case request.params do
      params when is_map(params) ->
        with {:ok, principal} <- principal(conn, cfg.principal),
             {:cont, info} <- evaluate_and_admit(principal, request, params, cfg) do
          {:cont, info}
        end

      _ ->
        # No params: nothing to authorize (GET card, undecodable body).
        {:cont, nil}
    end
  end

  defp evaluate_and_admit(principal, request, params, cfg) do
    metadata = params["metadata"] || %{}
    capability = metadata["skill"] || message_skill(params) || capability(request)
    resource_id = resource_id(params)

    effect = PreparedEffect.new(principal, capability, resource_id, params)

    context =
      metadata
      |> Map.drop(["delegation"])
      |> Map.put("method", request.method)

    case delegation_chain(metadata) do
      {:error, detail} ->
        {:refuse, 403, authzen_refusal("invalid_delegation", detail)}

      {:ok, chain} ->
        case evaluate(cfg, principal, capability, resource_id, context) do
          {:ok, decision} ->
            admit(cfg, principal, capability, resource_id, effect, decision, chain)

          {:error, reason} ->
            {:refuse, 403, pdp_refusal(reason)}
        end
    end
  end

  defp evaluate(cfg, principal, capability, resource_id, context) do
    Client.evaluate(
      cfg.client,
      %Types.Entity{type: "workload", id: principal},
      %Types.Action{name: capability},
      %Types.Entity{type: "task", id: resource_id},
      context
    )
  end

  defp admit(cfg, principal, capability, resource_id, effect, decision, chain) do
    evidence = %PolicyEvidence{
      decision: decision.decision,
      policy_decision_point: decision.source || cfg.expected_pdp,
      principal: principal,
      effect_digest: effect.digest,
      observed_at: decision.observed_at || System.system_time(:millisecond)
    }

    case DecisionGate.admit_delegated(evidence, effect, cfg.expected_pdp, chain) do
      :ok ->
        {:cont,
         %{
           principal: principal,
           capability: capability,
           resource_id: resource_id,
           effect_digest: effect.digest,
           delegated?: chain != nil
         }}

      {:error, reason} ->
        {:refuse, 403, gate_refusal(reason)}
    end
  end

  defp capability(request) do
    case request.envelope do
      %{"method" => m} when is_binary(m) -> m
      _ -> "message/send"
    end
  end

  defp message_skill(%{"message" => %{"metadata" => %{"skill" => skill}}}) when is_binary(skill),
    do: skill

  defp message_skill(_), do: nil

  defp resource_id(params) do
    params["id"] ||
      case params["message"] do
        %{"taskId" => id} when is_binary(id) -> id
        %{"id" => id} when is_binary(id) -> id
        _ -> "task"
      end
  end

  # A delegated task presents its inherited (already narrowed) scope in
  # `metadata.delegation.effective`; the gate refuses any capability outside
  # it — the wire-level shape of monotonic grant narrowing.
  defp delegation_chain(%{"delegation" => %{"effective" => caps}}) when is_list(caps) do
    {:ok, Monotonic.root(caps)}
  end

  defp delegation_chain(%{"delegation" => other}) do
    {:error,
     "metadata.delegation must be %{\"effective\" => [capability, ...]}, got #{inspect(other)}"}
  end

  defp delegation_chain(_), do: {:ok, nil}

  defp principal(conn, nil) do
    case SvidValidator.get_spiffe_identity(conn) do
      %{identity: %{uri: uri}} -> {:ok, uri}
      _ -> {:refuse, 401, authzen_refusal("identity_absent", "no verified caller identity")}
    end
  end

  defp principal(conn, fun) when is_function(fun, 1) do
    case fun.(conn) do
      uri when is_binary(uri) and uri != "" ->
        {:ok, uri}

      _ ->
        {:refuse, 401, authzen_refusal("identity_absent", "principal resolver returned none")}
    end
  end

  defp authzen_refusal(reason, detail, extra \\ %{}) do
    Map.merge(
      %{
        "error" => "authzen_refused",
        "stage" => "authzen",
        "reason" => reason,
        "detail" => detail
      },
      extra
    )
  end

  defp pdp_refusal(:pdp_unreachable),
    do: authzen_refusal("pdp_unreachable", "PDP unreachable; refusing fail-closed")

  defp pdp_refusal({:pdp_error, status}),
    do: authzen_refusal("pdp_error", "PDP answered HTTP #{status}", %{"status" => status})

  defp pdp_refusal(:invalid_decision),
    do: authzen_refusal("invalid_decision", "PDP payload undecodable")

  defp pdp_refusal(reason), do: authzen_refusal("invalid_request", inspect(reason))

  defp gate_refusal(%Monotonic.Refusal{} = refusal) do
    authzen_refusal(
      to_string(refusal.code),
      "capability outside the delegated effective set",
      %{"digest" => refusal.digest, "excess" => refusal.excess}
    )
  end

  defp gate_refusal(:denied), do: authzen_refusal("denied", "PDP decision denied the request")

  defp gate_refusal(:pdp_mixup),
    do: authzen_refusal("pdp_mixup", "decision not from the expected PDP")

  defp gate_refusal(:effect_digest_mismatch),
    do: authzen_refusal("effect_digest_mismatch", "evidence does not bind this exact effect")

  defp gate_refusal(:principal_mismatch),
    do: authzen_refusal("principal_mismatch", "evidence names a different principal")

  # -- dlp ----------------------------------------------------------------------------

  defp dlp_inbound(conn, request, dlp_opts) do
    case request do
      %{params: params} when is_map(params) ->
        {redacted, findings} = DLPFilter.redact(params, dlp_opts)
        body = reencode(request, redacted)
        {serve(conn, body), findings}

      _ ->
        {conn, []}
    end
  end

  defp reencode(%{envelope: %{} = envelope}, redacted_params) when not is_struct(envelope) do
    Jason.encode!(Map.put(envelope, "params", redacted_params))
  end

  defp reencode(_request, redacted_params) do
    Jason.encode!(%{"params" => redacted_params})
  end

  # -- budget --------------------------------------------------------------------------

  defp budget_check({:finops, opts}, conn, params) do
    # The request view is params ∪ request headers (header names are already
    # lowercased by the HTTP layer), so the enforcer's "x-cost-center"
    # header attribution form works on the wire.
    request_view = Map.merge(header_map(conn), params)
    store = Keyword.fetch!(opts, :store)
    enforcer_opts = Keyword.take(opts, [:estimated_tokens])

    case AshA2A.FinOps.BudgetEnforcer.authorize(store, request_view, enforcer_opts) do
      {:ok, tag} ->
        {:cont, %{mode: :finops, tag: tag}}

      {:error, %{code: code, detail: detail}} ->
        {:refuse, budget_status(code), stage_refusal(:budget, code, inspect(detail))}
    end
  end

  defp budget_check({mod, opts}, _conn, params) do
    if Code.ensure_loaded?(mod) do
      case apply(mod, :check, [params, opts]) do
        :ok ->
          {:cont, %{mode: :module, module: mod}}

        {:error, code, detail} ->
          {:refuse, 429, stage_refusal(:budget, code, detail)}

        other ->
          {:refuse, 500, stage_refusal(:budget, :refused_budget_gate_invalid, inspect(other))}
      end
    else
      {:refuse, 503,
       stage_refusal(
         :budget,
         :refused_budget_gate_unavailable,
         "budget gate module #{inspect(mod)} is not loaded"
       )}
    end
  end

  defp budget_status(:budget_exceeded), do: 429
  defp budget_status(:invalid_request), do: 400
  defp budget_status(:missing_evidence), do: 403
  defp budget_status(_), do: 429

  defp header_map(conn), do: Map.new(conn.req_headers)

  defp stage_refusal(stage, code, detail) do
    %{"error" => to_string(code), "stage" => to_string(stage), "detail" => detail}
  end

  # -- refusal wire format -----------------------------------------------------------

  defp refuse(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  # -- outbound chain (before-send hook) ------------------------------------------------

  # Runs inside the inner plug's send_resp: DLP outbound redaction on every
  # JSON body, then (2xx only) CMEK envelope and affidavit receipt. A
  # refused outbound stage REPLACES the response.
  defp finish(conn, ctx, cfg, started) do
    json? =
      conn
      |> get_resp_header("content-type")
      |> List.first("")
      |> String.contains?("json")

    conn =
      if json? and is_binary(conn.resp_body) and conn.resp_body != "" do
        dlp_outbound(conn, cfg.dlp)
      else
        conn
      end

    if json? and conn.status in 200..299 do
      case outbound(conn, ctx, cfg) do
        {:ok, conn, extra} ->
          emit_completed(started, ctx, extra)
          conn

        {:refuse, code, detail} ->
          emit_refused(started, :outbound, to_string(code))
          rewrite_response(conn, 500, stage_refusal(:outbound, code, detail))
      end
    else
      emit_completed(started, ctx, %{})
      conn
    end
  end

  defp dlp_outbound(conn, nil), do: conn

  defp dlp_outbound(conn, dlp_opts) do
    case Jason.decode(conn.resp_body) do
      {:ok, decoded} ->
        {redacted, _findings} = DLPFilter.redact(decoded, dlp_opts)
        new_body = Jason.encode!(redacted)

        conn
        |> put_resp_header("content-length", Integer.to_string(byte_size(new_body)))
        |> Map.put(:resp_body, new_body)

      _ ->
        conn
    end
  end

  defp outbound(conn, ctx, cfg) do
    body = IO.iodata_to_binary(conn.resp_body || "")

    with {:ok, conn, cmek} <- cmek_stage(conn, body, cfg.cmek),
         {:ok, conn, affidavit} <- affidavit_stage(conn, ctx, body, cfg.affidavit) do
      {:ok, conn, %{cmek: cmek, affidavit: affidavit}}
    end
  end

  defp cmek_stage(conn, _body, nil), do: {:ok, conn, nil}

  defp cmek_stage(conn, body, opts) do
    case KeyManager.encrypt(body, opts) do
      {:ok, envelope} ->
        {:ok, store_private(conn, :cmek, envelope), envelope}

      {:error, code, detail} ->
        {:refuse, code, detail}
    end
  end

  defp affidavit_stage(conn, _ctx, _body, nil), do: {:ok, conn, nil}

  defp affidavit_stage(conn, ctx, body, _opts) do
    events = Enum.map(affidavit_events(ctx, body), &event_map/1)

    case assemble(events) do
      {:ok, assembled} ->
        receipt = assembled["receipt"]
        digest = receipt_digest(receipt)

        {:ok,
         conn
         |> put_resp_header(@affidavit_header, digest)
         |> store_private(:affidavit, assembled), assembled}

      {:error, reason} ->
        {:refuse, :refused_affidavit_receipt_failed, inspect(reason)}
    end
  end

  defp event_map(event),
    do: %{
      "event_type" => event.type,
      "objects" => event.objects,
      "payload" => Jason.encode!(event.payload)
    }

  defp assemble(events) do
    Affidavit.assemble_receipt(events)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp receipt_digest(receipt) when is_map(receipt) do
    Base.encode16(:crypto.hash(:sha256, Jason.encode!(receipt)), case: :lower)
  end

  defp receipt_digest(other) do
    Base.encode16(:crypto.hash(:sha256, inspect(other)), case: :lower)
  end

  defp affidavit_events(ctx, body) do
    request = ctx.request
    stages = Enum.reverse(ctx.trace) ++ [:dispatch]
    rid = request_id(request)

    base = [
      %{
        type: "enterprise.pipeline.request",
        objects: [rid],
        payload: %{
          "method" => request.method,
          "capability" => ctx.authzen && ctx.authzen.capability,
          "stages" => stages
        }
      },
      %{
        type: "enterprise.pipeline.response",
        objects: [rid],
        payload: %{
          "bytes" => byte_size(body),
          "stages" => stages ++ [:dlp_outbound, :cmek, :affidavit]
        }
      }
    ]

    authzen_event =
      if ctx.authzen do
        [
          %{
            type: "enterprise.pipeline.authzen",
            objects: [ctx.authzen.principal],
            payload: %{
              "capability" => ctx.authzen.capability,
              "effect_digest" => ctx.authzen.effect_digest,
              "delegated" => ctx.authzen.delegated?
            }
          }
        ]
      else
        []
      end

    findings_event =
      if ctx.findings != [] do
        [
          %{
            type: "enterprise.pipeline.dlp",
            objects: [rid],
            payload: %{
              "findings" => length(ctx.findings),
              "types" => Enum.uniq(Enum.map(ctx.findings, & &1.type))
            }
          }
        ]
      else
        []
      end

    residency_event =
      if ctx.residency do
        [
          %{
            type: "enterprise.pipeline.residency",
            objects: [rid],
            payload: %{
              "code" => to_string(ctx.residency.code),
              "decision" => to_string(ctx.residency.decision)
            }
          }
        ]
      else
        []
      end

    base ++ authzen_event ++ findings_event ++ residency_event
  end

  defp request_id(%{envelope: %{"id" => id}}), do: "rpc:" <> to_string(id)
  defp request_id(_), do: "rpc:unknown"

  defp store_private(conn, key, value) do
    stored = Map.get(conn.private, @assign, %{})
    %{conn | private: Map.put(conn.private, @assign, Map.put(stored, key, value))}
  end

  # -- response rewrite on outbound refusal ---------------------------------------------

  defp rewrite_response(conn, status, body) do
    new_body = Jason.encode!(body)

    conn
    |> Map.put(:status, status)
    |> Map.put(:resp_body, new_body)
    |> put_resp_header("content-length", Integer.to_string(byte_size(new_body)))
    |> put_resp_header("content-type", "application/json; charset=utf-8")
  end

  # -- telemetry --------------------------------------------------------------------------

  defp emit_completed(started, ctx, extra) do
    :telemetry.execute(
      [:ash_a2a, :enterprise, :pipeline, :completed],
      %{duration_ns: System.monotonic_time() - started},
      %{
        stages: Enum.reverse(ctx.trace) ++ [:dispatch, :dlp_outbound, :cmek, :affidavit, :ocel],
        dlp_findings: Enum.uniq(Enum.map(ctx.findings, & &1.type)),
        cmek: extra[:cmek],
        affidavit: extra[:affidavit]
      }
    )
  end

  defp emit_refused(started, stage, code) do
    :telemetry.execute(
      [:ash_a2a, :enterprise, :pipeline, :refused],
      %{duration_ns: System.monotonic_time() - started},
      %{stage: stage, code: code}
    )
  end

  # -- body adapter shim -----------------------------------------------------------------

  defmodule BodyAdapter do
    @moduledoc false
    # `Plug.Conn.Adapter` shim re-serving a (possibly DLP-rewritten) buffered
    # request body to the inner transport plug — the same technique as
    # `AshA2A.Security.DLPFilter.Plug.Adapter`.

    @behaviour Plug.Conn.Adapter

    @doc false
    # The adapter must stay a {module, payload} 2-tuple: Plug.Conn's
    # send_resp funnel matches that shape and answers a misleading
    # AlreadySentError for anything else.
    def init({mod, state}, body), do: {__MODULE__, {mod, state, body, false}}

    @doc false
    def read_req_body({mod, state, body, sent} = payload, opts) do
      max_length = Keyword.get(opts, :length, 8_000_000)

      cond do
        sent ->
          {:ok, "", payload}

        body == "" ->
          {:ok, "", {mod, state, "", true}}

        byte_size(body) <= max_length ->
          {:ok, body, {mod, state, "", true}}

        true ->
          part = binary_part(body, 0, max_length)
          rest = binary_part(body, max_length, byte_size(body) - max_length)
          {:more, part, {mod, state, rest, false}}
      end
    end

    @doc false
    def send_resp({mod, state, _, _}, status, headers, body),
      do: mod.send_resp(state, status, headers, body)

    @doc false
    def send_file({mod, state, _, _}, status, headers, path, offset, length),
      do: mod.send_file(state, status, headers, path, offset, length)

    @doc false
    def send_chunked({mod, state, _, _}, status, headers),
      do: mod.send_chunked(state, status, headers)

    @doc false
    def chunk({mod, state, _, _}, body), do: mod.chunk(state, body)

    @doc false
    def inform({mod, state, _, _}, status, headers), do: mod.inform(state, status, headers)

    @doc false
    def upgrade({mod, state, _, _}, protocol, opts), do: mod.upgrade(state, protocol, opts)

    @doc false
    def push({mod, state, _, _}, path, headers), do: mod.push(state, path, headers)

    @doc false
    def get_peer_data({mod, state, _, _}), do: mod.get_peer_data(state)

    @doc false
    def get_sock_data({mod, state, _, _}), do: mod.get_sock_data(state)

    @doc false
    def get_ssl_data({mod, state, _, _}), do: mod.get_ssl_data(state)

    @doc false
    def get_http_protocol({mod, state, _, _}), do: mod.get_http_protocol(state)
  end
end
