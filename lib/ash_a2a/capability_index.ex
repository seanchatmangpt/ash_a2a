defmodule AshA2A.CapabilityIndex do
  @moduledoc """
  Thin public facade over a compiled A2A capability index's two real
  concerns, kept as separate modules:

    * `AshA2A.CapabilityIndex.Validator` -- fail-closed business-rule
      validation (`validate/1`, delegated to below).
    * `AshA2A.CapabilityIndex.AgentCardBuilder` -- real `A2A.AgentCard.t()`
      construction (`build_agent_card/2`, delegated to below).

  This facade exists so existing call sites (`AshA2A.Verify`,
  `AshA2A.Info`) and the `AshA2A.CapabilityIndex.skill()`/`refusal()` types
  they reference keep working unchanged; new code may call either extracted
  module directly.

  Per the ash_a2a ARD (`~/ggen-marketplace/docs/explanation/ash-a2a-prd-ard.md`
  §3.3), `DSL valid ⇏ Capability valid`: a transformer persists the compiled
  skill list as a canonical IR, and `Validator.validate/1` is the
  hand-written business check a generated `Spark.Dsl.Verifier` delegates to
  -- mirroring `AshR2RML.Resource.Verify` delegating to
  `AshR2RML.Mapping.validate/1`
  (`~/ash_r2rml/lib/ash_r2rml/resource.ex:492-511`,
  `~/ash_r2rml/lib/ash_r2rml/mapping.ex:243-253`).

  ## Known drift: vendored `:a2a` 0.2.0 struct vs. the current a2a.proto spec

  `AgentCardBuilder.build_agent_card/2` populates every field the *vendored*
  `:a2a` 0.2.0 dependency's `A2A.AgentCard` struct defines
  (`~/xaas/deps/a2a/lib/a2a/agent_card.ex:16-76`). That struct has drifted
  from the current proto spec at `/Users/sac/A2A/specification/a2a.proto`,
  and this library cannot fix that drift -- fixing it means changing the
  `:a2a` dependency itself, which is out of scope for `ash_a2a`. What
  follows is an explicit inventory of what `AgentCardBuilder` does and does
  not populate, so a future proto-conformance pass on `:a2a` has a starting
  checklist instead of a silent gap:

    * `url` -- `A2A.AgentCard.t()` still declares `url` as an `@enforce_keys`
      required field (`agent_card.ex:59-65`) and `AgentCardBuilder` always
      supplies one (defaults to `"http://localhost:4000"`). The current
      proto marks the analogous field differently (absent/reserved per the
      prior drift-finding pass) -- `ash_a2a` cannot stop requiring `url`
      without the vendored struct changing first.
    * `security` -- populated as the bare `[%{String.t() => [String.t()]}]`
      list shape the vendored struct declares (`agent_card.ex:52`,
      `security: []` default), not the proto's typed `security_requirements`
      message. There is no typed `SecurityRequirement` struct to build
      against because `:a2a` doesn't define one.
    * `signatures` -- **not populated, and cannot be**: `A2A.AgentCard.t()`
      has no `signatures` field at all (`agent_card.ex:41-76` enumerates
      every field the struct supports; there is no `:signatures` key in the
      `@type t` or in `defstruct`). Adding it here would mean either patching
      the vendored dependency or fabricating a field the wire struct silently
      drops -- both out of scope.
    * `supported_interfaces` -- populated as `[]` by the struct's own
      default (`agent_card.ex:73`) since `AgentCardBuilder` never sets it
      explicitly; the proto marks this field `[REQUIRED]` but the vendored
      struct does not enforce it (`@enforce_keys` above excludes it), so
      nothing in this library would catch a caller who never supplies real
      interfaces.

  See `AshA2A.CapabilityIndexAgentCardShapeTest`
  (`test/ash_a2a/capability_index_agent_card_shape_test.exs`) for a real,
  compiled-struct test that pins the current `A2A.AgentCard` field set this
  library depends on -- a `:a2a` dependency bump that adds/removes/renames a
  field (e.g. finally adding `signatures`, or making `url` optional) fails
  that test loudly instead of this library silently building a
  proto-nonconformant card.
  """

  # `AshA2A.Skill.t/0` (skill.ex:15-21), not a bare map -- every real skill in
  # the persisted capability index is always an `%AshA2A.Skill{}` struct
  # (`AshA2A.Transformers.BuildCapabilityIndex.transform/1` persists compiled
  # `AshA2A.Skill` DSL entities verbatim, never plain maps). Declaring this as
  # a structless map previously made every `%AshA2A.Skill{...}` pattern match
  # against a `skill()`-typed value a real Dialyzer `pattern_match` finding
  # (dialyzer sees the callee's success type as a plain, unstructed map and
  # can prove a `%AshA2A.Skill{}` struct pattern -- which requires a
  # `__struct__ => AshA2A.Skill` key no plain map type carries -- can never
  # match it), even though every real call site does exactly that (e.g.
  # `AshA2A.Agent.default_skill_name/1`, `AshA2A.Info.skill/2`).
  @type skill :: AshA2A.Skill.t()
  @type refusal :: %{code: atom(), detail: String.t()}

  @doc """
  Builds a real `A2A.AgentCard.t()` from the persisted, verified capability
  index. Delegates to `AshA2A.CapabilityIndex.AgentCardBuilder.build_agent_card/2`
  -- see that module for the full option list and rationale.

  ## Examples

      iex> skills = AshA2A.Info.capability_index(AshA2A.Test.Fixture.Echo)
      iex> card = AshA2A.CapabilityIndex.build_agent_card(skills, name: "echo_agent")
      iex> {card.name, card.version, card.url}
      {"echo_agent", "0.1.0", "http://localhost:4000"}
      iex> [%{id: "echo", name: "echo"}] = card.skills
      iex> card.skills
      [%{id: "echo", name: "echo", description: "read action :read on AshA2A.Test.Fixture.Echo (no arguments)", tags: ["read"]}]

      iex> AshA2A.CapabilityIndex.build_agent_card([]).description
      "Ash-backed A2A agent exposing 0 skill(s)."

  """
  @spec build_agent_card([skill()], keyword()) :: A2A.AgentCard.t()
  defdelegate build_agent_card(skills, opts \\ []), to: AshA2A.CapabilityIndex.AgentCardBuilder

  @doc """
  Fail-closed validation of a compiled capability index. Delegates to
  `AshA2A.CapabilityIndex.Validator.validate/1` -- see that module for the
  full check list.

  ## Examples

      iex> skills = AshA2A.Info.capability_index(AshA2A.Test.Fixture.Echo)
      iex> AshA2A.CapabilityIndex.validate(skills)
      :ok

      iex> bad = %{name: :bogus, resource: AshA2A.Test.Fixture.Echo, action: :not_real, arguments: []}
      iex> {:error, [refusal]} = AshA2A.CapabilityIndex.validate([bad])
      iex> refusal.code
      :REFUSED_ACTION_NOT_FOUND

      iex> dup = %{name: :dup, resource: AshA2A.Test.Fixture.Echo, action: :read, arguments: []}
      iex> {:error, [refusal]} = AshA2A.CapabilityIndex.validate([dup, dup])
      iex> refusal.code
      :REFUSED_DUPLICATE_SKILL_NAME

  """
  @spec validate([skill()]) :: :ok | {:error, [refusal()]}
  defdelegate validate(skills), to: AshA2A.CapabilityIndex.Validator
end
