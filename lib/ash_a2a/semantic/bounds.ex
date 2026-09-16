defmodule AshA2A.Semantic.Bounds do
  @moduledoc """
  Explicit, fail-closed execution ceilings for semantic work (RFC-SA2A-001
  S34 fan-out/depth/parallelism, S35 resource envelope, S73 no blank check).

  A `Bounds` is an *envelope*, never a grant. It cannot admit anything: it
  can only refuse. `authority: :none` is enforced structurally by
  `fence/1` and is never settable through `new/1`, so no code path can turn
  a budget into permission. Authority remains exclusively the business of
  `AshA2A.Authority` / `AshA2A.CommandBus`; possessing budget is orthogonal
  to being allowed to spend it (RFC S29: `Capability NOT=> Authority`, and
  by the same argument `Budget NOT=> Authority`).

  ## Fail closed, not open

  Every ceiling is REQUIRED at construction. There is deliberately no
  default and no `:infinity`:

    * An unspecified ceiling is a construction error, not "unlimited".
    * An unknown resource key in `consume/3` is a refusal
      (`:bounds_resource_unknown`), not an implicitly infinite budget.
    * Exhaustion is a refusal (`:bounds_resource_exhausted`), never a
      clamp-to-zero-and-proceed.

  ## S73 -- no blank check

  `delegate/2` is the only way to produce a child envelope, and it may only
  NARROW:

    * `fan_out`, `parallelism`, and every resource budget must be `<=` the
      parent's.
    * `depth` must be `<= parent.depth - 1`; delegating from `depth: 0` is
      refused outright (`:bounds_depth_exhausted`).
    * the child's capability set must be a subset of the parent's.
    * the child's reservation is SUBTRACTED from the parent, so a subtask
      cannot manufacture budget for itself by being delegated to twice --
      `delegate/2` returns both the child and the debited parent.

  A subtask asking for more than it was delegated is refused
  (`:bounds_delegation_not_narrowing`) with the offending field named.
  """

  @enforce_keys [:fan_out, :depth, :parallelism, :resources, :capabilities]
  defstruct [:fan_out, :depth, :parallelism, :resources, :capabilities, authority: :none]

  @type refusal :: %{required(:code) => atom(), optional(:detail) => term()}
  @type t :: %__MODULE__{
          fan_out: non_neg_integer(),
          depth: non_neg_integer(),
          parallelism: pos_integer(),
          resources: %{optional(atom()) => non_neg_integer()},
          capabilities: MapSet.t(String.t()),
          authority: :none
        }

  @ceilings [:fan_out, :depth, :parallelism]

  @doc """
  Builds an envelope. Every ceiling is required; there is no implicit
  unlimited.

      iex> {:ok, bounds} =
      ...>   AshA2A.Semantic.Bounds.new(
      ...>     fan_out: 2,
      ...>     depth: 1,
      ...>     parallelism: 1,
      ...>     resources: %{tokens: 100},
      ...>     capabilities: ["Some.Resource.read"]
      ...>   )
      iex> {bounds.fan_out, bounds.authority}
      {2, :none}

      iex> AshA2A.Semantic.Bounds.new(depth: 1, parallelism: 1)
      {:error, %{code: :bounds_ceiling_missing, detail: :fan_out}}
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, refusal()}
  def new(opts) when is_list(opts) do
    with {:ok, fan_out} <- fetch_ceiling(opts, :fan_out),
         {:ok, depth} <- fetch_ceiling(opts, :depth),
         {:ok, parallelism} <- fetch_ceiling(opts, :parallelism),
         :ok <- positive_parallelism(parallelism),
         {:ok, resources} <- normalize_resources(Keyword.get(opts, :resources, %{})),
         {:ok, capabilities} <- normalize_capabilities(Keyword.get(opts, :capabilities, [])) do
      {:ok,
       %__MODULE__{
         fan_out: fan_out,
         depth: depth,
         parallelism: parallelism,
         resources: resources,
         capabilities: capabilities,
         authority: :none
       }}
    end
  end

  @doc """
  Structural authority ceiling, mirroring `AshA2A.Semantic.Admission`'s own
  `fence/1`: an envelope that somehow carries authority is not admissible.
  """
  @spec fence(t()) :: :ok | {:error, refusal()}
  def fence(%__MODULE__{authority: :none}), do: :ok
  def fence(%__MODULE__{}), do: error(:bounds_authority_ceiling_violated)

  @doc """
  Refuses a requested fan-out above the ceiling.

      iex> {:ok, bounds} = AshA2A.Semantic.Bounds.new(fan_out: 2, depth: 1, parallelism: 1)
      iex> AshA2A.Semantic.Bounds.admit_fan_out(bounds, 2)
      :ok
      iex> AshA2A.Semantic.Bounds.admit_fan_out(bounds, 3)
      {:error, %{code: :bounds_fan_out_exceeded, detail: %{ceiling: 2, requested: 3}}}
  """
  @spec admit_fan_out(t(), integer()) :: :ok | {:error, refusal()}
  def admit_fan_out(%__MODULE__{} = bounds, requested),
    do: admit_ceiling(bounds, :fan_out, requested, :bounds_fan_out_exceeded)

  @doc "Refuses a requested depth above the ceiling."
  @spec admit_depth(t(), integer()) :: :ok | {:error, refusal()}
  def admit_depth(%__MODULE__{} = bounds, requested),
    do: admit_ceiling(bounds, :depth, requested, :bounds_depth_exceeded)

  @doc "Refuses a requested parallelism above the ceiling."
  @spec admit_parallelism(t(), integer()) :: :ok | {:error, refusal()}
  def admit_parallelism(%__MODULE__{} = bounds, requested),
    do: admit_ceiling(bounds, :parallelism, requested, :bounds_parallelism_exceeded)

  @doc """
  Refuses a capability the envelope was never delegated. Membership here is
  NOT authority -- it only says the envelope does not forbid the capability;
  `AshA2A.CommandBus` still requires a real `AshA2A.Authority`.
  """
  @spec admit_capability(t(), String.t()) :: :ok | {:error, refusal()}
  def admit_capability(%__MODULE__{} = bounds, capability_id) when is_binary(capability_id) do
    if MapSet.member?(bounds.capabilities, capability_id),
      do: :ok,
      else: error(:bounds_capability_not_delegated, capability_id)
  end

  @doc """
  Spends `amount` of `key`. Unknown keys and overspend both fail closed.

      iex> {:ok, bounds} =
      ...>   AshA2A.Semantic.Bounds.new(
      ...>     fan_out: 1, depth: 1, parallelism: 1, resources: %{tokens: 10}
      ...>   )
      iex> {:ok, spent} = AshA2A.Semantic.Bounds.consume(bounds, :tokens, 10)
      iex> spent.resources
      %{tokens: 0}
      iex> AshA2A.Semantic.Bounds.consume(spent, :tokens, 1)
      {:error, %{code: :bounds_resource_exhausted, detail: %{key: :tokens, remaining: 0, requested: 1}}}
      iex> AshA2A.Semantic.Bounds.consume(bounds, :gpu_seconds, 1)
      {:error, %{code: :bounds_resource_unknown, detail: :gpu_seconds}}
  """
  @spec consume(t(), atom(), integer()) :: {:ok, t()} | {:error, refusal()}
  def consume(%__MODULE__{} = bounds, key, amount) when is_atom(key) and is_integer(amount) do
    cond do
      amount < 0 ->
        error(:bounds_resource_amount_invalid, %{key: key, requested: amount})

      not Map.has_key?(bounds.resources, key) ->
        error(:bounds_resource_unknown, key)

      Map.fetch!(bounds.resources, key) < amount ->
        error(:bounds_resource_exhausted, %{
          key: key,
          remaining: Map.fetch!(bounds.resources, key),
          requested: amount
        })

      true ->
        {:ok, %{bounds | resources: Map.update!(bounds.resources, key, &(&1 - amount))}}
    end
  end

  @doc """
  RFC S73. Produces a strictly-narrower child envelope and the parent it was
  debited from. A subtask cannot manufacture authority or budget for itself:
  every field is checked against the parent, and the parent's resources are
  reduced by the child's reservation.

  Returns `{:ok, %{child: child, parent: debited_parent}}`.
  """
  @spec delegate(t(), keyword()) ::
          {:ok, %{child: t(), parent: t()}} | {:error, refusal()}
  def delegate(%__MODULE__{} = parent, request) when is_list(request) do
    result = do_delegate(parent, request)

    # RFC-SA2A-002 §66 delegated-envelope evidence: every delegation decision
    # is emitted at this boundary. Observation only; `result` is unchanged.
    {outcome, code} =
      case result do
        {:ok, _} -> {:delegated, nil}
        {:error, %{code: code}} -> {:refused, code}
        _other -> {:refused, nil}
      end

    :telemetry.execute(
      [:ash_a2a, :semantic, :bounds, :delegate],
      %{system_time: System.system_time()},
      %{
        outcome: outcome,
        code: code,
        parent_capabilities: capability_label(parent.capabilities),
        requested_capabilities: capability_label(Keyword.get(request, :capabilities, []))
      }
    )

    result
  end

  defp capability_label(%MapSet{} = capabilities),
    do: capabilities |> MapSet.to_list() |> capability_label()

  defp capability_label(capabilities) do
    capabilities
    |> List.wrap()
    |> Enum.map(&if(is_binary(&1), do: &1, else: inspect(&1)))
    |> Enum.sort()
    |> Enum.join(",")
  end

  defp do_delegate(parent, request) do
    with :ok <- fence(parent),
         :ok <- depth_available(parent),
         {:ok, fan_out} <- narrowed(request, :fan_out, parent.fan_out),
         {:ok, depth} <- narrowed(request, :depth, parent.depth - 1),
         {:ok, parallelism} <- narrowed(request, :parallelism, parent.parallelism),
         :ok <- positive_parallelism(parallelism),
         {:ok, requested_resources} <-
           normalize_resources(Keyword.get(request, :resources, %{})),
         {:ok, resources} <- narrowed_resources(parent.resources, requested_resources),
         {:ok, capabilities} <-
           narrowed_capabilities(
             parent.capabilities,
             Keyword.get(request, :capabilities, MapSet.to_list(parent.capabilities))
           ),
         :ok <- no_manufactured_authority(request) do
      child = %__MODULE__{
        fan_out: fan_out,
        depth: depth,
        parallelism: parallelism,
        resources: resources,
        capabilities: capabilities,
        authority: :none
      }

      debited = %{
        parent
        | resources:
            Enum.reduce(resources, parent.resources, fn {key, amount}, acc ->
              Map.update!(acc, key, &(&1 - amount))
            end)
      }

      {:ok, %{child: child, parent: debited}}
    end
  end

  # -- internals -------------------------------------------------------

  defp admit_ceiling(bounds, field, requested, code) when is_integer(requested) do
    ceiling = Map.fetch!(bounds, field)

    cond do
      requested < 0 -> error(code, %{ceiling: ceiling, requested: requested})
      requested > ceiling -> error(code, %{ceiling: ceiling, requested: requested})
      true -> :ok
    end
  end

  defp admit_ceiling(bounds, field, requested, code),
    do: error(code, %{ceiling: Map.fetch!(bounds, field), requested: requested})

  defp depth_available(%__MODULE__{depth: depth}) when depth >= 1, do: :ok
  defp depth_available(%__MODULE__{depth: depth}), do: error(:bounds_depth_exhausted, depth)

  defp narrowed(request, field, ceiling) do
    case Keyword.fetch(request, field) do
      :error ->
        {:ok, ceiling}

      {:ok, value} when is_integer(value) and value >= 0 and value <= ceiling ->
        {:ok, value}

      {:ok, value} ->
        error(:bounds_delegation_not_narrowing, %{
          field: field,
          parent: ceiling,
          requested: value
        })
    end
  end

  defp narrowed_resources(parent_resources, requested) do
    Enum.reduce_while(requested, {:ok, %{}}, fn {key, amount}, {:ok, acc} ->
      case Map.fetch(parent_resources, key) do
        :error ->
          {:halt, error(:bounds_resource_unknown, key)}

        {:ok, parent_amount} when amount <= parent_amount ->
          {:cont, {:ok, Map.put(acc, key, amount)}}

        {:ok, parent_amount} ->
          {:halt,
           error(:bounds_delegation_not_narrowing, %{
             field: {:resources, key},
             parent: parent_amount,
             requested: amount
           })}
      end
    end)
  end

  defp narrowed_capabilities(parent_capabilities, requested) do
    requested = MapSet.new(List.wrap(requested))

    if MapSet.subset?(requested, parent_capabilities) do
      {:ok, requested}
    else
      error(:bounds_delegation_not_narrowing, %{
        field: :capabilities,
        requested: MapSet.to_list(MapSet.difference(requested, parent_capabilities))
      })
    end
  end

  # A delegation request may never carry authority, even `:none` explicitly
  # supplied by the subtask -- the child's authority is set by this module,
  # not requested by the delegate.
  defp no_manufactured_authority(request) do
    if Keyword.has_key?(request, :authority),
      do: error(:bounds_authority_not_delegable, Keyword.get(request, :authority)),
      else: :ok
  end

  defp fetch_ceiling(opts, field) when field in @ceilings do
    case Keyword.fetch(opts, field) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, value} -> error(:bounds_ceiling_invalid, %{field: field, value: value})
      :error -> error(:bounds_ceiling_missing, field)
    end
  end

  defp positive_parallelism(value) when is_integer(value) and value >= 1, do: :ok

  defp positive_parallelism(value),
    do: error(:bounds_ceiling_invalid, %{field: :parallelism, value: value})

  defp normalize_resources(resources) when is_map(resources) do
    Enum.reduce_while(resources, {:ok, %{}}, fn
      {key, amount}, {:ok, acc} when is_atom(key) and is_integer(amount) and amount >= 0 ->
        {:cont, {:ok, Map.put(acc, key, amount)}}

      {key, amount}, {:ok, _acc} ->
        {:halt, error(:bounds_resource_invalid, %{key: key, value: amount})}
    end)
  end

  defp normalize_resources(other), do: error(:bounds_resource_invalid, other)

  defp normalize_capabilities(capabilities) when is_list(capabilities) do
    if Enum.all?(capabilities, &is_binary/1),
      do: {:ok, MapSet.new(capabilities)},
      else: error(:bounds_capability_invalid, capabilities)
  end

  defp normalize_capabilities(%MapSet{} = capabilities),
    do: normalize_capabilities(MapSet.to_list(capabilities))

  defp normalize_capabilities(other), do: error(:bounds_capability_invalid, other)

  defp error(code), do: {:error, %{code: code}}
  defp error(code, detail), do: {:error, %{code: code, detail: detail}}
end
