defmodule AshA2A.GraphLaw.Manifest do
  @moduledoc """
  The GraphLaw law-package root manifest (RFC-SA2A-001 S21).

  The manifest binds a *content address* to a *provenance record* and to a
  *real executed verification*. It is the thing that makes the vendored
  `.wasm` a law package rather than a hand-copied blob: a consumer who has
  only `priv/graphlaw/` (no Rust toolchain, no praxis checkout) can still
  re-derive both digests and re-run the same acceptance probe.

  Per RFC S27 the manifest is a **projection, not truth**. It records what was
  measured at vendor time and can be re-derived from the artifact at any
  later time; it grants nothing. A matching digest is evidence of byte
  identity, not of authority to act.

  ## Canonical form

  `canonical_json/1` emits a deterministic serialization -- recursively
  key-sorted objects, no insignificant whitespace -- so that
  `content_digest/1` is stable across BEAM versions and map iteration order.
  The digest deliberately excludes the `"content_digest"` key itself, so it
  can be stored inside the document it describes.
  """

  alias AshA2A.GraphLaw

  @schema "ash_a2a.graphlaw.manifest/v1"

  @doc "The manifest schema identifier this module reads and writes."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  Reads and decodes the manifest at `path` (default: the committed one).

  Typed errors: `:manifest_not_found`, `:manifest_non_json`,
  `:manifest_unknown_schema`.
  """
  @spec read(String.t() | nil) :: {:ok, map()} | {:error, map()}
  def read(path \\ nil) do
    path = path || GraphLaw.manifest_path()

    with {:ok, body} <- read_file(path),
         {:ok, decoded} <- decode(body, path) do
      case decoded do
        %{"schema" => @schema} ->
          {:ok, decoded}

        %{"schema" => other} ->
          {:error,
           %{
             code: :manifest_unknown_schema,
             message: "#{path} declares schema #{inspect(other)}, expected #{@schema}"
           }}

        _ ->
          {:error, %{code: :manifest_unknown_schema, message: "#{path} declares no schema"}}
      end
    end
  end

  @doc """
  Writes `manifest` to `path`, stamping a freshly computed `"content_digest"`
  and emitting pretty-printed canonical JSON (sorted keys, two-space indent)
  so the committed file reviews cleanly in a diff.
  """
  @spec write!(map(), String.t()) :: :ok
  def write!(manifest, path) when is_map(manifest) do
    stamped = Map.put(manifest, "content_digest", content_digest(manifest))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, pretty_json(stamped) <> "\n")
    :ok
  end

  @doc """
  Recomputes the real `sha256` and `blake3` of `artifact_path` and compares
  them to what `manifest` claims.

  `blake3` is computed by the real `b3sum` executable when one is available;
  when it is not, blake3 verification is reported as `:skipped` with a reason
  rather than silently passing. `sha256` is always computed in-BEAM via
  `:crypto` and is never skipped.
  """
  @spec verify_digests(map(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def verify_digests(manifest, artifact_path, opts \\ []) do
    case File.read(artifact_path) do
      {:error, reason} ->
        {:error,
         %{
           code: :artifact_not_found,
           message: "cannot read #{artifact_path}: #{:file.format_error(reason)}"
         }}

      {:ok, bytes} ->
        actual_sha = sha256_hex(bytes)
        claimed_sha = get_in(manifest, ["artifact", "sha256"])
        claimed_b3 = get_in(manifest, ["artifact", "blake3"])
        claimed_size = get_in(manifest, ["artifact", "bytes"])

        blake3 = blake3_hex(artifact_path, opts)

        result = %{
          path: artifact_path,
          bytes_actual: byte_size(bytes),
          bytes_claimed: claimed_size,
          sha256_actual: actual_sha,
          sha256_claimed: claimed_sha,
          sha256_match: actual_sha == claimed_sha,
          blake3_claimed: claimed_b3,
          blake3_actual: elem_or_nil(blake3),
          blake3_status: blake3_status(blake3, claimed_b3)
        }

        if result.sha256_match and byte_size(bytes) == claimed_size and
             result.blake3_status != :mismatch do
          {:ok, result}
        else
          {:error, Map.put(result, :code, :digest_mismatch)}
        end
    end
  end

  @doc """
  Computes the real BLAKE3 hex digest of `path` using the `b3sum` executable.

  Returns `{:ok, hex}`, or `{:skipped, reason}` when no `b3sum` is on `PATH`.
  There is no pure-Elixir BLAKE3 implementation in this dependency set, and
  this repository will not hand-roll one -- an absent tool is reported as
  absent, never approximated.
  """
  @spec blake3_hex(String.t(), keyword()) :: {:ok, String.t()} | {:skipped, String.t()}
  def blake3_hex(path, opts \\ []) do
    candidate = Keyword.get(opts, :b3sum) || System.get_env("ASH_A2A_B3SUM") || "b3sum"

    case System.find_executable(candidate) do
      nil ->
        {:skipped, "no `#{candidate}` executable on PATH; set ASH_A2A_B3SUM to enable"}

      exe ->
        case System.cmd(exe, ["--no-names", path]) do
          {out, 0} -> {:ok, String.trim(out)}
          {out, code} -> {:skipped, "#{candidate} exited #{code}: #{String.trim(out)}"}
        end
    end
  end

  @doc "Lowercase hex SHA-256 of a binary."
  @spec sha256_hex(binary()) :: String.t()
  def sha256_hex(bytes) when is_binary(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  SHA-256 over `canonical_json/1` of `manifest`, excluding any existing
  `"content_digest"` key so the value can live inside the document.
  """
  @spec content_digest(map()) :: String.t()
  def content_digest(manifest) when is_map(manifest) do
    manifest
    |> Map.delete("content_digest")
    |> canonical_json()
    |> sha256_hex()
  end

  @doc """
  Deterministic JSON serialization: objects emitted with recursively sorted
  keys and no insignificant whitespace.
  """
  @spec canonical_json(term()) :: String.t()
  def canonical_json(term), do: term |> canon() |> IO.iodata_to_binary()

  @doc "Same ordering as `canonical_json/1`, indented two spaces for review."
  @spec pretty_json(term()) :: String.t()
  def pretty_json(term), do: term |> canon(0) |> IO.iodata_to_binary()

  defp canon(term, indent \\ nil)

  defp canon(map, indent) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))

    wrap("{", "}", indent, pairs, fn {k, v}, inner ->
      [JSON.encode!(k), ":", sep(indent), canon(v, inner)]
    end)
  end

  defp canon(list, indent) when is_list(list) do
    wrap("[", "]", indent, list, fn item, inner -> canon(item, inner) end)
  end

  defp canon(other, _indent), do: JSON.encode!(other)

  defp wrap(open, close, _indent, [], _fun), do: [open, close]

  defp wrap(open, close, nil, items, fun) do
    [open, items |> Enum.map(&fun.(&1, nil)) |> Enum.intersperse(","), close]
  end

  defp wrap(open, close, indent, items, fun) do
    inner = indent + 1
    pad = String.duplicate("  ", inner)

    body =
      items
      |> Enum.map(&[pad, fun.(&1, inner)])
      |> Enum.intersperse([",\n"])

    [open, "\n", body, "\n", String.duplicate("  ", indent), close]
  end

  defp sep(nil), do: ""
  defp sep(_), do: " "

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         %{
           code: :manifest_not_found,
           message: "cannot read #{path}: #{:file.format_error(reason)}"
         }}
    end
  end

  defp decode(body, path) do
    case JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      _ ->
        {:error, %{code: :manifest_non_json, message: "#{path} is not a JSON object"}}
    end
  end

  defp elem_or_nil({:ok, hex}), do: hex
  defp elem_or_nil({:skipped, _}), do: nil

  defp blake3_status({:skipped, _}, _claimed), do: :skipped
  defp blake3_status({:ok, _}, nil), do: :unclaimed
  defp blake3_status({:ok, hex}, claimed) when hex == claimed, do: :match
  defp blake3_status({:ok, _}, _claimed), do: :mismatch
end
