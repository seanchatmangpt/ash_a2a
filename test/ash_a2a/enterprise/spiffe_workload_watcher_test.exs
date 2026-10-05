# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.SPIFFEWorkloadWatcherTest do
  @moduledoc """
  FR-01.1 courts (PRD v26.10.4) for `AshA2A.SPIFFE.WorkloadWatcher`:
  SVID stream received + parsed; rotation witnessed (new SVID delivered before
  expiry, cache updated); socket-down -> fail-closed last-known-good retained
  with expiry-bounded trust; reconnect witnessed.

  Zero mocks: the SPIRE agent is a real process on a real UNIX domain socket,
  speaking the emulated Workload API wire protocol (gRPC message framing +
  X509SVIDUpdate protobufs); all certificates are real X.509 generated
  per-test via :public_key and validated with real
  :public_key.pkix_path_validation.
  """

  use ExUnit.Case, async: true

  alias AshA2A.SPIFFE.TrustBundle
  alias AshA2A.SPIFFE.WorkloadWatcher

  alias __MODULE__.FakeSpireAgent
  alias __MODULE__.SpiffeTestCerts

  @trust_domain "td.test"

  setup do
    path =
      Path.join(System.tmp_dir!(), "spire-agent-test-#{System.unique_integer([:positive])}.sock")

    {:ok, agent} =
      FakeSpireAgent.start_link(
        socket_path: path,
        trust_domain: @trust_domain,
        name: agent_name()
      )

    on_exit(fn -> File.rm(path) end)

    {:ok, agent: agent, socket_path: path, watcher_name: watcher_name()}
  end

  # ------------------------------------------------------------------
  # Court 1: SVID stream received + parsed (+ real chain validation)
  # ------------------------------------------------------------------

  test "streams and parses the X.509 SVID over the real UNIX socket", %{
    socket_path: path,
    watcher_name: name
  } do
    {:ok, watcher} = start_watcher(name, path)

    assert {:ok, svid} = wait_until(fn -> WorkloadWatcher.current_svid(watcher) end)
    assert {:ok, %TrustBundle{} = bundle} = WorkloadWatcher.trust_bundle(watcher)

    assert svid.identity.trust_domain == @trust_domain
    assert svid.identity.uri == "spiffe://td.test/workload/a"

    # real crypto: the streamed SVID validates against the streamed bundle root
    assert [root_der] = bundle.certs
    assert {:ok, _} = :public_key.pkix_path_validation(root_der, [svid.cert], [])

    # bundle digest is the content identity of the roots
    assert TrustBundle.digest(bundle.certs) == bundle.digest
    assert WorkloadWatcher.status(watcher) == :watching
  end

  # ------------------------------------------------------------------
  # Court 2: rotation witnessed — new SVID delivered BEFORE expiry
  # ------------------------------------------------------------------

  test "rotation delivers a new SVID and updates the cache before expiry", %{
    agent: agent,
    socket_path: path,
    watcher_name: name
  } do
    {:ok, watcher} = start_watcher(name, path)

    assert {:ok, old_svid} = wait_until(fn -> WorkloadWatcher.current_svid(watcher) end)
    assert {:ok, old_bundle} = WorkloadWatcher.trust_bundle(watcher)

    # the agent issues and pushes a fresh SVID + bundle while the stream is up
    :ok = FakeSpireAgent.rotate(agent)

    assert {:ok, new_svid} =
             wait_until(fn ->
               case WorkloadWatcher.current_svid(watcher) do
                 {:ok, %{cert: cert}} = ok ->
                   if cert != old_svid.cert, do: ok

                 _ ->
                   nil
               end
             end)

    assert {:ok, new_bundle} = WorkloadWatcher.trust_bundle(watcher)

    # witnessed BEFORE expiry: at the cache swap the old bundle was still valid
    assert System.system_time(:second) < old_bundle.expires_at

    # cache actually updated: new cert, newer expiry, newer received_at
    assert new_svid.cert != old_svid.cert
    assert new_svid.expires_at > old_svid.expires_at
    assert new_bundle.received_at > old_bundle.received_at
    assert new_bundle.expires_at > old_bundle.expires_at

    # the rotated SVID is a genuinely new certificate under the same root
    assert [root_der] = new_bundle.certs
    assert {:ok, _} = :public_key.pkix_path_validation(root_der, [new_svid.cert], [])
  end

  # ------------------------------------------------------------------
  # Court 3: socket-down -> fail-closed LKG retained, expiry-bounded
  # ------------------------------------------------------------------

  test "socket down retains last-known-good with expiry-bounded trust", %{
    socket_path: path,
    watcher_name: name
  } do
    # a fresh agent whose SVID expires in 3 seconds
    short_path = path <> ".short"
    on_exit(fn -> File.rm(short_path) end)

    {:ok, agent3} =
      FakeSpireAgent.start_link(
        socket_path: short_path,
        trust_domain: @trust_domain,
        name: agent_name(),
        svid_ttl: 3
      )

    {:ok, watcher} = start_watcher(name, short_path)

    assert {:ok, svid} = wait_until(fn -> WorkloadWatcher.current_svid(watcher) end)
    assert {:ok, bundle} = WorkloadWatcher.trust_bundle(watcher)
    assert svid.expires_at == bundle.expires_at

    # stream drops: last-known-good retained, status degraded
    :ok = FakeSpireAgent.drop_connections(agent3)

    assert :degraded =
             wait_until(fn ->
               if WorkloadWatcher.status(watcher) == :degraded, do: :degraded
             end)

    # ...and the LKG bundle + SVID remain queryable (expiry-bounded trust)
    assert {:ok, _} = WorkloadWatcher.trust_bundle(watcher)
    assert {:ok, _} = WorkloadWatcher.current_svid(watcher)

    # past expiry the same queries FAIL CLOSED (never serve a stale bundle)
    wait_past(bundle.expires_at)

    assert {:error, :trust_bundle_expired} = WorkloadWatcher.trust_bundle(watcher)
    assert {:error, :trust_bundle_expired} = WorkloadWatcher.current_svid(watcher)
    assert {:error, :trust_bundle_expired} = WorkloadWatcher.bundle_digest(watcher)
  end

  # ------------------------------------------------------------------
  # Court 4: reconnect witnessed — degraded -> watching, bundle refreshed
  # ------------------------------------------------------------------

  test "reconnects after stream loss and refreshes the bundle", %{
    agent: agent,
    socket_path: path,
    watcher_name: name
  } do
    {:ok, watcher} = start_watcher(name, path)

    assert {:ok, first} = wait_until(fn -> WorkloadWatcher.trust_bundle(watcher) end)

    :ok = FakeSpireAgent.drop_connections(agent)

    assert :degraded =
             wait_until(fn ->
               if WorkloadWatcher.status(watcher) == :degraded, do: :degraded
             end)

    # the watcher auto-reconnects; the agent re-pushes current state on open
    assert :watching =
             wait_until(fn ->
               if WorkloadWatcher.status(watcher) == :watching, do: :watching
             end)

    assert {:ok, refreshed} = WorkloadWatcher.trust_bundle(watcher)
    assert refreshed.received_at >= first.received_at
    assert refreshed.digest == first.digest
  end

  # ------------------------------------------------------------------
  # Court 5: no agent ever on the socket -> fail-closed :no_trust_bundle
  # ------------------------------------------------------------------

  test "refuses with :no_trust_bundle when the agent socket never exists", %{
    socket_path: path,
    watcher_name: name
  } do
    missing = path <> ".missing"

    {:ok, watcher} =
      WorkloadWatcher.start_link(
        name: name,
        socket_path: missing,
        reconnect_backoff_ms: 5_000
      )

    assert {:error, :no_trust_bundle} = WorkloadWatcher.trust_bundle(watcher)
    assert {:error, :no_trust_bundle} = WorkloadWatcher.current_svid(watcher)

    assert :degraded =
             wait_until(fn ->
               if WorkloadWatcher.status(watcher) == :degraded, do: :degraded
             end)
  end

  # ------------------------------------------------------------------
  # Collaborators — all real: real sockets, real certs, real wire bytes
  # ------------------------------------------------------------------

  defp start_watcher(name, path) do
    WorkloadWatcher.start_link(
      name: name,
      socket_path: path,
      rotation_lead_ms: 60_000,
      reconnect_backoff_ms: 100
    )
  end

  defp agent_name, do: :"spire_agent_#{System.unique_integer([:positive])}"
  defp watcher_name, do: :"spiffe_watcher_#{System.unique_integer([:positive])}"

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("wait_until: condition not met within #{deadline} deadline")
        else
          Process.sleep(20)
          do_wait_until(fun, deadline)
        end

      value ->
        value
    end
  end

  defp wait_past(epoch_secs, margin \\ 1) do
    now = System.system_time(:second)

    if now < epoch_secs + margin do
      Process.sleep((epoch_secs + margin - now) * 1000)
    end
  end

  # ------------------------------------------------------------------

  defmodule SpiffeTestCerts do
    @moduledoc """
    Real X.509 generation via :public_key — hand-built OTPTBSCertificate
    records signed with `:public_key.pkix_sign/2`, so validity is exact to the
    second (rotation-before-expiry needs sub-minute cert lifetimes).
    """

    def root_ca(cn \\ "SPIFFE Test Root", not_after \\ nil) do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      now = System.system_time(:second)
      not_after = not_after || now + 3600

      tbs =
        tbs(
          serial: 1,
          subject: cn,
          issuer: cn,
          not_before: now - 60,
          not_after: not_after,
          spki: spki(key),
          extensions: [
            {:Extension, {2, 5, 29, 19}, true, {:BasicConstraints, true, :asn1_NOVALUE}}
          ]
        )

      %{cert: :public_key.pkix_sign(tbs, key), key: key}
    end

    @doc "Issues a workload SVID cert signed by the CA, with a URI SAN."
    def svid(ca, spiffe_id, ttl_secs) do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      now = System.system_time(:second)

      tbs =
        tbs(
          serial: :rand.uniform(2 ** 31),
          subject: "Workload",
          issuer: "SPIFFE Test Root",
          not_before: now - 60,
          not_after: now + ttl_secs,
          spki: spki(key),
          extensions: [
            {:Extension, {2, 5, 29, 17}, false,
             [{:uniformResourceIdentifier, String.to_charlist(spiffe_id)}]}
          ]
        )

      %{cert: :public_key.pkix_sign(tbs, ca.key)}
    end

    defp tbs(opts) do
      {:OTPTBSCertificate, :v3, Keyword.fetch!(opts, :serial),
       {:SignatureAlgorithm, {1, 2, 840, 113549, 1, 1, 11}, :asn1_NOVALUE},
       name(Keyword.fetch!(opts, :issuer)), validity(Keyword.fetch!(opts, :not_before), Keyword.fetch!(opts, :not_after)),
       name(Keyword.fetch!(opts, :subject)), Keyword.fetch!(opts, :spki), :asn1_NOVALUE,
       :asn1_NOVALUE, Keyword.get(opts, :extensions, [])}
    end

    defp validity(nb, na), do: {:Validity, {:utcTime, utc(nb)}, {:utcTime, utc(na)}}

    defp utc(secs) do
      %{year: y, month: mo, day: d, hour: h, minute: mi, second: s} =
        DateTime.from_unix!(secs, :second)

      :io_lib.format("~2..0B~2..0B~2..0B~2..0B~2..0B~2..0BZ", [
        rem(y, 100),
        mo,
        d,
        h,
        mi,
        s
      ])
      |> IO.iodata_to_binary()
    end

    defp name(cn) do
      {:rdnSequence,
       [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:printableString, cn}}]]}
    end

    defp spki({:RSAPrivateKey, _v, n, e, _d, _p, _q, _dp, _dq, _qi, _other}) do
      {:OTPSubjectPublicKeyInfo,
       {:PublicKeyAlgorithm, {1, 2, 840, 113549, 1, 1, 1}, :asn1_NOVALUE}, {:RSAPublicKey, n, e}}
    end
  end

  # ------------------------------------------------------------------


  defmodule FakeSpireAgent do
    @moduledoc """
    A REAL process listening on a REAL UNIX domain socket emulating the SPIRE
    Workload API wire protocol: on every accepted connection it pushes the
    current `X509SVIDUpdate` (gRPC message framing + protobuf) exactly as a
    SPIRE agent does on stream open. `rotate/0` issues and pushes a genuinely
    new X.509 SVID (new key, new validity, real :public_key signature);
    `drop_connections/0` closes live streams like an agent restart.
    """

    use GenServer

    import Bitwise

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @doc "Issues a fresh SVID + bundle and pushes the update to live streams."
    def rotate(server), do: GenServer.call(server, :rotate)

    @doc "Closes every live workload stream (agent-restart emulation)."
    def drop_connections(server), do: GenServer.call(server, :drop_connections)

    @impl GenServer
    def init(opts) do
      path = Keyword.fetch!(opts, :socket_path)
      trust_domain = Keyword.fetch!(opts, :trust_domain)
      ttl = Keyword.get(opts, :svid_ttl, 3600)
      File.rm(path)

      case :gen_tcp.listen(0,
             ifaddr: {:local, to_charlist(path)},
             backlog: 10,
             mode: :binary,
             active: false
           ) do
        {:ok, listen_socket} ->
          spiffe_id = "spiffe://#{trust_domain}/workload/a"
          ca = SpiffeTestCerts.root_ca()
          svid = SpiffeTestCerts.svid(ca, spiffe_id, ttl)

          state = %{
            path: path,
            trust_domain: trust_domain,
            spiffe_id: spiffe_id,
            ttl: ttl,
            listen: listen_socket,
            ca: ca,
            sockets: %{},
            update: nil,
            serial: 1
          }

          state = %{state | update: build_update(state)}
          Process.send_after(self(), :accept, 0)
          {:ok, state}

        {:error, reason} ->
          {:stop, {:listen_failed, path, reason}}
      end
    end

    @impl GenServer
    def handle_info(:accept, state) do
      case :gen_tcp.accept(state.listen, 50) do
        {:ok, socket} ->
          :gen_tcp.controlling_process(socket, self())
          :inet.setopts(socket, active: true)
          :gen_tcp.send(socket, frame(state.update))
          Process.send_after(self(), :accept, 0)
          {:noreply, %{state | sockets: Map.put(state.sockets, socket, true)}}

        {:error, :timeout} ->
          Process.send_after(self(), :accept, 0)
          {:noreply, state}

        {:error, :closed} ->
          {:noreply, state}
      end
    end

    def handle_info({:tcp, _socket, _data}, state), do: {:noreply, state}

    def handle_info({:tcp_closed, socket}, state) do
      {:noreply, %{state | sockets: Map.delete(state.sockets, socket)}}
    end

    def handle_info({:tcp_error, socket}, state) do
      {:noreply, %{state | sockets: Map.delete(state.sockets, socket)}}
    end

    @impl GenServer
    def handle_call(:rotate, _from, state) do
      state = %{state | serial: state.serial + 1, update: build_update(state)}
      push(state)
      {:reply, :ok, state}
    end

    def handle_call(:drop_connections, _from, state) do
      Enum.each(Map.keys(state.sockets), &:gen_tcp.close/1)
      {:reply, :ok, %{state | sockets: %{}}}
    end

    defp push(state) do
      Enum.each(Map.keys(state.sockets), fn socket ->
        :gen_tcp.send(socket, frame(state.update))
      end)
    end

    # X509SVIDUpdate { repeated X509SVID svids = 1; repeated bytes bundle = 3; }
    # X509SVID { string spiffe_id = 1; bytes x509_svid = 2; }
    defp build_update(state) do
      svid_cert = SpiffeTestCerts.svid(state.ca, state.spiffe_id, state.ttl)
      svid_msg = len_field(1, state.spiffe_id) <> len_field(2, svid_cert.cert)
      len_field(1, svid_msg) <> len_field(3, state.ca.cert)
    end

    defp frame(msg), do: <<0::8, IO.iodata_length(msg)::32, msg::binary>>

    defp len_field(field, value) when is_integer(field) and is_binary(value) do
      tag = field <<< 3 ||| 2
      <<tag::8, varint(byte_size(value))::binary, value::binary>>
    end

    defp varint(n) when n < 128, do: <<n>>

    defp varint(n), do: <<1::1, rem(n, 128)::7, varint(div(n, 128))::binary>>
  end
end
