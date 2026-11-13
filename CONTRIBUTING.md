# Contributing to AshA2A

Thanks for helping. Issues and pull requests are welcome at
<https://github.com/seanchatmangpt/ash_a2a>. Participation is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md). Report security issues as described in
[SECURITY.md](SECURITY.md), not in public issues.

## Setup

- Elixir `~> 1.19` and Ash `~> 3.0` (the exact toolchain is in `.tool-versions`).
- Fetch dependencies: `mix deps.get`.
- Build the native planner binary once (needed by part of the test suite):

  ```sh
  cd native/hddl_cli && cargo build --release --locked && cd -
  ```

- Postgres 16 on `localhost:55432` (see `config/test.exs`) is needed by the Oban
  delivery tests.

Details, including known-flaky tests: [Testing ash_a2a](docs/how-to/test-your-ash_a2a-app.md).

## Running tests

- `mix test` — fast default tier.
- `mix test.all --max-cases 6` — the full suite, as CI runs it.
- `mix format --check-formatted` and `mix compile --warnings-as-errors` before pushing.

Tests use real collaborators (real processes, real transports, real stores) rather
than mocks. Please follow that style: assert on resulting state, not call counts.

## Pull requests

- Keep changes focused; one concern per PR.
- Add or update tests with the change, and update docs under `docs/` when behavior
  changes. Docs follow [Diataxis](https://diataxis.fr/) and are indexed in
  `docs/README.md`.
- Add a user-facing bullet under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md)
  (Added / Changed / Fixed / Security).
- Do not edit generated files by hand; change the source model and regenerate.
- Merge, do not rebase or force-push, shared branches.

## License

By contributing you agree that your contributions are licensed under the MIT license
in [LICENSE](LICENSE).
