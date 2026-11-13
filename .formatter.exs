# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Used by "mix format", in the same shape as the ash family (deps/ash,
# deps/ash_graphlaw): Spark DSL imports, the Spark.Formatter plugin, and the
# `a2a` DSL's call-shaped entities formatted without parentheses -- exported
# so every project that `import_deps: [:ash_a2a]` (what `mix ash_a2a.install`
# wires) formats `skill :name, :action` parensless too.
spark_locals_without_parens = [
  add_effects: 1,
  argument: 2,
  argument_mapping: 1,
  base_url: 1,
  consequence: 1,
  default_mount: 1,
  delete_effects: 1,
  description: 1,
  documentation_url: 1,
  expose?: 1,
  gate: 1,
  get?: 1,
  hddl_operator: 1,
  hddl_operators: 1,
  icon_url: 1,
  lease_duration_ms: 1,
  lease_required?: 1,
  mount: 1,
  name: 1,
  on_cancel: 1,
  parameters: 1,
  post_dispatch: 1,
  pre_dispatch: 1,
  preconditions: 1,
  provider: 1,
  push_notifications: 1,
  requirements: 1,
  security_scheme: 2,
  semantic_requests: 1,
  skill: 2,
  skill: 3,
  skill: 4,
  streaming: 1,
  tags: 1,
  url: 1,
  version: 1
]

[
  import_deps: [:ash, :spark],
  plugins: [Spark.Formatter],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
