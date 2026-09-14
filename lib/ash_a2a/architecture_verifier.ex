# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ArchitectureVerifier.Fixture.Resource do
  @moduledoc """
  Real, minimal `Ash.Resource` fixture private to `AshA2A.ArchitectureVerifier`.

  `test/support/fixture.ex`'s `AshA2A.Test.Fixture.Echo`/`Item` are the
  repo's usual real fixtures, but `mix.exs`'s `elixirc_paths(:test)` is the
  *only* environment that adds `"test/support"` to `elixirc_paths` --
  `elixirc_paths(_)` (the branch a plain `mix ash_a2a.verify_architecture`
  compiles under) is just `["lib"]`. Those fixtures are therefore genuinely
  unreachable from a plain mix task run outside `MIX_ENV=test`, so this
  module exists to give `mix ash_a2a.verify_architecture` its own real,
  always-compiled `Ash.Resource` to check against, instead of forcing the
  task to only work under a special `MIX_ENV`.

  One real `:create` default action (public actions default to consequence
  `:change` -- `AshA2A.CapabilityIndex.Compiler.default_consequence/1`) and
  one real generic `:action` with no `a2a do skill ..., consequence: ... end`
  override (public generic actions default to consequence `:unknown`) --
  exactly the two consequence classes `AshA2A.ArchitectureVerifier`'s checks
  need a real compiled resource for. No explicit `a2a do end` block is
  declared: `AshA2A.Dsl`'s own moduledoc ("Public Ash actions require no
  `skill` declaration") and `AshA2A.Transformers.BuildCapabilityIndex`
  (`Transformer.get_entities(dsl_state, [:a2a])` on an empty entity list,
  unconditionally persisting `:ash_a2a_skill_overrides`/`:ash_a2a_subject_kind`
  regardless) both confirm the section persists correctly with zero explicit
  skill entries -- both real actions are picked up automatically from
  `Ash.Resource.Info.public_actions/1`.
  """

  use Ash.Resource,
    domain: AshA2A.ArchitectureVerifier.Fixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:create])

    action :probe, :string do
      run(fn _input, _context -> {:ok, "probed"} end)
    end
  end
end

defmodule AshA2A.ArchitectureVerifier.Fixture.Domain do
  @moduledoc """
  Real fixture domain for `AshA2A.ArchitectureVerifier.Fixture.Resource`
  above, mirroring `test/support/fixture.ex`'s existing
  resource-then-domain-second declaration order (the resource references this
  domain module's atom before it is defined; this domain then references the
  resource's atom -- proven to compile in this same codebase already).
  """

  # `validate_config_inclusion?: false` -- this fixture domain is a small,
  # always-compiled (`lib/`, every Mix env) internal collaborator for
  # `AshA2A.ArchitectureVerifier`'s checks, not a real application domain a
  # host app is expected to register in `config :ash_a2a, ash_domains: [...]`
  # (that config, per `config/test.exs`, only lists the real, test-only
  # `AshA2A.Test.Fixture.Domain`). Without this, `mix compile
  # --warnings-as-errors` fails in the default `:dev` Mix env (the env this
  # repo's own `.github/workflows` CI job actually runs that command under --
  # `elixirc_paths(:dev)` is just `["lib"]`, so this domain compiles there
  # while `ash_domains` config does not, unlike in `:test`).
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.ArchitectureVerifier.Fixture.Resource)
  end
end

