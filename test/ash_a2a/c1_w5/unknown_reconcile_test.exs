defmodule AshA2A.C1W5.UnknownReconcileTest do
  use ExUnit.Case, async: true

  test "unknown_reconcile" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "unknown_reconcile.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end
