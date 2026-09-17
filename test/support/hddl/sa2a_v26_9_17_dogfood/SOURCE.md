# SOURCE: Original v26.9.17 HDDL/FOND Paste (Verbatim)

This file preserves the user's own original, byte-for-byte verbatim pasted
v26.9.17 HDDL domain+problem write-up, unedited, exactly as recovered from
this session's transcript at
`/Users/sac/.claude/projects/-Users-sac-ash-a2a/ec3dd2e8-fa19-4efe-90a3-eca0b048d05b.jsonl`
(same recovery technique used earlier this session for
`docs/rfc/RFC-SA2A-001-v26.9.16.md` and `docs/rfc/RFC-SA2A-002-v26.9.16.md`:
grep the JSONL for the raw user turn and extract its exact `content` string).
The message was typed as `ultracode <paste>`; the leading `ultracode ` slash
command trigger has been stripped, and everything from `The clean
representation is...` onward — every prose paragraph, every lisp/text code
fence, every closing formal-property block — is reproduced exactly as pasted,
character for character. It is kept here purely for fidelity auditing against
the committed, reconciled
`test/support/hddl/sa2a_v26_9_17_dogfood/domain.hddl` and `problem.hddl`,
which are a real, disclosed superset of this original text: 6 mirrored
Episode-2 actions plus a handful of `recoverable_added` repair methods and one
grounding-gap reconciliation (`classify-episode` wrapping the two originally
undead-wired actions below, `classify-problem` / `observe-classification`),
each already disclosed via comments directly in `domain.hddl` itself. Nothing
below this line has been edited, reformatted, or reflowed.

<!-- BEGIN VERBATIM SOURCE -->
The clean representation is **HDDL for decomposition + FOND for contingent outcomes**. `oneof` below is the FOND extension; the model can later be compiled into the exact dialect of the selected planner.

### `sa2a-v26.9.17-domain.hddl`

```lisp
(define (domain sa2a-v26-9-17)

  (:requirements
    :typing
    :negative-preconditions
    :hierarchy
    :method-preconditions
    :conditional-effects
    :non-deterministic)

  (:types
    release episode subject repo capability candidate
    plan artifact command receipt experience)

  ;; ============================================================
  ;; STATE
  ;; ============================================================

  (:predicates

    ;; Repository / capability topology
    (owns ?r - repo ?c - capability)
    (critical ?c - capability)
    (qualified ?r - repo ?c - capability)
    (build-broken ?r - repo ?c - capability)
    (blocked ?r - repo ?c - capability)
    (unsupported ?r - repo ?c - capability)

    ;; Exact subject identity
    (heads-pinned ?rel - release)
    (world-reconstructed ?e - episode ?s - subject)

    ;; Classification
    (classified ?e - episode)
    (unknown ?e - episode)
    (known ?e - episode)

    ;; Exploration
    (frontier-clean ?e - episode)
    (candidate-produced ?e - episode ?c - candidate)

    ;; Admission
    (admitted ?c - candidate)
    (candidate-refused ?c - candidate)
    (candidate-blocked ?c - candidate)
    (candidate-unsupported ?c - candidate)

    ;; Planning / allocation
    (plan-built ?e - episode ?p - plan)
    (allocation-bounded ?p - plan)
    (allocation-blocked ?p - plan)

    ;; Manufacture
    (manufactured ?e - episode ?a - artifact)
    (manufacture-failed ?e - episode)

    ;; Authority
    (authority-admitted ?e - episode)
    (authority-refused ?e - episode)

    ;; DO / receipt
    (command-issued ?e - episode ?cmd - command)
    (actuated ?cmd - command)
    (actuation-failed ?cmd - command)
    (receipt-pending ?cmd - command)
    (receipt-durable ?cmd - command ?r - receipt)
    (receipt-reconcile-blocked ?cmd - command)

    ;; Independent verification
    (verified ?e - episode)
    (verification-failed ?e - episode)
    (process-conformant ?e - episode)
    (process-nonconformant ?e - episode)

    ;; Feedback / learning
    (feedback-recorded ?e - episode)
    (experience-created ?e - episode ?x - experience)
    (experience-admitted ?x - experience)
    (replay-contract ?x - experience)

    ;; Equivalence / replay
    (equivalent ?new - episode ?old - episode)
    (equivalence-failed ?new - episode ?old - episode)
    (replayed ?e - episode ?x - experience)

    ;; Evidence / standing
    (affidavit-issued ?e - episode)
    (episode-alive ?e - episode)
    (release-qualified ?rel - release)
  )

  ;; ============================================================
  ;; TOP TASK
  ;; ============================================================

  (:task qualify-v26-9-17
    :parameters
      (?rel - release
       ?e1 ?e2 - episode
       ?s - subject
       ?x - experience))

  (:method m-qualify-v26-9-17
    :parameters
      (?rel - release
       ?e1 ?e2 - episode
       ?s - subject
       ?x - experience)

    :task (qualify-v26-9-17 ?rel ?e1 ?e2 ?s ?x)

    :ordered-subtasks
      (and
        (t1 (orient-release ?rel))
        (t2 (close-critical-repo-boundaries))
        (t3 (run-discovery-episode ?e1 ?s ?x))
        (t4 (run-known-replay-episode ?e2 ?e1 ?s ?x))
        (t5 (certify-release ?rel ?e1 ?e2))))
```

