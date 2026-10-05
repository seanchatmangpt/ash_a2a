defmodule AshA2A.Protocol.Version do
  @moduledoc """
  Helpers for the `A2A-Version` HTTP header (A2A v1.0 spec §3.6).

  Versions are negotiated as `Major.Minor` strings. Patch components are
  not significant and are stripped during normalization. Per spec §3.6.2
  an empty or missing version is interpreted as `"0.3"`.
  """

  # Single source of truth for the A2A protocol version carried by every
  # emitted Agent Card interface (spec v1.0, sections 4.4/8.2).
  @protocol_version "1.0"
  @well_known_path "/.well-known/agent-card.json"

  @default "1.0"
  @supported_default ["0.3", "1.0"]

  @doc """
  The A2A protocol version (spec v1.0, sections 4.4/8.2): the single source of
  truth for the `protocolVersion` advertised on every emitted Agent Card
  interface.
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc "The well-known Agent Card discovery path (spec v1.0, section 4.4)."
  @spec well_known_path() :: String.t()
  def well_known_path, do: @well_known_path

  @doc "Default version a client sends in the `A2A-Version` request header."
  @spec default() :: String.t()
  def default, do: @default

  @doc "Default list of versions a server accepts."
  @spec supported_default() :: [String.t()]
  def supported_default, do: @supported_default

  @doc """
  Normalizes a version string to its `Major.Minor` form.

  - `nil` and `""` → `"0.3"` (per spec §3.6.2)
  - `"1.0.3"` → `"1.0"`
  - `"  0.3  "` → `"0.3"`

  Values that can't be parsed as `Major.Minor` are returned trimmed so the
  caller can include them in an error response.

  ## Examples

      iex> AshA2A.Protocol.Version.normalize("1.0.3")
      "1.0"

      iex> AshA2A.Protocol.Version.normalize(nil)
      "0.3"
  """
  @spec normalize(String.t() | nil) :: String.t()
  def normalize(nil), do: "0.3"
  def normalize(""), do: "0.3"

  def normalize(version) when is_binary(version) do
    case String.trim(version) do
      "" ->
        "0.3"

      trimmed ->
        case Regex.run(~r/^(\d+)\.(\d+)/, trimmed) do
          [_, major, minor] -> major <> "." <> minor
          _ -> trimmed
        end
    end
  end

  @doc """
  Parses a Plug-style header value (list of strings, single string, or nil)
  into a normalized `Major.Minor` version. An empty list or missing value
  becomes `"0.3"`.
  """
  @spec parse_header([String.t()] | String.t() | nil) :: String.t()
  def parse_header(nil), do: "0.3"
  def parse_header([]), do: "0.3"
  def parse_header(value) when is_binary(value), do: normalize(value)
  def parse_header([value | _]) when is_binary(value), do: normalize(value)

  @doc """
  Returns `:ok` when `version` is in the supported list, otherwise
  `{:error, version}` with the rejected value so the caller can surface it
  in a `VersionNotSupportedError`.
  """
  @spec validate(String.t(), [String.t()]) :: :ok | {:error, String.t()}
  def validate(version, supported) when is_binary(version) and is_list(supported) do
    if version in supported, do: :ok, else: {:error, version}
  end
end
