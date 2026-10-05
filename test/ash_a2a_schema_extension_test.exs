defmodule AshA2A.Test.SchemaExtensionFixture do
  @moduledoc """
  Real ETS fixture surface for lane V25, defined inside this test's own file
  (same established pattern as `AshA2A.Test.ProtocolExtensionE2EFixture`).

  `AshA2A.Test.SchemaExtensionFixture.Note` is a genuine `Ash.Resource` with
  the `AshA2A` extension, exposing two real skills with different argument
  serializability:

    * `search` — fully serializable (required `:string` + optional
      `:integer`), so its schema lands in `params[:schemas]`,
    * `snapshot` — carries an unserializable `:term` argument, so it is
      omitted from `params[:schemas]` and listed under `params[:omitted]`
      with the typed `{:unserializable_type, :term}` reason.

  `search_skill_id/0` / `snapshot_skill_id/0` expose the canonical
  capability ids (`AshA2A.CapabilityIndex.Compiler.capability_id/2`) so the
  assertions never hand-copy them.
  """

  def search_skill_id, do: "AshA2A.Test.SchemaExtensionFixture.Note.search"
  def snapshot_skill_id, do: "AshA2A.Test.SchemaExtensionFixture.Note.snapshot"

  defmodule Note do
    @moduledoc """
    Real ETS fixture resource: two skills, one schema-serializable, one not.
    """

    use Ash.Resource,
      domain: AshA2A.Test.SchemaExtensionFixture.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])

      action :search, :string do
        argument(:query, :string, allow_nil?: false)
        argument(:limit, :integer, default: 10)

        run(fn _input, _context -> {:ok, "ok"} end)
      end

      action :snapshot, :term do
        argument(:state, :term, allow_nil?: false)

        run(fn _input, _context -> {:ok, nil} end)
      end
    end

    # No `a2a do skill ... end` declarations on purpose: public Ash actions
    # are exposed through the capability index without declarations, and an
    # explicit `skill(:snapshot, :snapshot)` override would trip the tree's
    # own `AshA2A.Verifiers.VerifySkills` refusal warning
    # (`refused_type_not_json_serializable`) on the :term argument -- which
    # fails `mix compile --warnings-as-errors`. The :term skill is still in
    # the index (and still lands in params[:omitted] via
    # `AshA2A.Schema.for_skill/2`'s typed error), which is exactly the path
    # this extension exists to cover.
  end

  defmodule Domain do
    @moduledoc """
    Real fixture domain for the Note resource. `validate_config_inclusion?:
    false` -- same established pattern as the other test-only fixture
    domains in this codebase.
    """

    use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

    resources do
      resource(AshA2A.Test.SchemaExtensionFixture.Note)
    end
  end
end