The top-level release therefore has exactly five phases:

$$
Orient
\rightarrow CloseBoundaries
\rightarrow Episode_1
\rightarrow Episode_2
\rightarrow Certify
$$

---

## 1. Repository closure

```lisp
  (:task orient-release
    :parameters (?rel - release))

  (:method m-orient-release
    :parameters (?rel - release)
    :task (orient-release ?rel)
    :ordered-subtasks
      (and
        (p1 (pin-exact-heads ?rel))))

  (:action pin-exact-heads
    :parameters (?rel - release)
    :precondition ()
    :effect (heads-pinned ?rel))


  (:task close-critical-repo-boundaries
    :parameters ())

  (:method m-close-critical-repo-boundaries
    :parameters ()
    :task (close-critical-repo-boundaries)
    :ordered-subtasks
      (and
        ;; admission + SA2A transport
        (r1 (qualify-boundary ash-a2a cap-orchestration))
        (r2 (qualify-boundary ash-r2rml cap-semantic-feedback))

        ;; bounded SELECT
        (r3 (qualify-boundary bcinr cap-bounded-select))

        ;; CONSTRUCT
        (r4 (qualify-boundary ggen cap-manufacture))
        (r5 (qualify-boundary ggen-igniter cap-framework-projection))

        ;; Authority + DO
        (r6 (qualify-boundary xaas cap-system-authority))

        ;; Evidence courts
        (r7 (qualify-boundary affidavit cap-standing))
        (r8 (qualify-boundary beam4pm cap-process-court))

        ;; Crown
        (r9 (qualify-boundary autofde-lab cap-crown))))


  (:task qualify-boundary
    :parameters (?r - repo ?c - capability))


  ;; Already qualifies
  (:method m-boundary-already-qualified
    :parameters (?r - repo ?c - capability)
    :task (qualify-boundary ?r ?c)
    :precondition (qualified ?r ?c)
    :subtasks ())


  ;; Otherwise observe exact boundary
  (:method m-boundary-observe
    :parameters (?r - repo ?c - capability)
    :task (qualify-boundary ?r ?c)
    :precondition
      (and
        (owns ?r ?c)
        (not (qualified ?r ?c)))
    :ordered-subtasks
      (and
        (v1 (verify-boundary ?r ?c))
        (v2 (resolve-boundary-result ?r ?c))))


  (:action verify-boundary
    :parameters (?r - repo ?c - capability)
    :precondition (owns ?r ?c)

    :effect
      (oneof

        ;; exact subject passed its court
        (qualified ?r ?c)

        ;; implementation exists but does not build
        (build-broken ?r ?c)

        ;; lawful path exists but cannot currently execute
        (blocked ?r ?c)

        ;; capability does not exist
        (unsupported ?r ?c)))
```

Recovery is topology, not blind retry:

