defmodule AuthorityService.KeyFile do
  @moduledoc """
  Loads the service's OWN automated policy key from a file (never from the environment).

  File content: base64url (no padding) of the 32-byte P-256 private scalar. The file must
  be readable by the owner only (no group/world permission bits); anything looser is
  refused with `:key_file_permissions`.
  """
  import Bitwise
  alias Sa2aCrypto.KeyRef

  @type t :: %{
          kid: String.t(),
          alg: String.t(),
          public_key: binary(),
          private_key: binary(),
          revocation_epoch: non_neg_integer()
        }

  @spec load(Path.t()) ::
          {:ok, t()}
          | {:error, :key_file_unreadable | :key_file_permissions | :key_file_malformed}
  def load(path) do
    with {:ok, %File.Stat{mode: mode, type: :regular}} <- File.stat(path) |> readable(),
         :ok <- perms(mode),
         {:ok, body} <- File.read(path) |> readable(),
         {:ok, priv} <- decode(body) do
      {pub, ^priv} = :crypto.generate_key(:ecdh, :secp256r1, priv)

      {:ok,
       %{
         kid: KeyRef.kid!("ES256", pub),
         alg: "ES256",
         public_key: pub,
         private_key: priv,
         revocation_epoch: 0
       }}
    end
  end

  defp readable({:ok, v}), do: {:ok, v}
  defp readable(_), do: {:error, :key_file_unreadable}

  defp perms(mode), do: if(band(mode, 0o077) == 0, do: :ok, else: {:error, :key_file_permissions})

  defp decode(body) do
    with {:ok, priv} <- Base.url_decode64(String.trim(body), padding: false),
         32 <- byte_size(priv),
         true <- valid_scalar?(priv) do
      {:ok, priv}
    else
      _ -> {:error, :key_file_malformed}
    end
  end

  # scalar must be in 1..n-1
  defp valid_scalar?(priv) do
    n = Sa2aCrypto.DER.n()
    d = :binary.decode_unsigned(priv)
    d >= 1 and d < n
  end
end
