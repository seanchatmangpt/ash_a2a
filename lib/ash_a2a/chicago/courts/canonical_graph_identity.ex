defmodule AshA2A.Chicago.Courts.CanonicalGraphIdentity do
  @moduledoc """
  RFC-SA2A-002 §50 Canonical Graph Identity court (RFC-SA2A-001 S12, S21).

    * Isomorphism: triple reorder, prefix reorder / equivalent aliases,
      whitespace and serialization variation, blank-node relabeling and
      anonymous blank-node syntax must all yield the same RFC S12 identity
      through the real `AshA2A.Semantic.CanonicalGraph.compare/2`
      (RDFC-1.0 over RDF.ex, SHA-256 over sorted N-Quads).
    * Discrimination: a changed IRI and a non-isomorphic blank-node structure
      over the same terms must yield different identities.
    * Fail closed: malformed Turtle, a valid graph followed by garbage (the
      input the vendored wasm `graph_hash` silently hashes as its parseable
      prefix) and non-UTF-8 bytes never receive a digest; the lawful empty
      graph does.
    * Pinning: the canonicalization algorithm, digest function and
      implementation are pinned by the Root Manifest. A manifest whose pin
      drifts from the executing identity -- with a correctly recomputed
      content address -- must be refused by the real
      `AshA2A.Semantic.RootManifest.load/2`, and the committed manifest must
      load with its pin verified.

  Attempt evidence comes from the boundaries' own telemetry
  (`[:ash_a2a, :semantic, :canonical_graph, :digest | :compare | :pin]`,
  `[:ash_a2a, :semantic, :root_manifest, :load]`), mapped by
  `AshA2A.Chicago.Fixtures.CanonicalIdentity.mappings/0`.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.CanonicalIdentity, as: F
  alias AshA2A.Semantic.{CanonicalGraph, RootManifest}

  @court "SA2A-CANON"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Canonical graph identity: isomorphism, discrimination, fail-closed, pinning"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§12", "§50", "§53", "§100", "RFC-SA2A-001 S12", "S21"]

  @impl true
  def ocel_mappings, do: F.mappings()

  # --- declarations -----------------------------------------------------------

  @compare_attempt {:observed, "canonical_graph.compare"}
  @compare_same {:observed, "canonical_graph.compare", %{"outcome" => "same_identity"}}
  @compare_not_same {:any,
                     [
                       {:observed, "canonical_graph.compare",
                        %{"outcome" => "distinct_identity"}},
                       {:observed, "canonical_graph.compare", %{"outcome" => "refused"}}
                     ]}
  @digest_attempt {:observed, "canonical_graph.digest"}
  @digested {:observed, "canonical_graph.digest", %{"outcome" => "digested"}}
  @load_attempt {:observed, "root_manifest.load"}
  @loaded {:observed, "root_manifest.load", %{"outcome" => "loaded"}}

  @isomorphic [
    {1, :iso_triple_reorder, "triple reorder"},
    {2, :iso_prefix_alias,
     "prefix reorder, SPARQL-style PREFIX, an unused alias and two aliases for one namespace"},
    {3, :iso_serialization,
     "whitespace, comments, predicate/object lists, a bare integer and N-Triples syntax"},
    {4, :iso_bnode_relabel, "blank-node relabeling"},
    {5, :iso_bnode_anonymous, "anonymous `[ ]` blank-node syntax with reordered predicates"}
  ]

  @malformed [
    {8, :unterminated, "an unterminated literal"},
    {9, :trailing_garbage,
     "a valid graph followed by garbage (hashed by the wasm graph_hash as its parseable prefix)"},
    {10, :invalid_utf8, "non-UTF-8 bytes inside a literal"}
  ]

  @drifts [
    {12, :algorithm, "the canonicalization algorithm (URDNA2015 instead of RDFC-1.0)"},
    {13, :hash_function, "the digest function (SHA-384 instead of SHA-256)"},
    {14, :implementation,
     "the implementation (praxis-graphlaw wasm graph_hash, BLAKE3, not blank-node invariant)"}
  ]

  @impl true
  def falsifiers do
    Enum.map(@isomorphic, fn {n, doc, what} ->
      declare(n, :negative,
        invariant: "G1 ≅ G2 ⇒ Digest(G1) = Digest(G2) under #{what}",
        stimulus: "CanonicalGraph.compare/2 of :base and :#{doc}",
        boundary: "AshA2A.Semantic.CanonicalGraph.compare/2 (RDFC-1.0 canonicalization)",
        forbidden_outcome: "distinct_identity or refused for isomorphic graphs",
        attempt_evidence: "canonical_graph.compare observed",
        survival_evidence: "canonical_graph.compare outcome=distinct_identity|refused",
        guard:
          "RDF.Graph.canonical_hash/1: RDFC-1.0 canonicalize + sorted N-Quads before SHA-256",
        failure_class: :identity_failure,
        attempt_predicate: @compare_attempt,
        outcome_predicate: @compare_not_same,
        tags: [:isomorphism, doc]
      )
    end) ++
      [
        declare(6, :negative,
          invariant:
            "A semantically distinct graph (one object IRI changed) has a different identity",
          stimulus: "CanonicalGraph.compare/2 of :base and :distinct_iri",
          boundary: "AshA2A.Semantic.CanonicalGraph.compare/2",
          forbidden_outcome: "same_identity",
          attempt_evidence: "canonical_graph.compare observed",
          survival_evidence: "canonical_graph.compare outcome=same_identity",
          guard: "SHA-256 over the full canonical N-Quads (no lossy normalisation)",
          failure_class: :identity_failure,
          attempt_predicate: @compare_attempt,
          outcome_predicate: @compare_same
        ),
        declare(7, :negative,
          invariant:
            "Non-isomorphic blank-node structure over the same terms and triple count has a different identity",
          stimulus: "CanonicalGraph.compare/2 of :bnode_chain and :distinct_bnode_structure",
          boundary: "AshA2A.Semantic.CanonicalGraph.compare/2 (RDFC-1.0 n-degree hashing)",
          forbidden_outcome: "same_identity",
          attempt_evidence: "canonical_graph.compare observed",
          survival_evidence: "canonical_graph.compare outcome=same_identity",
          guard: "RDFC-1.0 blank-node hashing over graph structure, not over labels or counts",
          failure_class: :identity_failure,
          attempt_predicate: @compare_attempt,
          outcome_predicate: @compare_same
        )
      ] ++
      Enum.map(@malformed, fn {n, input, what} ->
        declare(n, :negative,
          invariant:
            "Malformed RDF (#{what}) fails closed: no digest, never an empty/unrelated graph's",
          stimulus: "CanonicalGraph.canonical_digest/1 of malformed(:#{input})",
          boundary: "AshA2A.Semantic.CanonicalGraph.canonical_digest/1",
          forbidden_outcome: "a digest is returned",
          attempt_evidence: "canonical_graph.digest observed",
          survival_evidence: "canonical_graph.digest outcome=digested",
          guard: "CanonicalGraph.parse/1 (ensure_utf8 + RDF.Turtle.read_string typed error)",
          failure_class: :identity_failure,
          attempt_predicate: @digest_attempt,
          outcome_predicate: @digested,
          tags: [:fail_closed, input]
        )
      end) ++
      [
        declare(11, :positive_control,
          invariant:
            "Positive control for 008-010: the lawful empty graph and a well-formed graph receive digests",
          stimulus: "CanonicalGraph.canonical_digest/1 of \"\" and of :base",
          boundary: "AshA2A.Semantic.CanonicalGraph.canonical_digest/1",
          attempt_evidence: "canonical_graph.digest observed",
          survival_evidence: "every canonical_graph.digest outcome=digested",
          attempt_predicate: @digest_attempt,
          outcome_predicate:
            {:all,
             [@digested, {:not_observed, "canonical_graph.digest", %{"outcome" => "refused"}}]}
        )
      ] ++
      Enum.map(@drifts, fn {n, drift, what} ->
        declare(n, :negative,
          invariant:
            "The Root Manifest pins #{what}; a manifest pinning a different identity is refused at load",
          stimulus:
            "RootManifest.load/2 of a committed-manifest copy with a drifted canonicalization pin and a recomputed content address",
          boundary: "AshA2A.Semantic.RootManifest.load/2",
          forbidden_outcome: "the drifted manifest loads",
          attempt_evidence: "root_manifest.load observed",
          survival_evidence: "root_manifest.load outcome=loaded",
          guard: "RootManifest.load/2 canonicalization check (CanonicalGraph.verify_pin/1)",
          failure_class: :meta_admission_failure,
          attempt_predicate: @load_attempt,
          outcome_predicate: @loaded,
          tags: [:pin, drift]
        )
      end) ++
      [
        declare(15, :positive_control,
          invariant:
            "Positive control for 012-014: the committed Root Manifest pins the executing identity and loads with the pin verified",
          stimulus: "RootManifest.load/2 of priv/sa2a/root_manifest.json",
          boundary: "AshA2A.Semantic.RootManifest.load/2 + CanonicalGraph.verify_pin/1",
          attempt_evidence: "root_manifest.load observed",
          survival_evidence:
            "root_manifest.load loaded and canonical_graph.pin verified; every pinned key equals CanonicalGraph.identity/0",
          attempt_predicate: @load_attempt,
          outcome_predicate:
            {:all, [@loaded, {:observed, "canonical_graph.pin", %{"outcome" => "verified"}}]}
        )
      ]
  end

  defp fid(n), do: "#{@court}-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp declare(n, kind, fields) do
    Falsifier.new!([id: fid(n), court_id: @court, kind: kind, rfc_sections: ["§50"]] ++ fields)
  end

  # --- execution --------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = fn n -> Map.fetch!(fs, fid(n)) end

    Enum.map(@isomorphic, fn {n, doc, _} -> compare(ctx, f.(n), :base, doc) end) ++
      [
        compare(ctx, f.(6), :base, :distinct_iri),
        compare(ctx, f.(7), :bnode_chain, :distinct_bnode_structure)
      ] ++
      Enum.map(@malformed, fn {n, input, _} -> malformed(ctx, f.(n), input) end) ++
      [lawful_digests(ctx, f.(11))] ++
      Enum.map(@drifts, fn {n, drift, _} -> drift(ctx, f.(n), drift) end) ++
      [committed_pin(ctx, f.(15))]
  end

  defp compare(ctx, falsifier, left, right) do
    reply =
      Context.stimulus(ctx, falsifier, fn ->
        CanonicalGraph.compare(F.graph(left), F.graph(right))
      end)

    attempt = F.observed?(ctx, falsifier, "canonical_graph.compare")
    evidence = %{"left" => left, "right" => right, "reply" => inspect(reply)}

    forbidden =
      case falsifier.tags do
        [:isomorphism | _] -> reply != {:ok, :same_identity}
        _ -> reply == {:ok, :same_identity}
      end

    Result.negative(falsifier,
      attempt_observed?: attempt,
      forbidden_outcome_observed?: forbidden,
      evidence: evidence
    )
  end

  defp malformed(ctx, falsifier, input) do
    reply =
      Context.stimulus(ctx, falsifier, fn ->
        CanonicalGraph.canonical_digest(F.malformed(input))
      end)

    Result.negative(falsifier,
      attempt_observed?: F.observed?(ctx, falsifier, "canonical_graph.digest"),
      forbidden_outcome_observed?: match?({:ok, _}, reply),
      evidence: %{"input" => input, "reply" => inspect(reply)}
    )
  end

  defp lawful_digests(ctx, falsifier) do
    replies =
      Context.stimulus(ctx, falsifier, fn ->
        [CanonicalGraph.canonical_digest(""), CanonicalGraph.canonical_digest(F.graph(:base))]
      end)

    distinct? =
      case replies do
        [{:ok, empty}, {:ok, base}] -> empty != base
        _ -> false
      end

    Result.positive(falsifier,
      attempt_observed?: F.observed?(ctx, falsifier, "canonical_graph.digest"),
      expected_outcome_observed?: Enum.all?(replies, &match?({:ok, _}, &1)) and distinct?,
      evidence: %{"replies" => inspect(replies)}
    )
  end

  defp drift(ctx, falsifier, drift) do
    case F.drifted_manifest(ctx.evidence_dir, drift) do
      {:ok, path} ->
        reply =
          Context.stimulus(ctx, falsifier, fn ->
            RootManifest.load(path, F.manifest_load_opts())
          end)

        Result.negative(falsifier,
          attempt_observed?: F.observed?(ctx, falsifier, "root_manifest.load"),
          forbidden_outcome_observed?: match?({:ok, _}, reply),
          evidence: %{"drift" => drift, "reply" => manifest_reply(reply)}
        )

      {:error, reason} ->
        Result.blocked(falsifier, "committed Root Manifest did not load: #{inspect(reason)}")
    end
  end

  defp committed_pin(ctx, falsifier) do
    reply =
      Context.stimulus(ctx, falsifier, fn ->
        RootManifest.load(F.committed_manifest_path(), F.manifest_load_opts())
      end)

    identity = CanonicalGraph.identity()

    pinned_matches? =
      case reply do
        {:ok, %RootManifest{canonicalization: pinned}} ->
          Enum.all?(identity, fn {k, v} -> Map.get(pinned, k) == v end)

        _ ->
          false
      end

    Result.positive(falsifier,
      attempt_observed?: F.observed?(ctx, falsifier, "root_manifest.load"),
      expected_outcome_observed?:
        pinned_matches? and
          F.observed?(ctx, falsifier, "canonical_graph.pin", %{"outcome" => "verified"}),
      evidence: %{"reply" => manifest_reply(reply), "executing_identity" => identity}
    )
  end

  defp manifest_reply({:ok, manifest}), do: %{"loaded" => manifest.digest}

  defp manifest_reply({:error, %{code: code} = refusal}),
    do: %{"code" => code, "detail" => inspect(refusal.detail)}
end
