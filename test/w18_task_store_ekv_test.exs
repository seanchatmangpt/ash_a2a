defmodule AshA2A.W18TaskStoreEkvTest do
  use AshA2A.TaskStoreContract, store: AshA2A.TaskStore.Ekv

  def start_store(tag) do
    id = System.unique_integer([:positive])
    name = :"w18_ekv_#{tag}_#{id}"
    dir = Path.join(System.tmp_dir!(), "w18_ekv_#{tag}_#{id}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!(
      Supervisor.child_spec(AshA2A.TaskStore.Ekv.child_spec(name: name, data_dir: dir),
        id: {:w18_ekv, name}
      )
    )

    name
  end
end
