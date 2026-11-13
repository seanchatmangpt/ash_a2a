# Reproducing the v26.9.18 Stack

Version: v26.9.18. Order: ash_a2a, then beam4pm, then ferroplan.

## 1. ash_a2a

```sh
cd ash_a2a
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test --max-cases 1
```

## 2. beam4pm (depends on ash_a2a and ferroplan)

```sh
cd beam4pm
git submodule update --init --recursive
source scripts/env/rust4pm_reactor_env.sh   # exports RF3_ORACLE_BIN
just verify
```

`RF3_ORACLE_BIN` must point at the built `rf3-ocel-oracle` binary
(`native/rf3-ocel-oracle/target/release/rf3-ocel-oracle`); build it with
`cargo build --release` in that directory first.

## 3. ferroplan (native/ferroplan submodule of beam4pm)

```sh
cd beam4pm/native/ferroplan
cargo test
```

The submodule pin is recorded in beam4pm's git tree; check it with
`git submodule status`.
