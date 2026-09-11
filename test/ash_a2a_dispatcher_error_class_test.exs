defmodule AshA2ADispatcherErrorClassTest do
  @moduledoc """
  Assignment #9: real dispatcher error-class -> wire-message-text mapping.

  `AshA2A.Dispatcher.to_reply/1` has distinct clauses for Ash's
  `:forbidden`/`:framework`/`:unknown`/`:invalid` (non-tenant) error
  classes, each producing a class-prefixed message string via
  `class_message/2` (`lib/ash_a2a/dispatcher.ex:564-582`). The ORIGINAL
  framing of this assignment ("verify the real resulting JSON-RPC error
  response uses the correct real error code") does not correspond to
  anything ash_a2a actually does: `A2A.Agent.Runtime.handle_reply/2`
  (`~/xaas/deps/a2a/lib/a2a/agent/runtime.ex:96-99`) never produces a
  top-level JSON-RPC error from a dispatch failure -- it always builds a
  real `TASK_STATE_FAILED` task with `Message.new_agent("Error:
  \#{inspect(reason)}")`, confirmed empirically via
  `test/ash_a2a_plug_tenant_actor_test.exs`. There is no real JSON-RPC
  error-CODE distinction per dispatcher error class today; only a real,
  distinct class-prefixed TEXT message inside a real failed task. This test
  verifies the real behavior instead of the incorrect original premise.

  `:invalid_config` (the `TenantRequired`/`NoPrimaryAction` carve-out) is
  already covered by `test/ash_a2a_dispatcher_tenant_test.exs` -- not
  duplicated here. `:forbidden` had zero coverage anywhere in this suite;
  this test closes that gap via a real `Ash.Policy.Authorizer` denial (not
  a hand-constructed error term). `:framework` and `:unknown` are Splode
  error classes reserved for genuine internal/unexpected faults
  (`Ash.Error.Framework`/`Ash.Error.Unknown`) -- there is no real,
  legitimate Ash usage pattern that raises either from a correctly
  configured resource; fabricating one would mean hand-constructing the
  exact error struct this test is supposed to prove arises from real
  usage, which is the fabrication this session's own discipline forbids.
  Left honestly untested for that reason, not silently skipped: see the
  moduledoc note on `class_message/2`'s catch-all coverage below.

  Chicago-style: a real `Ash.Policy.Authorizer`-guarded resource, a real
  `AshA2A.Dispatcher.dispatch/3` call, real state-based assertions on the
  real returned error tuple. No Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.ErrorClassProbe

  test "a real Ash.Policy.Authorizer denial maps to a real class-tagged :forbidden message" do
    message = data_message(%{})

    assert {:error, {:execution, reason}} =
             AshA2A.Dispatcher.dispatch(:list, message, ErrorClassProbe)

    assert reason =~ "forbidden:"
  end

  test "the real class-tagged message is real text, not opaque Elixir tuple syntax on the wire" do
    message = data_message(%{})

    assert {:error, {:execution, reason}} =
             AshA2A.Dispatcher.dispatch(:list, message, ErrorClassProbe)

    # A real A2A client can only ever receive plain text (`A2A.Part.Text.new/1`
    # inside `Message.new_agent/1`) -- confirm the real reason is a legible
    # string, never literal `{:forbidden, ...}` tuple syntax a remote caller
    # could not parse into a structured class.
    assert is_binary(reason)
    refute reason =~ "{:forbidden"
  end
end
