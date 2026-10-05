defmodule AshA2A.Protocol.Extensions.Schema do
  @extension_uri "urn:sa2a:extension:schema:v1"
  @version "1"

  @moduledoc """
  Per-skill JSON Schema as an A2A v1.0 agent extension.

  v1.0 `AgentCard.skills` entries advertise only input/output MIME modes —
  callers cannot discover what arguments a skill accepts before dispatch.
  This module projects `AshA2A.Schema.for_skill/2` schemas for every skill in
  the subject's compiled capability index into ONE
  `AshA2A.Protocol.AgentExtension` declaration under the stable URI
  `#{@extension_uri}`, so a client can fetch the card once and
  know the full typed input contract of every advertised skill.

  A skill whose action carries an argument type the schema projection cannot
  represent (`AshA2A.Schema.for_skill/2` ->
  `{:error, {:unserializable_type, type}}`) is never allowed to fail the
  card: it is omitted from `params[:schemas]` and listed under
  `params[:omitted]` with its typed reason, so verifiers and clients can see
  exactly which skills advertise no schema and why.

  ## Examples

      iex> ext = AshA2A.Protocol.Extensions.Schema.declaration(AshA2A.Test.Fixture.TypedArguments)
      iex> ext.uri
      "urn:sa2a:extension:schema:v1"
      iex> ext.required
      false
      iex> schema = ext.params.schemas["AshA2A.Test.Fixture.TypedArguments.search"]
      iex> schema["required"]
      ["query"]
      iex> schema["properties"]["query"]
      %{"type" => "string"}

  Attachment is idempotent per URI — attaching twice replaces, never
  duplicates:

      iex> card = AshA2A.Info.agent_card(AshA2A.Test.Fixture.TypedArguments)
      iex> card = AshA2A.Protocol.Extensions.Schema.attach(card, AshA2A.Test.Fixture.TypedArguments)
      iex> card = AshA2A.Protocol.Extensions.Schema.attach(card, AshA2A.Test.Fixture.TypedArguments)
      iex> card.capabilities.extensions |> Enum.filter(&(&1.uri == AshA2A.Protocol.Extensions.Schema.uri())) |> length()
      1
  """

  alias AshA2A.Protocol.AgentExtension

  @doc "The stable URI advertised by this extension."
  @spec uri() :: String.t()
  def uri, do: @extension_uri

  @doc """
  Builds ONE extension declaration carrying every public skill's JSON Schema.

  Accepts a resource or an `Ash.Domain` with the `AshA2A` extension and a
  compiled capability index (`AshA2A.Info.capability_index!/1` raises
  `ArgumentError` otherwise — a subject with no index is never silently
  advertised with an empty schema set).

  Schemas are `AshA2A.Schema.for_skill/2` outputs keyed by the same skill id
  the card's `skills[].id` uses, so clients can join the two surfaces by id.
  Skills with unserializable argument types are omitted from `schemas` and
  listed under `omitted` with a typed, Jason-safe reason entry
  (`%{skill: id, reason: "unserializable_type", type: inspect(type)}`) — the
  raw `{:unserializable_type, type}` tuple is not Jason-encodable, and the
  params ride the card's JSON verbatim, so the reason is emitted in wire
  form directly. The declaration itself never fails the card.

  ## Options

    * `:uri` — override the extension URI (default `#{@extension_uri}`).
    * `:required` — advertise the extension as `required: true`
      (default `false`, so clients without schema support are never
      refused).
  """
  @spec declaration(module(), keyword()) :: AgentExtension.t()
  def declaration(resource_or_domain, opts \\ []) when is_atom(resource_or_domain) and is_list(opts) do
    skills = AshA2A.Info.capability_index!(resource_or_domain)

    {schemas, omitted} =
      skills
      |> Enum.sort_by(& &1.id)
      |> Enum.reduce({%{}, []}, fn skill, {schemas, omitted} ->
        case AshA2A.Schema.for_skill(skill, skill.resource) do
          {:ok, schema} ->
            {Map.put(schemas, skill.id, schema), omitted}

          {:error, {:unserializable_type, type}} ->
            {schemas,
             [%{skill: skill.id, reason: "unserializable_type", type: inspect(type)} | omitted]}
        end
      end)

    %AgentExtension{
      uri: Keyword.get(opts, :uri, @extension_uri),
      description:
        "Per-skill JSON Schema (Draft 2020-12) for skill input arguments, " <>
          "keyed by skill id; skills with unserializable argument types are " <>
          "listed under `omitted` with a typed reason.",
      required: Keyword.get(opts, :required, false),
      params: %{version: @version, schemas: schemas, omitted: omitted}
    }
  end

  @doc """
  Appends the schema declaration to a card or card-builder opts, idempotently.

  Accepts either:

    * an `AshA2A.Protocol.AgentCard` struct — the declaration replaces any
      existing same-URI entry in `capabilities.extensions` (attached last,
      so the freshest params win);
    * card-builder opts (a keyword list) — the declaration replaces any
      existing same-URI entry in `opts[:capabilities][:extensions]`, the
      same surface `AshA2A.Info.agent_card/2` and
      `AshA2A.CapabilityIndex.AgentCardBuilder.build_agent_card/2` already
      forward.

  Both paths replace same-URI entries rather than appending a duplicate, so
  attaching twice yields exactly one entry for `#{@extension_uri}`.

  ## Examples

      iex> card = AshA2A.Info.agent_card(AshA2A.Test.Fixture.TypedArguments)
      iex> attached = AshA2A.Protocol.Extensions.Schema.attach(card, AshA2A.Test.Fixture.TypedArguments)
      iex> [%AshA2A.Protocol.AgentExtension{params: %{schemas: schemas}}] = attached.capabilities.extensions
      iex> Map.has_key?(schemas, "AshA2A.Test.Fixture.TypedArguments.search")
      true
  """
  @spec attach(AshA2A.Protocol.AgentCard.t() | keyword(), module()) ::
          AshA2A.Protocol.AgentCard.t() | keyword()
  def attach(card_or_opts, resource_or_domain)

  def attach(%AshA2A.Protocol.AgentCard{} = card, resource_or_domain) do
    declaration = declaration(resource_or_domain)
    capabilities = card.capabilities || %{}

    %{
      card
      | capabilities:
          Map.put(
            capabilities,
            :extensions,
            put_extension(Map.get(capabilities, :extensions, []), declaration)
          )
    }
  end

  def attach(opts, resource_or_domain) when is_list(opts) do
    declaration = declaration(resource_or_domain)
    capabilities = Keyword.get(opts, :capabilities, %{}) || %{}

    Keyword.put(
      opts,
      :capabilities,
      Map.put(
        capabilities,
        :extensions,
        put_extension(Map.get(capabilities, :extensions, []), declaration)
      )
    )
  end

  # Replace-by-URI: drop any existing same-URI entry, then prepend the fresh
  # declaration. Idempotent by construction.
  defp put_extension(extensions, declaration) when is_list(extensions) do
    [declaration | Enum.reject(extensions, &(&1.uri == declaration.uri))]
  end
end
