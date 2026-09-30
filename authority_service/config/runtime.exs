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

  config :authority_service, :runtime,
    key_path: System.get_env("AUTHORITY_KEY_FILE", "/etc/authority/key/policy.key"),
    policy_path: Path.join(dir, "policy/policy.json"),
    registry_path: Path.join(dir, "policy/approvers.json"),
    authority_audience: System.get_env("AUTHORITY_AUDIENCE", "authority:default"),
    # registered actuator identity (server-side); unset => config refused, release stops
    actuator_audience: System.get_env("AUTHORITY_ACTUATOR_AUDIENCE"),
    journal_path: System.get_env("AUTHORITY_JOURNAL", "/var/lib/authority/journal.log"),
    transport: transport
end
