defmodule SemanticLane12EngineTest do
  use ExUnit.Case, async: false

  alias AshA2A.Semantic.Conformance
  alias AshA2A.Semantic.Engine.AshGraphLaw, as: Engine
  alias AshA2A.Semantic.HookReactor.Hook

  @ttl "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\n"

  test "bad input is refused with a typed error, never coerced" do
    assert {:error, %{code: :engine_bad_input}} = Engine.datalog_closure("text", [])
    assert {:error, %{code: :engine_bad_input}} = Engine.datalog_closure([], :nope)
    assert {:error, %{code: :engine_bad_input}} = Engine.n3_closure(42, nil)
    assert {:error, %{code: :engine_bad_input}} = Engine.n3_closure(%{}, "x")
    assert {:error, %{code: :engine_bad_input}} = Engine.validate_shex(nil, "s", "m")
  end

  test "datalog_closure runs on the real engine" do
    assert {:ok, res} =
             Engine.datalog_closure(
               [["a", "p", "b"]],
               [%{"head" => ["?x", "q", "?y"], "body" => [["?x", "p", "?y"]]}]
             )

    assert res.count == 2
  end

  test "n3_closure runs on the real engine" do
    rules = "{ ?x ex:p ?y } => { ?y ex:q ?x } ."
    assert {:ok, res} = Engine.n3_closure(@ttl, "@prefix ex: <http://example.org/> .\n" <> rules)
    assert is_binary(res.derived)
  end

  test "validate_shex runs on the real engine" do
    assert {:ok, res} =
             Engine.validate_shex(
               @ttl,
               "PREFIX ex: <http://example.org/>\n<http://example.org/S> { ex:p . }",
               "<http://example.org/a>@<http://example.org/S>"
             )

    assert res != nil
  end

  test "engine_capability/2 consults the engine (probe) and closure determinism runs" do
    assert Engine.probe(:datalog_closure, 2) == :ok
    assert {:error, {:no_probe, :nope, 1}} = Engine.probe(:nope, 1)
    assert Conformance.engine_capability(:n3_closure, 2) == :met
    assert Conformance.check_deterministic_closure() == :met
  end

  test "hook condition routing parses tokens, not substrings" do
    denial =
      "# kh: in a comment\n@prefix ex: <http://example.org/> .\n{ ?s ex:p \"kh:x\" } => false ."

    refute Hook.hook_pack_condition?(denial)

    assert Hook.hook_pack_condition?(
             "@prefix kh: <urn:kh#> .\nex:h a kh:Hook ; kh:kind \"delta\" ."
           )

    assert :ok = Hook.condition_shape(:condition, denial)

    assert {:error, %{code: :hook_condition_invalid}} =
             Hook.condition_shape(:condition, denial <> denial)
  end
end
