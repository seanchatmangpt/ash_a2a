# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DoctestTest do
  @moduledoc """
  Wires every public module's `@doc` doctest examples into ExUnit via
  `doctest/1`. Every example runs against the real, compiled code (and, where
  referenced, the real `AshA2A.Test.Fixture.*` fixtures from
  `test/support/fixture.ex`) -- no Mock/mox/patch, no fabricated data.

  Modules whose `@doc` examples live in other test files (e.g.
  `AshA2A.Semantic.Envelope` in `test/ash_a2a/semantic_envelope_doctest_test.exs`,
  `AshA2A.Transport.Principal` in `test/ash_a2a/transport/transport_court_test.exs`)
  are wired there, not duplicated here.
  """

  use ExUnit.Case, async: true

  doctest AshA2A.Info
  doctest AshA2A.CapabilityIndex
  doctest AshA2A.CapabilityIndex.AgentCardBuilder
  doctest AshA2A.ContextResolver
  doctest AshA2A.Schema
  doctest AshA2A.ToA2AError

  doctest AshA2A.Actuation
  doctest AshA2A.Authority
  doctest AshA2A.Receipt
  doctest AshA2A.TaskLifecycle

  doctest AshA2A.Protocol.Version
  doctest AshA2A.Protocol.JSON
  doctest AshA2A.Protocol.JSONRPC.Error
  doctest AshA2A.Protocol.CardSigning
  doctest AshA2A.Protocol.CardCache
  doctest AshA2A.Protocol.Extensions.Schema

  doctest AshA2A.Gall.Capability
  doctest AshA2A.Gall.Fields
  doctest AshA2A.Gall.Message

  doctest AshA2A.GraphLaw.WasmDriver
  doctest AshA2A.GraphLaw.WasmexHost

  doctest AshA2A.Chicago.Observer.EvidenceBounds

  doctest AshA2A.Semantic.Serialize
  doctest AshA2A.Semantic.LogicClosure.RuleDocument
end
