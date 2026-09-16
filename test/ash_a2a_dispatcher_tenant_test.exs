defmodule AshA2ADispatcherTenantTest do
  @moduledoc """
  Chicago-style regression coverage for the Zach-Daniel-review finding:
  `AshA2A.Dispatcher.to_reply/1`'s `TenantRequired` carve-out (routing a
  missing-tenant error to `{:error, {:invalid_config, _}}` instead of the
  generic `:input_required` "supply more input" signal) previously only
  matched `Ash.Error.Invalid.TenantRequired`/`NoPrimaryAction`, which only
  `:read` ever raises. `:create`/`:update`/`:destroy` enforce multitenancy
  through a different path (`Ash.Actions.Helpers
  .validate_changeset_multitenancy/1`) that raises a generic
  `Ash.Error.Changes.InvalidChanges` wrapped in a top-level
  `Ash.Error.Invalid{errors: [...]}`, which fell through to the generic
  `%{class: :invalid}` clause and told the caller "supply more input" --
  exactly the wrong signal, since no input the caller could supply fixes a
  missing tenant.

  Uses the real `AshA2A.Test.Fixture.TenantedItem` multitenant resource
  (`test/support/fixture.ex`), dispatched through the real
  `AshA2A.Dispatcher.dispatch/3` with no tenant in context -- no Mock/mox/
  patch, no stubbed Ash or A2A behavior anywhere in this file. Every error
  asserted on here is a genuine error Ash's own multitenancy enforcement
  raised, not a hand-built term.
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.TenantedItem
  alias AshA2A.Test.ReceiptedDispatch

  test "dispatch/3 maps a real missing-tenant :create error to a class-tagged :invalid_config error, not :input_required" do
    message = data_message(%{"label" => "widget"})

    assert {:error, {:execution, reason}} =
             ReceiptedDispatch.dispatch(:create_tenanted_item, message, TenantedItem)

    assert reason =~ "invalid_config:"
    assert reason =~ "tenant"
  end

  test "dispatch/3 maps a real missing-tenant :update error to a class-tagged :invalid_config error, not :input_required" do
    {:ok, record} =
      TenantedItem
      |> Ash.Changeset.for_create(:create, %{label: "before"}, tenant: "acme")
      |> Ash.create(domain: AshA2A.Test.Fixture.TenantedItemDomain)

    message =
      data_message(%{"id" => record.id, "label" => "after"})

    assert {:error, {:execution, reason}} =
             ReceiptedDispatch.dispatch(:update_tenanted_item, message, TenantedItem)

    assert reason =~ "invalid_config:"
    assert reason =~ "tenant"
  end

  test "dispatch/3 maps a real missing-tenant :destroy error to a class-tagged :invalid_config error, not :input_required" do
    {:ok, record} =
      TenantedItem
      |> Ash.Changeset.for_create(:create, %{label: "before"}, tenant: "acme")
      |> Ash.create(domain: AshA2A.Test.Fixture.TenantedItemDomain)

    message = data_message(%{"id" => record.id})

    assert {:error, {:execution, reason}} =
             ReceiptedDispatch.dispatch(:destroy_tenanted_item, message, TenantedItem)

    assert reason =~ "invalid_config:"
    assert reason =~ "tenant"
  end

  test "dispatch/3 still returns :input_required for a genuine caller-fixable :invalid error (unrelated to tenancy)" do
    # Regression guard for the fix itself: an ordinary missing-required-
    # attribute error on a *non*-multitenant resource must still be
    # caller-actionable (`:input_required`), not swept into
    # `:invalid_config` by an overly broad tenant-message match.
    message = data_message(%{})

    assert {:input_required, _parts} =
             ReceiptedDispatch.dispatch(:create_item, message, AshA2A.Test.Fixture.Item)
  end
end
