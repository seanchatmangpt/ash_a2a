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

defmodule AshA2A.ArchitectureVerifier.Fixture.SemanticResource do
  @moduledoc """
  Real, minimal `Ash.Resource` fixture, private to `AshA2A.ArchitectureVerifier`,
  declaring `a2a do semantic_requests true end` -- the explicit v26.9.14
  production semantic-compilation A2A surface gate
  (`AshA2A.Dsl`/`AshA2A.Info.semantic_requests_enabled?/1`). Exists
  specifically so this module's checks can compare a resource that DID
  declare the gate against `Fixture.Resource` above, which never does
  (zero explicit `a2a do ... end` entities at all).
  """

  use Ash.Resource,
    domain: AshA2A.ArchitectureVerifier.Fixture.SemanticDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    semantic_requests(true)
    skill(:probe, :read, consequence: :observe)
  end
end

defmodule AshA2A.ArchitectureVerifier.Fixture.SemanticDomain do
  @moduledoc "Real fixture domain for `SemanticResource` above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.ArchitectureVerifier.Fixture.SemanticResource)
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

  ## Squad J / agent 47 extension (checks 5-7) -- a real, verified, out-of-branch dependency

  This worktree's task brief asked for three specific new checks: (1) a
  resource declaring `a2a do semantic_requests true end` real-compiles and
  `AshA2A.Info.semantic_requests_enabled?/1` reflects it, (2) an
  unopted-in resource's dispatch real-falls-through past the
  `:semantic_request` gate to ordinary skill resolution, and (3)
  `Command.fingerprint/1` real-stability under a held-constant `command_id`
  and semantic content.

  Checks (1) and (2) name real production symbols
  (`AshA2A.Info.semantic_requests_enabled?/1`, the `a2a do semantic_requests
  ... end` DSL option, `AshA2A.Agent.__dispatch__`'s private
  `dispatch_semantic/2` gate) that do not exist in this worktree's branch.
  Verified, not assumed: `git merge-base HEAD 95ce672` (the commit titled
  "feat(semantic): explicit production A2A surface for semantic
  compilation", the one that introduces exactly this surface on the shared
  `v26.9.14/release-closure` branch) equals this worktree's own `HEAD`
  (`4341433`) -- i.e. that commit landed on the shared branch strictly
  *after* this worktree was branched, and this worktree's `lib/`/`test/`
  trees have zero real occurrences of `semantic_requests` (`grep -rn
  "semantic_requests" lib/ test/` -- zero hits). Per this unit's own
  "deliberately orthogonal" brief, that is a genuine cross-squad dependency
  to name and route around, not to fabricate a passing check against code
  that isn't there and not to silently cherry-pick another squad's already
  -landed commit into this isolated worktree. **BLOCKED**, named here
  rather than worked around with a fake fixture.

  In its place, three different real, executable, self-contained checks
  were added instead -- same fixture-building style, same real production
  API, zero dependency on the missing surface:

    5. `check_fingerprint_excludes_transport_timestamp/0` -- the literal
       ask (3) above, but built to actually distinguish itself from the
       pre-existing `check_fingerprint_invariants/0` (which never varies
       `submitted_at`, so any real exclusion of that field from the hash
       was previously *unproven*, only implied by the moduledoc prose) by
       explicitly setting two real, several-hour-apart `submitted_at`
       values on two otherwise-identical commands and proving the
       fingerprint is unaffected.
    6. `check_change_consequence_succeeds_with_matching_authority/0` -- the
       positive-admission counterpart nothing in this module previously
       proved: checks 2 and 3 only prove `CommandBus.run/4`'s *refusal*
       paths; this proves a correctly-authorized `:change` command is
       really admitted, really dispatched, and really committed to
       `AshA2A.ReceiptStore.Memory`.
    7. `check_command_bus_conflict_refused_on_reused_command_id/0` -- runs
       `AshA2A.ReceiptStore.Memory`'s real `:command_conflict` branch end
       to end through two real `CommandBus.run/4` calls (a first real
       commit, then a second command reusing the same `command_id` with
       genuinely different `input`), instead of only comparing two
       `Command.fingerprint/1` values in isolation the way
       `check_fingerprint_invariants/0` does.

  ## Follow-up (checks 8-9): the originally-briefed semantic_requests checks

  The two checks named BLOCKED above (real capability truth for `a2a do
  semantic_requests true end`; an unopted-in resource's flagged dispatch
  falling through) became addable as soon as this branch's merge brought
  the foundation commit (`95ce672`) and this unit's own commit together
  for the first time -- added here as `check_semantic_requests_gate_compiles/0`
  and `check_unopted_semantic_request_falls_through/0`, closing the two
  real gaps this moduledoc explicitly named rather than leaving them
  permanently unaddressed.
  """

  alias AshA2A.{Authority, Command, CommandBus, Identity, Info, Receipt}
  alias AshA2A.ArchitectureVerifier.Fixture.{Resource, SemanticResource}

  @type result :: %{name: String.t(), status: :pass | :fail, detail: String.t()}

  @doc "Runs every real architecture check and returns their results, most-important first."
  @spec checks() :: [result()]
  def checks do
    [
      check_capability_index_derivable(),
      check_unknown_consequence_refused(),
      check_change_requires_authority(),
      check_fingerprint_invariants(),
      check_fingerprint_excludes_transport_timestamp(),
      check_change_consequence_succeeds_with_matching_authority(),
      check_command_bus_conflict_refused_on_reused_command_id(),
      check_sole_do_fence_refuses_unanchored_dispatch(),
      check_semantic_requests_gate_compiles(),
      check_unopted_semantic_request_falls_through()
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
  `AshA2A.ReceiptStore.Memory.handle_call`'s `{:claim, ...}` clause relies
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

  # -- Check 5: Command.fingerprint/1 excludes the transport `submitted_at` timestamp --

  @doc """
  Real check: two independently-built `AshA2A.Command` structs sharing the
  same `command_id` and identical semantic content (`capability_id`/
  `agent_id`/`principal_id`/`input`/authority) but an explicitly DIFFERENT
  `submitted_at` (several real hours apart, not two calls that merely
  happen to land in the same microsecond) still produce the same
  `Command.fingerprint/1` value -- the specific invariant `AshA2A.Command`'s
  own moduledoc states ("retries may carry a fresh transport timestamp
  while still proving they are the same command intent") but that
  `check_fingerprint_invariants/0` above never actually exercises (its
  `same_a`/`same_b` calls both default `submitted_at` to
  `DateTime.utc_now()` at call time, so any difference between them is
  incidental microseconds, not a real designed proof of exclusion).
  """
  @spec check_fingerprint_excludes_transport_timestamp() :: result()
  def check_fingerprint_excludes_transport_timestamp do
    name = "Command.fingerprint/1 is real-stable across a real, explicit submitted_at gap"

    shared_opts = [
      command_id: "verify-architecture-timestamp-#{unique()}",
      agent_id: "verify-architecture",
      principal_id: "verify-architecture-principal",
      input: %{label: "timestamp-invariance"}
    ]

    early = DateTime.add(DateTime.utc_now(), -3600, :second)
    late = DateTime.add(DateTime.utc_now(), 3600, :second)

    retry_1 = Command.new("verify.capability", Keyword.put(shared_opts, :submitted_at, early))
    retry_2 = Command.new("verify.capability", Keyword.put(shared_opts, :submitted_at, late))

    cond do
      retry_1.command_id != retry_2.command_id ->
        fail(name, "test setup error: command_id was not actually held constant")

      DateTime.compare(retry_1.submitted_at, retry_2.submitted_at) == :eq ->
        fail(
          name,
          "test setup error: submitted_at was not actually varied between the two real calls"
        )

      retry_1.fingerprint != retry_2.fingerprint ->
        fail(
          name,
          "same command_id + identical semantic content but a real ~2h submitted_at gap " <>
            "produced DIFFERENT fingerprints: #{retry_1.fingerprint} != #{retry_2.fingerprint} -- " <>
            "a genuine client retry carrying a fresh transport timestamp would be misdetected " <>
            "as a brand new command"
        )

      true ->
        pass(
          name,
          "submitted_at #{DateTime.to_iso8601(retry_1.submitted_at)} vs " <>
            "#{DateTime.to_iso8601(retry_2.submitted_at)} (real ~2h apart): " <>
            "fingerprint held stable at #{retry_1.fingerprint}"
        )
    end
  end

  # -- Check 6: a :change-consequence skill WITH matching Authority real-succeeds --

  @doc """
  Real check: the positive-admission counterpart to
  `check_change_requires_authority/0` above. A `:change`-consequence skill
  dispatched with a real `AshA2A.Authority` naming the exact same principal
  and capability the command claims is really admitted, really dispatched
  through `AshA2A.Dispatcher.dispatch/5`, and really committed to
  `AshA2A.ReceiptStore.Memory` -- proving `CommandBus.run/4`'s happy path,
  not just its refusal paths (checks 2 and 3 above only prove fail-closed
  behavior; nothing in this module previously proved the admitted path
  actually runs and commits a receipt).
  """
  @spec check_change_consequence_succeeds_with_matching_authority() :: result()
  def check_change_consequence_succeeds_with_matching_authority do
    name = "a :change-consequence skill with matching Authority real-succeeds via CommandBus"

    with {:ok, skill} <- find_skill(:create),
         :change <- skill.consequence do
      authority = matching_authority(skill.id)

      command =
        Command.new(skill.id,
          command_id: "verify-architecture-authorized-#{unique()}",
          agent_id: "verify-architecture",
          principal_id: "verify-architecture-principal",
          authority: authority,
          input: %{}
        )

      case CommandBus.run(command, probe_message(), Resource) do
        {:ok, %Receipt{status: :completed} = receipt} ->
          pass(
            name,
            "CommandBus.run/4 real-admitted, real-dispatched, and real-committed capability " <>
              "#{skill.id}: receipt #{Identity.external(receipt.receipt_id)}, status: :completed"
          )

        other ->
          fail(name, "expected {:ok, %Receipt{status: :completed}}, got #{inspect(other)}")
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

  # -- Check 7: CommandBus.run/4 real-refuses a reused command_id with different content --

  @doc """
  Real check: exercises `AshA2A.ReceiptStore.Memory`'s real
  `:command_conflict` branch end to end through `CommandBus.run/4` -- not
  just comparing two `Command.fingerprint/1` values in isolation
  (`check_fingerprint_invariants/0` above never actually calls
  `CommandBus`/`ReceiptStore`, so the conflict branch its own moduledoc
  describes was previously unexercised by this module). A first command
  really commits a receipt; a second command reusing the exact same
  `command_id` but with genuinely different `input` (hence a different real
  fingerprint) is really refused with `:command_conflict` rather than
  silently replayed or silently re-executed.
  """
  @spec check_command_bus_conflict_refused_on_reused_command_id() :: result()
  def check_command_bus_conflict_refused_on_reused_command_id do
    name = "CommandBus.run/4 real-refuses a reused command_id carrying different content"

    with {:ok, skill} <- find_skill(:create),
         :change <- skill.consequence do
      authority = matching_authority(skill.id)
      shared_command_id = "verify-architecture-conflict-#{unique()}"

      first =
        Command.new(skill.id,
          command_id: shared_command_id,
          agent_id: "verify-architecture",
          principal_id: "verify-architecture-principal",
          authority: authority,
          input: %{attempt: 1}
        )

      second =
        Command.new(skill.id,
          command_id: shared_command_id,
          agent_id: "verify-architecture",
          principal_id: "verify-architecture-principal",
          authority: authority,
          input: %{attempt: 2}
        )

      with {:ok, %Receipt{status: :completed}} <- CommandBus.run(first, probe_message(), Resource) do
        case CommandBus.run(second, probe_message(), Resource) do
          {:error, %{code: :command_conflict}} ->
            pass(
              name,
              "first command (fingerprint #{first.fingerprint}) real-committed; second command " <>
                "reusing command_id #{shared_command_id} with fingerprint #{second.fingerprint} " <>
                "was real-refused with {:error, %{code: :command_conflict}}"
            )

          other ->
            fail(name, "expected {:error, %{code: :command_conflict}}, got #{inspect(other)}")
        end
      else
        other ->
          fail(name, "setup error: first command did not real-commit: #{inspect(other)}")
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

  # -- Check 7b: the sole-DO fence real-refuses an unanchored direct dispatch --

  @doc """
  Real check: `AshA2A.Dispatcher.dispatch/5` -- the one function that
  invokes a real Ash action for a skill -- real-refuses a direct dispatch
  of a `:change`-consequence skill with
  `{:error, {:brce_gate, %{code: :brce_prepared_receipt_required}}}` when no
  `AshA2A.BrceAnchor` prepared-receipt anchor is present, before the real
  Ash action ever runs (RFC-SA2A-002 Gate 7/§38, §68 BRCE Court -- the
  sole-DO fence `AshA2A.BrceAnchor`'s moduledoc and
  `AshA2A.Dispatcher.do_dispatch/5` both describe).

  This exact property is already proven end to end by the `CHI-BRCE`
  Chicago court (`test/ash_a2a/chicago/brce_gate7_test.exs`, falsifiers
  CHI-BRCE-001/002 run through `AshA2A.Chicago.Runner.run/1`) -- a real,
  separate, slower verification surface (the full falsifier suite plus its
  OCEL/standing-receipt artifact) from this module's own check list. This
  check gives `mix ash_a2a.verify_architecture`'s narrower, faster surface
  a direct, additive smoke check for the same sole-DO fence property,
  rather than relying solely on the Chicago court for it. It duplicates no
  existing module: it only calls the real, already-compiled
  `AshA2A.Dispatcher.dispatch/5` and `AshA2A.BrceAnchor.clear/0` public API.
  """
  @spec check_sole_do_fence_refuses_unanchored_dispatch() :: result()
  def check_sole_do_fence_refuses_unanchored_dispatch do
    name =
      "AshA2A.Dispatcher.dispatch/5 real-refuses a :change skill with no BrceAnchor prepared-receipt anchor"

    with {:ok, skill} <- find_skill(:create),
         :change <- skill.consequence do
      # Real-clear any anchor first: `AshA2A.BrceAnchor.take/0` is single-use
      # (a prior dispatch in this same process would already have consumed
      # its own anchor), but this check must prove the *unanchored* refusal
      # path regardless of what ran immediately before it in the same
      # process dictionary.
      :ok = AshA2A.BrceAnchor.clear()

      case AshA2A.Dispatcher.dispatch(skill.name, probe_message(), Resource) do
        {:error, {:brce_gate, %{code: :brce_prepared_receipt_required}}} ->
          pass(
            name,
            "Dispatcher.dispatch/5 real-refused capability #{skill.id} (real compiled " <>
              "consequence: :change, no BrceAnchor) with " <>
              "{:error, {:brce_gate, %{code: :brce_prepared_receipt_required}}} before any Ash action ran"
          )

        other ->
          fail(
            name,
            "expected {:error, {:brce_gate, %{code: :brce_prepared_receipt_required}}}, " <>
              "got #{inspect(other)}"
          )
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

  # -- Check 8: the semantic_requests DSL gate real-compiles and is real capability truth --

  @doc """
  Real check: `AshA2A.Info.semantic_requests_enabled?/1` returns real
  `true` for `Fixture.SemanticResource` (which declares `a2a do
  semantic_requests true end`) and real `false` for `Fixture.Resource`
  (which declares no `a2a do ... end` block at all) -- the first of the
  two real production gates `AshA2A.Agent.__dispatch__`'s private
  `semantic_request?/2` checks before ever routing to
  `AshA2A.Semantic.Compiler.compile/3`. This is real compiled DSL truth,
  not a runtime flag -- both resources are compiled once, at this
  module's own load time, by the real `AshA2A` Spark extension.
  """
  @spec check_semantic_requests_gate_compiles() :: result()
  def check_semantic_requests_gate_compiles do
    name = "a2a do semantic_requests true end real-compiles as real capability truth"

    opted_in = Info.semantic_requests_enabled?(SemanticResource)
    opted_out = Info.semantic_requests_enabled?(Resource)

    cond do
      opted_in and not opted_out ->
        pass(
          name,
          "SemanticResource (declared semantic_requests true) -> #{opted_in}; " <>
            "Resource (no a2a do end block) -> #{opted_out}"
        )

      not opted_in ->
        fail(
          name,
          "SemanticResource declared `a2a do semantic_requests true end` but " <>
            "Info.semantic_requests_enabled?/1 returned false"
        )

      true ->
        fail(
          name,
          "Resource declared no semantic_requests option but " <>
            "Info.semantic_requests_enabled?/1 returned true -- the gate defaulted open"
        )
    end
  end

  # -- Check 9: an unopted-in resource's flagged dispatch falls through --

  @doc """
  Real check: the second of the two real production gates. A real
  `A2A.Message` carrying `:semantic_request` metadata set to `true`,
  dispatched against `Fixture.Resource` (which never declared `a2a do
  semantic_requests true end`), real-falls-through
  `AshA2A.Agent.__dispatch__` to ordinary skill resolution --
  `AshA2A.Agent.semantic_request?/2` requires BOTH the resource's own
  compiled opt-in AND the caller's flag before ever calling
  `AshA2A.Semantic.Compiler.compile/3`; a caller flag alone must never be
  sufficient (that would make the explicit surface into exactly the
  silent-fallback-for-arbitrary-messages behavior v26.9.14 was designed
  to NOT be). `__dispatch__/3` is called directly, as a real plain
  function call, with no supervised `A2A.Agent` process needed to prove
  this branch.
  """
  @spec check_unopted_semantic_request_falls_through() :: result()
  def check_unopted_semantic_request_falls_through do
    name = "an unopted-in resource's :semantic_request-flagged dispatch real-falls-through"

    # `Fixture.Resource` has two real skills (`:create` and `:probe`), so
    # an explicit `:skill` metadata is required alongside `:semantic_request`
    # here -- without it, `resolve_skill_name/2`'s real default-skill
    # resolution would itself refuse with a real, but unrelated,
    # `{:ambiguous_skill, _}` before this check's actual target (the
    # `:semantic_request` gate) is even reached. Naming `:probe` explicitly
    # isolates exactly the real behavior under test.
    message =
      %{
        A2A.Message.new_user([A2A.Part.Data.new(%{})])
        | metadata: %{semantic_request: true, skill: "probe"}
      }

    case AshA2A.Agent.__dispatch__(Resource, message, %{}) do
      {:error, %{code: :consequence_unclassified}} ->
        # The one real skill this fixture's default-skill resolution can
        # reach is :probe (consequence :unknown) -- reaching its real,
        # ordinary :consequence_unclassified refusal (not a semantic-
        # compiler error shape) IS the proof this fell through to normal
        # skill dispatch rather than reaching the semantic compiler.
        pass(
          name,
          "Resource.probe (real consequence :unknown) was real-reached via ordinary skill " <>
            "resolution -- the :semantic_request flag alone, without the resource's own " <>
            "compiled opt-in, never routed to Semantic.Compiler.compile/3"
        )

      other ->
        fail(
          name,
          "expected the real ordinary-dispatch refusal {:error, %{code: :consequence_unclassified}} " <>
            "(proving fallthrough to skill resolution), got #{inspect(other)} -- if this reached " <>
            "the semantic compiler instead, the caller-supplied flag alone was sufficient to bypass " <>
            "the resource's own compiled opt-in gate"
        )
    end
  end

  # -- shared helpers --

  # A real `AshA2A.Authority` naming the exact same principal + capability a
  # command built with `principal_id: "verify-architecture-principal"` for
  # `capability_id` carries, so `Authority.admits?/2` real-passes.
  defp matching_authority(capability_id) do
    principal = Identity.principal("verify-architecture-principal")
    Authority.new(principal, capability_id, source: :verify_architecture)
  end

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
