# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TwoPortGateTest do
  @moduledoc """
  The algebraic two-port lease gate (loops-of-loops spec §1 Loop 1, lane L1):
  real Ed25519 keys, real signed leases, the real gate, the real CommandBus
  with a real ReceiptStore.Memory — Chicago discipline, no doubles.

  Covers: conjunct masks (single-bit tampers 0x1/0x2/0x4/0x8, all-four 0xF),
  the hybrid clock law (same-VM monotonic window; cross-VM wall fallback,
  both directions), fail-closed missing-key, the RDFC-1.0 root recomputation
  path, the branchless witness, e2e opt-in wiring in `CommandBus.run/4`
  (admit / refuse-before-claim / silent skip), and the ≤10ms budget
  measurement (assert a generous CI bound; the measured number is printed).
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Authority.Lease
  alias AshA2A.Authority.TwoPortGate
  alias AshA2A.{Command, CommandBus, ReceiptStore, SemanticSubject}
  alias AshA2A.Semantic.CanonicalGraph
  alias AshA2A.Test.Fixture.Echo

  @ga "sha256:" <> String.duplicate("a", 64)
  @gb "sha256:" <> String.duplicate("b", 64)
  @gc "sha256:" <> String.duplicate("c", 64)
  @gd "sha256:" <> String.duplicate("d", 64)
  @ge "sha256:" <> String.duplicate("e", 64)

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  # --- real collaborators -----------------------------------------------------

  defp subject do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: @ga,
        projection_digest: @gb,
        manufacturer_digest: @gc,
        ephemeral?: false
      )

    subject
  end

  defp command do
    Command.new("AshA2A.Test.Fixture.Echo.read",
      command_id: "two-port-1",
      agent_id: "test",
      principal_id: "p-1",
      task_id: "task-1",
      semantic_subject: subject(),
      input: %{},
      metadata: %{candidate_digest: "sha256:two-port-candidate"}
    )
  end

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  defp signed_lease(cmd, opts \\ []) do
    {pub, priv} = keypair()
    {:ok, signed} = cmd |> Lease.for_command(opts) |> Lease.sign(priv)
    {pub, signed}
  end

  defp flip_byte(%Lease{signature: <<b, rest::binary>>} = lease),
    do: %{lease | signature: <<Bitwise.bxor(b, 1), rest::binary>>}

  defp expired_wall(cmd) do
    Lease.for_command(cmd, issued_monotonic_ms: nil)
    |> struct(not_before: ~U[2020-01-01 00:00:00Z], expires_at: ~U[2020-01-02 00:00:00Z])
  end

  defp future_wall(cmd) do
    Lease.for_command(cmd, issued_monotonic_ms: nil)
    |> struct(not_before: DateTime.add(DateTime.utc_now(), 3600, :second))
  end

  # --- conjunct masks ---------------------------------------------------------

  describe "TwoPortGate.evaluate/3 conjunct masks" do
    test "valid same-VM lease admits with the null mask" do
      {pub, signed} = signed_lease(command())
      assert :admitted = TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "scope tamper refuses with exactly 0x1" do
      {pub, priv} = keypair()

      {:ok, signed} =
        command() |> Lease.for_command() |> struct(scope_digest: @gd) |> Lease.sign(priv)

      assert {:error, {:refused_lease, 0x1, %{codes: [:lease_scope_mismatch]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "root tamper refuses with exactly 0x2" do
      {pub, priv} = keypair()

      {:ok, signed} =
        command() |> Lease.for_command() |> struct(root_digest: @gd) |> Lease.sign(priv)

      assert {:error, {:refused_lease, 0x2, %{codes: [:lease_root_mismatch]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "cross-VM expired lease refuses with exactly 0x4" do
      {pub, priv} = keypair()
      {:ok, signed} = Lease.sign(expired_wall(command()), priv)

      assert {:error, {:refused_lease, 0x4, %{codes: [:lease_expired]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "cross-VM future not_before refuses with 0x4 (wall path only)" do
      {pub, priv} = keypair()
      {:ok, signed} = Lease.sign(future_wall(command()), priv)

      assert {:error, {:refused_lease, 0x4, %{codes: [:lease_expired]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "same-VM future not_before does NOT bite (window opens at issuance)" do
      # Documented consequence of the hybrid law: on the same-VM path the
      # monotonic window is [issued_monotonic, issued_monotonic + duration];
      # not_before bounds only the cross-VM wall path.
      {pub, priv} = keypair()

      nb = DateTime.add(DateTime.utc_now(), 3600, :second)

      future =
        Lease.for_command(command())
        |> struct(not_before: nb, expires_at: DateTime.add(nb, 60, :second))

      {:ok, signed} = Lease.sign(future, priv)

      assert :admitted = TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "zero-duration window refuses with 0x4" do
      {pub, priv} = keypair()

      zero =
        Lease.new(
          lease_id: "lease-zero",
          scope_digest: Lease.scope_digest_for(command()),
          root_digest: @ga,
          not_before: ~U[2026-01-02 00:00:00Z],
          expires_at: ~U[2026-01-01 00:00:00Z],
          issued_monotonic_ms: System.monotonic_time(:millisecond)
        )

      {:ok, signed} = Lease.sign(zero, priv)

      assert {:error, {:refused_lease, 0x4, %{codes: [:lease_expired]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end

    test "flipped signature byte refuses with exactly 0x8" do
      {pub, signed} = signed_lease(command())
      forged = flip_byte(signed)

      assert {:error, {:refused_lease, 0x8, %{codes: [:lease_signature_invalid]}}} =
               TwoPortGate.evaluate(command(), forged, lease_public_key: pub)
    end

    test "missing public key fails closed with 0x8" do
      {_pub, signed} = signed_lease(command())

      assert {:error, {:refused_lease, 0x8, %{codes: [:lease_signature_invalid]}}} =
               TwoPortGate.evaluate(command(), signed, lease_public_key: nil)
    end

    test "all four broken refuses with 0xF and all four codes" do
      {pub, priv} = keypair()

      broken =
        Lease.for_command(command())
        |> struct(
          scope_digest: @gd,
          root_digest: @ge,
          issued_monotonic_ms: nil,
          not_before: ~U[2020-01-01 00:00:00Z],
          expires_at: ~U[2020-01-02 00:00:00Z]
        )
        |> Lease.sign(priv)
        |> elem(1)
        |> flip_byte()

      assert {:error,
              {:refused_lease, 0xF,
               %{codes: code_list}}} =
               TwoPortGate.evaluate(command(), broken, lease_public_key: pub)

      assert code_list == [
               :lease_scope_mismatch,
               :lease_root_mismatch,
               :lease_expired,
               :lease_signature_invalid
             ]
    end
  end

  # --- decode / refusal code map ----------------------------------------------

  describe "mask decode and refusal-code map" do
    test "decode(0) is empty; each bit decodes to its code" do
      assert [] = TwoPortGate.decode(0x0)
      assert [%{code: :lease_scope_mismatch, bit: 1}] = TwoPortGate.decode(0x1)
      assert [%{code: :lease_root_mismatch, bit: 2}] = TwoPortGate.decode(0x2)
      assert [%{code: :lease_expired, bit: 4}] = TwoPortGate.decode(0x4)
      assert [%{code: :lease_signature_invalid, bit: 8}] = TwoPortGate.decode(0x8)

      assert [_, _, _, _] = TwoPortGate.decode(0xF)
    end

    test "gate refusal codes are refused_authority class" do
      codes = TwoPortGate.__sa2a_refusal_codes__()

      assert codes == %{
               lease_scope_mismatch: :refused_authority,
               lease_root_mismatch: :refused_authority,
               lease_expired: :refused_authority,
               lease_signature_invalid: :refused_authority
             }
    end
  end

  # --- hybrid clock law -------------------------------------------------------

  describe "hybrid clock law" do
    test "cross-VM lease (nil monotonic) admits inside the wall window" do
      {pub, priv} = keypair()
      {:ok, signed} = Lease.sign(Lease.for_command(command(), issued_monotonic_ms: nil), priv)

      assert :admitted = TwoPortGate.evaluate(command(), signed, lease_public_key: pub)
    end
  end

  # --- RDFC-1.0 root path -----------------------------------------------------

  describe "RDF state root recomputation" do
    @ttl "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\n"

    test "matching RDFC-1.0 digest admits" do
      {:ok, root} = CanonicalGraph.canonical_digest(@ttl)
      {pub, priv} = keypair()
      lease = Lease.for_command(command(), root_digest: root)
      {:ok, signed} = Lease.sign(lease, priv)

      assert :admitted =
               TwoPortGate.evaluate(command(), signed,
                 lease_public_key: pub,
                 rdf_state: @ttl
               )
    end

    test "mismatching RDF root refuses 0x2" do
      {pub, priv} = keypair()
      lease = Lease.for_command(command(), root_digest: @ga)
      {:ok, signed} = Lease.sign(lease, priv)

      assert {:error, {:refused_lease, 0x2, %{codes: [:lease_root_mismatch]}}} =
               TwoPortGate.evaluate(command(), signed,
                 rdf_state: @ttl,
                 lease_public_key: pub
               )
    end

    test "unparseable RDF state fails closed with 0x2" do
      {pub, priv} = keypair()
      lease = Lease.for_command(command(), root_digest: @ga)
      {:ok, signed} = Lease.sign(lease, priv)

      assert {:error, {:refused_lease, 0x2, %{codes: [:lease_root_mismatch]}}} =
               TwoPortGate.evaluate(command(), signed,
                 rdf_state: <<0xFF>>,
                 lease_public_key: pub
               )
    end
  end

  # --- Lease unit law ---------------------------------------------------------

  describe "Lease sign/verify" do
    test "roundtrip verifies; foreign key refuses" do
      {pub, priv} = keypair()
      {:ok, signed} = Lease.for_command(command()) |> Lease.sign(priv)

      assert :ok = Lease.verify(signed, signed.signature, pub)
      assert {:error, :bad_signature} = Lease.verify(signed, signed.signature, elem(keypair(), 0))
    end

    test "payload tamper invalidates the signature" do
      {pub, priv} = keypair()
      {:ok, signed} = Lease.for_command(command()) |> Lease.sign(priv)

      assert {:error, :bad_signature} =
               Lease.verify(%{signed | payload_map: %{"x" => 1}}, signed.signature, pub)
    end

    test "missing signature or key fails closed" do
      lease = Lease.for_command(command())

      assert {:error, :bad_signature} = Lease.verify(lease, nil, elem(keypair(), 0))
      assert {:error, :bad_key} = Lease.verify(lease, <<0::256>>, nil)
    end
  end

  # --- branchless witness -----------------------------------------------------

  describe "branchless witness" do
    test "hook sees exactly four conjunct evaluations on both tails" do
      {pub, priv} = keypair()
      cmd = command()

      hook = fn name, failed? -> send(self(), {:conjunct, name, failed?}) end

      {:ok, valid} = Lease.for_command(cmd) |> Lease.sign(priv)
      assert :admitted = TwoPortGate.evaluate(cmd, valid, lease_public_key: pub, conjunct_hook: hook)
      admitted_calls = drain([])

      broken = Lease.for_command(cmd) |> struct(scope_digest: @gd, root_digest: @ge)
      {:ok, broken_signed} = Lease.sign(broken, priv)

      assert {:error, {:refused_lease, _, _}} =
               TwoPortGate.evaluate(cmd, broken_signed, lease_public_key: pub, conjunct_hook: hook)

      refused_calls = drain([])

      assert [:scope, :root, :clock, :signature] = Enum.map(admitted_calls, &elem(&1, 0))
      assert [false, false, false, false] = Enum.map(admitted_calls, &elem(&1, 1))
      assert [:scope, :root, :clock, :signature] = Enum.map(refused_calls, &elem(&1, 0))
      assert [true, true, false, false] = Enum.map(refused_calls, &elem(&1, 1))
    end
  end

  defp drain(acc) do
    receive do
      {:conjunct, name, failed?} -> drain([{name, failed?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # --- e2e through the real CommandBus ----------------------------------------

  describe "e2e through CommandBus.run/4 (opt-in lease gate)" do
    test "valid lease admitted before claim; receipt minted and replayed", %{
      store_opts: store_opts
    } do
      cmd = command()
      {pub, signed} = signed_lease(cmd)

      assert {:ok, first} =
               CommandBus.run(cmd, data_message(%{}), Echo,
                 store_opts: store_opts,
                 lease: signed,
                 lease_public_key: pub
               )

      assert first.status == :completed

      assert {:ok, replay} =
               CommandBus.run(cmd, data_message(%{}), Echo,
                 store_opts: store_opts,
                 lease: signed,
                 lease_public_key: pub
               )

      assert replay.replayed?
      assert replay.receipt_id == first.receipt_id
    end

    test "tampered lease refused before claim; no receipt minted", %{store_opts: store_opts} do
      cmd = command()
      {pub, priv} = keypair()

      {:ok, tampered} =
        cmd |> Lease.for_command() |> struct(scope_digest: @gd) |> Lease.sign(priv)

      assert {:error, %{code: :refused_lease, mask: 0x1}} =
               CommandBus.run(cmd, data_message(%{}), Echo,
                 store_opts: store_opts,
                 lease: tampered,
                 lease_public_key: pub
               )

      assert :error = ReceiptStore.Memory.fetch(cmd.command_id, store_opts)
    end

    test "opt-in skip: no lease, run completes, lease_gate telemetry never fires", %{
      store_opts: store_opts
    } do
      handler_id = "two-port-skip-#{System.unique_integer()}"

      :ok =
        :telemetry.attach(handler_id, [:ash_a2a, :command_bus, :lease_gate], fn _, _, _, _ ->
          send(self(), :lease_gate_fired)
        end, %{})

      assert {:ok, receipt} =
               CommandBus.run(command(), data_message(%{}), Echo, store_opts: store_opts)

      assert receipt.status == :completed
      refute_received :lease_gate_fired
      :telemetry.detach(handler_id)
    end
  end

  # --- budget ------------------------------------------------------------------

  describe "budget (loops-of-loops §1 Loop 1 gate budget)" do
    test "admission path with a real signed lease measures inside the CI bound" do
      cmd = command()
      {pub, signed} = signed_lease(cmd)

      for _ <- 1..10, do: TwoPortGate.evaluate(cmd, signed, lease_public_key: pub)

      samples =
        for _ <- 1..25 do
          {us, :admitted} =
            :timer.tc(fn -> TwoPortGate.evaluate(cmd, signed, lease_public_key: pub) end)

          us
        end

      sorted = Enum.sort(samples)
      median = Enum.at(sorted, div(length(sorted), 2))
      max_us = Enum.max(sorted)

      IO.puts("""
      [two-port gate budget] admission path, real Ed25519 verify, 25 samples:
        median #{median}us
        max    #{max_us}us
      """)

      assert median < 50_000, "gate admission median #{median}us exceeded the 50ms CI bound"
    end
  end
end
