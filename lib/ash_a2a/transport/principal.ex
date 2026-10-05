# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.Principal do
  @moduledoc """
  Stable, non-leaking owner key for a transport-verified caller identity.

  Task ownership (SEC-01) compares the principal that created a task with the
  principal asking to read, continue, cancel or list it. The key must be:

    * derived only from the verified identity `AshA2A.Protocol.Plug.Auth` produced
      (`metadata["a2a.auth"][:identity]`, atom-keyed; see
      `AshA2A.Agent`'s `verified_auth_identity/1` for why the string-keyed
      shape a remote caller can forge is never accepted);
    * stable across token refresh, so it is built from explicit subject
      claims, never from the whole identity map;
    * free of credential material: it never `inspect/1`s the identity, so a
      raw token or volatile claim inside the map cannot reach a task, a log
      or a telemetry event through this key (SEC-06, transport side).

  Claims are configurable with `config :ash_a2a, :principal_claims, [:iss,
  :sub]`: every listed claim must be present, and the key is their values
  joined with `"|"`. The default (no config) is the first present of
  `:sub`, `:id` (atom or string key), scoped by `:iss` when present (the
  same subject from two issuers is two principals). An identity map carrying none of the
  claims is keyed by a SHA-256 digest of its canonical term encoding -- still
  deterministic and non-leaking, but not refresh-stable, so ownership fails
  closed on refresh for such identities rather than open.
  """

  @default_claims [:sub, :id]

  @typedoc "`:anonymous` when no verified identity is present."
  @type key :: String.t() | :anonymous

  @doc """
  Owner key for the verified identity carried in a call/task `metadata` map.

      iex> AshA2A.Transport.Principal.from_metadata(%{"a2a.auth" => %{identity: %{sub: "u1", token: "t"}}})
      "sub:u1"

      iex> AshA2A.Transport.Principal.from_metadata(%{"a2a.auth" => %{"identity" => %{"sub" => "u1"}}})
      :anonymous
  """
  @spec from_metadata(term()) :: key()
  def from_metadata(%{} = metadata) do
    case Map.get(metadata, "a2a.auth") do
      %{identity: identity} -> key(identity)
      _other -> :anonymous
    end
  end

  def from_metadata(_metadata), do: :anonymous

  @doc """
  Owner key for a verified identity value (the `:identity` field itself).

      iex> AshA2A.Transport.Principal.key(nil)
      :anonymous

      iex> AshA2A.Transport.Principal.key("alice")
      "id:alice"

      iex> AshA2A.Transport.Principal.key(%{"id" => "u2", "exp" => 1})
      "id:u2"

      iex> AshA2A.Transport.Principal.key(%{sub: "u1", iss: "https://idp-a"})
      "sub:u1|iss:https://idp-a"
  """
  @spec key(term()) :: key()
  def key(nil), do: :anonymous
  def key(identity) when is_binary(identity), do: "id:" <> identity

  def key(identity) when is_map(identity) do
    case Application.get_env(:ash_a2a, :principal_claims) do
      claims when is_list(claims) and claims != [] -> all_claims(identity, claims)
      _default -> identity |> first_claim(@default_claims) |> scope_issuer(identity)
    end
  end

  def key(identity), do: digest(identity)

  defp all_claims(identity, claims) do
    values = Enum.map(claims, &claim(identity, &1))

    if Enum.all?(values, &(&1 != nil)) do
      Enum.map_join(Enum.zip(claims, values), "|", fn {c, v} -> "#{c}:#{v}" end)
    else
      digest(identity)
    end
  end

  defp first_claim(identity, claims) do
    Enum.find_value(claims, digest(identity), fn c ->
      case claim(identity, c) do
        nil -> nil
        value -> "#{c}:#{value}"
      end
    end)
  end

  # The same `sub` from two issuers is two principals: when the identity
  # carries `:iss`, the default key is scoped by it.
  defp scope_issuer("h:" <> _ = digest, _identity), do: digest

  defp scope_issuer(key, identity) do
    case claim(identity, :iss) do
      nil -> key
      iss -> key <> "|iss:" <> iss
    end
  end

  defp claim(identity, claim) when is_atom(claim) do
    case AshA2A.MetadataKey.get(identity, claim) do
      value when is_binary(value) and value != "" -> value
      value when is_integer(value) -> Integer.to_string(value)
      value when is_atom(value) and value not in [nil, true, false] -> Atom.to_string(value)
      _other -> nil
    end
  end

  defp digest(identity) do
    "h:" <>
      (:crypto.hash(:sha256, :erlang.term_to_binary(identity, [:deterministic]))
       |> Base.encode16(case: :lower))
  end
end
