defmodule AshA2A.DocsTruthTest do
  @moduledoc """
  Chicago court: `docs/reference/configuration.md` may not state a default for
  a security-relevant key that differs from the default the code actually
  applies.

  Oracle independence: the documented value is parsed from the markdown text;
  the code-side value is observed by running the real public entry point with
  the application-env key deleted (`CommandBus.actuation_dedup_mode/1`,
  `CapabilityRelease.binding/2`, `Authority.Grant.authorize/3`), never by
  re-reading the doc or a copied constant. DB-free; no mocks. The env is
  mutated, so this module is `async: false` and restores it on exit.
  """
  use ExUnit.Case, async: false

  alias AshA2A.{Authority, CapabilityRelease, CommandBus}

  @doc_path Path.expand("../../docs/reference/configuration.md", __DIR__)
  @keys [:actuation_dedup, :capability_release_mode, :authority_policy]

  setup do
    saved =
      for key <- @keys ++ [:authority_broker], do: {key, Application.fetch_env(:ash_a2a, key)}

    Enum.each(@keys ++ [:authority_broker], &Application.delete_env(:ash_a2a, &1))

    on_exit(fn ->
      for {key, res} <- saved do
        case res do
          {:ok, value} -> Application.put_env(:ash_a2a, key, value)
          :error -> Application.delete_env(:ash_a2a, key)
        end
      end
    end)

    :ok
  end

  # Row shape: | `:key` | `default` ... -- returns the first backticked token of cell 2.
  defp documented_default(key) do
    prefix = "| `#{inspect(key)}` |"

    row =
      @doc_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, prefix))

    assert row, "docs/reference/configuration.md has no table row for #{inspect(key)}"
    [_, _, cell | _] = String.split(row, "|")
    [_, value | _] = String.split(cell, "`")
    value
  end

  defp code_default(:actuation_dedup), do: inspect(CommandBus.actuation_dedup_mode([]))

  defp code_default(:capability_release_mode) do
    case CapabilityRelease.binding("docs.truth.probe") do
      {:ok, nil} -> ":legacy"
      {:error, :capability_release_closure_missing} -> ":strict"
    end
  end

  defp code_default(:authority_policy) do
    principal = "docs-truth-#{System.unique_integer([:positive])}"

    case Authority.Grant.authorize(principal, "docs.truth.probe") do
      nil -> ":broker"
      %Authority{} -> ":transport_verified_grants_capability"
    end
  end

  for key <- @keys do
    test "configuration.md default for #{inspect(key)} equals the code default" do
      key = unquote(key)

      assert documented_default(key) == code_default(key),
             "docs/reference/configuration.md states #{documented_default(key)} for " <>
               "#{inspect(key)} but the code default is #{code_default(key)}"
    end
  end

  test "the court is not vacuous: a wrong documented value is detected" do
    assert documented_default(:actuation_dedup) != ":off"
    assert code_default(:actuation_dedup) != ":off"
  end

  describe "docs/how-to/test-governed-actions.md example (AshA2A.Test.Governed)" do
    alias AshA2A.Test.Fixture.{Echo, Item}
    alias AshA2A.Test.Governed

    test "a change skill is refused without a grant, completes with one, refused after revoke" do
      gov = Governed.start!()
      capability = "AshA2A.Test.Fixture.Item.create"
      input = %{label: "widget"}

      assert {:error, %{code: :authority_required}} =
               Governed.run(gov, Item, capability, principal: "alice", input: input)

      gov = Governed.grant!(gov, "alice", capability)

      assert {:ok, receipt} =
               Governed.run(gov, Item, capability,
                 principal: "alice",
                 input: input,
                 command_id: "gov-1"
               )

      assert receipt.status == :completed
      assert receipt.consequence == :change

      assert {:ok, stored} = Governed.fetch_receipt(gov, receipt.command_id)
      assert stored.receipt_id == receipt.receipt_id

      gov = Governed.revoke!(gov, "alice", capability)

      assert {:error, %{code: :authority_revoked}} =
               Governed.run(gov, Item, capability,
                 principal: "alice",
                 input: %{label: "gadget"},
                 command_id: "gov-2"
               )
    end

    test "an observe skill needs no grant and replays by command id" do
      gov = Governed.start!()
      cap = "AshA2A.Test.Fixture.Echo.read"

      assert {:ok, first} = Governed.run(gov, Echo, cap, command_id: "gov-read")
      refute first.replayed?
      assert {:ok, again} = Governed.run(gov, Echo, cap, command_id: "gov-read")
      assert again.replayed?
      assert again.receipt_id == first.receipt_id
    end

    test "grants are isolated per context" do
      one = Governed.start!()
      two = Governed.start!()
      capability = "AshA2A.Test.Fixture.Item.create"
      Governed.grant!(one, "bob", capability)

      assert {:error, %{code: :authority_required}} =
               Governed.run(two, Item, capability, principal: "bob", input: %{label: "x"})
    end
  end
end
