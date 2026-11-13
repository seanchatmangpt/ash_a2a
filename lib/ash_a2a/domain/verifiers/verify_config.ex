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
         :ok <- verify_scheme_kinds(dsl_state, module),
         :ok <- verify_unique_scheme_names(dsl_state, module),
         :ok <- verify_scheme_fields(dsl_state, module),
         :ok <- verify_requirements(dsl_state, module),
         :ok <- verify_requirement_scopes(dsl_state, module),
         :ok <- verify_urls(dsl_state, module),
         :ok <- verify_default_mount(dsl_state, module) do
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

  defp schemes(dsl_state) do
    dsl_state
    |> Spark.Dsl.Verifier.get_entities([:security])
    |> Enum.filter(&match?(%AshA2A.Domain.SecurityScheme{}, &1))
  end

  defp config_error(module, path, message) do
    {:error, Spark.Error.DslError.exception(module: module, path: path, message: message)}
  end

  defp verify_unique_scheme_names(dsl_state, module) do
    dsl_state
    |> schemes()
    |> Enum.frequencies_by(& &1.name)
    |> Enum.find(fn {_name, count} -> count > 1 end)
    |> case do
      nil ->
        :ok

      {name, count} ->
        config_error(
          module,
          [:security, name],
          "security scheme `#{inspect(name)}` is declared #{count} times; scheme names must be unique"
        )
    end
  end

  defp verify_requirements(dsl_state, module) do
    declared = dsl_state |> schemes() |> MapSet.new(&to_string(&1.name))
    requirements = Spark.Dsl.Verifier.get_option(dsl_state, [:security], :requirements, []) || []

    case Enum.find(requirements, &(not MapSet.member?(declared, to_string(&1)))) do
      nil ->
        :ok

      undeclared ->
        config_error(
          module,
          [:security, :requirements],
          "security requirement `#{inspect(undeclared)}` references no declared security_scheme " <>
            "(declared: #{inspect(declared |> MapSet.to_list() |> Enum.sort())})"
        )
    end
  end

  # Kind-specific required fields: `:http` needs `http_scheme`, `:oauth2` needs
  # `oauth_flows`, `:openid_connect` needs `openid_url`.
  @required_scheme_fields %{
    http: :http_scheme,
    oauth2: :oauth_flows,
    openid_connect: :openid_url
  }

  defp verify_scheme_fields(dsl_state, module) do
    Enum.reduce_while(schemes(dsl_state), :ok, fn %{name: name, kind: kind} = scheme, :ok ->
      field = Map.get(@required_scheme_fields, kind)
      value = field && Map.get(scheme, field)

      if is_nil(field) or (not is_nil(value) and value != %{}) do
        {:cont, :ok}
      else
        {:halt,
         config_error(
           module,
           [:security, name, field],
           "security scheme `#{inspect(name)}` of kind `#{inspect(kind)}` requires `#{field}`"
         )}
      end
    end)
  end

  defp verify_requirement_scopes(dsl_state, module) do
    requirements =
      (Spark.Dsl.Verifier.get_option(dsl_state, [:security], :requirements, []) || [])
      |> MapSet.new(&to_string/1)

    scopes = Spark.Dsl.Verifier.get_option(dsl_state, [:security], :requirement_scopes, %{}) || %{}

    case Enum.find(Map.keys(scopes), &(not MapSet.member?(requirements, to_string(&1)))) do
      nil ->
        :ok

      stray ->
        config_error(
          module,
          [:security, :requirement_scopes],
          "requirement_scopes key #{inspect(stray)} is not listed in `requirements`"
        )
    end
  end

  defp verify_urls(dsl_state, module) do
    [
      {[:transport], :base_url},
      {[:agent], :url},
      {[:agent], :documentation_url},
      {[:agent], :icon_url}
    ]
    |> Enum.reduce_while(:ok, fn {section, key}, :ok ->
      case Spark.Dsl.Verifier.get_option(dsl_state, section, key) do
        nil ->
          {:cont, :ok}

        url ->
          if valid_url?(url) do
            {:cont, :ok}
          else
            {:halt,
             config_error(
               module,
               section ++ [key],
               "`#{key}` #{inspect(url)} is not a valid absolute http(s) URL " <>
                 "(expected scheme://host[:port][/path])"
             )}
          end
      end
    end)
  end

  defp valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _ ->
        false
    end
  end

  defp valid_url?(_), do: false

  defp verify_default_mount(dsl_state, module) do
    case Spark.Dsl.Verifier.get_option(dsl_state, [:transport], :default_mount, "/a2a") do
      "/" <> _ ->
        :ok

      other ->
        config_error(
          module,
          [:transport, :default_mount],
          "`default_mount` #{inspect(other)} must start with \"/\""
        )
    end
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
