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
      :retirement_digest
    ]

    @type state :: :candidate | :admitted | :released | :retired

    @type t :: %__MODULE__{
            id: String.t(),
            version: String.t(),
            digest: String.t(),
            state: state(),
            admission_digest: String.t() | nil,
            release_digest: String.t() | nil,
            retirement_digest: String.t() | nil
          }
  end

  defmodule Closure do
    @moduledoc false
    @enforce_keys [:digest, :capabilities]
    defstruct [:digest, :capabilities]

    @type t :: %__MODULE__{
            digest: String.t(),
            capabilities: %{required(String.t()) => Capability.t()}
          }
  end

  alias __MODULE__.{Capability, Closure}

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
      by_id = Map.new(ordered, &{&1.id, &1})
      {:ok, %Closure{digest: digest, capabilities: by_id}}
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
  Runtime release gate used by CommandBus.

  Modes:
    * legacy - preserve pre-v26.9.26 behavior.
    * strict - require a frozen closure and exact skill id membership.

  Passing a closure in opts implies strict for that call unless a mode is
  explicitly supplied.
  """
  @spec guard(String.t(), keyword()) :: :ok | {:error, term()}
  def guard(capability_id, opts \\ []) when is_binary(capability_id) and is_list(opts) do
    closure =
      Keyword.get(opts, :capability_release_closure) ||
        Application.get_env(:ash_a2a, :capability_release_closure)

    mode =
      Keyword.get_lazy(opts, :capability_release_mode, fn ->
        cond do
          Keyword.has_key?(opts, :capability_release_closure) -> :strict
          Application.get_env(:ash_a2a, :capability_release_mode) == :strict -> :strict
          true -> :legacy
        end
      end)

    case {mode, closure} do
      {:legacy, _} ->
        :ok

      {:strict, %Closure{} = frozen} ->
        case select(frozen, capability_id) do
          {:ok, _capability} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:strict, nil} ->
        {:error, :capability_release_closure_missing}

      {other, _} ->
        {:error, {:invalid_capability_release_mode, other}}
    end
  end

  defp require_released(capabilities) do
    case Enum.find(capabilities, &(&1.state != :released)) do
      nil -> :ok
      %Capability{} = capability -> {:error, {:not_released, capability.id, capability.state}}
    end
  end

  defp require_unique_ids(capabilities) do
    ids = Enum.map(capabilities, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      [duplicate | _] -> {:error, {:duplicate_capability_id, duplicate}}
    end
  end

  defp closure_projection(%Capability{} = capability) do
    {
      capability.id,
      capability.version,
      capability.digest,
      capability.admission_digest,
      capability.release_digest
    }
  end

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
