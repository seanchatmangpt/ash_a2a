# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.AgentCardSignature do
  @moduledoc """
  Standard JWS signatures (RFC 7515, detached payload) over A2A agent cards,
  for the `AgentCardSignature` entries of the card's `signatures` field.

  The signed payload is the RFC 8785 canonical JSON of the card map **without**
  its `"signatures"` member. A signature entry is
  `%{"protected" => b64url(header_json), "signature" => b64url(sig)}` where the
  signing input is `protected <> "." <> b64url(canonical_card_bytes)`; the
  payload itself is not carried (detached).

  Algorithms: `ES256` (ECDSA P-256 / SHA-256, raw `r || s`) and `EdDSA`
  (Ed25519). Keys are JWK maps with string keys (RFC 7517/8037):

    * `%{"kty" => "EC", "crv" => "P-256", "x" => _, "y" => _, "d" => _}`
    * `%{"kty" => "OKP", "crv" => "Ed25519", "x" => _, "d" => _}`

  (`"d"` is only needed to sign.)

  ## Refusals

  `sign/3` and `verify/3` refuse: `alg` other than `ES256`/`EdDSA` (including
  `none` and every HMAC/RSA alg), an `alg` that does not match the key's
  `kty`/`crv` (or the JWK's own `alg`), a missing or empty `kid`, a `crit`
  header, a JWK with `use` other than `sig`, a tampered card or signature, and
  card maps whose keys are not all strings (an atom key beside a string key of
  the same name would otherwise produce duplicate canonical members). Key order
  in the map never changes the canonical bytes (RFC 8785 sorts members).

  The `alg`/`kid` used for verification come only from the **protected** header;
  the unprotected `"header"` member is ignored.

  ## Integration hook

  `attach/2` appends signature entries to a card map's `"signatures"` list.
  The card plugs do this for you: pass `sign_with: [jwk: private_jwk, kid: kid]`
  to `AshA2A.Protocol.Plug`, `AshA2A.A2ATransport.Plug`, `AshA2A.Transport.Plug`
  or `AshA2A.Transport.HTTPJSON` and the served card carries one entry computed
  over the exact served document. See `docs/how-to/sign-agent-cards.md`.

  This is distinct from `AshA2A.Protocol.CardSigning`, which signs the v1.0
  wire projection with its own non-standard `typ`/digest header.
  """

  @algs ["ES256", "EdDSA"]

  @type jwk :: %{optional(String.t()) => String.t()}
  @type keys :: %{required(String.t()) => list(jwk())} | (String.t() -> jwk() | nil)

  @doc """
  Signs a string-keyed card map. Options: `:kid` (required), `:alg`
  (`"ES256"` | `"EdDSA"`, default inferred from the key).

  Returns `{:ok, signature_entry}` (not attached; pass it to `attach/2`).
  """
  @spec sign(map(), jwk(), keyword()) :: {:ok, map()} | {:error, term()}
  def sign(card, key, opts \\ []) when is_map(card) and is_map(key) and is_list(opts) do
    kid = Keyword.get(opts, :kid)

    with :ok <- check_kid(kid),
         {:ok, alg} <- pick_alg(key, Keyword.get(opts, :alg)),
         :ok <- check_key_alg(key, alg),
         {:ok, payload} <- canonical_payload(card),
         {:ok, protected} <- encode_protected(alg, kid),
         {:ok, sig} <- raw_sign(alg, key, signing_input(protected, payload)) do
      {:ok, %{"protected" => protected, "signature" => b64(sig)}}
    end
  end

  @doc """
  Appends `signatures` (a list of entries) to the card map's `"signatures"`.
  Existing entries are kept. Does not verify them.
  """
  @spec attach(map(), [map()]) :: map()
  def attach(card, signatures) when is_map(card) and is_list(signatures) do
    Enum.each(signatures, fn
      %{"protected" => p, "signature" => s} when is_binary(p) and is_binary(s) -> :ok
      other -> raise ArgumentError, "invalid AgentCardSignature entry: #{inspect(other)}"
    end)

    existing =
      case Map.get(card, "signatures") do
        list when is_list(list) -> list
        _ -> []
      end

    Map.put(card, "signatures", existing ++ signatures)
  end

  @doc """
  Verifies the card's `"signatures"`. `keys` is a JWKS map
  (`%{"keys" => [jwk, ...]}`) or a one-arity function `kid -> jwk | nil`.

  Options: `:allowed_algs` (subset of `["ES256", "EdDSA"]`), `:require`
  (`:any`, default: at least one entry verifies; `:all`: every entry must).

  Returns `{:ok, [kid]}` of verified entries, or `{:error, reason}`.
  """
  @spec verify(map(), keys(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def verify(card, keys, opts \\ []) when is_map(card) and is_list(opts) do
    allowed = Keyword.get(opts, :allowed_algs, @algs) |> Enum.filter(&(&1 in @algs))

    with {:ok, payload} <- canonical_payload(card),
         {:ok, entries} <- entries(card) do
      results = Enum.map(entries, &verify_entry(&1, payload, keys, allowed))
      oks = for {:ok, kid} <- results, do: kid
      errors = for {:error, _} = e <- results, do: e

      case {Keyword.get(opts, :require, :any), oks, errors} do
        {:any, [_ | _], _} -> {:ok, oks}
        {:all, [_ | _], []} -> {:ok, oks}
        {_, _, [first | _]} -> first
        _ -> {:error, :no_signatures}
      end
    end
  end

  defp entries(card) do
    case Map.get(card, "signatures") do
      [_ | _] = list -> {:ok, list}
      _ -> {:error, :no_signatures}
    end
  end

  defp verify_entry(%{"protected" => p, "signature" => s}, payload, keys, allowed)
       when is_binary(p) and is_binary(s) do
    with {:ok, header} <- decode_protected(p),
         :ok <- check_crit(header),
         alg = Map.get(header, "alg"),
         :ok <- check_alg(alg, allowed),
         kid = Map.get(header, "kid"),
         :ok <- check_kid(kid),
         {:ok, jwk} <- lookup(keys, kid),
         :ok <- check_key_alg(jwk, alg),
         {:ok, sig} <- decode_b64(s, :bad_signature_encoding),
         true <- raw_verify(alg, jwk, signing_input(p, payload), sig) || {:error, :bad_signature} do
      {:ok, kid}
    end
  end

  defp verify_entry(_, _, _, _), do: {:error, :malformed_signature_entry}

  defp check_alg(alg, allowed) when is_binary(alg) do
    if alg in allowed, do: :ok, else: {:error, {:alg_not_allowed, alg}}
  end

  defp check_alg(_, _), do: {:error, :missing_alg}

  defp check_kid(kid) when is_binary(kid) and kid != "", do: :ok
  defp check_kid(_), do: {:error, :missing_kid}

  defp check_crit(%{"crit" => _}), do: {:error, :crit_unsupported}
  defp check_crit(_), do: :ok

  defp pick_alg(key, nil) do
    case key do
      %{"kty" => "EC", "crv" => "P-256"} -> {:ok, "ES256"}
      %{"kty" => "OKP", "crv" => "Ed25519"} -> {:ok, "EdDSA"}
      _ -> {:error, :unsupported_key}
    end
  end

  defp pick_alg(_key, alg) when alg in [:ES256, "ES256"], do: {:ok, "ES256"}
  defp pick_alg(_key, alg) when alg in [:EdDSA, "EdDSA"], do: {:ok, "EdDSA"}
  defp pick_alg(_key, alg), do: {:error, {:alg_not_allowed, alg}}

  defp check_key_alg(jwk, alg) do
    ok_type =
      case {alg, jwk} do
        {"ES256", %{"kty" => "EC", "crv" => "P-256"}} -> true
        {"EdDSA", %{"kty" => "OKP", "crv" => "Ed25519"}} -> true
        _ -> false
      end

    cond do
      not ok_type -> {:error, :alg_key_mismatch}
      Map.has_key?(jwk, "alg") and jwk["alg"] != alg -> {:error, :alg_key_mismatch}
      Map.has_key?(jwk, "use") and jwk["use"] != "sig" -> {:error, :key_not_for_signing}
      true -> :ok
    end
  end

  defp lookup(fun, kid) when is_function(fun, 1) do
    case fun.(kid) do
      %{} = jwk -> {:ok, jwk}
      _ -> {:error, :unknown_kid}
    end
  end

  defp lookup(%{"keys" => list}, kid) when is_list(list) do
    case Enum.filter(list, &(is_map(&1) and &1["kid"] == kid)) do
      [jwk] -> {:ok, jwk}
      [] -> {:error, :unknown_kid}
      _ -> {:error, :ambiguous_kid}
    end
  end

  defp lookup(_, _), do: {:error, :unknown_kid}

  defp encode_protected(alg, kid) do
    with {:ok, json} <- AshA2A.Wire.Jcs.encode(%{"alg" => alg, "kid" => kid, "typ" => "JOSE"}) do
      {:ok, b64(json)}
    end
  end

  defp decode_protected(p) do
    with {:ok, json} <- decode_b64(p, :bad_protected_header),
         {:ok, %{} = header} <- Jason.decode(json) do
      {:ok, header}
    else
      _ -> {:error, :bad_protected_header}
    end
  end

  defp signing_input(protected_b64, payload), do: protected_b64 <> "." <> b64(payload)

  defp canonical_payload(card) do
    body = Map.delete(card, "signatures")

    if strict_json?(body) do
      AshA2A.Wire.Jcs.encode(body)
    else
      {:error, :non_canonicalizable_card}
    end
  end

  defp strict_json?(%{} = m) when not is_struct(m),
    do: Enum.all?(m, fn {k, v} -> is_binary(k) and String.valid?(k) and strict_json?(v) end)

  defp strict_json?(l) when is_list(l), do: Enum.all?(l, &strict_json?/1)
  # RFC 8785 numbers are IEEE-754 doubles: an integer outside +-(2^53 - 1) has no
  # canonical form (and a huge one has no finite double at all).
  defp strict_json?(v) when is_integer(v), do: abs(v) <= 9_007_199_254_740_991
  defp strict_json?(v) when is_binary(v), do: String.valid?(v)
  defp strict_json?(v) when is_float(v) or is_boolean(v) or is_nil(v), do: true
  defp strict_json?(_), do: false

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp decode_b64(s, err) do
    case Base.url_decode64(s, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, err}
    end
  end

  defp raw_sign("ES256", %{"d" => d}, input) do
    with {:ok, priv} <- decode_b64(d, :bad_key) do
      der = :crypto.sign(:ecdsa, :sha256, input, [priv, :secp256r1])
      {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
      {:ok, <<r::unsigned-big-size(256), s::unsigned-big-size(256)>>}
    end
  end

  defp raw_sign("EdDSA", %{"d" => d}, input) do
    with {:ok, priv} <- decode_b64(d, :bad_key) do
      {:ok, :crypto.sign(:eddsa, :none, input, [priv, :ed25519])}
    end
  end

  defp raw_sign(_, _, _), do: {:error, :missing_private_key}

  defp raw_verify(
         "ES256",
         %{"x" => x, "y" => y},
         input,
         <<r::unsigned-big-size(256), s::unsigned-big-size(256)>>
       ) do
    with {:ok, xb} <- decode_b64(x, :bad_key),
         {:ok, yb} <- decode_b64(y, :bad_key),
         32 <- byte_size(xb),
         32 <- byte_size(yb) do
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
      :crypto.verify(:ecdsa, :sha256, input, der, [<<4, xb::binary, yb::binary>>, :secp256r1])
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp raw_verify("EdDSA", %{"x" => x}, input, sig) when byte_size(sig) == 64 do
    case decode_b64(x, :bad_key) do
      {:ok, pub} when byte_size(pub) == 32 ->
        :crypto.verify(:eddsa, :none, input, sig, [pub, :ed25519])

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp raw_verify(_, _, _, _), do: false
end
