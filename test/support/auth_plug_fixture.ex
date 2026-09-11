defmodule AshA2A.Test.Fixture.AuthProbe do
  @moduledoc """
  Real fixture resource for `test/ash_a2a_plug_auth_test.exs` -- exercises
  the real end-to-end auth path: a real `A2A.Plug.Auth` verifies a real
  Bearer credential and stores the resulting identity in
  `conn.private[:a2a][:auth]`; real `A2A.Plug` merges it into the call-level
  metadata as `"a2a.auth"`; `AshA2A.Agent.__dispatch__/3` reads
  `metadata["a2a.auth"][:identity]` and threads it into
  `AshA2A.Dispatcher.dispatch/5` as `auth_identity`; `AshA2A.ContextResolver`
  turns that into `actor`/`tenant`.

  This `:whoami` generic action reflects `context.actor`/`context.tenant`
  straight back to the caller as plain data, so the test can assert on the
  *real* value that reached the real Ash action -- not on whether some
  function was called.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.AuthProbeDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :whoami, :map do
      run(fn _input, context ->
        {:ok, %{actor: context.actor, tenant: context.tenant}}
      end)
    end
  end

  a2a do
    skill(:whoami, :whoami)
  end
end

defmodule AshA2A.Test.Fixture.AuthProbeDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.AuthProbe` above.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.AuthProbe)
  end
end

defmodule AshA2A.Test.Fixture.AuthProbeAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer built with `use AshA2A.Agent` over the fixture
  `AuthProbe` resource above, started directly (registered under its own
  module name, the `A2A.Agent`-generated `start_link/1` default) so a real
  `A2A.Plug` can front it with `agent: __MODULE__` in
  `test/ash_a2a_plug_auth_test.exs`.
  """

  use AshA2A.Agent, resource_or_domain: AshA2A.Test.Fixture.AuthProbe, name: "auth_probe_agent"
end
