defmodule AshA2A.Planning.BoundedPlan do
  @moduledoc """
  The whole bounded plan presented for execution (RFC-SA2A-001 S24, S34, S35;
  RFC-SA2A-002 §36).

  A `%BoundedPlan{}` pairs a strict, digest-identified
  `AshA2A.Semantic.PlanPackage` with the execution-envelope values that
  change what executing it would do:

    * `:steps` -- the ordered plan steps, `[%{capability_id: String.t(), input: map()}]`
    * `:fan_out` -- steps the plan may issue (`<= plan_package.max_fan_out`)
    * `:cascade_depth` -- reactive cascade depth (`<= plan_package.max_depth`)
    * `:parallelism` -- concurrent steps (`<= plan_package.max_parallelism`)
    * `:retry_count` -- retries per step
    * `:resource_budget` -- `%{max_invocations, max_wall_ms, max_external_requests}`
    * `:external_request_count` -- external requests the plan may issue
    * `:financial_envelope` -- `%{currency: String.t(), max_minor_units: non_neg_integer()}`
    * `:authority_requirement` -- the per-capability authority STATEMENT
      (`[%{capability_id: ...}]`); never a grant
    * `:semantic_subject` -- the exact `AshA2A.SemanticSubject` the plan was
      constructed for

  Standing `:candidate`, authority `:none`. A bounded plan is not authority:
  every step still needs its own `AshA2A.Authority` at `AshA2A.CommandBus`.
  """

  @enforce_keys [
    :plan_package,
    :steps,
    :fan_out,
    :cascade_depth,
    :parallelism,
    :retry_count,
    :resource_budget,
    :external_request_count,
    :financial_envelope,
    :authority_requirement,
    :semantic_subject
  ]
  defstruct @enforce_keys ++ [standing: :candidate, authority: :none]

  @type step :: %{capability_id: String.t(), input: map()}

  @type t :: %__MODULE__{
          plan_package: AshA2A.Semantic.PlanPackage.t(),
          steps: [step()],
          fan_out: pos_integer(),
          cascade_depth: non_neg_integer(),
          parallelism: pos_integer(),
          retry_count: non_neg_integer(),
          resource_budget: map(),
          external_request_count: non_neg_integer(),
          financial_envelope: map(),
          authority_requirement: [map()],
          semantic_subject: AshA2A.SemanticSubject.t(),
          standing: :candidate,
          authority: :none
        }
end

