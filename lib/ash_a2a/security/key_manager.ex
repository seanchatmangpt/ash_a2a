# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Security.KeyManager do
  @moduledoc """
  CMEK envelope-encryption orchestration (PRD FR-03 / ARD §3.3,
  module `AshA2A.Security.KeyManager`).

  Implements the standard envelope pattern:

    1. Generates an ephemeral 256-bit DEK with
       `:crypto.strong_rand_bytes(32)` (via `AshA2A.Security.CMEK`).
    2. Encrypts the payload with AES-256-GCM under the DEK.
    3. Calls a `AshA2A.Security.KMS.Client` binding (Google Cloud KMS
       / AWS KMS / Vault Transit shape) to wrap the DEK under the
       customer's KEK: `WrappedDEK = Encrypt_KEK(DEK)`.
    4. Persists `{ciphertext, wrapped_dek, iv, tag, kek_version_id}`.

  Rotation (FR-03.3) re-wraps the DEK under a new KEK version *without
  decrypting the payload*: the `ciphertext`, `iv`, and `tag` bytes are
  carried over untouched; only `wrapped_dek` and `kek_version_id`
  change.

  ## KMS binding selection (highest first)

  1. `opts[:kms_client]` — explicit caller override;
  2. `config :ash_a2a, :cmek_kms_client` — a module implementing
     `AshA2A.Security.KMS.Client`;
  3. none — **fail closed**: every operation refuses with the typed
     code `:refused_cmek_kms_unavailable`. There is no plaintext
     fallback and no locally-held key material.

  The same fail-closed rule applies when a configured KMS is
  unreachable (its calls return errors): every KMS failure becomes a
  typed refusal, never a decryption attempt under some fallback key.

  ## Typed refusals

  * `:refused_cmek_kms_unavailable` — no KMS client configured, or the
    KMS reports unavailability;
  * `:refused_cmek_unwrap_failed` — the KMS could not recover the DEK
    (unknown KEK version, malformed or tampered `wrapped_dek`);
  * `:refused_cmek_tamper_detected` — AEAD authentication failed on
    the payload (ciphertext/tag/IV modified);
  * `:refused_cmek_invalid_envelope` — the envelope is missing or
    malformed fields.

  All refusals are `{:error, code, detail}` triples; expected failure
  paths never raise.

  ## Supervision (enterprise supervisor `:kms` gate)

  The module is also a startable OTP child: `child_spec/1` (from
  `use GenServer`) starts a thin supervised holder process via
  `start_link/1`. The holder owns the resolved KMS binding (`kms_client`,
  `kek_id`) and, in `init/1`, applies the same `:kms` -> `:cmek_kms_client`
  projection the enterprise supervisor performs, so a supervised
  KeyManager is self-sufficient wherever it is placed. The encrypt /
  decrypt / rotate functions stay pure and resolve their KMS binding
  per call (opts first, then `config :ash_a2a, :cmek_kms_client`), so
  starting or stopping the holder never changes the fail-closed
  behavior of the API. `AshA2A.Enterprise.Supervisor` starts this child
  when `config :ash_a2a, :kms` is set; with no KMS client configured the
  holder still starts and every operation refuses
  `:refused_cmek_kms_unavailable` exactly as before.
  """

  use GenServer

  alias AshA2A.Security.CMEK

  @default_kek_id "ash-a2a/cmek-kek"
  @typedoc false
  @type opts :: keyword()

  @type envelope :: CMEK.envelope()

  @type refusal_code ::
          :refused_cmek_kms_unavailable
          | :refused_cmek_unwrap_failed
          | :refused_cmek_tamper_detected
          | :refused_cmek_invalid_envelope

  @doc """
  Encrypts `plaintext` into a fresh envelope: ephemeral DEK, AES-256-GCM
  payload, DEK wrapped under the KEK's current version.
  """
  @spec encrypt(binary(), opts()) :: {:ok, envelope()} | {:error, refusal_code(), String.t()}
  def encrypt(plaintext, opts \\ []) when is_binary(plaintext) do
    with {:ok, kms, kek_id} <- resolve_kms(opts) do
      dek = CMEK.generate_dek()

      with {:ok, payload} <- CMEK.encrypt_payload(plaintext, dek),
           {:ok, wrapped_dek, kek_version_id} <- wrap_dek(kms, kek_id, dek) do
        {:ok,
         %{
           ciphertext: payload.ciphertext,
           wrapped_dek: wrapped_dek,
           iv: payload.iv,
           tag: payload.tag,
           kek_version_id: kek_version_id,
           algorithm: CMEK.algorithm(),
           kek_id: kek_id
         }}
      end
    end
  end

  @doc """
  Decrypts `envelope`: unwraps the DEK through the KMS under the
  recorded KEK version, then verifies and decrypts the payload. KMS
  failure fails closed; payload tamper is a typed refusal.
  """
  @spec decrypt(envelope(), opts()) :: {:ok, binary()} | {:error, refusal_code(), String.t()}
  def decrypt(envelope, opts \\ []) do
    with {:ok, kms, kek_id} <- resolve_kms(opts),
         :ok <- CMEK.validate_envelope(envelope),
         {:ok, dek} <- unwrap_dek(kms, kek_id, envelope) do
      CMEK.decrypt_payload(envelope, dek)
    end
  end

  @doc """
  Re-wraps the DEK under a NEW KEK version without decrypting the
  payload: the KMS first advances the KEK to its next version
  (`rotate_version/1` — the cloud-side rotation event), then the still
  unwrapped DEK is wrapped under that new current version. Returns an
  envelope whose `ciphertext`, `iv`, and `tag` are byte-identical to
  the input's; only `wrapped_dek` and `kek_version_id` move.
  """
  @spec rotate(envelope(), opts()) :: {:ok, envelope()} | {:error, refusal_code(), String.t()}
  def rotate(envelope, opts \\ []) do
    with {:ok, kms, kek_id} <- resolve_kms(opts),
         :ok <- CMEK.validate_envelope(envelope),
         {:ok, dek} <- unwrap_dek(kms, envelope_kek_id(envelope, kek_id), envelope),
         {:ok, _new_version} <- rotate_version(kms, kek_id),
         {:ok, wrapped_dek, kek_version_id} <- wrap_dek(kms, kek_id, dek) do
      {:ok,
       %{
         envelope
         | wrapped_dek: wrapped_dek,
           kek_version_id: kek_version_id,
           algorithm: CMEK.algorithm(),
           kek_id: kek_id
       }}
    end
  end

  @doc """
  Generates a 256-bit DEK (FR-03.2); exported for courts and hosts
  that pre-provision DEKs. The DEK is never persisted by this module.
  """
  @spec generate_dek() :: CMEK.dek()
  def generate_dek, do: CMEK.generate_dek()

  @doc "The KEK id used when none is configured."
  @spec default_kek_id() :: String.t()
  def default_kek_id, do: @default_kek_id

  # --- supervised holder child (enterprise supervisor :kms gate) ---

  @typedoc "KMS binding owned by the supervised holder."
  @type kms_binding :: %{kms_client: module() | nil, kek_id: String.t()}

  @doc """
  Starts the supervised KeyManager holder (the enterprise supervisor's
  `:kms` child). `opts` accepts `:name` (default `__MODULE__`),
  `:kms_client`, and `:kek_id`; anything unset is resolved from
  `config :ash_a2a, :cmek_kms_client` / `:cmek_kek_id` in `init/1`,
  after applying the `:kms` -> `:cmek_kms_client` projection. The holder
  owns the binding only — the encrypt/decrypt/rotate API is unchanged.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The KMS binding the supervised holder resolved at start:
  `%{kms_client: module() | nil, kek_id: String.t()}`. A `nil`
  `kms_client` means the holder started fail-closed (no KMS configured);
  every operation still refuses `:refused_cmek_kms_unavailable`.
  """
  @spec kms_binding(GenServer.server()) :: {:ok, kms_binding()} | {:error, term()}
  def kms_binding(server \\ __MODULE__), do: GenServer.call(server, :binding)

  @impl true
  def init(opts) do
    :ok = project_kms_binding()

    {:ok,
     %{
       kms_client: Keyword.get(opts, :kms_client) || Application.get_env(:ash_a2a, :cmek_kms_client),
       kek_id:
         Keyword.get(opts, :kek_id) || Application.get_env(:ash_a2a, :cmek_kek_id) ||
           @default_kek_id
     }}
  end

  @impl true
  def handle_call(:binding, _from, state), do: {:reply, {:ok, state}, state}

  # Mirrors `AshA2A.Enterprise.Supervisor`'s `:kms` projection: when the
  # `:kms` gate names a client module and the host has not set
  # `:cmek_kms_client`, project it. Explicit host config always wins and
  # the fail-closed resolution order is untouched.
  defp project_kms_binding do
    case Application.get_env(:ash_a2a, :kms) do
      binding when is_list(binding) ->
        client = Keyword.get(binding, :client)

        if is_atom(client) and client != nil and
             Application.get_env(:ash_a2a, :cmek_kms_client) in [nil, false] do
          Application.put_env(:ash_a2a, :cmek_kms_client, client)
        end

        :ok

      _other ->
        :ok
    end
  end

  # --- internals ---

  defp resolve_kms(opts) do
    case opts[:kms_client] || Application.get_env(:ash_a2a, :cmek_kms_client) do
      nil ->
        {:error, :refused_cmek_kms_unavailable,
         "no KMS client configured (opts :kms_client or config :ash_a2a, :cmek_kms_client); refusing fail-closed — no plaintext fallback"}

      kms when is_atom(kms) ->
        {:ok, kms, Keyword.get(opts, :kek_id) || kek_id_env() || @default_kek_id}

      other ->
        {:error, :refused_cmek_kms_unavailable,
         "KMS client #{inspect(other)} is not a module; refusing fail-closed"}
    end
  end

  defp kek_id_env, do: Application.get_env(:ash_a2a, :cmek_kek_id)

  defp rotate_version(kms, kek_id) do
    case kms.rotate_version(kek_id) do
      {:ok, _version} = ok ->
        ok

      {:error, :kms_unavailable} ->
        {:error, :refused_cmek_kms_unavailable,
         "KMS reports unavailability during KEK version rotation; refusing fail-closed"}

      {:error, reason} ->
        {:error, :refused_cmek_kms_unavailable,
         "KEK version rotation failed (#{inspect(reason)}); refusing fail-closed"}
    end
  catch
    :error, reason ->
      {:error, :refused_cmek_kms_unavailable,
       "KEK version rotation raised #{inspect(reason)}; refusing fail-closed"}

    :exit, reason ->
      {:error, :refused_cmek_kms_unavailable,
       "KEK version rotation exited #{inspect(reason)}; refusing fail-closed"}
  end

  defp wrap_dek(kms, kek_id, dek) do
    case kms.wrap(kek_id, dek) do
      {:ok, wrapped_dek, kek_version_id} ->
        {:ok, wrapped_dek, kek_version_id}

      {:error, :kms_unavailable} ->
        {:error, :refused_cmek_kms_unavailable,
         "KMS reports unavailability during DEK wrap; refusing fail-closed"}

      {:error, reason} ->
        {:error, :refused_cmek_kms_unavailable,
         "KEK wrap failed (#{inspect(reason)}); refusing fail-closed"}
    end
  catch
    :error, reason ->
      {:error, :refused_cmek_kms_unavailable,
       "KEK wrap raised #{inspect(reason)}; refusing fail-closed"}

    :exit, reason ->
      {:error, :refused_cmek_kms_unavailable,
       "KEK wrap exited #{inspect(reason)}; refusing fail-closed"}
  end

  defp unwrap_dek(kms, kek_id, envelope) do
    case kms.unwrap(kek_id, envelope.wrapped_dek, envelope.kek_version_id) do
      {:ok, dek} ->
        {:ok, dek}

      {:error, :kms_unavailable} ->
        {:error, :refused_cmek_kms_unavailable,
         "KMS reports unavailability during DEK unwrap; refusing fail-closed"}

      {:error, reason} ->
        {:error, :refused_cmek_unwrap_failed,
         "KEK unwrap failed (#{inspect(reason)}); wrapped_dek malformed, KEK version unknown, or KMS degraded"}
    end
  catch
    # A misbehaving KMS binding that raises must also fail closed.
    :error, reason ->
      {:error, :refused_cmek_unwrap_failed,
       "KEK unwrap raised #{inspect(reason)}; refusing fail-closed"}

    :exit, reason ->
      {:error, :refused_cmek_unwrap_failed,
       "KEK unwrap exited #{inspect(reason)}; refusing fail-closed"}
  end

  defp envelope_kek_id(envelope, default) do
    case envelope do
      %{kek_id: kek_id} when is_binary(kek_id) -> kek_id
      _ -> default
    end
  end
end
