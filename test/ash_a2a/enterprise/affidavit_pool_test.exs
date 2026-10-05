# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.AffidavitPoolCourtTest do
  @moduledoc """
  Affidavit pool court (PRD v26.10.4 §2 `:affidavit` gate child): Chicago
  courts over the REAL `AshA2A.Evidence.AffidavitPool` — a supervised pool of
  REAL `AshAffidavit.Host` WASM engine instances (Wasmtime via `wasmex`,
  engine bytes at `deps/ash_affidavit/priv/affidavit/affidavit.wasm`). Zero
  mocks.

  Witnessed:

    * concurrent sign/verify (assemble/verify ops) through the pool facade
      while the real registry routes across multiple live pool members;
    * each pool member individually answers through the REAL engine;
    * engine-bytes load failure is a typed refusal (`:wasm_not_vendored`
      via the `:refused` outcome), the pool STARTS FINE (no crash loop:
      the member stays supervised under `:unavailable` and retries), and
      the facade carries the exact `AshA2A.Evidence.Affidavit`-shaped
      `{:error, {:refused_affidavit, refusal}}`;
    * engine identity via `info/0` (64-hex wasm sha256 pin) and typed
      unavailability (`available?/0` false, `info/0` typed refusal) when the
      pool is down.
  """

  use ExUnit.Case, async: false

  alias AshAffidavit.Refusal
  alias AshA2A.Evidence.AffidavitPool

  @moduletag :affidavit_pool

  # The lifecycle trace (real engine input shape, as in affidavit_test.exs).
  defp lifecycle_events do
    [
      %{"event_type" => "start", "objects" => ["task:1"], "payload" => "init"},
      %{"event_type" => "finish", "objects" => ["task:1"], "payload" => "done"}
    ]
  end

  # ---------------------------------------------------------------------------
  # Court 1 — concurrent sign/verify across real pool members
  # ---------------------------------------------------------------------------

  test "concurrent assemble/verify across the real WASM pool: every op succeeds and every member serves" do
    start_supervised!({AffidavitPool, size: 2})
    assert AffidavitPool.available?() == true

    # Both real members are live and individually answer the real engine.
    members = AffidavitPool.members()
    assert length(members) == 2

    for pid <- members do
      assert Process.alive?(pid)
      assert {:ok, caps} = AshAffidavit.Host.request(pid, %{"op" => "capabilities"})
      assert caps["module"] == "affidavit-wasm"
    end

    # Concurrent sign/verify ops through the pool facade (shortest-mailbox
    # routing fans the burst across both members): even tasks seal and
    # re-verify the real receipt, odd tasks flip one commitment byte in the
    # receipt and witness the engine's typed `accepted: false` verdict.
    results =
      1..8
      |> Enum.map(fn i ->
        Task.async(fn ->
          events = lifecycle_events()
          assert {:ok, assembled} = AffidavitPool.assemble_receipt(events)
          assert assembled["chain_hash"]

          receipt = assembled["receipt"]

          if rem(i, 2) == 0 do
            assert {:ok, true} = AffidavitPool.verify_receipt(receipt)
          else
            tampered =
              update_in(
                receipt,
                ["events", Access.at(0), "payload_commitment"],
                fn
                  <<"a", rest::binary>> -> "b" <> rest
                  <<_other, rest::binary>> -> "a" <> rest
                end
              )

            assert tampered != receipt
            assert {:ok, false} = AffidavitPool.verify_receipt(tampered)
          end

          :ok
        end)
      end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert results == List.duplicate(:ok, 8)
    assert is_pid(Process.whereis(AffidavitPool))
  end

  # ---------------------------------------------------------------------------
  # Court 2 — engine-bytes load failure: typed refusal, never a crash loop
  # ---------------------------------------------------------------------------

  test "engine-bytes load failure starts fine and answers with a typed refusal, never a crash loop" do
    name = :"affidavit_pool_unavailable_#{System.unique_integer([:positive, :monotonic])}"

    # The start SUCCEEDS with engine bytes that cannot load: the pool never
    # crash-loops the supervisor, the member heals in the background.
    start_supervised!({AffidavitPool, name: name, size: 1, wasm_path: "/nonexistent/affidavit-unavailable-in-test.wasm"})

    assert {:refused, %Refusal{code: :wasm_not_vendored} = refusal} =
             AffidavitPool.call(name, %{"op" => "capabilities"})

    assert refusal.message =~ "affidavit-unavailable-in-test.wasm"

    # The facade carries the exact `AshA2A.Evidence.Affidavit`-shaped error.
    assert {:error, {:refused_affidavit, %Refusal{code: :wasm_not_vendored}}} =
             AffidavitPool.assemble_receipt(name, lifecycle_events())

    assert {:error, {:refused_affidavit, %Refusal{code: :wasm_not_vendored}}} =
             AffidavitPool.verify_receipt(name, %{"format_version" => "core/v1"})

    # The member is still supervised, listed as unavailable (healing), and the
    # pool survives repeated calls — no crash loop.
    assert length(AffidavitPool.unavailable_members(name)) == 1
    assert AffidavitPool.available?(name) == false

    for _ <- 1..3 do
      assert {:refused, %Refusal{code: :wasm_not_vendored}} =
               AffidavitPool.call(name, %{"op" => "capabilities"})
    end

    assert is_pid(Process.whereis(name))
  end

  # ---------------------------------------------------------------------------
  # Court 3 — engine identity and typed unavailability
  # ---------------------------------------------------------------------------

  test "info/0 reports the real engine identity; a down pool is typed, never a raise" do
    start_supervised!({AffidavitPool, size: 1})

    assert {:ok, %{wasm_sha256: sha}} = AffidavitPool.info()
    assert is_binary(sha) and byte_size(sha) == 64

    # A pool that was never started is a typed refusal, never a raise.
    down_name = :"affidavit_pool_down_#{System.unique_integer([:positive, :monotonic])}"

    assert {:error, %Refusal{code: :host_not_started}} = AffidavitPool.info(down_name)
    assert {:error, :pool_not_started} = AffidavitPool.call(down_name, %{"op" => "capabilities"})
    assert AffidavitPool.available?(down_name) == false
  end
end