defmodule AshA2A.SchemaExtensionTest do
  @moduledoc """
  Real, end-to-end test for lane V25 (per-skill JSON Schema as an A2A v1.0
  agent extension): a real ETS Ash fixture resource with two exposed skills
  — one fully serializable (`:search`, string + integer arguments) and one
  with an unserializable `:term` argument (`:snapshot`) — driven through the
  REAL pipeline:

    1. `AshA2A.Protocol.Extensions.Schema.declaration/2` projects
       `AshA2A.Schema.for_skill/2` schemas for every public skill, omits the
       `:term` skill into `params[:omitted]` with its typed reason, and
       never fails the card,
    2. `attach/2` appends exactly one extension entry to the real
       `AshA2A.Info.agent_card/1` output — and to card-builder opts —
       idempotently (double attach => still one),
    3. `AshA2A.Protocol.JSON.encode_agent_card/2` puts the declaration on
       the wire (V2's preservation path) and a Jason round-trip loses
       nothing: uri/required/params.schemas/params.omitted with the typed
       reason `%{"reason" => "unserializable_type", "type" => "Ash.Type.Term"}`
       all survive.

  No `Mock`/`mox`/`patch`/`monkeypatch` anywhere: the resource is a real
  `Ash.Resource` on the ETS data layer, the card is the real
  `AshA2A.Info.agent_card/1` projection, and the wire encoding is the real
  unmodified codec.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Extensions.Schema
  alias AshA2A.Test.SchemaExtensionFixture

  @search_id SchemaExtensionFixture.search_skill_id()
  @snapshot_id SchemaExtensionFixture.snapshot_skill_id()

  describe "declaration/2" do
    test "projects schemas for serializable skills, omits the :term skill with its typed reason" do
      ext = Schema.declaration(SchemaExtensionFixture.Note)

      assert %AshA2A.Protocol.AgentExtension{} = ext
      assert ext.uri == "urn:sa2a:extension:schema:v1"
      assert ext.required == false
      assert ext.params[:version] == "1"

      search_schema = ext.params.schemas[@search_id]
      assert %{"type" => "object", "required" => ["query"]} = search_schema
      assert %{"type" => "string"} = search_schema["properties"]["query"]
      assert %{"type" => "integer"} = search_schema["properties"]["limit"]

      refute Map.has_key?(ext.params.schemas, @snapshot_id)

      assert [
               %{skill: @snapshot_id, reason: "unserializable_type", type: "Ash.Type.Term"}
             ] = ext.params.omitted
    end

    test "covers every public skill in the compiled capability index (id join with the card)" do
      ext = Schema.declaration(SchemaExtensionFixture.Note)
      card = AshA2A.Info.agent_card(SchemaExtensionFixture.Note)

      schema_ids = Map.keys(ext.params.schemas) ++ Enum.map(ext.params.omitted, & &1.skill)
      card_skill_ids = card.skills |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.new(schema_ids) == card_skill_ids
      assert MapSet.size(card_skill_ids) > 0
      assert @search_id in card_skill_ids
    end
  end

  describe "attach/2" do
    test "appends the declaration to a real agent card's capabilities.extensions" do
      card = AshA2A.Info.agent_card(SchemaExtensionFixture.Note)
      assert card.capabilities[:extensions] == nil

      attached = Schema.attach(card, SchemaExtensionFixture.Note)

      assert [%AshA2A.Protocol.AgentExtension{} = ext] = attached.capabilities.extensions
      assert ext.uri == Schema.uri()
      assert ext.params.schemas[@search_id]["required"] == ["query"]
      # The rest of the card is untouched.
      assert attached.skills == card.skills
      assert attached.url == card.url
    end

    test "double attach is idempotent: exactly one same-URI entry" do
      attached_twice =
        SchemaExtensionFixture.Note
        |> AshA2A.Info.agent_card()
        |> Schema.attach(SchemaExtensionFixture.Note)
        |> Schema.attach(SchemaExtensionFixture.Note)

      assert [%AshA2A.Protocol.AgentExtension{} = ext] =
               attached_twice.capabilities.extensions

      assert ext.uri == Schema.uri()
      assert ext.params.schemas[@search_id]["required"] == ["query"]
    end

    test "attaches onto card-builder opts, replacing same-URI entries idempotently" do
      existing = %AshA2A.Protocol.AgentExtension{uri: Schema.uri(), params: %{"stale" => true}}

      opts =
        [capabilities: %{streaming: true, extensions: [existing]}]
        |> Schema.attach(SchemaExtensionFixture.Note)
        |> Schema.attach(SchemaExtensionFixture.Note)

      assert [%AshA2A.Protocol.AgentExtension{} = ext] = opts[:capabilities][:extensions]
      assert ext.uri == Schema.uri()
      assert ext.params[:version] == "1"
      # The stale same-URI entry was replaced, not appended after.
      assert length(opts[:capabilities][:extensions]) == 1
      # Other capability keys survive.
      assert opts[:capabilities][:streaming] == true
    end

    test "empty builder opts get a capabilities map with the declaration" do
      opts = Schema.attach([], SchemaExtensionFixture.Note)
      assert [%AshA2A.Protocol.AgentExtension{uri: uri} = ext] = opts[:capabilities][:extensions]
      assert uri == Schema.uri()
      assert ext.params.schemas[@search_id]["required"] == ["query"]
    end
  end

  describe "wire survival" do
    test "encoded card carries the extension through the real codec and a Jason round-trip" do
      card =
        SchemaExtensionFixture.Note
        |> AshA2A.Info.agent_card()
        |> Schema.attach(SchemaExtensionFixture.Note)

      encoded =
        card
        |> AshA2A.Protocol.JSON.encode_agent_card(url: card.url)
        |> Jason.encode!()

      wire = Jason.decode!(encoded)

      assert %{
               "capabilities" => %{
                 "extensions" => [
                   %{
                     "uri" => "urn:sa2a:extension:schema:v1",
                     "required" => false,
                     "description" => description,
                     "params" => %{
                       "version" => "1",
                       "schemas" => schemas,
                       "omitted" => [omitted]
                     }
                   }
                 ]
               }
             } = wire

      assert %{"type" => "object", "required" => ["query"]} = schemas[@search_id]
      assert %{"type" => "string"} = schemas[@search_id]["properties"]["query"]

      assert %{
               "skill" => @snapshot_id,
               "reason" => "unserializable_type",
               "type" => "Ash.Type.Term"
             } = omitted

      assert description =~ "JSON Schema"
    end

    test "Jason decode -> encode round-trip is stable (idempotent wire form)" do
      card =
        SchemaExtensionFixture.Note
        |> AshA2A.Info.agent_card()
        |> Schema.attach(SchemaExtensionFixture.Note)

      encoded =
        card
        |> AshA2A.Protocol.JSON.encode_agent_card(url: card.url)
        |> Jason.encode!()

      assert encoded |> Jason.decode!() |> Jason.encode!() |> Jason.decode!() ==
               Jason.decode!(encoded)
    end
  end
end
