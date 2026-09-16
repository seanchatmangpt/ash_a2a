defmodule AshA2A.Semantic.CanonicalGraphThreeWayAgreementTest do
  @moduledoc """
  A real cross-engine conformance artifact: does the vendored praxis-graphlaw
  wasm law package agree with RDF.ex on canonical form?

  The experiment, for a Turtle document `T`:

      A = graphlaw.graph_hash(T)
      B = graphlaw.graph_hash(CanonicalGraph.canonical_nquads(T))

  If `A == B`, graphlaw's own notion of canonical form and RDFC-1.0's agree on
  `T` -- feeding graphlaw the RDFC-1.0 canonical serialization instead of the
  original concrete syntax does not move its digest.

  ## The real, measured answer (praxis-graphlaw v26.7.5, RDF.ex 3.0.1)

  **Blank-node-free graphs: the two engines AGREE.** Both `A` and `B` are
  `9b818096...` for the vendored `base.ttl` fixture.

  **Graphs containing blank nodes: the two engines DIVERGE**, and the
  divergence is informative rather than a failure. `A` is not even well-defined
  for a blank-node graph, because graphlaw's digest depends on the *arbitrary
  names* of the blank nodes (`_:b1` and `_:zzz9` give `98d6f0bb...` and
  `fa6b931d...` for the same graph). `B` is a single value, `37eef97d...`, for
  both -- so pre-canonicalizing with RDF.ex *repairs* graphlaw's blank-node
  non-invariance. `B` is the digest a receipt should carry if it wants a
  graphlaw-side BLAKE3 identity that is actually an identity.

  This is asserted below, in both directions, as the standing record.

  ## Real collaborators only

  This test executes the real vendored wasm law package in a real `node`
  process. It does not stub, fake or simulate graphlaw. The vendored artifact
  (`priv/graphlaw/praxis_graphlaw.wasm`, written by
  `mix ash_a2a.vendor_graphlaw`) and its node host are on `main`, so this
  runs for real there; wherever either (or `node`) is absent the test SKIPS
  visibly, naming what is missing. It never substitutes a double for the
  engine under comparison.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.CanonicalGraph

  @wasm_candidates ["praxis_graphlaw.wasm", "praxis_graphlaw_wasm.wasm"]
  @host_relative "graphlaw/host/graphlaw_host.mjs"

  # Resolved at compile time so the skip reason can be a module tag.
  @priv Path.join(File.cwd!(), "priv")
  @wasm Enum.find_value(@wasm_candidates, fn name ->
          path = Path.join([@priv, "graphlaw", name])
          if File.regular?(path), do: path
        end)
  @host (fn ->
           path = Path.join(@priv, @host_relative)
           if File.regular?(path), do: path
         end).()
  @node System.find_executable("node")

  @missing Enum.reject(
             [
               {@wasm, "priv/graphlaw/{praxis_graphlaw,praxis_graphlaw_wasm}.wasm"},
               {@host, "priv/#{@host_relative}"},
               {@node, "a `node` executable on PATH"}
             ],
             fn {found, _} -> found end
           )

  if @missing != [] do
    @moduletag skip:
                 "graphlaw wasm law package not available on this branch; missing: " <>
                   Enum.map_join(@missing, ", ", &elem(&1, 1)) <>
                   " (vendored by `mix ash_a2a.vendor_graphlaw`)"
  end

  @base "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:c .\n"
  @reordered "@prefix zz: <http://example.org/> .\nzz:b zz:p zz:c .\nzz:a zz:p zz:b .\n"
  @mutated "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:ZZZ .\n"
  @blank_b1 "@prefix ex: <http://example.org/> .\nex:a ex:p _:b1 .\n_:b1 ex:p ex:c .\n"
  @blank_zzz9 "@prefix ex: <http://example.org/> .\nex:a ex:p _:zzz9 .\n_:zzz9 ex:p ex:c .\n"

  # Real measured graphlaw v26.7.5 digests (BLAKE3, lowercase hex).
  @gl_base "9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d"
  @gl_mutated "610ccbcd4ed4b23cf4179fde360625da286557d18a15403f76797e28c1c68f66"
  @gl_blank_b1 "98d6f0bb8000170baa790b30dc641ce0bd49ca82f7f9c0ce45452c2994e2820e"
  @gl_blank_zzz9 "fa6b931d903050d2837bb557482f1669d8767ad12b1c340e68192a85de873215"
  @gl_blank_canonicalized "37eef97df291cd1de78fc2b5bb9009490cc6be459e57818a9c26c30d58e939bc"
  @gl_empty "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"

  describe "three-way agreement, blank-node-free graphs" do
    test "graphlaw(turtle) == graphlaw(RDFC-1.0 canonical N-Quads)" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@base)

      assert [direct, via_canonical] = graph_hash([@base, nquads])

      assert direct == @gl_base
      assert via_canonical == @gl_base
      assert direct == via_canonical
    end

    test "agreement survives prefix relabeling and triple reordering on both sides" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@reordered)

      assert [direct, via_canonical] = graph_hash([@reordered, nquads])

      assert direct == @gl_base
      assert via_canonical == @gl_base

      # And RDF.ex reaches the same conclusion about sameness, on its own digest.
      assert CanonicalGraph.canonical_digest(@base) ==
               CanonicalGraph.canonical_digest(@reordered)
    end

    test "both engines still discriminate a genuinely different graph" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@mutated)

      assert [direct, via_canonical] = graph_hash([@mutated, nquads])

      assert direct == @gl_mutated
      assert via_canonical == @gl_mutated
      refute direct == @gl_base

      refute CanonicalGraph.canonical_digest(@mutated) ==
               CanonicalGraph.canonical_digest(@base)
    end
  end

  describe "documented divergence, graphs containing blank nodes" do
    test "graphlaw alone is NOT blank-node-relabel invariant" do
      assert [b1, zzz9] = graph_hash([@blank_b1, @blank_zzz9])

      assert b1 == @gl_blank_b1
      assert zzz9 == @gl_blank_zzz9

      # The defect, reproduced against the real engine: same graph, two digests.
      refute b1 == zzz9
    end

    test "pre-canonicalizing with RDF.ex repairs that non-invariance" do
      {:ok, nq_b1} = CanonicalGraph.canonical_nquads(@blank_b1)
      {:ok, nq_zzz9} = CanonicalGraph.canonical_nquads(@blank_zzz9)

      assert nq_b1 == nq_zzz9

      assert [via_b1, via_zzz9] = graph_hash([nq_b1, nq_zzz9])

      assert via_b1 == @gl_blank_canonicalized
      assert via_zzz9 == @gl_blank_canonicalized
      assert via_b1 == via_zzz9
    end

    test "the divergence is real: graphlaw(turtle) != graphlaw(canonical N-Quads)" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@blank_b1)

      assert [direct, via_canonical] = graph_hash([@blank_b1, nquads])

      # Recorded honestly. The two engines do NOT agree here, because
      # graphlaw's digest is a function of the blank-node *labels* and
      # RDFC-1.0 rewrites them to _:c14n0.
      refute direct == via_canonical
      assert direct == @gl_blank_b1
      assert via_canonical == @gl_blank_canonicalized
    end
  end

  describe "the graphlaw failure modes this correction exists for" do
    test "graph_hash on unparseable input returns the empty-graph digest, not an error" do
      assert [garbage, empty] = graph_hash(["@@@ not turtle", ""])

      assert garbage == @gl_empty
      assert empty == @gl_empty
      assert garbage == empty

      # RDF.ex, on the identical inputs, distinguishes them and fails closed.
      assert {:error, {:parse_error, _}} = CanonicalGraph.canonical_digest("@@@ not turtle")
      assert {:ok, _} = CanonicalGraph.canonical_digest("")
    end

    test "the two engines use different hash functions, so digests must be labelled" do
      assert [gl_base] = graph_hash([@base])
      {:ok, rdf_base} = CanonicalGraph.canonical_digest(@base)

      assert gl_base == @gl_base
      refute gl_base == rdf_base
    end
  end

  # Executes the real vendored wasm law package via the real dependency-free
  # node host, once per call, and returns the results in order.
  defp graph_hash(inputs) when is_list(inputs) do
    Enum.each(inputs, fn input -> assert :ok = CanonicalGraph.ensure_utf8(input) end)

    request =
      Jason.encode!(%{
        "wasm" => @wasm,
        "calls" => Enum.map(inputs, &%{"fn" => "graph_hash", "args" => [&1]})
      })

    path = Path.join(System.tmp_dir!(), "graphlaw_req_#{System.unique_integer([:positive])}.json")
    File.write!(path, request)

    try do
      {out, status} = System.cmd(@node, [@host, path], stderr_to_stdout: true)
      assert status == 0, "graphlaw host exited #{status}: #{out}"

      assert %{"ok" => true, "results" => results} = Jason.decode!(out)
      assert length(results) == length(inputs)
      results
    after
      File.rm(path)
    end
  end
end