```lisp
  (:task resolve-boundary-result
    :parameters (?r - repo ?c - capability))


  (:method m-boundary-success
    :parameters (?r - repo ?c - capability)
    :task (resolve-boundary-result ?r ?c)
    :precondition (qualified ?r ?c)
    :subtasks ())


  (:method m-repair-build
    :parameters (?r - repo ?c - capability)
    :task (resolve-boundary-result ?r ?c)
    :precondition (build-broken ?r ?c)
    :ordered-subtasks
      (and
        (d1 (diagnose-build ?r ?c))
        (d2 (repair-build ?r ?c))
        (d3 (verify-boundary ?r ?c))
        (d4 (resolve-boundary-result ?r ?c))))


  (:method m-reroute-blocked
    :parameters (?r - repo ?c - capability)
    :task (resolve-boundary-result ?r ?c)
    :precondition (blocked ?r ?c)
    :ordered-subtasks
      (and
        (b1 (discover-lawful-alternate ?r ?c))
        (b2 (verify-boundary ?r ?c))
        (b3 (resolve-boundary-result ?r ?c))))


  (:action diagnose-build
    :parameters (?r - repo ?c - capability)
    :precondition (build-broken ?r ?c)
    :effect ())

  (:action repair-build
    :parameters (?r - repo ?c - capability)
    :precondition (build-broken ?r ?c)
    :effect (not (build-broken ?r ?c)))

  (:action discover-lawful-alternate
    :parameters (?r - repo ?c - capability)
    :precondition (blocked ?r ?c)
    :effect (not (blocked ?r ?c)))
```

`UNSUPPORTED` deliberately has **no generic repair method**.

That forces:

$$
UNSUPPORTED \neq UNKNOWN
$$

A generator/runtime capability has to be explicitly extended rather than silently letting an LLM improvise around the missing machinery.

---

# 2. Episode 1 — UNKNOWN → Machine Experience

```lisp
  (:task run-discovery-episode
    :parameters
      (?e - episode
       ?s - subject
       ?x - experience))

  (:method m-run-discovery-episode
    :parameters
      (?e - episode
       ?s - subject
       ?x - experience)

    :task (run-discovery-episode ?e ?s ?x)

    :ordered-subtasks
      (and
        (e1 (reconstruct-world ?e ?s))
        (e2 (classify-problem ?e))
        (e3 (solve-classified-problem ?e))
        (e4 (construct-plan ?e plan-episode-1))
        (e5 (bound-allocation plan-episode-1))
        (e6 (manufacture ?e artifact-episode-1))
        (e7 (admit-authority ?e))
        (e8 (dispatch-command ?e command-episode-1))
        (e9 (execute-command command-episode-1))
        (e10 (close-receipt command-episode-1 receipt-episode-1))
        (e11 (independent-verify ?e))
        (e12 (observe-process ?e))
        (e13 (record-feedback ?e))
        (e14 (create-machine-experience ?e ?x))
        (e15 (admit-machine-experience ?x))
        (e16 (issue-affidavit ?e))))
```

World reconstruction and classification:

```lisp
  (:action reconstruct-world
    :parameters (?e - episode ?s - subject)
    :precondition ()
    :effect (world-reconstructed ?e ?s))


  (:action classify-problem
    :parameters (?e - episode)
    :precondition (classified ?e)
    :effect ())


  ;; Concrete observation court.
  ;; Outcome is not assumed in advance.
  (:action observe-classification
    :parameters (?e - episode)
    :precondition (not (classified ?e))
    :effect
      (oneof
        (and (classified ?e) (known ?e))
        (and (classified ?e) (unknown ?e))))
```

For the dogfood first pass, UNKNOWN invokes intelligence:

```lisp
  (:task solve-classified-problem
    :parameters (?e - episode))


  (:method m-solve-known
    :parameters (?e - episode)
    :task (solve-classified-problem ?e)
    :precondition (known ?e)
    :subtasks ())


  (:method m-solve-unknown
    :parameters (?e - episode)
    :task (solve-classified-problem ?e)
    :precondition
      (and
        (unknown ?e)
        (frontier-clean ?e))
    :ordered-subtasks
      (and
        (u1 (explore-unknown ?e candidate-1))
        (u2 (admit-candidate candidate-1))))


  (:action explore-unknown
    :parameters (?e - episode ?c - candidate)
    :precondition
      (and
        (unknown ?e)
        (frontier-clean ?e))

    :effect
      (and
        (candidate-produced ?e ?c)

        ;; records that frontier reasoning was purchased
        (not (frontier-clean ?e))))


  (:action admit-candidate
    :parameters (?c - candidate)
    :precondition ()

    :effect
      (oneof
        (admitted ?c)
        (candidate-refused ?c)
        (candidate-blocked ?c)
        (candidate-unsupported ?c)))
```

That is the exact boundary:

$$
LLM \rightarrow Candidate
$$

not:

$$
LLM \rightarrow Truth
$$

---

