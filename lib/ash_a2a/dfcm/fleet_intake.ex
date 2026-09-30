defmodule AshA2A.DfCM.FleetIntake do
  @moduledoc """
  DfCM fleet-capability intake.

  The donor ontology is canonical. The JSON manifest and per-donor modules are
  projections. Every imported capability is evidence-only at this boundary:
  authority is NONE and consequence is EVIDENCE_ONLY. Native donor runtimes
  remain the owners of their own semantics.

  This module does not copy donor implementations and cannot actuate.
  """

  alias AshA2A.Identity.Canonical
  alias AshA2A.Semantic.Envelope

  @manifest_path Path.expand("../../../priv/dfcm/fleet/manifest.json", __DIR__)
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> Jason.decode!()
  @donors Map.new(@manifest["donors"], fn donor -> {donor["id"], donor} end)
  @sha40 ~r/\A[0-9a-f]{40}\z/

  @spec manifest() :: map()
  def manifest, do: @manifest

  @spec ids() :: [String.t()]
  def ids, do: @donors |> Map.keys() |> Enum.sort()

  @spec fetch(String.t()) :: {:ok, map()} | {:error, map()}
  def fetch(id) when is_binary(id) do
    case Map.fetch(@donors, id) do
      {:ok, donor} -> {:ok, donor}
      :error -> {:error, %{code: :unknown_dfcm_donor, donor: id}}
    end
  end

  @spec fetch!(String.t()) :: map()
  def fetch!(id), do: Map.fetch!(@donors, id)

  @spec validate() :: :ok | {:error, map()}
  def validate do
    Enum.reduce_while(ids(), :ok, fn id, :ok ->
      case validate_donor(fetch!(id)) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @spec exact_subject?(String.t(), String.t()) :: boolean()
  def exact_subject?(id, subject) when is_binary(subject) do
    case fetch(id) do
      {:ok, donor} -> donor["subject"] == subject
      {:error, _} -> false
    end
  end

  @spec digest(String.t()) :: {:ok, String.t()} | {:error, map()}
  def digest(id) do
    with {:ok, donor} <- fetch(id),
         :ok <- validate_donor(donor) do
      Canonical.digest(donor)
    end
  end

  @spec project(String.t(), map()) :: {:ok, map()} | {:error, map()}
  def project(id, payload \\ %{}) when is_map(payload) do
    with {:ok, donor} <- fetch(id),
         :ok <- validate_donor(donor),
         {:ok, payload_digest} <- Canonical.digest(payload),
         {:ok, donor_digest} <- Canonical.digest(donor) do
      {:ok,
       %{
         "schema" => "ash-a2a.dfcm-fleet-projection.v1",
         "donor" => donor["id"],
         "subject" => donor["subject"],
         "capability" => donor["capability"],
         "owner" => donor["owner"],
         "donorDigest" => donor_digest,
         "payloadDigest" => payload_digest,
         "authority" => "NONE",
         "consequence" => "EVIDENCE_ONLY",
         "standing" => "CANDIDATE"
       }}
    end
  end

  @spec admit_projection(String.t(), map()) :: {:ok, map()} | {:error, map()}
  def admit_projection(id, projection) when is_map(projection) do
    with {:ok, donor} <- fetch(id),
         :ok <- validate_donor(donor),
         {:ok, donor_digest} <- Canonical.digest(donor),
         :ok <- require_projection(projection["schema"] == "ash-a2a.dfcm-fleet-projection.v1", :schema),
         :ok <- require_projection(projection["donor"] == id, :donor),
         :ok <- require_projection(projection["subject"] == donor["subject"], :subject),
         :ok <- require_projection(projection["capability"] == donor["capability"], :capability),
         :ok <- require_projection(projection["owner"] == donor["owner"], :owner),
         :ok <- require_projection(projection["donorDigest"] == donor_digest, :donor_digest),
         :ok <- require_projection(digest?(projection["payloadDigest"]), :payload_digest),
         :ok <- require_projection(projection["authority"] == "NONE", :authority),
         :ok <- require_projection(projection["consequence"] == "EVIDENCE_ONLY", :consequence),
         :ok <- require_projection(projection["standing"] == "CANDIDATE", :standing) do
      {:ok, projection}
    end
  end

  def admit_projection(id, other),
    do: {:error, %{code: :refused_dfcm_projection_shape, donor: id, observed: other}}

  @spec envelope(String.t()) :: {:ok, Envelope.t()} | {:error, term()}
  def envelope(id) do
    with {:ok, donor} <- fetch(id),
         :ok <- validate_donor(donor) do
      Envelope.new(%{
        envelope_id: "urn:ash-a2a:dfcm:fleet:#{donor["id"]}:#{donor["sha"]}",
        kind: "sa2a:FleetCapabilityDonor",
        subjects: [donor["subject"]],
        semantic_basis: ["urn:ash-a2a:dfcm:capability:#{donor["capability"]}"],
        provenance: %{
          "dfcm" => true,
          "repository" => donor["repository"],
          "sha" => donor["sha"],
          "owner" => donor["owner"]
        },
        consequence_class: "none",
        authority_requirement: "none",
        bounds: %{
          "authority" => "NONE",
          "consequence" => "EVIDENCE_ONLY",
          "falsifier" => donor["falsifier"]
        }
      })
    end
  end

  defp validate_donor(donor) do
    cond do
      not is_binary(donor["id"]) or donor["id"] == "" ->
        refusal(:id, donor["id"])

      not is_binary(donor["repository"]) or
          not String.starts_with?(donor["repository"], "seanchatmangpt/") ->
        refusal(:repository, donor["repository"])

      not is_binary(donor["sha"]) or not Regex.match?(@sha40, donor["sha"]) ->
        refusal(:sha, donor["sha"])

      donor["subject"] != donor["repository"] <> "@" <> donor["sha"] ->
        refusal(:subject, donor["subject"])

      donor["authority"] != "NONE" ->
        refusal(:authority, donor["authority"])

      donor["consequence"] != "EVIDENCE_ONLY" ->
        refusal(:consequence, donor["consequence"])

      not is_list(donor["reuse"]) or donor["reuse"] == [] ->
        refusal(:reuse, donor["reuse"])

      not is_list(donor["negative_knowledge"]) or donor["negative_knowledge"] == [] ->
        refusal(:negative_knowledge, donor["negative_knowledge"])

      not is_binary(donor["falsifier"]) or donor["falsifier"] == "" ->
        refusal(:falsifier, donor["falsifier"])

      true ->
        :ok
    end
  end

  defp digest?(value),
    do: is_binary(value) and Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, value)

  defp require_projection(true, _field), do: :ok
  defp require_projection(false, field), do: {:error, %{code: :refused_dfcm_projection, field: field}}

  defp refusal(field, observed),
    do: {:error, %{code: :invalid_dfcm_donor, field: field, observed: observed}}
end
