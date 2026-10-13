defmodule Mix.Tasks.AshA2a.StandingReceipt.Revision do
  @shortdoc "Append a receipt-revision event to the standing-receipt hash chain"

  @moduledoc """
  Appends a `receipt-revision` event to the standing-receipt chain file
  (JSONL, next to the doc) and prints the new chain head (lane L108).

  Each line:

      {"event_type":"receipt-revision","event_id":"<sha256(doc) hex>",
       "commitment":"<prior chain head hex>","ts":"<iso8601>"}

  If no chain file exists, the genesis commitment is the minted payload sha
  from `STANDING-RECEIPT.attestation.json` (`payload_sha256`). Otherwise the
  prior head is recomputed by folding the existing chain.

  ## Usage

      mix ash_a2a.standing_receipt.revision \\
        --in docs/sjira/v26.10.8/STANDING-RECEIPT.md

  ## Options

    * `--in` -- the standing-receipt document (default: the v26.10.8 path)
    * `--chain` -- explicit chain file path (default: `--in` with extension
      replaced by `.chain.jsonl`)

  ## Exit status

  `0` appended (prints `CHAIN_HEAD:<hex>`); `1` REFUSED (unreadable doc or
  broken prior chain -- never appends onto a broken chain).
  """

  use Mix.Task

  alias AshA2a.StandingReceipt.Chain

  @switches [in: :string, chain: :string]
  @default_receipt "docs/sjira/v26.10.8/STANDING-RECEIPT.md"

  @impl true
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches)

    in_path =
      opts[:in] ||
        Path.expand(@default_receipt, Path.join(__DIR__, "../../.."))

    chain_file = opts[:chain] || Chain.chain_path(in_path)

    with {:ok, doc} <- read_doc(in_path),
         {:ok, prior_head} <- prior_head(chain_file) do
      event_id = Chain.sha256_hex(doc)
      new_head = Chain.digest(prior_head, event_id)
      line = event_line(event_id, prior_head)

      case File.open(chain_file, [:append, :utf8], fn io -> IO.puts(io, line) end) do
        {:ok, _} ->
          Mix.shell().info("APPENDED event_id=#{event_id} commitment=#{prior_head}")
          Mix.shell().info("CHAIN_HEAD:#{new_head}")
          :ok

        {:error, reason} ->
          Mix.shell().error("REFUSED: chain append failed (#{inspect(reason)}): #{chain_file}")
          exit({:shutdown, 1})
      end
    else
      {:refused, msg} ->
        Mix.shell().error("REFUSED: #{msg}")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("REFUSED: read failed (#{inspect(reason)}): #{in_path}")
        exit({:shutdown, 1})
    end
  end

  defp read_doc(path) do
    case File.read(path) do
      {:ok, doc} -> {:ok, doc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prior_head(chain_file) do
    if File.exists?(chain_file) do
      case File.read(chain_file) do
        {:ok, body} ->
          lines = String.split(body, "\n", trim: true)

          case Chain.fold(lines) do
            {:ok, head} -> {:ok, head}
            {:refused, msg} -> {:refused, "prior chain broken: #{msg}"}
          end

        {:error, reason} ->
          {:refused, "chain read failed: #{inspect(reason)}"}
      end
    else
      {:ok, Chain.genesis()}
    end
  end

  defp event_line(event_id, commitment) do
    Jason.encode!(%{
      "event_type" => "receipt-revision",
      "event_id" => event_id,
      "commitment" => commitment,
      "ts" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end
end
