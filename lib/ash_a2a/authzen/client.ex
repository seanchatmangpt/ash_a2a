# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthZEN.Client do
  @moduledoc """
  Access-evaluation client that posts `AshA2A.AuthZEN.Wire` requests through an injected
  transport and returns the observed decision via `evaluate/2`. It observes PDP outcomes
  as evidence; an allow confers no authority.

  `evaluate/4` is the real-PDP path (FR-01.3): it builds the OpenID AuthZEN evaluation
  request (`subject`/`action`/`resource`/`context`), POSTs it to the PDP through
  `AshA2A.AuthZEN.DecisionPool` (real Finch pool + local TTL cache), and fails closed:
  `:pdp_unreachable`, `{:pdp_error, status}` and `:invalid_decision` are typed refusals
  the caller must treat as a dispatch halt — a PDP outage can never become an allow.
  """

  alias AshA2A.AuthZEN.{DecisionPool, Metadata, Types, Wire}

  @enforce_keys [:metadata, :transport]
  defstruct [:metadata, :transport, cache_ttl: 60_000, timeout: 5_000]

  @type t :: %__MODULE__{}

  @headers [
    {"content-type", "application/json"},
    {"accept", "application/json"}
  ]

  @doc """
  Builds a client for the real-PDP path: `transport` defaults to the real
  `DecisionPool` HTTP transport, so the returned client needs no injected fn.
  An `:transport` opt overrides the default (same contract as `evaluate/2`:
  receives the encoded Wire map, returns `{:ok, raw_map}`).
  """
  @spec new(Metadata.t(), keyword()) :: t()
  def new(%Metadata{} = metadata, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    cache_ttl = Keyword.get(opts, :cache_ttl, 60_000)

    transport = Keyword.get(opts, :transport) || default_transport(timeout)

    %__MODULE__{metadata: metadata, transport: transport, cache_ttl: cache_ttl, timeout: timeout}
  end

  # The default transport owns both wire seams of the `evaluate/2` contract:
  # it JSON-encodes the outbound Wire map (Finch requires iodata) and
  # JSON-decodes the inbound 2xx body (decode_and_stamp requires a map).
  # Transport failures and non-2xx pass through fail-closed.
  defp default_transport(timeout) do
    fn endpoint, body ->
      payload = if is_binary(body), do: body, else: Jason.encode!(body)

      with {:ok, _status, response} <-
             DecisionPool.post(endpoint, payload, @headers, receive_timeout: timeout),
           {:ok, raw} <- Jason.decode(response) do
        {:ok, raw}
      end
    end
  end

  @doc """
  Injected-transport evaluation: posts the encoded `Wire` request through the client's
  transport fn and returns the observed decision (evidence only).
  """
  def evaluate(
        %__MODULE__{metadata: %Metadata{} = metadata, transport: transport},
        %Types.Request{} = request
      )
      when is_function(transport, 2) do
    with {:ok, raw} <- transport.(metadata.access_evaluation_endpoint, Wire.request(request)) do
      decode_and_stamp(metadata, raw)
    end
  end

  @doc """
  Real-PDP evaluation (FR-01.3): builds the AuthZEN evaluation request from
  `subject`/`action`/`resource`/`context`, serves it from the local TTL cache when a
  fresh decision exists, else POSTs it to the PDP through `DecisionPool`.

  Options:

    * `:cache_ttl` — per-call TTL override in ms (`0` forces a PDP re-consult)
    * `:bypass_cache` — `true` skips both the cache read and the write

  Fail-closed refusals: `{:error, :pdp_unreachable}` (PDP down/timeout), `{:error,
  {:pdp_error, status}}` (non-2xx), `{:error, :invalid_decision}` (undecodable payload),
  `{:error, :invalid_request}` (non-AuthZEN argument shapes). Each must halt dispatch.
  """
  def evaluate(client, subject, action, resource, context \\ %{}, opts \\ [])

  def evaluate(%__MODULE__{} = client, subject, action, resource, context, opts)
      when is_map(context) and is_list(opts) do
    endpoint = client.metadata.access_evaluation_endpoint
    ttl = Keyword.get(opts, :cache_ttl, client.cache_ttl)

    with {:ok, wire} <- wire_request(subject, action, resource, context),
         :ok <- DecisionPool.ensure_started([]),
         {:ok, decision} <- resolve(client, endpoint, Jason.encode!(wire), ttl, opts) do
      {:ok, decision}
    end
  end

  def evaluate(_client, _subject, _action, _resource, _context, _opts) do
    {:error, :invalid_request}
  end

  defp wire_request(subject, action, resource, context) do
    with {:ok, subject} <- as_entity(subject),
         {:ok, action} <- as_action(action),
         {:ok, resource} <- as_entity(resource) do
      {:ok,
       Wire.request(%Types.Request{
         subject: subject,
         action: action,
         resource: resource,
         context: context
       })}
    end
  end

  defp as_entity(%Types.Entity{} = entity), do: {:ok, entity}
  defp as_entity(_), do: {:error, :invalid_subject}

  defp as_action(%Types.Action{} = action), do: {:ok, action}
  defp as_action(_), do: {:error, :invalid_action}

  defp resolve(client, endpoint, encoded, ttl, opts) do
    if Keyword.get(opts, :bypass_cache, false) do
      fetch(client, endpoint, encoded, ttl)
    else
      case DecisionPool.cache_get(endpoint, encoded, System.system_time(:millisecond)) do
        {:ok, decision} -> {:ok, decision}
        _miss_or_expired -> fetch(client, endpoint, encoded, ttl)
      end
    end
  end

  defp fetch(client, endpoint, encoded, ttl) do
    with {:ok, _status, body} <-
           DecisionPool.post(endpoint, encoded, @headers, receive_timeout: client.timeout),
         {:ok, raw} <- Jason.decode(body),
         {:ok, decision} <- Wire.decode_decision(raw) do
      decision =
        %{decision | source: client.metadata.policy_decision_point}
        |> stamp_observed_at()

      DecisionPool.cache_put(
        endpoint,
        encoded,
        decision,
        now_ms: System.system_time(:millisecond),
        ttl_ms: ttl
      )

      {:ok, decision}
    end
  end

  defp stamp_observed_at(%Types.Decision{observed_at: nil} = decision) do
    %{decision | observed_at: DateTime.utc_now() |> DateTime.to_iso8601()}
  end

  defp stamp_observed_at(%Types.Decision{} = decision), do: decision

  defp decode_and_stamp(metadata, raw) when is_map(raw) do
    case Wire.decode_decision(raw) do
      {:ok, decision} -> {:ok, %{decision | source: metadata.policy_decision_point}}
      error -> error
    end
  end

  defp decode_and_stamp(_metadata, _raw), do: {:error, :invalid_decision}
end
