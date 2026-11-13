defmodule AshA2A.TaskStore.Ash.PushRow do
  @moduledoc "One persisted push notification config, keyed by namespace/task_id/config_id."
  use Ash.Resource,
    domain: AshA2A.TaskStore.Ash.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    attribute(:namespace, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:task_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:config_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:payload, :term, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:namespace, :task_id, :config_id, :payload])
    end

    update :update do
      primary?(true)
      accept([:payload])
    end
  end
end
