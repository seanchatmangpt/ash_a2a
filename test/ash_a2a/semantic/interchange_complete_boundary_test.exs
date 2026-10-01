defmodule AshA2A.Semantic.InterchangeCompleteBoundaryTest do
  use ExUnit.Case, async: true
  alias AshA2A.Semantic.InterchangeBoundary

  test "every interchange dimension is explicit before authority is meaningful" do
    boundary = %InterchangeBoundary{
      subject: "source:a",
      contract: "contract:a",
      projection: "projection:a",
      runtime: "runtime:a",
      technical_standing: "technical:a",
      external_standing: "external:a",
      runtime_authority: "authority:a"
    }

    assert InterchangeBoundary.authorized?(boundary)

    for field <- [:subject, :contract, :projection, :runtime, :technical_standing, :external_standing] do
      refute InterchangeBoundary.authorized?(Map.put(boundary, field, nil))
    end
  end
end
