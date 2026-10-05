defmodule AshA2A.Domain.SecurityScheme do
  @moduledoc """
  One declared A2A security scheme (`security do security_scheme :name, :kind end`).
  """

  defstruct [:name, :kind, :__identifier__, :__spark_metadata__]

  @type t :: %__MODULE__{
          name: atom(),
          kind: :bearer | :api_key | :none,
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }
end
