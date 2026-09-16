defmodule AshA2A.Chicago.Courts.AuthorityHarness do
  @moduledoc """
  Shared, real-collaborator plumbing for the RFC-SA2A-002 authority courts
  (`AshA2A.Chicago.Courts.AuthorityNonImplication`,
  `AshA2A.Chicago.Courts.GrantLifecycle`). Not a court.

  Everything here drives the real SUT: real `A2A.Agent` GenServers generated
  by `use AshA2A.Agent`, the real `A2A.Plug.Auth` + `A2A.Plug` HTTP pipeline
  (driven with `Plug.Test`, a real `Plug.Conn`), the real
  `AshA2A.Authority.Grant` decision, real brokers, and the real
  `AshA2A.CommandBus`. The only thing a court changes is the ENVIRONMENT
  around those components (which broker instance the host is configured
  with, whether that broker's process is running), which RFC-SA2A-002 §10
  permits.

  ## OCEL mappings

  `mappings/1` admits the authority-boundary telemetry the SUT emits:

  | telemetry event                                    | activity                  |
  |----------------------------------------------------|---------------------------|
  | `[:ash_a2a, :authority, :decision]`                | `authority.decision`      |
  | `[:ash_a2a, :authority, :broker, :lookup]`         | `authority.broker.lookup` |
  | `[:ash_a2a, :authority, :grant, :issue]`           | `authority.grant.issue`   |
  | `[:ash_a2a, :authority, :grant, :revoke]`          | `authority.grant.revoke`  |
  | `[:ash_a2a, :semantic, :bounds, :delegate]`        | `bounds.delegate`         |

  The source is this harness module -- it defines the closures -- so the
  identical set declared by both `SA2A-AUTH` and `SA2A-AUTH-GRANT` is admitted
  once by `AshA2A.Chicago.Runner.ocel_mappings/1` (one emission, one OCEL
  event), and the mapping digest versions the code that interprets the events.
  """

  alias AshA2A.Chicago.Ocel.Mapping

  @auth_attrs [:outcome, :reason, :policy, :broker, :authenticated, :capability_id, :principal_id]

  @doc "Admitted OCEL mappings for authority-boundary telemetry, shared by both authority courts."
  @spec mappings() :: [Mapping.t()]
  def mappings do
    source = __MODULE__

    authority =
      for {suffix, activity} <- [
            {[:decision], "authority.decision"},
            {[:broker, :lookup], "authority.broker.lookup"},
            {[:grant, :issue], "authority.grant.issue"},
            {[:grant, :revoke], "authority.grant.revoke"}
          ] do
        Mapping.new!(
          event: [:ash_a2a, :authority | suffix],
          activity: activity,
          source: source,
          objects: fn _m, meta ->
            [
              {"principal", meta[:principal_id], "principal"},
              {"capability", meta[:capability_id], "capability"},
              {"authority_grant", meta[:token_id], "grant"}
            ]
          end,
          attributes: fn _m, meta -> Map.take(meta, @auth_attrs) end
        )
      end

    authority ++
      [
        Mapping.new!(
          event: [:ash_a2a, :semantic, :bounds, :delegate],
          activity: "bounds.delegate",
          source: source,
          attributes: fn _m, meta ->
            Map.take(meta, [:outcome, :code, :parent_capabilities, :requested_capabilities])
          end
        )
      ]
  end

  # --- identities -----------------------------------------------------------

  @doc "A run-unique principal identity string."
  @spec principal(String.t()) :: String.t()
  def principal(label), do: "chicago-#{label}-#{System.unique_integer([:positive])}"

  @doc "A run-unique ledger nonce."
  @spec nonce(String.t()) :: String.t()
  def nonce(label), do: "#{label}-#{System.unique_integer([:positive])}"

  # --- environment ------------------------------------------------------------

  @doc """
  Runs `fun` with the host's `:authority_broker` pointed at `broker`,
  restoring the prior value afterwards. The policy is NOT overridden: the
  court qualifies whatever `:authority_policy` the host runs.
  """
  @spec with_broker(term(), (-> result)) :: result when result: var
  def with_broker(broker, fun) do
    prior = Application.fetch_env(:ash_a2a, :authority_broker)
    Application.put_env(:ash_a2a, :authority_broker, broker)

    try do
      fun.()
    after
      case prior do
        {:ok, value} -> Application.put_env(:ash_a2a, :authority_broker, value)
        :error -> Application.delete_env(:ash_a2a, :authority_broker)
      end
    end
  end

  @doc "Starts a real agent process under a unique name (unlinked). Returns the name."
  @spec start_agent(module()) :: atom()
  def start_agent(agent_module) do
    name = :"#{inspect(agent_module)}.Chicago#{System.unique_integer([:positive])}"
    {:ok, pid} = agent_module.start_link(name: name)
    Process.unlink(pid)
    name
  end

  @doc "Stops an agent started by `start_agent/1` (tolerates it being gone)."
  @spec stop_agent(atom()) :: :ok
  def stop_agent(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  # --- stimuli ----------------------------------------------------------------

  @doc """
  Sends a real message to a real agent as `identity` (the transport-verified
  identity `A2A.Plug.Auth` would have stored; `nil` for none). Returns
  `{:ok, task}`, `{:error, reason}` or `{:exit, reason}` -- an agent crash is
  evidence, never swallowed into a pass.
  """
  @spec agent_call(module(), atom(), term(), map(), map()) ::
          {:ok, A2A.Task.t()} | {:error, term()} | {:exit, term()}
  def agent_call(agent_module, name, identity, data, message_metadata) do
    message = %{A2A.Message.new_user([A2A.Part.Data.new(data)]) | metadata: message_metadata}

    call_metadata =
      if identity == nil,
        do: %{},
        else: %{"a2a.auth" => %{scheme: "bearer_auth", identity: identity}}

    agent_module.call(name, message, metadata: call_metadata, timeout: 30_000)
  catch
    :exit, reason -> {:exit, inspect(reason, limit: 20)}
  end

  @doc "A2A task state of an `agent_call/5` result, as a string."
  @spec task_state(term()) :: String.t()
  def task_state({:ok, %{status: %{state: state}}}), do: to_string(state)
  def task_state({:error, reason}), do: "error:" <> inspect(reason, limit: 10)
  def task_state({:exit, reason}), do: "exit:" <> to_string(reason)
  def task_state(other), do: inspect(other, limit: 10)

  @bearer_schemes %{"bearer_auth" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  @doc """
  Sends a real JSON-RPC `message/send` through `Plug.Test` into the real
  transport pipeline.

  Options:

    * `:tokens` -- `%{bearer_token => identity}`; when given, the pipeline is
      `A2A.Plug.Auth` (bearer scheme, verifying against this table) then
      `A2A.Plug`. When absent the pipeline is `A2A.Plug` alone (a deployment
      that never wired transport authentication).
    * `:bearer` -- the `Authorization: Bearer` credential to present.
    * `:params_metadata` -- the client-controlled JSON-RPC `params.metadata`.

  Returns `%{status: integer, halted: boolean, task_state: String.t() | nil, body: map | nil}`.
  """
  @spec http_send(atom(), String.t(), map(), keyword()) :: map()
  def http_send(agent_name, skill, data, opts) do
    message = %{A2A.Message.new_user([A2A.Part.Data.new(data)]) | metadata: %{"skill" => skill}}
    {:ok, message_json} = A2A.JSON.encode(message)

    params =
      case Keyword.get(opts, :params_metadata) do
        nil -> %{"message" => message_json}
        metadata -> %{"message" => message_json, "metadata" => metadata}
      end

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "chicago-" <> Integer.to_string(System.unique_integer([:positive])),
        "method" => "message/send",
        "params" => params
      })

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> maybe_bearer(Keyword.get(opts, :bearer))
      |> maybe_authenticate(Keyword.get(opts, :tokens))
      |> then(fn conn ->
        if conn.halted,
          do: conn,
          else:
            A2A.Plug.call(
              conn,
              A2A.Plug.init(agent: agent_name, base_url: "http://localhost:4000/a2a")
            )
      end)

    decoded =
      case Jason.decode(conn.resp_body || "") do
        {:ok, map} when is_map(map) -> map
        _ -> nil
      end

    %{
      status: conn.status,
      halted: conn.halted,
      body: decoded,
      task_state: get_in(decoded || %{}, ["result", "task", "status", "state"])
    }
  end

  defp maybe_bearer(conn, nil), do: conn

  defp maybe_bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  defp maybe_authenticate(conn, nil), do: conn

  defp maybe_authenticate(conn, tokens) when is_map(tokens) do
    verify = fn
      "bearer_auth", credential, _conn ->
        case Map.fetch(tokens, credential) do
          {:ok, identity} -> {:ok, identity}
          :error -> {:error, "invalid token"}
        end

      _scheme, _credential, _conn ->
        {:error, "unsupported scheme"}
    end

    A2A.Plug.Auth.call(conn, A2A.Plug.Auth.init(schemes: @bearer_schemes, verify: verify))
  end

  # --- predicates ---------------------------------------------------------------

  @doc "Attempt reached both the grant decision and the BRCE admission boundary."
  @spec reached_authority_and_admission() :: AshA2A.Chicago.Query.predicate()
  def reached_authority_and_admission,
    do: {:all, [{:observed, "authority.decision"}, {:observed, "brce.admission"}]}

  @doc "Forbidden: a grant decision, an admission, or an actuation."
  @spec granted_admitted_or_actuated() :: AshA2A.Chicago.Query.predicate()
  def granted_admitted_or_actuated do
    {:any,
     [
       {:observed, "authority.decision", %{"outcome" => "granted"}},
       {:observed, "brce.admission", %{"outcome" => "admitted"}},
       {:observed, "brce.actuate.start"}
     ]}
  end

  @doc "Forbidden without the grant decision (for stimuli whose own decision is lawful)."
  @spec admitted_or_actuated() :: AshA2A.Chicago.Query.predicate()
  def admitted_or_actuated do
    {:any,
     [
       {:observed, "brce.admission", %{"outcome" => "admitted"}},
       {:observed, "brce.actuate.start"}
     ]}
  end

  @doc "Expected for a lawful consequence: granted, admitted, prepared before actuation, committed."
  @spec granted_and_committed() :: AshA2A.Chicago.Query.predicate()
  def granted_and_committed do
    {:all,
     [
       {:observed, "authority.decision", %{"outcome" => "granted"}},
       {:observed, "brce.admission", %{"outcome" => "admitted"}},
       {:precedes, "brce.prepare", "brce.actuate.start", "command"},
       {:observed, "brce.commit", %{"outcome" => "committed"}}
     ]}
  end

  @doc "Observer activities attributed to a falsifier so far, with outcome attributes."
  @spec seen(AshA2A.Chicago.Context.t(), AshA2A.Chicago.Falsifier.t()) :: [String.t()]
  def seen(ctx, falsifier) do
    ctx
    |> AshA2A.Chicago.Context.observed(falsifier)
    |> Enum.map(fn record ->
      case record.attributes["outcome"] do
        nil -> record.activity
        outcome -> "#{record.activity}:#{outcome}"
      end
    end)
  end

  @doc "True when the observer saw `activity` with every attribute in `attrs` for `falsifier`."
  @spec saw?(AshA2A.Chicago.Context.t(), AshA2A.Chicago.Falsifier.t(), String.t(), map()) ::
          boolean()
  def saw?(ctx, falsifier, activity, attrs \\ %{}) do
    ctx
    |> AshA2A.Chicago.Context.observed(falsifier)
    |> Enum.any?(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(record.attributes[k]) == to_string(v) end)
    end)
  end
end
