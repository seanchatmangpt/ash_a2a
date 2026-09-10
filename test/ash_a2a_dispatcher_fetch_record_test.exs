defmodule AshA2ADispatcherFetchRecordTest.Ticket do
  @moduledoc """
  Real fixture resource, private to this test file (kept out of the shared
  `test/support/fixture.ex` to avoid collisions with concurrent edits to that
  file): a genuine `Ash.Resource` whose primary key attribute is deliberately
  named `:ticket_ref` -- not `:id` -- so `AshA2A.Dispatcher`'s update/destroy
  dispatch path is exercised against a resource `Ash.get/3` (via
  `Ash.Resource.Info.primary_key/1`) resolves generically, exactly as it
  would for any resource not named `id`.
  """

  use Ash.Resource,
    domain: AshA2ADispatcherFetchRecordTest.TicketDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    attribute(:ticket_ref, :string,
      primary_key?: true,
      allow_nil?: false,
      writable?: true,
      public?: true
    )

    attribute(:status, :string, public?: true, default: "open")
  end

  actions do
    defaults([:read, :destroy, create: [:ticket_ref, :status], update: [:ticket_ref, :status]])
  end

  a2a do
    skill(:close, :update)
    skill(:remove, :destroy)
  end
end

defmodule AshA2ADispatcherFetchRecordTest.TicketDomain do
  @moduledoc "Real fixture domain for `AshA2ADispatcherFetchRecordTest.Ticket` above."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2ADispatcherFetchRecordTest.Ticket)
  end
end

defmodule AshA2ADispatcherFetchRecordTest.LineItem do
  @moduledoc """
  Real fixture resource, private to this test file, with a *composite*
  primary key (`:order_id` + `:line_no`, neither named `id`), for
  `fetch_record_for_update/3` composite-key regression coverage -- the
  second identity shape `Ash.Filter.get_filter/2` supports generically via
  `Ash.Resource.Info.primary_key/1` (a map/keyword of every key field).
  """

  use Ash.Resource,
    domain: AshA2ADispatcherFetchRecordTest.LineItemDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    attribute(:order_id, :string,
      primary_key?: true,
      allow_nil?: false,
      writable?: true,
      public?: true
    )

    attribute(:line_no, :integer,
      primary_key?: true,
      allow_nil?: false,
      writable?: true,
      public?: true
    )

    attribute(:sku, :string, public?: true)
  end

  actions do
    defaults([
      :read,
      :destroy,
      create: [:order_id, :line_no, :sku],
      update: [:order_id, :line_no, :sku]
    ])
  end

  a2a do
    skill(:update_sku, :update)
  end
end

defmodule AshA2ADispatcherFetchRecordTest.LineItemDomain do
  @moduledoc "Real fixture domain for `AshA2ADispatcherFetchRecordTest.LineItem` above."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2ADispatcherFetchRecordTest.LineItem)
  end
end

defmodule AshA2ADispatcherFetchRecordTest do
  @moduledoc """
  Chicago-style regression coverage for the reviewed
  `fetch_record_for_update/3` finding: dispatcher.ex's update/destroy
  dispatch path used to only recognize a literal `"id"`/`:id` input key
  before calling `Ash.get/3`, failing closed with
  `{:error, {:missing_argument, :id}}` for any resource whose real primary
  key is named something else, or is composite.

  Uses two real fixture resources defined above, private to this file (kept
  out of `test/support/fixture.ex` to avoid collisions with unrelated
  concurrent edits to that shared file):

    * `Ticket` -- single-attribute primary key named `:ticket_ref`, not `:id`.
    * `LineItem` -- composite primary key (`:order_id`, `:line_no`), neither
      named `id`.

  All records are inserted via real `Ash.create!/2` calls against the real
  ETS data layer and dispatched through the real
  `AshA2A.Dispatcher.dispatch/3` -- no Mock/mox/patch anywhere in this file.
  """

  use ExUnit.Case

  alias AshA2ADispatcherFetchRecordTest.LineItem
  alias AshA2ADispatcherFetchRecordTest.Ticket

  test "update dispatch resolves a non-`id`-named single primary key by its real attribute name" do
    ticket =
      Ticket
      |> Ash.Changeset.for_create(:create, %{ticket_ref: "TCK-1", status: "open"})
      |> Ash.create!()

    message =
      A2A.Message.new_user([
        A2A.Part.Data.new(%{"ticket_ref" => ticket.ticket_ref, "status" => "closed"})
      ])

    assert {:reply, [%A2A.Part.Data{data: %{status: "closed"}}]} =
             AshA2A.Dispatcher.dispatch(:close, message, Ticket)

    assert Ash.get!(Ticket, ticket.ticket_ref).status == "closed"
  end

  test "update dispatch resolves the primary key from atom-keyed input, not only string keys" do
    ticket =
      Ticket
      |> Ash.Changeset.for_create(:create, %{ticket_ref: "TCK-2", status: "open"})
      |> Ash.create!()

    message =
      A2A.Message.new_user([
        A2A.Part.Data.new(%{ticket_ref: ticket.ticket_ref, status: "closed"})
      ])

    assert {:reply, [%A2A.Part.Data{data: %{status: "closed"}}]} =
             AshA2A.Dispatcher.dispatch(:close, message, Ticket)
  end

  test "update dispatch still fails closed (missing_argument) when the real primary key is absent" do
    message = A2A.Message.new_user([A2A.Part.Data.new(%{"status" => "closed"})])

    assert {:input_required, [%A2A.Part.Text{text: text}]} =
             AshA2A.Dispatcher.dispatch(:close, message, Ticket)

    assert text =~ "ticket_ref"
  end

  test "destroy dispatch resolves a non-`id`-named primary key the same way" do
    ticket =
      Ticket
      |> Ash.Changeset.for_create(:create, %{ticket_ref: "TCK-3", status: "open"})
      |> Ash.create!()

    message = A2A.Message.new_user([A2A.Part.Data.new(%{"ticket_ref" => ticket.ticket_ref})])

    assert {:reply, [%A2A.Part.Data{}]} = AshA2A.Dispatcher.dispatch(:remove, message, Ticket)

    assert match?({:error, _}, Ash.get(Ticket, ticket.ticket_ref))
  end

  test "update dispatch resolves a composite primary key supplied as a map, no field named `id`" do
    line_item =
      LineItem
      |> Ash.Changeset.for_create(:create, %{order_id: "ORD-1", line_no: 1, sku: "WIDGET-A"})
      |> Ash.create!()

    message =
      A2A.Message.new_user([
        A2A.Part.Data.new(%{
          "order_id" => line_item.order_id,
          "line_no" => line_item.line_no,
          "sku" => "WIDGET-B"
        })
      ])

    assert {:reply, [%A2A.Part.Data{data: %{sku: "WIDGET-B"}}]} =
             AshA2A.Dispatcher.dispatch(:update_sku, message, LineItem)

    assert Ash.get!(LineItem, %{order_id: line_item.order_id, line_no: line_item.line_no}).sku ==
             "WIDGET-B"
  end

  test "update dispatch fails closed when only part of a composite primary key is supplied" do
    message =
      A2A.Message.new_user([
        A2A.Part.Data.new(%{"order_id" => "ORD-2", "sku" => "WIDGET-C"})
      ])

    assert {:input_required, [%A2A.Part.Text{text: text}]} =
             AshA2A.Dispatcher.dispatch(:update_sku, message, LineItem)

    assert text =~ "order_id"
    assert text =~ "line_no"
  end
end
