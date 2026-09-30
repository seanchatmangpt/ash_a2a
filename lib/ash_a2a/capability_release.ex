defmodule AshA2A.CapabilityRelease do
  @moduledoc """
  Frozen capability lifecycle and deployment closure.

  Candidate, admitted, released, and retired are distinct states. Only released
  capabilities may enter a frozen closure, and only members of that closure may
  pass the strict runtime guard. A closure digest is evidence identity, never
  authority by itself.

  Existing deployments remain backward-compatible until strict mode is enabled.
  Supplying a capability_release_closure in CommandBus opts enables strict mode
  for that call automatically.
  """

  @digest ~r/^(?:sha256|blake3):[0-9a-f]{64}$/
  @sha40 ~r/\A[0-9a-f]{40}\z/

  defmodule Capability do
    @moduledoc false
    @enforce_keys [:id, :version, :digest, :state]
    defstruct [
      :id,
      :version,
      :digest,
      :state,
      :admission_digest,
      :release_digest,
      :retirement_digest,
      :standing_binding
    ]

    @type state :: :candidate | :admitted | :released | :retired

    @type t :: %__MODULE__{
            id: String.t(),
            version: String.t(),
            digest: String.t(),
            state: state(),
            admission_digest: String.t() | nil,
            release_digest: String.t() | nil,
            retirement_digest: String.t() | nil,
            standing_binding: AshA2A.CapabilityRelease.StandingBinding.t() | nil
          }
  end

  defmodule StandingBinding do
    @moduledoc false
    @enforce_keys [
      :court,
      :standing,
      :subject_sha,
      :receipt_digest,
      :conformance,
      :binding_digest
    ]
    defstruct [
      :court,
      :standing,
      :subject_sha,
      :profile,
      :receipt_digest,
      :receipt_source,
      :conformance,
      :binding_digest
    ]

    @type t :: %__MODULE__{
            court: String.t(),
            standing: String.t(),
            subject_sha: String.t(),
            profile: String.t() | nil,
            receipt_digest: String.t(),
            receipt_source: String.t() | nil,
            conformance: String.t(),
            binding_digest: String.t()
          }
  end

  defmodule Closure do
    @moduledoc false
    @enforce_keys [:digest, :portable_digest, :capabilities]
    defstruct [:digest, :portable_digest, :capabilities]

    @type t :: %__MODULE__{
            digest: String.t(),
            portable_digest: String.t(),
            capabilities: %{required(String.t()) => Capability.t()}
          }
  end

  defmodule Binding do
    @moduledoc false
    @enforce_keys [
      :closure_digest,
      :portable_closure_digest,
      :capability_id,
      :capability_version,
      :capability_digest,
      :admission_digest,
      :release_digest,
      :binding_digest
    ]
    defstruct [
      :closure_digest,
      :portable_closure_digest,
      :capability_id,
      :capability_version,
      :capability_digest,
      :admission_digest,
      :release_digest,
      :standing_binding,
      :binding_digest
    ]

    @type t :: %__MODULE__{
            closure_digest: String.t(),
            portable_closure_digest: String.t(),
            capability_id: String.t(),
            capability_version: String.t(),
            capability_digest: String.t(),
            admission_digest: String.t(),
            release_digest: String.t(),
            standing_binding: AshA2A.CapabilityRelease.StandingBinding.t() | nil,
            binding_digest: String.t()
          }
  end

  alias __MODULE__.{Binding, Capability, Closure, StandingBinding}

  @spec candidate(String.t(), String.t(), String.t()) :: Capability.t()
  def candidate(id, version, digest) do
    validate_text!(:id, id)
    validate_text!(:version, version)
    validate_digest!(:digest, digest)
    %Capability{id: id, version: version, digest: digest, state: :candidate}
  end

  @spec admit(Capability.t(), String.t()) :: {:ok, Capability.t()} | {:error, term()}
  def admit(%Capability{state: :candidate} = capability, admission_digest) do
    with :ok <- validate_digest(:admission_digest, admission_digest) do
      {:ok,
       %{
         capability
         | state: :admitted,
           admission_digest: admission_digest
       }}
    end
  end

  def admit(%Capability{state: state}, _digest),
    do: {:error, {:invalid_release_transition, state, :admitted}}

  @spec release(Capability.t(), String.t()) :: {:ok, Capability.t()} | {:error, term()}
  def release(%Capability{state: :admitted} = capability, release_digest) do
    with :ok <- validate_digest(:release_digest, release_digest) do
      {:ok,
       %{
         capability
         | state: :released,
           release_digest: release_digest
       }}
    end
  end

  def release(%Capability{state: state}, _digest),
    do: {:error, {:invalid_release_transition, state, :released}}

  @doc """
  Releases an admitted capability only after AshA2A.StandingRef resolves
  durable court evidence for an exact subject.

  This is additive to release/2: existing strict deployments retain their
  historical release semantics. Consumers that require technical standing use
  release_from_standing/2 plus freeze_standing/1 and runtime mode
  :standing_strict.

  The court receipt is evidence, never runtime authority. External
  institutional standing is deliberately outside this structure.
  """
  @spec release_from_standing(Capability.t(), keyword()) ::
          {:ok, Capability.t()} | {:error, term()}
  def release_from_standing(%Capability{state: :admitted} = capability, opts \\ [])
      when is_list(opts) do
    with {:ok, resolution} <- AshA2A.StandingRef.resolve(opts),
         :ok <- ensure_releasable_standing(resolution.standing),
         {:ok, receipt_digest} <- normalize_receipt_digest(resolution.receipt_digest) do
      standing_binding = build_standing_binding(resolution, receipt_digest)

      {:ok,
       %{
         capability
         | state: :released,
           release_digest: receipt_digest,
           standing_binding: standing_binding
       }}
    end
  end

  def release_from_standing(%Capability{state: state}, _opts),
    do: {:error, {:invalid_release_transition, state, :released}}

  @spec retire(Capability.t(), String.t()) :: {:ok, Capability.t()} | {:error, term()}
  def retire(%Capability{state: :released} = capability, retirement_digest) do
    with :ok <- validate_digest(:retirement_digest, retirement_digest) do
      {:ok,
       %{
         capability
         | state: :retired,
           retirement_digest: retirement_digest
       }}
    end
  end

  def retire(%Capability{state: state}, _digest),
    do: {:error, {:invalid_release_transition, state, :retired}}

  @doc """
  Freezes one deployment closure. Every member must already be released and each
  capability id may occur only once. The digest is stable under input ordering.
  """
  @spec freeze([Capability.t()]) :: {:ok, Closure.t()} | {:error, term()}
  def freeze(capabilities) when is_list(capabilities) do
    with :ok <- require_released(capabilities),
         :ok <- require_unique_ids(capabilities) do
      ordered = Enum.sort_by(capabilities, &{&1.id, &1.version, &1.digest})
      digest = digest_term(Enum.map(ordered, &closure_projection/1))
      portable_digest = portable_digest(ordered)
      by_id = Map.new(ordered, &{&1.id, &1})
      {:ok, %Closure{digest: digest, portable_digest: portable_digest, capabilities: by_id}}
    end
  end

  @doc """
  Freezes a closure only when every released capability carries durable
  technical-standing evidence resolved by release_from_standing/2.
  """
  @spec freeze_standing([Capability.t()]) :: {:ok, Closure.t()} | {:error, term()}
  def freeze_standing(capabilities) when is_list(capabilities) do
    with {:ok, closure} <- freeze(capabilities),
         :ok <- require_standing(capabilities) do
      {:ok, closure}
    end
  end

  @spec select(Closure.t(), String.t()) :: {:ok, Capability.t()} | {:error, term()}
  def select(%Closure{} = closure, capability_id) when is_binary(capability_id) do
    case Map.fetch(closure.capabilities, capability_id) do
      {:ok, %Capability{state: :released} = capability} -> {:ok, capability}
      :error -> {:error, {:capability_not_released, capability_id, closure.digest}}
    end
  end

  @doc """
  Runtime release gate used by CommandBus and Dispatcher.

  Modes:
    * legacy - preserve pre-v26.9.26 behavior.
    * strict - require a frozen closure and exact skill id membership.
    * standing_strict - additionally require every closure member to carry
      durable exact-subject technical standing.

  Passing a closure in opts implies strict for that call unless a mode is
  explicitly supplied.
  """
  @spec guard(String.t(), keyword()) :: :ok | {:error, term()}
  def guard(capability_id, opts \\ []) when is_binary(capability_id) and is_list(opts) do
    case binding(capability_id, opts) do
      {:ok, _binding_or_nil} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolve the exact released version selected by the current closure.

  Legacy mode returns {:ok, nil}; strict mode returns an immutable Binding.
  The binding is evidence identity and may be recorded on a receipt, but it is
  never an authority token.
  """
  @spec binding(String.t(), keyword()) :: {:ok, Binding.t() | nil} | {:error, term()}
  def binding(capability_id, opts \\ []) when is_binary(capability_id) and is_list(opts) do
    case release_config(opts) do
      {:legacy, _closure} ->
        {:ok, nil}

      {:strict, %Closure{} = closure} ->
        with {:ok, capability} <- select(closure, capability_id) do
          {:ok, build_binding(closure, capability)}
        end

      {:standing_strict, %Closure{} = closure} ->
        with :ok <- require_standing(Map.values(closure.capabilities)),
             {:ok, capability} <- select(closure, capability_id) do
          {:ok, build_binding(closure, capability)}
        end

      {:strict, nil} ->
        {:error, :capability_release_closure_missing}

      {:standing_strict, nil} ->
        {:error, :capability_release_closure_missing}

      {other, _closure} ->
        {:error, {:invalid_capability_release_mode, other}}
    end
  end

  @doc "Return released capability ids in stable lexical order."
  @spec released_ids(Closure.t()) :: [String.t()]
  def released_ids(%Closure{} = closure) do
    closure.capabilities
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Filter an advertised/dispatchable skill index through the current release
  mode. Strict mode never advertises a skill that the same closure would refuse
  at runtime.
  """
  @spec filter_skills([map()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def filter_skills(skills, opts \\ []) when is_list(skills) and is_list(opts) do
    case release_config(opts) do
      {:legacy, _closure} ->
        {:ok, skills}

      {:strict, %Closure{} = closure} ->
        released = MapSet.new(released_ids(closure))
        {:ok, Enum.filter(skills, &MapSet.member?(released, &1.id))}

      {:standing_strict, %Closure{} = closure} ->
        with :ok <- require_standing(Map.values(closure.capabilities)) do
          released = MapSet.new(released_ids(closure))
          {:ok, Enum.filter(skills, &MapSet.member?(released, &1.id))}
        end

      {:strict, nil} ->
        {:error, :capability_release_closure_missing}

      {:standing_strict, nil} ->
        {:error, :capability_release_closure_missing}

      {other, _closure} ->
        {:error, {:invalid_capability_release_mode, other}}
    end
  end

  @doc "Stable receipt/intended-effect projection of one strict release binding."
  @spec attributes(Binding.t() | nil) :: map()
  def attributes(nil), do: %{}

  def attributes(%Binding{} = binding) do
    base = %{
      release_closure_digest: binding.closure_digest,
      release_portable_closure_digest: binding.portable_closure_digest,
      release_capability_id: binding.capability_id,
      release_capability_version: binding.capability_version,
      release_capability_digest: binding.capability_digest,
      release_admission_digest: binding.admission_digest,
      release_evidence_digest: binding.release_digest,
      release_binding_digest: binding.binding_digest
    }

    case binding.standing_binding do
      nil ->
        base

      %StandingBinding{} = standing ->
        Map.merge(base, %{
          technical_standing_court: standing.court,
          technical_standing: standing.standing,
          technical_standing_subject_sha: standing.subject_sha,
          technical_standing_profile: standing.profile,
          technical_standing_conformance: standing.conformance,
          technical_standing_receipt_digest: standing.receipt_digest,
          technical_standing_binding_digest: standing.binding_digest
        })
    end
  end

  defp build_binding(%Closure{} = closure, %Capability{state: :released} = capability) do
    legacy_projection = {
      closure.digest,
      closure.portable_digest,
      capability.id,
      capability.version,
      capability.digest,
      capability.admission_digest,
      capability.release_digest
    }

    projection =
      case capability.standing_binding do
        nil -> legacy_projection
        %StandingBinding{} = standing -> {legacy_projection, standing.binding_digest}
      end

    %Binding{
      closure_digest: closure.digest,
      portable_closure_digest: closure.portable_digest,
      capability_id: capability.id,
      capability_version: capability.version,
      capability_digest: capability.digest,
      admission_digest: capability.admission_digest,
      release_digest: capability.release_digest,
      standing_binding: capability.standing_binding,
      binding_digest: digest_term(projection)
    }
  end

  defp build_standing_binding(resolution, receipt_digest) do
    projection = {
      resolution.court,
      resolution.standing,
      resolution.sha,
      resolution.profile,
      resolution.conformance,
      receipt_digest
    }

    %StandingBinding{
      court: resolution.court,
      standing: resolution.standing,
      subject_sha: resolution.sha,
      profile: resolution.profile,
      receipt_digest: receipt_digest,
      receipt_source: resolution.receipt_source,
      conformance: resolution.conformance,
      binding_digest: digest_term(projection)
    }
  end

  defp release_config(opts) do
    closure =
      Keyword.get(opts, :capability_release_closure) ||
        Application.get_env(:ash_a2a, :capability_release_closure)

    mode =
      Keyword.get_lazy(opts, :capability_release_mode, fn ->
        configured = Application.get_env(:ash_a2a, :capability_release_mode)

        cond do
          configured == :standing_strict -> :standing_strict
          Keyword.has_key?(opts, :capability_release_closure) -> :strict
          configured == :strict -> :strict
          true -> :legacy
        end
      end)

    {mode, closure}
  end

  defp require_released(capabilities) do
    case Enum.find(capabilities, &(&1.state != :released)) do
      nil -> :ok
      %Capability{} = capability -> {:error, {:not_released, capability.id, capability.state}}
    end
  end

  defp require_standing(capabilities) do
    Enum.reduce_while(capabilities, :ok, fn
      %Capability{} = capability, :ok ->
        case validate_standing_binding(capability) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
    end)
  end

  defp validate_standing_binding(%Capability{standing_binding: nil} = capability),
    do: {:error, {:technical_standing_required, capability.id}}

  defp validate_standing_binding(
         %Capability{
           release_digest: release_digest,
           standing_binding: %StandingBinding{} = standing
         } = capability
       ) do
    projection = {
      standing.court,
      standing.standing,
      standing.subject_sha,
      standing.profile,
      standing.conformance,
      standing.receipt_digest
    }

    expected_binding_digest = digest_term(projection)

    cond do
      standing.standing != "CONFORMANT" ->
        {:error, {:technical_standing_not_releasable, capability.id, standing.standing}}

      not is_binary(standing.court) or String.trim(standing.court) == "" ->
        {:error, {:technical_standing_invalid, capability.id, :court}}

      not is_binary(standing.subject_sha) or not Regex.match?(@sha40, standing.subject_sha) ->
        {:error, {:technical_standing_invalid, capability.id, :subject_sha}}

      validate_digest(:receipt_digest, standing.receipt_digest) != :ok ->
        {:error, {:technical_standing_invalid, capability.id, :receipt_digest}}

      release_digest != standing.receipt_digest ->
        {:error, {:technical_standing_invalid, capability.id, :release_digest_mismatch}}

      not is_binary(standing.receipt_source) or String.trim(standing.receipt_source) == "" ->
        {:error, {:technical_standing_invalid, capability.id, :receipt_source}}

      standing.binding_digest != expected_binding_digest ->
        {:error, {:technical_standing_invalid, capability.id, :binding_digest}}

      true ->
        :ok
    end
  end

  defp ensure_releasable_standing("CONFORMANT"), do: :ok

  defp ensure_releasable_standing(other),
    do: {:error, {:technical_standing_not_releasable, other}}

  defp require_unique_ids(capabilities) do
    ids = Enum.map(capabilities, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      [duplicate | _] -> {:error, {:duplicate_capability_id, duplicate}}
    end
  end

  defp closure_projection(%Capability{} = capability) do
    legacy = {
      capability.id,
      capability.version,
      capability.digest,
      capability.admission_digest,
      capability.release_digest
    }

    case capability.standing_binding do
      nil -> legacy
      %StandingBinding{} = standing -> {legacy, standing.binding_digest}
    end
  end

  @doc """
  Cross-runtime closure identity using RFC 8785 JCS.

  The existing `Closure.digest` remains the compatibility identity based on
  deterministic Erlang-term encoding. This portable digest is an additional
  identity over JSON-native data so Python/RDF/tooling can independently
  recompute the same closure without understanding BEAM term encoding.
  """
  @spec portable_digest([Capability.t()]) :: String.t()
  def portable_digest(capabilities) when is_list(capabilities) do
    standing? = Enum.any?(capabilities, &match?(%StandingBinding{}, &1.standing_binding))

    members =
      capabilities
      |> Enum.sort_by(&{&1.id, &1.version, &1.digest})
      |> Enum.map(&portable_member(&1, standing?))

    payload = %{
      "schema" => if(standing?, do: "chatman.release-closure/v2", else: "chatman.release-closure/v1"),
      "members" => members
    }

    "sha256:" <>
      (:crypto.hash(:sha256, Jcs.encode(payload))
       |> Base.encode16(case: :lower))
  end

  defp portable_member(capability, false) do
    %{
      "capability_id" => capability.id,
      "version" => capability.version,
      "capability_digest" => capability.digest,
      "admission_digest" => capability.admission_digest,
      "release_digest" => capability.release_digest
    }
  end

  defp portable_member(
         %Capability{standing_binding: %StandingBinding{} = standing} = capability,
         true
       ) do
    portable_member(capability, false)
    |> Map.put("technical_standing", %{
      "court" => standing.court,
      "standing" => standing.standing,
      "subject_sha" => standing.subject_sha,
      "profile" => standing.profile,
      "conformance" => standing.conformance,
      "receipt_digest" => standing.receipt_digest,
      "binding_digest" => standing.binding_digest
    })
  end

  defp portable_member(%Capability{} = capability, true) do
    portable_member(capability, false)
    |> Map.put("technical_standing", nil)
  end

  defp normalize_receipt_digest("sha256:" <> _ = digest) do
    case validate_digest(:receipt_digest, digest) do
      :ok -> {:ok, digest}
      {:error, _} = error -> error
    end
  end

  defp normalize_receipt_digest(digest) when is_binary(digest) do
    candidate = "sha256:" <> digest

    case validate_digest(:receipt_digest, candidate) do
      :ok -> {:ok, candidate}
      {:error, _} = error -> error
    end
  end

  defp normalize_receipt_digest(_), do: {:error, {:invalid_digest, :receipt_digest}}

  defp digest_term(term) do
    "sha256:" <>
      (:crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
       |> Base.encode16(case: :lower))
  end

  defp validate_text!(name, value) when is_binary(value) do
    if String.trim(value) == "", do: raise(ArgumentError, "#{name} is required")
    value
  end

  defp validate_text!(name, _value), do: raise(ArgumentError, "#{name} must be a string")

  defp validate_digest(name, value) when is_binary(value) do
    if Regex.match?(@digest, value), do: :ok, else: {:error, {:invalid_digest, name}}
  end

  defp validate_digest(name, _value), do: {:error, {:invalid_digest, name}}

  defp validate_digest!(name, value) do
    case validate_digest(name, value) do
      :ok -> value
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end
end
