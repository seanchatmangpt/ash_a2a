# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Security.KMS.Local do
  @moduledoc """
  Real local KMS harness for CMEK envelope-encryption courts and dev
  shells (PRD FR-03 / ARD §3.3). A GenServer holding real KEK key
  material in memory, doing real AES-256-GCM wrap/unwrap of DEKs via
  `:crypto` — a hand-written real interface implementation, not a mock.

  * `wrap/2` encrypts the DEK under the KEK's current version (fresh
    random IV per wrap) and returns `{wrapped_dek, kek_version_id}`.
  * `unwrap/3` recovers the DEK under the exact recorded version; a
    tampered or truncated `wrapped_dek` fails AEAD authentication and
    returns `{:error, :unwrap_auth_failed}`.
  * `current_version/1` reports the version `wrap/2` uses.
  * `rotate/1` mints a fresh 256-bit KEK version and makes it current;
    old versions stay unwrap-able for legacy envelopes (the
    non-destructive half of DEK re-wrap rotation).
  * `stop/0` halts the process, so the fail-closed court can drive a
    KMS outage: calls then fail with `{:error, :kms_unavailable}`.

  Wire format of a wrapped DEK: `<<iv::12-bytes, tag::16-bytes, ct>>`,
  AES-256-GCM under the named KEK version key.

  **Not for production**: key material lives in process memory, is
  minted per process, and dies with the process. Restarting the
  harness mints a fresh KEK lineage — wrapped blobs from a dead
  process are unrecoverable by design (a real KEK must survive
  restarts; a test harness must not pretend to). Production hosts bind
  `AshA2A.Security.KMS.Client` to Google Cloud KMS / AWS KMS / Vault
  Transit instead.
  """

  use GenServer
  @behaviour AshA2A.Security.KMS.Client

  @default_name __MODULE__
  @empty_kek %{versions: %{}, current: nil}

  # --- behaviour callbacks (client edge) ---

  @impl true
  def wrap(kek_id, dek) when is_binary(dek) do
    call({:wrap, kek_id, dek})
  end

  @impl true
  def unwrap(kek_id, wrapped, version) do
    call({:unwrap, kek_id, wrapped, version})
  end

  @impl true
  def current_version(kek_id) do
    call({:current_version, kek_id})
  end

  @impl true
  @doc "Behaviour callback: mints the next KEK version and makes it current."
  def rotate_version(kek_id) do
    call({:rotate, kek_id})
  end

  # --- harness controls ---

  @doc """
  Starts the harness (named process). Safe from test setup: an
  already-running instance is left alone.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, @default_name))
  end

  @doc "Ensures the harness is running; returns the registered name."
  @spec ensure_started(keyword()) :: atom()
  def ensure_started(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)

    if GenServer.whereis(name) do
      name
    else
      case start_link(opts) do
        {:ok, _pid} -> name
        {:error, {:already_started, _pid}} -> name
      end
    end
  end

  @doc """
  Mints a fresh 256-bit KEK version and makes it current for `opts`
  `:kek_id` (mints the KEK first if unknown). Old versions remain
  unwrap-able; the non-destructive half of DEK re-wrap rotation.
  """
  @spec rotate(keyword()) :: {:ok, AshA2A.Security.KMS.Client.kek_version_id()} | {:error, term()}
  def rotate(opts \\ []) do
    kek_id = Keyword.get(opts, :kek_id, default_kek_id())
    call({:rotate, kek_id}, Keyword.get(opts, :name, @default_name))
  end

  @doc """
  Stops the harness. Subsequent wrap/unwrap/current_version calls fail
  closed with `{:error, :kms_unavailable}` — the fail-closed court
  drives a KMS outage through this.
  """
  @spec stop(keyword()) :: :ok
  def stop(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)

    case GenServer.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(name)
    end

    :ok
  end

  @doc "Default KEK id the harness and `AshA2A.Security.KeyManager` agree on."
  @spec default_kek_id() :: String.t()
  def default_kek_id, do: "ash-a2a/cmek-kek"

  # --- GenServer callbacks ---

  @impl true
  def init(:ok) do
    {:ok, %{keks: %{}}}
  end

  @impl true
  def handle_call({:wrap, kek_id, dek}, _from, state)
      when is_binary(dek) and byte_size(dek) == 32 do
    case get_kek(state, kek_id).current do
      nil ->
        {version, key, state2} = mint_version(state, kek_id)
        {:reply, {:ok, wrap_under(key, dek), version}, state2}

      version ->
        kek = get_kek(state, kek_id)
        {:reply, {:ok, wrap_under(kek.versions[version], dek), version}, state}
    end
  end

  def handle_call({:wrap, _kek_id, dek}, _from, state) when is_binary(dek) do
    {:reply, {:error, {:invalid_dek_size, byte_size(dek)}}, state}
  end

  def handle_call({:unwrap, kek_id, wrapped, version}, _from, state) do
    kek = get_kek(state, kek_id)

    case kek.versions do
      %{^version => key} ->
        {:reply, unwrap_under(key, wrapped), state}

      _ ->
        {:reply, {:error, {:unknown_kek_version, version}}, state}
    end
  end

  def handle_call({:current_version, kek_id}, _from, state) do
    case get_kek(state, kek_id).current do
      nil ->
        {version, _key, state2} = mint_version(state, kek_id)
        {:reply, {:ok, version}, state2}

      version ->
        {:reply, {:ok, version}, state}
    end
  end

  def handle_call({:rotate, kek_id}, _from, state) do
    {version, _key, state2} = mint_version(state, kek_id)
    {:reply, {:ok, version}, state2}
  end

  # --- internals ---

  defp call(message, name \\ @default_name) do
    case GenServer.whereis(name) do
      nil ->
        {:error, :kms_unavailable}

      _pid ->
        try do
          GenServer.call(name, message)
        catch
          :exit, _ -> {:error, :kms_unavailable}
        end
    end
  end

  defp get_kek(state, kek_id) do
    Map.get(state.keks, kek_id, @empty_kek)
  end

  defp mint_version(state, kek_id) do
    kek = get_kek(state, kek_id)
    version = map_size(kek.versions) + 1
    key = :crypto.strong_rand_bytes(32)
    kek2 = %{versions: Map.put(kek.versions, version, key), current: version}
    {version, key, %{state | keks: Map.put(state.keks, kek_id, kek2)}}
  end

  defp wrap_under(kek, dek) do
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, dek, <<>>, true)
    <<iv::binary-size(12), tag::binary-size(16), ct::binary>>
  end

  defp unwrap_under(kek, <<iv::binary-size(12), tag::binary-size(16), ct::binary>>) do
    try do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, ct, <<>>, tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        _ -> {:error, :unwrap_auth_failed}
      end
    rescue
      _ -> {:error, :unwrap_auth_failed}
    end
  end

  defp unwrap_under(_kek, _malformed) do
    {:error, :malformed_wrapped_dek}
  end
end