defmodule AshA2A.ArchitectureVerifier do
  @moduledoc """
  Real, executable architecture-invariant checks for `mix
  ash_a2a.verify_architecture` (`lib/mix/tasks/ash_a2a.verify_architecture.ex`).

  Every check below calls the real, current, unmodified public API
  (`AshA2A.Info`, `AshA2A.Command`, `AshA2A.CommandBus`) against either the
  real compiled `AshA2A.ArchitectureVerifier.Fixture.Resource` above or a
  hand-built `AshA2A.Command` -- never a hand-asserted description of
  expected behavior, never a mock/stub standing in for any of these
  collaborators. `checks/0` returns a plain list of result maps; nothing in
  this module prints to stdout or halts the VM -- that I/O belongs to
  `Mix.Tasks.AshA2a.VerifyArchitecture` alone, so this module stays a plain
  function directly callable (and directly asserted against) from
  `test/ash_a2a_architecture_verifier_test.exs`.
  """

  alias AshA2A.{Command, CommandBus, Info}
  alias AshA2A.ArchitectureVerifier.Fixture.Resource

  @type result :: %{name: String.t(), status: :pass | :fail, detail: String.t()}

  @doc "Runs every real architecture check and returns their results, most-important first."
  @spec checks() :: [result()]
  def checks do
    [
      check_capability_index_derivable(),
      check_unknown_consequence_refused(),
      check_change_requires_authority(),
      check_fingerprint_invariants()
    ]
  end

  # -- Check 1: AshA2A.Info.capability_index/1 derives real capability truth --

  @doc """
  Real check: `AshA2A.Info.capability_index/1` returns a non-nil list for a
  real compiled resource -- capability truth is derivable from Ash
  introspection alone, per `AshA2A.Info`'s own moduledoc, with no separate
  hand-maintained capability model to drift out of sync.
  """
  @spec check_capability_index_derivable() :: result()
  def check_capability_index_derivable do
    name = "AshA2A.Info.capability_index/1 derives a real, non-nil capability index"

    case Info.capability_index(Resource) do
      index when is_list(index) and index != [] ->
        pass(
          name,
          "capability_index/1 returned #{length(index)} real compiled skill(s): " <>
            Enum.map_join(index, ", ", &"#{&1.id} (consequence: #{inspect(&1.consequence)})")
        )

      other ->
        fail(name, "expected a non-empty list, got #{inspect(other)}")
    end
  end

  # -- Check 2: an :unknown-consequence skill is refused before dispatch --

  @doc """
  Real check: a skill whose real, compiled `consequence` is `:unknown` (a
  generic `:action` with no explicit `consequence:` override -- see
  `AshA2A.Skill`'s moduledoc and
  `AshA2A.CapabilityIndex.Compiler.default_consequence/1`) is refused by
  `AshA2A.CommandBus.run/4` with the typed `:consequence_unclassified` code,
  never silently dispatched.
  """
  @spec check_unknown_consequence_refused() :: result()
  def check_unknown_consequence_refused do
    name =
      "an :unknown-consequence skill is real-refused by CommandBus (:consequence_unclassified)"

    with {:ok, skill} <- find_skill(:probe),
         :unknown <- skill.consequence do
      command =
        Command.new(skill.id,
          command_id: "verify-architecture-unknown-#{unique()}",
          agent_id: "verify-architecture",
          principal_id: "verify-architecture-principal",
          input: %{}
        )

      case CommandBus.run(command, probe_message(), Resource) do
        {:error, %{code: :consequence_unclassified}} ->
          pass(
            name,
            "CommandBus.run/4 refused capability #{skill.id} (real compiled consequence: :unknown) " <>
              "with {:error, %{code: :consequence_unclassified}}"
          )

        other ->
          fail(
            name,
            "expected {:error, %{code: :consequence_unclassified}}, got #{inspect(other)}"
          )
      end
    else
      {:error, reason} ->
        fail(name, "could not locate the :probe fixture skill: #{inspect(reason)}")

      other ->
        fail(
          name,
          "expected the :probe fixture skill's real consequence to be :unknown, got #{inspect(other)}"
        )
    end
  end

  # -- Check 3: a :change-consequence skill with no Authority is refused --

  @doc """
  Real check: a skill whose real, compiled `consequence` is `:change` (the
  default for a `:create`/`:update`/`:destroy` action) is refused by
  `AshA2A.CommandBus.run/4` with the typed `:authority_required` code when
  the `AshA2A.Command` carries no `AshA2A.Authority` -- `CommandBus.admit/2`'s
  fail-closed default for `:change`/`:external_do` consequences.
  """
  @spec check_change_requires_authority() :: result()
  def check_change_requires_authority do
    name =
      "a :change-consequence skill with no Authority is real-refused by CommandBus (:authority_required)"

    with {:ok, skill} <- find_skill(:create),
         :change <- skill.consequence do
      command =
        Command.new(skill.id,
          command_id: "verify-architecture-change-#{unique()}",
          agent_id: "verify-architecture",
          principal_id: "verify-architecture-principal",
          # deliberately no `authority:` -- this is the real fail-closed path
          input: %{}
        )

      case CommandBus.run(command, probe_message(), Resource) do
        {:error, %{code: :authority_required}} ->
          pass(
            name,
            "CommandBus.run/4 refused capability #{skill.id} (real compiled consequence: :change, " <>
              "no Authority) with {:error, %{code: :authority_required}}"
          )

        other ->
          fail(name, "expected {:error, %{code: :authority_required}}, got #{inspect(other)}")
      end
    else
      {:error, reason} ->
        fail(name, "could not locate the :create fixture skill: #{inspect(reason)}")

      other ->
        fail(
          name,
          "expected the :create fixture skill's real consequence to be :change, got #{inspect(other)}"
        )
    end
  end

  # -- Check 4: Command.fingerprint/1 is the real replay/conflict invariant --

  @doc """
  Real check: two independently-built `AshA2A.Command` structs with the same
  `command_id` and the same semantic content (`agent_id`/`principal_id`/
  `capability_id`/`input`/authority token) produce the same real
  `Command.fingerprint/1` value (the replay-safety invariant
  `AshA2A.ReceiptStore.Memory.handle_call/3`'s `{:claim, ...}` clause relies
  on to detect a genuine retry), while the same `command_id` with different
  `input` produces a different fingerprint (the conflict-safety invariant
  that same clause relies on to refuse `:command_conflict`).
  """
  @spec check_fingerprint_invariants() :: result()
  def check_fingerprint_invariants do
    name = "Command.fingerprint/1 is stable for identical content, distinct for changed input"

    shared_opts = [
      command_id: "verify-architecture-fingerprint-1",
      agent_id: "verify-architecture",
      principal_id: "verify-architecture-principal"
    ]

    same_a = Command.new("verify.capability", Keyword.put(shared_opts, :input, %{label: "a"}))
    same_b = Command.new("verify.capability", Keyword.put(shared_opts, :input, %{label: "a"}))
    different = Command.new("verify.capability", Keyword.put(shared_opts, :input, %{label: "b"}))

    cond do
      same_a.command_id != same_b.command_id or same_a.command_id != different.command_id ->
        fail(
          name,
          "test setup error: command_id was not actually held constant across the three commands"
        )

      same_a.fingerprint != same_b.fingerprint ->
        fail(
          name,
          "same command_id + identical semantic content produced DIFFERENT fingerprints: " <>
            "#{same_a.fingerprint} != #{same_b.fingerprint}"
        )

      same_a.fingerprint == different.fingerprint ->
        fail(
          name,
          "same command_id + different input produced the SAME fingerprint (#{same_a.fingerprint}) -- " <>
            "a real conflict would go undetected"
        )

      true ->
        pass(
          name,
          "identical content: #{same_a.fingerprint} == #{same_b.fingerprint}; " <>
            "changed input: #{same_a.fingerprint} != #{different.fingerprint}"
        )
    end
  end

  # -- shared helpers --

  defp find_skill(action_name) do
    Resource
    |> Info.capability_index()
    |> List.wrap()
    |> Enum.find(&(&1.action == action_name))
    |> case do
      nil -> {:error, {:no_such_skill, action_name}}
      skill -> {:ok, skill}
    end
  end

  defp probe_message, do: A2A.Message.new_user([A2A.Part.Data.new(%{})])

  defp unique, do: System.unique_integer([:positive, :monotonic])

  defp pass(name, detail), do: %{name: name, status: :pass, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}
end
