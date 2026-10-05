# SPDX-WorkOrder: GGE-26922-12 (docs/jira/v26.10.4/PRD.md FR-01.1)
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SPIFFE.TrustBundle do
  @moduledoc """
  In-memory X.509 trust-bundle cache fed by `AshA2A.SPIFFE.WorkloadWatcher` from
  a SPIRE agent's X509SVID stream. Fail-closed admission: `from_update/3` and
  `admit/3` never admit an already-expired delivery — the last-known-good bundle
  is retained instead, and remains queryable exactly until its own `:expires_at`,
  never past it (expiry-bounded trust).
  """

  alias AshA2A.SPIFFE.Identity

  @enforce_keys [:certs, :digest, :received_at, :expires_at]
  defstruct @enforce_keys ++ [:svids]

  @typedoc "DER-encoded X.509 certificate"
  @type der :: binary()

  @type t :: %__MODULE__{
          certs: [der()],
          digest: binary(),
          received_at: integer(),
          expires_at: integer(),
          svids: [svid()]
        }

  @typedoc """
  A streamed X.509 SVID: the parsed `AshA2A.SPIFFE.Identity`, its DER leaf
  certificate, the issuing chain (leaf first, then intermediates; bundle roots
  are carried by the bundle itself), and the leaf `notAfter` as Unix-epoch
  integer seconds.
  """
  @type svid :: %{
          required(:identity) => Identity.t(),
          required(:cert) => der(),
          required(:chain) => [der()],
          required(:expires_at) => integer()
        }

  @doc """
  Admits a delivered update (streamed SVIDs + bundle roots) into a new bundle.
  Fail-closed: if the delivered material's earliest `notAfter` (bundle roots and
  SVID leaf certificates alike) is not in the future at `now`, the delivery is
  refused with `{:error, :trust_bundle_expired}` and the caller must retain the
  last-known-good bundle; otherwise `{:ok, bundle}`.
  """
  @spec from_update([svid()], [der()], now :: integer()) ::
          {:ok, t()} | {:error, :trust_bundle_expired}
  def from_update(svids, bundle_certs, now)

  def from_update(_svids, [], _now), do: {:error, :trust_bundle_expired}

  def from_update(svids, bundle_certs, now) when is_list(svids) and is_list(bundle_certs) do
    expires_at = earliest_expiry(bundle_certs ++ Enum.map(svids, & &1.cert))

    if now < expires_at do
      {:ok,
       %__MODULE__{
         certs: bundle_certs,
         digest: digest(bundle_certs),
         received_at: now,
         expires_at: expires_at,
         svids: svids
       }}
    else
      {:error, :trust_bundle_expired}
    end
  end

  @doc """
  Expiry-bounded validity: true only while `now < bundle.expires_at`. The
  last-known-good bundle stays queryable exactly this long after the stream
  goes down — never longer.
  """
  @spec valid?(t(), integer()) :: boolean()
  def valid?(%__MODULE__{} = bundle, now) when is_integer(now),
    do: now < bundle.expires_at

  @doc """
  Fail-closed fetch used by `AshA2A.SPIFFE.WorkloadWatcher`'s public API:
  `{:ok, bundle}` while within validity, `{:error, :no_trust_bundle}` when no
  bundle has ever been admitted, `{:error, :trust_bundle_expired}` at or past
  `:expires_at`.
  """
  @spec fetch(t() | nil, integer()) ::
          {:ok, t()} | {:error, :no_trust_bundle | :trust_bundle_expired}
  def fetch(nil, _now), do: {:error, :no_trust_bundle}

  def fetch(%__MODULE__{} = bundle, now) do
    if valid?(bundle, now), do: {:ok, bundle}, else: {:error, :trust_bundle_expired}
  end

  @doc """
  Rotation admission: admit `candidate` only when it is not already expired at
  `now`; otherwise retain the last-known-good `current`. Errors only when there
  is no last-known-good to retain.
  """
  @spec admit(current :: t() | nil, candidate :: t(), now :: integer()) ::
          {:admitted, t()} | {:retained, t() | nil} | {:error, :no_last_known_good}
  def admit(nil, %__MODULE__{} = candidate, now) do
    if now < candidate.expires_at do
      {:admitted, candidate}
    else
      {:error, :no_last_known_good}
    end
  end

  def admit(%__MODULE__{} = current, %__MODULE__{} = candidate, now) do
    if now < candidate.expires_at do
      {:admitted, candidate}
    else
      {:retained, current}
    end
  end

  @doc """
  Pre-expiry rotation deadline for `bundle` (Unix-epoch seconds): the instant
  the watcher must force a re-push (reconnect) so the cache rotates before
  `:expires_at`. `lead_ms` is a millisecond policy knob, converted to seconds
  internally; deadline is the earlier of `expires_at - lead` and `now + lead`.
  """
  @spec rotation_due_at(t(), integer(), integer()) :: integer()
  def rotation_due_at(%__MODULE__{expires_at: expires_at}, now, lead_ms)
      when is_integer(now) and is_integer(lead_ms) and lead_ms >= 0 do
    lead_secs = div(lead_ms, 1000)
    min(expires_at - lead_secs, now + lead_secs)
  end

  @doc """
  True when `now` is at or past the rotation deadline of `bundle` under
  `lead_ms` — rotation must be forced now.
  """
  @spec due?(t(), integer(), integer()) :: boolean()
  def due?(%__MODULE__{expires_at: expires_at}, now, lead_ms),
    do: now >= expires_at - div(lead_ms, 1000)

  @doc """
  Earliest `notAfter` across DER certificates (infinity when the list is empty
  — the caller is expected to refuse empty deliveries before reaching here).
  """
  @spec earliest_expiry([der()]) :: integer() | :infinity
  def earliest_expiry([]), do: :infinity

  def earliest_expiry(certs) when is_list(certs) do
    certs
    |> Enum.map(&cert_not_after/1)
    |> Enum.min()
  end

  @doc """
  SHA-256 digest over the concatenated DER bundle roots — the content identity
  of the bundle: stable across re-delivery of the same roots, changed by any
  root substitution.
  """
  @spec digest([der()]) :: binary()
  def digest(certs) when is_list(certs),
    do: :crypto.hash(:sha256, certs)

  ## ------------------------------------------------------------------
  ## Certificate field extraction (:public_key OTP records)
  ## ------------------------------------------------------------------

  defp cert_not_after(der) when is_binary(der) do
    # Undecodable material fails closed: epoch 0, so any delivery containing it
    # is refused rather than trusted with an infinite expiry.
    try do
      case :public_key.pkix_decode_cert(der, :otp) do
        {:OTPCertificate, tbs, _sig_alg, _} ->
          {:Validity, _not_before, not_after} = elem(tbs, 5)
          parse_time(elem(not_after, 1))

        _ ->
          0
      end
    rescue
      _ -> 0
    end
  end

  defp parse_time({:utcTime, chars}), do: utc_time_to_epoch(chars)
  defp parse_time({:generalTime, chars}), do: general_time_to_epoch(chars)

  defp utc_time_to_epoch([y1, y2 | rest]) do
    year = List.to_integer([y1, y2])
    year = if year >= 50, do: 1900 + year, else: 2000 + year
    epoch_from_parts(year, rest)
  end

  defp general_time_to_epoch([y1, y2, y3, y4 | rest]) do
    epoch_from_parts(List.to_integer([y1, y2, y3, y4]), rest)
  end

  defp epoch_from_parts(year, [m1, m2, d1, d2, h1, h2, i1, i2, s1, s2 | _]) do
    :calendar.datetime_to_gregorian_seconds(
      {{year, List.to_integer([m1, m2]), List.to_integer([d1, d2])},
       {List.to_integer([h1, h2]), List.to_integer([i1, i2]), List.to_integer([s1, s2])}}
    ) - 62_167_219_200
  end
end
