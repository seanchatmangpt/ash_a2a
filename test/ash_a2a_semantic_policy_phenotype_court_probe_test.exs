defmodule AshA2A.Court.PolicyPhenotypeProbeTest do
  # Court probe (ash_a2a#45 @ d35394a0). Real module, no doubles.
  use ExUnit.Case, async: true
  alias AshA2A.Semantic.PolicyPhenotype, as: P

  defp opts(axis, extra \\ []) do
    [
      capability_iri: "urn:sa2a:capability:Example.Search.read",
      policy_family: "planner:MCTS",
      conditionable_axes: %{axis => %{min: 0.0, max: 1.0}},
      condition: %{axis => 0.5}
    ] ++ extra
  end

  defp code(r),
    do:
      (case r do
         {:error, %{code: c}} -> c
         {:ok, _} -> :ADMITTED
       end)

  @split [
    "gr_ant",
    "execution_gr_ant",
    "execution-g-rant",
    "le_ase",
    "tok-en",
    "d_o",
    "GRant",
    "executionGRant",
    "LEase",
    "TOken",
    "su_do",
    "gra͏nt",
    "execution͏gr͏ant"
  ]
  for a <- @split do
    test "separator/camel/invisible-mark split refused: #{inspect(a)}" do
      assert code(P.new(opts(unquote(a)))) == :temperament_cannot_encode_authority
    end
  end

  test "range map cannot carry a grant/token field" do
    o =
      opts("boldness")
      |> Keyword.put(
        :conditionable_axes,
        %{"boldness" => %{min: 0.0, max: 1.0, grant: :do, token: "secret"}}
      )

    r = P.new(o)
    assert code(r) != :ADMITTED, "admitted: #{inspect(r)}"
  end

  test "reaction norm cannot carry an authority field" do
    o =
      opts("boldness",
        reaction_norms: %{"boldness" => %{slope: 0.1, authority: :execute, token: "t"}}
      )

    r = P.new(o)
    assert code(r) != :ADMITTED, "admitted: #{inspect(r)}"
  end

  test "forged struct with injected grant field is refused by condition/2" do
    {:ok, p} = P.new(opts("boldness", reaction_norms: %{"boldness" => %{slope: 0.1}}))
    forged = Map.put(p, :execution_grant, "token-abc")
    r = P.condition(forged, 1.0)
    assert code(r) != :ADMITTED, "admitted: #{inspect(r)}"
  end

  # Controls: the fence the PR does claim.
  for a <- ["execution_grant", "ExecutionGrant", "grаnt", "auth_ority", "HTTPGrant", "grantlevel"] do
    test "control refused: #{inspect(a)}" do
      assert code(P.new(opts(unquote(a)))) == :temperament_cannot_encode_authority
    end
  end
end
