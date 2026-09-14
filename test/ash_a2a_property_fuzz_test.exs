defmodule AshA2A.PropertyFuzzTest do
  @moduledoc """
  Real property/fuzz coverage (Squad H, security DO re-census + property
  fuzz, agents 36-37) using the real `StreamData` dependency (a required,
  unrestricted transitive dep of `:ash` itself -- `deps/ash/mix.exs` declares
  `{:stream_data, "~> 1.0"}` with no `:only`, confirmed in `mix.lock`;
  promoted to an explicit direct dep in this repo's own `mix.exs` so this
  file's dependency is declared, not incidental).

  No test double anywhere in this file -- every property below exercises a
  real collaborator directly (`AshA2A.Command`, `AshA2A.Identity`,
  `AshA2A.Authority`, `AshA2A.Info`, and the already-compiled real
  `Ash.Resource`/`AshA2A` fixtures in `test/support/fixture.ex`) and asserts
  on real returned state -- never on "was this called."

  ## Coverage

    1. `AshA2A.Command.fingerprint/1` is deterministic (identical semantic
       command content -> identical real SHA-256 fingerprint, independent of
       the transport-only `command_id`/`submitted_at` fields that vary on
       every real retry) and injective enough in practice (a real generated
       sample of distinct semantic command content never collides).
    2. `AshA2A.Skill.consequence` classification is stable across repeated
       real recompilation. `AshA2A.Info.skill/2` -> `AshA2A.Info
       .capability_index/1` -> `AshA2A.CapabilityIndex.Compiler.compile/3`
       is **not** memoized (confirmed by reading `lib/ash_a2a/info.ex`'s own
       moduledoc and `capability_index_result/1`, which calls `Compiler
       .compile/3` fresh on every single call, re-walking
       `Ash.Resource.Info.public_actions/1` each time) -- so calling
       `AshA2A.Info.skill/2` N times against a real, already-Spark-DSL
       -compiled fixture resource genuinely re-runs the real capability
       -index recompilation N times, for real, no mock of the compiler or
       of Ash introspection anywhere.
    3. `AshA2A.Identity.new/2` real-normalizes a wide, generated range of
       binary (including Unicode, whitespace-only, empty-string, and
       very-long-string)/atom/integer values for every genuinely valid kind
       without ever raising, and raises for real (`ArgumentError`) for an
       invalid kind regardless of how well-formed the value is.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshA2A.{Authority, Command, Identity, Info}

  # -- 1. AshA2A.Command.fingerprint/1 -------------------------------------

  # Real, varied string content -- alphanumeric plus real Unicode -- used to
  # build the machine-identity values (`agent_id`/`principal_id`/`task_id`)
  # and `capability_id` that feed `Command.fingerprint/1`.
  defp id_value_gen do
    one_of([
      string(:alphanumeric, min_length: 1, max_length: 24),
      string(:utf8, min_length: 1, max_length: 24)
    ])
  end

  defp command_input_gen do
    map_of(
      string(:alphanumeric, min_length: 1, max_length: 8),
      one_of([
        integer(),
        boolean(),
        string(:alphanumeric, max_length: 16)
      ]),
      max_length: 5
    )
  end

  # The full real set of fields `Command.fingerprint/1` actually hashes
  # (`agent_id`, `principal_id`, `task_id`, `capability_id`, `input`, and
  # whether real `Authority` evidence is attached) -- deliberately excludes
  # `command_id`/`submitted_at`/`metadata`, which `fingerprint/1` never reads
  # (`lib/ash_a2a/command.ex`'s own moduledoc: "retries may carry a fresh
  # transport timestamp while still proving they are the same command
  # intent").
  defp command_fields_gen do
    fixed_map(%{
      agent_id: id_value_gen(),
      principal_id: id_value_gen(),
      task_id: one_of([constant(nil), id_value_gen()]),
      capability_id: string(:alphanumeric, min_length: 1, max_length: 24),
      input: command_input_gen(),
      with_authority?: boolean()
    })
  end

  # Builds a real `%AshA2A.Command{}` from generated semantic fields via the
  # real `Command.new/2` constructor -- `command_id`/`submitted_at` are left
  # to their real defaults (`Ash.UUIDv7.generate()` / `DateTime.utc_now()`),
  # so two commands built from identical `fields` are still two genuinely
  # distinct transport-level commands (different `command_id`, different
  # real wall-clock `submitted_at`).
  defp build_command(fields) do
    authority =
      if fields.with_authority? do
        Authority.from_verified_identity(fields.principal_id, fields.capability_id)
      end

    Command.new(fields.capability_id,
      agent_id: fields.agent_id,
      principal_id: fields.principal_id,
      task_id: fields.task_id,
      input: fields.input,
      authority: authority
    )
  end

  property "Command.fingerprint/1 is deterministic: identical real semantic content " <>
             "produces the identical real fingerprint across independently-built commands" do
    check all(fields <- command_fields_gen(), max_runs: 100) do
      command_a = build_command(fields)
      command_b = build_command(fields)

      # Real, live transport identity genuinely differs between the two
      # real command structs built one after another (different real
      # `Ash.UUIDv7.generate()` calls) -- proving the equal fingerprint
      # below is not just "we built the exact same struct twice."
      assert command_a.command_id != command_b.command_id

      assert command_a.fingerprint == command_b.fingerprint
      # `fingerprint/1` is a pure real function of the struct -- recomputing
      # it directly must agree with what `Command.new/2` already stored.
      assert command_a.fingerprint == Command.fingerprint(command_a)
      assert command_b.fingerprint == Command.fingerprint(command_b)
    end
  end

  property "Command.fingerprint/1 does not collide across a real generated sample " <>
             "of distinct semantic command content" do
    check all(
            fields_list <-
              list_of(command_fields_gen(), min_length: 15, max_length: 30)
              |> map(&Enum.uniq/1)
              |> filter(&(length(&1) >= 2)),
            max_runs: 30
          ) do
      fingerprints =
        fields_list
        |> Enum.map(&build_command/1)
        |> Enum.map(& &1.fingerprint)

      assert length(Enum.uniq(fingerprints)) == length(fingerprints)
    end
  end

  # -- 2. AshA2A.Skill.consequence stability under real recompilation ------

  # Real, already-Spark-DSL-compiled fixtures from `test/support/fixture.ex`
  # (loaded automatically for the `:test` env), covering every real Ash
  # action type `AshA2A.CapabilityIndex.Compiler.default_consequence/1`
  # branches on, plus one explicit `consequence:` override on a generic
  # `:action` (`Item`'s `:ping` skill) -- real DSL-authored capability
  # truth, not a hand-built `%AshA2A.Skill{}` literal.
  @fixture_probes [
    # {resource, skill_selector, expected_real_consequence}
    {AshA2A.Test.Fixture.Echo, :echo, :observe},
    {AshA2A.Test.Fixture.Widget, :inspect, :observe},
    {AshA2A.Test.Fixture.Item, :create_item, :change},
    {AshA2A.Test.Fixture.Item, :update_item, :change},
    {AshA2A.Test.Fixture.Item, :destroy_item, :change},
    {AshA2A.Test.Fixture.Item, :ping, :observe},
    {AshA2A.Test.Fixture.TenantedItem, :create_tenanted_item, :change},
    {AshA2A.Test.Fixture.TenantedItem, :update_tenanted_item, :change},
    {AshA2A.Test.Fixture.TenantedItem, :destroy_tenanted_item, :change}
  ]

  property "Skill.consequence classification is stable across N real, independent " <>
             "recompilations of the capability index, for varied real action-type combinations" do
    check all(
            {resource, skill_selector, expected} <- member_of(@fixture_probes),
            recompile_count <- integer(2..6),
            max_runs: 60
          ) do
      # Every one of these `Info.skill/2` calls independently re-derives the
      # capability index for real via `AshA2A.CapabilityIndex.Compiler
      # .compile/3` -> `Ash.Resource.Info.public_actions/1` -- confirmed
      # unmemoized by reading `AshA2A.Info.capability_index_result/1`
      # (`lib/ash_a2a/info.ex`) -- so this loop genuinely recompiles the
      # index `recompile_count` real times, not once with a cached reread.
      observed =
        for _ <- 1..recompile_count do
          assert {:ok, skill} = Info.skill(resource, skill_selector)
          skill.consequence
        end

      assert Enum.uniq(observed) == [expected]
    end
  end

  # -- 3. AshA2A.Identity.new/2 ---------------------------------------------

  @valid_kinds [:principal, :agent, :task, :command, :execution, :runtime]

  # Real Unicode, whitespace-only, empty-string, and very-long-string binary
  # shapes, plus real atoms and real integers -- the exact "binary/atom/
  # integer/malformed (Unicode, whitespace, empty-string, very long string)"
  # coverage this unit's task calls for.
  defp identity_value_gen do
    one_of([
      # Ordinary + Unicode text, including the empty string.
      string(:utf8, min_length: 0, max_length: 40),
      # Whitespace-heavy / whitespace-only strings.
      string([?\s, ?\t, ?\n, ?a..?z], min_length: 1, max_length: 30),
      # Very long strings.
      string(:alphanumeric, min_length: 2_000, max_length: 4_000),
      atom(:alphanumeric),
      integer()
    ])
  end

  defp expected_identity_normalization(value) when is_binary(value), do: value
  defp expected_identity_normalization(value) when is_atom(value), do: Atom.to_string(value)
  defp expected_identity_normalization(value) when is_integer(value), do: Integer.to_string(value)

  property "Identity.new/2 real-normalizes every generated binary/atom/integer value " <>
             "without ever raising, for every genuinely valid kind" do
    check all(kind <- member_of(@valid_kinds), value <- identity_value_gen(), max_runs: 200) do
      identity = Identity.new(kind, value)

      assert %Identity{kind: ^kind, value: normalized} = identity
      assert is_binary(normalized)
      assert normalized == expected_identity_normalization(value)

      # `external/1` is the other real, total function every real command/
      # authority fingerprint path routes identities through -- must never
      # raise for a real identity this constructor just admitted.
      assert Identity.external(identity) == "#{kind}:#{normalized}"
    end
  end

  # Every atom that is not one of the six real declared kinds -- StreamData's
  # own random alphanumeric atom generator, filtered against the real
  # `@valid_kinds` list above (not a hand-picked example list), so the
  # invalid-kind space is itself generated, not enumerated.
  defp invalid_kind_gen do
    atom(:alphanumeric)
    |> filter(&(&1 not in @valid_kinds))
  end

  property "Identity.new/2 raises for real (ArgumentError) for an invalid kind, " <>
             "even with an otherwise well-formed real value" do
    check all(kind <- invalid_kind_gen(), value <- identity_value_gen(), max_runs: 100) do
      assert_raise ArgumentError, fn -> Identity.new(kind, value) end
    end
  end

  property "Identity.new/2 raises for real (ArgumentError) for a nil value, " <>
             "even for a genuinely valid kind" do
    check all(kind <- member_of(@valid_kinds), max_runs: 20) do
      assert_raise ArgumentError, fn -> Identity.new(kind, nil) end
    end
  end
end
