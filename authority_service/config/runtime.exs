import Config

if config_env() == :prod do
  # Paths only. Key material is read from AUTHORITY_KEY_FILE (0600), never from env.
  dir = System.get_env("AUTHORITY_CONFIG_DIR", "/etc/authority")

  transport =
    case System.get_env("AUTHORITY_LISTEN_UNIX") do
      nil ->
        {:tls, String.to_integer(System.get_env("AUTHORITY_PORT", "8443")),
         [
           certfile: Path.join(dir, "tls/tls.crt"),
           keyfile: Path.join(dir, "tls/tls.key"),
           cacertfile: Path.join(dir, "tls/ca.crt")
         ]}

      path ->
        {:unix, path}
    end

  # Optional mTLS listener alongside the UDS one: set AUTHORITY_LISTEN_UNIX and AUTHORITY_TLS_PORT.
  tls_transport =
    with path when is_binary(path) <- System.get_env("AUTHORITY_LISTEN_UNIX"),
         port when is_binary(port) <- System.get_env("AUTHORITY_TLS_PORT") do
      {:tls, String.to_integer(port),
       [
         certfile: Path.join(dir, "tls/tls.crt"),
         keyfile: Path.join(dir, "tls/tls.key"),
         cacertfile: Path.join(dir, "tls/ca.crt")
       ]}
    else
      _ -> nil
    end

  # Revocation epoch the service key stands at (an integer, not key material). Unset => 0.
  # A value that is not a non-negative integer is passed through and refused by Config.
  key_revocation_epoch =
    case System.get_env("AUTHORITY_KEY_REVOCATION_EPOCH") do
      nil ->
        nil

      v ->
        case Integer.parse(v) do
          {n, ""} -> n
          _ -> v
        end
    end

  config :authority_service, :runtime,
    key_path: System.get_env("AUTHORITY_KEY_FILE", "/etc/authority/key/policy.key"),
    key_revocation_epoch: key_revocation_epoch,
    policy_path: Path.join(dir, "policy/policy.json"),
    registry_path: Path.join(dir, "policy/approvers.json"),
    authority_audience: System.get_env("AUTHORITY_AUDIENCE", "authority:default"),
    # registered actuator identity (server-side); unset => config refused, release stops
    actuator_audience: System.get_env("AUTHORITY_ACTUATOR_AUDIENCE"),
    journal_path: System.get_env("AUTHORITY_JOURNAL", "/var/lib/authority/journal.log"),
    transport: transport,
    tls_transport: tls_transport
end
