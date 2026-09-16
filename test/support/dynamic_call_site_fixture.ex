defmodule AshA2A.Providers.NeverCalled do
  @moduledoc """
  Real, test-only module in the `AshA2A.Providers.*` namespace
  `AshA2A.Semantic.Conformance.llm_module?/1` treats as LLM-bearing.

  It exists so `AshA2A.Test.DynamicCallSiteFixture` can carry a *real*
  literal call to an LLM-classified module (rather than a call to a
  non-existent one, which would compile with a warning and prove nothing
  about a module that can actually be reached). Nothing calls `run/1`; the
  point is the call site in the compiled AST, not the behaviour.
  """

  @doc false
  def run(value), do: value
end

defmodule AshA2A.Test.DynamicCallSiteFixture do
  @moduledoc """
  Real compiled module carrying the three call-site shapes
  `AshA2A.Semantic.Conformance.remote_call_targets/1` cannot see, used by
  `test/ash_a2a/semantic_conformance_dynamic_call_sites_test.exs`.

  This is a real module compiled to a real `.beam` with real abstract code,
  not a fabricated AST handed to the analyser: the test reads it back through
  `:beam_lib` exactly as the production DO-path scan reads `AshA2A.CommandBus`.

  `literal_llm_call/0` reaches an `AshA2A.Providers.*` module by literal
  name, so `remote_call_targets/1` sees it. The other three reach the same
  module through a runtime value, so it sees nothing at all -- which is the
  whole point.
  """

  @doc "Reachable by static analysis: the module is an atom literal."
  def literal_llm_call, do: AshA2A.Providers.NeverCalled.run(:noop)

  @doc "Invisible to static analysis: the module is a variable."
  def variable_module_call(module), do: module.run(:noop)

  @doc "Invisible to static analysis: `apply/3` with a computed module."
  def dynamic_apply_call(module), do: apply(module, :run, [:noop])

  @doc "Invisible to static analysis: a capture over a computed module."
  def dynamic_capture(module) do
    fun = Function.capture(module, :run, 1)
    fun.(:noop)
  end

  @doc "Fully static: every callee is an atom literal."
  def only_literal_calls(value), do: Enum.reverse(String.to_charlist(to_string(value)))
end

defmodule AshA2A.Test.StaticCallSiteFixture do
  @moduledoc """
  Real compiled module whose every remote call names its module literally.

  The negative control for `dynamic_call_sites/1`: without it, a test showing
  the analyser flags `AshA2A.Test.DynamicCallSiteFixture` proves only that it
  flags something, not that it discriminates.
  """

  @doc "Every callee here is an atom literal."
  def run(value) do
    value
    |> to_string()
    |> String.upcase()
    |> String.to_charlist()
    |> Enum.reverse()
  end
end
