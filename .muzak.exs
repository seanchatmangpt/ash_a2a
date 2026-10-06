# Mutation testing over ash_a2a's security-critical auth/verify surface.
#
# Run:  MIX_ENV=test mix muzak.sec              # full surface, full oracle
#       MIX_ENV=test mix muzak.sec --mutations 25   # bounded sample
# Scoping the oracle to the matching courts (recommended, hours -> minutes):
#       MUZAK_TEST_PATHS=test/ash_a2a/protocol/plug MIX_ENV=test mix muzak.sec
#
# muzak 1.1.1 (2022-12, unmaintained) predates Elixir 1.15+'s Inspect.Algebra
# doc-AST change, the vsn-29 Mix compile manifest, and the modern
# ExUnit.Server state shape -- it crashes at each of those on Elixir 1.19.
# Before muzak reads this file it re-compiles the two compatibility shims in
# `.muzak/` over the dep's broken modules (see .muzak/*.ex headers), so the
# hex dep stays stock and nothing is vendored into the package.
Code.put_compiler_option(:ignore_module_conflict, true)

:code.purge(Muzak.Code.Formatter)
:code.delete(Muzak.Code.Formatter)
Code.compile_file(".muzak/formatter_shim.ex")

:code.purge(Muzak.Runner)
:code.delete(Muzak.Runner)
Code.compile_file(".muzak/runner.ex")

# The security-critical surface. muzak's `mutation_filter` opt is a 1-arity
# function over the candidate file list; it must return [{path, lines}]
# tuples (returning plain strings crashes Muzak.Mutations.read_file/1 --
# verified empirically).
sec_files = [
  "lib/ash_a2a/transport/plug.ex",
  "lib/ash_a2a/protocol/plug/auth.ex",
  "lib/ash_a2a/protocol/plug/security_validators.ex",
  "lib/ash_a2a/protocol/plug/jwt_verifier.ex",
  "lib/ash_a2a/protocol/card_signing.ex",
  "lib/ash_a2a/protocol/push_notification_sender/http.ex"
]

%{
  default: [
    mutations: 1_000,
    mutation_filter: fn files ->
      files
      |> Enum.filter(&(&1 in sec_files))
      |> Enum.map(&{&1, nil})
    end
  ]
}
# Oracle = the matching security courts. muzak requires ALL files under
# `:test_paths` for every mutant, so the honest full-court oracle is the
# whole `test/` tree (hours). For bounded per-module runs scope it:
#   MUZAK_TEST_PATHS=test/ash_a2a/protocol/plug MIX_ENV=test mix muzak.sec
#
# Profiles: add a named key (e.g. auth: [...]) to .muzak.exs and select with
# `--profile auth` to mutate one module at a time.
