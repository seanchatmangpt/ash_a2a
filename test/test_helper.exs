ExUnit.start(exclude: [:external_api, :benchmark])

# A real, run-wide `AshA2A.Authority.Broker.InMemory` process, started once
# here and configured in `config/test.exs` as this suite's
# `:authority_broker`.
#
# Since `AshA2A.Authority.Grant`'s fail-closed `:broker` policy became the
# default, a transport-authenticated caller no longer holds authority for a
# `:change`/`:external_do` capability just by being authenticated
# (RFC-SA2A-001 S29) -- a real standing grant must exist. Tests that dispatch
# such a skill issue their own real grants into this broker via
# `AshA2A.Test.AuthorityGrantCase.grant!/1`.
#
# Deliberately one shared broker rather than a per-test one: grants are keyed
# on `AshA2A.Authority.grant_token_id/2`, i.e. on `(principal,
# capability_id)`, so two test modules granting different principals cannot
# collide, and no test needs to mutate the `:authority_broker` application
# environment at runtime (which would race across `async: true` modules).
# A test that specifically needs isolated grant/revocation state -- e.g.
# `test/ash_a2a_authority_capability_grant_test.exs`, which revokes -- starts
# its own uniquely-named broker and is `async: false`.
{:ok, _authority_broker} = AshA2A.Authority.Broker.InMemory.start_link([])

# A2A-2601: point the receipt outbox at a fresh per-run directory so tests
# that exercise the outbox never read (or opportunistically reconcile) a
# previous run's journal entries from the default OS-tmp location.
Application.put_env(
  :ash_a2a,
  :receipt_outbox_dir,
  Path.join(
    System.tmp_dir!(),
    "ash_a2a_receipt_outbox_test_#{System.unique_integer([:positive])}"
  )
)
