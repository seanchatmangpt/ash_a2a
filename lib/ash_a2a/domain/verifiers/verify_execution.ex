defmodule AshA2A.Domain.Verifiers.VerifyExecution do
  @moduledoc """
  Verifies the v1.1 execution/transport knobs.

  `events_transport`, `cancel_in_flight` and `validate_input_modes` are not
  Spark DSL options: they are read from the `execution:` keyword of
  `use AshA2A.Agent` (and `config :ash_a2a, :execution`). `validate/1` is the
  pure check for that keyword and returns a typed `Spark.Error.DslError`.

  As a `Spark.Dsl.Verifier` it additionally re-asserts, at verify time, that a
  domain's `transport.user_artifacts` is a boolean.

  Rules:

    * `events_transport` -- `nil` or a running-transport reference: an atom
      (registered name / module), `{:global, term}`, `{:via, module, term}`
      or a `pid`. Booleans and other terms are refused.
    * `cancel_in_flight` -- `:refuse`, `:interrupt` / `:default` (the
      default behaviour) or `nil`.
    * `validate_input_modes` -- boolean (or `nil` = default).
    * `user_artifacts` -- boolean.
  """

  use Spark.Dsl.Verifier

  @cancel_values [:refuse, :interrupt, :default, nil]

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    case Spark.Dsl.Verifier.get_option(dsl_state, [:transport], :user_artifacts, false) do
      v when is_boolean(v) ->
        :ok

      other ->
        {:error,
         error(
           module,
           [:transport, :user_artifacts],
           "`user_artifacts` must be a boolean, got #{inspect(other)}"
         )}
    end
  end

  @doc """
  Validates an `execution:` keyword. Returns `:ok` or
  `{:error, %Spark.Error.DslError{}}`.
  """
  @spec validate(keyword(), module() | nil) :: :ok | {:error, Exception.t()}
  def validate(execution, module \\ nil) when is_list(execution) do
    with :ok <- check_events_transport(Keyword.get(execution, :events_transport), module),
         :ok <- check_cancel(Keyword.get(execution, :cancel_in_flight), module),
         :ok <-
           check_bool(
             :validate_input_modes,
             Keyword.get(execution, :validate_input_modes),
             module
           ) do
      check_bool(:user_artifacts, Keyword.get(execution, :user_artifacts), module)
    end
  end

  @doc "Like `validate/2` but raises the `Spark.Error.DslError`."
  @spec validate!(keyword(), module() | nil) :: :ok
  def validate!(execution, module \\ nil) do
    case validate(execution, module) do
      :ok -> :ok
      {:error, e} -> raise e
    end
  end

  defp check_events_transport(nil, _), do: :ok
  defp check_events_transport(v, _) when is_atom(v) and not is_boolean(v), do: :ok
  defp check_events_transport(v, _) when is_pid(v), do: :ok
  defp check_events_transport({:global, _}, _), do: :ok
  defp check_events_transport({:via, m, _}, _) when is_atom(m), do: :ok

  defp check_events_transport(v, module),
    do:
      {:error,
       error(
         module,
         [:execution, :events_transport],
         "invalid `events_transport` #{inspect(v)} -- expected nil or a transport reference " <>
           "(registered name atom, {:global, term}, {:via, module, term} or pid)"
       )}

  defp check_cancel(v, _) when v in @cancel_values, do: :ok

  defp check_cancel(v, module),
    do:
      {:error,
       error(
         module,
         [:execution, :cancel_in_flight],
         "invalid `cancel_in_flight` #{inspect(v)} -- expected one of #{inspect(@cancel_values)}"
       )}

  defp check_bool(_key, nil, _), do: :ok
  defp check_bool(_key, v, _) when is_boolean(v), do: :ok

  defp check_bool(key, v, module),
    do:
      {:error,
       error(module, [:execution, key], "invalid `#{key}` #{inspect(v)} -- expected a boolean")}

  defp error(module, path, message),
    do: Spark.Error.DslError.exception(module: module, path: path, message: message)
end
