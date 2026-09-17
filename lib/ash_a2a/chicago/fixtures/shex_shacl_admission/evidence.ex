defmodule AshA2A.Chicago.Fixtures.ShexShaclAdmission.Evidence do
  @moduledoc """
  Shared stimulus and independent post-state readers for the Gate 2 /
  admission / ShEx / SHACL courts.

  ## What "canonical state" is read through

  `AshA2A.Semantic.AdmissionPipeline` claims it performs no writes at all.
  `canonical_snapshot/1` observes that claim from outside the boundary, never
  through a module under attack:

    * `"ontology_cache"` -- a SHA-256 tree digest, computed here with
      `File`/`:crypto`, of every file under the admitted, pinned ontology cache
      (`priv/semantic/ontology_cache`), the durable admitted vocabulary the
      executable world's term index is built from;
    * `"law_corpus"` -- the same tree digest over the admitted conformance law
      package (`priv/sa2a_conformance`);
    * `"engine_scratch_entries"` -- the number of files left in the court-owned
      directory handed to the pipeline as the engine's `:tmp_dir` (the only
      place the pipeline's transport writes).

  A falsifier's canonical-state conjunct holds only when the digests are
  byte-identical before and after its stimulus and the scratch directory is
  empty afterwards.
  """

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.GraphLaw.Wasm
  alias AshA2A.Semantic.AdmissionPipeline
  alias AshA2A.Semantic.AdmissionPipeline.Candidate
  alias AshA2A.Semantic.AdmissionRefusal

  # --- OCEL predicates over the admission pipeline's own telemetry ----------

  @doc "The pipeline emitted a stage event for `stage` (optionally with `outcome`)."
  @spec stage(atom(), atom() | nil) :: AshA2A.Chicago.Query.predicate()
  def stage(stage, outcome \\ nil) do
    attrs = %{"stage" => Atom.to_string(stage)}
    attrs = if outcome, do: Map.put(attrs, "outcome", Atom.to_string(outcome)), else: attrs
    {:observed, "admission.stage", attrs}
  end

  @doc "The pipeline granted `:admitted` standing."
  @spec admitted() :: AshA2A.Chicago.Query.predicate()
  def admitted, do: {:observed, "admission.stop", %{"outcome" => "admitted"}}

  # --- engine availability ---------------------------------------------------

  @doc "`:ok`, or `{:blocked, reason}` when the real engine cannot run here (never killed)."
  @spec engine() :: :ok | {:blocked, String.t()}
  def engine do
    case Wasm.availability() do
      :ok -> :ok
      {:error, detail} -> {:blocked, "real GraphLaw wasm unavailable: #{inspect(detail)}"}
    end
  end

  @doc "Every declared falsifier as `:blocked` with `reason`."
  @spec blocked([Falsifier.t()], String.t()) :: [Result.t()]
  def blocked(falsifiers, reason), do: Enum.map(falsifiers, &Result.blocked(&1, reason))

  # --- in-run observation ------------------------------------------------------

  @doc "True when the run's observer recorded `activity` with every attribute in `attrs`."
  @spec seen?(Context.t(), Falsifier.t(), String.t(), map()) :: boolean()
  def seen?(%Context{} = ctx, %Falsifier{} = f, activity, attrs \\ %{}) do
    Enum.any?(Context.observed(ctx, f), fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} ->
          to_string(Map.get(record.attributes, to_string(k))) == to_string(v)
        end)
    end)
  end

  @doc "In-run form of `stage/2`."
  @spec stage_seen?(Context.t(), Falsifier.t(), atom(), atom() | nil) :: boolean()
  def stage_seen?(ctx, f, stage, outcome \\ nil) do
    {:observed, activity, attrs} = stage(stage, outcome)
    seen?(ctx, f, activity, attrs)
  end

  @doc "In-run form of `admitted/0`."
  @spec admitted_seen?(Context.t(), Falsifier.t()) :: boolean()
  def admitted_seen?(ctx, f), do: seen?(ctx, f, "admission.stop", %{"outcome" => "admitted"})

  # --- canonical state -----------------------------------------------------------

  @doc "A fresh, empty, court-owned engine scratch directory under the evidence dir."
  @spec scratch_dir(Context.t(), String.t()) :: Path.t()
  def scratch_dir(%Context{evidence_dir: dir}, court_id) do
    path = Path.join(dir, "engine-scratch-" <> String.downcase(court_id))
    File.mkdir_p!(path)
    path
  end

  @doc "Independent canonical-state snapshot (see moduledoc)."
  @spec canonical_snapshot(Path.t()) :: map()
  def canonical_snapshot(scratch) do
    priv = to_string(:code.priv_dir(:ash_a2a))

    %{
      "ontology_cache" => tree_digest(Path.join(priv, "semantic/ontology_cache")),
      "law_corpus" => tree_digest(Path.join(priv, "sa2a_conformance")),
      "engine_scratch_entries" => scratch |> File.ls!() |> length()
    }
  end

  @doc "True when `after_snapshot` equals `before` and no engine scratch residue remains."
  @spec canonical_unchanged?(map(), map()) :: boolean()
  def canonical_unchanged?(before, after_snapshot) do
    Map.delete(before, "engine_scratch_entries") ==
      Map.delete(after_snapshot, "engine_scratch_entries") and
      after_snapshot["engine_scratch_entries"] == 0
  end

  @doc "SHA-256 over sorted `(relative path, sha256(bytes))` of every regular file under `root`."
  @spec tree_digest(Path.t()) :: String.t()
  def tree_digest(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(fn path ->
      [Path.relative_to(path, root), 0, sha256(File.read!(path)), ?\n]
    end)
    |> IO.iodata_to_binary()
    |> sha256()
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # --- admission stimulus ---------------------------------------------------------

  @doc """
  Drives the real pipeline with `candidate` as `f`'s stimulus, bracketed by
  canonical snapshots taken outside the stimulus. Returns
  `{result, before, after}`.

  The pipeline is configured with the world's admitted law
  (`pipeline_opts/1`): the host's Root Manifest, never anything the candidate
  carries.
  """
  @spec admit(Context.t(), Falsifier.t(), Candidate.t(), Path.t()) ::
          {{:ok, AdmissionPipeline.Result.t()} | {:error, AdmissionRefusal.t()}, map(), map()}
  def admit(ctx, f, %Candidate{} = candidate, scratch) do
    opts = pipeline_opts(scratch)
    before = canonical_snapshot(scratch)

    result = Context.stimulus(ctx, f, fn -> AdmissionPipeline.admit(candidate, opts) end)

    {result, before, canonical_snapshot(scratch)}
  end

  @doc """
  Pipeline options for a court-owned engine scratch directory: `:tmp_dir` and
  the world's admitted law manifest, materialized beside the scratch
  directory (outside it, so scratch residue stays an independent reading).
  """
  @spec pipeline_opts(Path.t()) :: keyword()
  def pipeline_opts(scratch) do
    [
      tmp_dir: scratch,
      root_manifest:
        AshA2A.Chicago.Fixtures.ShexShaclAdmission.law_manifest!(Path.dirname(scratch))
    ]
  end

  @doc """
  A `:negative` admission falsifier whose boundary is `stage`.

  Attempt: the pipeline emitted a `stage` event for this stimulus, whatever
  its outcome -- so a removed guard shows up as a survival, not as an
  unobserved attempt (§22). Forbidden: `stage` passed, the candidate reached
  `:admitted`, the call returned `{:ok, _}`, or canonical state changed.
  """
  @spec stage_negative(Context.t(), Falsifier.t(), Candidate.t(), Path.t(), atom()) :: Result.t()
  def stage_negative(ctx, f, candidate, scratch, stage) do
    {result, before, after_snapshot} = admit(ctx, f, candidate, scratch)

    Result.negative(f,
      attempt_observed?: stage_seen?(ctx, f, stage),
      forbidden_outcome_observed?:
        stage_seen?(ctx, f, stage, :ok) or admitted_seen?(ctx, f) or
          match?({:ok, _}, result) or not canonical_unchanged?(before, after_snapshot),
      evidence: admission_evidence(result, before, after_snapshot)
    )
  end

  @doc """
  A `:negative` falsifier whose forbidden outcome is standing itself: the
  pipeline ran (`admission.start` and a `stage` event observed) and the
  candidate must not reach `:admitted`.
  """
  @spec standing_negative(Context.t(), Falsifier.t(), Candidate.t(), Path.t(), atom()) ::
          Result.t()
  def standing_negative(ctx, f, candidate, scratch, stage) do
    {result, before, after_snapshot} = admit(ctx, f, candidate, scratch)

    Result.negative(f,
      attempt_observed?: seen?(ctx, f, "admission.start") and stage_seen?(ctx, f, stage),
      forbidden_outcome_observed?:
        admitted_seen?(ctx, f) or match?({:ok, _}, result) or
          not canonical_unchanged?(before, after_snapshot),
      evidence: admission_evidence(result, before, after_snapshot)
    )
  end

  @doc "JSON-safe evidence for one admission attempt."
  @spec admission_evidence(term(), map(), map()) :: map()
  def admission_evidence(result, before, after_snapshot) do
    outcome =
      case result do
        {:ok, %AdmissionPipeline.Result{} = r} ->
          %{
            "outcome" => "admitted",
            "standing" => r.standing,
            "authority" => r.authority,
            "stages" => r.stages,
            "admission_digest" => r.admission_digest
          }

        {:error, %AdmissionRefusal{} = r} ->
          %{
            "outcome" => "refused",
            "refusal" => AdmissionRefusal.describe(r),
            "engine_evidence" => r.evidence,
            "detail" => inspect(r.detail, limit: 20, printable_limit: 512)
          }
      end

    Map.merge(outcome, %{
      "canonical_before" => before,
      "canonical_after" => after_snapshot,
      "canonical_unchanged" => canonical_unchanged?(before, after_snapshot)
    })
  end
end
