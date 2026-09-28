defmodule SwarmNode.JsonLogFormatter do
  @moduledoc """
  Minimal structured (one JSON object per line) `:logger` formatter for the
  prod release (DEP-12), built on Elixir's own `JSON` module so the release
  needs no extra dependency. Configured in `config/runtime.exs`:

      config :logger, :default_handler,
        formatter: {SwarmNode.JsonLogFormatter, %{metadata: [:request_id]}}

  Emits `time` (RFC 3339, UTC), `level`, `msg`, and only the whitelisted
  metadata keys (never the full metadata map, which can carry pids/terms).
  """

  @spec check_config(map()) :: :ok
  def check_config(_config), do: :ok

  @spec format(:logger.log_event(), map()) :: iodata()
  def format(%{level: level, msg: msg, meta: meta}, config) do
    keys = Map.get(config, :metadata, [])

    metadata =
      for key <- keys, Map.has_key?(meta, key), into: %{} do
        {key, printable(Map.fetch!(meta, key))}
      end

    %{
      "time" => time(meta),
      "level" => Atom.to_string(level),
      "msg" => message(msg, meta)
    }
    |> Map.merge(Map.new(metadata, fn {k, v} -> {Atom.to_string(k), v} end))
    |> JSON.encode!()
    |> then(&[&1, ?\n])
  end

  defp time(%{time: micros}),
    do: micros |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  defp time(_meta), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp message({:string, chardata}, _meta), do: IO.chardata_to_string(chardata)

  defp message({:report, report}, meta) do
    case meta do
      %{report_cb: cb} when is_function(cb, 1) ->
        {format, args} = cb.(report)
        format |> :io_lib.format(args) |> IO.chardata_to_string()

      _ ->
        inspect(report)
    end
  end

  defp message({format, args}, _meta),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  defp printable(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp printable(value) when is_atom(value), do: Atom.to_string(value)
  defp printable(value), do: inspect(value)
end
