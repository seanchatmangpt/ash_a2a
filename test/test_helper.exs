ExUnit.start(exclude: [:external_api, :benchmark])

# SA2A: the `:graphlaw` tests really execute the real praxis-graphlaw wasm
# through a real `node` subprocess. On a machine without `node` or without the
# praxis wasm artifact they are excluded with a NAMED, PRINTED reason -- never
# silently substituted with a stubbed engine, which would defeat the only thing
# the conformance corpus exists to establish.
case AshA2A.SA2A.Graphlaw.available?() do
  :ok ->
    :ok

  {:unavailable, reason} ->
    IO.puts(
      :stderr,
      "[sa2a] EXCLUDING :graphlaw live-engine tests -- #{reason} " <>
        "(wasm: #{AshA2A.SA2A.Graphlaw.wasm_path()}). " <>
        "Corpus digest/expectation tests still run."
    )

    ExUnit.configure(exclude: [:external_api, :benchmark, :graphlaw])
end

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
