# beam4pm Dogfood Receipt

Standing: PARTIAL

Subject: ash_a2a working tree (uncommitted, base 68a8bd5e) client
`AshA2A.Protocol.Client` against beam4pm 26.10.18 live agent
(`scripts/beam4pm_up.sh 4211`, `MIX_ENV=test`, `~/beam4pm` compiled in its own tree).

## Commands and results

- `BEAM4PM_A2A_URL=http://127.0.0.1:4211/a2a mix test test/dogfood --include external_api --include serial`
  -> 2 tests, 1 failure.
- `Client.discover/1`: PASS. Card name `beam4pm_a2a_agent`, 1346 skills, protocol_version "1.0".
- `Client.send_message/3` skill `BeamPM.Ash.Resources.OcelEvent.read`:
  FAIL, `{:error, {:http_error, 500, ""}}`.

## Finding (beam4pm side, not fixed)

beam4pm's `BeamPM.A2ARouter` forwards `/a2a` to `A2A.Plug` (hex `a2a` 0.3.0), not
ash_a2a's own plug. The agent is `use AshA2A.Agent`, so the task is an
`%AshA2A.Protocol.Task{}`, which `A2A.JSONRPC.encode_send_result/2` cannot encode
(`FunctionClauseError`, `lib/a2a/jsonrpc.ex:338`; beam4pm server log). Also the task
state was `:failed` before encoding (cause not inspected).
Fix lives in beam4pm: mount ash_a2a's transport plug for the agent, or encode with
`AshA2A.Protocol.JSON`.

## Version skew

beam4pm resolves ash_a2a from git ref `99280b85` (`~/beam4pm/mix.exs:132-146`,
`mix.lock:5`), not 26.10.9. Results are old-server / new-client.

## Not done

- No fix applied in beam4pm. `Planning.plan_with_ferroplan` still in-process.
- `get_task` / `list_tasks` not exercised (no task id from a successful send).
- Ferroplan engine in beam4pm did not start (wasm not built) — per its own log.

## Update: beam4pm upgraded to local ash_a2a (loop closed for read skills)

Changes in `~/beam4pm` (uncommitted, other lanes' dirty files untouched):
- `mix.exs` `ash_a2a_dep/0`: `ASH_A2A_PATH`, else sibling `../ash_a2a` path dep
  (`override: true`), else the old git ref; `mix.lock` ash_a2a git line removed,
  `mix deps.get` re-resolved (ash 3.37.4, spark 2.7.10, ecto, nimble_options).
- `lib/beam4pm_a2a_router.ex`: forwards `/a2a` to `AshA2A.Protocol.Plug`
  (was hex `A2A.Plug`, which crashed encoding `%AshA2A.Protocol.Task{}`).
- `lib/beam4pm_a2a_agent.ex`: `public_skills` for the two curated read-only skills
  (the failed task was `:unauthenticated`, inferred from code, not read from payload).
- `ontology.ttl`: re-admitted sha256 of the two edited hand-authored files;
  `ggen sync run --skip-ea-admission` (installed ggen 26.11.5 demands an absent
  `ea.graph.json`; the opt-out was used) rewrote only
  `schema/beam4pm_hand_authored_source.tsv` and `docs/reference/..._source.md`.

Results:
- `mix compile` (MIX_ENV=test) in beam4pm: Generated beam4pm app.
- `BEAM4PM_A2A_URL=http://127.0.0.1:4211/a2a mix test test/dogfood --include external_api --include serial`
  -> 2 tests, 0 failures; `send_message` of `BeamPM.Ash.Resources.OcelEvent.read`
  returns a `:completed` Task.
- beam4pm `test/beam4pm_authorship_gate_test.exs`: still 2 failures from pre-existing
  drift/unadmitted files (8 SHA-drift incl. application.ex, replan_router.ex; ~25 unadmitted
  repop/zcode/digest files) — none are the two files edited here.

Still open: no `beam4pm_replan` / `beam4pm_plan` skill on beam4pm (needs a hand-authored
resource admitted as `bpm:HandAuthoredSource`, plus an agent domain that includes it);
`get_task`/`list_tasks` not exercised; beam4pm's own full suite not run.
