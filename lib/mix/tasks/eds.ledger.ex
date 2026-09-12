defmodule Mix.Tasks.Eds.Ledger do
  @moduledoc """
  Print this repo's real ERC (Executable Research Claim) ledger --
  one row per distinct claim id, its current evidence state, and what
  it depends on. Reads real receipt files under `research/erc/`; prints
  nothing fabricated. An empty ledger (no receipts emitted yet) prints
  a real, honest "no receipts" line rather than an empty table.

      mix eds.ledger
  """
  @shortdoc "Print the real ERC ledger for this repo"
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    case AshA2A.Research.ERC.ledger() do
      [] ->
        Mix.shell().info("No ERC receipts found under research/erc/.")

      entries ->
        Mix.shell().info(format_table(entries))
    end
  end

  defp format_table(entries) do
    header = ["ID", "STATE", "DEPENDS_ON", "CLAIM"]

    rows =
      Enum.map(entries, fn e ->
        [
          e["id"],
          e["state"],
          Enum.join(e["depends_on"] || [], ","),
          truncate(e["claim"], 70)
        ]
      end)

    widths =
      [header | rows]
      |> Enum.zip_with(& &1)
      |> Enum.map(fn col -> col |> Enum.map(&String.length/1) |> Enum.max() end)

    ([header] ++ rows)
    |> Enum.map(fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map(fn {cell, w} -> String.pad_trailing(cell, w) end)
      |> Enum.join("  ")
    end)
    |> Enum.join("\n")
  end

  defp truncate(str, max) when byte_size(str) > max, do: String.slice(str, 0, max - 1) <> "…"
  defp truncate(str, _max), do: str
end
