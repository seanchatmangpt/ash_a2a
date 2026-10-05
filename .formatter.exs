# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/ash-project/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Used by "mix format", in the same shape as the ash family (deps/ash,
# deps/ash_graphlaw): Spark DSL imports, the Spark.Formatter plugin, and the
# `a2a` DSL's call-shaped entities formatted without parentheses -- exported
# so every project that `import_deps: [:ash_a2a]` (what `mix ash_a2a.install`
# wires) formats `skill :name, :action` parensless too.
spark_locals_without_parens = [
  argument: 2,
  hddl_operator: 1,
  skill: 2,
  skill: 3,
  skill: 4
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
