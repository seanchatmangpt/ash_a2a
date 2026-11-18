# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ADispatcherNotFoundTest.Case do
  @moduledoc """
  Real fixture resource, private to this test file: a genuine `Ash.Resource`
  on the real ETS data layer whose `:update` and `:destroy` actions are
  exposed as A2A skills, so a dispatch against a primary key that names no
  stored record runs the real `Ash.get/3` not-found path inside
  `AshA2A.Dispatcher.fetch_record_for_update/3`.
  """

  use Ash.Resource,
    domain: AshA2ADispatcherNotFoundTest.CaseDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    attribute(:case_ref, :string,
      primary_key?: true,
      allow_nil?: false,
      writable?: true,
      public?: true
    )

    attribute(:status, :string, public?: true, default: "open")
    attribute(:priority, :integer, public?: true, default: 1)
  end

  actions do
    defaults([
      :read,
      :destroy,
      create: [:case_ref, :status, :priority],
      update: [:status, :priority]
    ])
  end

  a2a do
    skill(:resolve_case, :update)
    skill(:drop_case, :destroy)
  end
end

defmodule AshA2ADispatcherNotFoundTest.CaseDomain do
  @moduledoc "Real fixture domain for `AshA2ADispatcherNotFoundTest.Case` above."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2ADispatcherNotFoundTest.Case)
  end
end

defmodule AshA2ADispatcherNotFoundTest do
  @moduledoc """
  Chicago-school coverage for the `Ash.Error.Query.NotFound` reply class
  carried forward from `preserve/v26.9.22/stash-4` (unique hunk U1).

  An update/destroy dispatch whose primary key names no stored record used to
  fall into `AshA2A.Dispatcher.to_reply/1`'s generic `class: :invalid` clause
  and come back as `{:input_required, _}` -- telling a well-behaved A2A client
  to resubmit identical input forever. It must instead be the non-retryable
  `"not_found: ..."` error class (main's `class_message/2` shape), stage-tagged
  `:execution` by `dispatch/6` like every other execution-stage error.

  Everything is real: records are written with `Ash.create!/2` to the real ETS
  data layer, and every dispatch goes through the real `AshA2A.CommandBus`
  (via `AshA2A.Test.ReceiptedDispatch`) into the real dispatcher. No
  Mock/Mox/patch anywhere in this file. The positive controls (existing
  record replies; a genuinely malformed argument still asks for input) keep
  the not-found assertion from being satisfiable by a dispatcher that maps
  every `:invalid` error to `:not_found`.
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.ReceiptedDispatch
  alias AshA2ADispatcherNotFoundTest.Case

  defp create_case!(ref) do
    Case
    |> Ash.Changeset.for_create(:create, %{case_ref: ref, status: "open"})
    |> Ash.create!()
  end

  defp missing_ref, do: "CASE-MISSING-" <> Ash.UUIDv7.generate()

  test "update dispatch against a nonexistent primary key returns the not_found class" do
    message = data_message(%{"case_ref" => missing_ref(), "status" => "closed"})

    assert {:error, {:execution, "not_found: " <> detail}} =
             ReceiptedDispatch.dispatch(:resolve_case, message, Case)

    assert detail =~ "not found"
  end

  test "destroy dispatch against a nonexistent primary key returns the not_found class" do
    message = data_message(%{"case_ref" => missing_ref()})

    assert {:error, {:execution, "not_found: " <> detail}} =
             ReceiptedDispatch.dispatch(:drop_case, message, Case)

    assert detail =~ "not found"
  end

  test "a record destroyed before an update dispatch is not_found, never input_required" do
    ref = "CASE-GONE-" <> Ash.UUIDv7.generate()
    record = create_case!(ref)
    :ok = Ash.destroy!(record)

    message = data_message(%{"case_ref" => ref, "status" => "closed"})
    result = ReceiptedDispatch.dispatch(:resolve_case, message, Case)

    refute match?({:input_required, _}, result)
    assert {:error, {:execution, "not_found: " <> detail}} = result
    assert detail =~ ref
  end

  test "positive control: an existing record still updates and replies" do
    ref = "CASE-LIVE-" <> Ash.UUIDv7.generate()
    create_case!(ref)

    message = data_message(%{"case_ref" => ref, "status" => "closed"})

    assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{status: "closed"}}]} =
             ReceiptedDispatch.dispatch(:resolve_case, message, Case)

    assert Ash.get!(Case, ref).status == "closed"
  end

  test "control: a malformed argument on an existing record still asks for input" do
    ref = "CASE-BADARG-" <> Ash.UUIDv7.generate()
    create_case!(ref)

    message = data_message(%{"case_ref" => ref, "priority" => "not-an-integer"})

    assert {:input_required, [%AshA2A.Protocol.Part.Text{}]} =
             ReceiptedDispatch.dispatch(:resolve_case, message, Case)

    assert Ash.get!(Case, ref).priority == 1
  end
end
