defmodule AshA2a.StandingReceipt.Chain do
  @moduledoc """
  Append-only hash-chain over standing-receipt revisions (lane L108, L33 rank-1).

  Chain file: JSONL next to the standing receipt,
  e.g. `docs/sjira/v26.10.8/STANDING-RECEIPT.chain.jsonl`. One revision event
  per line:

      {"event_type":"receipt-revision","event_id":"<sha256(doc) hex>",
       "commitment":"<prior chain head hex>","ts":"<iso8601>"}

  Genesis commitment is the minted payload sha (`payload_sha256` of the
  `.attestation.json`, currently `e1c0981885fd766625b7276489b2f882585305e345b8e40810779ab7c442289b`).

  Fold: `h_0 = genesis`; line i+1 carries `commitment = h_i` and `event_id`;
  `h_{i+1} = sha256(commitment_i <> event_id_{i+1})`. The chain head after N
  lines is `h_N`; its line's `event_id` must equal the live document's sha256.
  An edited document with a fresh valid Ed25519 signature therefore refuses:
  its sha no longer matches the head `event_id`, and the head can only be moved
  by appending a revision through `mix ash_a2a.standing_receipt.revision`.
  """

  @genesis_payload_sha "e1c0981885fd766625b7276489b2f882585305e345b8e40810779ab7c442289b"

  @type event :: %{
          required(String.t()) => term
        }

  @spec genesis :: String.t()
  def genesis, do: @genesis_payload_sha

  @doc "Chain file path for a receipt document path."
  @spec chain_path(String.t()) :: String.t()
  def chain_path(doc_path) do
    base = String.replace_suffix(doc_path, Path.extname(doc_path), "")
    base <> ".chain.jsonl"
  end

  @doc """
  Fold over events (binary JSONL lines or already-decoded maps).
  `{:ok, head}` where head is the final chain hash, or `{:refused, reason}` on
  linkage/format failure.
  """
  @spec fold(Enumerable.t(), String.t()) :: {:ok, String.t()} | {:refused, String.t()}
  def fold(events, genesis \\ genesis()) when is_binary(genesis) do
    events
    |> Enum.reduce_while({:ok, genesis}, fn line, {:ok, head} ->
      case step(line, head) do
        {:ok, new_head, _event} -> {:cont, {:ok, new_head}}
        {:refused, _} = refused -> {:halt, refused}
      end
    end)
  end

  defp step(line, prior_head) do
    with {:ok, event} <- decode_line(line),
         :ok <- check_type(event),
         :ok <- check_fields(event, prior_head) do
      new_head = digest(prior_head, event["event_id"])
      {:ok, new_head, event}
    end
  end

  defp decode_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{} = m} -> {:ok, m}
      {:ok, other} -> {:refused, "chain line not a JSON object: #{inspect(other)}"}
      {:error, e} -> {:refused, "chain line not valid JSON: #{Exception.message(e)}"}
    end
  end

  defp decode_line(%{} = m), do: {:ok, m}

  defp check_type(%{"event_type" => "receipt-revision"}), do: :ok

  defp check_type(%{"event_type" => other}),
    do: {:refused, "unknown event_type #{inspect(other)}"}

  defp check_type(_), do: {:refused, "chain line missing event_type"}

  defp check_fields(%{"commitment" => c, "event_id" => eid}, prior_head) do
    cond do
      not is_binary(c) or not is_binary(eid) ->
        {:refused, "commitment/event_id not strings"}

      c != prior_head ->
        {:refused, "commitment #{c} does not match prior chain head #{prior_head}"}

      true ->
        :ok
    end
  end

  defp check_fields(_, _), do: {:refused, "chain line missing commitment/event_id"}

  @doc "Fold digest step: sha256 hex of the concatenation of prior head and event_id."
  @spec digest(String.t(), String.t()) :: String.t()
  def digest(prior_head, event_id) when is_binary(prior_head) and is_binary(event_id) do
    Base.encode16(:crypto.hash(:sha256, prior_head <> event_id), case: :lower)
  end

  @doc "sha256 hex of a binary (the doc payload or an event_id)."
  @spec sha256_hex(binary) :: String.t()
  def sha256_hex(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  @doc """
  Full chain court over the live doc: fold the chain file (if present), then
  require the head event's `event_id` to equal the live doc's sha256.

  Returns `:ok`, `{:refused, reason}`, or `{:absent, chain_path}` when no chain
  file exists (back-compat: caller keeps prior two-stage behavior).
  """
  @spec verify(String.t()) :: :ok | {:refused, String.t()} | {:absent, String.t()}
  def verify(doc_path) do
    path = chain_path(doc_path)

    with {:present, ^path} <- chain_present(path),
         {:ok, body} <- read_chain(path),
         lines <- split_lines(body),
         {:ok, _head} <- fold(lines),
         {:ok, head_event} <- last_event(lines) do
      check_head(head_event, doc_path)
    end
  end

  defp chain_present(path), do: if(File.exists?(path), do: {:present, path}, else: {:absent, path})

  defp read_chain(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:refused, "chain file read failed: #{inspect(reason)}"}
    end
  end

  defp split_lines(body), do: String.split(body, "\n", trim: true)

  defp last_event(lines) do
    case List.last(lines) do
      nil ->
        {:refused, "chain file is empty"}

      last_line ->
        case Jason.decode(last_line) do
          {:ok, %{"event_id" => _} = m} -> {:ok, m}
          {:ok, _} -> {:refused, "last chain line missing event_id"}
          {:error, e} -> {:refused, "last chain line invalid JSON: #{Exception.message(e)}"}
        end
    end
  end

  defp check_head(head_event, doc_path) do
    head_event_id = head_event["event_id"]
    doc_sha = sha256_hex(File.read!(doc_path))

    if head_event_id == doc_sha do
      :ok
    else
      {:refused,
       "chain head event_id #{head_event_id} != live doc sha #{doc_sha} " <>
         "(edited doc with a fresh valid signature must re-mint through " <>
         "mix ash_a2a.standing_receipt.revision)"}
    end
  end
end
