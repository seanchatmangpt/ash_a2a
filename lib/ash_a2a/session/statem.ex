# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Session.Statem do
  @moduledoc """
  Per-connection session `:gen_statem` (FNOX-SJ-SESS-1).

  One process per connection id, registered in `AshA2A.Session.Supervisor.registry/0`
  and started under its `DynamicSupervisor`. Unlike `AshA2A.Twin.Server`, which is
  one shared actor, a crash here is isolated to a single connection.

  States and the only valid transitions:

      :hydrating        --:hydrated-->      :projecting
      :projecting       --:projected-->     :awaiting_step_up
      :awaiting_step_up --:step_up_done-->  :projecting

  Any other lifecycle event is answered `{:error, {:invalid_event, state, event}}`
  and leaves the state untouched. `:sys.get_state/1` returns `{state, data}`.

  ## Channel bind (R-04)

  Independently of the lifecycle events above, a client may bind an ECDSA P-256
  public key (`bind_channel/2`) and later prove possession across a network-path
  change with `verify_reconnect/2`. Cookies and bearer tokens are refused on
  that surface — see `AshA2A.Session.ChannelBind`.
  """

  @behaviour :gen_statem

  alias AshA2A.Session.ChannelBind

  @type state :: :hydrating | :projecting | :awaiting_step_up
  @type event :: :hydrated | :projected | :step_up_done
  @type conn_id :: term()

  @transitions %{
    {:hydrating, :hydrated} => :projecting,
    {:projecting, :projected} => :awaiting_step_up,
    {:awaiting_step_up, :step_up_done} => :projecting
  }

  @doc "Child spec; sessions are `:temporary` (a dead connection is not resurrected)."
  def child_spec(conn_id) do
    %{
      id: {__MODULE__, conn_id},
      start: {__MODULE__, :start_link, [conn_id]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "Starts a session registered under `conn_id` in the session registry."
  @spec start_link(conn_id()) :: :gen_statem.start_ret()
  def start_link(conn_id) do
    :gen_statem.start_link(via(conn_id), __MODULE__, conn_id, [])
  end

  @doc "Registry `:via` name for a connection id."
  @spec via(conn_id()) :: {:via, Registry, {atom(), conn_id()}}
  def via(conn_id), do: {:via, Registry, {AshA2A.Session.Supervisor.registry(), conn_id}}

  @doc """
  Sends an event synchronously. Returns `{:ok, new_state}` or
  `{:error, {:invalid_event, state, event}}`.
  """
  @spec send_event(pid() | conn_id(), event()) ::
          {:ok, state()} | {:error, {:invalid_event, state(), term()}}
  def send_event(pid, event) when is_pid(pid), do: :gen_statem.call(pid, {:event, event})
  def send_event(conn_id, event), do: :gen_statem.call(via(conn_id), {:event, event})

  @doc """
  Binds a raw uncompressed P-256 public key to this session and returns a
  Base64 challenge the client must sign with its non-extractable private key.
  """
  @spec bind_channel(pid() | conn_id(), binary()) ::
          {:ok, String.t()} | {:error, :bad_public_key | :already_bound}
  def bind_channel(pid, public_key) when is_pid(pid),
    do: :gen_statem.call(pid, {:bind_channel, public_key})

  def bind_channel(conn_id, public_key),
    do: :gen_statem.call(via(conn_id), {:bind_channel, public_key})

  @doc """
  Verifies a reconnect proof. `proof` must be `%{signature: <<r||s::64>>}` with
  no `:cookie` / `:token` keys (and no `"cookie"` / `"token"` string keys).
  Presenting either is a typed refusal — Wi-Fi↔cellular continuity is proved
  by the bound key alone.

  On success returns `{:ok, %{standing: :bound, challenge: next_challenge_b64}}`
  where `challenge` is the next nonce the client must sign on a subsequent
  path change.
  """
  @spec verify_reconnect(pid() | conn_id(), map()) ::
          {:ok, %{standing: :bound, challenge: String.t()}}
          | {:error,
             :not_bound
             | :cookie_refused
             | :token_refused
             | :bad_signature
             | :bad_signature_encoding
             | :missing_signature}
  def verify_reconnect(pid, proof) when is_pid(pid) and is_map(proof),
    do: :gen_statem.call(pid, {:verify_reconnect, proof})

  def verify_reconnect(conn_id, proof) when is_map(proof),
    do: :gen_statem.call(via(conn_id), {:verify_reconnect, proof})

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(conn_id),
    do: {:ok, :hydrating, %{conn_id: conn_id, transitions: 0, channel_bind: nil}}

  @impl true
  def handle_event({:call, from}, {:event, event}, state, data) do
    case Map.fetch(@transitions, {state, event}) do
      {:ok, next} ->
        {:next_state, next, %{data | transitions: data.transitions + 1},
         [{:reply, from, {:ok, next}}]}

      :error ->
        {:keep_state_and_data, [{:reply, from, {:error, {:invalid_event, state, event}}}]}
    end
  end

  def handle_event({:call, from}, {:bind_channel, public_key}, _state, data) do
    case data.channel_bind do
      %{public_key: _} ->
        {:keep_state_and_data, [{:reply, from, {:error, :already_bound}}]}

      _ ->
        case ChannelBind.normalize_public_key(public_key) do
          {:ok, key} ->
            challenge = ChannelBind.mint_challenge()

            bind = %{
              public_key: key,
              challenge: challenge,
              bound?: false,
              reconnects: 0
            }

            {:keep_state, %{data | channel_bind: bind},
             [{:reply, from, {:ok, Base.encode64(challenge)}}]}

          {:error, reason} ->
            {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
        end
    end
  end

  def handle_event({:call, from}, {:verify_reconnect, proof}, _state, data) do
    case do_verify_reconnect(data, proof) do
      {:ok, new_bind} ->
        reply = %{standing: :bound, challenge: Base.encode64(new_bind.challenge)}

        {:keep_state, %{data | channel_bind: new_bind}, [{:reply, from, {:ok, reply}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, _other, state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, {:invalid_event, state, :unknown}}}]}
  end

  def handle_event(_type, _content, _state, _data), do: :keep_state_and_data

  defp do_verify_reconnect(%{channel_bind: nil}, _proof), do: {:error, :not_bound}

  defp do_verify_reconnect(%{channel_bind: bind, conn_id: conn_id}, proof) when is_map(proof) do
    cond do
      Map.has_key?(proof, :cookie) or Map.has_key?(proof, "cookie") ->
        {:error, :cookie_refused}

      Map.has_key?(proof, :token) or Map.has_key?(proof, "token") ->
        {:error, :token_refused}

      true ->
        sig = Map.get(proof, :signature) || Map.get(proof, "signature")

        case sig do
          sig when is_binary(sig) ->
            case ChannelBind.verify_signature(bind.public_key, conn_id, bind.challenge, sig) do
              :ok ->
                next = ChannelBind.mint_challenge()

                {:ok, %{bind | bound?: true, reconnects: bind.reconnects + 1, challenge: next}}

              {:error, reason} ->
                {:error, reason}
            end

          _ ->
            {:error, :missing_signature}
        end
    end
  end
end
