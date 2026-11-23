# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Session.R04WebcryptoChannelBindCourtTest do
  @moduledoc """
  R-04 Chicago court: Chromium WebCrypto ECDSA P-256 (`extractable: false`)
  → IndexedDB → refuse export → `AshA2A.Session.Statem` (SessionActor) verifies
  a Wi-Fi↔cellular reconnect with zero cookie/token.

  Real collaborators only: Google Chrome via CDP, real IndexedDB CryptoKey
  storage, real `:gen_statem` session actor, real OTP ECDSA verify. No London
  doubles for SubtleCrypto, IndexedDB, or the session actor.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo

  alias AshA2A.Session.Statem
  alias AshA2A.Session.Supervisor, as: Sess

  @host Path.expand("../../support/hosts/r04_webcrypto_channel_bind.mjs", __DIR__)

  setup do
    if Process.whereis(Sess) == nil, do: start_supervised!(Sess)
    :ok
  end

  defp require_chrome! do
    bins = [
      System.get_env("CHROME_BIN"),
      "/usr/bin/google-chrome-stable",
      "/usr/bin/google-chrome",
      "/usr/local/bin/google-chrome"
    ]

    unless Enum.any?(bins, &(is_binary(&1) and File.exists?(&1))) do
      flunk("BLOCKED: Google Chrome not on PATH; R-04 Chromium boundary unavailable")
    end
  end

  defp require_node! do
    unless match?({_, 0}, System.cmd("node", ["--version"], stderr_to_stdout: true)) do
      flunk("BLOCKED: node is required to drive Chrome CDP for R-04")
    end
  rescue
    ErlangError -> flunk("BLOCKED: node is required to drive Chrome CDP for R-04")
  end

  defp open_host do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("node")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [@host]
        ]
      )

    port
  end

  defp rpc(port, msg) do
    true = Port.command(port, Jason.encode!(msg) <> "\n")
    await_json(port, 30_000)
  end

  defp await_json(port, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    await_json_loop(port, "", deadline)
  end

  defp await_json_loop(port, buf, deadline) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        flunk("R-04 host timed out; buf=#{inspect(buf)}")

      true ->
        receive do
          {^port, {:data, chunk}} ->
            buf = buf <> chunk

            case String.split(buf, "\n", parts: 2) do
              [line, rest] when line != "" ->
                # Keep any remainder for the next call by stuffing it back —
                # for this court each reply is one line and we drain fully.
                _ = rest
                Jason.decode!(line)

              _ ->
                await_json_loop(port, buf, deadline)
            end

          {^port, {:exit_status, status}} ->
            flunk("R-04 host exited #{status}; buf=#{inspect(buf)}")
        after
          1_000 ->
            await_json_loop(port, buf, deadline)
        end
    end
  end

  defp b64_decode!(s) do
    case Base.decode64(s) do
      {:ok, bin} -> bin
      :error -> flunk("bad base64: #{inspect(s)}")
    end
  end

  test "R-04: Chromium non-extractable P-256 binds SessionActor across cookie-free reconnect" do
    require_chrome!()
    require_node!()

    conn_id = "r04-wifi-cellular-#{System.unique_integer([:positive])}"
    {:ok, session} = Sess.start_session(conn_id)

    port = open_host()

    on_exit(fn ->
      if Port.info(port) do
        Port.command(port, Jason.encode!(%{op: "shutdown"}) <> "\n")
        # Drain exit; ignore failures on teardown.
        receive do
          {^port, _} -> :ok
        after
          2_000 ->
            Port.close(port)
        end
      end
    end)

    boot = rpc(port, %{op: "boot"})
    assert boot["ok"] == true, "Chromium WebCrypto boot failed: #{inspect(boot)}"
    assert boot["extractable"] == false
    assert boot["exportRefused"] == true
    assert boot["idbStored"] == true
    assert is_binary(boot["pubB64"])

    pub = b64_decode!(boot["pubB64"])
    assert byte_size(pub) == 65
    assert <<0x04, _::binary>> = pub

    assert {:ok, challenge_b64} = Statem.bind_channel(session, pub)
    assert is_binary(challenge_b64)

    # Path A (Wi-Fi): sign challenge with IndexedDB-held non-extractable key.
    signed1 = rpc(port, %{op: "sign", connId: conn_id, challengeB64: challenge_b64})
    assert signed1["ok"] == true, inspect(signed1)
    assert signed1["extractable"] == false
    sig1 = b64_decode!(signed1["sigB64"])
    assert byte_size(sig1) == 64

    assert {:ok, %{standing: :bound, challenge: next_challenge}} =
             Statem.verify_reconnect(session, %{signature: sig1})

    assert is_binary(next_challenge)
    refute next_challenge == challenge_b64

    # Cookie / token ambient credentials are refused on this surface.
    assert {:error, :cookie_refused} =
             Statem.verify_reconnect(session, %{signature: sig1, cookie: "session=ambient"})

    assert {:error, :token_refused} =
             Statem.verify_reconnect(session, %{signature: sig1, token: "bearer-ambient"})

    # Simulate Wi-Fi → cellular: clear cookies + sessionStorage; IndexedDB kept.
    cleared = rpc(port, %{op: "clear_ambient"})
    assert cleared["ok"] == true
    assert cleared["cookie"] in [nil, ""]
    assert cleared["sessionStorageLength"] == 0

    export = rpc(port, %{op: "probe_export"})
    assert export["exportRefused"] == true

    # Path B (cellular): same IndexedDB key, new challenge, zero cookie/token.
    signed2 = rpc(port, %{op: "sign", connId: conn_id, challengeB64: next_challenge})
    assert signed2["ok"] == true, inspect(signed2)
    assert signed2["extractable"] == false
    sig2 = b64_decode!(signed2["sigB64"])

    assert {:ok, %{standing: :bound, challenge: _}} =
             Statem.verify_reconnect(session, %{signature: sig2})

    # Wrong signature (empty / garbage) is refused — positive falsifier.
    assert {:error, :bad_signature} =
             Statem.verify_reconnect(session, %{signature: :crypto.strong_rand_bytes(64)})

    {_state, data} = :sys.get_state(session)
    assert data.channel_bind.bound? == true
    assert data.channel_bind.reconnects >= 2
  end

  test "ChannelBind refuses malformed public keys and cookie-only proofs without Chrome" do
    conn_id = "r04-unit-#{System.unique_integer([:positive])}"
    {:ok, session} = Sess.start_session(conn_id)

    assert {:error, :bad_public_key} = Statem.bind_channel(session, <<1, 2, 3>>)
    assert {:error, :not_bound} = Statem.verify_reconnect(session, %{signature: <<0::512>>})

    # Lifecycle events still work (SESS ≠ R-04 bind, but must not regress).
    assert {:ok, :projecting} = Statem.send_event(session, :hydrated)
  end
end
