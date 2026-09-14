defmodule Ultracode.Domain do
  @moduledoc """
  `Ash.Domain` for the Ultracode operating loop. `Ultracode.Info` (Ash's
  generated introspection) is capability truth for this domain, same
  principle as `AshA2A.Info` in the sibling ash_a2a library.
  """
  use Ash.Domain

  resources do
    resource Ultracode.Run
    resource Ultracode.Epoch
  end
end
