defmodule AshA2A.Domain.Verifiers.VerifyExtensions do
  @moduledoc """
  Verifies `AshA2A.Domain`'s `transport.extension` declarations: every
  extension `uri` must be unique within the domain.
  """

  use Spark.Dsl.Verifier

  alias AshA2A.Domain.Extension

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Spark.Dsl.Verifier.get_entities([:transport])
    |> Enum.filter(&match?(%Extension{}, &1))
    |> Enum.frequencies_by(& &1.uri)
    |> Enum.find(fn {_uri, count} -> count > 1 end)
    |> case do
      nil ->
        :ok

      {uri, count} ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:transport, :extension, uri],
           message:
             "extension uri #{inspect(uri)} is declared #{count} times; extension uris must be unique"
         )}
    end
  end
end
