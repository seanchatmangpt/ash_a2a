defmodule AshA2A.Semantic.Construction do
  @moduledoc """
  The result of `AshA2A.Semantic.Construct.construct/4` -- `A = mu(O*)`
  (RFC-SA2A-001 S26).

  Carries every identity S26 requires of a construction: the admitted
  inputs, the manufacturer identity and version, the target profile, the
  produced artifact's digest, and a construction receipt.

  ## `construction_receipt` is NOT an `AshA2A.Receipt`

  Deliberately a distinct struct, not a reuse of `AshA2A.Receipt`.
  `AshA2A.Receipt` is the *consequence* receipt `AshA2A.CommandBus` commits
  for a real DO: it is bound to a `command_id`, a `principal_id`, an
  `execution_id`, and a `consequence`, and its existence is evidence that a
  consequence-bearing action actually ran under a real authority. A
  construction receipt is evidence that an artifact was *manufactured from
  admitted semantics* -- no command, no principal, no execution, no
  authority. Collapsing the two would make "I generated a file" structurally
  indistinguishable from "I committed a change", which is exactly the
  confusion S26's "neither implies authority" clause exists to prevent.

  `standing: :candidate, authority: :none` on both structs, unconditionally.
  """

  @enforce_keys [
    :artifact,
    :artifact_digest,
    :semantic_subject,
    :manufacturer_identity,
    :manufacturer_version,
    :target_profile,
    :construction_receipt
  ]
  defstruct [
    :artifact,
    :artifact_digest,
    :semantic_subject,
    :manufacturer_identity,
    :manufacturer_version,
    :target_profile,
    :construction_receipt,
    admitted_input_digests: [],
    standing: :candidate,
    authority: :none
  ]

  @type t :: %__MODULE__{
          artifact: term(),
          artifact_digest: String.t(),
          semantic_subject: AshA2A.SemanticSubject.t(),
          manufacturer_identity: String.t(),
          manufacturer_version: String.t(),
          target_profile: atom(),
          construction_receipt: map(),
          admitted_input_digests: [String.t()],
          standing: :candidate,
          authority: :none
        }
end

