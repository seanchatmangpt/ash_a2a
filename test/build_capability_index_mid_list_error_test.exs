defmodule AshA2A.BuildCapabilityIndexMidListErrorTest do
  @moduledoc """
  Chicago-style, standalone from `test/ash_a2a_test.exs`: real repro for the
  reviewed `Enum.reduce`-accumulator finding in
  `AshA2A.Transformers.BuildCapabilityIndex.transform/1`
  (lib/ash_a2a/transformers/build_capability_index.ex). A domain-level `a2a`
  block declaring 2+ skills where an earlier one fails `resolve_resource/4`
  used to leave `{:error, %Spark.Error.DslError{}}` as the reduce
  accumulator, then crash with a raw `FunctionClauseError` on the next
  entity instead of short-circuiting -- because the reducer's only clause
  matched `{:ok, dsl, skills}`. This compiles a real, standalone `Ash.Domain`
  with two domain-level skills -- the first missing `resource` (malformed),
  the second well-formed -- through the genuine `BuildCapabilityIndex`
  transformer. No Mock/mox/patch, no hand-built refusal:
  `Spark.Test.assert_dsl_error/2` is Spark's own real collector for the
  `Spark.Error.DslError` a domain's `@after_verify` would otherwise only
  emit as a stderr warning.
  """

  use ExUnit.Case

  test "a non-last malformed skill yields a clean DslError, not a FunctionClauseError" do
    # Transformer errors (unlike `AshA2A.Verify`'s `@after_verify` errors,
    # covered by `Spark.Test.assert_dsl_error/2` elsewhere in this suite) are
    # raised synchronously from `Spark.Dsl.__before_compile__/1` -- so the
    # real assertion here is `assert_raise`, not the after_verify message
    # collector. This is the load-bearing check: before the fix, this same
    # `defmodule` raised `FunctionClauseError` instead (the reduce
    # accumulator's `{:error, _}` shape did not match the reducer's
    # `{:ok, dsl, skills}`-only clause on the next iteration).
    error =
      assert_raise Spark.Error.DslError, fn ->
        defmodule Elixir.AshA2A.Test.Fixture.MidListResolutionFailure do
          use Ash.Domain, extensions: [AshA2A]

          resources do
            resource(AshA2A.Test.Fixture.Echo)
          end

          a2a do
            skill(:first_bad, :read)
            skill(:second_good, AshA2A.Test.Fixture.Echo, :read)
          end
        end
      end

    assert error.message =~ "domain-level skill overrides must declare a resource"
  end
end
