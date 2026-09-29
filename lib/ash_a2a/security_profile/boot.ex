defmodule AshA2A.SecurityProfile.Boot do
  @moduledoc """
  Boot enforcement for the compiled `AshA2A.SecurityProfile`
  (RFC-SA2A-007). `run!/0` is called from `AshA2A.Application.start/2`
  before any child starts.

  ## `:strict` refuses (each a named violation)

    * `:outbox_key_missing` - neither `:receipt_outbox_key` nor
      `:receipt_binding_key` is a non-empty binary
    * `:outbox_dir_not_durable` - `:receipt_outbox_dir` unset or under a
      volatile tmp path (`AshA2A.ReceiptStore.durable_path?/1`)
    * `:receipt_store_in_memory` - `AshA2A.ReceiptStore.Memory`
    * `:capability_release_mode_legacy` - `:capability_release_mode` is not
      `:strict`
    * `:authority_broker_missing` - no `:authority_broker`
    * `:kill_switch_class_missing` - `:kill_switch_class` is nil
    * `:transport_verified_policy_forbidden` - `:authority_policy` is
      `:transport_verified_grants_capability` (the legacy acknowledgement
      does not lift this under `:strict`)

  It also runs `AshA2A.Authority.SecurityPreflight.check!/1` (forced) and
  `AshA2A.ReceiptStore.boot_check/0`; any failure raises
  `AshA2A.Authority.SecurityPreflight.Error`.

  ## `:legacy_compat`

  Logs the strict violations as warnings and emits
  `[:ash_a2a, :security_profile, :legacy_compat]`; the ordinary
  `SecurityPreflight` rules (`strict_security` config) still apply.

  ## `:dev_bypass`

  Prints a loud banner and emits `[:ash_a2a, :security_profile, :dev_bypass]`.
  Receipt producers stamp receipts via `AshA2A.SecurityProfile.stamp/1`.

  In every profile `ReceiptStore.boot_check/0` failures raise when the
  profile is `:strict` or `config :ash_a2a, :production` is true, and are
  logged otherwise.
  """

  require Logger

  alias AshA2A.Authority.SecurityPreflight
  alias AshA2A.ReceiptStore
  alias AshA2A.SecurityProfile

  @type violation :: SecurityPreflight.violation()
  @type snapshot :: %{
          outbox_key: binary() | nil,
          outbox_dir: String.t() | nil,
          receipt_store: module(),
          capability_release_mode: atom(),
          authority_broker: module() | nil,
          kill_switch_class: term(),
          authority_policy: atom() | nil
        }

  @doc false
  def __sa2a_refusal_codes__ do
    %{
      outbox_key_missing: :refused_receipt,
      outbox_dir_not_durable: :refused_receipt,
      receipt_store_in_memory: :refused_receipt,
      receipt_store_boot_check_failed: :refused_receipt,
      capability_release_mode_legacy: :refused_authority,
      authority_broker_missing: :refused_authority,
      kill_switch_class_missing: :refused_authority,
      transport_verified_policy_forbidden: :refused_authority
    }
  end

  @doc "Reads the real application env into a snapshot."
  @spec snapshot() :: snapshot()
  def snapshot do
    %{
      outbox_key: AshA2A.ReceiptOutbox.integrity_key(),
      outbox_dir: Application.get_env(:ash_a2a, :receipt_outbox_dir),
      receipt_store: Application.get_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Memory),
      capability_release_mode:
        if(Application.get_env(:ash_a2a, :capability_release_mode) == :strict,
          do: :strict,
          else: :legacy
        ),
      authority_broker: broker_module(Application.get_env(:ash_a2a, :authority_broker)),
      kill_switch_class: Application.get_env(:ash_a2a, :kill_switch_class),
      authority_policy: Application.get_env(:ash_a2a, :authority_policy)
    }
  end

  @doc """
  The refusal violations `profile` imposes on `snapshot`. Pure. Only
  `:strict` refuses; other profiles return `[]`.
  """
  @spec violations(atom(), snapshot()) :: [violation()]
  def violations(:strict, s) do
    [
      if(not (is_binary(s.outbox_key) and byte_size(s.outbox_key) > 0),
        do:
          v(
            :outbox_key_missing,
            "receipt outbox is unkeyed; set :receipt_outbox_key or :receipt_binding_key"
          )
      ),
      if(not ReceiptStore.durable_path?(s.outbox_dir),
        do:
          v(
            :outbox_dir_not_durable,
            ":receipt_outbox_dir #{inspect(s.outbox_dir)} is unset or under a tmp directory"
          )
      ),
      if(s.receipt_store == AshA2A.ReceiptStore.Memory,
        do: v(:receipt_store_in_memory, ":receipt_store is AshA2A.ReceiptStore.Memory")
      ),
      if(s.capability_release_mode != :strict,
        do:
          v(
            :capability_release_mode_legacy,
            ":capability_release_mode must be :strict (capabilities unbound under :legacy)"
          )
      ),
      if(is_nil(s.authority_broker),
        do: v(:authority_broker_missing, "no :authority_broker configured")
      ),
      if(is_nil(s.kill_switch_class),
        do: v(:kill_switch_class_missing, ":kill_switch_class is nil; no class can be halted")
      ),
      if(s.authority_policy == :transport_verified_grants_capability,
        do:
          v(
            :transport_verified_policy_forbidden,
            ":authority_policy :transport_verified_grants_capability is refused under :strict"
          )
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  def violations(_profile, _snapshot), do: []

  @doc "Enforces the compiled profile against the real env. Raises or returns `:ok`."
  @spec run!() :: :ok
  def run! do
    enforce!(SecurityProfile.current(), snapshot())
  end

  @doc """
  Enforces an already-resolved `profile` against `snapshot` (the profile
  itself is resolved only by `run!/0` from the compiled module).
  """
  @spec enforce!(atom(), snapshot()) :: :ok
  def enforce!(:strict, snapshot) do
    case violations(:strict, snapshot) do
      [] -> :ok
      vs -> raise SecurityPreflight.Error, vs
    end

    SecurityPreflight.check!(force: true)
    boot_check!(true)
  end

  def enforce!(:legacy_compat, snapshot) do
    for %{code: code, detail: detail} <- violations(:strict, snapshot) do
      Logger.warning("AshA2A legacy_compat profile: #{code}: #{detail}")
    end

    :telemetry.execute(
      [:ash_a2a, :security_profile, :legacy_compat],
      %{system_time: System.system_time()},
      %{profile: :legacy_compat}
    )

    SecurityPreflight.check!()
    boot_check!(false)
  end

  def enforce!(:dev_bypass, _snapshot) do
    # Compiled only when Mix.env() != :prod; reached only when the compiled
    # profile is :dev_bypass, so the function exists.
    apply(SecurityProfile, :announce_dev_bypass, [])
    SecurityPreflight.check!()
    boot_check!(false)
  end

  defp boot_check!(strict?) do
    case ReceiptStore.boot_check() do
      :ok ->
        :ok

      {:error, reason} ->
        violation = v(:receipt_store_boot_check_failed, inspect(reason))

        if strict? or Application.get_env(:ash_a2a, :production, false) == true do
          raise SecurityPreflight.Error, [violation]
        else
          Logger.warning("AshA2A boot_check: #{violation.detail}")
          :ok
        end
    end
  end

  defp v(code, detail), do: %{code: code, detail: detail}

  defp broker_module({m, _}) when is_atom(m), do: m
  defp broker_module(m) when is_atom(m), do: m
end
