# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.GRPC.Codec do
  @moduledoc false
  # Request codecs of `AshA2A.Transport.GRPC.Server`.
  #
  # `GRPC.Server` decodes the request message before any interceptor or
  # service function runs, and the stock codecs raise on bytes that are not
  # the request message; the Cowboy adapter turns that raise into `UNKNOWN`.
  # A request that cannot be decoded is the caller's error, so these codecs
  # hand the service an `%Undecodable{}` marker instead, which the server
  # answers `INVALID_ARGUMENT` with an `ErrorInfo` (A2A v1.1 5.4: invalid
  # parameters). Encoding is the stock codec's.

  defmodule Undecodable do
    @moduledoc false
    defstruct [:module]
  end

  @doc false
  def decode_with(codec, binary, module) do
    case codec.decode(binary, module) do
      %{__struct__: ^module} = message -> message
      _other -> %Undecodable{module: module}
    end
  rescue
    _ -> %Undecodable{module: module}
  catch
    _, _ -> %Undecodable{module: module}
  end

  defmodule Proto do
    @moduledoc false
    @behaviour GRPC.Codec

    @impl true
    def name, do: GRPC.Codec.Proto.name()

    @impl true
    def encode(struct, opts \\ []), do: GRPC.Codec.Proto.encode(struct, opts)

    @impl true
    def decode(binary, module),
      do: AshA2A.Transport.GRPC.Codec.decode_with(GRPC.Codec.Proto, binary, module)
  end

  defmodule WebText do
    @moduledoc false
    @behaviour GRPC.Codec

    @impl true
    def name, do: GRPC.Codec.WebText.name()

    @impl true
    def encode(struct, opts \\ []), do: GRPC.Codec.WebText.encode(struct, opts)

    @impl true
    def pack_for_channel(data), do: GRPC.Codec.WebText.pack_for_channel(data)

    # Bytes that are not Base64 reach `decode/2` unchanged and fail there.
    @impl true
    def unpack_from_channel(binary) do
      case Base.decode64(binary) do
        {:ok, decoded} -> decoded
        :error -> binary
      end
    end

    @impl true
    def decode(binary, module),
      do: AshA2A.Transport.GRPC.Codec.decode_with(GRPC.Codec.WebText, binary, module)
  end

  defmodule JSON do
    @moduledoc false
    @behaviour GRPC.Codec

    @impl true
    def name, do: GRPC.Codec.JSON.name()

    @impl true
    def encode(struct, opts \\ []), do: GRPC.Codec.JSON.encode(struct, opts)

    @impl true
    def decode(binary, module),
      do: AshA2A.Transport.GRPC.Codec.decode_with(GRPC.Codec.JSON, binary, module)
  end
end
