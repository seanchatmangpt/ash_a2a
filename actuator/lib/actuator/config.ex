defmodule Actuator.Config do
  @moduledoc """
  Loads the operator-pinned actuator configuration into an `Actuator.Context`.

  The file (`ACTUATOR_CONFIG`) pins the key registry (public keys only; the `kid` of every
  entry is recomputed from the key and must match), audience, policy epoch, allowed
  subjects, quorum policy and generation view. The revocation view is read from
  `<state_dir>/revocation.json` (`{refreshed_at, epoch, revoked}`) on every call; a missing
  or unreadable view yields a nil revocation view, which the fence refuses (fail closed).
  """
  alias Actuator.Context
  alias Sa2aCrypto.{Envelope, KeyRecord, KeyRef}
  alias Sa2aCrypto.Registry.Static

  @spec load(Path.t()) :: {:ok, Context.t()} | {:error, atom()}
  def load(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, c} when is_map(c) <- Actuator.StrictJson.decode(raw),
         {:ok, qd} <- quorum_default(c),
         :ok <- quorum_map(c["quorum"]),
         {:ok, records} <- records(c["registry"]),
         {:ok, profile} <- profile(c["required_profile"] || "classical") do
      dir = c["state_dir"]

      {:ok,
       %Context{
         state_dir: dir,
         registry: Static.view(records),
         audience: c["audience"],
         policy_epoch: c["policy_epoch"],
         revocation: revocation(dir),
         allowed_subjects: c["allowed_subjects"] || [],
         allowed_capabilities: c["allowed_capabilities"] || :all,
         quorum: c["quorum"] || %{},
         quorum_default: qd,
         generations: c["generations"] || %{},
         generation_default: c["generation_default"] || 1,
         skew: c["skew"] || 30,
         max_ttl: c["max_ttl"] || 900,
         max_revocation_staleness: c["max_revocation_staleness"] || 300,
         required_profile: profile
       }}
    else
      _ -> {:error, :config_unavailable}
    end
  rescue
    _ -> {:error, :config_unavailable}
  end

  defp quorum_default(%{"quorum_default" => n}) when is_integer(n) and n >= 1, do: {:ok, n}
  defp quorum_default(_), do: :error

  defp quorum_map(nil), do: :ok

  defp quorum_map(m) when is_map(m),
    do: if(Enum.all?(m, fn {_, v} -> is_integer(v) and v >= 1 end), do: :ok, else: :error)

  defp quorum_map(_), do: :error

  defp profile(p) when p in ["classical", "hybrid", "pqc"], do: {:ok, String.to_atom(p)}
  defp profile(_), do: :error

  defp records(list) when is_list(list) and list != [] do
    Enum.reduce_while(list, {:ok, []}, fn k, {:ok, acc} ->
      with {:ok, pub} <- Envelope.b64(k["public_key"] || ""),
           {:ok, kid} <- KeyRef.kid(k["alg"], pub),
           true <- kid == k["kid"],
           state
           when state in [
                  :active,
                  :suspended,
                  :deactivated,
                  :compromised,
                  :destroyed,
                  :pre_activation
                ] <-
             state(k["state"] || "active") do
        rec = %KeyRecord{
          kid: kid,
          alg: k["alg"],
          public_key: pub,
          custodian_id: k["custodian_id"],
          custody_tier: String.to_atom(k["custody_tier"] || "i1"),
          state: state,
          revocation_epoch: k["revocation_epoch"] || 0,
          not_after: k["not_after"]
        }

        {:cont, {:ok, [rec | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp records(_), do: :error

  defp state(s) when is_binary(s) do
    Enum.find(KeyRecord.states(), fn x -> Atom.to_string(x) == s end)
  end

  defp revocation(dir) do
    with {:ok, raw} <- File.read(Path.join(dir, "revocation.json")),
         {:ok, %{"refreshed_at" => at, "epoch" => ep, "revoked" => rv}}
         when is_integer(at) and is_integer(ep) and is_list(rv) <- Actuator.StrictJson.decode(raw) do
      %{refreshed_at: at, epoch: ep, revoked: MapSet.new(rv)}
    else
      _ -> nil
    end
  end
end
