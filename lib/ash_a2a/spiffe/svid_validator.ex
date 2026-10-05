# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Plug) do
  defmodule AshA2A.SPIFFE.SvidValidator do
    @moduledoc """
    Plug that authenticates the caller as a SPIFFE workload from the TLS peer
    certificate (X.509-SVID) and stamps the verified identity into
    `conn.assigns` for the AuthZEN gate.

    Fail-closed by construction: a missing, malformed, expired, or untrusted
    SVID — or an unavailable trust bundle — is a typed refusal, never an
    ambient pass. Authentication is evidence, not authority: the stamped
    identity grants nothing by itself.

    ## Options

      * `:trust_domain` — the local trust domain (required). The SVID's SPIFFE
        ID must live in this trust domain.
      * `:bundle_source` — module exporting `bundle/0` (required; default
        `AshA2A.SPIFFE.WorkloadWatcher`, the V4-1 workload watcher's cached
        trust bundle). The callback returns `{:ok, bundle}` or
        `{:error, term}`, where `bundle` is a map with:

        * `:trust_domain` — the trust domain the bundle belongs to (binary);
        * `:root_certificates` — trust anchors of that trust domain (DER
          binaries);
        * `:intermediate_certificates` — optional off-bundle CA material (DER
          binaries) needed to build the certification path from an SVID to a
          root (defaults to `[]`).

      * `:assign` — the `conn.assigns` key the verified identity is stamped
        under (default `:spiffe_identity`).

    ## Verified identity

    On success `conn.assigns[:spiffe_identity]` holds an
    `AshA2A.SPIFFE.AttestedIdentity` whose `identity` is the parsed
    `AshA2A.SPIFFE.Identity` (`spiffe://<td>/ns/<ns>/sa/<sa>`). Helpers:

      * `get_spiffe_identity/1` — the attested identity, or `nil`;
      * `workload/1` — `{:ok, %{trust_domain:, namespace:, service_account:}}`
        for the required `/ns/<ns>/sa/<sa>` path shape, else
        `{:error, :identity_path_invalid}`.

    ## Refusals

    Every refusal is a typed JSON body — HTTP 401 for SVID faults, 503 for a
    faulting bundle source (still fail-closed):

        {"error": "spiffe_svid_refused", "reason": "<typed reason>"}

    Reasons: `missing_svid`, `svid_malformed`, `svid_expired`,
    `svid_untrusted`, `svid_identity_absent`, `svid_multiple_uris`,
    `trust_domain_mismatch`, `identity_path_invalid`,
    `bundle_source_unavailable`, `trust_bundle_unavailable`,
    `trust_bundle_empty`.
    """

    @behaviour Plug

    import Plug.Conn

    alias AshA2A.SPIFFE.{AttestedIdentity, Identity}

    @default_assign :spiffe_identity
    @default_bundle_source AshA2A.SPIFFE.WorkloadWatcher

    @refusal_reasons [
      :missing_svid,
      :svid_malformed,
      :svid_expired,
      :svid_untrusted,
      :svid_identity_absent,
      :svid_multiple_uris,
      :trust_domain_mismatch,
      :identity_path_invalid,
      :bundle_source_unavailable,
      :trust_bundle_unavailable,
      :trust_bundle_empty
    ]

    # -- Plug callbacks ----------------------------------------------------------

    @impl Plug
    def init(opts) do
      trust_domain = Keyword.fetch!(opts, :trust_domain)
      bundle_source = Keyword.get(opts, :bundle_source, @default_bundle_source)
      assign = Keyword.get(opts, :assign, @default_assign)

      unless is_binary(trust_domain) and trust_domain != "" do
        raise ArgumentError, "AshA2A.SPIFFE.SvidValidator :trust_domain must be a non-empty binary"
      end

      unless is_atom(bundle_source) do
        raise ArgumentError, "AshA2A.SPIFFE.SvidValidator :bundle_source must be a module"
      end

      unless is_atom(assign) do
        raise ArgumentError, "AshA2A.SPIFFE.SvidValidator :assign must be an atom"
      end

      %{trust_domain: trust_domain, bundle_source: bundle_source, assign: assign}
    end

    @impl Plug
    @spec call(Plug.Conn.t(), %{
            required(:trust_domain) => String.t(),
            required(:bundle_source) => module(),
            required(:assign) => atom()
          }) :: Plug.Conn.t()
    def call(conn, %{trust_domain: trust_domain} = opts) do
      with {:ok, bundle} <- load_bundle(opts.bundle_source),
           {:ok, svid_der} <- peer_certificate(conn),
           {:ok, otp_cert} <- decode_svid(svid_der),
           {:ok, root_der} <- validate_chain(svid_der, bundle),
           {:ok, spiffe_uri} <- svid_spiffe_uri(otp_cert),
           {:ok, identity} <- parse_identity(spiffe_uri),
           :ok <- check_trust_domain(identity, bundle.trust_domain),
           :ok <- check_trust_domain(identity, trust_domain),
           {:ok, _workload} <- workload_or_refuse(identity) do
        digest = Base.encode16(:crypto.hash(:sha256, root_der), case: :lower)

        {:ok, attested} =
          AttestedIdentity.from_verified(identity.uri,
            svid_type: :x509,
            bundle_digest: digest,
            observed_at: System.system_time(:millisecond)
          )

        %{conn | assigns: Map.put(conn.assigns, opts.assign, attested)}
      else
        {:refuse, status, reason} -> refuse(conn, status, reason)
      end
    end

    # -- Accessors ----------------------------------------------------------------

    @doc "The verified SPIFFE identity stamped by this plug, or `nil`."
    @spec get_spiffe_identity(Plug.Conn.t()) :: AttestedIdentity.t() | nil
    def get_spiffe_identity(conn), do: conn.assigns[@default_assign]

    @doc """
    The `/ns/<namespace>/sa/<service-account>` segments of a
    `AshA2A.SPIFFE.Identity`, or `{:error, :identity_path_invalid}`.
    """
    @spec workload(Identity.t()) ::
            {:ok, %{trust_domain: String.t(), namespace: String.t(), service_account: String.t()}}
            | {:error, :identity_path_invalid}
    def workload(%Identity{trust_domain: td, path: path}) do
      case String.split(path, "/", trim: true) do
        ["ns", ns, "sa", sa] -> {:ok, %{trust_domain: td, namespace: ns, service_account: sa}}
        _ -> {:error, :identity_path_invalid}
      end
    end

    def workload(_), do: {:error, :identity_path_invalid}

    # -- Steps ---------------------------------------------------------------------

    # Bundle faults are server-side, but still fail-closed: 503, never a pass.
    defp load_bundle(source) do
      cond do
        not Code.ensure_loaded?(source) ->
          {:refuse, 503, :bundle_source_unavailable}

        true ->
          case bundle_result(source) do
            {:ok, %{trust_domain: td, root_certificates: roots} = bundle}
            when is_binary(td) and td != "" and is_list(roots) ->
              clean_roots = Enum.filter(roots, &is_binary/1)

              if clean_roots == [] do
                {:refuse, 503, :trust_bundle_empty}
              else
                {:ok,
                 %{
                   trust_domain: td,
                   roots: clean_roots,
                   intermediates: clean_intermediates(bundle)
                 }}
              end

            _ ->
              {:refuse, 503, :trust_bundle_unavailable}
          end
      end
    end

    defp bundle_result(source) do
      source.bundle()
    catch
      _kind, _reason -> {:error, :bundle_raised}
    end

    defp clean_intermediates(%{intermediate_certificates: inters}) when is_list(inters) do
      Enum.filter(inters, &is_binary/1)
    end

    defp clean_intermediates(_), do: []

    defp peer_certificate(conn) do
      case Plug.Conn.get_peer_data(conn) do
        %{ssl_cert: der} when is_binary(der) and der != "" -> {:ok, der}
        _ -> {:refuse, 401, :missing_svid}
      end
    rescue
      _ -> {:refuse, 401, :missing_svid}
    end

    defp decode_svid(der) do
      {:ok, :public_key.pkix_decode_cert(der, :otp)}
    rescue
      _ -> {:refuse, 401, :svid_malformed}
    end

    defp svid_spiffe_uri(otp_cert) do
      # :otp-mode record layout: element 1 is tbsCertificate; extensions is the
      # 10th field of OTPTBSCertificate. In :otp mode known extension values are
      # already decoded, so SAN entries are {:uniformResourceIdentifier, charlist}.
      tbs = elem(otp_cert, 1)

      uris =
        for {:Extension, {2, 5, 29, 17}, _critical, entries} <- elem(tbs, 10) |> List.wrap(),
            {:uniformResourceIdentifier, uri} <- List.wrap(entries) do
          to_string(uri)
        end

      spiffe = Enum.filter(uris, &String.starts_with?(&1, "spiffe://"))

      cond do
        spiffe == [] -> {:refuse, 401, :svid_identity_absent}
        tl(spiffe) != [] -> {:refuse, 401, :svid_multiple_uris}
        true -> {:ok, hd(spiffe)}
      end
    end

    defp parse_identity(spiffe_uri) do
      case Identity.parse(spiffe_uri) do
        {:ok, identity} -> {:ok, identity}
        {:error, _} -> {:refuse, 401, :svid_malformed}
      end
    end

    defp check_trust_domain(%Identity{trust_domain: td}, td), do: :ok
    defp check_trust_domain(_identity, _td), do: {:refuse, 401, :trust_domain_mismatch}

    defp workload_or_refuse(identity) do
      case workload(identity) do
        {:ok, _wl} -> {:ok, identity}
        {:error, reason} -> {:refuse, 401, reason}
      end
    end

    defp validate_chain(svid_der, %{roots: roots, intermediates: inters}) do
      # pkix_path_validation/3 takes the path as [anchor's child..., leaf]:
      # the first element is the certificate signed by the trust anchor and the
      # SVID must be last (last_cert=true skips the CA keyUsage check for it).
      path = inters ++ [svid_der]

      results =
        for root <- roots do
          {root,
           case :public_key.pkix_path_validation(root, path, []) do
             {:ok, _state} -> {:ok, root}
             {:error, {:bad_cert, :cert_expired}} -> :svid_expired
             {:error, _other} -> :svid_untrusted
           end}
        end

      case Enum.find(results, &match?({_root, {:ok, _}}, &1)) do
        {root, {:ok, _root_der}} ->
          {:ok, root}

        _ ->
          # Expiry is reported ahead of distrust: an SVID whose own chain is
          # time-expired is expired even when no anchor matched.
          if Enum.any?(results, &match?({_root, :svid_expired}, &1)) do
            {:refuse, 401, :svid_expired}
          else
            {:refuse, 401, :svid_untrusted}
          end
      end
    end

    # -- Refusal response ----------------------------------------------------------

    @reason_strings %{
      missing_svid: "missing_svid",
      svid_malformed: "svid_malformed",
      svid_expired: "svid_expired",
      svid_untrusted: "svid_untrusted",
      svid_identity_absent: "svid_identity_absent",
      svid_multiple_uris: "svid_multiple_uris",
      trust_domain_mismatch: "trust_domain_mismatch",
      identity_path_invalid: "identity_path_invalid",
      bundle_source_unavailable: "bundle_source_unavailable",
      trust_bundle_unavailable: "trust_bundle_unavailable",
      trust_bundle_empty: "trust_bundle_empty"
    }

    defp refuse(conn, status, reason) when status in [401, 503] do
      body = %{"error" => "spiffe_svid_refused", "reason" => Map.fetch!(@reason_strings, reason)}

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
      |> halt()
    end
  end
end
