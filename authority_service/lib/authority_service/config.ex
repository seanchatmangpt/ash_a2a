defmodule AuthorityService.Config do
  @moduledoc "Immutable service configuration."
  alias AuthorityService.{KeyFile, Policy}
  alias Sa2aCrypto.{KeyRecord, KeyRef}

  @enforce_keys [:service_key, :policy, :approver_registry, :authority_audience, :journal_path]
  defstruct [
    :service_key,
    :policy,
    :approver_registry,
    :authority_audience,
    :journal_path,
    channel: nil,
    clock: nil
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Build from files. Key material only ever comes from `key_path` (0600 file). The registry
  file is JSON: `[{kid?, alg: "ES256", public_key (b64url X9.62 point), custodian_id,
  custody_tier, state, revocation_epoch, not_after?}]`.
  """
  @spec from_files(keyword()) :: {:ok, t()} | {:error, term()}
  def from_files(opts) do
    with {:ok, key} <- KeyFile.load(Keyword.fetch!(opts, :key_path)),
         {:ok, pjson} <- File.read(Keyword.fetch!(opts, :policy_path)),
         {:ok, policy} <- Policy.from_json(pjson),
         {:ok, rjson} <- File.read(Keyword.fetch!(opts, :registry_path)),
         {:ok, records} <- registry(rjson) do
      {:ok,
       new(
         service_key: key,
         policy: policy,
         approver_registry: Sa2aCrypto.Registry.Static.view(records),
         authority_audience: Keyword.fetch!(opts, :authority_audience),
         journal_path: Keyword.fetch!(opts, :journal_path)
       )}
    else
      {:error, _} = e -> e
      _ -> {:error, :config_unreadable}
    end
  end

  defp registry(json) do
    with {:ok, list} when is_list(list) <- Jason.decode(json) do
      Enum.reduce_while(list, {:ok, []}, fn r, {:ok, acc} ->
        with {:ok, pub} <- Base.url_decode64(r["public_key"] || "", padding: false),
             {:ok, kid} <- KeyRef.kid("ES256", pub) do
          rec = %KeyRecord{
            kid: kid,
            alg: "ES256",
            public_key: pub,
            custodian_id: r["custodian_id"],
            custody_tier: String.to_existing_atom(r["custody_tier"]),
            state: String.to_existing_atom(r["state"]),
            revocation_epoch: r["revocation_epoch"] || 0,
            not_after: r["not_after"]
          }

          {:cont, {:ok, [rec | acc]}}
        else
          _ -> {:halt, {:error, :registry_malformed}}
        end
      end)
    else
      _ -> {:error, :registry_malformed}
    end
  rescue
    _ -> {:error, :registry_malformed}
  end
end
