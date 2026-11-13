# DSL Reference

The `AshA2A` Spark extension contributes three top-level DSL sections,
`a2a`, `authority` and `hooks` (`AshA2A.Dsl.sections/0`), usable on an
`Ash.Resource`, an `Ash.Domain`, or both. The schema below is the
authoritative surface defined in `AshA2A.Dsl` (`lib/ash_a2a/dsl.ex`).

## The zero-declaration default

The `a2a` section is entirely optional. Every **public** Ash action on an
extended resource or domain is projected into the capability index as a
skill with id `"<Resource>.<action>"` (or `"<Domain>.<action>"`),
introspected arguments, and a consequence classification derived from the
action type (see the table under `skill` below). The `skill` entity exists
to *override* projection metadata for one action — it cannot expose an
action that is not public, does not exist, or is excluded.

## Section `a2a`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `semantic_requests` | `boolean` | `false` | Opts this resource/domain into the semantic-compilation surface (`AshA2A.Semantic.Compiler`). Dual-gated: dispatch reaches the compiler only when this is `true` **and** the caller's message metadata sets `:semantic_request`/`"semantic_request"` to `true`. Never a silent fallback for unrecognized skill names or free text. See [Enable semantic requests](../how-to/enable-semantic-requests.md). |

## Entity `skill`

Args: `skill :name, :action` on a resource, or
`skill :name, Resource, :action` on a domain. Identifier: `:name`
(duplicate names fail compilation with `:REFUSED_DUPLICATE_SKILL_NAME`).

| Option | Type | Req/Default | Description |
| --- | --- | --- | --- |
| `name` | `atom` | required | A2A display/selector name override for the referenced public Ash action. |
| `resource` | `{:spark, Ash.Resource}` | optional | Target resource. Required on a domain; implicit on a resource. |
| `action` | `atom` | required | Canonical public Ash action to override. |
| `description` | `string` | optional | A2A-only description override. |
| `tags` | `{list, string}` | optional | A2A-only tags override. |
| `expose?` | `boolean` | default `true` | Whether this otherwise-public action is exposed through A2A. Set `false` to exclude it. |
| `consequence` | `one_of [:observe, :change, :external_do, :unknown]` | optional | Explicit consequence classification. Required to lift a generic `:action` skill off the fail-closed `:unknown` default; no effect on `:read`/`:create`/`:update`/`:destroy` unless deliberately overriding. |
| `on_cancel` | `module` or `{m, f, a}` | optional | Ash-side compensation hook run by `AshA2A.Agent` when a task under this skill is genuinely canceled. A bare module must implement `c:AshA2A.OnCancel.on_cancel/3`; an MFA is called with `[exec_context, task_id, context_id | extra_args]`. Unset leaves cancellation telemetry-only. |
| `argument_mapping` | `{:map, :string, :atom}` | default `%{}` | Wire (string) argument name to action argument atom. Empty means pass-through. Enforced (see below). |
| `get?` | `boolean` | default `false` | Declares a read skill a single-record get. |
| `lease_required?` | `boolean` | default `false` | Declares that dispatch under this skill requires an authority lease. |
| `examples` | `{list, string}` | optional | AgentSkill `examples` (example prompts). Projected onto the card skill. |
| `input_modes` | `{list, string}` | optional | AgentSkill `inputModes` (MIME types). Overrides the agent `default_input_modes`. |
| `output_modes` | `{list, string}` | optional | AgentSkill `outputModes` (MIME types). Overrides the agent `default_output_modes`. |
| `security_requirements` | `{list, {:map, :string, {:list, :string}}}` | optional | AgentSkill `securityRequirements`: `[%{"scheme" => ["scope"]}]`. Keys must name a domain `security_scheme`. |
| `streaming?` | `boolean` | default `false` | Declares the skill as streaming. Metadata only (see below). |

### Enforced vs declared-only

`AshA2A.CapabilityIndex.Compiler.project/3` copies `name`, `description`,
`tags`, `consequence`, `hddl_operators`, `on_cancel`, `argument_mapping`,
`get?`, `lease_required?`, `examples`, `input_modes`, `output_modes`,
`security_requirements` and `streaming?` from an override into the compiled
`AshA2A.Skill`; `expose?: false` drops the action.

