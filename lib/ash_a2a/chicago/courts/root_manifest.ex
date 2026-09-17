defmodule AshA2A.Chicago.Courts.RootManifest do
  @moduledoc """
  RFC-SA2A-002 §53 Root Manifest Court (`SA2A-ROOT`).

  The court attacks every trust-root binding §53 names at the real boundaries
  that decide them -- `AshA2A.Semantic.RootManifest.load/2` (load phase),
  `AshA2A.Semantic.RootManifest.verify_use/2` (use phase, what every consumer
  such as `AshA2A.Semantic.MetaAdmission.document_standing/4` runs) and
  `AshA2A.Semantic.RootManifest.mutate/5` -- over a staged copy of the
  committed conformance corpus (`AshA2A.Chicago.Fixtures.RootManifestMeta`):

  | id  | binding                         | attack                                                              |
  |-----|---------------------------------|---------------------------------------------------------------------|
  | 001 | content addressing              | an addressed field edited on disk, recorded digest untouched         |
  | 002 | ontology roots                  | pinned ontology root substituted after load, receipt untouched       |
  | 003 | semantic profile version        | held manifest's profile pin re-versioned in memory, receipt untouched |
  | 004 | canonicalization identity       | re-addressed manifest claiming another canonical graph identity      |
  | 005 | manufacturer identities         | re-addressed manifest with the engine manufacturer removed           |
  | 006 | validator identities            | pinned SHACL shapes substituted at use time, receipt untouched       |
  | 007 | compiler/engine identity        | engine artifact substituted at use time, receipt untouched           |
  | 008 | Authority Broker identity       | a non-broker module named as a broker implementation                 |
  | 009 | BRCE contract                   | a boundary function the BRCE module does not export (`admit/2`)      |
  | 010 | receipt law                     | a receipt store module that does not exist                           |
  | 011 | cryptographic algorithms        | artifact pins claimed as sha3-256                                    |
  | 012 | version policy                  | policy letting ordinary transport agents mutate                      |
  | 013 | custody (version policy, S21)   | a transport-verified authority attempts `mutate/5`                   |
  | 014 | positive control                | the committed manifest loads (engine executed) and verifies at use   |
  | 015 | positive control                | a custodian mutation moves the address and verifies at use           |

  Attempts are keyed on the decision event of the boundary
  (`semantic.root_manifest.verify` for the phase, `semantic.root_manifest.mutate`)
  in any outcome, so removing a check makes its falsifier survive (§11, §22).
  Independent post-state readers re-digest the staged files with `:crypto`,
  never through `RootManifest`.

  Measured defect found while building this court and repaired: the committed
  manifest pinned the BRCE contract as `AshA2A.CommandBus.admit/2`, a private
  function -- the pinned contract named no exported boundary. The pin is now
  the exported sole-DO entry `run/4` (009 attacks the old pin).
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.RootManifestMeta, as: F
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission.Evidence
  alias AshA2A.Semantic.MetaAdmission
  alias AshA2A.Semantic.RootManifest, as: Root
  alias AshA2A.Semantic.RootManifest.{ConformanceCorpus, EngineProbe}

  @id "SA2A-ROOT"
  @verify "semantic.root_manifest.verify"
  @mutate "semantic.root_manifest.mutate"

  @use_cases [
    {"002", "ontology_roots", :pins,
     "after a verified load (receipt = its digest), the pinned ontology root file gains a triple; RootManifest.verify_use/2 with expected_digest: receipt"},
    {"003", "semantic_profiles", :content_address,
     "the held manifest's semantic profile pin re-versioned to urn:ash-a2a:profile:sa2a:2 in memory, recorded digest untouched; RootManifest.verify_use/2 with expected_digest: receipt"},
    {"004", "canonicalization", :canonicalization,
     "a re-addressed manifest declaring canonical graph identity URDNA2015/SHA-1/n-quads; RootManifest.verify_use/2"},
    {"005", "manufacturers", :manufacturers,
     "a re-addressed manifest without the praxis-graphlaw semantic_engine manufacturer; RootManifest.verify_use/2"},
    {"006", "validators", :pins,
     "after a verified load, the pinned command-envelope SHACL shapes replaced by the unpinned rogue shapes; RootManifest.verify_use/2 with expected_digest: receipt and MetaAdmission.standing/3 of the shapes"},
    {"007", "engine", :engine,
     "the committed manifest verified at use with the engine resolved to a byte-flipped copy of the pinned wasm; RootManifest.verify_use/2 with expected_digest: receipt"},
    {"008", "authority_broker", :authority_broker,
     "a re-addressed manifest naming Elixir.AshA2A.Receipt as an Authority Broker implementation; RootManifest.verify_use/2"},
    {"009", "brce_contract", :brce_contract,
     "a re-addressed manifest pinning the BRCE boundary as AshA2A.CommandBus.admit/2 (private); RootManifest.verify_use/2"},
    {"010", "receipt_law", :receipt_law,
     "a re-addressed manifest naming Elixir.AshA2A.ReceiptStoreForged as the receipt store; RootManifest.verify_use/2"},
    {"011", "hash_algorithms", :hash_algorithms,
     "a re-addressed manifest claiming artifact pins are sha3-256; RootManifest.verify_use/2"},
    {"012", "version_policy", :version_policy,
     "a re-addressed manifest whose version policy lets ordinary transport agents mutate; RootManifest.verify_use/2"}
  ]

  @impl true
  def id, do: @id
  @impl true
  def title, do: "Root Manifest: content-addressed trust root, use-time substitution"
  @impl true
  def gate, do: 1
  @impl true
  def profile, do: :strict
  @impl true
  def rfc_sections, do: ["§53", "§100"]

  @impl true
  def ocel_mappings, do: F.mappings()

  # --- declarations -------------------------------------------------------------

  @impl true
  def falsifiers do
    load =
      Falsifier.new!(
        id: "#{@id}-001",
        court_id: @id,
        kind: :negative,
        invariant:
          "The Root Manifest is content-addressed: a document whose contents no longer produce its recorded address MUST NOT load (§53, RFC-SA2A-001 S21)",
        stimulus:
          "RootManifest.load/2 of a staged manifest whose version_policy.ordinary_transport_agents_may_mutate was edited to true on disk, recorded digest untouched",
        boundary: "AshA2A.Semantic.RootManifest.load/2",
        forbidden_outcome:
          "semantic.root_manifest.verify phase=load outcome=verified; {:ok, manifest}",
        attempt_evidence: "semantic.root_manifest.verify phase=load (any outcome)",
        survival_evidence: "semantic.root_manifest.verify phase=load outcome=verified in OCEL",
        guard: "RootManifest.verify_self_address/2 (REFUSED_MANIFEST_DIGEST_MISMATCH)",
        failure_class: :identity_failure,
        rfc_sections: ["§53"],
        attempt_predicate: {:observed, @verify, %{"phase" => "load"}},
        outcome_predicate: {:observed, @verify, %{"phase" => "load", "outcome" => "verified"}}
      )

    use_time =
      for {n, binding, component, stimulus} <- @use_cases do
        Falsifier.new!(
          id: "#{@id}-#{n}",
          court_id: @id,
          kind: :negative,
          invariant:
            "The Root Manifest binds #{binding}: a use-time substitution of that component MUST be detected, whatever manifest receipt the consumer holds (§53)",
          stimulus: stimulus,
          boundary: "AshA2A.Semantic.RootManifest.verify_use/2",
          forbidden_outcome:
            "semantic.root_manifest.verify phase=use outcome=verified; {:ok, manifest}",
          attempt_evidence: "semantic.root_manifest.verify phase=use (any outcome)",
          survival_evidence:
            "semantic.root_manifest.verify phase=use outcome=verified in OCEL; independent file digests",
          guard: "RootManifest.verify_use/2 #{component} check",
          failure_class: :identity_failure,
          rfc_sections: ["§53"],
          attempt_predicate: {:observed, @verify, %{"phase" => "use"}},
          outcome_predicate: {:observed, @verify, %{"phase" => "use", "outcome" => "verified"}}
        )
      end

    custody =
      Falsifier.new!(
        id: "#{@id}-013",
        court_id: @id,
        kind: :negative,
        invariant:
          "No ordinary agent MAY mutate the Root Manifest (RFC-SA2A-001 S21): a transport-verified authority with the right capability and subject is refused",
        stimulus:
          "RootManifest.mutate/5 of the staged manifest's version policy with Authority source: :transport_verified for root_manifest:mutate and the matching principal",
        boundary: "AshA2A.Semantic.RootManifest.mutate/5",
        forbidden_outcome: "semantic.root_manifest.mutate outcome=mutated; {:ok, manifest}",
        attempt_evidence: "semantic.root_manifest.mutate (any outcome)",
        survival_evidence: "semantic.root_manifest.mutate outcome=mutated in OCEL",
        guard: "RootManifest.mutate/5 custody source gate (REFUSED_ROOT_CUSTODY)",
        failure_class: :authority_failure,
        rfc_sections: ["§53"],
        attempt_predicate: {:observed, @mutate},
        outcome_predicate: {:observed, @mutate, %{"outcome" => "mutated"}}
      )

    controls = [
      Falsifier.new!(
        id: "#{@id}-014",
        court_id: @id,
        kind: :positive_control,
        invariant:
          "The committed Root Manifest loads with its engine executed and verifies at use against its own receipt: the checks discriminate (§100)",
        stimulus:
          "RootManifest.load/2 of priv/sa2a/root_manifest.json (require_engine: true), then RootManifest.verify_use/2 with expected_digest: its digest",
        boundary: "AshA2A.Semantic.RootManifest.load/2 + verify_use/2",
        attempt_evidence: "semantic.root_manifest.verify phase=load",
        survival_evidence:
          "semantic.root_manifest.verify phase=load outcome=verified and phase=use outcome=verified",
        rfc_sections: ["§53", "§100"],
        attempt_predicate: {:observed, @verify, %{"phase" => "load"}},
        outcome_predicate:
          {:all,
           [
             {:observed, @verify, %{"phase" => "load", "outcome" => "verified"}},
             {:observed, @verify, %{"phase" => "use", "outcome" => "verified"}}
           ]}
      ),
      Falsifier.new!(
        id: "#{@id}-015",
        court_id: @id,
        kind: :positive_control,
        invariant:
          "A root-custodian mutation is admitted, moves the content address, and the new manifest verifies at use against its new receipt (§100, RFC-SA2A-001 S21)",
        stimulus:
          "RootManifest.mutate/5 of the staged manifest's version policy with Authority source: :root_custodian, then RootManifest.verify_use/2 with expected_digest: the new digest",
        boundary: "AshA2A.Semantic.RootManifest.mutate/5 + verify_use/2",
        attempt_evidence: "semantic.root_manifest.mutate",
        survival_evidence:
          "semantic.root_manifest.mutate outcome=mutated and semantic.root_manifest.verify phase=use outcome=verified",
        rfc_sections: ["§53", "§100"],
        attempt_predicate: {:observed, @mutate},
        outcome_predicate:
          {:all,
           [
             {:observed, @mutate, %{"outcome" => "mutated"}},
             {:observed, @verify, %{"phase" => "use", "outcome" => "verified"}}
           ]}
      )
    ]

    [load] ++ use_time ++ [custody] ++ controls
  end

  # --- execution -----------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    case Root.current_engine_digest() do
      {:ok, _} ->
        run_cases(ctx)

      {:error, refusal} ->
        # Every staged manifest pins the engine artifact: without it nothing
        # here can be built, so nothing is decided -- blocked, never killed.
        Enum.map(
          falsifiers(),
          &Result.blocked(&1, "engine artifact not resolvable: #{inspect(refusal, limit: 6)}")
        )
    end
  end

  defp run_cases(ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = fn n -> Map.fetch!(fs, "#{@id}-#{n}") end
    root = Path.join(ctx.evidence_dir, "sa2a-root")

    use_results =
      for {n, _binding, component, _stimulus} <- @use_cases do
        guarded(f.(n), fn -> use_case(ctx, f.(n), Path.join(root, n), {component, n}) end)
      end

    [guarded(f.("001"), fn -> load_case(ctx, f.("001"), Path.join(root, "001")) end)] ++
      use_results ++
      [
        guarded(f.("013"), fn -> custody_case(ctx, f.("013"), Path.join(root, "013")) end),
        guarded(f.("014"), fn -> committed_case(ctx, f.("014")) end),
        guarded(f.("015"), fn -> custodian_case(ctx, f.("015"), Path.join(root, "015")) end)
      ]
  end

  defp guarded(%Falsifier{} = f, fun) do
    fun.()
  rescue
    exception ->
      Result.unknown(f, "raised: " <> Exception.format(:error, exception, __STACKTRACE__))
  end

  # --- 001 ------------------------------------------------------------------------

  defp load_case(ctx, f, dir) do
    staged = F.stage_corpus!(dir)
    original = F.file_sha256(staged.path)

    edited =
      staged.path
      |> File.read!()
      |> JSON.decode!()
      |> put_in(["version_policy", "ordinary_transport_agents_may_mutate"], true)

    File.write!(staged.path, JSON.encode!(edited))

    reply = Context.stimulus(ctx, f, fn -> Root.load(staged.path, require_engine: false) end)

    # Independent reader: the bytes changed, the recorded address did not.
    recorded = staged.path |> File.read!() |> JSON.decode!() |> Map.get("digest")

    Result.negative(f,
      attempt_observed?: Evidence.seen?(ctx, f, @verify, %{"phase" => "load"}),
      forbidden_outcome_observed?:
        Evidence.seen?(ctx, f, @verify, %{"phase" => "load", "outcome" => "verified"}) or
          match?({:ok, _}, reply),
      evidence: %{
        "document_bytes_changed" => original != F.file_sha256(staged.path),
        "recorded_digest_untouched" => recorded == staged.manifest.digest,
        "reply" => describe(reply)
      }
    )
  end

  # --- 002-012 ----------------------------------------------------------------------

  defp use_case(ctx, f, dir, case_key) do
    staged = F.stage_corpus!(dir)
    {:ok, held} = Root.load(staged.path, require_engine: false)
    receipt = held.digest
    {manifest, verify_opts, extra, independent} = substitute(case_key, staged, held, dir)

    reply =
      Context.stimulus(ctx, f, fn ->
        {Root.verify_use(manifest, verify_opts), extra.()}
      end)

    {verified, consumer} = reply

    Result.negative(f,
      attempt_observed?: Evidence.seen?(ctx, f, @verify, %{"phase" => "use"}),
      forbidden_outcome_observed?:
        Evidence.seen?(ctx, f, @verify, %{"phase" => "use", "outcome" => "verified"}) or
          match?({:ok, _}, verified) or match?({:ok, _}, consumer),
      evidence:
        Map.merge(independent.(), %{
          "receipt" => receipt,
          "reply" => describe(verified),
          "consumer_reply" => describe(consumer),
          "refused_component" => refused_component(verified)
        })
    )
  end

  # Each substitution returns {manifest to verify, verify_use opts, an extra
  # in-stimulus consumer call, an independent post-state reader}.
  defp substitute({:pins, "002"}, staged, held, _dir) do
    path = Path.join(staged.root, "conformance/ontology/a2a_vocab.ttl")
    pinned = held.ontology_roots |> hd() |> Map.fetch!("digest")

    File.write!(
      path,
      File.read!(path) <> "\n<urn:ash-a2a:substituted> <urn:ash-a2a:p> <urn:ash-a2a:o> .\n"
    )

    {held, [expected_digest: held.digest], fn -> :no_consumer end,
     fn -> %{"ontology_root_bytes_match_pin" => "sha256:" <> F.file_sha256(path) == pinned} end}
  end

  defp substitute({:pins, "006"}, staged, held, _dir) do
    relative = "conformance/shapes/command_envelope.shacl.ttl"
    path = Path.join(staged.root, relative)
    rogue = Path.join(staged.root, ConformanceCorpus.unpinned_falsifiers().shacl_shapes)
    {:ok, pin} = Root.find_pin(held, relative, "shacl_shapes")
    File.write!(path, File.read!(rogue))

    {held, [expected_digest: held.digest],
     fn -> MetaAdmission.standing(held, relative, "shacl_shapes") end,
     fn -> %{"shapes_bytes_match_pin" => "sha256:" <> F.file_sha256(path) == pin["digest"]} end}
  end

  defp substitute({:content_address, _n}, _staged, held, _dir) do
    [profile] = held.semantic_profiles
    manifest = %{held | semantic_profiles: [Map.put(profile, "id", "urn:ash-a2a:profile:sa2a:2")]}

    {manifest, [expected_digest: held.digest], fn -> :no_consumer end,
     fn -> %{"recorded_digest_untouched" => manifest.digest == held.digest} end}
  end

  defp substitute({:engine, _n}, _staged, held, dir) do
    wasm = EngineProbe.wasm_path([])
    copy = F.flipped_copy!(wasm, Path.join(dir, "substituted_engine.wasm"))

    {held, [expected_digest: held.digest, wasm_path: copy], fn -> :no_consumer end,
     fn ->
       %{
         "substituted_engine_sha256" => F.file_sha256(copy),
         "pinned_engine_artifact" => held.engine["artifact_digest"]
       }
     end}
  end

  defp substitute({component, _n}, _staged, held, _dir) do
    changes =
      case component do
        :canonicalization ->
          %{
            canonicalization:
              Map.put(held.canonicalization, "graph_identity", "URDNA2015/SHA-1/n-quads")
          }

        :manufacturers ->
          %{manufacturers: Enum.reject(held.manufacturers, &(&1["role"] == "semantic_engine"))}

        :authority_broker ->
          %{
            authority_broker:
              Map.update!(
                held.authority_broker,
                "implementations",
                &(&1 ++ ["Elixir.AshA2A.Receipt"])
              )
          }

        :brce_contract ->
          %{brce_contract: Map.put(held.brce_contract, "boundary", "admit/2")}

        :receipt_law ->
          %{receipt_law: Map.put(held.receipt_law, "store", "Elixir.AshA2A.ReceiptStoreForged")}

        :hash_algorithms ->
          %{hash_algorithms: Map.put(held.hash_algorithms, "artifact_pin", "sha3-256")}

        :version_policy ->
          %{
            version_policy:
              Map.put(held.version_policy, "ordinary_transport_agents_may_mutate", true)
          }
      end

    manifest = F.readdressed(held, changes)

    {manifest, [], fn -> :no_consumer end,
     fn ->
       %{
         "self_consistent_address" => manifest.digest != held.digest,
         "substituted_fields" => changes |> Map.keys() |> Enum.map(&Atom.to_string/1)
       }
     end}
  end

  # --- 013 ----------------------------------------------------------------------------

  defp custody_case(ctx, f, dir) do
    staged = F.stage_corpus!(dir)
    {:ok, held} = Root.load(staged.path, require_engine: false)
    principal = Identity.principal("sa2a-root-ordinary-agent")

    authority =
      Authority.new(principal, Root.mutation_capability_id(), source: :transport_verified)

    changes = %{version_policy: Map.put(held.version_policy, "review", "ordinary agent")}

    reply =
      Context.stimulus(ctx, f, fn ->
        Root.mutate(held, changes, authority, principal, require_engine: false)
      end)

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, @mutate),
      forbidden_outcome_observed?:
        Evidence.seen?(ctx, f, @mutate, %{"outcome" => "mutated"}) or match?({:ok, _}, reply),
      evidence: %{
        "reply" => describe(reply),
        "staged_document_unchanged" =>
          staged.path |> File.read!() |> JSON.decode!() |> Map.get("digest") == held.digest
      }
    )
  end

  # --- 014 --------------------------------------------------------------------------------

  defp committed_case(ctx, f) do
    if EngineProbe.available?() do
      reply =
        Context.stimulus(ctx, f, fn ->
          with {:ok, manifest} <- Root.load(nil, require_engine: true) do
            Root.verify_use(manifest, expected_digest: manifest.digest)
          end
        end)

      recorded =
        ConformanceCorpus.manifest_path() |> File.read!() |> JSON.decode!() |> Map.get("digest")

      Result.positive(f,
        attempt_observed?: Evidence.seen?(ctx, f, @verify, %{"phase" => "load"}),
        expected_outcome_observed?:
          Evidence.seen?(ctx, f, @verify, %{"phase" => "load", "outcome" => "verified"}) and
            Evidence.seen?(ctx, f, @verify, %{"phase" => "use", "outcome" => "verified"}) and
            match?({:ok, %{engine_verified?: true, digest: ^recorded}}, reply),
        evidence: %{"reply" => describe(reply), "committed_digest" => recorded}
      )
    else
      Result.blocked(f, "praxis-graphlaw engine probe not runnable on this host")
    end
  end

  # --- 015 ----------------------------------------------------------------------------------

  defp custodian_case(ctx, f, dir) do
    staged = F.stage_corpus!(dir)
    {:ok, held} = Root.load(staged.path, require_engine: false)
    principal = Identity.principal("sa2a-root-custodian")
    authority = Authority.new(principal, Root.mutation_capability_id(), source: :root_custodian)
    changes = %{version_policy: Map.put(held.version_policy, "review", "RFC-SA2A-002 §53")}

    previous = held.digest

    reply =
      Context.stimulus(ctx, f, fn ->
        with {:ok, mutated} <-
               Root.mutate(held, changes, authority, principal, require_engine: false) do
          {Root.verify_use(mutated, expected_digest: mutated.digest),
           Root.verify_use(mutated, expected_digest: previous)}
        end
      end)

    moved? =
      case reply do
        {{:ok, %{digest: new}}, {:error, %{code: :REFUSED_MANIFEST_RECEIPT_MISMATCH}}} ->
          new != previous

        _ ->
          false
      end

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, @mutate),
      expected_outcome_observed?:
        Evidence.seen?(ctx, f, @mutate, %{"outcome" => "mutated"}) and
          Evidence.seen?(ctx, f, @verify, %{"phase" => "use", "outcome" => "verified"}) and moved?,
      evidence: %{"reply" => describe(reply), "previous_digest" => held.digest}
    )
  end

  # --- helpers --------------------------------------------------------------------------------

  defp refused_component({:error, %{detail: %{component: component}}}), do: component
  defp refused_component(_), do: nil

  defp describe({:ok, %Root{digest: digest}}), do: "ok " <> to_string(digest)

  defp describe({:error, %{code: code, detail: detail}}),
    do: "#{code} #{inspect(detail, limit: 8, printable_limit: 256)}"

  defp describe(other), do: inspect(other, limit: 8, printable_limit: 256)
end
