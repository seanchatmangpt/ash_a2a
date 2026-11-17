# Run the doctor

Status: verified (2026-11-16, Elixir 1.20.4 / OTP 29.1.1): `mix test test/ash_a2a/doctor_test.exs`, 7 passed;
`mix ash_a2a.doctor` ran against this repository and exited 1 on its findings.

`mix ash_a2a.doctor` reads your compiled domains and resources and prints findings about
how they are wired for A2A. It starts no agents and sends no requests.

```
mix ash_a2a.doctor            # exits non-zero on any :error
mix ash_a2a.doctor --strict   # :warn is fatal too
mix ash_a2a.doctor --json     # JSON array instead of text
mix ash_a2a.doctor --domain MyApp.Agents   # repeatable; default: config :my_app, ash_domains
```

Each finding is `%{severity: :error | :warn | :info, code: atom, message: String.t(), fix: String.t()}`.
The pure core is `AshA2A.Doctor.diagnose/1`; its `:env` and `:loaded?` options replace
`Application.get_env(:ash_a2a, key)` and `Code.ensure_loaded?/1` for tests.

| Code | Severity | Meaning |
|---|---|---|
| `authenticated_caller_disabled` | error | `:require_authenticated_caller` is `false` |
| `mount_missing_auth` | warn | a domain mounts agents but declares no security scheme |
| `authority_broker_unset` | warn | consequence-bearing skills exist and `:authority_broker` is unset, so every such dispatch is refused |
| `consequential_skill_no_gate` | warn | consequence-bearing skills with authority gate `:open` |
| `card_mount_mismatch` | warn | the card endpoint uses a default mount no declared mount serves |
| `agent_name_missing`, `card_url_missing`, `no_a2a_skills` | warn | incomplete card identity or nothing exposed |
| `config_<key>_unset` | warn/info | `:receipt_binding_key`, `:standing_ledger_key` unset |
| `optional_dep_present` / `optional_dep_absent` | info | optional dependencies (`oban`, `ash_oban`, `ash_state_machine`, `postgrex`, `flame`, `durable_server`, `req_llm`) |

Limits: the doctor checks only the config keys listed above, not every key in
[configuration.md](../reference/configuration.md). It cannot see an auth plug you put in
front of a mount, so `mount_missing_auth` means "no declared scheme", not "no auth". It reads
the application env of the node that runs the task, which may differ from production.
Tests: `test/ash_a2a/doctor_test.exs`.
