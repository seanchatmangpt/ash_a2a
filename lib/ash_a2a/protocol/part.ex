defmodule AshA2A.Protocol.Part do
  @moduledoc """
  Typed content parts used in messages and artifacts.

  Three variants exist:

  - `AshA2A.Protocol.Part.Text` — plain text content
  - `AshA2A.Protocol.Part.File` — file content (inline bytes or URI)
  - `AshA2A.Protocol.Part.Data` — structured data (map)
  """

  @type t :: AshA2A.Protocol.Part.Text.t() | AshA2A.Protocol.Part.File.t() | AshA2A.Protocol.Part.Data.t()
end

defmodule AshA2A.Protocol.Part.Text do
  @moduledoc """
  A text content part.
  """

  @type t :: %__MODULE__{
          text: String.t(),
          metadata: map()
        }

  defstruct text: "", metadata: %{}

  @doc """
  Creates a new text part.
  """
  @spec new(String.t(), map()) :: t()
  def new(text, metadata \\ %{}) do
    %__MODULE__{text: text, metadata: metadata}
  end
end

defmodule AshA2A.Protocol.Part.File do
  @moduledoc """
  A file content part.
  """

  @type t :: %__MODULE__{
          file: AshA2A.Protocol.FileContent.t(),
          metadata: map()
        }

  @enforce_keys [:file]
  defstruct file: nil, metadata: %{}

  @doc """
  Creates a new file part.
  """
  @spec new(AshA2A.Protocol.FileContent.t(), map()) :: t()
  def new(%AshA2A.Protocol.FileContent{} = file, metadata \\ %{}) do
    %__MODULE__{file: file, metadata: metadata}
  end
end

defmodule AshA2A.Protocol.Part.Data do
  @moduledoc """
  A structured data content part.
  """

  @type t :: %__MODULE__{
          data: map(),
          metadata: map()
        }

  defstruct data: %{}, metadata: %{}

  @doc """
  Creates a new data part.
  """
  @spec new(map(), map()) :: t()
  def new(data, metadata \\ %{}) when is_map(data) do
    %__MODULE__{data: data, metadata: metadata}
  end
end
