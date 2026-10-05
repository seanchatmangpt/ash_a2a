defmodule A2aDemo.Domain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource A2aDemo.Note
  end
end
