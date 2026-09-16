defmodule AshA2A.SemanticAdmissionStandingTest do
  @moduledoc """
  Real state-based tests for the monotonic standing ladder. No collaborators to
  fake: `AshA2A.Semantic.AdmissionStanding` is pure, and every assertion below is on a
  real returned value.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.AdmissionStanding, as: Standing

  test "the ladder starts at :candidate and terminates at :admitted" do
    assert Standing.initial() == :candidate
    assert Standing.terminal() == :admitted
    assert List.first(Standing.stages()) == :candidate
    assert List.last(Standing.stages()) == :admitted
  end

  test "advance/2 moves exactly one step forward" do
    assert {:ok, :parsed} = Standing.advance(:candidate, :parsed)
    assert {:ok, :identified} = Standing.advance(:parsed, :identified)
    assert {:ok, :admitted} = Standing.advance(:profile_conformant, :admitted)
  end

  test "advance/2 refuses a skipped stage rather than clamping to it" do
    assert {:error, %{code: :standing_transition_invalid, from: :candidate, to: :admitted}} =
             Standing.advance(:candidate, :admitted)

    assert {:error, %{code: :standing_transition_invalid}} =
             Standing.advance(:candidate, :shacl_conformant)
  end

  test "advance/2 refuses a regression and a repeat" do
    assert {:error, %{code: :standing_transition_invalid}} = Standing.advance(:admitted, :parsed)
    assert {:error, %{code: :standing_transition_invalid}} = Standing.advance(:parsed, :parsed)
  end

  test "advance/2 refuses an unknown standing" do
    assert {:error, %{code: :standing_transition_invalid}} =
             Standing.advance(:candidate, :made_up)

    assert {:error, %{code: :standing_transition_invalid}} = Standing.advance(:made_up, :parsed)
  end

  test "reached?/2 is a real ordering on the ladder" do
    assert Standing.reached?(:admitted, :parsed)
    assert Standing.reached?(:parsed, :parsed)
    refute Standing.reached?(:parsed, :admitted)
    refute Standing.reached?(:made_up, :parsed)
  end

  test "walking the whole ladder one step at a time is the only way to :admitted" do
    final =
      Enum.reduce(tl(Standing.stages()), Standing.initial(), fn next, current ->
        {:ok, advanced} = Standing.advance(current, next)
        advanced
      end)

    assert final == :admitted
    assert Standing.admitted?(final)
  end
end
