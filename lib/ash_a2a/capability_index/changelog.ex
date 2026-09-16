defmodule AshA2A.CapabilityIndex.Changelog do
  @moduledoc """
  Diffs two real capability-id sets and produces a receipted changelog entry.

  Closes a real, disclosed, still-open gap in the "knowledge routing" lens:
  a compiled `AshA2A.CapabilityIndex.Compiler` output
  (`AshA2A.Info.capability_index/1`) simply IS whatever the current code
  declares, with no record of WHEN or WHY a capability was added or removed.
  This module does not decide WHO authorizes a capability-set change (a
  real, genuinely hard governance question, correctly left open) -- it makes
  CHANGES to the closed set auditable: given two real capability-id sets (an
  "old" and "new" index, e.g. `AshA2A.Info.capability_index/1` output
  compiled at two different git revisions, or from two different
  resource/domain module versions), it computes a precise added/removed/
  unchanged diff and a deterministic content fingerprint.

  The fingerprinting approach mirrors this codebase's own established
  pattern, `AshA2A.Command.fingerprint/1`
  (`lib/ash_a2a/command.ex`): a `:crypto.hash(:sha256, ...)` of
  `:erlang.term_to_binary/1` over sorted, order-independent content, encoded
  as lowercase hex. Just as `Command.fingerprint/1` is derived only from
  semantic command content (so a transport retry with a fresh `command_id`
  still fingerprints identically), this changelog entry's fingerprint is
  derived only from the sorted `added`/`removed`/`unchanged` id lists -- the
  order the caller happened to enumerate either input set in never changes
  the result.

  This is a standalone utility module, NOT wired into compilation or
  `AshA2A.CommandBus` admission -- that would be a bigger, riskier change.
  It is a tool a host or CI pipeline can run to produce a real, auditable
  record of capability-set changes between two points in time, closing the
  "changes are untracked" gap without claiming to solve "who authorized this
  change."
  """

  alias AshA2A.Skill

  @type capability_id :: String.t()

  @type t :: %__MODULE__{
          added: [capability_id()],
          removed: [capability_id()],
          unchanged: [capability_id()],
          fingerprint: String.t()
        }

  @enforce_keys [:added, :removed, :unchanged, :fingerprint]
  defstruct [:added, :removed, :unchanged, :fingerprint]

  @doc """
  Builds a receipted changelog entry from an "old" and "new" real
  capability-id set.

  Accepts any enumerable of capability id strings -- typically the real
  `id` field off compiled `AshA2A.Skill.t()` structs
  (`Enum.map(index, & &1.id)`, or see `build_from_indices/2` below), but any
  `Enumerable.t()` of ids works. Duplicate ids within one side collapse
  (set semantics, via `MapSet`); `added`, `removed`, and `unchanged` are
  each returned sorted, so two calls over the same real content supplied in
  a different enumeration order produce a byte-identical entry, fingerprint
  included.

    * `added` -- ids present in `new_ids` but not `old_ids`.
    * `removed` -- ids present in `old_ids` but not `new_ids`.
    * `unchanged` -- ids present in both.
  """
  @spec build(Enumerable.t(), Enumerable.t()) :: t()
  def build(old_ids, new_ids) do
    old_set = MapSet.new(old_ids)
    new_set = MapSet.new(new_ids)

    added = new_set |> MapSet.difference(old_set) |> Enum.sort()
    removed = old_set |> MapSet.difference(new_set) |> Enum.sort()
    unchanged = old_set |> MapSet.intersection(new_set) |> Enum.sort()

    entry = %__MODULE__{added: added, removed: removed, unchanged: unchanged, fingerprint: ""}

    %{entry | fingerprint: fingerprint(entry)}
  end

  @doc """
  Convenience entry point: builds a changelog entry directly from two real
  compiled capability indices (`[AshA2A.Skill.t()]`, e.g. two
  `AshA2A.Info.capability_index/1` results, or `AshA2A.Info.capability_index/1`
  called against two different resource/domain module compiles), extracting
  each skill's real `id` rather than requiring the caller to project ids
  first.
  """
  @spec build_from_indices([Skill.t()], [Skill.t()]) :: t()
  def build_from_indices(old_index, new_index)
      when is_list(old_index) and is_list(new_index) do
    build(Enum.map(old_index, & &1.id), Enum.map(new_index, & &1.id))
  end

  @doc """
  Recomputes the content fingerprint for an entry's real `added`/`removed`/
  `unchanged` lists -- mirrors `AshA2A.Command.fingerprint/1`'s pattern of
  taking the struct and hashing only its semantic content. Deterministic:
  two entries carrying the same real diff content (regardless of how each
  was independently built) fingerprint identically; any real change to
  which ids are added, removed, or unchanged changes the fingerprint.
  """
  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{added: added, removed: removed, unchanged: unchanged}) do
    {added, removed, unchanged}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
