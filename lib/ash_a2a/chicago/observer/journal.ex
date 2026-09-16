defmodule AshA2A.Chicago.Observer.Journal do
  @moduledoc """
  Append-only, line-hashed JSONL journal behind `AshA2A.Chicago.Observer`
  (RFC-SA2A-002 §19 evidence durability, §138 restart recovery).

  The observer appends every record it accepts the moment it accepts it, so
  process evidence survives an observer crash and a recovery incarnation can
  rebuild what was observed -- and mark, never paper over, what was not.

  ## Line format

  One canonical JSON object per line (`AshA2A.Chicago.Json.canonical/1`:
  recursively sorted keys) carrying `"kind"` and `"h"`, where `"h"` is the
  lowercase sha256 of the canonical JSON of the same object without `"h"`.

    * `"header"` -- one per observer incarnation (`run_id`, `incarnation`,
      `mapping_digest`, `schema`)
    * `"record"` -- one accepted observer record (`seq`, `event`, `activity`,
      `time_us`, `attributes`, `objects`, `falsifier_id`, `court_id`, `run_id`)
    * `"drops"` -- an incarnation's delivery-drop counter total when it changed
    * `"flush"` -- an artifact flush (`sha256`, `events`)
    * `"close"` -- clean incarnation shutdown

  `recover/1` never restores a line that is not valid JSON, lacks `"h"`, has a
  mismatching hash or an invalid record shape (counted in `corrupt_lines`); a
  final segment without a terminating newline is a torn write (`torn_tail`,
  also counted corrupt); a record whose `seq` was already restored is a
  duplicated delivery (`duplicate_lines`) and is not restored twice.

  ## fsync policy

  Lines are written through a raw, unbuffered file descriptor: once
  `append/2` returns, the bytes are in the operating system's page cache,
  which survives termination of the observer process, the producer process
  and the BEAM itself. `fsync(2)` additionally protects against an OS crash or
  power loss and is applied according to the policy:

    * `:every_record` -- after every line;
    * `{:every, n}` (default `{:every, 32}`) -- after every `n` lines, and
      unconditionally at every durability point the observer names via
      `sync/1`: stimulus stop, recovery gap, artifact flush, clean close.

  Under `{:every, n}` an OS crash (not a process crash) can lose at most the
  lines written since the last sync; the recovery that follows still marks
  the restart as a gap, so lost lines lower evidence standing rather than
  disappearing silently.
  """

  alias AshA2A.Chicago.Json

  @schema "ash_a2a.chicago.observer_journal/1"
  @default_policy {:every, 32}

  defstruct [:path, :io, policy: @default_policy, unsynced: 0]

  @type policy :: :every_record | {:every, pos_integer()}
  @type t :: %__MODULE__{
          path: Path.t(),
          io: term(),
          policy: policy(),
          unsynced: non_neg_integer()
        }

  @type recovery :: %{
          run_ids: [String.t()],
          incarnations: non_neg_integer(),
          records: [map()],
          drops: %{non_neg_integer() => non_neg_integer()},
          corrupt_lines: non_neg_integer(),
          duplicate_lines: non_neg_integer(),
          torn_tail: boolean(),
          lines: non_neg_integer()
        }

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec default_policy() :: policy()
  def default_policy, do: @default_policy

  @doc """
  Opens `path` for appending (creating directories). A torn final line left
  by a crashed writer is terminated first so new lines never fuse with it.
  """
  @spec open(Path.t(), policy()) :: {:ok, t()} | {:error, term()}
  def open(path, policy \\ @default_policy) do
    with :ok <- validate_policy(policy),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- terminate_torn_tail(path),
         {:ok, io} <- :file.open(path, [:append, :binary, :raw]) do
      {:ok, %__MODULE__{path: path, io: io, policy: policy}}
    end
  end

  @doc "Appends one entry (a map with `\"kind\"`), applying the fsync policy."
  @spec append(t(), map()) :: {:ok, t()} | {:error, term()}
  def append(%__MODULE__{} = journal, %{"kind" => _} = entry) do
    case :file.write(journal.io, encode_line(entry)) do
      :ok -> maybe_sync(%{journal | unsynced: journal.unsynced + 1})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "fsyncs the journal now (a named durability point)."
  @spec sync(t()) :: {:ok, t()} | {:error, term()}
  def sync(%__MODULE__{unsynced: 0} = journal), do: {:ok, journal}

  def sync(%__MODULE__{} = journal) do
    case :file.sync(journal.io) do
      :ok -> {:ok, %{journal | unsynced: 0}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{} = journal) do
    _ = sync(journal)
    _ = :file.close(journal.io)
    :ok
  end

  @doc "The exact bytes of one journal line (with trailing newline)."
  @spec encode_line(map()) :: iodata()
  def encode_line(entry) do
    body = entry |> Json.safe() |> Map.delete("h")
    [Json.canonical(Map.put(body, "h", digest(body))), ?\n]
  end

  @doc "Decodes and hash-verifies one line (without newline)."
  @spec decode_line(binary()) :: {:ok, map()} | {:error, :corrupt}
  def decode_line(line) do
    with {:ok, %{"h" => h, "kind" => kind} = doc} when is_binary(h) and is_binary(kind) <-
           JSON.decode(line),
         body = Map.delete(doc, "h"),
         true <- digest(body) == h do
      {:ok, body}
    else
      _ -> {:error, :corrupt}
    end
  end

  @doc """
  Reads a journal and returns everything a recovery incarnation needs. Never
  raises on corrupt content; a missing file is `{:error, :enoent}`.
  """
  @spec recover(Path.t()) :: {:ok, recovery()} | {:error, term()}
  def recover(path) do
    with {:ok, bytes} <- File.read(path) do
      # Everything after the last newline is a torn (partially written) line.
      {complete, tail} = bytes |> String.split("\n") |> Enum.split(-1)
      torn? = tail != [""]

      initial = %{
        run_ids: [],
        incarnations: 0,
        records: [],
        seqs: MapSet.new(),
        drops: %{},
        corrupt_lines: if(torn?, do: 1, else: 0),
        duplicate_lines: 0,
        torn_tail: torn?,
        lines: 0
      }

      acc =
        complete
        |> Enum.reject(&(&1 == ""))
        |> Enum.reduce(initial, &recover_line/2)

      {:ok,
       acc
       |> Map.delete(:seqs)
       |> Map.update!(:records, &Enum.reverse/1)
       |> Map.update!(:run_ids, &Enum.uniq/1)}
    end
  end

  defp recover_line(line, acc) do
    acc = %{acc | lines: acc.lines + 1}

    case decode_line(line) do
      {:ok, %{"kind" => "header", "run_id" => run_id, "incarnation" => inc}}
      when is_binary(run_id) and is_integer(inc) ->
        %{acc | run_ids: [run_id | acc.run_ids], incarnations: max(acc.incarnations, inc)}

      {:ok, %{"kind" => "record"} = entry} ->
        case to_record(entry) do
          {:ok, record} ->
            if MapSet.member?(acc.seqs, record.seq),
              do: %{acc | duplicate_lines: acc.duplicate_lines + 1},
              else: %{
                acc
                | records: [record | acc.records],
                  seqs: MapSet.put(acc.seqs, record.seq)
              }

          :error ->
            %{acc | corrupt_lines: acc.corrupt_lines + 1}
        end

      {:ok, %{"kind" => "drops", "incarnation" => inc, "total" => total}}
      when is_integer(inc) and is_integer(total) ->
        %{acc | drops: Map.update(acc.drops, inc, total, &max(&1, total))}

      {:ok, %{"kind" => kind}} when kind in ["flush", "close", "drops", "header"] ->
        acc

      {:ok, _unknown_kind} ->
        %{acc | corrupt_lines: acc.corrupt_lines + 1}

      {:error, :corrupt} ->
        %{acc | corrupt_lines: acc.corrupt_lines + 1}
    end
  end

  @doc "Journal entry for an observer record."
  @spec record_entry(map()) :: map()
  def record_entry(record) do
    %{
      "kind" => "record",
      "seq" => record.seq,
      "event" => event_segments(record.event),
      "activity" => record.activity,
      "time_us" => record.time_us,
      "attributes" => record.attributes,
      "objects" => Enum.map(record.objects, fn {t, id, q} -> [t, id, q] end),
      "falsifier_id" => Map.get(record, :falsifier_id),
      "court_id" => Map.get(record, :court_id),
      "run_id" => Map.get(record, :run_id)
    }
  end

  @doc "Observer record from a verified journal entry, or `:error` on an invalid shape."
  @spec to_record(map()) :: {:ok, map()} | :error
  def to_record(
        %{
          "seq" => seq,
          "event" => event,
          "activity" => activity,
          "time_us" => time_us,
          "attributes" => attributes,
          "objects" => objects
        } = entry
      )
      when is_integer(seq) and is_list(event) and is_binary(activity) and is_integer(time_us) and
             is_map(attributes) and is_list(objects) do
    if Enum.all?(
         objects,
         &match?([t, id, q] when is_binary(t) and is_binary(id) and is_binary(q), &1)
       ) and
         Enum.all?(event, &is_binary/1) do
      {:ok,
       %{
         seq: seq,
         event: Enum.map(event, &existing_atom/1),
         activity: activity,
         time_us: time_us,
         attributes: attributes,
         objects: Enum.map(objects, &List.to_tuple/1),
         falsifier_id: string_or_nil(entry["falsifier_id"]),
         court_id: string_or_nil(entry["court_id"]),
         run_id: string_or_nil(entry["run_id"])
       }}
    else
      :error
    end
  end

  def to_record(_entry), do: :error

  defp event_segments(event) when is_list(event), do: Enum.map(event, &to_string/1)
  defp event_segments(event) when is_binary(event), do: String.split(event, ".")

  defp existing_atom(segment) do
    String.to_existing_atom(segment)
  rescue
    ArgumentError -> segment
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil

  defp digest(body) do
    body |> Json.canonical() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp maybe_sync(%__MODULE__{policy: :every_record} = journal), do: sync(journal)

  defp maybe_sync(%__MODULE__{policy: {:every, n}, unsynced: unsynced} = journal)
       when unsynced >= n,
       do: sync(journal)

  defp maybe_sync(journal), do: {:ok, journal}

  defp validate_policy(:every_record), do: :ok
  defp validate_policy({:every, n}) when is_integer(n) and n > 0, do: :ok
  defp validate_policy(other), do: {:error, {:invalid_journal_sync_policy, other}}

  defp terminate_torn_tail(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > 0 ->
        with {:ok, io} <- :file.open(path, [:read, :binary, :raw]) do
          last =
            try do
              :file.pread(io, size - 1, 1)
            after
              :file.close(io)
            end

          case last do
            {:ok, "\n"} -> :ok
            {:ok, _} -> File.write(path, "\n", [:append])
            other -> {:error, {:journal_unreadable, other}}
          end
        end

      _ ->
        :ok
    end
  end
end
