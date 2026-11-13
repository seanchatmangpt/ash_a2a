defmodule AshA2A.Protocol.TimelineEntry do
  @moduledoc """
  A generation-ordered entry in a task's timeline (A2A v1.1, ADR-002).

  `entry` is `{:message, Message.t()}` (client input), `{:status, TaskStatus.t()}`
  (agent status) or `{:unknown, term()}` -- an entry kind this implementation
  does not recognise. Decoders fail open: unknown kinds are kept as `:unknown`
  (generation still accounted for) rather than refused.
  """

  @type entry ::
          {:message, AshA2A.Protocol.Message.t()}
          | {:status, AshA2A.Protocol.Task.Status.t()}
          | {:unknown, term()}

  @type t :: %__MODULE__{entry: entry(), generation: non_neg_integer()}

  @enforce_keys [:entry]
  defstruct [:entry, generation: 0]
end
