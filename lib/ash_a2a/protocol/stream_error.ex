defmodule AshA2A.Protocol.StreamError do
  @moduledoc """
  A non-fatal rejection of a single client request on a live stream
  (A2A v1.1 `StreamError`, `StreamResponse.error` field 6). The stream stays open.
  """

  @type t :: %__MODULE__{
          task_id: String.t() | nil,
          code: String.t(),
          message: String.t() | nil,
          reference_id: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:code]
  defstruct [:task_id, :code, :message, :reference_id, metadata: %{}]
end