# 3. Plan → bounded SELECT → CONSTRUCT

```lisp
  (:action construct-plan
    :parameters (?e - episode ?p - plan)
    :precondition ()
    :effect (plan-built ?e ?p))


  (:action bound-allocation
    :parameters (?p - plan)
    :precondition ()

    :effect
      (oneof
        (allocation-bounded ?p)
        (allocation-blocked ?p)))


  (:action manufacture
    :parameters (?e - episode ?a - artifact)
    :precondition (allocation-bounded plan-episode-1)

    :effect
      (oneof
        (manufactured ?e ?a)
        (manufacture-failed ?e)))
```

This is the repo boundary:

```text
bcinr
  = SELECT

ggen + ggen_igniter
  = CONSTRUCT
```

Neither has DO authority.

---

# 4. Authority → DO → Receipt

```lisp
  (:action admit-authority
    :parameters (?e - episode)
    :precondition (manufactured ?e artifact-episode-1)

    :effect
      (oneof
        (authority-admitted ?e)
        (authority-refused ?e)))


  (:action dispatch-command
    :parameters (?e - episode ?cmd - command)
    :precondition (authority-admitted ?e)
    :effect (command-issued ?e ?cmd))


  ;; Critical BRCE invariant:
  ;;
  ;; There is NO possible successful actuation state that lacks
  ;; a corresponding receipt-pending state.
  ;;
  (:action execute-command
    :parameters (?cmd - command)
    :precondition ()

    :effect
      (oneof

        ;; successful consequence is born with receipt obligation
        (and
          (actuated ?cmd)
          (receipt-pending ?cmd))

        ;; no consequence occurred
        (actuation-failed ?cmd)))


  (:action close-receipt
    :parameters (?cmd - command ?r - receipt)
    :precondition
      (and
        (actuated ?cmd)
        (receipt-pending ?cmd))

    :effect
      (oneof

        ;; durable receipt
        (and
          (receipt-durable ?cmd ?r)
          (not (receipt-pending ?cmd)))

        ;; consequence known, receipt still unresolved:
        ;; NEVER replay automatically
        (receipt-reconcile-blocked ?cmd)))
```

Therefore the reachable state graph forbids:

$$
\boxed{actuated \land \neg receipt\_pending}
$$

until a durable receipt exists.

That is the FOND encoding of **zero unreceipted actuation**.

---

# 5. Independent evidence → learning

```lisp
  (:action independent-verify
    :parameters (?e - episode)
    :precondition
      (receipt-durable command-episode-1 receipt-episode-1)

    :effect
      (oneof
        (verified ?e)
        (verification-failed ?e)))


  (:action observe-process
    :parameters (?e - episode)
    :precondition (verified ?e)

    :effect
      (oneof
        (process-conformant ?e)
        (process-nonconformant ?e)))


  (:action record-feedback
    :parameters (?e - episode)
    :precondition
      (and
        (verified ?e)
        (process-conformant ?e))
    :effect (feedback-recorded ?e))


  (:action create-machine-experience
    :parameters (?e - episode ?x - experience)
    :precondition
      (and
        (feedback-recorded ?e)
        (verified ?e))

    :effect
      (experience-created ?e ?x))


  ;; Knowledge promotion is its own admission.
  (:action admit-machine-experience
    :parameters (?x - experience)
    :precondition (experience-created episode-1 ?x)

    :effect
      (oneof

        (and
          (experience-admitted ?x)
          (replay-contract ?x))

        ;; failed knowledge admission does not retroactively
        ;; invalidate the execution receipt
        (candidate-refused candidate-experience)))


  (:action issue-affidavit
    :parameters (?e - episode)
    :precondition
      (and
        (verified ?e)
        (process-conformant ?e))
    :effect (affidavit-issued ?e))
```

Critical separation:

$$
Executed
\neq Verified
\neq Experience
\neq KNOWN
$$

---

# 6. Episode 2 — prove the reinforcement

This is the crown.

