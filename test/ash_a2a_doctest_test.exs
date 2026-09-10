defmodule AshA2A.DoctestTest do
  @moduledoc """
  Wires the `@doc` doctests on `AshA2A.Info`, `AshA2A.CapabilityIndex`, and
  `AshA2A.ContextResolver` into ExUnit via `doctest/1`. Every example in
  those modules' docs runs against the real, compiled
  `AshA2A.Test.Fixture.Echo`/`AshA2A.Test.Fixture.Domain` fixtures
  (`test/support/fixture.ex`) -- no Mock/mox/patch, no fabricated data.
  """

  use ExUnit.Case, async: true

  doctest AshA2A.Info
  doctest AshA2A.CapabilityIndex
  doctest AshA2A.ContextResolver
end
