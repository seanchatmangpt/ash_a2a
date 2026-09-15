ExUnit.start(exclude: [:external_api])

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
