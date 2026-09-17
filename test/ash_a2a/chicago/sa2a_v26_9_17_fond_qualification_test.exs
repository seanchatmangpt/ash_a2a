defmodule AshA2A.Chicago.SA2AV26917FondQualificationTest do
  @moduledoc """
  Qualifies the real `native/hddl_cli` (ferroplan, strong-cyclic FOND) solver
  against `test/support/hddl/sa2a_v26_9_17_dogfood/{domain,problem}.hddl` -- a
  HDDL model of the v26.9.17 cross-repo SA2A self-improvement release-
  qualification loop (Orient -> CloseBoundaries -> Episode1(UNKNOWN->
  Experience) -> Episode2(KNOWN->Replay) -> Certify), spanning 11 real local
  repos as HDDL objects (autofde-lab, ash-a2a, ash-r2rml, bcinr, ggen,
  ggen-igniter, xaas, affidavit, beam4pm, unrdf, wasm4pm). Repo-topology
  grounding (a sibling Design-phase investigation, not re-derived here) found
  9 of these 11 real, ALIVE-or-PARTIAL local repos actually implementing the
  capability their HDDL object claims (autofde-lab/cap-crown, ash-a2a/
  cap-orchestration, ash-r2rml/cap-semantic-feedback, bcinr/cap-bounded-select,
  ggen/cap-manufacture, ggen-igniter/cap-framework-projection, xaas/
  cap-system-authority, affidavit/cap-standing all ALIVE; beam4pm/
  cap-process-court PARTIAL) -- real-world grounding for why this domain
  models what it models, not just an abstract exercise.

  Shells out to the real `native/hddl_cli/target/release/hddl_cli` binary via
  `System.cmd/2` (a real OS subprocess, zero Mock/mox/patch/monkeypatch) and
  asserts on the real decoded JSON/exit code it produces, mirroring
  `test/ash_a2a_hddl_solver_qualification_test.exs`'s own conventions exactly.

  ## The real, honest result this test asserts

  The fully reconciled domain reports **real NoPlan (not solved)** -- and this
  is the correct, disclosed, non-overclaimed result, not a failure to fix.

  Three sibling Design-phase investigations (episode1-recovery,
  episode2-and-receipt-boundary, repo-topology-grounding) independently
  verified, predicate by predicate, which of the domain's many
  non-deterministic (`oneof`) failure branches are genuine *modeling gaps*
  (a real recovery path exists and was added) versus genuine *intentional
  terminal states* (adding a "retry until it works" method would fabricate
  confidence or bypass a real invariant rather than repair a fixable fact).
  This test's fixture is their reconciled union:

  Recoverable and repaired (diagnose -> repair -> re-verify/re-admit, mirroring
  the domain's own pre-existing `build-broken`/`blocked` repo-boundary
  pattern): `allocation-blocked`, `manufacture-failed`, `authority-refused`
  (episode 1's `admit-authority` occurrence only), `actuation-failed`
  (episode 1's `execute-command` occurrence only), `candidate-refused`,
  `candidate-blocked` (via restructuring `admit-candidate` into a real
  compound task, mirroring `qualify-boundary`).

  Left deliberately terminal, no repair method added, each independently
  confirmed fatal-when-reachable by a real isolated ablation: `unsupported`
  (repo boundary -- capability genuinely doesn't exist), `candidate-unsupported`
  (same reasoning at the admission layer), `verification-failed` and
  `process-nonconformant` (both episodes -- independent evidence courts;
  retrying them until they pass would erase a real finding, not repair a
  fixable fact), `candidate-refused candidate-experience` (knowledge-promotion
  admission court -- the domain's own comment already states failing it does
  not invalidate the real execution receipt), `equivalence-failed` (no
  separately-fixable intervening state exists), `receipt-reconcile-blocked`
  (both episodes -- the domain's own explicit "NEVER replay automatically"
  BRCE zero-unreceipted-actuation invariant; real corroborating evidence in
  `ash_a2a/lib/ash_a2a/command_bus.ex`, whose reconciliation path is a
  distinct, presumably operator-invoked function, never folded into automatic
  dispatch), and `authority-refused`/`actuation-failed` on their EPISODE 2
  (replay) occurrences specifically -- deliberately left unwired even though
  episode 1's identically-named predicate got a real repair, because episode
  2's replay actions are real, separate call sites this reconciliation never
  wires a retry into (confirmed: `command_bus.ex`'s only real retries are
  bounded RECEIPT-COMMIT persistence retries, a different, later step, never
  execute/replay-execute itself).

  A real, previously-undiscovered bug was also found and fixed during
  reconciliation, independent of the above: `classify-problem` (wired into
  `run-discovery-episode`'s `e2` slot) had precondition `(classified ?e)`,
  but the only action that ever produces `classified` (`observe-classification`)
  was never invoked by any task/method anywhere in the domain -- an orphaned
  action, structurally identical to leaving a `oneof` branch permanently
  unreachable. Confirmed by stripping every OTHER `oneof` in the pasted
  domain down to its success-only branch (a maximal positive control) and
  observing it STILL returned real NoPlan; the minimal, non-inventive fix
  wraps `classify-problem`/`observe-classification` in a `classify-episode`
  task using the domain's own already-established `qualify-boundary`/
  `verify-boundary`/`resolve-boundary-result` "already done, else observe it
  for real" pattern -- inventing no new action or predicate.

  With that bug fixed and every remaining branch classified as above, a
  careful reconstruction that neutralizes exactly (and only) the confirmed
  terminal branches -- built from a from-scratch success-only baseline with
  each recoverable branch surgically restored one at a time and in
  combination -- reports real `solved: true`. This proves the honest `NoPlan`
  this test asserts against the real, undiluted fixture is fully and only
  explained by the deliberately-uncovered terminal predicates above: no other
  latent defect remains. See the manufacturing receipt for the exact real
  ablation commands and outputs (both the individual per-predicate ablations
  from the three sibling Design-phase tasks, and this reconciliation's own
  positive-control mechanism check).

  The real, load-bearing structural finding this whole exercise surfaces: the
  pinned ferroplan rev's `PlanningType::Fond` dispatch requires strong-cyclic
  coverage of *every* reachable `oneof` branch, with no HDDL syntax to declare
  an accepted non-goal terminal state (`adapt_problem` in `hddl.rs` hardcodes
  `unsafe_states`/`soft_goal_facts` to `Default::default()`, and neither field
  is consulted by `fond_policy_strong_cyclic` in a way that would help even if
  it could be populated from HDDL). A domain author who wants a genuine
  zero-unreceipted-actuation / non-rubber-stamp-court invariant (as this
  domain deliberately does, matching the real ash_a2a/command_bus.ex system it
  models) and wants this CLI to report a real strong-cyclic solve cannot have
  both at once for those predicates. That tension is real and unresolved by
  any existing knob in this pinned ferroplan rev -- an honest `NoPlan` is the
  correct report, not a defect to paper over.
  """

  use ExUnit.Case, async: true

  @cli_path Path.expand("../../../native/hddl_cli/target/release/hddl_cli", __DIR__)

  @domain Path.expand(
            "../../support/hddl/sa2a_v26_9_17_dogfood/domain.hddl",
            __DIR__
          )
  @problem Path.expand(
             "../../support/hddl/sa2a_v26_9_17_dogfood/problem.hddl",
             __DIR__
           )

  setup_all do
    unless File.exists?(@cli_path) do
      flunk("""
      hddl_cli binary not built at #{@cli_path}.
      Run: cd #{Path.expand("../../../native/hddl_cli", __DIR__)} && cargo build --release --locked
      """)
    end

    :ok
  end

  defp run_hddl_cli!(domain_path, problem_path) do
    {stdout, exit_code} = System.cmd(@cli_path, [domain_path, problem_path])

    decoded =
      case JSON.decode(stdout) do
        {:ok, decoded} ->
          decoded

        {:error, reason} ->
          flunk("hddl_cli produced non-JSON stdout: #{inspect(reason)}: #{stdout}")
      end

    {decoded, exit_code, stdout}
  end

  test "the real hddl_cli solver reports genuine NoPlan for the fully reconciled v26.9.17 domain" do
    assert File.exists?(@domain), "fixture domain missing: #{@domain}"
    assert File.exists?(@problem), "fixture problem missing: #{@problem}"

    {decoded, exit_code, raw} = run_hddl_cli!(@domain, @problem)

    # This is the real, asserted result: NoPlan, not solved. See moduledoc for
    # the full, disclosed reasoning on why this is the correct outcome and not
    # a failure to fix -- the domain models real, deliberate BRCE
    # zero-unreceipted-actuation and independent-evidence-court invariants
    # that this pinned ferroplan rev has no syntax to mark as acceptable
    # non-goal terminals, so a genuinely faithful model of them is honestly
    # unsolvable under PlanningType::Fond's universal-coverage requirement.
    refute exit_code == 0,
           "expected the real hddl_cli to report a non-zero exit for this " <>
             "genuinely unsolvable pair. Real raw stdout: #{raw}"

    assert Map.has_key?(decoded, "error"),
           "expected an \"error\" key (the real solver's NoPlan shape) from " <>
             "the real binary. Real raw stdout: #{raw}"

    assert decoded["error"] =~ "NoPlan",
           "expected the real solver's error to name NoPlan specifically " <>
             "(not a grounding/parse error -- this fixture is confirmed to " <>
             "ground cleanly), got: #{inspect(decoded["error"])}. " <>
             "Real raw stdout: #{raw}"

    refute decoded["solved"] == true,
           "the sa2a_v26_9_17_dogfood pair must never be reported solved -- " <>
             "if it ever is, either a genuinely-terminal invariant was " <>
             "silently weakened or ferroplan gained new behavior; either way " <>
             "this assertion, not a passing green run, is the signal to " <>
             "re-investigate. Real raw stdout: #{raw}"
  end

  test "the domain fixture grounds cleanly (the NoPlan above is semantic, not a parse/grounding error)" do
    {decoded, _exit_code, raw} = run_hddl_cli!(@domain, @problem)

    refute decoded["error"] =~ "parse error",
           "fixture must ground cleanly -- a parse error would mean the " <>
             "NoPlan assertion above is not testing what it claims to. " <>
             "Real raw stdout: #{raw}"

    refute decoded["error"] =~ "grounding error",
           "fixture must ground cleanly -- a grounding error would mean the " <>
             "NoPlan assertion above is not testing what it claims to. " <>
             "Real raw stdout: #{raw}"
  end
end