defmodule AshA2A.Planning.Preflight do
  @moduledoc """
  Whole bounded plan preflight (RFC-SA2A-002 §36 Gate 5; RFC-SA2A-001 S24,
  S34, S35, S73).

      Preflighted(plan) ⇒ Bounded(plan) ∧ Identity(plan) = preflight_digest

  `preflight/1` admits an `AshA2A.Planning.BoundedPlan` before any consequence
  and issues a preflight identity: a per-field `AshA2A.Semantic.CanonicalTermDigest`
  over every consequence-changing field (`bound_fields/0`) and one
  `preflight_digest` over those field digests.

  `admit_step/3` is the consequence-time check `AshA2A.CommandBus` runs for a
  plan step: the executing plan's fields are re-digested and must equal the
  preflighted ones, so a post-preflight mutation of ANY bound field is refused
  (`:preflight_identity_mismatch`, naming the fields) before claim, receipt
  preparation or actuation. The executing plan is then re-validated, so a
  hand-built preflight identity over an out-of-bounds plan is refused too.

  A preflight is evidence, never authority (`authority: :none`): a verified
  step still requires a real `AshA2A.Authority` at `CommandBus.admit/2`.

  ## Validation (fail closed)

    1. plan fence -- `standing: :candidate, authority: :none`
    2. `PlanPackage.verify/1` and the `:strict` profile
    3. every envelope bound present and well formed (`:preflight_bound_missing`)
    4. envelope within the package's own bounds (`:preflight_bound_exceeded`)
    5. every step names a required capability with an authority requirement
       statement (`:preflight_step_not_in_plan`,
       `:preflight_authority_requirement_missing`)
    6. the semantic subject is bound to this package
       (`:preflight_semantic_subject_mismatch`)
  """

  alias AshA2A.Planning.BoundedPlan
  alias AshA2A.Semantic.{CanonicalTermDigest, PlanPackage}
  alias AshA2A.SemanticSubject

  @bound_fields [
    :plan_package,
    :steps,
    :fan_out,
    :cascade_depth,
    :parallelism,
    :retry_count,
    :resource_budget,
    :external_request_count,
    :financial_envelope,
    :authority_requirement,
    :semantic_subject,
    :standing,
    :authority
  ]

  @budget_keys [:max_invocations, :max_wall_ms, :max_external_requests]

  @enforce_keys [:preflight_digest, :plan_digest, :field_digests]
  defstruct [
    :preflight_digest,
    :plan_digest,
    :field_digests,
    bound_fields: @bound_fields,
    standing: :preflighted,
    authority: :none
  ]

  @type t :: %__MODULE__{
          preflight_digest: String.t(),
          plan_digest: String.t(),
          field_digests: %{atom() => String.t()},
          bound_fields: [atom()],
          standing: :preflighted,
          authority: :none
        }

  @type refusal :: {:error, %{code: atom(), detail: term()}}

  @doc "Every `BoundedPlan` field the preflight identity binds."
  @spec bound_fields() :: [atom()]
  def bound_fields, do: @bound_fields

  @doc false
  def __sa2a_refusal_codes__ do
    %{
      preflight_required: :refused_bounds,
      preflight_plan_missing: :refused_bounds,
      preflight_identity_mismatch: :refused_identity,
      preflight_authority_ceiling_violated: :refused_authority,
      preflight_plan_unverifiable: :refused_plan,
      preflight_production_bounds_missing: :refused_bounds,
      preflight_bound_missing: :refused_bounds,
      preflight_bound_exceeded: :refused_bounds,
      preflight_step_not_in_plan: :refused_plan,
      preflight_authority_requirement_missing: :refused_authority,
      preflight_semantic_subject_mismatch: :refused_identity
    }
  end

  @doc """
  Preflights a whole bounded plan, issuing its preflight identity, or refuses.
  Emits `[:ash_a2a, :planning, :preflight]` for every outcome.
  """
  @spec preflight(BoundedPlan.t()) :: {:ok, t()} | refusal()
  def preflight(%BoundedPlan{} = plan) do
    with :ok <- validate(plan) do
      field_digests = field_digests(plan)

      {:ok,
       %__MODULE__{
         preflight_digest: identity_digest(field_digests),
         plan_digest: plan.plan_package.plan_digest,
         field_digests: field_digests
       }}
    end
    |> emit(plan)
  end

  @doc """
  Consequence-time admission of one plan step (`AshA2A.CommandBus`).

  `preflight` must be the identity issued for exactly `plan`: every bound
  field is re-digested and compared; the plan is re-validated; the command
  must be one of the plan's steps.
  """
  @spec admit_step(t() | nil, BoundedPlan.t() | nil, map()) :: {:ok, t()} | refusal()
  def admit_step(nil, _plan, _command),
    do: error(:preflight_required, "a plan step must present the plan's preflight identity")

  def admit_step(%__MODULE__{}, nil, _command),
    do: error(:preflight_plan_missing, "a preflight identity must travel with its executing plan")

  def admit_step(%__MODULE__{} = preflight, %BoundedPlan{} = plan, command) do
    with :ok <- same_identity(preflight, plan),
         :ok <- validate(plan),
         :ok <- step_in_plan(plan, command) do
      {:ok, preflight}
    end
  end

  def admit_step(_preflight, _plan, _command),
    do: error(:preflight_identity_mismatch, "preflight or plan is not a recognised structure")

  @doc "Per-field digests over every `bound_fields/0` value of `plan`."
  @spec field_digests(BoundedPlan.t()) :: %{atom() => String.t()}
  def field_digests(%BoundedPlan{} = plan),
    do: Map.new(@bound_fields, &{&1, CanonicalTermDigest.digest(Map.fetch!(plan, &1))})

  @doc "The preflight identity over a set of field digests."
  @spec identity_digest(%{atom() => String.t()}) :: String.t()
  def identity_digest(field_digests) when is_map(field_digests),
    do: CanonicalTermDigest.digest(%{preflight: field_digests})

  # --- identity ---------------------------------------------------------------

  defp same_identity(%__MODULE__{} = preflight, plan) do
    executing = field_digests(plan)

    changed =
      Enum.filter(@bound_fields, fn field ->
        Map.get(preflight.field_digests || %{}, field) != Map.fetch!(executing, field)
      end)

    forged? = identity_digest(preflight.field_digests || %{}) != preflight.preflight_digest

    if changed == [] and not forged? do
      :ok
    else
      error(:preflight_identity_mismatch, %{
        fields: changed,
        forged_identity: forged?,
        preflighted: preflight.preflight_digest,
        executing: identity_digest(executing)
      })
    end
  end

  # --- validation -------------------------------------------------------------

  defp validate(%BoundedPlan{} = plan) do
    with :ok <- fence(plan),
         :ok <- package(plan.plan_package),
         :ok <- present(plan),
         :ok <- within(plan),
         :ok <- steps(plan) do
      subject(plan)
    end
  end

  defp fence(%BoundedPlan{standing: :candidate, authority: :none}), do: :ok

  defp fence(%BoundedPlan{standing: standing, authority: authority}),
    do: error(:preflight_authority_ceiling_violated, %{standing: standing, authority: authority})

  defp package(%PlanPackage{} = package) do
    with {:ok, _} <- verify_package(package) do
      case PlanPackage.enforce_profile(%{package | profile: :strict}) do
        :ok -> :ok
        {:error, detail} -> error(:preflight_production_bounds_missing, detail)
      end
    end
  end

  defp package(other), do: error(:preflight_plan_unverifiable, %{plan_package: inspect(other)})

  defp verify_package(package) do
    case PlanPackage.verify(package) do
      {:ok, _} = ok -> ok
      {:error, detail} -> error(:preflight_plan_unverifiable, detail)
    end
  end

  defp present(plan) do
    missing =
      [
        steps: nonempty_list?(plan.steps),
        fan_out: pos_int?(plan.fan_out),
        cascade_depth: non_neg_int?(plan.cascade_depth),
        parallelism: pos_int?(plan.parallelism),
        retry_count: non_neg_int?(plan.retry_count),
        resource_budget:
          is_map(plan.resource_budget) and
            Enum.all?(@budget_keys, &non_neg_int?(Map.get(plan.resource_budget, &1))),
        external_request_count: non_neg_int?(plan.external_request_count),
        financial_envelope: financial?(plan.financial_envelope),
        authority_requirement:
          nonempty_list?(plan.authority_requirement) and
            Enum.all?(plan.authority_requirement, &requirement?/1),
        semantic_subject: match?(%SemanticSubject{}, plan.semantic_subject)
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    if missing == [], do: :ok, else: error(:preflight_bound_missing, %{missing: missing})
  end

  defp within(plan) do
    pkg = plan.plan_package
    envelope = pkg.resource_envelope
    budget = plan.resource_budget
    invocations = length(plan.steps) * (plan.retry_count + 1)

    exceeded =
      [
        fan_out: length(plan.steps) <= plan.fan_out and plan.fan_out <= pkg.max_fan_out,
        cascade_depth: plan.cascade_depth <= pkg.max_depth,
        parallelism: plan.parallelism <= pkg.max_parallelism,
        retry_count: invocations <= budget.max_invocations,
        resource_budget:
          budget.max_invocations <= envelope.max_invocations and
            budget.max_wall_ms <= envelope.max_wall_ms,
        external_request_count: plan.external_request_count <= budget.max_external_requests
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    if exceeded == [], do: :ok, else: error(:preflight_bound_exceeded, %{fields: exceeded})
  end

  defp steps(plan) do
    required = MapSet.new(plan.plan_package.required_capabilities)
    stated = MapSet.new(plan.authority_requirement, &requirement_capability/1)

    cond do
      not Enum.all?(plan.steps, &step?/1) ->
        error(:preflight_bound_missing, %{missing: [:steps]})

      Enum.any?(plan.steps, &(not MapSet.member?(required, &1.capability_id))) ->
        error(:preflight_step_not_in_plan, %{
          capability_ids: Enum.map(plan.steps, & &1.capability_id) -- MapSet.to_list(required)
        })

      Enum.any?(plan.steps, &(not MapSet.member?(stated, &1.capability_id))) ->
        error(:preflight_authority_requirement_missing, %{
          capability_ids: Enum.map(plan.steps, & &1.capability_id) -- MapSet.to_list(stated)
        })

      true ->
        :ok
    end
  end

  defp subject(%BoundedPlan{semantic_subject: subject, plan_package: pkg}) do
    graph = normalize(pkg.source_graph_digest)

    if subject.projection_digest == pkg.plan_digest and subject.graph_digest == graph,
      do: :ok,
      else:
        error(:preflight_semantic_subject_mismatch, %{
          subject_projection_digest: subject.projection_digest,
          plan_digest: pkg.plan_digest
        })
  end

  defp step_in_plan(plan, %{capability_id: capability_id, input: input}) do
    if Enum.any?(plan.steps, &(&1.capability_id == capability_id and &1.input == input)),
      do: :ok,
      else: error(:preflight_step_not_in_plan, %{capability_id: capability_id})
  end

  defp step_in_plan(_plan, _command),
    do: error(:preflight_step_not_in_plan, %{capability_id: nil})

  defp step?(%{capability_id: id, input: input}) when is_binary(id) and is_map(input), do: true
  defp step?(_), do: false

  defp requirement?(%{capability_id: id}) when is_binary(id) and id != "", do: true
  defp requirement?(_), do: false

  defp requirement_capability(%{capability_id: id}), do: id
  defp requirement_capability(_), do: nil

  defp financial?(%{currency: currency, max_minor_units: units})
       when is_binary(currency) and currency != "",
       do: non_neg_int?(units)

  defp financial?(_), do: false

  defp nonempty_list?([_ | _]), do: true
  defp nonempty_list?(_), do: false

  defp pos_int?(value), do: is_integer(value) and value > 0
  defp non_neg_int?(value), do: is_integer(value) and value >= 0

  defp normalize("sha256:" <> _ = digest), do: digest
  defp normalize(hex) when is_binary(hex), do: "sha256:" <> hex
  defp normalize(other), do: other

  # --- telemetry --------------------------------------------------------------

  # `[:ash_a2a, :planning, :preflight]`: the whole-plan preflight decision
  # (RFC-SA2A-002 §36). Observational only; the result passes through.
  defp emit(result, plan) do
    {outcome, meta} =
      case result do
        {:ok, %__MODULE__{} = preflight} ->
          {:preflighted, %{preflight_digest: preflight.preflight_digest}}

        {:error, %{code: code, detail: detail}} ->
          {:refused, %{code: code, fields: detail_fields(detail)}}
      end

    :telemetry.execute(
      [:ash_a2a, :planning, :preflight],
      %{system_time: System.system_time(), bound_fields: length(@bound_fields)},
      Map.merge(meta, %{outcome: outcome, plan_digest: plan_digest(plan)})
    )

    result
  end

  @doc false
  def detail_fields(%{missing: fields}) when is_list(fields), do: join(fields)
  def detail_fields(%{fields: fields}) when is_list(fields), do: join(fields)
  def detail_fields(_), do: nil

  defp join(fields), do: Enum.map_join(fields, ",", &to_string/1)

  defp plan_digest(%BoundedPlan{plan_package: %PlanPackage{plan_digest: digest}}), do: digest
  defp plan_digest(_), do: nil

  defp error(code, detail), do: {:error, %{code: code, detail: detail}}
end
