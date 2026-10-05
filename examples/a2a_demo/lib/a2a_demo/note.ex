defmodule A2aDemo.Note do
  @moduledoc """
  The one demo capability: an ETS-backed note store with exactly two A2A
  skills.

  * `get_note` (`:read`, consequence `:observe`) -- admitted with
    authentication alone.
  * `create_note` (generic `:action`, consequence `:change`,
    `lease_required? true`) -- refused `:authority_required` unless the
    verified caller holds a standing grant for capability `"create_note"`.
  """

  use Ash.Resource,
    domain: A2aDemo.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshA2A]

  attributes do
    uuid_primary_key :id
    attribute :text, :string, public?: true, allow_nil?: false
    create_timestamp :inserted_at
  end

  actions do
    defaults [:read]

    # The real Ash write action is deliberately private (`public? false`): it
    # never appears on the agent card. The A2A surface is the generic
    # `create_note` action below, whose `:change` consequence routes it
    # through the receipted CommandBus admission gate.
    create :create do
      public? false
      accept [:text]
    end

    action :create_note, :map do
      argument :text, :string, allow_nil?: false

      run fn input, _context ->
        note =
          Ash.Changeset.for_create(A2aDemo.Note, :create, %{text: input.arguments.text},
            authorize?: false
          )
          |> Ash.create!()

        {:ok, %{id: note.id, text: note.text}}
      end
    end
  end

  # Satisfies the `lease_required?` compile-time verifier: the skill's target
  # carries a real Ash authorizer. The demo policy is deliberately permissive;
  # the a2a authority gate (the standing grant) is the boundary this demo
  # exists to show.
  policies do
    bypass always() do
      authorize_if always()
    end
  end

  a2a do
    skill :get_note, :read do
      description "List every note (observe: authentication only)"
    end

    skill :create_note, :create_note do
      description "Create a note (change: requires a standing authority grant)"
      consequence :change
      lease_required? true
    end
  end
end
