defmodule AshA2A.TaskStore.Ash.Domain do
  @moduledoc "Ash domain holding the resources behind `AshA2A.TaskStore.Ash`."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshA2A.TaskStore.Ash.TaskRow)
    resource(AshA2A.TaskStore.Ash.PushRow)
  end
end
