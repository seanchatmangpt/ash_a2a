defmodule AshA2A.Chicago.Ocel.FreshReader do
  @moduledoc """
  Fresh-process OCEL read (RFC-SA2A-002 §139, §42).

  Proves the OCEL evidence is an artifact rather than a live dashboard: a
  separate operating-system process (`elixir -e`, sharing no BEAM, no code
  path of this project, and no memory with the producer or the observer)
  reads the file, hashes its bytes (before, and independently of, decoding),
  decodes it with Elixir's built-in `JSON` module, and reports digest and
  counts. `verify/2` compares that report with
  the digest and counts the producer claimed.

  Emits `[:ash_a2a, :chicago, :ocel, :fresh_read]` with outcome
  `:reproduced | :diverged | :failed`.
  """

  # Evaluated by a fresh `elixir` OS process. Uses only :crypto, File and the
  # built-in JSON module; prints one JSON line.
  @script ~S"""
  [path] = System.argv()
  bytes = File.read!(path)
  sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  {doc, decoded} =
    case JSON.decode(bytes) do
      {:ok, %{} = doc} -> {doc, true}
      _ -> {%{}, false}
    end

  events = Map.get(doc, "events", [])
  objects = Map.get(doc, "objects", [])

  seqs =
    Enum.map(events, fn e ->
      e |> Map.get("attributes", []) |> Enum.find_value(fn a -> a["name"] == "chicago_seq" && a["value"] end)
    end)

  ordered = seqs |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> is_integer(a) and is_integer(b) and a < b end)

  IO.puts(
    JSON.encode!(%{
      "os_pid" => System.pid(),
      "sha256" => sha,
      "decoded" => decoded,
      "bytes" => byte_size(bytes),
      "events" => length(events),
      "objects" => length(objects),
      "event_types" => events |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort(),
      "object_types" => objects |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort(),
      "ordered_by_chicago_seq" => ordered
    })
  )
  """

  @type report :: %{String.t() => term()}

  @doc "Reads `path` in a fresh OS process. Returns the child's report."
  @spec read(Path.t()) :: {:ok, report()} | {:error, term()}
  def read(path) do
    case System.find_executable("elixir") do
      nil ->
        {:error, :elixir_executable_not_found}

      elixir ->
        case System.cmd(elixir, ["-e", @script, Path.expand(path)],
               stderr_to_stdout: true,
               env: [{"MIX_ENV", nil}, {"ERL_LIBS", nil}]
             ) do
          {out, 0} -> decode_report(out)
          {out, status} -> {:error, {:fresh_process_exit, status, String.slice(out, 0, 2000)}}
        end
    end
  rescue
    exception -> {:error, {:fresh_process_raised, Exception.message(exception)}}
  end

  @doc """
  Reads `path` in a fresh process and compares with `claimed`
  (`%{sha256: _, events: _, objects: _}`, e.g. an observer flush result).
  """
  @spec verify(Path.t(), map()) ::
          {:reproduced | :diverged | :failed, report() | term()}
  def verify(path, claimed) do
    {outcome, detail, meta} =
      case read(path) do
        {:ok, report} ->
          digest_match = report["sha256"] == claimed.sha256
          events_match = report["decoded"] == true and report["events"] == claimed.events
          objects_match = report["decoded"] == true and report["objects"] == claimed.objects

          outcome =
            if digest_match and events_match and objects_match,
              do: :reproduced,
              else: :diverged

          {outcome, report,
           %{
             os_pid: report["os_pid"],
             os_exit: 0,
             digest_match: digest_match,
             events_match: events_match,
             objects_match: objects_match,
             ordered: report["ordered_by_chicago_seq"],
             sha256: report["sha256"]
           }}

        {:error, reason} ->
          {:failed, reason, %{os_exit: exit_status(reason)}}
      end

    :telemetry.execute(
      [:ash_a2a, :chicago, :ocel, :fresh_read],
      %{system_time: System.system_time()},
      Map.put(meta, :outcome, outcome)
    )

    {outcome, detail}
  end

  defp decode_report(out) do
    out
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil -> {:error, {:fresh_process_no_output, out}}
      line -> JSON.decode(line)
    end
  end

  defp exit_status({:fresh_process_exit, status, _}), do: status
  defp exit_status(_), do: -1
end