```lisp
  (:task run-known-replay-episode
    :parameters
      (?e2 ?e1 - episode
       ?s - subject
       ?x - experience))

  (:method m-run-known-replay-episode
    :parameters
      (?e2 ?e1 - episode
       ?s - subject
       ?x - experience)

    :task (run-known-replay-episode ?e2 ?e1 ?s ?x)

    :precondition
      (and
        (experience-admitted ?x)
        (replay-contract ?x))

    :ordered-subtasks
      (and
        (k1 (reconstruct-world ?e2 ?s))
        (k2 (prove-semantic-equivalence ?e2 ?e1))
        (k3 (route-known-replay ?e2 ?x))
        (k4 (replay-known-transition ?e2 ?x))
        (k5 (admit-authority-replay ?e2))
        (k6 (dispatch-replay-command ?e2 command-episode-2))
        (k7 (execute-replay-command command-episode-2))
        (k8 (close-replay-receipt
              command-episode-2
              receipt-episode-2))
        (k9 (verify-replay ?e2))
        (k10 (observe-replay-process ?e2))
        (k11 (issue-affidavit ?e2))))
```

Equivalence cannot be analogy:

```lisp
  (:action prove-semantic-equivalence
    :parameters (?new ?old - episode)
    :precondition ()

    :effect
      (oneof
        (equivalent ?new ?old)
        (equivalence-failed ?new ?old)))
```

The replay route has a hard negative condition:

```lisp
  (:action route-known-replay
    :parameters (?e - episode ?x - experience)

    :precondition
      (and
        (equivalent ?e episode-1)
        (experience-admitted ?x)
        (replay-contract ?x)
        (frontier-clean ?e))

    :effect
      (known ?e))


  (:action replay-known-transition
    :parameters (?e - episode ?x - experience)

    :precondition
      (and
        (known ?e)
        (frontier-clean ?e)
        (replay-contract ?x))

    :effect
      (replayed ?e ?x))
```

There is intentionally **no `explore-unknown` subtask** in the replay method.

So the second crown requires:

$$
\boxed{frontier\_clean(Episode_2)}
$$

through completion.

---

# 7. Release certification

```lisp
  (:task certify-release
    :parameters
      (?rel - release
       ?e1 ?e2 - episode))

  (:method m-certify-release
    :parameters
      (?rel - release
       ?e1 ?e2 - episode)

    :task (certify-release ?rel ?e1 ?e2)

    :precondition
      (and
        ;; Episode 1 actually happened
        (verified ?e1)
        (process-conformant ?e1)
        (affidavit-issued ?e1)

        ;; Experience exists and has standing
        (experience-admitted experience-1)
        (replay-contract experience-1)

        ;; Episode 2 used it
        (equivalent ?e2 ?e1)
        (replayed ?e2 experience-1)
        (verified ?e2)
        (process-conformant ?e2)
        (affidavit-issued ?e2)

        ;; No repeated frontier reasoning
        (frontier-clean ?e2))

    :ordered-subtasks
      (and
        (c1 (mark-release-qualified ?rel))))


  (:action mark-release-qualified
    :parameters (?rel - release)
    :precondition ()
    :effect (release-qualified ?rel))
)
```

---

# `sa2a-v26.9.17-problem.hddl`

```lisp
(define (problem dogfood-v26-9-17)
  (:domain sa2a-v26-9-17)

  (:objects

    v26-9-17 - release

    episode-1
    episode-2 - episode

    sa2a-self-improvement - subject

    ;; Repositories
    autofde-lab
    ash-a2a
    ash-r2rml
    bcinr
    ggen
    ggen-igniter
    xaas
    affidavit
    beam4pm
    unrdf
    wasm4pm
      - repo

    ;; Capability boundaries
    cap-crown
    cap-orchestration
    cap-semantic-feedback
    cap-bounded-select
    cap-manufacture
    cap-framework-projection
    cap-system-authority
    cap-standing
    cap-process-court
    cap-runtime
    cap-portable-runtime
      - capability

    candidate-1
    candidate-experience
      - candidate

    plan-episode-1 - plan

    artifact-episode-1 - artifact

    command-episode-1
    command-episode-2
      - command

    receipt-episode-1
    receipt-episode-2
      - receipt

    experience-1 - experience
  )

  (:htn
    :tasks
      (and
        (top
          (qualify-v26-9-17
            v26-9-17
            episode-1
            episode-2
            sa2a-self-improvement
            experience-1))))

  (:init

    ;; ========================================================
    ;; Repo responsibility graph
    ;; ========================================================

    (owns autofde-lab cap-crown)

    (owns ash-a2a cap-orchestration)

    (owns ash-r2rml cap-semantic-feedback)

    (owns bcinr cap-bounded-select)

    (owns ggen cap-manufacture)

    (owns ggen-igniter cap-framework-projection)

    (owns xaas cap-system-authority)

    (owns affidavit cap-standing)

    (owns beam4pm cap-process-court)

    (owns unrdf cap-runtime)

    (owns wasm4pm cap-portable-runtime)

    ;; Critical release chain
    (critical cap-crown)
    (critical cap-orchestration)
    (critical cap-semantic-feedback)
    (critical cap-bounded-select)
    (critical cap-manufacture)
    (critical cap-framework-projection)
    (critical cap-system-authority)
    (critical cap-standing)
    (critical cap-process-court)

    ;; Both episodes begin without frontier use.
    ;; Episode 1 is allowed to consume it.
    ;; Episode 2 must preserve it.
    (frontier-clean episode-1)
    (frontier-clean episode-2)
  )

  (:goal
    (and
      (release-qualified v26-9-17)

      ;; First episode acquired knowledge.
      (experience-admitted experience-1)
      (replay-contract experience-1)

      ;; Second episode proved reuse.
      (replayed episode-2 experience-1)
      (frontier-clean episode-2)

      ;; Both have independent evidence.
      (affidavit-issued episode-1)
      (affidavit-issued episode-2)

      (process-conformant episode-1)
      (process-conformant episode-2)))
)
```

