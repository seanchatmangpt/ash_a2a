defmodule AshA2A.Test.Fixture.StreamingWidget do
  @moduledoc """
  Real fixture resource for `test/ash_a2a_sse_stream_test.exs` (assignment
  #8: real `message/stream` parsed via `A2A.Client.SSE.feed/2`).

  A genuine `Ash.Resource` (ETS-backed, `extensions: [AshA2A]`) with exactly
  one real `a2a do skill(:widgets, :read) end` declaration -- same shape as
  `AshA2A.Test.Fixture.Echo` (`test/support/fixture.ex`), which the existing
  dispatcher-level streaming tests already exercise, but distinct here
  because `Echo`'s ETS table is always empty (no `:create` action), so its
  streamed `Enum.to_list/1` is always `[]` -- useless for asserting that
  *real streamed content* survives a real SSE encode/decode round trip.
  `StreamingWidget` is seeded with real rows via `Ash.Seed.seed!/2` (a real,
  non-mocking Ash test-data API -- bypasses action validation the same way
  a direct ETS fixture load would, without hand-rolling ETS access) so the
  real `Ash.stream!/2` call inside `AshA2A.Dispatcher.run_read_stream/4` has
  real, non-empty content to stream.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.StreamingWidgetDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:widgets, :read)
  end
end

defmodule AshA2A.Test.Fixture.StreamingWidgetDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.StreamingWidget`, paired the
  same way `AshA2A.Test.Fixture.Domain` pairs with `Echo`.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.StreamingWidget)
  end
end

defmodule AshA2A.Test.Fixture.StreamingWidgetAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer over `StreamingWidget`, started under a real
  `A2A.AgentSupervisor` (via `AshA2A.Test.AgentSupervisorCase`) so
  `test/ash_a2a_sse_stream_test.exs` can call the real `A2A.stream/3` public
  API against an actual supervised process -- not a bare
  `AshA2A.Dispatcher.dispatch/3` function call -- matching the pattern
  `test/ash_a2a_test.exs`'s `EchoAgent` already establishes for `:call`.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.StreamingWidget,
    name: "streaming_widget_agent"
end
