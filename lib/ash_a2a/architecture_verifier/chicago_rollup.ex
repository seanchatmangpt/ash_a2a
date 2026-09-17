# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ArchitectureVerifier.ChicagoRollup do
  @moduledoc """
  Rolls a small, named subset of the real RFC-SA2A-002 Chicago court evidence
  (`lib/ash_a2a/chicago/courts/`) up into `AshA2A.ArchitectureVerifier.checks/0`,
  so the one CI-gate entry point ARD §23 names (`mix
  ash_a2a.verify_architecture`) actually attests to it.

  ## The gap this closes

  `AshA2A.ArchitectureVerifier.checks/0` (before this module existed) only ran
  9 checks scoped to capability-index derivability, consequence
  classification, `CommandBus` admission and `Command.fingerprint/1`
  invariants. Real, separate falsifier-court coverage already existed under
  `lib/ash_a2a/chicago/courts/` for the *other* ARD §23 invariants (semantic
  envelope negotiation, BRCE/sole-DO-boundary, authority non-implication,
  receipt identity binding, offline replay, knowledge-hook meta-admission,
  OCEL evidence validity) -- each with its own real `test/ash_a2a/chicago/
  *_test.exs` -- but none of that evidence rolled up into the one task ARD
  §23 names as the architecture-invariant gate. A CI run of `mix
  ash_a2a.verify_architecture` alone attested to none of it.

  ## What this module does, concretely

  For each named court module below, this runs that court alone (no other
  court's falsifiers) through the real `AshA2A.Chicago.Runner` --
  `Runner.run(courts: [court], profile: court.profile(), evidence_dir: ...)`
  -- exactly the pattern this repo's own `test/ash_a2a/chicago/*_test.exs`
  files already use (e.g. `brce_gate7_test.exs`,
  `envelope_negotiation_transport_test.exs`). A full Chicago run, not a
  single cherry-picked falsifier: every falsifier the court declares is
  attempted for real, its OCEL evidence is independently corroborated by the
  runner's own consumer (`AshA2A.Chicago.Query`), and this module's one
  `checks/0` entry for that court PASSes only when every one of the court's
  falsifiers `AshA2A.Chicago.Result.counts_as_pass?/1` (killed / positive-control
  -passed / measured, AND OCEL-corroborated) -- never on the court merely not
  crashing.

  Courts rolled up (all real, all already exercised by their own dedicated
  test file, all compiled under plain `lib/` so they are reachable from a
  plain `mix ash_a2a.verify_architecture` run outside `MIX_ENV=test`):

    * `AshA2A.Chicago.Courts.SemanticEnvelope` (`SA2A-ENV`, §54) -- semantic
      envelope / profile negotiation admission boundary.
    * `AshA2A.Chicago.Courts.Brce` (`CHI-BRCE`, Gate 7, §38/§68/§69) -- sole
      DO boundary / zero unreceipted actuation, direct `CommandBus` bypass
      included.
    * `AshA2A.Chicago.Courts.AuthorityNonImplication` (`SA2A-AUTH`,
      §57/§64/§65/§66) -- authority non-implication / confused-deputy.
    * `AshA2A.Chicago.Courts.ReceiptBinding` (`CHI-RECEIPT`, Gate 9, §40/§128)
      -- receipt identity binding / evidence-laundering resistance.
    * `AshA2A.Chicago.Courts.OfflineReplay` (`CHI-REPLAY`, Gate 10, §41/§92)
      -- offline replay without consequence.
    * `AshA2A.Chicago.Courts.KnowledgeHooks` (`SA2A-HOOK`, Gate 7,
      §60/§61/§62) -- knowledge-hook meta-admission (Hook ≠ DO).
    * `AshA2A.Chicago.Courts.OcelValidity` (`SA2A-OCEL`, §15/§16/§17) -- OCEL
      2.0 validity / evidence completeness of the evidence chain itself.

  One named, confirmed exclusion, not a silent omission: an "exact-subject" /
  "composition-lock" court (RFC-SA2A-003) is not rolled up here. No such
  module exists yet under `lib/ash_a2a/chicago/courts/` (confirmed by
  directory listing at the time this module was written) -- only an
  uncommitted, untested draft exists outside this worktree. Rolling up a
  court that doesn't compile would make this module lie about what it
  verified; add it here once that court is real, tested, and merged.

  `AshA2A.Chicago.Courts.SemanticBoundary` is deliberately not in the list
  above: it is shared OCEL-mapping plumbing for the envelope/negotiation/
  transport courts (`peer_mappings/2`), not itself a `Court` behaviour
  implementation (`Court.court?/1` is false for it) -- there is nothing to
  run.

  ## Result shape

  Each entry is the same `%{name:, status:, detail:}` shape
  `AshA2A.ArchitectureVerifier.checks/0` already returns -- `status` is
  `:pass` or `:fail`, never anything else, so `Mix.Tasks.AshA2a.
  VerifyArchitecture`'s existing `print_result/1`/`Mix.raise/1` handles these
  identically to the original 9 checks with no changes there.
  """

  alias AshA2A.Chicago.{Result, Runner}

  alias AshA2A.Chicago.Courts.{
    AuthorityNonImplication,
    Brce,
    KnowledgeHooks,
    OcelValidity,
    OfflineReplay,
    ReceiptBinding,
    SemanticEnvelope
  }

  @type result :: %{name: String.t(), status: :pass | :fail, detail: String.t()}

  @courts [
    SemanticEnvelope,
    Brce,
    AuthorityNonImplication,
    ReceiptBinding,
    OfflineReplay,
    KnowledgeHooks,
    OcelValidity
  ]

  @doc "The Chicago court modules this rollup runs, in the order `checks/0` reports them."
  @spec courts() :: [module()]
  def courts, do: @courts

  @doc "Runs every rolled-up Chicago court for real and returns one result per court."
  @spec checks() :: [result()]
  def checks, do: Enum.map(@courts, &check_court/1)

  @doc false
  @spec check_court(module()) :: result()
  def check_court(court) do
    name =
      "Chicago court #{court.id()} (#{court.title()}) real-corroborated-passes " <>
        "under mix ash_a2a.verify_architecture"

    evidence_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a-arch-verifier-chicago-#{court.id()}-#{System.unique_integer([:positive])}"
      )

    try do
      case Runner.run(courts: [court], profile: court.profile(), evidence_dir: evidence_dir) do
        {:ok, run} -> summarize(name, run)
        {:error, reason} -> fail(name, "AshA2A.Chicago.Runner.run/1 errored: #{inspect(reason)}")
      end
    after
      File.rm_rf(evidence_dir)
    end
  end

  defp summarize(name, run) do
    total = length(run.results)
    failing = Enum.reject(run.results, &Result.counts_as_pass?/1)

    case failing do
      [] ->
        pass(
          name,
          "#{total}/#{total} falsifier(s) real-corroborated-passed " <>
            "(standing: #{inspect(run.receipt["standing"])})"
        )

      _ ->
        detail =
          Enum.map_join(failing, "; ", fn r ->
            case r.detail do
              nil -> "#{r.falsifier_id}=#{r.verdict}"
              detail -> "#{r.falsifier_id}=#{r.verdict} (#{detail})"
            end
          end)

        fail(
          name,
          "#{length(failing)}/#{total} falsifier(s) did not real-pass: #{detail}"
        )
    end
  end

  defp pass(name, detail), do: %{name: name, status: :pass, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}
end
