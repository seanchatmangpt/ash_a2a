defmodule AshA2A.Domain.Verifiers.VerifyConfig do
  @moduledoc """
  Verifies `AshA2A.Domain` declarations:

  - `agent.name` is required (a `Spark.Error.DslError`, not a warning).
  - At least one of `transport.base_url` or `agent.url` should be set --
    missing both is a warning, not an error.
  - Every `security_scheme` kind must be an atom in the allowed set
    (`:bearer`, `:api_key`, `:none`).
  """

  use Spark.Dsl.Verifier

  alias AshA2A.Domain

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    with :ok <- require_agent_name(dsl_state, module),
         :ok <- verify_scheme_kinds(dsl_state, module) do
      warn_unless_url(dsl_state, module)
    end
  end

  defp require_agent_name(dsl_state, module) do
    case Spark.Dsl.Verifier.get_option(dsl_state, [:agent], :name) do
      nil ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:agent, :name],
           message: "required option `agent.name` is not set"
         )}

      _name ->
        :ok
    end
  end

  defp verify_scheme_kinds(dsl_state, module) do
    dsl_state
    |> Spark.Dsl.Verifier.get_entities([:security])
    |> Enum.reduce_while(:ok, fn
      %AshA2A.Domain.SecurityScheme{name: name, kind: kind}, :ok ->
        if is_atom(kind) and kind in Domain.scheme_kinds() do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            Spark.Error.DslError.exception(
              module: module,
              path: [:security, name, :kind],
              message:
                "invalid security scheme kind `#{inspect(kind)}` -- expected one of " <>
                  inspect(Domain.scheme_kinds())
            )}}
        end

      _other, :ok ->
        {:cont, :ok}
    end)
  end

  defp warn_unless_url(dsl_state, _module) do
    base_url? = not is_nil(Spark.Dsl.Verifier.get_option(dsl_state, [:transport], :base_url))
    agent_url? = not is_nil(Spark.Dsl.Verifier.get_option(dsl_state, [:agent], :url))

    if base_url? or agent_url? do
      :ok
    else
      {:warn,
       [
         "transport.base_url is not set; agent.url is also unset -- " <>
           "the derived AgentCard will have no url. Set `transport do base_url ... end` " <>
           "or `agent do url ... end`."
       ]}
    end
  end
end
