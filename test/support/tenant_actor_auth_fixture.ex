defmodule AshA2A.Test.Fixture.TenantActorNote do
  @moduledoc """
  Real fixture resource for `test/ash_a2a_plug_tenant_actor_test.exs` --
  assignment #10: proving real tenant+actor threading through a REAL
  `A2A.Plug.Auth` + `A2A.Plug` HTTP pipeline into a REAL multitenant Ash
  resource, combining item #2's real-auth-pipeline proof
  (`test/ash_a2a_plug_auth_test.exs`, `AshA2A.Test.Fixture.AuthProbe`) with a
  genuine `multitenancy do strategy :attribute end` resource and a genuine
  `Ash.Policy.Authorizer` policy keyed on the verified actor -- not the
  `AuthProbe` fixture's generic action that only reflects
  `context.actor`/`context.tenant` back as data, and not the existing
  `test/ash_a2a_dispatcher_tenant_test.exs` tenant coverage, which calls
  `AshA2A.Dispatcher.dispatch/5` directly and so never proves the identity
  really came from a verified HTTP credential.

  Two real, load-bearing behaviors this resource exercises end to end:

    * **Real multitenancy isolation** (`multitenancy do strategy :attribute
      attribute :tenant end`, same strategy as
      `AshA2A.Test.Fixture.TenantedItem`): the `:tenant` attribute is not
      accepted by `:create_note`'s `accept` list, so the only way a created
      record's `tenant` is ever populated is via the `tenant:` opt Ash's own
      multitenancy machinery derives from the resolved
      `AshA2A.ExecutionContext`, which in turn comes only from
      `auth_identity[:tenant]` -- never from message data a caller controls.
      `:list_notes` is scoped to `Ash.DataLayer.Ets`'s real per-tenant
      partitioning, so a caller authenticated as tenant "acme" can never see
      a record real-created under tenant "beta", and vice versa.
    * **Real actor-keyed policy authorization**
      (`Ash.Policy.Authorizer`, `actor_attribute_equals(:id, ...)`-free
      `actor_present()` gate plus a `created_by` attribute populated from
      `context.actor` by a real `Ash.Resource.Change` function, not read
      back from any caller-supplied input) -- proving the verified identity's
      `:id` claim, not just its `:tenant` claim, really reaches the Ash
      changeset through the full real pipeline.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.TenantActorNoteDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshA2A]

  multitenancy do
    strategy(:attribute)
    attribute(:tenant)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:tenant, :string, public?: true, allow_nil?: false)
    attribute(:body, :string, public?: true, allow_nil?: false)
    # Never accepted as create input -- populated exclusively by the
    # `set_created_by_from_actor` change below, from the real verified
    # `context.actor`, so a caller can never spoof authorship by putting
    # `"created_by"` in the A2A message's own data payload.
    attribute(:created_by, :string, public?: true, allow_nil?: true)
  end

  changes do
    change(fn changeset, context ->
      actor_id =
        case context.actor do
          %{id: id} -> id
          %{"id" => id} -> id
          _other -> nil
        end

      Ash.Changeset.force_change_attribute(changeset, :created_by, actor_id)
    end)
  end

  policies do
    # Every action on this resource requires a real verified actor -- an
    # unauthenticated dispatch (auth_identity `nil`, per
    # `AshA2A.ContextResolver`'s fail-closed default) is really forbidden by
    # `Ash.Policy.Authorizer`, not merely documented as unsupported.
    policy(always()) do
      authorize_if(actor_present())
    end
  end

  actions do
    defaults([:read, create: [:body], update: [:body]])
  end

  a2a do
    skill(:create_note, :create)
    skill(:list_notes, :read)
  end
end

defmodule AshA2A.Test.Fixture.TenantActorNoteDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.TenantActorNote` above.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.TenantActorNote)
  end
end

defmodule AshA2A.Test.Fixture.TenantActorNoteAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer over `AshA2A.Test.Fixture.TenantActorNote`,
  started directly (registered under its own module name) so a real
  `A2A.Plug` can front it with `agent: __MODULE__` in
  `test/ash_a2a_plug_tenant_actor_test.exs`.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.TenantActorNote,
    name: "tenant_actor_note_agent"
end
