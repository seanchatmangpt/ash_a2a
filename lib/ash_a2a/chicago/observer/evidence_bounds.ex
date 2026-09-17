defmodule AshA2A.Chicago.Observer.EvidenceBounds do
  @moduledoc """
  Explicit, fail-closed evidence-fan-out envelope for
  `AshA2A.Chicago.Observer` (PRD §48 / ARD §51, mirroring the S34/S35
  resource-envelope discipline `AshA2A.Semantic.Bounds` already applies to
  command/hook dispatch fan-out -- applied here to the evidence/observation
  boundary instead).

  The volume and breadth of evidence a Chicago run can emit -- OCEL record
  count, distinct `:watch_events` vocabulary, and durable journal bytes (a
  proxy for total attribute payload, since payload size drives line size) --
  is admitted under an explicit ceiling rather than growing unboundedly. A
  `EvidenceBounds` is an *envelope*, never a grant: it cannot admit evidence,
  it can only refuse it, exactly as `AshA2A.Semantic.Bounds` cannot admit
  actuation, only refuse it. `authority: :none` is enforced structurally and
  is never settable through `new/1`.

  ## Fail closed, not open

  Every ceiling is REQUIRED at construction. There is deliberately no
  default and no `:infinity`:

    * An unspecified ceiling is a construction error, not "unlimited".
    * Exhaustion of any dimension is a refusal
      (`:evidence_fan_out_exceeded`), never a silent drop and never an
      implicit clamp that keeps accepting past the ceiling.

  ## What is bounded

    * `max_records` -- total OCEL records this run's observer will accept.
    * `max_watch_events` -- distinct `:watch_events` telemetry names
      attached without an admitted `Ocel.Mapping` (the unmapped-event
      vocabulary named at `AshA2A.Chicago.Observer.start_link/1`).
    * `max_journal_bytes` -- cumulative durable journal bytes across every
      accepted record's canonical JSONL line
      (`AshA2A.Chicago.Observer.Journal.encode_line/1`), a real proxy for
      total attribute payload since a record's line size grows with its
      attribute map.

  An `AshA2A.Chicago.Observer` with no `:evidence_bounds` opt behaves exactly
  as before (unbounded, per RFC-SA2A-002 §19/§138 evidence-durability
  discipline unchanged) -- this envelope is strictly additive.
  """

  @enforce_keys [:max_records, :max_watch_events, :max_journal_bytes]
  defstruct [
    :max_records,
    :max_watch_events,
    :max_journal_bytes,
    consumed_records: 0,
    consumed_journal_bytes: 0,
    watch_events_seen: MapSet.new(),
    authority: :none
  ]

  @type refusal :: %{required(:code) => atom(), optional(:detail) => term()}
  @type t :: %__MODULE__{
          max_records: pos_integer(),
          max_watch_events: non_neg_integer(),
          max_journal_bytes: pos_integer(),
          consumed_records: non_neg_integer(),
          consumed_journal_bytes: non_neg_integer(),
          watch_events_seen: MapSet.t(String.t()),
          authority: :none
        }

  @ceilings [:max_records, :max_watch_events, :max_journal_bytes]

  @doc """
  Builds an envelope. Every ceiling is required; there is no implicit
  unlimited.

      iex> {:ok, bounds} =
      ...>   AshA2A.Chicago.Observer.EvidenceBounds.new(
      ...>     max_records: 10,
      ...>     max_watch_events: 4,
      ...>     max_journal_bytes: 65_536
      ...>   )
      iex> {bounds.max_records, bounds.authority}
      {10, :none}

      iex> AshA2A.Chicago.Observer.EvidenceBounds.new(max_watch_events: 4, max_journal_bytes: 1)
      {:error, %{code: :evidence_bounds_ceiling_missing, detail: :max_records}}
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, refusal()}
  def new(opts) when is_list(opts) do
    with {:ok, max_records} <- fetch_ceiling(opts, :max_records),
         {:ok, max_watch_events} <- fetch_ceiling(opts, :max_watch_events),
         {:ok, max_journal_bytes} <- fetch_ceiling(opts, :max_journal_bytes) do
      {:ok,
       %__MODULE__{
         max_records: max_records,
         max_watch_events: max_watch_events,
         max_journal_bytes: max_journal_bytes,
         authority: :none
       }}
    end
  end

  @doc "Like `new/1`, raising on refusal. For call sites that construct a static envelope."
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, bounds} -> bounds
      {:error, refusal} -> raise ArgumentError, "invalid evidence bounds: #{inspect(refusal)}"
    end
  end

  @doc """
  Structural authority ceiling, mirroring `AshA2A.Semantic.Bounds.fence/1`:
  an envelope that somehow carries authority is not admissible. A bounds
  envelope is a budget, never a grant.
  """
  @spec fence(t()) :: :ok | {:error, refusal()}
  def fence(%__MODULE__{authority: :none}), do: :ok
  def fence(%__MODULE__{}), do: error(:evidence_bounds_authority_ceiling_violated)

  @doc """
  Admits one more accepted record against `max_records`. Fail-closed: a run
  already at the ceiling is refused rather than silently kept accepting.

      iex> {:ok, bounds} =
      ...>   AshA2A.Chicago.Observer.EvidenceBounds.new(
      ...>     max_records: 1, max_watch_events: 1, max_journal_bytes: 1_000
      ...>   )
      iex> {:ok, spent} = AshA2A.Chicago.Observer.EvidenceBounds.consume_record(bounds)
      iex> spent.consumed_records
      1
      iex> AshA2A.Chicago.Observer.EvidenceBounds.consume_record(spent)
      {:error, %{code: :evidence_fan_out_exceeded, detail: %{resource: :max_records, ceiling: 1, consumed: 1}}}
  """
  @spec consume_record(t()) :: {:ok, t()} | {:error, refusal()}
  def consume_record(%__MODULE__{} = bounds) do
    if bounds.consumed_records >= bounds.max_records do
      error(:evidence_fan_out_exceeded, %{
        resource: :max_records,
        ceiling: bounds.max_records,
        consumed: bounds.consumed_records
      })
    else
      {:ok, %{bounds | consumed_records: bounds.consumed_records + 1}}
    end
  end

  @doc """
  Charges `size` bytes against `max_journal_bytes`. Unlike `consume_record/1`
  this is a cumulative spend of an integer amount, mirroring
  `AshA2A.Semantic.Bounds.consume/3`: a negative size is refused outright
  (never a credit), and overspend fails closed rather than clamping.
  """
  @spec consume_journal_bytes(t(), integer()) :: {:ok, t()} | {:error, refusal()}
  def consume_journal_bytes(%__MODULE__{} = bounds, size) when is_integer(size) do
    cond do
      size < 0 ->
        error(:evidence_bounds_amount_invalid, %{resource: :max_journal_bytes, requested: size})

      bounds.consumed_journal_bytes + size > bounds.max_journal_bytes ->
        error(:evidence_fan_out_exceeded, %{
          resource: :max_journal_bytes,
          ceiling: bounds.max_journal_bytes,
          consumed: bounds.consumed_journal_bytes,
          requested: size
        })

      true ->
        {:ok, %{bounds | consumed_journal_bytes: bounds.consumed_journal_bytes + size}}
    end
  end

  @doc """
  Admits one telemetry event name into the distinct `:watch_events`
  vocabulary. Idempotent for an event already admitted (re-observing a known
  event name never itself costs vocabulary budget); a genuinely new event
  name past `max_watch_events` is refused.

      iex> {:ok, bounds} =
      ...>   AshA2A.Chicago.Observer.EvidenceBounds.new(
      ...>     max_records: 10, max_watch_events: 1, max_journal_bytes: 1_000
      ...>   )
      iex> {:ok, admitted} = AshA2A.Chicago.Observer.EvidenceBounds.admit_watch_event(bounds, "a")
      iex> AshA2A.Chicago.Observer.EvidenceBounds.admit_watch_event(admitted, "a")
      {:ok, admitted}
      iex> AshA2A.Chicago.Observer.EvidenceBounds.admit_watch_event(admitted, "b")
      {:error, %{code: :evidence_fan_out_exceeded, detail: %{resource: :max_watch_events, ceiling: 1, consumed: 1}}}
  """
  @spec admit_watch_event(t(), String.t()) :: {:ok, t()} | {:error, refusal()}
  def admit_watch_event(%__MODULE__{} = bounds, event) when is_binary(event) do
    cond do
      MapSet.member?(bounds.watch_events_seen, event) ->
        {:ok, bounds}

      MapSet.size(bounds.watch_events_seen) >= bounds.max_watch_events ->
        error(:evidence_fan_out_exceeded, %{
          resource: :max_watch_events,
          ceiling: bounds.max_watch_events,
          consumed: MapSet.size(bounds.watch_events_seen)
        })

      true ->
        {:ok, %{bounds | watch_events_seen: MapSet.put(bounds.watch_events_seen, event)}}
    end
  end

  @doc "Snapshot of consumption against ceilings, for stats/telemetry."
  @spec snapshot(t()) :: %{
          records: %{consumed: non_neg_integer(), limit: pos_integer()},
          watch_events: %{consumed: non_neg_integer(), limit: non_neg_integer()},
          journal_bytes: %{consumed: non_neg_integer(), limit: pos_integer()}
        }
  def snapshot(%__MODULE__{} = bounds) do
    %{
      records: %{consumed: bounds.consumed_records, limit: bounds.max_records},
      watch_events: %{
        consumed: MapSet.size(bounds.watch_events_seen),
        limit: bounds.max_watch_events
      },
      journal_bytes: %{consumed: bounds.consumed_journal_bytes, limit: bounds.max_journal_bytes}
    }
  end

  # -- internals -------------------------------------------------------

  defp fetch_ceiling(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, value} -> error(:evidence_bounds_ceiling_invalid, %{key => value})
      :error -> error(:evidence_bounds_ceiling_missing, key)
    end
  end

  defp error(code), do: {:error, %{code: code}}
  defp error(code, detail), do: {:error, %{code: code, detail: detail}}

  @doc false
  def ceilings, do: @ceilings
end
