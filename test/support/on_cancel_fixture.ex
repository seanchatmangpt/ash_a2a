defmodule AshA2A.Test.Fixture.OnCancelRecorder do
  @moduledoc """
  Real, observable recorder for `AshA2A.OnCancel` hook invocations
  (`test/ash_a2a_on_cancel_hook_test.exs`).

  An ordinary supervised `Agent` holding a real list of recorded
  invocations -- not a mock, not a spy (`AshA2A.Test.Fixture.
  KeyedActuationCounter`, `test/support/counting_actuator_fixture.ex`, is
  the same real-collaborator pattern for a different fixture). The hook
  module below performs the real effect (`record/1`); the test asserts on
  the real list `records/0` returns -- a state-based claim, not "was this
  called".
  """
  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(fn -> [] end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Performs the real effect: appends `entry` to the recorded invocation list."
  def record(entry, name \\ __MODULE__) do
    Agent.update(name, fn records -> records ++ [entry] end)
  end

  @doc "The real list of invocations recorded so far, oldest first."
  def records(name \\ __MODULE__), do: Agent.get(name, & &1)
end

defmodule AshA2A.Test.Fixture.OnCancelHook do
  @moduledoc """
  Real `AshA2A.OnCancel` implementation: on cancel, records the resolved
  `exec_context`/`task_id`/`context_id` into `AshA2A.Test.Fixture.
  OnCancelRecorder` -- genuine resource-author code running on a real
  cancel, not a stub return value.
  """
  @behaviour AshA2A.OnCancel

  alias AshA2A.Test.Fixture.OnCancelRecorder

  @impl AshA2A.OnCancel
  def on_cancel(exec_context, task_id, context_id) do
    OnCancelRecorder.record({exec_context, task_id, context_id})
    :ok
  end
end

defmodule AshA2A.Test.Fixture.OnCancelHookErroring do
  @moduledoc """
  Real `AshA2A.OnCancel` implementation that always raises, used to prove
  `AshA2A.Agent.__cancel__/2` catches a misbehaving hook rather than
  letting it crash the agent's cancel call (`AshA2A.OnCancel`'s
  @moduledoc, "Failure handling").
  """
  @behaviour AshA2A.OnCancel

  @impl AshA2A.OnCancel
  def on_cancel(_exec_context, _task_id, _context_id) do
    raise "deliberate on_cancel hook failure (test fixture)"
  end
end

defmodule AshA2A.Test.Fixture.OnCancelStreamItem do
  @moduledoc """
  Real fixture resource for `test/ash_a2a_on_cancel_hook_test.exs`: same
  streaming-`:read`-produces-a-genuinely-`:working`-task shape as
  `AshA2A.Test.Fixture.StreamItem` (`test/support/cancel_fixture.ex` --
  see that module's @moduledoc for why streaming is the one real
  in-flight window a concurrent `cancel/2` can interrupt), but with a real
  `on_cancel:` hook declared on the skill.
  """
  use Ash.Resource,
    domain: AshA2A.Test.Fixture.OnCancelStreamItemDomain,
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
    skill(:list_items, :read, on_cancel: AshA2A.Test.Fixture.OnCancelHook)
  end
end

defmodule AshA2A.Test.Fixture.OnCancelStreamItemDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.OnCancelStreamItem`."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.OnCancelStreamItem)
  end
end

defmodule AshA2A.Test.Fixture.OnCancelStreamItemAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer over `AshA2A.Test.Fixture.OnCancelStreamItem`,
  mirroring `AshA2A.Test.Fixture.StreamItemAgent`.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.OnCancelStreamItem,
    name: "on_cancel_stream_item_agent"
end

defmodule AshA2A.Test.Fixture.OnCancelErrorStreamItem do
  @moduledoc """
  Same shape as `AshA2A.Test.Fixture.OnCancelStreamItem`, but its skill
  declares the always-raising `AshA2A.Test.Fixture.OnCancelHookErroring`
  hook instead, to prove a misbehaving hook cannot crash cancellation.
  """
  use Ash.Resource,
    domain: AshA2A.Test.Fixture.OnCancelErrorStreamItemDomain,
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
    skill(:list_items, :read, on_cancel: AshA2A.Test.Fixture.OnCancelHookErroring)
  end
end

defmodule AshA2A.Test.Fixture.OnCancelErrorStreamItemDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.OnCancelErrorStreamItem`."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.OnCancelErrorStreamItem)
  end
end

defmodule AshA2A.Test.Fixture.OnCancelErrorStreamItemAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer over `AshA2A.Test.Fixture.OnCancelErrorStreamItem`.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.OnCancelErrorStreamItem,
    name: "on_cancel_error_stream_item_agent"
end
