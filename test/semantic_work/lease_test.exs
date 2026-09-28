defmodule AshA2A.SemanticWork.LeaseTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Lease

  test "fails closed" do
    assert {:error, _} = Lease.bind(%{})
    assert {:error, :refused_invalid_envelope} = Lease.bind(:invalid)
  end

  test "accepts integer or DateTime expires_at" do
    now = DateTime.utc_now()
    assert {:ok, %{expires_at: 10}} = Lease.bind(%{lease_id: "l", subject: "s", expires_at: 10})

    assert {:ok, %{expires_at: ^now}} =
             Lease.bind(%{"lease_id" => "l", "subject" => "s", "expires_at" => now})
  end

  test "refuses other expires_at types" do
    for bad <- ["tomorrow", 1.5, :soon, %{}] do
      assert {:error, {:refused_invalid_lease, :expires_at}} =
               Lease.bind(%{lease_id: "l", subject: "s", expires_at: bad})
    end
  end
end
