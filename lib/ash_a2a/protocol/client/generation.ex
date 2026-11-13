defmodule AshA2A.Protocol.Client.Generation do
  @moduledoc """
  Client-side A2A v1.1 generation tracking (spec 3.2.7, ADR-002).

  Folds stream events while remembering the last seen task generation and
  reports, per event:

    * `:ok` - the event continues the sequence (or is a `Task` snapshot, which
      always resynchronises the tracker);
    * `{:gap, expected, got}` - generation `got` arrived where `expected`
      (`last + 1`) was due; the caller should `reconcile/2` (re-fetch the task);
    * `:unsupported` - the server does not implement generation: an event carried
      generation `0`/absent, or two consecutive events repeated one generation.
      Once unsupported the tracker stays unsupported and the client MUST NOT use
      generation any more (every later observation answers `:unsupported`);
    * `:ignore` - the event carries no generation (message-only reply,
      `StreamError`, unknown).

  The pure core (`new/1`, `observe/2`, `fold/2`) does no I/O. `annotate/2` lifts
  it onto a stream and `reconcile/3` re-fetches the task through
  `AshA2A.Protocol.Client.get_task/3`.

  Timeline helpers `timeline/1` and `interleave_artifacts/1` are also pure.
  """

  alias AshA2A.Protocol.{Artifact, TimelineEntry}
  alias AshA2A.Protocol.Event.{ArtifactUpdate, MessageUpdate, StatusUpdate}
  alias AshA2A.Protocol.Task, as: T

  @type t :: %__MODULE__{
          last: non_neg_integer() | nil,
          unsupported: boolean(),
          gap: {pos_integer(), non_neg_integer()} | nil
        }

  defstruct last: nil, unsupported: false, gap: nil

  @type result :: :ok | {:gap, non_neg_integer(), non_neg_integer()} | :unsupported | :ignore

  @doc "New tracker. `:last_seen` seeds the last seen generation (resubscribe)."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: %__MODULE__{last: opts[:last_seen]}

  @doc "Observes one stream element. Returns `{result, new_state}`."
  @spec observe(t(), term()) :: {result(), t()}
  def observe(%__MODULE__{unsupported: true} = state, event) do
    case generation_of(event) do
      :none -> {:ignore, state}
      _ -> {:unsupported, state}
    end
  end

  def observe(%__MODULE__{} = state, %T{generation: gen}) do
    # A snapshot is a resync point: any jump is lawful, a repeat too.
    if gen in [0, nil] do
      {:unsupported, %{state | unsupported: true}}
    else
      {:ok, %{state | last: gen, gap: nil}}
    end
  end

  def observe(%__MODULE__{} = state, event) do
    case generation_of(event) do
      :none -> {:ignore, state}
      {:event, gen} -> observe_event(state, gen)
    end
  end

  defp observe_event(state, gen) when gen in [0, nil],
    do: {:unsupported, %{state | unsupported: true}}

  defp observe_event(%{last: nil} = state, gen), do: {:ok, %{state | last: gen}}

  defp observe_event(%{last: last} = state, gen) when gen == last,
    do: {:unsupported, %{state | unsupported: true}}

  defp observe_event(%{last: last} = state, gen) when gen == last + 1,
    do: {:ok, %{state | last: gen, gap: nil}}

  defp observe_event(%{last: last} = state, gen) do
    expected = last + 1
    {{:gap, expected, gen}, %{state | last: gen, gap: {expected, gen}}}
  end

  defp generation_of(%StatusUpdate{generation: g}), do: {:event, g}
  defp generation_of(%ArtifactUpdate{generation: g}), do: {:event, g}
  defp generation_of(%MessageUpdate{generation: g}), do: {:event, g}
  defp generation_of(%T{generation: g}), do: {:event, g}
  defp generation_of(_), do: :none

  @doc "Folds a list of events: `{[{event, result}], state}`."
  @spec fold(Enumerable.t(), t()) :: {[{term(), result()}], t()}
  def fold(events, state \\ new()) do
    {rev, state} =
      Enum.reduce(events, {[], state}, fn event, {acc, st} ->
        {result, st} = observe(st, event)
        {[{event, result} | acc], st}
      end)

    {Enum.reverse(rev), state}
  end

  @doc """
  Wraps a stream so each element becomes `{:event, ev}`, preceded by
  `{:gap, expected, got}` on a gap and by `{:generation, :unsupported}` once when
  the server is detected not to implement generation. Options: `:last_seen`.
  """
  @spec annotate(Enumerable.t(), keyword()) :: Enumerable.t()
  def annotate(stream, opts \\ []) do
    Stream.transform(
      stream,
      fn -> new(opts) end,
      fn event, state ->
        was_unsupported = state.unsupported
        {result, state} = observe(state, event)

        annotations =
          case result do
            {:gap, expected, got} -> [{:gap, expected, got}]
            :unsupported when not was_unsupported -> [{:generation, :unsupported}]
            _ -> []
          end

        {annotations ++ [{:event, event}], state}
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Re-fetches the task through `get_task/3` after a gap and resynchronises the
  tracker to the fetched generation. `{client, task_id}` names the task.
  Returns `{:ok, task, new_state}` or the `get_task/3` error.
  """
  @spec reconcile(t(), {AshA2A.Protocol.Client.target(), String.t()}, keyword()) ::
          {:ok, T.t(), t()} | {:error, term()}
  def reconcile(%__MODULE__{} = state, {client, task_id}, opts \\ []) do
    case AshA2A.Protocol.Client.get_task(client, task_id, opts) do
      {:ok, %T{} = task} ->
        {_result, state} = observe(%{state | gap: nil}, task)
        {:ok, task, state}

      {:error, _} = error ->
        error
    end
  end

  @doc "Timeline entries sorted by generation (stable), `{:unknown, _}` skipped."
  @spec timeline(T.t()) :: [TimelineEntry.t()]
  def timeline(%T{timeline: timeline}) do
    (timeline || [])
    |> Enum.reject(fn
      %TimelineEntry{entry: {:unknown, _}} -> true
      _ -> false
    end)
    |> Enum.sort_by(& &1.generation)
  end

  @doc """
  Timeline entries and artifacts in one generation-ordered list.

  An artifact is placed at its `start_generation` (falling back to
  `end_generation`; an artifact with neither goes last). At equal generation the
  timeline entry precedes the artifact it produced.
  """
  @spec interleave_artifacts(T.t()) :: [{:entry, TimelineEntry.t()} | {:artifact, Artifact.t()}]
  def interleave_artifacts(%T{artifacts: artifacts} = task) do
    entries = for e <- timeline(task), do: {{e.generation, 0}, {:entry, e}}

    arts =
      for a <- artifacts || [] do
        gen = a.start_generation || a.end_generation || :infinity
        {{gen, 1}, {:artifact, a}}
      end

    (entries ++ arts)
    |> Enum.sort_by(fn {{gen, rank}, _} ->
      {gen == :infinity, if(gen == :infinity, do: 0, else: gen), rank}
    end)
    |> Enum.map(&elem(&1, 1))
  end
end
