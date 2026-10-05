# SPDX-Static: n/a
#
# Credo configuration for ash_a2a's `mix credo --strict` gate stage
# (see .check.exs). Started from the ash-project's own .credo.exs, trimmed
# to the non-noisy set: checks that misfire on this codebase (sigil-heavy
# code, Mix task plumbing, large guard-heavy modules) are `false` here,
# same as upstream ash keeps its own noise disables.
#
# Run:   mix credo --strict
#
# SPDX: see mix.exs header.

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "mix.exs", ".check.exs"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      # 120 cols like the formatter; ash uses the same ceiling.
      parse_timeout: 5000,
      color: true,
      checks: [
        #
        ## Consistency
        #
        {Credo.Check.Consistency.ExceptionNames, []},
        {Credo.Check.Consistency.LineEndings, []},
        {Credo.Check.Rules.DirectoryTestExclusion, false},
        {Credo.Check.Consistency.ParameterPatternMatching, []},
        # Disabled for the same real reason ash disables it: this check
        # misparses sigil-heavy code (this repo's RDF/graph code is sigil-heavy).
        {Credo.Check.Consistency.SpaceAroundOperators, false},
        {Credo("{Credo.Check.Consistency.SpaceInParentheses, []},