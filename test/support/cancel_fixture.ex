# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.Fixture.StreamItem do
  @moduledoc """
  Real fixture resource for `test/ash_a2a_cancel_inflight_test.exs` (item
  #5: real cancellation of an in-flight dispatch).

  A genuine `Ash.Resource` with a real `:read` action exposed as a streaming
  A2A skill (`AshA2A.Dispatcher.run_read_stream/4`, driven by the real
  `Ash.stream!/2` API -- same mechanism `test/ash_a2a_test.exs` and
  `test/ash_a2a_dispatcher_skills_test.exs` already exercise for a fully
  *consumed* stream). This fixture exists to produce a task that is
  genuinely still `:working` -- an actual in-flight dispatch, not yet
  finalized -- so a real concurrent `cancel/2` call has something real to
  interrupt.

  Why streaming, and not a plain synchronous action, is the only real
  in-flight window `AshA2A.Protocol.Agent` offers: `AshA2A.Protocol.Agent`'s GenServer
  (in the in-repo ported codec, `lib/ash_a2a/protocol/agent.ex`) processes `{:message, ...}`
  and `{:cancel, ...}` calls through the *same* serialized mailbox --
  `handle_message/2` runs synchronously inside `handle_call({:message, ...})`
  before the GenServer ever replies, so a `:cancel` call sent while an
  ordinary synchronous action is executing cannot be delivered until that
  call already finished (there is no window to interleave it; the mailbox
  is blocked on the very call being "canceled"). A `{:stream, enumerable}`
  reply is different: `AshA2A.Protocol.Agent.Runtime.run_task/4` transitions the task to
  `:working` and returns the *unconsumed* stream to the caller as part of
  the `{:ok, task}` reply -- the GenServer call has already completed and
  the mailbox is free -- and the task stays `:working` (non-terminal) until
  a caller actually drains the stream (triggering the `{:stream_done, ...}`
  cast that finalizes it to `:completed` in the in-repo ported codec's
  `lib/ash_a2a/protocol/agent.ex`). A test that never drains the
  stream has a real, indefinitely-in-flight `:working` task to cancel.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.StreamItemDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, create: [:label]])
  end

  a2a do
    skill(:list_items, :read)
  end
end

defmodule AshA2A.Test.Fixture.StreamItemDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.StreamItem` above, mirroring
  the shape of the other single-resource fixture domains in
  `test/support/fixture.ex`.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.StreamItem)
  end
end

defmodule AshA2A.Test.Fixture.StreamItemAgent do
  @moduledoc """
  Real `AshA2A.Protocol.Agent` GenServer built with `use AshA2A.Agent` over the
  `StreamItem` fixture above, for
  `test/ash_a2a_cancel_inflight_test.exs` to start under a real
  `AshA2A.Protocol.AgentSupervisor` and dispatch a real streaming skill through, then
  issue a real concurrent `cancel/2` against the same agent process while
  the resulting task is still genuinely `:working`.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.StreamItem,
    name: "stream_item_agent"
end
