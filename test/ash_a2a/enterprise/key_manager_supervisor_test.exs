# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.KeyManagerSupervisorTest do
  @moduledoc """
  Courts for `AshA2A.Security.KeyManager` as a startable supervised
  child (lane V4-22, closing the V4-13 `{:not_startable,
  AshA2A.Security.KeyManager}` typed gap):

    1. `child_spec/1` is a real supervisor child spec and starts a live
       holder under a plain test supervisor;
    2. with the local KMS harness configured, the supervised instance's
       binding drives a real envelope wrap/unwrap (AES-256-GCM payload,
       DEK wrapped under the KEK through `AshA2A.Security.KMS.Local`);
    3. unconfigured/stopped -> fail-closed refusals and clean
       termination, no crash;
    4. the enterprise supervisor's `:kms` gate now starts a running
       `AshA2A.Security.KeyManager` child instead of skipping with
       `{:not_startable, AshA2A.Security.KeyManager}` (same startability
       predicate `AshA2A.Enterprise.Supervisor` resolves with).

  Zero mocks: the KMS is the real local harness GenServer, the
  supervisors are real OTP supervisors, the envelopes round-trip real
  ciphertext.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Enterprise.Supervisor
  alias AshA2A.Security.KeyManager
  alias AshA2A.Security.KMS.Local
  alias Elixir.Supervisor, as: OTPSup

  @gates [
    :spiffe_socket,
    :authzen_pdp_url,
    :kms,
    :finops,
    :drain,
    :affidavit,
    :siem
  ]

  setup do
    saved =
      Map.new(@gates, fn key -> {key, Application.get_env(:ash_a2a, key)} end)
      |> Map.put(:spiffe_trust_domain, Application.get_env(:ash_a2a, :spiffe_trust_domain))
      |> Map.put(:cmek_kms_client, Application.get_env(:ash_a2a, :cmek_kms_client))
      |> Map.put(:cmek_kek_id, Application.get_env(:ash_a2a, :cmek_kek_id))

    Enum.each(@gates, &Application.delete_env(:ash_a2a, &1))
    Application.delete_env(:ash_a2a, :spiffe_trust_domain)
    Application.delete_env(:ash_a2a, :cmek_kms_client)
    Application.delete_env(:ash_a2a, :cmek_kek_id)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:ash_a2a, key)
        {key, value} -> Application.put_env(:ash_a2a, key, value)
      end)

      # NOTE: the local KMS harness is NOT stopped here on purpose. ExUnit
      # on_exit callbacks run concurrently with the next test module's
      # setup, and an async stop raced CMEKTest's `Local.ensure_started/0`
      # (killing the harness mid-file). Every test below that starts the
      # harness stops it synchronously in its own after-block instead;
      # when CMEKTest runs alongside, its own on_exit stops the harness.
    end)

    %{saved: saved}
  end

  # -- helpers --

  defp set_gates(kw) do
    Enum.each(kw, fn {key, value} -> Application.put_env(:ash_a2a, key, value) end)
  end

  defp unique(base) do
    :"#{base}_court_#{System.unique_integer([:positive])}"
  end

  # Same startability predicate `AshA2A.Enterprise.Supervisor.put_child/4`
  # resolves with — computed here rather than edited into the supervisor
  # court, which is not this lane's file.
  defp startable?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :child_spec, 1)
  end

  defp start_under_test_supervisor(spec) do
    {:ok, sup} = OTPSup.start_link([spec], strategy: :one_for_one)
    sup
  end

  defp stop_sup(sup) do
    # Unlink BEFORE exiting so the supervisor's `:shutdown` exit signal
    # can never kill this (non-trapping) test process and mask a real
    # failure (same technique as the supervisor court).
    ref = Process.monitor(sup)
    Process.unlink(sup)
    Process.exit(sup, :shutdown)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  @plaintext "kms-gate::" <> Base.encode16(:crypto.strong_rand_bytes(16))

  # ------------------------------------------------------------------
  # Court (a): child_spec/1 is a real, startable supervisor child spec
  # ------------------------------------------------------------------

  test "child_spec/1 starts a real KeyManager holder under a test supervisor" do
    assert startable?(KeyManager)

    name = unique(KeyManager)
    spec = KeyManager.child_spec(name: name)

    assert elem(spec.start, 0) == KeyManager
    assert spec.id == KeyManager

    sup = start_under_test_supervisor(spec)

    try do
      assert is_pid(Process.whereis(name))

      # No :kms gate, no :cmek_kms_client -> the holder resolves
      # fail-closed: it runs, holding a nil client and the default KEK.
      assert {:ok, %{kms_client: nil, kek_id: kek_id}} = KeyManager.kms_binding(name)
      assert kek_id == KeyManager.default_kek_id()
    after
      stop_sup(sup)
    end

    # Clean termination: the holder is gone with the supervisor.
    refute Process.whereis(name)
  end

  # ------------------------------------------------------------------
  # Court (b): supervised instance performs real envelope wrap/unwrap
  # through the local KMS harness via the :kms projection
  # ------------------------------------------------------------------

  test "supervised KeyManager drives a real envelope cycle through the :kms projection" do
    Local.ensure_started()
    set_gates(kms: [client: Local, kek_id: "ash-a2a/cmek-kek"])

    name = unique(KeyManager)
    sup = start_under_test_supervisor(KeyManager.child_spec(name: name))

    try do
      # The holder projected `kms: [client: Local]` onto
      # `:cmek_kms_client` (explicit host config was unset) and now owns
      # the binding.
      assert Application.get_env(:ash_a2a, :cmek_kms_client) == Local

      assert {:ok, %{kms_client: Local, kek_id: "ash-a2a/cmek-kek"}} =
               KeyManager.kms_binding(name)

      # Real envelope cycle: DEK wrap under the KEK through the
      # supervised binding, then unwrap on decrypt.
      assert {:ok, envelope} = KeyManager.encrypt(@plaintext)
      assert is_binary(envelope.wrapped_dek) and byte_size(envelope.wrapped_dek) >= 29
      assert {:ok, version} = Local.current_version(KeyManager.default_kek_id())
      assert envelope.kek_version_id == version

      assert {:ok, @plaintext} = KeyManager.decrypt(envelope)

      # The binding the holder resolved is itself sufficient to drive
      # the cycle (no hidden env dependence).
      binding_opts = [kms_client: Local, kek_id: "ash-a2a/cmek-kek"]
      assert {:ok, envelope2} = KeyManager.encrypt(@plaintext, binding_opts)

      assert {:ok, @plaintext} = KeyManager.decrypt(envelope2, binding_opts)

      # Rotation through the supervised binding: re-wrap, same payload.
      {:ok, rotated} = KeyManager.rotate(envelope, binding_opts)
      assert rotated.ciphertext == envelope.ciphertext
      assert rotated.kek_version_id == envelope.kek_version_id + 1
      assert {:ok, @plaintext} = KeyManager.decrypt(rotated, binding_opts)
    after
      stop_sup(sup)
      stop_local()
    end
  end

  # ------------------------------------------------------------------
  # Court (c): unconfigured stays fail-closed; stop is clean, no crash
  # ------------------------------------------------------------------

  test "unconfigured holder starts fail-closed and stops cleanly" do
    # no :kms gate, no :cmek_kms_client — nothing projected
    name = unique(KeyManager)
    sup = start_under_test_supervisor(KeyManager.child_spec(name: name))

    try do
      assert {:ok, %{kms_client: nil}} = KeyManager.kms_binding(name)
      refute Application.get_env(:ash_a2a, :cmek_kms_client)

      assert {:error, :refused_cmek_kms_unavailable, detail} = KeyManager.encrypt(@plaintext)
      assert detail =~ "fail-closed"
    after
      stop_sup(sup)
    end

    refute Process.whereis(name)
  end

  test "a :kms gate of false or nil never projects a client" do
    Local.ensure_started()

    for gate_value <- [false, nil] do
      set_gates(kms: gate_value)

      name = unique(KeyManager)
      sup = start_under_test_supervisor(KeyManager.child_spec(name: name))

      try do
        assert {:ok, %{kms_client: nil}} = KeyManager.kms_binding(name)
      after
        stop_sup(sup)
      end

      refute Application.get_env(:ash_a2a, :cmek_kms_client)
    end

    # explicit host config wins over the projection
    set_gates(kms: [client: Local, kek_id: "ash-a2a/cmek-kek"])
    Application.put_env(:ash_a2a, :cmek_kms_client, OtherKms)

    name = unique(KeyManager)
    sup = start_under_test_supervisor(KeyManager.child_spec(name: name))

    try do
      assert {:ok, %{kms_client: OtherKms}} = KeyManager.kms_binding(name)
      assert Application.get_env(:ash_a2a, :cmek_kms_client) == OtherKms
    after
      stop_sup(sup)
      stop_local()
    end
  end

  # ------------------------------------------------------------------
  # Court (d): the enterprise supervisor :kms gate starts a running
  # KeyManager child — the {:not_startable} gap is closed
  # ------------------------------------------------------------------

  test "enterprise supervisor :kms gate resolves and boots a running KeyManager child" do
    Local.ensure_started()
    set_gates(kms: [client: Local, kek_id: "ash-a2a/cmek-kek"])

    # resolution layer: KeyManager is startable, so :kms yields a child
    # spec and NOT a {:not_startable, KeyManager} skip
    resolution = Supervisor.resolve()

    assert KeyManager in Enum.map(resolution.children, fn spec -> elem(spec.start, 0) end)
    refute Enum.any?(resolution.skipped, fn {_key, module, _reason} -> module == KeyManager end)

    km_name = unique(KeyManager)

    {:ok, sup} =
      Supervisor.start_link(
        name: unique(AshA2A.Enterprise.Supervisor),
        overrides: [{KeyManager, name: km_name}]
      )

    try do
      children = OTPSup.which_children(sup)

      assert length(children) == length(Supervisor.resolve().children)

      for {_id, pid, _type, _modules} <- children do
        assert is_pid(pid) and Process.alive?(pid)
      end

      # the supervised instance is the projected, live holder
      km = Process.whereis(km_name)
      assert is_pid(km)

      assert {:ok, %{kms_client: Local, kek_id: "ash-a2a/cmek-kek"}} =
               KeyManager.kms_binding(km_name)

      assert km == find_child_pid(children)

      # real wrap/unwrap through the supervisor-started instance's binding
      assert {:ok, envelope} = KeyManager.encrypt(@plaintext)
      assert {:ok, @plaintext} = KeyManager.decrypt(envelope)
    after
      stop_sup(sup)
      stop_local()
    end
  end

  defp find_child_pid(children) when is_list(children) do
    children
    |> Enum.find_value(fn {_id, pid, _type, _modules} -> pid end)
  end

  # Synchronous harness teardown (never an on_exit callback — see setup).
  defp stop_local, do: Local.stop()

  # a KMS client that is configured but cannot serve the KEK: proves the
  # holder reports the binding it resolved, not what happens to work
  defmodule OtherKms do
    @behaviour AshA2A.Security.KMS.Client

    @impl true
    def wrap(_kek_id, _dek), do: {:error, :other_tenancy}

    @impl true
    def unwrap(_kek_id, _wrapped, _version), do: {:error, :other_tenancy}

    @impl true
    def current_version(_kek_id), do: {:error, :other_tenancy}

    @impl true
    def rotate_version(_kek_id), do: {:error, :other_tenancy}
  end
end
