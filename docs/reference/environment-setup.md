# Environment setup and verification

How to build the verification environment for ash_a2a from nothing, keep it
running, and run every proof. Everything here is scripted: nothing depends on
hand-installed pieces.

| File | Role |
| --- | --- |
| `scripts/env.sh` | Source it: puts the `.tool-versions` OTP and Elixir first on `PATH`, exports `LANG`/`LC_ALL=C.UTF-8`, `ELIXIR_ERL_OPTIONS=+fnu`, `MIX_ENV=test`. |
| `scripts/dev_env_setup.sh` | Installs and checks every component. Idempotent; `--quick` for a seconds-long check. |
| `scripts/verify_all.sh` | Runs every gate and prints one verdict line per gate. |
| `scripts/toolchain.sh` | Older entry point kept for existing docs and `bin/a2a-sim-mcp`; now a wrapper over `scripts/env.sh`. |

## Prerequisites

- Linux (the OTP build is fetched for `ubuntu-24.04`), root or passwordless
  sudo for `apt-get` and for the `postgres` OS user, `curl`, `git`, `python3`.
- Outbound HTTPS to the hosts listed under [Hosts](#hosts).
- About 3 GB of free disk for OTP, Elixir, Postgres, dependencies, the Rust
  `target/` directory and the parity venv.

## One-time setup

```bash
scripts/dev_env_setup.sh          # full mode, a no-op for what already exists
. scripts/env.sh                  # in every new shell, before any mix command
```

Full mode checks each component first and prints `present` for those that
exist, so re-running it is safe.

| Component | What it ensures |
| --- | --- |
| `apt` | `openssh-client` (the tests call `ssh-keygen`), `build-essential`, `libssl-dev`, `libncurses-dev`, `unzip`, `curl`, `git`, `git-lfs`, `ca-certificates`, `postgresql-16` (and `python3-venv` when the system Python cannot create venvs). |
| `otp` | Erlang/OTP at the version in `.tool-versions`, from `builds.hex.pm`, into `$PREFIX/otp/OTP-<version>`. The tarball is verified against the sha256 in `builds.hex.pm/builds/otp/ubuntu-24.04/builds.txt`, then `./Install -minimal`. |
| `elixir` | Elixir at the version in `.tool-versions`, zip from `builds.hex.pm`, verified against the sha256 in `builds.hex.pm/builds/elixir/builds.txt`, unzipped into `$PREFIX/elixir`. |
| `hex` | `mix local.hex --force`, `mix local.rebar --force`, and `mix deps.get` only when `mix deps` reports a missing dependency. |
| `postgres` | A PostgreSQL 16 cluster in `/var/lib/pgtest` (user `postgres`, password `postgres`, port 55432, `listen_addresses=localhost`, `max_connections=300`), initialized if absent and started if down. |
| `databases` | `ash_a2a_test` and `ash_a2a_test1` .. `ash_a2a_test20` (one per parallel `MIX_TEST_PARTITION`), then `mix ecto.create`. |
| `rust` | `cargo build --release --locked` for `native/hddl_cli` (binaries `hddl_cli` and `hddl_analyze` under its `target/release/`). `native/graphlaw_host` is built only with `--graphlaw`; its tests skip themselves when it is unbuilt. Installs rustup from `static.rust-lang.org` if `cargo` is missing; the pinned toolchain comes from `rust-toolchain.toml`. |
| `venv` | The parity venv via `scripts/a2a_v1_1_parity/setup.sh`. |
| `upstream` | Shallow clone of `a2aproject/a2a` with tags `v1.1.0-rc` and `v1.0.1` (`GIT_LFS_SKIP_SMUDGE=1`). |

Options: `--quick`, `--only a,b`, `--skip a,b`, `--graphlaw`, `--no-apt`.

Environment variables (all optional): `PREFIX` (install prefix, default `/opt`),
`PGDATA`, `PGPORT`, `PG_PASSWORD`, `PG_DB_COUNT`, `A2A_UPSTREAM_DIR`
(default `/home/user/a2aproject/a2a`), `A2A_PARITY_VENV` (default
`/tmp/a2a_v1_1_parity/venv`), `A2A_SETUP_DOWNLOAD_DIR`.

### Quick mode

```bash
scripts/dev_env_setup.sh --quick
```

Checks that `erl` and `mix` resolve under the prefix and that Postgres answers
on `localhost:55432`, starting it if it is down. It finishes in well under a
second when everything is up. Use it after a container restart.

## Ports

| Port | Used by |
| --- | --- |
| 55432 | Test Postgres (fixed in `config/test.exs`; a cluster on another port is created and left alone but `mix ecto.create` is skipped for it). |
| ephemeral | The simulation server (`mix ash_a2a.sim`, `bin/a2a-sim-mcp`) picks free ports for HTTP+JSON, JSON-RPC and gRPC; read them from `sim_info` or the task output. `bin/a2a-sim-mcp --http 4000` serves MCP on 4000. |

## Running the proofs

Run `. scripts/env.sh` first. Set `MIX_TEST_PARTITION=<n>` for any command
that touches the database.

| Proof | Command |
| --- | --- |
| Compile clean | `mix compile --warnings-as-errors` |
| Formatting | `mix format --check-formatted` |
| Simulation prover | `mix ash_a2a.sim --prove` |
| Byte-for-byte parity with the upstream v1.1.0-rc proto | `mix ash_a2a.sim --parity --strict` (needs the parity venv) |
| MCP surface | `python3 scripts/mcp_drive.py` |
| Mutation gate | `mix ash_a2a.chicago.mutate --require-killed` |
| Default test tier | `mix test` |
| CI test tier | `mix test.all` |

### verify_all.sh

```bash
scripts/verify_all.sh             # compile, format, prove, parity, mcp (quick tier)
scripts/verify_all.sh --tests     # plus mix test
scripts/verify_all.sh --full      # plus mix test.all
scripts/verify_all.sh --mutation  # plus the mutation gate
scripts/verify_all.sh --json      # one JSON object on stdout, progress on stderr
```

Each gate prints one line: name, `PASS`/`FAIL`/`SKIP`, seconds, command and the
log path. The exit status is non-zero when any gate fails; skips do not fail.

The mutation gate hot-loads mutated modules into this checkout's build while
it runs, so another `mix` process sharing the same `_build` can observe the
mutants. `verify_all.sh` therefore refuses to run it (verdict `SKIP`, with this
reason) unless `--mutation` is passed; combine `--mutation` with a private build
path.

Running next to other work: give the script its own build path so it does not
collide with other mix processes. The first run then compiles everything.

```bash
MIX_BUILD_PATH=/tmp/a2a_verify_build MIX_TEST_PARTITION=3 scripts/verify_all.sh
```

## Hosts

The setup needs these outbound hosts: `builds.hex.pm`, `repo.hex.pm`,
`hex.pm`, `github.com`, `pypi.org`, `files.pythonhosted.org`,
`static.crates.io`, `index.crates.io`, `static.rust-lang.org`, and the apt
mirrors of the distribution (for Ubuntu 24.04: `archive.ubuntu.com`,
`security.ubuntu.com`).

## Proposal: environment setup script (NOT APPLIED)

This section is a proposal for the environment owner. It has not been applied
to any environment; nothing in the repository applies it. If the owner wants
fresh containers to prepare themselves, the setup script below would be added
to the environment (it runs as root after the repositories are cloned and
before Claude starts, in the directory that holds the checkouts), together with
the host list from the previous section.

```bash
#!/usr/bin/env bash
set -euo pipefail
if [ -d ash_a2a ]; then
  (cd ash_a2a && scripts/dev_env_setup.sh)
fi
```

Notes for the owner: the first run takes several minutes (OTP and Elixir
downloads, a Rust build, venv creation) and is a fast no-op afterwards; use
`scripts/dev_env_setup.sh --skip rust,venv` for a lighter container. A
`SessionStart` hook that runs `scripts/dev_env_setup.sh --quick` is another
option (it restarts Postgres after a container restart); the owner can ask for
it. Neither is configured here.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Tests fail with `Real Postgres not reachable at localhost:55432/...` | Postgres is down (it does not survive a container restart). Run `scripts/dev_env_setup.sh --quick`, or by hand: `su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/pgtest -o '-p 55432 -c listen_addresses=localhost -c max_connections=300' -l /var/lib/pgtest/log -w start"`. If it will not start, read `/var/lib/pgtest/log`. |
| `mix: command not found` or a different Elixir/OTP | The shell has not sourced `scripts/env.sh`, or OTP/Elixir are not installed: run `scripts/dev_env_setup.sh --only otp,elixir`. |
| `database "ash_a2a_test<N>" does not exist` | Run `scripts/dev_env_setup.sh --only databases`. |
| MCP client reports a connect timeout for `a2a-sim` | `bin/a2a-sim-mcp` answers the handshake from `scripts/mcp_shim.py` while mix compiles in the background; a cold or stale build, or a missing `mix` on the launcher's `PATH`, delays the real server. Set `A2A_SIM_MCP_ENV` to a file that sources `scripts/env.sh`, warm the build with `mix compile`, and check the log named by `A2A_SIM_MCP_LOG`. |
| `hddl_cli` tests fail with a missing binary | Run `scripts/dev_env_setup.sh --only rust` (builds `native/hddl_cli/target/release/hddl_cli` and `hddl_analyze`). |
| `mix ash_a2a.sim --parity` cannot find the reference, or the venv is missing | Run `scripts/dev_env_setup.sh --only upstream,venv`. |
| `ssh-keygen` not found | Run `scripts/dev_env_setup.sh --only apt` (installs `openssh-client`). |
| `sha256 mismatch` during OTP or Elixir install | The download was altered or truncated; the file is deleted. Retry; if it persists, compare with `builds.txt` on `builds.hex.pm`. |
