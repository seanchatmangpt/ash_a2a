defmodule AshA2A.Domain.Transformers.PersistConfig do
  @moduledoc """
  Persists all `AshA2A.Domain` section values under flat
  `ash_a2a_domain_*` persisted keys, and derives the agent-card identity
  from the `agent` + `transport` section values.
  """

  use Spark.Dsl.Transformer

  alias AshA2A.Domain
  alias AshA2A.Domain.SecurityScheme
  alias Spark.Dsl.Transformer

  @impl true
  def after?(AshA2A.Domain.Transformers.PersistMounts), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    agent = %{
      name: Transformer.get_option(dsl_state, [:agent], :name),
      description: Transformer.get_option(dsl_state, [:agent], :description),
      version: Transformer.get_option(dsl_state, [:agent], :version),
      url: Transformer.get_option(dsl_state, [:agent], :url),
      provider: Transformer.get_option(dsl_state, [:agent], :provider),
      documentation_url: Transformer.get_option(dsl_state, [:agent], :documentation_url),
      icon_url: Transformer.get_option(dsl_state, [:agent], :icon_url)
    }

    transport = %{
      base_url: Transformer.get_option(dsl_state, [:transport], :base_url),
      # `transport.mount` is the `default_mount` option (lane G-I renamed the
      # option; a same-named option + entity would be ambiguous). The
      # persisted key keeps its lane-B name and semantics.
      mount: Transformer.get_option(dsl_state, [:transport], :default_mount, "/a2a"),
      streaming: Transformer.get_option(dsl_state, [:transport], :streaming, true),
      push_notifications:
        Transformer.get_option(dsl_state, [:transport], :push_notifications, false)
    }

    schemes =
      dsl_state
      |> Transformer.get_entities([:security])
      |> Enum.filter(&match?(%SecurityScheme{}, &1))

    requirements = Transformer.get_option(dsl_state, [:security], :requirements, []) || []

    dsl_state =
      dsl_state
      |> Transformer.persist(:ash_a2a_domain_agent, agent)
      |> Transformer.persist(:ash_a2a_domain_transport, transport)
      |> Transformer.persist(:ash_a2a_domain_security_schemes, schemes)
      |> Transformer.persist(:ash_a2a_domain_security_requirements, requirements)
      |> Transformer.persist(
        :ash_a2a_domain_card_identity,
        Domain.card_identity(agent, transport)
      )

    {:ok, dsl_state}
  end
end
