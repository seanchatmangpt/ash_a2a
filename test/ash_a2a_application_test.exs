defmodule AshA2AApplicationTest do
  @moduledoc """
  Proves `AshA2A.Application.start/2` genuinely attaches
  `AshA2A.Telemetry.OcelForwarder` at real application boot -- not just that
  the source code calls `attach!/0`, but that the real, currently-running
  `:ash_a2a` OTP application (started for real by `mix test` before any test
  runs, per Mix's own application-under-test convention) has the real
  telemetry handlers registered. No Mock/mox/patch/monkeypatch -- this reads
  real `:telemetry` registry state via `:telemetry.list_handlers/1`.
  """

  use ExUnit.Case, async: true

  test "OcelForwarder's real telemetry handlers are attached by real application startup" do
    dispatch_handlers = :telemetry.list_handlers([:ash_a2a, :dispatch, :stop])
    receipt_handlers = :telemetry.list_handlers([:ash_a2a, :receipt, :committed])

    assert Enum.any?(dispatch_handlers, fn h ->
             h.id == {AshA2A.Telemetry.OcelForwarder, :dispatch_stop}
           end)

    assert Enum.any?(receipt_handlers, fn h ->
             h.id == {AshA2A.Telemetry.OcelForwarder, :receipt_committed}
           end)
  end
end
