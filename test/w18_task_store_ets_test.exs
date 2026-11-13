defmodule AshA2A.W18TaskStoreEtsTest do
  use AshA2A.TaskStoreContract, store: AshA2A.Protocol.TaskStore.ETS

  def start_store(tag) do
    name = :"w18_ets_#{tag}_#{System.unique_integer([:positive])}"
    start_supervised!(
      Supervisor.child_spec({AshA2A.Protocol.TaskStore.ETS, [name: name]}, id: name)
    )

    name
  end
end
