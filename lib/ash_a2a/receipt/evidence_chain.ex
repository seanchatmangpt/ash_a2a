defmodule AshA2A.Receipt.EvidenceChain do
  @moduledoc """
  Durable, hash-linked receipt evidence chain for offline replay
  (RFC-SA2A-001 S32; RFC-SA2A-002 §41 Gate 10, §92 B8).

  A chain is an ordered sequence of links, each one real durable evidence of
  one BRCE transition, written to a directory:

      <dir>/chain.json                      manifest (canonical JSON)
      <dir>/links/000001-prepared.etf       the :pending anchor exactly as journaled
      <dir>/links/000002-final.etf          the finalized receipt as committed
      <dir>/links/000003-post_state.json    an independent post-state observation

  Link kinds:

    * `prepared` -- the bytes `AshA2A.ReceiptOutbox` journaled before DO
      (`{1, %AshA2A.Receipt{status: :pending}}`), copied verbatim.
    * `final` -- the receipt the primary `AshA2A.ReceiptStore` holds after the
      outcome was observed, encoded in the same journal format.
    * `post_state` -- a JSON observation of the external domain made by a
      reader that is not the actuator (`"command_id"`, `"receipt_id"`,
      `"actuation_id"`, `"reader"`, `"rows"`, ...).

  Every link records the SHA-256 of its file, the digest of the previous link
  (`prev`, starting at `genesis/0`) and its own digest over
  `[seq, kind, command_id, file, sha256, bytes, prev]` (`link_digest/2`). The
  manifest carries two roots:

    * `link_root` -- the digest of the last link (byte-level chain identity);
    * `basis_root` -- the SHA-256 of the canonical reconstruction
      `AshA2A.Receipt.OfflineReplay.reconstruct/1` derives from the link files
      as written (semantic chain identity).

  `write/2` computes `basis_root` by reading the link files back from disk, so
  the seal is derived from durable bytes, never from producer memory, and
  emits `[:ash_a2a, :replay, :chain_sealed]` -- the producer-side anchor an
  independent observer records before any replay runs.

  This module only records evidence. It never actuates, and it does not judge
  the chain: `AshA2A.Receipt.OfflineReplay` does.
  """

  alias AshA2A.{Identity, Receipt}
  alias AshA2A.Receipt.OfflineReplay

  @schema "ash_a2a.replay_chain/1"
  @manifest "chain.json"
  @genesis String.duplicate("0", 64)
  @sealed_event [:ash_a2a, :replay, :chain_sealed]
  @journal_version 1
  @kinds ["prepared", "final", "post_state"]

  defstruct chain_id: nil, entries: []

  @type t :: %__MODULE__{chain_id: String.t(), entries: [map()]}

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec manifest_file() :: String.t()
  def manifest_file, do: @manifest

  @spec genesis() :: String.t()
  def genesis, do: @genesis

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The producer-side seal event: `[:ash_a2a, :replay, :chain_sealed]`."
  @spec sealed_event() :: [atom()]
  def sealed_event, do: @sealed_event

  @spec new(String.t()) :: t()
  def new(chain_id) when is_binary(chain_id) and chain_id != "",
    do: %__MODULE__{chain_id: chain_id}

  @doc """
  Appends the journaled prepared anchor, byte for byte. The bytes must decode
  to a `:pending` receipt; anything else is refused rather than recorded as a
  prepared anchor.
  """
  @spec append_prepared(t(), binary()) :: {:ok, t()} | {:error, term()}
  def append_prepared(%__MODULE__{} = chain, bytes) when is_binary(bytes) do
    case decode_receipt(bytes) do
      {:ok, %Receipt{status: :pending} = receipt} ->
        {:ok, push(chain, "prepared", receipt.command_id, "etf", bytes)}

      {:ok, %Receipt{status: status}} ->
        {:error, {:not_a_prepared_anchor, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Appends a finalized receipt read from the primary store."
  @spec append_final(t(), Receipt.t()) :: t()
  def append_final(%__MODULE__{} = chain, %Receipt{} = receipt),
    do: push(chain, "final", receipt.command_id, "etf", encode_receipt(receipt))

  @doc "Appends an independent post-state observation (JSON-safe map with `\"command_id\"`)."
  @spec append_post_state(t(), map()) :: t()
  def append_post_state(%__MODULE__{} = chain, %{"command_id" => command_id} = observation)
      when is_binary(command_id),
      do: push(chain, "post_state", command_id, "json", canonical_json(observation))

  defp push(chain, kind, command_id, ext, bytes) do
    command_id =
      case command_id do
        %Identity{value: value} -> value
        value -> value
      end

    %{
      chain
      | entries: [%{kind: kind, command_id: command_id, ext: ext, bytes: bytes} | chain.entries]
    }
  end

  @doc "Encodes a receipt in the `AshA2A.ReceiptOutbox` journal format."
  @spec encode_receipt(Receipt.t()) :: binary()
  def encode_receipt(%Receipt{} = receipt),
    do: :erlang.term_to_binary({@journal_version, receipt})

  @doc "Decodes journal-format bytes into a receipt. Never raises."
  @spec decode_receipt(binary()) :: {:ok, Receipt.t()} | {:error, term()}
  def decode_receipt(bytes) when is_binary(bytes) do
    case :erlang.binary_to_term(bytes) do
      {@journal_version, %Receipt{} = receipt} -> {:ok, receipt}
      _ -> {:error, :foreign_format}
    end
  rescue
    _ -> {:error, :bad_term}
  end

  @doc """
  Writes the chain to `dir` and seals it. Returns the seal:
  `%{"chain_id", "chain_ref", "dir", "length", "commands", "evidence_bytes",
  "link_root", "basis_root", "reconstruction_failures"}`.
  """
  @spec write(t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def write(%__MODULE__{} = chain, dir) do
    dir = Path.expand(dir)
    File.mkdir_p!(Path.join(dir, "links"))

    links =
      chain.entries
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, seq} ->
        file =
          Path.join(
            "links",
            String.pad_leading(Integer.to_string(seq), 6, "0") <> "-#{entry.kind}.#{entry.ext}"
          )

        File.write!(Path.join(dir, file), entry.bytes, [:binary, :sync])

        %{
          "seq" => seq,
          "kind" => entry.kind,
          "command_id" => entry.command_id,
          "file" => file,
          "sha256" => sha256(entry.bytes),
          "bytes" => byte_size(entry.bytes)
        }
      end)

    manifest =
      relink(%{
        "schema" => @schema,
        "chain_id" => chain.chain_id,
        "genesis" => @genesis,
        "links" => links
      })

    reconstruction = OfflineReplay.reconstruct_dir(dir, manifest)
    manifest = Map.put(manifest, "basis_root", reconstruction.basis_root)
    File.write!(Path.join(dir, @manifest), canonical_json(manifest), [:binary, :sync])

    seal = %{
      "chain_id" => chain.chain_id,
      "chain_ref" => chain_ref(dir),
      "dir" => dir,
      "length" => length(links),
      "commands" => length(reconstruction.records),
      "evidence_bytes" => evidence_bytes(dir, manifest),
      "link_root" => manifest["link_root"],
      "basis_root" => manifest["basis_root"],
      "reconstruction_failures" => Enum.map(reconstruction.failures, & &1["reason"])
    }

    :telemetry.execute(@sealed_event, %{system_time: System.system_time()}, %{
      chain_id: seal["chain_id"],
      chain_ref: seal["chain_ref"],
      length: seal["length"],
      commands: seal["commands"],
      evidence_bytes: seal["evidence_bytes"],
      link_root: seal["link_root"],
      basis_root: seal["basis_root"]
    })

    {:ok, seal}
  rescue
    exception -> {:error, {:chain_write_failed, Exception.message(exception)}}
  end

  @doc """
  Recomputes `seq`, `prev`, `digest` for every link (in list order) and the
  manifest's `link_root`, from each link's recorded file digest. Pure.
  """
  @spec relink(map()) :: map()
  def relink(%{"links" => links} = manifest) do
    {links, root} =
      links
      |> Enum.with_index(1)
      |> Enum.map_reduce(@genesis, fn {link, seq}, prev ->
        link = link |> Map.put("seq", seq) |> Map.put("prev", prev)
        digest = link_digest(link, prev)
        {Map.put(link, "digest", digest), digest}
      end)

    manifest
    |> Map.put("links", links)
    |> Map.put("length", length(links))
    |> Map.put("link_root", root)
  end

  @doc "Digest of one link bound to the previous link's digest."
  @spec link_digest(map(), String.t()) :: String.t()
  def link_digest(link, prev) do
    [
      link["seq"],
      link["kind"],
      link["command_id"],
      link["file"],
      link["sha256"],
      link["bytes"],
      prev
    ]
    |> canonical_json()
    |> sha256()
  end

  @doc "Total bytes of the manifest plus every link file currently on disk."
  @spec evidence_bytes(Path.t(), map() | nil) :: non_neg_integer()
  def evidence_bytes(dir, manifest \\ nil) do
    files =
      case manifest do
        %{"links" => links} -> Enum.map(links, &Path.join(dir, &1["file"]))
        _ -> Path.wildcard(Path.join([dir, "links", "*"]))
      end

    Enum.reduce([Path.join(dir, @manifest) | files], 0, fn path, acc ->
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} -> acc + size
        _ -> acc
      end
    end)
  end

  @doc "Stable, location-derived reference for a chain directory."
  @spec chain_ref(Path.t()) :: String.t()
  def chain_ref(dir), do: "chain-" <> String.slice(sha256(Path.expand(dir)), 0, 16)

  @doc "SHA-256, lowercase hex."
  @spec sha256(iodata()) :: String.t()
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  Canonical JSON: identity structs to their value, atoms to strings, other
  structs to maps, tuples to lists, object keys sorted recursively.
  """
  @spec canonical_json(term()) :: binary()
  def canonical_json(term), do: term |> json_safe() |> encode_sorted() |> IO.iodata_to_binary()

  @doc "Lowers a term to JSON-encodable data (see `canonical_json/1`)."
  @spec json_safe(term()) :: term()
  def json_safe(term) when is_binary(term) do
    if String.valid?(term), do: term, else: "base16:" <> Base.encode16(term, case: :lower)
  end

  def json_safe(term) when is_number(term) or is_boolean(term) or is_nil(term), do: term
  def json_safe(term) when is_atom(term), do: Atom.to_string(term)
  def json_safe(%Identity{value: value}), do: json_safe(value)
  def json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  def json_safe(%{__struct__: module} = struct) do
    struct |> Map.from_struct() |> Map.put("__struct__", inspect(module)) |> json_safe()
  end

  def json_safe(term) when is_map(term),
    do: Map.new(term, fn {k, v} -> {json_key(k), json_safe(v)} end)

  def json_safe(term) when is_list(term), do: Enum.map(term, &json_safe/1)
  def json_safe(term) when is_tuple(term), do: term |> Tuple.to_list() |> json_safe()
  def json_safe(term), do: inspect(term)

  defp json_key(k) when is_binary(k), do: k
  defp json_key(k) when is_atom(k), do: Atom.to_string(k)
  defp json_key(k), do: inspect(k)

  defp encode_sorted(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> [JSON.encode!(k), ?:, encode_sorted(v)] end)
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  defp encode_sorted(list) when is_list(list),
    do: [?[, list |> Enum.map(&encode_sorted/1) |> Enum.intersperse(?,), ?]]

  defp encode_sorted(other), do: JSON.encode!(other)
end
