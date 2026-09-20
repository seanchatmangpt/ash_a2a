defmodule AshA2A.Gall.Fields do
  @moduledoc """
  Shared field-level predicates for the GALL Semantic Work Fabric message
  shapes (`AshA2A.Gall.Message` and the `gall:*` typed structs).

  These are shape checks, deliberately minimal and dependency-free:

    * `iri?/1` -- the value is a binary carrying an IRI-style scheme prefix
      (`urn:...`, `https://...`, ...). It does NOT dereference or resolve
      the IRI; transport never does.
    * `hex40?/1` -- a 40-character hexadecimal string (a git object SHA-1).
    * `sha256_digest?/1` -- the algorithm-prefixed digest form
      `"sha256:<digest>"` used by the `graphDigest`/`checkpointDigest`
      fields. The full 64-hex identity of a graph is the checkpoint's own
      canonical-digest concern (`AshA2A.Semantic.CanonicalGraph`); this
      boundary only enforces the typed prefix so a foreign digest
      algorithm cannot ride in a `sha256:` field.
    * `non_empty_binary?/1` -- exactly that.
    * `fetch/3` -- atom-or-string key lookup, so constructors accept both
      Elixir-side atom-keyed maps and decoded JSON string-keyed maps.
  """

  @doc """
  Looks `atom_key`/`string_key` up in a map that may use either key style.

      iex> AshA2A.Gall.Fields.fetch(%{"graphDigest" => "sha256:x"}, :graph_digest, "graphDigest")
      "sha256:x"
      iex> AshA2A.Gall.Fields.fetch(%{graph_digest: "sha256:y"}, :graph_digest, "graphDigest")
      "sha256:y"
      iex> AshA2A.Gall.Fields.fetch(%{}, :graph_digest, "graphDigest")
      nil
  """
  @spec fetch(map(), atom(), String.t()) :: term()
  def fetch(map, atom_key, string_key) when is_map(map) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end

  @doc "True when the value is a binary with an IRI-style scheme prefix."
  @spec iri?(term()) :: boolean()
  def iri?(value) when is_binary(value) do
    Regex.match?(~r|^[A-Za-z][A-Za-z0-9+.\-]*:|, value)
  end

  def iri?(_other), do: false

  @doc "True when the value is exactly 40 hexadecimal characters."
  @spec hex40?(term()) :: boolean()
  def hex40?(value) when is_binary(value) do
    Regex.match?(~r/^[0-9a-fA-F]{40}$/, value)
  end

  def hex40?(_other), do: false

  @doc "True when the value is the typed `\"sha256:<digest>\"` form with a non-empty digest."
  @spec sha256_digest?(term()) :: boolean()
  def sha256_digest?(value) when is_binary(value) do
    String.starts_with?(value, "sha256:") and byte_size(value) > byte_size("sha256:")
  end

  def sha256_digest?(_other), do: false

  @doc "True when the value is a binary with at least one non-whitespace character."
  @spec non_empty_binary?(term()) :: boolean()
  def non_empty_binary?(value) when is_binary(value), do: String.trim(value) != ""

  def non_empty_binary?(_other), do: false
end
