defmodule AuthorityService.Config do
  @moduledoc "Immutable service configuration."
  alias AuthorityService.{KeyFile, Policy}
  alias Sa2aCrypto.{KeyRecord, KeyRef}

  @enforce_keys [
    :service_key,
    :policy,
    :approver_registry,
    :authority_audience,
    :actuator_audience,
    :journal_path
  ]
  defstruct [
    :service_key,
    :policy,
    :approver_registry,
    :authority_audience,
    :actuator_audience,
    :journal_path,
    :anchor_path,
    channel: nil,
    clock: nil
  ]

  @type t :: %__MODULE__{}

  @doc """
  `actuator_audience` is the registered actuator identity, fixed server-side: every issued
  certificate carries it and a request naming any other audience is refused (B1).
  `approver_registry` is a `{module, state}` view or a zero-arity function returning one; a
  function is resolved inside the serialized issuance step, never before it (T4).
  `anchor_path` (default `journal_path <> ".anchor"`) holds the journal head anchor (B2).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    c = struct!(__MODULE__, opts)
    %{c | anchor_path: c.anchor_path || c.journal_path <> ".anchor"}
  end

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
         {:ok, records} <- registry(rjson),
         {:ok, actuator} <- fetch_actuator(opts) do
      {:ok,
       new(
         service_key: key,
         policy: policy,
         approver_registry: Sa2aCrypto.Registry.Static.view(records),
         authority_audience: Keyword.fetch!(opts, :authority_audience),
         actuator_audience: actuator,
         journal_path: Keyword.fetch!(opts, :journal_path)
       )}
    else
      {:error, _} = e -> e
      _ -> {:error, :config_unreadable}
    end
  end

  defp fetch_actuator(opts) do
    case Keyword.get(opts, :actuator_audience) do
      a when is_binary(a) and a != "" -> {:ok, a}
      _ -> {:error, :actuator_audience_missing}
    end
  end

  defp registry(json) do
    with {:ok, list} when is_list(list) <- Sa2aCrypto.StrictJson.decode(json, canonical: false) do
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
