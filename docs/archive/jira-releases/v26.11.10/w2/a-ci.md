# Wave 2 lane a-ci receipt

Standing: PARTIAL_ALIVE

## Subject / files

- .github/workflows/ci.yml (sleep-gate job unconditional, ripgrep ensured)
- scripts/sleep_gate.sh (exit 2 on missing lib root or rg error; scans sa2a_crypto/lib)
- scripts/beam4pm_up.sh (records PID file, fails fast on dead BEAM, verifies card body has "name")
- scripts/beam4pm_down.sh (kills recorded PID + port listeners, removes PID file)

## Commands + exits

- `bash -n` on three scripts: 0
- `bash scripts/sleep_gate.sh`: 0 ("sleep_gate: clean")
- `bash scripts/sleep_gate.sh /nonexistent`: 2 (missing lib root)
- `BEAM4PM_DIR=/nonexistent scripts/beam4pm_up.sh`: 2
- python yaml.safe_load of ci.yml: ok

## Disclosures

- beam4pm_up live start path (PID/dead-BEAM/card-body) not run against a real beam4pm.
- Added `# SLEEP-CLASS: POLL-STEP` to the existing poll sleep in beam4pm_up.sh.
- No mix build was used; no _build-w2-a-ci directory created.

## Not done

- Live beam4pm_up run; rg-error (exit >1) branch not exercised.

## Repair pass

- Untracked scripts: scripts/sleep_gate.sh, beam4pm_up.sh, beam4pm_down.sh are `??` in git status.
  The CI sleep-gate job runs `bash scripts/sleep_gate.sh`, so a fresh checkout fails until the
  coordinator stages these three paths explicitly (lane may not run git). REQUIRED at landing.
- ci.yml hunks beyond this lane's item, NOT authored by this lane (file was already modified at
  session start; attribution unverified): two `mix deps.unlock --check-unused` steps (new gates,
  never run or receipted here), checkout pin bump to v7.0.1, comment rewrite near the
  conformance job, and new `credo` and `dialyzer` jobs (continue-on-error: true, non-gating).
  This lane's own hunk is the final `sleep-gate` job only. Coordinator decides landing of the rest.
- Re-run: bash -n 0; sleep_gate.sh 0 clean; sleep_gate.sh /nonexistent 2; BEAM4PM_DIR=/nonexistent
  beam4pm_up.sh 2.
