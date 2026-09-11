defmodule AshA2A.Test.Fixture.ErrorClassProbe do
  @moduledoc """
  Real fixture resource for `test/ash_a2a_dispatcher_error_class_test.exs`
  (assignment #9: real dispatcher error-class message-text mapping).

  A real `Ash.Policy.Authorizer` policy that unconditionally denies every
  action, so dispatching against this resource always reaches
  `AshA2A.Dispatcher.to_reply/1`'s real `%{class: :forbidden}` clause via a
  genuine `Ash.Error.Forbidden.Policy` -- not a hand-constructed error term.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.ErrorClassProbeDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  policies do
    policy always() do
      forbid_if(always())
    end
  end

  a2a do
    skill(:list, :read)
  end
end

defmodule AshA2A.Test.Fixture.ErrorClassProbeDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.ErrorClassProbe`."

  use Ash.Domain

  resources do
    resource(AshA2A.Test.Fixture.ErrorClassProbe)
  end
end
