defmodule AshA2A.Domain.Extension do
  @moduledoc """
  One declared A2A agent extension (`transport do extension "https://..." end`).

  Merged into the AgentCard `capabilities.extensions` list by
  `AshA2A.CapabilityIndex.AgentCardBuilder`. `uri` is unique per domain
  (`AshA2A.Domain.Verifiers.VerifyExtensions`).
  """

  defstruct [:uri, :description, :__identifier__, :__spark_metadata__, required: false, params: %{}]

  @type t :: %__MODULE__{
          uri: String.t(),
          description: String.t() | nil,
          required: boolean(),
          params: map(),
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }
end