| Option | Compile-time effect | Runtime effect |
| --- | --- | --- |
| `argument_mapping` | `AshA2A.Verifiers.VerifySkills` refuses a target that is not in `action.arguments` or `action.accept` (`refused_argument_mapping_target`, path `[:a2a, <skill>, :argument_mapping]`). | Enforced in two places: `AshA2A.Executor.execute/3` renames inbound string wire keys to the mapped atom argument names before the Ash action runs (`executor.ex:239-252`; an `:argument_mapping` opt overrides the skill's, absent wire keys are left alone, no atoms are created from wire input); `AshA2A.Schema.for_skill/2` projects the mapped string keys as the wire argument names (`schema.ex:140`). `AshA2A.Dispatcher` has no reference to it. |
| `get?` | None. | Metadata only: copied onto the skill; nothing in `lib/` branches on the flag. |
| `lease_required?` | `VerifySkills` refuses `true` when the subject has no authorizer (`refused_lease_required_no_authorizer`). | Compile-time only; not read at dispatch. |
| `consequence` | `observe` on `:create`/`:update`/`:destroy` is refused (`observe_on_mutating_action`). | Compiled into the skill; drives admission. |
| `input_modes`, `output_modes` | `VerifySkills` refuses an entry that is not a MIME type (`refused_mode_not_mime`, path `[:a2a, <skill>, :input_modes \| :output_modes]`). | Projected onto the card skill by `AgentCardBuilder`. |
| `security_requirements` | On a domain subject, `VerifySkills` refuses a key that names no declared `security_scheme` (`refused_security_requirement_undeclared`). A resource-level skill cannot see the domain's schemes at compile time and is not checked. | Projected onto the card skill. |
| `examples` | None. | Projected onto the card skill. |
| `streaming?` | None. | Metadata only. Dispatch streams a `:read` skill only on the caller's per-call `"stream" => true`; enumerable results of a generic action are not streamed. |

### Consequence defaults (when `skill` is not declared)

| Ash action type | Compiled `consequence` |
| --- | --- |
| `:read` | `:observe` |
| `:create`, `:update`, `:destroy` | `:change` |
| generic `:action` | `:unknown` — **refused** (`:consequence_unclassified`) on the default agent path and in `CommandBus.admit/2` until explicitly classified |

### Nested entity `argument` (deprecated)

`skill ... do argument :name, :type end` is accepted for source
compatibility with pre-v26.9.12 declarations and **deliberately ignored**:
real arguments are derived from `Ash.Resource.Info` introspection.

### Nested entity `hddl_operator`

Declares this skill's HDDL operator for the deterministic, non-LLM
planning path (identifier auto-generated as a unique integer).
`AshA2A.Verifiers.VerifyHddlOperators.check/2` (called per skill by
`AshA2A.Verifiers.VerifySkills`, not a separate verifier) refuses at
compile time: more than one `hddl_operator` on a skill
(`refused_hddl_multiple_operators`), and any `preconditions`,
`add_effects` or `delete_effects` fact whose args are not among the
operator's declared `parameters` (`refused_hddl_fact_args`). Both errors
use path `[:a2a, <skill>, :hddl_operator]`.

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `parameters` | `{list, atom}` | `[]` | Ordered HDDL parameter variable names. |
| `preconditions` | `{list, {:tuple, [:atom, {:list, :atom}]}}` | `[]` | Facts required before this operator, as `{predicate, args}` tuples. |
| `add_effects` | same shape | `[]` | Facts asserted true after the operator runs. |
| `delete_effects` | same shape | `[]` | Facts retracted after the operator runs. |

## Section `authority`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `gate` | `one_of [:two_port, :open, :disabled]` | `:two_port` | Default admission gate for consequence-bearing actions. |
| `lease_duration_ms` | `pos_integer` | `60_000` | Default lease lifetime in milliseconds. |

Decision (W11): both options are kept as declared; no behavior was added.

- `gate`: **partly enforced.** `AshA2A.Dispatcher` reads
  `AshA2A.Info.authority_gate/1` and, for `:disabled`, refuses every
  consequence-bearing (anchored) skill with `:authority_gate_disabled`.
  `:two_port` and `:open` leave the sole-DO anchor and kernel fence as the
  gate, so they differ only as declarations. `AshA2A.Verify` additionally
  fails compilation when a skill override has `consequence: :change` or
  `:external_do` and `gate` is `:open` or `:disabled`.
- `lease_duration_ms`: **declared-only.** Persisted
  (`:ash_a2a_lease_duration_ms`) and readable via
  `AshA2A.Info.lease_duration_ms/1`; no dispatch code reads it.
- `AshA2A.Verify.inert_section_warnings/1` (`verify.ex`) still emits a
  compile-time warning for a non-default `gate` or `lease_duration_ms`
  ("declared but not enforced"). For `gate: :disabled` that wording is
  stale given the dispatcher behavior above (`verify.ex` is outside lane W11).

## Section `hooks`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `pre_dispatch` | `{list, atom}` | `[]` | GraphLaw hook identifiers to run before dispatch. |
| `post_dispatch` | `{list, atom}` | `[]` | GraphLaw hook identifiers to run after execution. |

Decision (W11): kept; behavior documented. `AshA2A.Dispatcher` reads
`AshA2A.Info.hooks/1` and resolves each identifier through
`config :ash_a2a, :dispatch_hooks, %{id => {Module, :fun}}`. The function
receives `%{phase, skill_id, message, reply}` and returns `:ok | {:error, reason}`.
An unresolvable `pre_dispatch` id fails the dispatch closed; a `post_dispatch`
failure is logged. `AshA2A.Verify` still emits a "declared but not enforced"
compile-time warning for a non-empty hooks list (`verify.ex`, outside lane W11),
which is stale against the dispatcher.

## Generic-action return contract

A generic `:action` skill may return (via `Ash.run_action/2`):

| Return | Dispatch reply |
| --- | --- |
| `{:ok, {:input_required, parts}}` | `{:input_required, parts}` |
| `{:ok, {:auth_required, parts}}` | `{:error, {:auth_required, parts}}` (passed through untagged; the runtime maps it to `auth-required`) |
| `{:ok, %AshA2A.Artifacts{artifacts: [...]}}` | `{:reply, parts}` with all artifact parts flattened in order |
| anything else | one `Part.Data` as before |

`parts` must be a non-empty list of `AshA2A.Protocol.Part` structs, otherwise
the value is treated as an ordinary result.

## Domain extension (`AshA2A.Domain`)

Agent-card configuration is declared on the domain. Additions:

- `agent`: `default_input_modes`, `default_output_modes` (MIME lists; the card
  builder prefers them, falling back to `["text/plain"]`), `sign_card` (key
  reference; declared and persisted only, signing is performed by the plug).
- `security_scheme`: kinds `:bearer`, `:api_key`, `:none`, `:http`, `:oauth2`,
  `:openid_connect`, `:mtls` with options `location`, `param_name`,
  `http_scheme`, `bearer_format`, `oauth_flows` (map passed through to
  `AshA2A.Protocol.SecurityScheme.OAuth2`), `scopes`, `openid_url`. `:http`
  requires `http_scheme`, `:oauth2` requires `oauth_flows`, `:openid_connect`
  requires `openid_url`.
- `security`: `requirement_scopes` (requirement name to scopes; keys must be in
  `requirements`) feeds the card's `security` scopes.
- `transport`: `extension uri, description:, required:, params:` entity (unique
  uri; merged into `capabilities.extensions`), `extended_agent_card` (sets
  `capabilities.extendedAgentCard`), `push_allowed_hosts` and `push_retry`
  (declared and persisted; read through `AshA2A.Domain.Info.push_allowed_hosts/1`
  and `push_retry/1` by the push modules).
- `mount`: `tenant` and `protocol_version` ride on the mount's
  supportedInterfaces entry.

## Compile-time verification

`AshA2A.Verify` runs fail-closed after `AshA2A.Transformers.BuildCapabilityIndex`:

- `:REFUSED_ACTION_NOT_FOUND` — an override names an action that does not
  exist on the target resource.
- `:REFUSED_ACTION_NOT_PUBLIC` — an override names an action that is not
  public.
- `:REFUSED_DUPLICATE_SKILL_NAME` — two overrides share one `name` on the
  same subject.
- `refused_argument_mapping_target`, `refused_type_not_json_serializable`,
  `refused_lease_required_no_authorizer` — `AshA2A.Verifiers.VerifySkills`.
- `refused_hddl_multiple_operators`, `refused_hddl_fact_args` —
  `AshA2A.Verifiers.VerifyHddlOperators` (via `VerifySkills`).
- `observe_on_mutating_action` — `BuildCapabilityIndex` transformer.
- `authority.gate` `:open`/`:disabled` with a `:change`/`:external_do`
  skill — `AshA2A.Verify`.

The transformer persists the residual overrides (plus subject kind and the
`semantic_requests` flag) as compile-time DSL data; the capability index
itself is derived on demand from `Ash.Resource.Info.public_actions/1` —
there is no persisted `:ash_a2a_capability_index` key (that was pre-v26.9.12
design).
