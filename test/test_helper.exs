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

# SA2A: the `:graphlaw` tests really execute the real praxis-graphlaw wasm
# through a real `node` subprocess. On a machine without `node` or without the
# praxis wasm artifact they are excluded with a NAMED, PRINTED reason -- never
# silently substituted with a stubbed engine, which would defeat the only thing
# the conformance corpus exists to establish.
excluded_tags = [:external_api, :benchmark]

excluded_tags =
  case AshA2A.SA2A.Graphlaw.available?() do
    :ok ->
      excluded_tags

    {:unavailable, reason} ->
      IO.puts(
        :stderr,
        "[sa2a] EXCLUDING :graphlaw live-engine tests -- #{reason} " <>
          "(wasm: #{AshA2A.SA2A.Graphlaw.wasm_path()}). " <>
          "Corpus digest/expectation tests still run."
      )

      [:graphlaw | excluded_tags]
  end

# `:graphlaw_engine`: the tests tagged with it reach the real praxis-graphlaw
# wasm through the seven independently-resolved paths this library exposes
# (`GraphLaw.WasmDriver`, `GraphLaw.Wasm`, `GraphLaw.Runtime`,
# `Semantic.GraphLawBridge`, `Semantic.GraphLaw.Wasm`, `SA2A.Graphlaw`,
# `Semantic.RootManifest.EngineProbe`). Each of them now defaults to the
# vendored, git-tracked, MANIFEST-pinned `priv/graphlaw/praxis_graphlaw.wasm`
# (`AshA2A.GraphLaw.wasm_path/0`), so on any checkout with `node` on PATH this
# tag excludes NOTHING and all of those tests run. (ash_a2a#27's 103 hosted-CI
# failures were the seven resolvers defaulting to a `/Users/sac/praxis/...`
# path, not an absent engine; `AshA2A.Chicago.WasmDefaultResolutionTest` and
# `AshA2A.Chicago.FalsifierWasmDefaultReachabilityTest` now guard that.)
#
# Same contract as `:graphlaw` above, kept only as a fallback for a truly
# missing artifact or a missing `node`: the tagged tests are excluded with a
# NAMED, PRINTED reason -- never stubbed, never silently passed.
graphlaw_engine_missing =
  [
    {"GraphLaw.WasmDriver", AshA2A.GraphLaw.WasmDriver.wasm_path()},
    {"GraphLaw.Wasm", AshA2A.GraphLaw.Wasm.wasm_path()},
    {"GraphLaw.Runtime", AshA2A.GraphLaw.Runtime.wasm_path()},
    {"Semantic.GraphLawBridge", AshA2A.Semantic.GraphLawBridge.wasm_path()},
    {"Semantic.GraphLaw.Wasm", AshA2A.Semantic.GraphLaw.Wasm.wasm_path()},
    {"SA2A.Graphlaw", AshA2A.SA2A.Graphlaw.wasm_path()},
    {"RootManifest.EngineProbe", AshA2A.Semantic.RootManifest.EngineProbe.wasm_path()}
  ]
  |> Enum.reject(fn {_resolver, path} -> File.exists?(path) end)
  |> Enum.map(fn {resolver, path} -> "#{resolver} -> #{path}" end)
  |> then(fn missing ->
    if System.find_executable("node") == nil, do: ["node not on PATH" | missing], else: missing
  end)

excluded_tags =
  if graphlaw_engine_missing == [] do
    excluded_tags
  else
    IO.puts(
      :stderr,
      "[graphlaw_engine] EXCLUDING :graphlaw_engine tests -- real engine unreachable: " <>
        Enum.join(graphlaw_engine_missing, "; ")
    )

    [:graphlaw_engine | excluded_tags]
  end

# `:sibling_repos`: tests that assert the real 11-repo topology of the author's
# workstation (`AshA2A.Chicago.Courts.SA2AV269_17Topology`, root defaults to
# `/Users/sac`). A hosted CI runner has none of those checkouts. Excluded, by
# name and printed, when any of the 11 is absent -- never stubbed.
sibling_repos_missing =
  AshA2A.Chicago.Courts.SA2AV269_17Topology.repos()
  |> Enum.map(fn {_object, dir, _capability, _critical?} ->
    AshA2A.Chicago.Courts.SA2AV269_17Topology.repo_path(dir)
  end)
  |> Enum.reject(&File.exists?(Path.join(&1, ".git")))

excluded_tags =
  if sibling_repos_missing == [] do
    excluded_tags
  else
    IO.puts(
      :stderr,
      "[sibling_repos] EXCLUDING :sibling_repos tests -- #{length(sibling_repos_missing)} of " <>
        "#{length(AshA2A.Chicago.Courts.SA2AV269_17Topology.repos())} sibling repos absent " <>
        "under #{AshA2A.Chicago.Courts.SA2AV269_17Topology.root()}."
    )

    [:sibling_repos | excluded_tags]
  end

ExUnit.configure(exclude: excluded_tags)

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