## The resulting FOND policy

The important part is that this does **not** compile into a single happy-path sequence. It compiles into a policy graph:

```text
                               ┌─ QUALIFIED ────────────────────┐
                               │                               │
VERIFY REPO ──────────────────┼─ BUILD_BROKEN → repair ───────┤
                               │                               │
                               ├─ BLOCKED → alternate edge ────┤
                               │                               │
                               └─ UNSUPPORTED → typed stop     │
                                                               ▼

OBSERVE
   │
   ├─ KNOWN ──────────────────────────────────────────────┐
   │                                                     │
   └─ UNKNOWN                                            │
         ↓                                               │
      EXPLORE                                            │
         ↓                                               │
      CANDIDATE                                          │
         ↓                                               │
      ADMIT                                              │
       ├─ REFUSED ──→ terminate/refine                   │
       ├─ BLOCKED ──→ topology repair                    │
       ├─ UNSUPPORTED → explicit extension               │
       └─ ADMITTED                                       │
              ↓                                          │
          FOND/HDDL PLAN                                 │
              ↓                                          │
        BOUNDED SELECT                                   │
         ├─ blocked → replan                             │
         └─ bounded                                      │
              ↓                                          │
          MANUFACTURE                                    │
         ├─ failure → repair generator                   │
         └─ artifact                                     │
              ↓                                          │
          AUTHORITY                                      │
         ├─ refused → stop                               │
         └─ admitted                                     │
              ↓                                          │
              DO                                         │
         ├─ failed → recovery                            │
         └─ actuated + receipt_pending                   │
                         ↓                               │
                    RECONCILE                            │
                     ├─ blocked → NO REPLAY              │
                     └─ durable receipt                  │
                              ↓                          │
                           VERIFY                        │
                       ├─ fail → repair                  │
                       └─ pass                           │
                              ↓                          │
                           OCEL                          │
                       ├─ nonconformant → reject         │
                       └─ conformant                     │
                              ↓                          │
                       MACHINE EXPERIENCE                │
                              ↓                          │
                       EXPERIENCE ADMISSION              │
                              ↓                          │
                            KNOWN ────────────────────────┘
                              ↓
                   ┌─────────────────────┐
                   │ SECOND EPISODE      │
                   │ equivalence proof   │
                   └──────────┬──────────┘
                              ↓
                           REPLAY
                              ↓
                       AUTHORITY / DO
                              ↓
                     RECEIPT / VERIFY
                              ↓
                frontier_clean = TRUE
                              ↓
                     v26.9.17 ALIVE
```

The most important formal property is now visible:

$$
\boxed{
Episode_1:
UNKNOWN \rightarrow Experience \rightarrow KNOWN
}
$$

while:

$$
\boxed{
Episode_2:
KNOWN \rightarrow Replay
}
$$

subject to:

$$
frontier\_clean(Episode_2)=true
$$

So **the planner itself can falsify the v26.9.17 thesis**: if Episode 2 requires `explore-unknown` for the semantic residue supposedly learned in Episode 1, there is no valid crown plan.

That is the FOND/HDDL form of the self-reinforcing SA2A loop.

<!-- END VERBATIM SOURCE -->
