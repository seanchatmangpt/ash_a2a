# SPDX-WorkOrder: GGE-26922-12 (docs/jira/v26.10.4/PRD.md FR-01.1)
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SPIFFE.WorkloadWatcher do
  @moduledoc """
  GenServer maintaining an active connection to a SPIRE agent's Workload API
  UNIX domain socket, streaming X.509 SVIDs into an
  `AshA2A.SPIFFE.TrustBundle` cache rotated BEFORE certificate expiry
  (PRD v26.10.4 FR-01.1).

  Wire note: the real SPIRE agent speaks gRPC over UDS. This watcher consumes
  the gRPC message-framing layer (1-byte compression flag + 4-byte big-endian
  message length) carrying Workload API `X509SVIDUpdate` protobufs — the
  framing + payload subset this library's test SPIRE-agent fixture speaks.

  Fail-closed: when the stream is down the last-known-good bundle is retained
  and served only until its `:expires_at`; at or past expiry every query
  refuses with `{:error, :trust_bundle_expired}` until the stream returns and
  delivers fresh material. Deliveries that would be admitted after their own
  expiry are refused outright (`AshA2A.SPIFFE.TrustBundle.admit/3`).
  """

  use GenServer

  import Bitwise

  alias AshA2A.SPIFFE.Identity
  alias AshA2A.SPIFFE.TrustBundle

  require Logger

  @default_socket_path "/run/spire/sockets/agent.sock"
  @default_rotation_lead_ms 30_000
  @default_reconnect_backoff_ms 500
  @connect_timeout_ms 5_000

  @typedoc "see `AshA2A.SPIFFE.SvidValidator` (:bundle_source contract)"
  @type bundle_projection :: %{
          required(:trust_domain) => String.t(),
          required(:root_certificates) => [TrustBundle.der()],
          optional(:intermediate_certificates) => [TrustBundle.der()]
        }

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Starts the watcher. Options:

    * `:name` — GenServer name (required).
    * `:socket_path` — SPIRE agent UDS path (default `/run/spire/sockets/agent.sock`).
    * `:trust_domain` — local trust domain, projected by `bundle/0` (default from
      `:ash_a2a` app env `:spiffe_trust_domain`).
    * `:rotation_lead_ms` — how long before `:expires_at` a rotation is forced
      (default 30_000).
    * `:reconnect_backoff_ms` — delay between reconnect attempts while
      degraded (default 500).
  """
  def start_link(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The currently streamed SVID; refuses with the bundle's fail-closed errors."
  @spec current_svid(GenServer.server()) ::
          {:ok, TrustBundle.svid()} | {:error, :no_svid | :no_trust_bundle | :trust_bundle_expired}
  def current_svid(server) do
    case GenServer.call(server, :trust_bundle) do
      {:ok, %TrustBundle{svids: [svid | _]}} -> {:ok, svid}
      {:ok, %TrustBundle{svids: []}} -> {:error, :no_svid}
      {:error, _} = error -> error
    end
  end

  @doc """
  Expiry-bounded trust-bundle query: `{:ok, bundle}` while `now < expires_at`
  (even when the socket is down — last-known-good retention), `{:error,
  :trust_bundle_expired}` at or past expiry, `{:error, :no_trust_bundle}`
  before any delivery.
  """
  @spec trust_bundle(GenServer.server()) ::
          {:ok, TrustBundle.t()} | {:error, :no_trust_bundle | :trust_bundle_expired}
  def trust_bundle(server), do: GenServer.call(server, :trust_bundle)

  @doc "Digest of the admitted bundle (see `AshA2A.SPIFFE.TrustBundle.digest/1`)."
  @spec bundle_digest(GenServer.server()) ::
          {:ok, binary()} | {:error, :no_trust_bundle | :trust_bundle_expired}
  def bundle_digest(server) do
    case trust_bundle(server) do
      {:ok, %TrustBundle{digest: digest}} -> {:ok, digest}
      {:error, _} = error -> error
    end
  end

  @doc """
  Connection status: `:watching` while the stream is up, `:degraded` while
  disconnected (last-known-good still served until expiry), `:connecting`
  before the first successful connection.
  """
  @spec status(GenServer.server()) :: :watching | :degraded | :connecting
  def status(server), do: GenServer.call(server, :status)

  @doc """
  `AshA2A.SPIFFE.SvidValidator` `:bundle_source` projection of the cached
  bundle: `{:ok, %{trust_domain:, root_certificates:, intermediate_certificates: []}}`
  while the cache is within validity, `{:error, term}` fail-closed otherwise.
  Reads the default watcher instance (name `AshA2A.SPIFFE.WorkloadWatcher`).
  """
  @spec bundle() :: {:ok, bundle_projection()} | {:error, term()}
  def bundle do
    case trust_bundle(__MODULE__) do
      {:ok, %TrustBundle{certs: certs}} ->
        trust_domain =
          case GenServer.call(__MODULE__, :trust_domain) do
            nil -> Application.get_env(:ash_a2a, :spiffe_trust_domain)
            td -> td
          end

        {:ok,
         %{
           trust_domain: trust_domain,
           root_certificates: certs,
           intermediate_certificates: []
         }}

      {:error, _} = error ->
        error
    end
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      socket_path: Keyword.get(opts, :socket_path, @default_socket_path),
      trust_domain: Keyword.get(opts, :trust_domain),
      rotation_lead_ms: Keyword.get(opts, :rotation_lead_ms, @default_rotation_lead_ms),
      reconnect_backoff_ms:
        Keyword.get(opts, :reconnect_backoff_ms, @default_reconnect_backoff_ms),
      socket: nil,
      buffer: <<>>,
      status: :connecting,
      bundle: nil,
      reconnect_ref: nil,
      rotation_ref: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    case :gen_tcp.connect(
           {:local, to_charlist(state.socket_path)},
           0,
           [:binary, active: :once, packet: :raw],
           @connect_timeout_ms
         ) do
      {:ok, socket} ->
        # A SPIRE agent pushes the current X509SVIDUpdate immediately on stream
        # open, so every (re)connect doubles as a rotation refresh.
        Logger.info("SPIFFE WorkloadWatcher connected to #{state.socket_path}")
        state = %{state | socket: socket, buffer: <<>>, status: :watching}
        {:noreply, schedule_rotation(state)}

      {:error, _reason} ->
        schedule_reconnect(state)
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    case :inet.setopts(socket, active: :once) do
      :ok ->
        {frames, buffer} = state.buffer |> append(data) |> take_frames()
        state = %{state | buffer: buffer}
        state = Enum.reduce(frames, state, &apply_update/2)
        {:noreply, state}

      {:error, _closed} ->
        schedule_reconnect(%{state | socket: nil, status: :degraded})
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.warning("SPIFFE WorkloadWatcher stream closed (#{state.socket_path}); failing closed")
    schedule_reconnect(%{state | socket: nil, buffer: <<>>, status: :degraded})
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.warning("SPIFFE WorkloadWatcher tcp error: #{inspect(reason)}")
    schedule_reconnect(%{state | socket: nil, buffer: <<>>, status: :degraded})
  end

  def handle_info(:reconnect, %{socket: nil} = state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info(:rotate, %{bundle: %TrustBundle{} = bundle} = state) do
    now = System.system_time(:second)

    if TrustBundle.due?(bundle, now, state.rotation_lead_ms) do
      # Rotation due BEFORE expiry: force the agent to re-push fresh material
      # by dropping and reopening the stream — a SPIRE agent resends current
      # state on stream open. While the socket is already down the reconnect
      # loop is the rotation path.
      Logger.info("SPIFFE WorkloadWatcher forcing rotation before bundle expiry")

      case state.socket do
        nil ->
          schedule_reconnect(state)

        socket ->
          :ok = :gen_tcp.close(socket)
          schedule_reconnect(%{state | socket: nil, buffer: <<>>, status: :degraded})
      end
    else
      {:noreply, schedule_rotation(state)}
    end
  end

  def handle_info(:rotate, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:trust_bundle, _from, state) do
    {:reply, TrustBundle.fetch(state.bundle, System.system_time(:second)), state}
  end

  def handle_call(:trust_domain, _from, state), do: {:reply, state.trust_domain, state}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  # ------------------------------------------------------------------
  # Frame + protobuf decoding (Workload API X509SVIDUpdate subset)
  # ------------------------------------------------------------------

  defp append(buffer, data), do: <<buffer::binary, data::binary>>

  # gRPC message framing: 1-byte compression flag, 4-byte big-endian length.
  defp take_frames(buffer) when byte_size(buffer) < 5, do: {[], buffer}

  defp take_frames(<<flag::8, len::32, payload::binary>>) when byte_size(payload) < len,
    do: {[], <<flag::8, len::32, payload::binary>>}

  defp take_frames(<<_flag::8, len::32, payload::binary-size(len), rest::binary>>) do
    {frames, buffer} = take_frames(rest)
    {[payload | frames], buffer}
  end

  defp apply_update(payload, state) do
    case decode_update(payload) do
      {:ok, svid_fields, bundle_certs} ->
        admit_update(svid_fields, bundle_certs, state)

      :error ->
        Logger.warning("SPIFFE WorkloadWatcher dropped undecodable X509SVIDUpdate frame")
        state
    end
  end

  defp admit_update(svid_fields, bundle_certs, state) do
    now = System.system_time(:second)

    with {:ok, svids} <- parse_svids(svid_fields),
         {:ok, candidate} <- TrustBundle.from_update(svids, bundle_certs, now) do
      case TrustBundle.admit(state.bundle, candidate, now) do
        {:admitted, bundle} ->
          Logger.info(
            "SPIFFE WorkloadWatcher trust bundle rotated " <>
              "(digest #{Base.encode16(bundle.digest, case: :lower)})"
          )

          schedule_rotation(%{state | bundle: bundle})

        {:retained, bundle} ->
          Logger.warning("SPIFFE WorkloadWatcher retained last-known-good bundle")
          schedule_rotation(%{state | bundle: bundle})
      end
    else
      {:error, reason} ->
        Logger.warning(
          "SPIFFE WorkloadWatcher refused delivery (#{inspect(reason)}); " <>
            "retaining last-known-good"
        )

        state
    end
  end

  defp schedule_reconnect(state) do
    ref = Process.send_after(self(), :reconnect, state.reconnect_backoff_ms)
    {:noreply, %{state | reconnect_ref: ref, socket: nil, status: :degraded}}
  end

  defp schedule_rotation(%{bundle: nil} = state), do: state

  defp schedule_rotation(%{bundle: bundle} = state) do
    now = System.system_time(:second)
    due_at = TrustBundle.rotation_due_at(bundle, now, state.rotation_lead_ms)
    delay = max(due_at - now, 0)

    if is_reference(state.rotation_ref), do: Process.cancel_timer(state.rotation_ref)

    ref = Process.send_after(self(), :rotate, delay)
    %{state | rotation_ref: ref}
  end

  # ------------------------------------------------------------------
  # Workload API protobuf: X509SVIDUpdate / X509SVID (tolerant subset)
  # ------------------------------------------------------------------

  defp decode_update(payload) do
    with {:ok, fields} <- walk(payload, %{}, &collect_update_field/4) do
      svid_fields = Enum.reverse(Map.get(fields, 1, []))
      bundle_certs = Enum.reverse(Map.get(fields, 3, []))
      {:ok, svid_fields, bundle_certs}
    end
  end

  defp collect_update_field(1, :length_delimited, value, acc),
    do: Map.update(acc, 1, [value], &[value | &1])

  defp collect_update_field(3, :length_delimited, value, acc),
    do: Map.update(acc, 3, [value], &[value | &1])

  defp collect_update_field(_field, _wire, _value, acc), do: acc

  defp parse_svids(svid_fields) do
    Enum.reduce_while(svid_fields, {:ok, []}, fn payload, {:ok, acc} ->
      case parse_svid(payload) do
        {:ok, svid} -> {:cont, {:ok, [svid | acc]}}
        :error -> {:halt, {:error, :invalid_svid_frame}}
      end
    end)
  end

  defp parse_svid(payload) do
    with {:ok, fields} <- walk(payload, %{}, &collect_svid_field/4),
         spiffe_id when is_binary(spiffe_id) <- Map.get(fields, :spiffe_id),
         {:ok, identity} <- Identity.parse(spiffe_id),
         cert when is_binary(cert) <- Map.get(fields, :cert) do
      expires_at = TrustBundle.earliest_expiry([cert])

      {:ok, %{identity: identity, cert: cert, chain: Map.get(fields, :chain, []), expires_at: expires_at}}
    else
      _ -> :error
    end
  end

  defp collect_svid_field(1, :length_delimited, value, acc),
    do: Map.put(acc, :spiffe_id, value)

  defp collect_svid_field(2, :length_delimited, value, acc),
    do: Map.put(acc, :cert, value)

  defp collect_svid_field(3, :length_delimited, value, acc),
    do: Map.update(acc, :chain, [value], &[value | &1])

  defp collect_svid_field(_field, _wire, _value, acc), do: acc

  # Generic protobuf wire walker: varint(0), fixed64(1), length-delimited(2),
  # fixed32(5); unknown fields are skipped.
  defp walk(payload, acc, collector) do
    case do_walk(payload, acc, collector) do
      {:ok, acc, <<>>} -> {:ok, acc}
      _ -> :error
    end
  end

  defp do_walk(<<>>, acc, _collector), do: {:ok, acc, <<>>}

  defp do_walk(<<tag_and_wire, 0::1, rest::binary>>, acc, collector) do
    field = tag_and_wire >>> 3
    wire = tag_and_wire &&& 7
    walk_value(rest, field, wire, acc, collector)
  end

  defp do_walk(<<_b, _rest::binary>>, _acc, _collector), do: :error

  defp walk_value(payload, field, 0, acc, collector) do
    case varint(payload) do
      {:ok, value, rest} -> do_walk(rest, collector.(field, :varint, value, acc), collector)
      :error -> :error
    end
  end

  defp walk_value(<<_fixed::unsigned-big-integer-size(64), rest::binary>>, field, 1, acc, collector) do
    do_walk(rest, collector.(field, :fixed64, nil, acc), collector)
  end

  defp walk_value(<<_fixed::unsigned-big-integer-size(32), rest::binary>>, field, 5, acc, collector) do
    do_walk(rest, collector.(field, :fixed32, nil, acc), collector)
  end

  defp walk_value(payload, field, 2, acc, collector) do
    case varint(payload) do
      {:ok, len, rest} when byte_size(rest) >= len ->
        <<value::binary-size(len), remainder::binary>> = rest
        do_walk(remainder, collector.(field, :length_delimited, value, acc), collector)

      _ ->
        :error
    end
  end

  defp walk_value(_payload, _field, _wire, _acc, _collector), do: :error

  defp varint(payload, shift \\ 0, acc \\ 0)

  defp varint(<<0::1, value::7, rest::binary>>, shift, acc) do
    {:ok, acc ||| value <<< shift, rest}
  end

  defp varint(<<1::1, value::7, rest::binary>>, shift, acc) do
    varint(rest, shift + 7, acc ||| value <<< shift)
  end

  defp varint(<<>>, _shift, _acc), do: :error
end
