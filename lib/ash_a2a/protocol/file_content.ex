defmodule AshA2A.Protocol.FileContent do
  @moduledoc """
  Represents file content with either inline bytes or a URI reference.

  At least one of `bytes` or `uri` must be provided.
  """

  @type t :: %__MODULE__{
          name: String.t() | nil,
          mime_type: String.t() | nil,
          bytes: binary() | nil,
          uri: String.t() | nil
        }

  @enforce_keys []
  defstruct [:name, :mime_type, :bytes, :uri]

  @doc """
  Creates a new `FileContent` with inline bytes.
  """
  @spec from_bytes(binary(), keyword()) :: t()
  def from_bytes(bytes, opts \\ []) do
    %__MODULE__{
      bytes: bytes,
      name: Keyword.get(opts, :name),
      mime_type: Keyword.get(opts, :mime_type)
    }
  end

  @doc """
  Creates a new `FileContent` with a URI reference.
  """
  @spec from_uri(String.t(), keyword()) :: t()
  def from_uri(uri, opts \\ []) do
    %__MODULE__{
      uri: uri,
      name: Keyword.get(opts, :name),
      mime_type: Keyword.get(opts, :mime_type)
    }
  end
end