defmodule AshA2A.Semantic.Construct do
  @moduledoc """
  CONSTRUCT (RFC-SA2A-001 S26): `A = mu(O*)` -- manufacture an artifact from
  admitted semantics.

  > CONSTRUCT manufactures an artifact from admitted semantics and MUST
  > identify admitted inputs, manufacturer identity + version, target
  > profile, produced artifact digest, and a construction receipt. Neither
  > [SELECT nor CONSTRUCT] implies authority.

  ## Reuse, not duplication

  The three-digest identity S26 needs is already
  `AshA2A.SemanticSubject` -- `graph_digest` / `projection_digest` /
  `manufacturer_digest`, explicitly authority-free by its own moduledoc.
  This module builds a real `AshA2A.SemanticSubject` via
  `SemanticSubject.new/1` rather than defining a fourth digest triple, so a
  construction's identity is the *same* identity a command can already carry
  for replay scoping. `SemanticSubject.new/1`'s own `"sha256:" <> 64 hex`
  validation is therefore the real format gate here --
  `AshA2A.Semantic.CanonicalTermDigest.digest/1` emits exactly that shape, so
  the two compose without reformatting.

  ## `manufacturer_digest` is over identity + version, not over the output

  `manufacturer_digest` answers "which manufacturer, at which version,
  produced this", so it is a digest of `{identity, version, target_profile}`
  and is stable across different inputs to the same manufacturer. The
  *output* has its own separate `artifact_digest`. Digesting the artifact
  into the manufacturer slot would make every run a "different manufacturer"
  and destroy the replay-scoping the subject exists for.

  ## No authority, structurally

  Like `AshA2A.Semantic.Select`, this module references no
  `AshA2A.CommandBus`, `AshA2A.Authority`, `AshA2A.ReceiptStore`, or
  `AshA2A.ReceiptOutbox`; `test/ash_a2a/semantic/construct_test.exs` asserts
  that against the compiled BEAM's real import table, not against a grep.
  """

  alias AshA2A.Semantic.{CanonicalTermDigest, Construction, PlanPackage, PlanProjection}
  alias AshA2A.SemanticSubject

  @type refusal :: {:error, %{code: atom(), detail: term()}}
  @type manufacturer :: (PlanPackage.t() -> {:ok, term()} | {:error, term()})

  @doc """
  Manufactures an artifact from an admitted plan package.

  `projection` is the package's own source projection, re-supplied so this
  function can bind the construction to the authoritative graph identity
  *and* re-run the S27 checks (`PlanProjection.verify_self/1`) at
  manufacture time -- an edited projection must not be able to manufacture
  a canonical artifact.

  `manufacturer` is a real 1-arity function from the package to
  `{:ok, artifact}` or `{:error, reason}`. It is a real collaborator, not a
  stub point: the HDDL path passes a function that actually shells out to
  `AshA2A.Planning.HddlSolver.solve/3`.

  `opts`:

    * `:manufacturer_identity` (required) -- e.g. `"AshA2A.Planning.HddlSolver"`
    * `:manufacturer_version` (required) -- e.g. `"hddl_cli@release"`
    * `:target_profile` -- defaults to the package's own `profile`

  Refusals: `:construct_projection_unverifiable`,
  `:construct_package_unverifiable`, `:construct_projection_package_mismatch`
  (the package was not built from this projection),
  `:construct_manufacturer_failed` (the real manufacturer returned an
  error -- detail carries it verbatim),
  `:construct_manufacturer_invalid_result` (it returned neither
  `{:ok, _}` nor `{:error, _}`), and whatever
  `AshA2A.SemanticSubject.new/1` refuses with, wrapped as
  `:construct_subject_invalid`.
  """
  @spec construct(PlanPackage.t(), PlanProjection.t(), manufacturer(), keyword()) ::
          {:ok, Construction.t()} | refusal()
  def construct(%PlanPackage{} = package, %PlanProjection{} = projection, manufacturer, opts)
      when is_function(manufacturer, 1) and is_list(opts) do
    identity = Keyword.fetch!(opts, :manufacturer_identity)
    version = Keyword.fetch!(opts, :manufacturer_version)
    target_profile = Keyword.get(opts, :target_profile, package.profile)

    with :ok <- verify_projection(projection),
         :ok <- verify_package(package),
         :ok <- same_projection(package, projection),
         {:ok, artifact} <- run_manufacturer(manufacturer, package),
         {:ok, subject} <-
           subject(projection, package, identity, version, target_profile) do
      artifact_digest = CanonicalTermDigest.digest(artifact)

      admitted_input_digests = [
        projection.source_graph_digest,
        projection.projection_digest,
        package.plan_digest
      ]

      receipt =
        construction_receipt(
          package,
          projection,
          subject,
          artifact_digest,
          admitted_input_digests,
          identity,
          version,
          target_profile
        )

      {:ok,
       %Construction{
         artifact: artifact,
         artifact_digest: artifact_digest,
         semantic_subject: subject,
         manufacturer_identity: identity,
         manufacturer_version: version,
         target_profile: target_profile,
         admitted_input_digests: admitted_input_digests,
         construction_receipt: receipt
       }}
    end
    |> emit_decision(package, identity)
  end

  # `[:ash_a2a, :semantic, :construct]`: the CONSTRUCT decision (RFC-SA2A-002
  # §35 CONSTRUCTED-standing evidence). Observational only.
  defp emit_decision(result, package, identity) do
    meta =
      case result do
        {:ok, %Construction{} = c} ->
          %{
            outcome: :constructed,
            artifact_digest: c.artifact_digest,
            receipt_digest: c.construction_receipt.receipt_digest,
            standing: c.standing,
            authority: c.authority
          }

        {:error, %{code: code}} ->
          %{outcome: :refused, code: code}
      end

    :telemetry.execute(
      [:ash_a2a, :semantic, :construct],
      %{system_time: System.system_time()},
      Map.merge(meta, %{plan_digest: package.plan_digest, manufacturer_identity: identity})
    )

    result
  end

  @doc """
  The manufacturer digest slot: a digest over `{identity, version,
  target_profile}` only. Public because a caller comparing two constructions
  should be able to ask "same manufacturer?" without reconstructing.
  """
  @spec manufacturer_digest(String.t(), String.t(), atom()) :: String.t()
  def manufacturer_digest(identity, version, target_profile)
      when is_binary(identity) and is_binary(version) and is_atom(target_profile) do
    CanonicalTermDigest.digest(%{
      manufacturer_identity: identity,
      manufacturer_version: version,
      target_profile: target_profile
    })
  end

  @doc """
  Normalizes a digest to `AshA2A.SemanticSubject`'s required
  `"sha256:" <> 64 lowercase hex` form.

  This adapter exists because the repo carries two real digest spellings
  that predate each other, and neither should be silently loosened:

    * `AshA2A.Semantic.Ontology.fingerprint` / `PlanningIR.fingerprint` are
      bare 64-char lowercase hex (`Base.encode16(case: :lower)`, no prefix).
    * `AshA2A.SemanticSubject.new/1` requires the `"sha256:"` prefix and
      rejects a bare hex string outright
      (`{:refused_semantic_subject, :graph_digest}`).

  Rather than relax `SemanticSubject`'s real format gate (it is the thing
  that makes a subject's algorithm explicit) or rewrite every existing
  `Ontology` fingerprint, `construct/4` adapts at the boundary and refuses
  anything that is neither spelling. `AshA2A.Semantic.CanonicalTermDigest.digest/1`
  already emits the prefixed form, so digests this task's own modules produce
  pass through unchanged.
  """
  @spec normalize_digest(String.t()) :: {:ok, String.t()} | :error
  def normalize_digest("sha256:" <> hex = digest) when byte_size(hex) == 64 do
    if String.match?(hex, ~r/\A[0-9a-f]{64}\z/), do: {:ok, digest}, else: :error
  end

  def normalize_digest(hex) when is_binary(hex) and byte_size(hex) == 64 do
    if String.match?(hex, ~r/\A[0-9a-f]{64}\z/), do: {:ok, "sha256:" <> hex}, else: :error
  end

  def normalize_digest(_other), do: :error

  defp subject(projection, package, identity, version, target_profile) do
    with {:ok, graph_digest} <- normalized(projection.source_graph_digest, :graph_digest),
         {:ok, plan_digest} <- normalized(package.plan_digest, :projection_digest) do
      build_subject(graph_digest, plan_digest, identity, version, target_profile)
    end
  end

  defp normalized(value, field) do
    case normalize_digest(value) do
      {:ok, digest} -> {:ok, digest}
      :error -> error(:construct_subject_invalid, {:refused_semantic_subject, field})
    end
  end

  defp build_subject(graph_digest, plan_digest, identity, version, target_profile) do
    case SemanticSubject.new(
           graph_digest: graph_digest,
           projection_digest: plan_digest,
           manufacturer_digest: manufacturer_digest(identity, version, target_profile),
           ephemeral?: true
         ) do
      {:ok, subject} -> {:ok, subject}
      {:error, detail} -> error(:construct_subject_invalid, detail)
    end
  end

  defp construction_receipt(
         package,
         projection,
         subject,
         artifact_digest,
         admitted_input_digests,
         identity,
         version,
         target_profile
       ) do
    body = %{
      kind: :construction_receipt,
      admitted_input_digests: admitted_input_digests,
      source_graph_digest: projection.source_graph_digest,
      projection_digest: projection.projection_digest,
      plan_digest: package.plan_digest,
      artifact_digest: artifact_digest,
      manufacturer_identity: identity,
      manufacturer_version: version,
      target_profile: target_profile,
      semantic_subject: SemanticSubject.fingerprint_token(subject),
      standing: :candidate,
      authority: :none
    }

    Map.put(body, :receipt_digest, CanonicalTermDigest.digest(body))
  end

  defp verify_projection(projection) do
    case PlanProjection.verify_self(projection) do
      {:ok, _projection} -> :ok
      {:error, detail} -> error(:construct_projection_unverifiable, detail)
    end
  end

  defp verify_package(package) do
    case PlanPackage.verify(package) do
      {:ok, _package} -> :ok
      {:error, detail} -> error(:construct_package_unverifiable, detail)
    end
  end

  defp same_projection(%PlanPackage{projection_digest: digest}, %PlanProjection{
         projection_digest: digest
       }),
       do: :ok

  defp same_projection(package, projection) do
    error(:construct_projection_package_mismatch, %{
      package_names: package.projection_digest,
      projection_is: projection.projection_digest
    })
  end

  defp run_manufacturer(manufacturer, package) do
    case manufacturer.(package) do
      {:ok, artifact} -> {:ok, artifact}
      {:error, reason} -> error(:construct_manufacturer_failed, reason)
      other -> error(:construct_manufacturer_invalid_result, other)
    end
  end

  defp error(code, detail), do: {:error, %{code: code, detail: detail}}
end
