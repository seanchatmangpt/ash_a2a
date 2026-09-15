defmodule AshA2A.Test.Fixture.Crashy do
  @moduledoc """
  Real fixture resource whose one generic `:action` skill's `run/2`
  callback genuinely raises a `RuntimeError` -- used only by
  `test/ash_a2a/command_bus_test.exs` to exercise
  `AshA2A.CommandBus.run/4`'s fail-closed handling of a real, unmocked
  exception raised inside the actual dispatch path.

  `AshA2A.Dispatcher.dispatch/5` routes a generic `:action` skill through
  `Ash.run_action/2` -> `Ash.Actions.Action.run/3`
  (`deps/ash/lib/ash/actions/action.ex`), which itself `rescue`s any
  exception raised by the action's `run/2` callback, wraps it as an
  `Ash.Error`, and then `reraise`s it -- so the crash this fixture's
  `:detonate` action produces still genuinely propagates all the way out
  of `Ash.run_action/2` uncaught (as a real, wrapped `Ash.Error` exception,
  not the bare `RuntimeError`), exactly as a real bug inside
  resource-owned action code would.

  Not a mock: nothing here asserts on *how* it was called -- only the real
  resulting state (receipt shape, claim closure, caller survival) the
  crash produces is asserted by the test that uses it.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.CrashyDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :detonate, :string do
      run(fn _input, _context ->
        raise "AshA2A.Test.Fixture.Crashy: real dispatch crash fixture"
      end)
    end
  end

  a2a do
    skill(:detonate, :detonate, consequence: :observe)
  end
end

defmodule AshA2A.Test.Fixture.CrashyDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.Crashy` above, mirroring
  `AshA2A.Test.Fixture.TypedArgumentsDomain`'s small-test-only-domain shape
  (`validate_config_inclusion?: false` -- never meant to be registered in
  `config :ash_a2a, ash_domains`).
  """

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Test.Fixture.Crashy)
  end
end
