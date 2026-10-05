# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityProfile.Boot do
  @moduledoc """
  Boot enforcement for the compiled `AshA2A.SecurityProfile`
  (RFC-SA2A-007). `run!/0` is called from `AshA2A.Application.start/2`
  before any child starts.

  ## `:strict` refuses (each a named violation)

    * `:outbox_key_missing` - neither `:receipt_outbox_key` nor
      `:receipt_binding_key` is a non-empty binary
    * `:outbox_key_weak` - the outbox/journal HMAC key is shorter than 32 bytes
    * `:claim_store_missing` - no `:claim_store` configured (snapshot carries
      `:claim_store`; evaluated whenever that key is present, always at boot)
    * `:claim_store_not_durable` - the claim store is in-memory/ETS or does not
      export `durable?/0 == true`
    * `:claim_store_dir_not_durable` - the durable-file claim store's
      `:claim_store_dir` is unset or under a volatile tmp path
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
  # `Application.get_env/3` is success-typed `term()`, so every env-derived
  # key here is honestly `term()`; typing them narrower (e.g. `module()`)
  # made the `snapshot()` contract unsatisfiable, which collapsed `run!/0`
  # to `none()` and cascaded `no_return` into `AshA2A.Application.start/2`.
  @type snapshot :: %{
          outbox_key: binary() | nil,
          outbox_dir: term(),
          claim_store: term(),
          claim_store_dir: term(),
          receipt_store: term(),
          capability_release_mode: atom(),
          authority_broker: atom(),
          kill_switch_class: term(),
          authority_policy: term()
        }

  @doc false
  def __sa2a_refusal_codes__ do
    %{
      outbox_key_missing: :refused_receipt,
      outbox_key_weak: :refused_receipt,
      claim_store_missing: :refused_receipt,
      claim_store_not_durable: :refused_receipt,
      claim_store_dir_not_durable: :refused_receipt,
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
      claim_store: Application.get_env(:ash_a2a, :claim_store),
      claim_store_dir: Application.get_env(:ash_a2a, :claim_store_dir),
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
      if(is_binary(s.outbox_key) and byte_size(s.outbox_key) in 1..31,
        do: v(:outbox_key_weak, "receipt outbox/journal HMAC key is shorter than 32 bytes")
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
    |> Kernel.++(claim_store_violations(s))
  end

  def violations(_profile, _snapshot), do: []

  # Evaluated only when the snapshot carries the claim-store facts (the real
  # `snapshot/0` always does; older partial snapshots do not).
  defp claim_store_violations(s) do
    case Map.fetch(s, :claim_store) do
      :error ->
        []

      {:ok, nil} ->
        [v(:claim_store_missing, "no :claim_store configured; nothing durable backs claims")]

      {:ok, mod} ->
        dir_ok? =
          mod != AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile or
            ReceiptStore.durable_path?(Map.get(s, :claim_store_dir))

        [
          if(not durable_claim_store?(mod),
            do:
              v(
                :claim_store_not_durable,
                ":claim_store #{inspect(mod)} is in-memory or does not export durable?/0 == true"
              )
          ),
          if(not dir_ok?,
            do:
              v(
                :claim_store_dir_not_durable,
                ":claim_store_dir #{inspect(Map.get(s, :claim_store_dir))} is unset or under a tmp directory"
              )
          )
        ]
        |> Enum.reject(&is_nil/1)
    end
  end

  defp durable_claim_store?(mod) when is_atom(mod) do
    Code.ensure_loaded(mod)

    not (Module.split(mod) |> List.last() =~ ~r/Memory|ETS/) and
      function_exported?(mod, :durable?, 0) and mod.durable?() == true
  end

  defp durable_claim_store?(_), do: false

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
