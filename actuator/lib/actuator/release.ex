defmodule Actuator.Release do
  @moduledoc """
  Operator entry points for `bin/actuator eval`. Reconciliation is deliberately NOT a wire
  operation: it is an administrative resolution (RFC-SA2A-006 s21).

      bin/actuator eval 'Actuator.Release.reconcile("<instance>", :confirmed_not_performed, "note")'
  """

  def reconcile(instance_id, resolution, note) do
    Actuator.Store.reconcile(Actuator.Store, instance_id, resolution, note)
  end
end
