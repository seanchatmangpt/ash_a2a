# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.Pipeline do
  @moduledoc """
  The ARD §2 inbound execution pipeline (v26.10.4): one configurable, ordered
  plug that composes the landed enterprise gates around any existing
  ash_a2a transport plug. The pipeline *wires* the gates; it never modifies
  them.

  ## Fixed stage order (ARD §2)

      SVID validation
        -> AuthZEN DecisionGate (incl. monotonic narrowing for delegated tasks)
        -> DLPFilter (inbound redaction of JSON-RPC params)
        -> DataResidency
        -> FinOps.BudgetCeiling (via the budget-gate contract, below)
        -> dispatch (the inner transport plug)
        -> DLPFilter (outbound redaction of the JSON response)
        -> CMEK envelope
        -> Affidavit receipt
        -> OcelForwarder (forwarding via the real dispatch telemetry)

  ## Fail-closed semantics

  * Any enabled stage's refusal halts the chain with **that stage's** typed
    wire error; later stages never run, the inner plug is never called, and
    no dispatch happens.
  * No stage is ever silently skipped while enabled. An enabled budget gate
    whose module is not loaded refuses fail-closed
    (`refused_budget_gate_unavailable`); an enabled affidavit stage with an
    unavailable engine refuses the response
    (`refused_affidavit_receipt_failed`); an enabled CMEK stage with no
    usable KMS refuses the response (`refused_cmek_envelope_failed`).
  * The order is structural, not configurable: config toggles stages on and
    off, never reorders them.
  * Disabled stages pass through untouched (the chain is a no-op wrapper).

  ## Mounting

  The pipeline wraps the transport plug (mounted before it) via `:inner`:

      forward "/a2a", AshA2A.Enterprise.Pipeline,
        agent: MyAgent,
        base_url: "https://agents.example.com/a2a",
        svid: [trust_domain: "corp.example", bundle_source: MyApp.SpiffeBundle],
        authzen: [client: my_authzen_client],
        dlp: [key: System.fetch_env!("A2A_DLP_KEY"]),
        residency: [node_region: "us-east-1"],
        budget: {MyApp.BudgetGate, ceiling: 100},
        cmek: [],
        affidavit: [],
        ocel: []

  Every stage key may be given three shapes: absent or `false` (disabled),
  `true` (enabled with defaults), or a keyword/options value (enabled with
  those options). Each stage also falls back to
  `config :ash_a2a, AshA2A.Enterprise.Pipeline, svid: [...], ...`, merged
  under the per-plug opts (plug opts win).

  ## Options

    * `:inner` — `{plug, opts}` or a module; the transport plug the pipeline
      wraps. Default: `AshA2A.A2ATransport.Plug` with all remaining (non-stage)
      options forwarded.

  ### Stage options

    * `:svid` — `AshA2A.SPIFFE.SvidValidator` options (`:trust_domain`,
      `:bundle_source`, `:assign`); the real plug runs verbatim.
    * :authzen — requires `:client` (an `AshA2A.AuthZEN.Client`); optional
      `:expected_pdp` (default: the client metadata's
      `:policy_decision_point`), and `:principal` — a `conn -> binary | nil`
      resolver overriding the default (the `:spiffe_identity` assign stamped
      by the SVID stage).
    * `:dlp` — `AshA2A.Security.DLPFilter` opts (`:key`, `:entropy_floor`,
      `:phi_patterns`); drives BOTH directions (inbound params + outbound
      response).
    * `:residency` — `AshA2A.Security.DataResidency.admit/2` opts
      (`:node_region`, `:region_groups`).
    * `:budget` — `{module, opts}`. The module must export
      `check/2`: `check(params, opts) :: :ok | {:error, code, detail}` with
      `code` an atom. Default module when only `true`/keyword is given:
      `AshA2A.FinOps.BudgetCeiling`. Fail-closed when the module is not
      loaded.
    * `:cmek` — `AshA2A.Security.KeyManager.encrypt/2` opts (e.g. `:kek_id`);
      requires the host's KMS binding (`config :ash_a2a, :cmek_kms_client`)
      — fail-closed when absent.
    * `:affidavit` — reserved keyword (no options today); refuses the
      response fail-closed when the `AshAffidavit` engine is unavailable.
    * `:ocel` — reserved keyword; ensures `AshA2A.Telemetry.OcelForwarder`
      is attached so real dispatch telemetry forwards to
      `config :ash_a2a, :ocel_ingest_url` (delivery is best-effort egress,
      per the forwarder's own contract — it never refuses traffic).

  ## Wire behaviour

  * Inbound stages run before the inner plug. SVID faults are answered by
    the `SvidValidator` plug itself (401 `spiffe_svid_refused`); every other
    refusal is a JSON body of the form
    `%{"error" => code, "stage" => stage, "detail" => detail}` with the
    stage's typed HTTP status (AuthZEN 403, residency 403, budget 429,
    pipeline-level faults 413/503).
  * Requests without JSON-RPC params (e.g. a `GET` agent card) pass the
    AuthZEN/residency/budget stages (nothing to authorize or charge); the
    SVID stage applies to every request.
  * Outbound stages run in a `register_before_send` hook on 2xx JSON
    responses (DLP outbound redaction also runs on non-2xx JSON, since error
    bodies can leak too). A refused outbound stage REPLACES the response with
    its typed 500 refusal — the response never leaves the process
    unenveloped.
  * The request body is read once, DLP-rewritten, and re-served to the inner
    plug through an adapter shim (the same technique as
    `AshA2A.Security.DLPFilter.Plug`), so the dispatching transport sees
    tokenized params, never plaintext.

  ## Telemetry

    * `[:ash_a2a, :enterprise, :pipeline, :completed]` — `%{duration_ns}`,
      `%{stages: [...], dlp_findings: [types], cmek: envelope,
      affidavit: assembled_receipt}` — the court-replayable trace.
    * `[:ash_a2a, :enterprise, :pipeline, :refused]` — `%{duration_ns}`,
      `%{stage, code}`.

  ## Wire-error table

  | stage | status | body `error` |
  |---|---|---|
  | svid | 401 | `spiffe_svid_refused` (from the plug itself) |
  | authzen | 403 | `authzen_refused` (`reason`: `denied`, `pdp_unreachable`, `pdp_error`, `invalid_decision`, `invalid_request`, `pdp_mixup`, `refused_non_monotonic_grant`, `identity_absent`) |
  | dlp | — | (redaction stage; tokenizes, never refuses) |
  | residency | 403 | `refused_data_residency_violation` / `refused_data_residency_unknown_region` |
  | budget | 429 | the gate module's typed code (`refused_budget_exceeded`) |
  | budget (module missing) | 503 | `refused_budget_gate_unavailable` |
  | cmek | 500 | `refused_cmek_envelope_failed` |
  | affidavit | 500 | `refused_affidavit_receipt_failed` |
  | ocel | — | (attach + forward; egress is best-effort, never refuses) |
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

    %{
      svid: svid_cfg(value(:svid, opts, app)),
      authzen: authzen_cfg(value(:authzen, opts, app)),
      dlp: kw_cfg(value(:dlp, opts, app)),
      residency: kw_cfg(value(:residency, opts, app)),
      budget: budget_cfg(value(:budget, opts, app)),
      cmek: kw_cfg(value(:cmek, opts, app)),
      affidavit: kw_cfg(value(:affidavit, opts, app)),
      ocel: kw_cfg(value(:ocel, opts, app)),
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
        emit_refused(started, :pipeline, "refused_pipeline_body_too_large")
        refuse(conn, status, body)

      {conn, request} ->
        case inbound(conn, request, cfg) do
          {:answered, conn} ->
            conn

          {:refuse, stage, status, body} ->
            emit_refused(started, stage, body["error"])
            refuse(conn, status, body)

          {:cont, ctx} ->
            conn
            |> register_before_send(fn c -> finish(c, ctx, cfg, started) end)
            |> call_inner(cfg.inner)
        end
    end
  end

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
  defp kw_cfg(other), do: bad_stage!(:unknown, other)

  defp budget_cfg(false), do: nil
  defp budget_cfg(nil), do: nil
  defp budget_cfg(true), do: {AshA2A.FinOps.BudgetCeiling, []}

  defp budget_cfg(mod) when is_atom(mod), do: {mod, []}

  defp budget_cfg({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
  defp budget_cfg(other), do: bad_stage!(:budget, other)

  defp inner_cfg(opts) do
    case Keyword.get(opts, :inner) do
      nil ->
        {AshA2A.A2ATransport.Plug,
         AshA2A.A2ATransport.Plug.init(Keyword.drop(opts, @pipeline_keys))}

      {mod, inner_opts} when is_atom(mod) and is_list(inner_opts) ->
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

  # Reads the JSON-RPC body once so every stage (and the outbound rewriter)
  # works over decoded params, and re-serves the (possibly DLP-rewritten)
  # bytes to the inner plug through an adapter shim.
  defp collect_request(conn) do
    cond do
      conn.method != "POST" ->
        {conn, %{envelope: nil, params: nil}}

      match?(%Plug.Conn.Unfetched{}, conn.body_params) ->
        case read_bounded(conn) do
          {:ok, body, conn} ->
            case Jason.decode(body) do
              {:ok, %{} = envelope} ->
                {serve(conn, body), %{envelope: envelope, params: envelope["params"], body: body}}

              _ ->
                # Undecodable: re-serve the original bytes; the inner transport
                # answers the canonical -32700 parse error.
                {serve(conn, body), %{envelope: nil, params: nil, body: body}}
            end

          {:error, :body_too_large} ->
            {:refuse, 413,
             %{
               "error" => "refused_pipeline_body_too_large",
               "stage" => "pipeline",
               "detail" => "request body exceeds #{byte_size_limit()} bytes; refusing fail-closed"
             }}
        end

      :else ->
        # An upstream parser already decoded the body.
        params = if is_map(conn.body_params), do: conn.body_params, else: nil
        {conn, %{envelope: conn.body_params, params: params, body: nil}}
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
        {:refuse, 400,
         %{
           "error" => "refused_pipeline_body_unreadable",
           "stage" => "pipeline",
           "detail" => inspect(reason)
         }}
    end
  end

  defp byte_size_limit, do: @max_body

  defp serve(conn, body) do
    %{conn | adapter: BodyAdapter.init(conn.adapter, body)}
  end

  # -- inbound chain ---------------------------------------------------------------

  defp inbound(conn, request, cfg) do
    ctx = %{request: request, trace: [], findings: [], authzen: nil, residency: nil, budget: nil}

    Enum.reduce_while(@inbound_order, {:cont, ctx}, fn stage, {:cont, ctx} ->
      case run_stage(stage, conn, ctx, cfg) do
        {:cont, ctx} -> {:cont, {:cont, ctx}}
        {:answered, conn} -> {:halt, {:answered, conn}}
        {:refuse, status, body} -> {:halt, {:refuse, stage, status, body}}
      end
    end)
  end

  # SVID is the only stage that receives (and may answer) the conn.
  defp run_stage(:svid, conn, ctx, %{svid: nil}), do: {:cont, ctx}

  defp run_stage(:svid, conn, ctx, %{svid: %{validator: validator}}) do
    case SvidValidator.call(conn, validator) do
      %{halted: true} = conn -> {:answered, conn}
      conn -> {:cont, ctx}
    end
  end

  defp run_stage(:authzen, conn, ctx, %{authzen: nil}), do: {:cont, ctx}

  defp run_stage(:authzen, conn, ctx, %{authzen: cfg}) do
    case authorize(conn, ctx.request, cfg) do
      {:cont, info} -> {:cont, %{ctx | authzen: info}}
      {:refuse, status, body} -> {:refuse, status, body}
    end
  end

  # DLP may rewrite the conn (tokenized body re-served to the inner plug).
  defp run_stage(:dlp, conn, ctx, %{dlp: nil}), do: {:cont, ctx}

  defp run_stage(:dlp, conn, ctx, %{dlp: dlp_opts}) do
    with {:cont, conn, findings} <- dlp_inbound(conn, ctx.request, dlp_opts) do
      {:cont, %{ctx | findings: findings}}
    end
  end

  defp run_stage(:residency, _conn, ctx, %{residency: nil}), do: {:cont, ctx}

  defp run_stage(:residency, _conn, ctx, %{residency: opts}) do
    workload = ctx.request.params || %{}

    with {:ok, _pass} <- DataResidency.admit(workload, opts) do
      {:cont, %{ctx | residency: DataResidency.receipt(workload, opts)}}
    end
  end

  defp run_stage(:budget, _conn, ctx, %{budget: nil}), do: {:cont, ctx}

  defp run_stage(:budget, _conn, ctx, %{budget: {mod, opts}}) do
    if ctx.request.params in [nil, %{}] do
      {:cont, ctx}
    else
      with :ok <- check_budget(mod, opts, ctx.request.params) do
        {:cont, %{ctx | budget: %{module: mod}}}
      end
    end
  end

  # -- authzen ----------------------------------------------------------------------

  defp authorize(conn, request, cfg) do
    with {:ok, principal} <- principal(conn, cfg.principal),
         {:ok, input} <- gate_input(request) do
      capability = input.capability
      resource_id = input.resource_id

      effect =
        PreparedEffect.new(principal, capability, resource_id, request.params)

      context =
        input.metadata
        |> Map.drop(["delegation"])
        |> Map.put("method", input.method)

      chain = delegation_chain(input.metadata)

      with {:ok, decision} <-
             Client.evaluate(
               cfg.client,
               %Types.Entity{type: "workload", id: principal},
               %Types.Action{name: capability},
               %Types.Entity{type: "task", id: resource_id},
               context
             ),
           evidence = %PolicyEvidence{
             decision: decision.decision,
             policy_decision_point: decision.source || cfg.expected_pdp,
             principal: principal,
             effect_digest: effect.digest,
             observed_at: decision.observed_at || System.system_time(:millisecond)
           },
           :ok <- DecisionGate.admit_delegated(evidence, effect, cfg.expected_pdp, chain) do
        {:cont,
         %{
           principal: principal,
           capability: capability,
           resource_id: resource_id,
           effect_digest: effect.digest,
           delegated?: chain != nil
         }}
      end
    end
  end

  defp principal(conn, nil) do
    case SvidValidator.get_spiffe_identity(conn) do
      %{identity: %{uri: uri}} -> {:ok, uri}
      _ -> {:refuse, 401, authzen_refusal("identity_absent", "no verified caller identity")}
    end
  end

  defp principal(conn, fun) when is_function(fun, 1) do
    case fun.(conn) do
      uri when is_binary(uri) and uri != "" -> {:ok, uri}
      _ -> {:refuse, 401, authzen_refusal("identity_absent", "principal resolver returned none")}
    end
  end

  defp gate_input(request) do
    case request.params do
      nil -> {:refuse, :skip, nil}
      params when is_map(params) -> {:ok, build_input(request, params)}
      _ -> {:refuse, :skip, nil}
    end
  end

  defp build_input(request, params) do
    metadata = params["metadata"] || %{}

    capability =
      metadata["skill"] ||
        (case request.envelope do
           %{"method" => m} when is_binary(m) -> m
           _ -> "message/send"
         end)

    resource_id =
      params["id"] ||
        (case params["message"] do
           %{"taskId" => id} when is_binary(id) -> id
           %{"id" => id} when is_binary(id) -> id
           _ -> "task"
         end)

    %{
      capability: capability,
      resource_id: resource_id,
      metadata: metadata,
      method:
        case request.envelope do
          %{"method" => m} when is_binary(m) -> m
          _ -> "unknown"
        end
    }
  end

  defp delegation_chain(%{"delegation" => %{"effective" => caps}}) when is_list(caps),
    do: Monotonic.root(caps)

  defp delegation_chain(%{"delegation" => other}),
    do: raise(ArgumentError, "malformed delegation metadata: #{inspect(other)}")

  defp delegation_chain(_), do: nil

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

  # -- dlp ----------------------------------------------------------------------------

  defp dlp_inbound(conn, request, dlp_opts) do
    case request do
      %{params: params} when is_map(params) ->
        {redacted, findings} = DLPFilter.redact(params, dlp_opts)

        findings = Enum.flat_map(findings, & &1)

        body = reencode(request, redacted)
        {:cont, serve(conn, body), findings}

      _ ->
        {:cont, conn, []}
    end
  end

  defp reencode(request, redacted_params) do
    case request.envelope do
      %{} = envelope when not is_struct(envelope) ->
        Jason.encode!(Map.put(envelope, "params", redacted_params))

      _ ->
        Jason.encode!(%{"params" => redacted_params})
    end
  end

  # -- budget --------------------------------------------------------------------------

  defp check_budget(mod, opts, params) do
    if Code.ensure_loaded?(mod) do
      case apply(mod, :check, [params, opts]) do
        :ok -> :ok
        {:error, code, detail} -> {:refuse, 429, budget_refusal(code, detail)}
        other -> {:refuse, 500, budget_refusal(:refused_budget_gate_invalid, inspect(other))}
      end
    else
      {:refuse, 503, budget_refusal(:refused_budget_gate_unavailable, inspect(mod))}
    end
  end

  defp budget_refusal(code, detail) do
    %{"error" => to_string(code), "stage" => "budget", "detail" => detail}
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
  # JSON body, then (2xx only) CMEK envelope, affidavit receipt and OcelForwarder
  # attachment. A refused outbound stage REPLACES the response.
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

    if success_json?(conn, json?) do
      case outbound(conn, ctx, cfg) do
        {:ok, conn, extra} ->
          emit_completed(started, ctx, extra)
          conn

        {:refuse, code, detail} ->
          emit_refused(started, :outbound, to_string(code))
          rewrite_response(conn, 500, %{"error" => to_string(code), "stage" => "outbound", "detail" => detail})
      end
    else
      emit_completed(started, ctx, %{})
      conn
    end
  end

  defp success_json?(conn, json?), do: json? and conn.status in 200..299

  defp dlp_outbound(conn, nil), do: conn

  defp dlp_outbound(conn, dlp_opts) when is_list(dlp_opts) do
    body = conn.resp_body

    case Jason.decode(body) do
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
         {:ok, conn, affidavit} <- affidavit_stage(conn, ctx, body, cfg.affidavit),
         :ok <- ocel_stage(cfg.ocel) do
      {:ok, conn, %{cmek: cmek, affidavit: affidavit}}
    end
  end

  defp cmek_stage(conn, _body, nil), do: {:ok, conn, nil}

  defp cmek_stage(conn, body, opts) do
    case KeyManager.encrypt(body, opts) do
      {:ok, envelope} ->
        {:ok,
         update_in(conn.private[@assign], fn
           nil -> %{cmek: envelope}
           m -> Map.put(m, :cmek, envelope)
         end), envelope}

      {:error, code, detail} ->
        {:refuse, code, detail}
    end
  end

  defp affidavit_stage(conn, _ctx, _body, nil), do: {:ok, conn, nil}

  defp affidavit_stage(conn, ctx, body, _opts) do
    events =
      Enum.map(affidavit_events(ctx, body), fn event ->
        %{"event_type" => event.type, "objects" => event.objects, "payload" => event.payload}
      end)

    case assemble(events) do
      {:ok, assembled} ->
        receipt = assembled["receipt"]
        digest = receipt_digest(receipt)

        {:ok,
         conn
         |> put_resp_header(@affidavit_header, digest)
         |> update_in(
           [Access.key!(:private), Access.key!(@assign, %{})],
           &Map.put(&1, :affidavit, assembled)
         ), assembled}

      {:error, reason} ->
        {:refuse, :refused_affidavit_receipt_failed, inspect(reason)}
    end
  end

  defp assemble(events) do
    Affidavit.assemble_receipt(events)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp receipt_digest(receipt) when is_map(receipt) do
    Base.encode16(:crypto.hash(:sha256, Jason.encode!(receipt)), case: :lower)
  end

  defp receipt_digest(other), do: Base.encode16(:crypto.hash(:sha256, inspect(other)), case: :lower)

  defp affidavit_events(ctx, body) do
    request = ctx.request

    base = [
      %{
        type: "enterprise.pipeline.request",
        objects: [request_id(request)],
        payload: %{
          "method" => request_method(request),
          "capability" => ctx.authzen && ctx.authzen.capability,
          "stages" => Enum.reverse(ctx.trace) ++ [:dispatch]
        }
      },
      %{
        type: "enterprise.pipeline.response",
        objects: [request_id(request)],
        payload: %{"bytes" => byte_size(body), "stages" => [:dispatch, :dlp_outbound, :cmek, :affidavit]}
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
            objects: [request_id(request)],
            payload: %{"findings" => length(ctx.findings), "types" => types(ctx.findings)}
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
            objects: [request_id(request)],
            payload: %{"code" => to_string(ctx.residency.code), "decision" => to_string(ctx.residency.decision)}
          }
        ]
      else
        []
      end

    base ++ authzen_event ++ findings_event ++ residency_event
  end

  defp request_id(request), do: request_id(request.envelope)
  defp request_id(%{"id" => id}), do: "rpc:" <> inspect(id)
  defp request_id(_), do: "rpc:unknown"

  defp request_method(%{envelope: %{"method" => m}}), do: m
  defp request_method(_), do: conn_method()

  defp conn_method, do: Process.get({__MODULE__, :method}) || "unknown"

  defp types(findings), do: findings |> Enum.map(& &1.type) |> Enum.uniq()

  defp ocel_stage(nil), do: :ok

  defp ocel_stage(_opts) do
    case OcelForwarder.attach!() do
      :ok -> :ok
      {:error, reason} -> {:refuse, :refused_ocel_attach_failed, inspect(reason)}
    end
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
        dlp_findings: types(ctx.findings),
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
    @moduledoc """
    `Plug.Conn.Adapter` shim re-serving a (possibly DLP-rewritten) buffered
    request body to the inner transport plug — the same technique as
    `AshA2A.Security.DLPFilter.Plug.Adapter`.
    """

    @behaviour Plug.Conn.Adapter

    @doc false
    def init({mod, state}, body), do: {mod, state, body, false}

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
