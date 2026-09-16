defmodule AshA2A.SemanticEnvelopeDoctestTest do
  @moduledoc """
  Runs the `@doc` doctests on the RFC-SA2A-001 S6/S11/S41/S42 semantic
  boundary modules for real.

  A separate module from `AshA2A.DoctestTest` so this layer's doctests are
  wired without touching that file's existing `AshA2A.Info` /
  `AshA2A.CapabilityIndex` / `AshA2A.ContextResolver` list.
  """

  use ExUnit.Case, async: true

  doctest AshA2A.Semantic.Refusal
  doctest AshA2A.Semantic.Envelope
  doctest AshA2A.Semantic.Standing
end
