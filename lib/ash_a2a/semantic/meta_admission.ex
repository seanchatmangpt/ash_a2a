defmodule AshA2A.Semantic.MetaAdmission do
  @moduledoc """
  RFC-SA2A-001 S20/S58: admission applied recursively to the MACHINERY.

  Ordinary admission asks "is this data graph valid?". Meta-admission asks
  the prior question: "does the thing about to judge that data graph itself
  have standing?". ShEx schemas, SHACL shapes, N3 rules, Datalog programs,
  SPARQL falsifiers, planning domains, generators, authority policies,
  receipt schemas, and semantic mappings are all semantic artifacts, and an
  unadmitted one is not a neutral tool -- it is an unaudited judge.

  ## The two invariants, as executable checks

      NOT Standing(v)  =>  NOT Validates(v, x)
      NOT Standing(r)  =>  NOT CanonicalDerivation(r)

  `validate/3` refuses BEFORE it reads or uses any shapes/schema whose
  standing it cannot establish, and `canonical_derivation/4` refuses BEFORE
  applying any rule set whose standing it cannot establish. Both refuse with
  `refusal_code/0` = `:REFUSED_META_RIGOR`. Neither invariant is expressed
  as a comment or a documented intention; each is the actual control flow,
  and each has a real falsifier test.

  ## What "Standing" means here, exactly

  `Standing(artifact)` holds iff the artifact's REAL current SHA-256, read
  off disk at the moment of use, equals a digest pinned in the loaded
  `AshA2A.Semantic.RootManifest` under a matching kind. Three consequences
  worth stating:

  * An artifact that is simply absent from the Root Manifest has no standing
    no matter how well-formed it is. Being valid SHACL is not standing.
  * The digest is re-read at USE time, not trusted from load time. A file
    swapped between `RootManifest.load/2` and this call is caught here --
    load-time verification alone would be a time-of-check/time-of-use hole.
  * The engine is machinery too. A manifest whose pinned
    `praxis-graphlaw` engine was not verified (`engine_verified?: false`)
    yields `REFUSED_META_RIGOR` with reason `:engine_unverified` for every
    engine-backed operation. Meta-admission that exempted its own executor
    would not be recursive.
  * Engine standing is itself re-checked at USE time, not just load time.
    `RootManifest.load/2` records the exact digest it verified
    (`manifest.engine_verified_digest`); every call into this module
    independently re-resolves the CURRENT wasm artifact's digest
    (`RootManifest.current_engine_digest/1`, the same resolution order
    `load/2` used) and refuses with reason `:engine_digest_drift` if it no
    longer matches. A manifest verified once against artifact A must not
    go on authorizing operations once the artifact backing later calls has
    been silently swapped for artifact B -- the load-time engine check
    alone would be exactly the same time-of-check/time-of-use hole the
    per-artifact standing check above already closes for shapes/schemas.

  ## Why this is not paranoia: a real, measured laundering attack

  Against this repo's own conformance corpus, using the real
  `praxis-graphlaw` engine, with the SAME invalid data graph
  (`conformance/data/invalid_command.ttl`, which omits a required
  `a2a:principalId`):

  * with the PINNED shapes (`conformance/shapes/command_envelope.shacl.ttl`)
    the engine really reports `SHACL REFUSED -- Report: 1 violations`;
  * with an UNPINNED but perfectly well-formed permissive shapes file
    (`conformance/shapes/unpinned_rogue.shacl.ttl`) the same engine really
    reports `SHACL ADMITTED -- Report: 0 violations`.

  Both runs are real and reproduced by
  `test/ash_a2a/semantic/meta_admission_test.exs`. Swapping the judge, not
  the data, converts a refusal into an admission. That is the attack
  meta-admission closes, and it is why the standing check has to happen
  before the validator is used rather than alongside its verdict.

  ## Refusal vs verdict -- a distinction this module keeps sharp

  A `{:error, %{code: :REFUSED_META_RIGOR}}` means the machinery never ran:
  something lacked standing. A `{:ok, report}` means admitted machinery
  really ran and produced a verdict, which may itself be a refusal OF THE
  DATA (`admitted?/1` returns `false`, dialect statuses say which). Callers
  must not collapse the two: "the shapes were not admitted" and "the data
  violated admitted shapes" are different facts with different remedies.
  """

  alias AshA2A.Semantic.RootManifest
  alias AshA2A.Semantic.RootManifest.EngineProbe

  @refusal_code :REFUSED_META_RIGOR

  @artifact_kinds ~w(
    ontology_root
    semantic_profile
    shacl_shapes
    shex_schema
    shex_shape_map
    n3_rules
    datalog_program
    sparql_falsifier
    planning_domain
    generator
    authority_policy
    receipt_schema
    semantic_mapping
    hook
  )

  @standing_event [:ash_a2a, :semantic, :meta_admission, :standing]
  @confer_event [:ash_a2a, :semantic, :meta_admission, :confer]

  @type refusal :: %{required(:code) => atom(), required(:detail) => map()}

  @doc "The single refusal code every meta-admission failure carries."
  @spec refusal_code() :: atom()
  def refusal_code, do: @refusal_code

  @doc """
  The semantic-artifact kinds that require standing (RFC S20's enumeration,
  plus the ontology roots / profiles / shape maps the Root Manifest pins, plus
  knowledge `hook`s -- RFC-SA2A-002 §61 hooks are machinery that fires).
  Every one of these is machinery, not data.
  """
  @spec artifact_kinds() :: [String.t()]
  def artifact_kinds, do: @artifact_kinds

  @doc """
  Establishes `Standing(artifact)` for the artifact at `relative_path`,
  required to be pinned under `kind`.

  Really reads and digests the file, then compares against the Root
  Manifest pin. Returns `{:ok, pin}` or a `REFUSED_META_RIGOR` refusal whose
  `detail.reason` is one of `:not_pinned`, `:artifact_missing`, or
  `:digest_drift`.
  """
  @spec standing(RootManifest.t(), String.t(), String.t()) :: {:ok, map()} | {:error, refusal()}
  def standing(%RootManifest{} = manifest, relative_path, kind)
      when is_binary(relative_path) and is_binary(kind) do
    result =
      case RootManifest.find_pin(manifest, relative_path, kind) do
        :error ->
          refuse(:not_pinned, %{
            artifact: relative_path,
            kind: kind,
            invariant: "NOT Standing(v) => NOT Validates(v, x)"
          })

        {:ok, pin} ->
          verify_pin_now(manifest, pin, relative_path, kind)
      end

    digest =
      case RootManifest.artifact_digest(RootManifest.resolve(manifest, relative_path)) do
        {:ok, d} -> d
        _ -> nil
      end

    emit_standing(kind, digest, manifest.digest, "path", result)
    result
  end

  @doc "Telemetry event of every standing decision (`standing/3`, `document_standing/4`)."
  @spec standing_event() :: [atom()]
  def standing_event, do: @standing_event

  @doc "Telemetry event of every production-standing decision (`confer/5`)."
  @spec confer_event() :: [atom()]
  def confer_event, do: @confer_event

  @doc """
  `Standing(document)` for machinery a consumer holds IN MEMORY (a law
  document carried as a string), required to be pinned under `kind`.

  Standing holds iff, at the moment of this call:

    1. `manifest` passes `AshA2A.Semantic.RootManifest.verify_use/2` -- its
       content address, its pinned files, its engine artifact and its
       component identities are re-checked NOW, and when
       `opts[:expected_digest]` is given the manifest is the one the consumer
       bound earlier (reason `:manifest_unverified` otherwise);
    2. `kind` is an `artifact_kinds/0` kind (`:unknown_kind`);
    3. the SHA-256 of `bytes` is pinned under `kind` (`:not_pinned`). Being
       well-formed, non-vacuous, or accepted by the engine is not standing.

  Because (1) re-digests every pinned file, a pin whose file changed after
  the manifest was built has no standing, whatever bytes the consumer holds.

  Emits `standing_event/0` with `kind`, `artifact_digest`, `outcome`
  (`:admitted | :refused`), `reason`, `manifest_digest` and `consumer`
  (`opts[:consumer]`).
  """
  @spec document_standing(RootManifest.t() | term(), binary(), String.t(), keyword()) ::
          {:ok, map()} | {:error, refusal()}
  def document_standing(manifest, bytes, kind, opts \\ [])
      when is_binary(bytes) and is_binary(kind) do
    digest = RootManifest.digest_bytes(bytes)

    result =
      with :ok <- known_kind(kind),
           :ok <- manifest_verified(manifest, opts) do
        case RootManifest.find_pin_by_digest(manifest, digest, kind) do
          {:ok, pin} ->
            {:ok, pin}

          :error ->
            refuse(:not_pinned, %{
              artifact_digest: digest,
              kind: kind,
              invariant: "NOT Standing(m) => NOT Validates(m, x)"
            })
        end
      end

    emit_standing(kind, digest, manifest_digest(manifest), opts[:consumer], result)
    result
  end

  @doc """
  The production-standing gate (RFC-SA2A-001 S20/S58, RFC-SA2A-002 §52):
  machinery output becomes a production object only through here.

  `apparent` is what the machinery itself reported -- a validator's
  admission, a solver's plan, a closure, a rendered artifact, a policy's
  grant, a hook's acceptance -- as `{:ok, object}` or anything else. The
  apparent result is never enough:

    * a negative apparent result is refused (`:apparent_result_negative`):
      admitted machinery that says no is a no;
    * a positive apparent result is refused unless `document_standing/4`
      admits the machinery `bytes` under `kind` -- an unadmitted validator's
      "valid", an unadmitted domain's plan, an unadmitted generator's
      artifact confer nothing.

  Returns `{:ok, %{standing: :production, kind:, artifact_digest:, pin_id:,
  manifest_digest:, object_digest:}}`. Emits `confer_event/0` with `kind`,
  `outcome` (`:production | :refused`), `reason`, `artifact_digest`,
  `manifest_digest` and `consumer`.
  """
  @spec confer(RootManifest.t() | term(), String.t(), binary(), term(), keyword()) ::
          {:ok, map()} | {:error, refusal()}
  def confer(manifest, kind, bytes, apparent, opts \\ [])
      when is_binary(kind) and is_binary(bytes) do
    digest = RootManifest.digest_bytes(bytes)

    result =
      case apparent do
        {:ok, object} ->
          with {:ok, pin} <- document_standing(manifest, bytes, kind, opts) do
            {:ok,
             %{
               standing: :production,
               kind: kind,
               artifact_digest: digest,
               pin_id: Map.get(pin, "id"),
               manifest_digest: manifest.digest,
               object_digest:
                 RootManifest.digest_bytes(:erlang.term_to_binary(object, [:deterministic]))
             }}
          end

        other ->
          refuse(:apparent_result_negative, %{
            kind: kind,
            artifact_digest: digest,
            apparent: inspect(other, limit: 10, printable_limit: 256)
          })
      end

    {outcome, reason} =
      case result do
        {:ok, _} -> {:production, nil}
        {:error, %{detail: detail}} -> {:refused, Map.get(detail, :reason)}
      end

    :telemetry.execute(@confer_event, %{system_time: System.system_time()}, %{
      kind: kind,
      outcome: outcome,
      reason: reason,
      artifact_digest: digest,
      manifest_digest: manifest_digest(manifest),
      consumer: opts[:consumer]
    })

    result
  end

  defp known_kind(kind) do
    if kind in @artifact_kinds,
      do: :ok,
      else: refuse(:unknown_kind, %{kind: kind, known: @artifact_kinds})
  end

  defp manifest_verified(%RootManifest{} = manifest, opts) do
    case RootManifest.verify_use(manifest, opts) do
      {:ok, _} ->
        :ok

      {:error, root_refusal} ->
        refuse(:manifest_unverified, %{root_refusal: root_refusal})
    end
  end

  defp manifest_verified(other, _opts),
    do: refuse(:manifest_unverified, %{root_refusal: :no_root_manifest, got: inspect(other)})

  defp manifest_digest(%RootManifest{digest: digest}), do: digest
  defp manifest_digest(_), do: nil

  defp emit_standing(kind, digest, manifest_digest, consumer, result) do
    {outcome, reason} =
      case result do
        {:ok, _} -> {:admitted, nil}
        {:error, %{detail: detail}} -> {:refused, Map.get(detail, :reason)}
      end

    :telemetry.execute(@standing_event, %{system_time: System.system_time()}, %{
      kind: kind,
      artifact_digest: digest,
      outcome: outcome,
      reason: reason,
      manifest_digest: manifest_digest,
      consumer: consumer
    })
  end

  defp verify_pin_now(manifest, pin, relative_path, kind) do
    absolute = RootManifest.resolve(manifest, relative_path)

    case RootManifest.artifact_digest(absolute) do
      {:error, _} ->
        refuse(:artifact_missing, %{artifact: relative_path, kind: kind, resolved: absolute})

      {:ok, actual} ->
        pinned = Map.fetch!(pin, "digest")

        if actual == pinned do
          {:ok, pin}
        else
          refuse(:digest_drift, %{
            artifact: relative_path,
            kind: kind,
            pinned: pinned,
            actual: actual
          })
        end
    end
  end

  @doc """
  Establishes standing for several artifacts at once, refusing on the first
  failure. `entries` is a list of `{relative_path, kind}` tuples.
  """
  @spec standing_all(RootManifest.t(), [{String.t(), String.t()}]) ::
          {:ok, [map()]} | {:error, refusal()}
  def standing_all(%RootManifest{} = manifest, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn {path, kind}, {:ok, acc} ->
      case standing(manifest, path, kind) do
        {:ok, pin} -> {:cont, {:ok, acc ++ [pin]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  INVARIANT 1 -- `NOT Standing(v) => NOT Validates(v, x)`.

  Validates the data graph at `data_relative_path` using ONLY validator
  artifacts that have real standing in the Root Manifest. Every piece of
  machinery is standing-checked before any of it is used:

      opts[:shapes]     -> kind "shacl_shapes"
      opts[:schema]     -> kind "shex_schema"
      opts[:shape_map]  -> kind "shex_shape_map"
      opts[:profile]    -> kind "semantic_profile"

  The data graph itself is deliberately NOT required to be pinned -- data is
  the input under judgement, not machinery. Only the judges need standing.

  Returns `{:ok, report}` with the real decoded engine report when admitted
  machinery really ran, or a `REFUSED_META_RIGOR` refusal when it did not.
  """
  @spec validate(RootManifest.t(), String.t(), keyword()) :: {:ok, map()} | {:error, refusal()}
  def validate(%RootManifest{} = manifest, data_relative_path, opts) do
    machinery = [
      {Keyword.fetch!(opts, :profile), "semantic_profile"},
      {Keyword.fetch!(opts, :shapes), "shacl_shapes"},
      {Keyword.fetch!(opts, :schema), "shex_schema"},
      {Keyword.fetch!(opts, :shape_map), "shex_shape_map"}
    ]

    with :ok <- require_verified_engine(manifest, opts),
         {:ok, pins} <- standing_all(manifest, machinery),
         {:ok, data_path} <- resolve_existing(manifest, data_relative_path) do
      paths = [
        data: data_path,
        profile: RootManifest.resolve(manifest, Keyword.fetch!(opts, :profile)),
        shapes: RootManifest.resolve(manifest, Keyword.fetch!(opts, :shapes)),
        schema: RootManifest.resolve(manifest, Keyword.fetch!(opts, :schema)),
        shape_map: RootManifest.resolve(manifest, Keyword.fetch!(opts, :shape_map))
      ]

      case EngineProbe.validate_all(paths, opts) do
        {:ok, report} ->
          {:ok,
           %{
             report: report,
             dialects: Map.get(report, "dialects", []),
             graph_hash: Map.get(report, "graph_hash"),
             admitted?: all_dialects_admitted?(report),
             standing: pins,
             manifest_digest: manifest.digest
           }}

        {:error, failure} ->
          refuse(:engine_call_failed, %{artifact: data_relative_path, detail: failure})
      end
    end
  end

  @doc """
  INVARIANT 2 -- `NOT Standing(r) => NOT CanonicalDerivation(r)`.

  Applies the N3 rule set at `rules_relative_path` (kind `"n3_rules"`) to
  the base graph at `base_relative_path`, but ONLY after the rule set's real
  standing is established. An unadmitted rule set never reaches the engine,
  so it can never contribute a derived triple to a canonical graph.

  The returned `:graph_hash` is the engine's real RDFC-1.0 canonical hash of
  the base graph -- computed by `praxis-graphlaw`, never by Elixir.
  """
  @spec canonical_derivation(RootManifest.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, refusal()}
  def canonical_derivation(
        %RootManifest{} = manifest,
        base_relative_path,
        rules_relative_path,
        opts \\ []
      ) do
    with :ok <- require_verified_engine(manifest, opts),
         {:ok, rule_pin} <- standing(manifest, rules_relative_path, "n3_rules"),
         {:ok, base_path} <- resolve_existing(manifest, base_relative_path) do
      rules_path = RootManifest.resolve(manifest, rules_relative_path)

      with {:ok, hooks} <- engine_hooks(base_path, rules_path, opts, rules_relative_path),
           {:ok, graph_hash} <- engine_graph_hash(base_path, opts, base_relative_path) do
        {:ok,
         %{
           hooks: hooks,
           status: Map.get(hooks, "status"),
           graph_hash: graph_hash,
           rules: rule_pin,
           manifest_digest: manifest.digest
         }}
      end
    end
  end

  defp engine_hooks(base_path, rules_path, opts, relative) do
    case EngineProbe.run_hooks(base_path, rules_path, opts) do
      {:ok, hooks} -> {:ok, hooks}
      {:error, failure} -> refuse(:engine_call_failed, %{artifact: relative, detail: failure})
    end
  end

  defp engine_graph_hash(base_path, opts, relative) do
    case EngineProbe.graph_hash(base_path, opts) do
      {:ok, hash} -> {:ok, hash}
      {:error, failure} -> refuse(:engine_call_failed, %{artifact: relative, detail: failure})
    end
  end

  @doc """
  True iff every dialect in a real engine report reached `"ADMITTED"`.
  A report with no dialects is NOT admitted -- absence of a verdict is not
  a positive verdict.
  """
  @spec all_dialects_admitted?(map()) :: boolean()
  def all_dialects_admitted?(report) when is_map(report) do
    case Map.get(report, "dialects", []) do
      [] -> false
      dialects -> Enum.all?(dialects, &(Map.get(&1, "status") == "ADMITTED"))
    end
  end

  @doc "Convenience accessor for a `validate/3` result's admitted flag."
  @spec admitted?(map()) :: boolean()
  def admitted?(%{admitted?: admitted}), do: admitted

  # The engine is machinery. Meta-admission that exempted its own executor
  # would not be recursive -- so an unverified engine refuses here too.
  #
  # Load-time verification alone is not enough: `engine_verified?: true`
  # only proves SOME artifact was verified once, not that it is the SAME
  # artifact backing THIS call. So every call re-resolves the current wasm
  # artifact's real digest and compares it against the digest that was
  # actually verified at load time -- a mismatch means the artifact was
  # swapped after verification and fails closed with `:engine_digest_drift`,
  # never silently continuing on the stale load-time boolean alone.
  defp require_verified_engine(
         %RootManifest{engine_verified?: true, engine_verified_digest: expected},
         opts
       )
       when is_binary(expected) do
    case RootManifest.current_engine_digest(opts) do
      {:ok, ^expected} ->
        :ok

      {:ok, observed} ->
        refuse(:engine_digest_drift, %{expected: expected, observed: observed})

      {:error, failure} ->
        refuse(:engine_digest_drift, %{expected: expected, observed: nil, detail: failure})
    end
  end

  defp require_verified_engine(%RootManifest{engine: engine}, _opts) do
    refuse(:engine_unverified, %{
      engine: Map.get(engine, "id"),
      expected_version: Map.get(engine, "expected_version"),
      hint: "load the Root Manifest with require_engine: true"
    })
  end

  defp resolve_existing(manifest, relative_path) do
    absolute = RootManifest.resolve(manifest, relative_path)

    if File.exists?(absolute) do
      {:ok, absolute}
    else
      refuse(:input_graph_missing, %{artifact: relative_path, resolved: absolute})
    end
  end

  defp refuse(reason, detail) do
    {:error, %{code: @refusal_code, detail: Map.put(detail, :reason, reason)}}
  end
end
