defmodule AshA2A.TaskStore.Ash.TaskRow do
  @moduledoc """
  One persisted task. Columns mirror a2a-python's `DatabaseTaskStore` table:
  `task_id`, `owner`, `context_id`, `status_state`, `last_updated`,
  `protocol_version`, `version` (optimistic concurrency) and `payload` (the
  encoded task). `namespace` carries the store `ref` so several logical stores
  can share one table.

  Data layer: `Ash.DataLayer.Ets` (mix.exs lists neither ash_postgres nor
  ash_sqlite). Swapping the data layer keeps the same resource shape.
  """
  use Ash.Resource,
    domain: AshA2A.TaskStore.Ash.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    attribute(:namespace, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:task_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:owner, :string, public?: true)
    attribute(:context_id, :string, public?: true)
    attribute(:status_state, :string, public?: true)
    attribute(:last_updated, :utc_datetime_usec, public?: true)
    attribute(:protocol_version, :string, public?: true)
    attribute(:version, :integer, allow_nil?: false, default: 1, public?: true)
    attribute(:payload, :term, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :namespace,
        :task_id,
        :owner,
        :context_id,
        :status_state,
        :last_updated,
        :protocol_version,
        :version,
        :payload
      ])
    end

    update :update do
      primary?(true)

      accept([
        :owner,
        :context_id,
        :status_state,
        :last_updated,
        :protocol_version,
        :version,
        :payload
      ])
    end
  end
end
