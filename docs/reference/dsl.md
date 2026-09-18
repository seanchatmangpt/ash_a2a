# DSL Reference

The `AshA2A` Spark extension contributes one top-level DSL section, `a2a`,
usable on an `Ash.Resource`, an `Ash.Domain`, or both. The schema below is
the authoritative surface defined in `AshA2A.Dsl` (`lib/ash_a2a/dsl.ex`).

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
planning path (identifier auto-generated as a unique integer):

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `parameters` | `{list, atom}` | `[]` | Ordered HDDL parameter variable names. |
| `preconditions` | `{list, {:tuple, [:atom, {:list, :atom}]}}` | `[]` | Facts required before this operator, as `{predicate, args}` tuples. |
| `add_effects` | same shape | `[]` | Facts asserted true after the operator runs. |
| `delete_effects` | same shape | `[]` | Facts retracted after the operator runs. |

## Compile-time verification

`AshA2A.Verify` runs fail-closed after `AshA2A.Transformers.BuildCapabilityIndex`:

- `:REFUSED_ACTION_NOT_FOUND` — an override names an action that does not
  exist on the target resource.
- `:REFUSED_ACTION_NOT_PUBLIC` — an override names an action that is not
  public.
- `:REFUSED_DUPLICATE_SKILL_NAME` — two overrides share one `name` on the
  same subject.

The transformer persists the residual overrides (plus subject kind and the
`semantic_requests` flag) as compile-time DSL data; the capability index
itself is derived on demand from `Ash.Resource.Info.public_actions/1` —
there is no persisted `:ash_a2a_capability_index` key (that was pre-v26.9.12
design).
