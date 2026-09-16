defmodule AshA2A.GraphLawWasmEngineTest do
  @moduledoc """
  Real invocation of the real `praxis-graphlaw` WebAssembly module through
  `AshA2A.GraphLaw.Wasm`.

  Every value asserted here came out of the real wasm's linear memory via a real
  `node` subprocess. Nothing is stubbed. When the artifact is absent the module
  is a named, visible skip carrying the real reason.
  """

  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.Wasm

  case AshA2A.GraphLaw.Wasm.availability() do
    :ok ->
      @moduletag :graphlaw

    {:error, detail} ->
      @moduletag skip:
                   "real GraphLaw wasm unavailable (#{inspect(detail)}) -- " <>
                     "these cases run the real engine and are never mocked"
  end

  @base """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:c .
  """

  @relabelled_reordered """
  @prefix zz: <http://example.org/> .
  zz:b zz:p zz:c .
  zz:a zz:p zz:b .
  """

  @different """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:zzz .
  """

  test "version/1 returns the real engine's own version string" do
    assert {:ok, version} = Wasm.version()
    assert version =~ "praxis-graphlaw"
  end

  test "blake3_hex/2 matches the published BLAKE3 test vector for \"abc\"" do
    assert {:ok, "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"} =
             Wasm.blake3_hex("abc")
  end

  test "graph_hash/2 is canonical: prefix labels and triple order do not change it" do
    assert {:ok, base} = Wasm.graph_hash(@base)
    assert {:ok, same} = Wasm.graph_hash(@relabelled_reordered)
    assert {:ok, other} = Wasm.graph_hash(@different)

    assert base == same
    refute base == other
    assert base =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "batch/2 runs several real calls in one real wasm instantiation, in order" do
    assert {:ok, [version, hash_a, hash_b]} =
             Wasm.batch([
               {:graphlaw_version, []},
               {:graph_hash, [@base]},
               {:graph_hash, [@different]}
             ])

    assert version =~ "praxis-graphlaw"
    refute hash_a == hash_b
  end

  test "validate_all/6 reports a real SHACL violation and a real conformance" do
    shapes = """
    @prefix sh: <http://www.w3.org/ns/shacl#> .
    @prefix ex: <http://example.org/> .
    ex:Shape a sh:NodeShape ;
      sh:targetClass ex:Thing ;
      sh:property [ sh:path ex:name ; sh:minCount 1 ] .
    """

    conforming = """
    @prefix ex: <http://example.org/> .
    ex:t a ex:Thing ; ex:name "n" .
    """

    violating = """
    @prefix ex: <http://example.org/> .
    ex:t a ex:Thing .
    """

    assert {:ok, ok_report} = Wasm.validate_all(conforming, "", shapes, "", "")
    assert {:ok, %{"status" => "ADMITTED"}} = Wasm.dialect(ok_report, "SHACL")

    assert {:ok, bad_report} = Wasm.validate_all(violating, "", shapes, "", "")

    assert {:ok, %{"status" => "REFUSED", "triples_out" => count}} =
             Wasm.dialect(bad_report, "SHACL")

    assert count >= 1
  end

  test "an absent dialect is an error, never a silent pass" do
    assert {:ok, report} = Wasm.validate_all(@base, "", "", "", "")
    assert {:error, %{code: :graphlaw_dialect_missing}} = Wasm.dialect(report, "NO_SUCH_DIALECT")
  end

  test "missing shapes come back UNSUPPORTED -- the engine's own 'nothing was checked'" do
    assert {:ok, report} = Wasm.validate_all(@base, "", "", "", "")
    assert {:ok, %{"status" => "UNSUPPORTED"}} = Wasm.dialect(report, "SHACL")
    assert {:ok, %{"status" => "PROFILE_NOT_ADMITTED"}} = Wasm.dialect(report, "OWL_RL")
  end

  test "run_hooks/3 returns the engine's real hook admission verdict" do
    event = """
    @prefix ex: <http://example.org/> .
    ex:ev a ex:Event .
    """

    assert {:ok, %{"status" => "ADMITTED"} = decoded} = Wasm.run_hooks(@base, event)
    assert Map.has_key?(decoded, "verdicts")
    assert Map.has_key?(decoded, "receipts")
  end

  test "the engine's replay block agrees with itself on a real graph" do
    assert {:ok, report} = Wasm.validate_all(@base, "", "", "", "")

    assert %{
             "replay" => %{"status" => "ADMITTED", "first_hash" => first, "second_hash" => second}
           } =
             report

    assert first == second
  end

  test "malformed input still yields a hash -- the measured leniency the pipeline guards against" do
    # This is a real falsifier for the naive reading "a hash means it parsed".
    assert {:ok, hash} = Wasm.graph_hash("this is not turtle at all <<< @@@ ;;;")
    assert hash =~ ~r/\A[0-9a-f]{64}\z/

    # The engine-native witness that actually distinguishes them: under the
    # universal denial rule, a real graph has denial violations and garbage
    # does not.
    witness = "\n{ ?s ?p ?o } => false .\n"

    assert {:ok, real_report} = Wasm.validate_all(@base <> witness, "", "", "", "")
    assert {:ok, %{"status" => "REFUSED"}} = Wasm.dialect(real_report, "N3_DENIAL")

    assert {:ok, junk_report} =
             Wasm.validate_all("this is not turtle at all <<<" <> witness, "", "", "", "")

    assert {:ok, %{"status" => "ADMITTED"}} = Wasm.dialect(junk_report, "N3_DENIAL")
  end
end

defmodule AshA2A.GraphLawWasmTest do
  @moduledoc """
  Engine-independent behaviour of `AshA2A.GraphLaw.Wasm`: path resolution and
  the typed errors it produces when the real engine is not reachable.
  """

  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.Wasm

  test "wasm_path/1 prefers an explicit option" do
    assert Wasm.wasm_path(wasm_path: "/custom/graphlaw.wasm") == "/custom/graphlaw.wasm"
  end

  test "availability/1 names a missing artifact instead of failing silently" do
    assert {:error, %{code: :graphlaw_wasm_not_found, path: "/nonexistent/graphlaw.wasm"}} =
             Wasm.availability(wasm_path: "/nonexistent/graphlaw.wasm")

    refute Wasm.available?(wasm_path: "/nonexistent/graphlaw.wasm")
  end

  test "batch/2 refuses rather than raising when the artifact is absent" do
    assert {:error, %{code: :graphlaw_wasm_not_found}} =
             Wasm.batch([{:graphlaw_version, []}], wasm_path: "/nonexistent/graphlaw.wasm")
  end

  test "decode_json/1 maps the engine's own error convention onto a typed error" do
    assert {:error, %{code: :graphlaw_engine_error, message: "boom"}} =
             Wasm.decode_json(~s({"error":"boom"}))

    assert {:error, %{code: :graphlaw_non_json_result}} = Wasm.decode_json("not json")
    assert {:ok, %{"a" => 1}} = Wasm.decode_json(~s({"a":1}))
  end

  test "dialect/2 refuses a malformed report" do
    assert {:error, %{code: :graphlaw_report_malformed}} = Wasm.dialect(%{}, "SHACL")
  end
end
