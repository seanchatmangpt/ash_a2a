# How to enable the semantic-compilation A2A surface

This guide wires the v26.9.14 explicit semantic-request surface onto a resource, so a
caller can send free text instead of a `:skill`-targeted message and have it real-compile
through the semantic-closed-loop pipeline (`Source -> SemanticIR -> Admission -> Ontology
-> PlanningIR -> SemanticSynthesis -> ExecutionPackage`). It is based directly on the
working end-to-end test `test/ash_a2a_agent_semantic_request_test.exs` and the real
dispatch code in `lib/ash_a2a/agent.ex` — every snippet below matches that real code.

This is deliberately **not** a silent fallback for an unrecognized skill name or
arbitrary free text. Two independent real gates must both be true before a dispatch ever
reaches the semantic compiler; a message missing either gate falls straight through to
the ordinary skill-resolution path exactly as if this feature did not exist.

## Gate 1: the resource opts in via the DSL

Add `semantic_requests(true)` inside the `a2a do ... end` block. It defaults to `false`,
so nothing changes for an existing resource unless it declares this explicitly:

```elixir
defmodule MyApp.Workflow do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    semantic_requests(true)
    skill(:probe, :read)
  end
end
```

This is real, compiled capability truth, not a runtime check: `semantic_requests(true)`
is persisted by `AshA2A.Transformers.BuildCapabilityIndex` at compile time and read back
via `AshA2A.Info.semantic_requests_enabled?/1`:

```elixir
AshA2A.Info.semantic_requests_enabled?(MyApp.Workflow)
#=> true

AshA2A.Info.semantic_requests_enabled?(MyApp.SomeOtherResourceThatNeverOptedIn)
#=> false
```

A `skill(...)` declaration (here, `:probe`) is still required if you want the ordinary
skill-resolution fallback to have something unambiguous to dispatch to for a ordinary,
unflagged message — `semantic_requests` only adds a second route, it does not replace the
existing one.

## Gate 2: the caller's message sets the `semantic_request` flag

A caller opts an individual message into the semantic surface by setting
`:semantic_request`/`"semantic_request"` to `true` in the outbound `A2A.Message`'s
`metadata`, and must send real text in a `A2A.Part.Text` part (the compiler has nothing
to compile otherwise):

```elixir
message = %A2A.Message{
  role: :user,
  parts: [A2A.Part.Text.new("advance the admitted workflow")],
  metadata: %{semantic_request: true}
}

{:ok, task} = MyApp.WorkflowAgent.call(MyApp.WorkflowAgent, message)
```

`metadata` follows the same atom-then-string caller-facing convention every other A2A
metadata key in this codebase uses (`AshA2A.MetadataKey.get/2`, the same helper
`:skill` metadata resolution already uses) — `%{semantic_request: true}` and
`%{"semantic_request" => true}` are both read correctly.

## What actually happens when both gates are true

`AshA2A.Agent.__dispatch__` checks both gates (`AshA2A.Info.semantic_requests_enabled?/1`
on the target resource/domain, and the message's `:semantic_request` metadata) before
choosing a route:

* **Either gate false** → falls straight through to the ordinary skill-resolution
  dispatch path (`dispatch_skill/4`) — the message is treated exactly as it would be if
  `semantic_requests` had never been declared.
* **Both gates true** → routes to `dispatch_semantic/2`, which pulls the message's real
  text via `A2A.Message.text/1` and calls `AshA2A.Semantic.Compiler.compile/3` for real.
  * No text part on the message → `{:error, %{code: :semantic_request_missing_text}}`,
    refused closed before any compilation is attempted.
  * `Compiler.compile/3` genuinely calls the configured `:semantic_reasoner` LLM role
    (`AshA2A.LLMProfiles.model_spec!/1`, which `raise`s `ArgumentError` on a misconfigured
    role) — `dispatch_semantic/2` wraps this in a real `rescue` so a misconfigured LLM
    profile, or any other real compilation failure, becomes a typed
    `{:error, %{code: :semantic_compilation_failed, detail: ...}}` reply instead of
    crashing the shared `A2A.Agent` GenServer process (which would otherwise terminate
    every other in-flight task that process is managing, not just this one request).
  * A successful compile produces a real `AshA2A.Semantic.ExecutionPackage`, converted to
    a reply by `to_reply/1` (see below).

There is no free-text content sniffing anywhere in this path: an unflagged message on an
opted-in resource, and a flagged message on a resource that never opted in, both take the
identical ordinary skill-resolution route real dispatch has always taken.

## The real reply shape

`AshA2A.Semantic.ExecutionPackage.to_reply/1` converts an admitted package into the same
`AshA2A.Dispatcher.reply()` tuple contract every other dispatch path returns — one
`{:reply, [%A2A.Part.Data{}]}` (or `{:error, reason}`) shape regardless of which real path
produced it. For a successful compile, the `A2A.Part.Data` body carries exactly these
fields (read directly from `to_reply/1` — nothing here is invented):

```elixir
%{
  "execution_package_fingerprint" => package.fingerprint,
  "standing" => "candidate",
  "authority" => "none",
  "request_id" => Map.get(candidate.plan, "request_id"),
  "capability_ids" => candidate.capability_ids,
  "hddl" => Map.get(synthesis, "hddl"),
  "fond" => Map.get(synthesis, "fond"),
  "rationale" => Map.get(synthesis, "rationale")
}
```

* `"standing"` is always `"candidate"` and `"authority"` is always `"none"` — this reply
  can never be mistaken for a `DO` receipt. Nothing was executed; the semantic surface
  only compiles and synthesizes a plan candidate.
* `"capability_ids"` is the set of real capability ids `SemanticSynthesis.synthesize/4`
  re-admitted against the canonical `AshA2A.Info` capability index — never the model's own
  unverified claim about what it can call.
* `"execution_package_fingerprint"` is the package's own content-addressed fingerprint. A
  caller can present it back to `AshA2A.Semantic.Compiler.replan/4` as a continuation for
  the same candidate lineage.
* A package that somehow reaches `to_reply/1` without `standing: :candidate,
  authority: :none` (the fenced invariant `ExecutionPackage.new/6` enforces at
  construction) is refused with
  `{:error, %{code: :semantic_package_authority_ceiling_violated}}` rather than ever
  being handed to a caller.

## Verifying it end to end

The real, working proof of all of the above is
`test/ash_a2a_agent_semantic_request_test.exs`, run against a real supervised
`A2A.Agent` process with no injected `generate_object` seam on this path (unlike
`AshA2A.Semantic.Compiler`'s test-only injectable seam used elsewhere — this production
entrypoint genuinely calls the configured LLM role every time, by design). In this
repository's own unmodified test environment (no reachable/authorized LLM endpoint for
the semantic role), the "both gates true" case fails closed with a real, typed
`:semantic_compilation_failed` reply and the agent process is still alive and serving
immediately afterward — proving a refusal, not a crash.
