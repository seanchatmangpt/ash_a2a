defmodule AshA2A.Test.PresenceFixture do
  @moduledoc """
  A real `Phoenix.Presence` implementation, backed by a real
  `Phoenix.PubSub` process (`AshA2A.Test.PubSubFixture`), used by
  `AshA2A.RuntimeProvidersIntegrationTest` to exercise
  `AshA2A.Topology.Presence` against an actual host Presence module rather
  than a substitute provider module.
  """
  use Phoenix.Presence,
    otp_app: :ash_a2a,
    pubsub_server: AshA2A.Test.PubSubFixture
end
