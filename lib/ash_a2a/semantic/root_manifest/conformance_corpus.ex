defmodule AshA2A.Semantic.RootManifest.ConformanceCorpus do
  @moduledoc """
  The one reproducible source of the SA2A conformance Root Manifest.

  `priv/sa2a/root_manifest.json` is not a hand-edited document: it is the
  output of `build/1` run over the real corpus files under
  `priv/sa2a/conformance/`. Keeping the spec in code rather than in the JSON
  makes regeneration a real, checkable operation -- a test re-runs `build/1`
  over the unchanged corpus and asserts the committed manifest's content
  address is reproduced byte-for-byte.

  ## What is pinned, and what is deliberately not

  Pinned (machinery, therefore requiring standing): the admitted ontology
  root, the semantic profile, the SHACL shapes, the ShExJ schema, both ShEx
  shape maps, the N3 derivation rules, and the SPARQL falsifier.

  Deliberately NOT pinned:

  * `conformance/data/*.ttl` -- data graphs are the INPUT under judgement,
    not judges. Requiring every input to be pre-pinned would make the system
    unable to judge anything new, which is the opposite of what admission is
    for.
  * `conformance/shapes/unpinned_rogue.shacl.ttl` and
    `conformance/rules/unpinned_rogue.n3` -- these exist precisely to be
    unpinned. They are real, well-formed, engine-accepted artifacts used as
    live falsifiers: `AshA2A.Semantic.MetaAdmission` must refuse to use them
    even though the engine would happily run them, and would return an
    ADMITTED verdict if it did. See `AshA2A.Semantic.MetaAdmission`'s
    moduledoc for the measured laundering result.

  ## The ShEx front end is ShExJ, not ShExC -- a measured constraint

  The pinned schema is `command_envelope.shexj` (ShEx JSON). The engine's
  `validate_all/5` export parses its schema argument with `serde_json` into
  its native `Schema` struct; the crate's `shexc_parser` (compact ShEx
  syntax) exists but is not reachable through that export in the pinned wasm
  build. Pinning a `.shex` compact-syntax file here would pin an artifact the
  pinned engine cannot actually consume, so the corpus pins the form that
  really validates.
  """

  alias AshA2A.Semantic.{CanonicalGraph, RootManifest}
  alias AshA2A.Semantic.RootManifest.EngineProbe

  @expected_engine_version "praxis-graphlaw v26.7.5"

  @doc """
  Absolute path of the corpus root -- the directory the manifest's relative
  pin paths resolve against, and the directory the manifest itself lives in.
  """
  @spec root() :: String.t()
  def root, do: Path.join(to_string(:code.priv_dir(:ash_a2a)), "sa2a")

  @doc "Absolute path of the committed manifest document."
  @spec manifest_path() :: String.t()
  def manifest_path, do: Path.join(root(), "root_manifest.json")

  @doc """
  The engine version this corpus was pinned against, as really reported by
  `graphlaw_version()` at pin time.
  """
  @spec expected_engine_version() :: String.t()
  def expected_engine_version, do: @expected_engine_version

  @doc """
  Relative paths of the deliberately UNPINNED falsifier artifacts, exposed
  so tests name them from one place rather than restating string literals.
  """
  @spec unpinned_falsifiers() :: %{shacl_shapes: String.t(), n3_rules: String.t()}
  def unpinned_falsifiers do
    %{
      shacl_shapes: "conformance/shapes/unpinned_rogue.shacl.ttl",
      n3_rules: "conformance/rules/unpinned_rogue.n3"
    }
  end

  @doc "The complete manifest spec consumed by `AshA2A.Semantic.RootManifest.build/2`."
  @spec spec(keyword()) :: keyword()
  def spec(opts \\ []) do
    [
      canonicalization:
        Map.put(
          CanonicalGraph.identity(),
          "note",
          "RFC S12 canonical graph identity is executed in-BEAM by RDF.ex's RDFC-1.0. " <>
            "praxis-graphlaw's wasm graph_hash (BLAKE3) is an engine digest: not " <>
            "blank-node invariant and not RDFC-1.0, so it is not pinned as canonicalization."
        ),
      hash_algorithms: %{
        "manifest_content" => "sha256",
        "artifact_pin" => "sha256",
        "graph_identity" => CanonicalGraph.hash_function(),
        "engine_graph_digest" => "BLAKE3",
        "note" =>
          "The manifest self-checks with sha256 via OTP :crypto, deliberately " <>
            "not with the BLAKE3 inside the engine artifact it pins -- that " <>
            "would be circular."
      },
      engine: [
        id: "praxis-graphlaw-wasm",
        abi: "wasm-bindgen",
        expected_version: Keyword.get(opts, :expected_version, @expected_engine_version),
        path: Keyword.get(opts, :engine_path) || EngineProbe.wasm_path(opts)
      ],
      ontology_roots: [
        [
          id: "urn:ash-a2a:vocab",
          kind: :ontology_root,
          path: "conformance/ontology/a2a_vocab.ttl"
        ]
      ],
      semantic_profiles: [
        [
          id: "urn:ash-a2a:profile:sa2a:1",
          kind: :semantic_profile,
          path: "conformance/profile/sa2a_profile.ttl"
        ]
      ],
      validators: [
        [
          id: "urn:ash-a2a:shapes:command-envelope",
          kind: :shacl_shapes,
          path: "conformance/shapes/command_envelope.shacl.ttl"
        ],
        [
          id: "urn:ash-a2a:schema:command-envelope",
          kind: :shex_schema,
          path: "conformance/schema/command_envelope.shexj"
        ],
        [
          id: "urn:ash-a2a:shapemap:command-001",
          kind: :shex_shape_map,
          path: "conformance/schema/command_envelope.shapemap"
        ],
        [
          id: "urn:ash-a2a:shapemap:command-002",
          kind: :shex_shape_map,
          path: "conformance/schema/invalid_command.shapemap"
        ],
        [
          id: "urn:ash-a2a:rules:envelope-derivation",
          kind: :n3_rules,
          path: "conformance/rules/derivation.n3"
        ],
        [
          id: "urn:ash-a2a:falsifier:unauthorized-actuation",
          kind: :sparql_falsifier,
          path: "conformance/queries/falsifier_unauthorized_actuation.rq"
        ]
      ],
      manufacturers: [
        %{
          "id" => "praxis-graphlaw",
          "role" => "semantic_engine",
          "owns" => ["engine_graph_digest", "shacl", "shex", "datalog", "n3", "sparql", "blake3"]
        },
        %{
          "id" => "ash_a2a",
          "role" => "semantic_host",
          "owns" => [
            "canonical_graph_identity",
            "envelope",
            "standing",
            "refusal_typing",
            "authority",
            "receipts",
            "admission_orchestration",
            "a2a_boundary"
          ]
        }
      ],
      authority_broker: %{
        "behaviour" => "Elixir.AshA2A.Authority.Broker",
        "implementations" => [
          "Elixir.AshA2A.Authority.Broker.InMemory",
          "Elixir.AshA2A.Authority.Broker.Ekv"
        ],
        "authority_struct" => "Elixir.AshA2A.Authority"
      },
      brce_contract: %{
        "module" => "Elixir.AshA2A.CommandBus",
        "admission" => "admit/2",
        "principle" => "zero unreceipted actuation"
      },
      receipt_law: %{
        "receipt" => "Elixir.AshA2A.Receipt",
        "store" => "Elixir.AshA2A.ReceiptStore",
        "outbox" => "Elixir.AshA2A.ReceiptOutbox"
      },
      version_policy: %{
        "mutation_capability_id" => RootManifest.mutation_capability_id(),
        "custody_source" => Atom.to_string(RootManifest.custody_source()),
        "mutation_moves_content_address" => true,
        "ordinary_transport_agents_may_mutate" => false
      }
    ]
  end

  @doc """
  Builds the manifest from the real corpus on disk. Deterministic: an
  unchanged corpus always produces the same content address.
  """
  @spec build(keyword()) :: {:ok, RootManifest.t()} | {:error, map()}
  def build(opts \\ []) do
    RootManifest.build(Keyword.get(opts, :root, root()), spec(opts))
  end

  @doc """
  Rebuilds and writes `priv/sa2a/root_manifest.json`. Used by
  `mix ash_a2a.sa2a.pin_root_manifest`.
  """
  @spec regenerate!(keyword()) :: RootManifest.t()
  def regenerate!(opts \\ []) do
    case build(opts) do
      {:ok, manifest} ->
        RootManifest.write!(manifest, Keyword.get(opts, :path, manifest_path()))
        manifest

      {:error, refusal} ->
        raise "root manifest build refused: #{inspect(refusal)}"
    end
  end
end
