defmodule AshA2A.StandingBinding do
  @moduledoc """
  Durable exact-subject technical-standing binding for capability release.

  The binding is produced only by resolving an admitted StandingRef from a
  durable source. Technical standing, external standing, and runtime authority
  are separate domains; this module fixes the latter two to NONE.
  """
  @enforce_keys [:capability_id, :capability_digest, :subject_revision, :court,
    :technical_standing, :required_standing, :receipt_digest, :receipt_source,
    :portable_identity]
  defstruct [:capability_id, :capability_digest, :subject_revision, :court,
    :technical_standing, :required_standing, :receipt_digest, :receipt_source,
    :portable_identity, external_standing: "NONE", runtime_authority: "NONE"]

  @type t :: %__MODULE__{
          capability_id: String.t(),
          capability_digest: String.t(),
          subject_revision: String.t(),
          court: String.t(),
          technical_standing: String.t(),
          required_standing: String.t(),
          receipt_digest: String.t(),
          receipt_source: String.t(),
          portable_identity: String.t(),
          external_standing: String.t(),
          runtime_authority: String.t()
        }

  @sha ~r/\A[0-9a-f]{40}\z/
  @levels %{"REFUSED" => 0, "UNKNOWN" => 1, "BUILD_BROKEN" => 1,
    "NONCONFORMANT" => 1, "PARTIAL_ALIVE" => 2, "CONFORMANT" => 3}

  def resolve(capability, opts) when is_map(capability) and is_list(opts) do
    required = Keyword.get(opts, :standing, "CONFORMANT")
    with :ok <- subject_present(capability),
         true <- Map.has_key?(@levels, required) || {:error, {:unknown_required_standing, required}},
         {:ok, r} <- resolve_at_least(opts, required),
         :ok <- exact_subject(capability.subject_revision, r),
         :ok <- durable(r),
         :ok <- standing_at_least(r.standing, required) do
      payload = %{
        "schema" => "ash-a2a.standing-binding/v1",
        "capability_id" => capability.id,
        "capability_digest" => capability.digest,
        "subject_revision" => capability.subject_revision,
        "court" => r.court,
        "technical_standing" => r.standing,
        "required_standing" => required,
        "receipt_digest" => r.receipt_digest,
        "receipt_source" => r.receipt_source,
        "external_standing" => "NONE",
        "runtime_authority" => "NONE"
      }
      {:ok, struct!(__MODULE__,
        capability_id: capability.id, capability_digest: capability.digest,
        subject_revision: capability.subject_revision, court: r.court,
        technical_standing: r.standing, required_standing: required,
        receipt_digest: r.receipt_digest, receipt_source: r.receipt_source,
        portable_identity: portable_digest(payload))}
    end
  end
  def resolve(_, _), do: {:error, :standing_binding_invalid_input}

  @doc "Verify canonical standing-binding identity before composition."
  def verify(%__MODULE__{} = b) do
    with :ok <- durable(%{receipt_source: b.receipt_source}),
         :ok <- standing_at_least(b.technical_standing, b.required_standing),
         :ok <- subject_present(%{subject_revision: b.subject_revision}),
         true <- b.external_standing == "NONE" || {:error, :external_standing_conflated},
         true <- b.runtime_authority == "NONE" || {:error, :runtime_authority_conflated},
         expected = portable_digest(payload(b)),
         true <- expected == b.portable_identity || {:error, {:standing_binding_identity_mismatch, expected, b.portable_identity}} do
      :ok
    end
  end
  def verify(_), do: {:error, :standing_binding_invalid_input}

  @doc "Re-admit the exact durable receipt behind this binding before consequential composition."
  def verify_durable(b, opts \\ [])
  def verify_durable(%__MODULE__{} = b, opts) do
    with :ok <- verify(b),
         {:ok, %{receipt: receipt}} <-
           AshA2A.StandingRef.replay(
             b.subject_revision, b.court, b.technical_standing, b.receipt_source, opts
           ),
         true <-
           receipt["receipt_digest"] == b.receipt_digest ||
             {:error, :standing_receipt_digest_replay_mismatch} do
      :ok
    end
  end
  def verify_durable(_, _), do: {:error, :standing_binding_invalid_input}

  defp payload(b), do: %{
    "schema" => "ash-a2a.standing-binding/v1", "capability_id" => b.capability_id,
    "capability_digest" => b.capability_digest, "subject_revision" => b.subject_revision,
    "court" => b.court, "technical_standing" => b.technical_standing,
    "required_standing" => b.required_standing, "receipt_digest" => b.receipt_digest,
    "receipt_source" => b.receipt_source, "external_standing" => b.external_standing,
    "runtime_authority" => b.runtime_authority
  }

  def attributes(%__MODULE__{} = b), do: %{
    standing_binding_identity: b.portable_identity,
    standing_subject_revision: b.subject_revision,
    standing_court: b.court,
    technical_standing: b.technical_standing,
    required_technical_standing: b.required_standing,
    standing_receipt_digest: b.receipt_digest,
    standing_receipt_source: b.receipt_source,
    external_standing: b.external_standing,
    runtime_authority: b.runtime_authority
  }

  defp subject_present(%{subject_revision: sha}) when is_binary(sha) do
    if Regex.match?(@sha, sha), do: :ok, else: {:error, :capability_exact_subject_missing}
  end
  defp subject_present(_), do: {:error, :capability_exact_subject_missing}

  defp exact_subject(sha, %{sha: sha}), do: :ok
  defp exact_subject(expected, %{sha: observed}),
    do: {:error, {:standing_exact_subject_mismatch, expected, observed}}
  defp exact_subject(_, _), do: {:error, :standing_exact_subject_mismatch}

  defp durable(%{receipt_source: "git:" <> _}), do: :ok
  defp durable(%{receipt_source: "artifact:" <> _}), do: :ok
  defp durable(_), do: {:error, :standing_evidence_not_durable}

  # StandingRef addresses an exact court standing; release law is >= required.
  defp resolve_at_least(opts, required) do
    required_rank = Map.fetch!(@levels, required)

    @levels
    |> Enum.filter(fn {_standing, rank} -> rank >= required_rank end)
    |> Enum.sort_by(fn {standing, rank} -> {-rank, standing} end)
    |> Enum.reduce_while({:error, {:no_standing_at_or_above, required, []}}, fn {standing, _},
                                                                                 {:error, {_, _, refused}} ->
      case AshA2A.StandingRef.resolve(Keyword.put(opts, :standing, standing)) do
        {:ok, resolution} -> {:halt, {:ok, resolution}}
        {:error, reason} ->
          {:cont, {:error, {:no_standing_at_or_above, required, [{standing, reason} | refused]}}}
      end
    end)
    |> case do
      {:error, {:no_standing_at_or_above, req, refused}} ->
        {:error, {:no_standing_at_or_above, req, Enum.reverse(refused)}}
      other -> other
    end
  end

  defp standing_at_least(observed, required) do
    with {:ok, o} <- Map.fetch(@levels, observed), {:ok, r} <- Map.fetch(@levels, required) do
      if o >= r, do: :ok, else: {:error, {:standing_below_required, observed, required}}
    else
      _ -> {:error, {:unknown_standing, observed}}
    end
  end

  defp portable_digest(payload), do:
    "sha256:" <> (:crypto.hash(:sha256, Jcs.encode(payload)) |> Base.encode16(case: :lower))

  @doc false
  def __sa2a_refusal_codes__, do: %{
    standing_binding_invalid_input: :refused_identity,
    capability_exact_subject_missing: :refused_identity,
    standing_exact_subject_mismatch: :refused_identity,
    standing_evidence_not_durable: :refused_receipt
  }
end
