defmodule AshA2A.Replan.ProviderFailureTest do
  use ExUnit.Case, async: true

  test "records failed edge" do
    assert %{provider: :p, attempt: 2} = AshA2A.Replan.ProviderFailure.new(:p, :timeout, 2)
  end
end
