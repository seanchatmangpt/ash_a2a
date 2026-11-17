defmodule AuthorityService.Runtime do
  @moduledoc """
  Production wiring from `config :authority_service, :runtime` (see config/runtime.exs).
  The environment supplies file PATHS only; the policy key is read from a 0600 file.
  A configuration that cannot load stops the release (fail closed).
  """
  alias AuthorityService.{ApproverChannel.Mailbox, Config, Issuer, Listener}

  def children do
    rt = Application.fetch_env!(:authority_service, :runtime)

    case Config.from_files(
           Keyword.take(rt, [
             :key_path,
             :key_revocation_epoch,
             :policy_path,
             :registry_path,
             :authority_audience,
             :actuator_audience,
             :journal_path
           ])
         ) do
      {:ok, config} ->
        config = %{config | channel: {Mailbox, Mailbox}}

        [
          %{
            id: Mailbox,
            start:
              {Mailbox, :start_link,
               [
                 [
                   name: Mailbox,
                   verify: [
                     registry: config.approver_registry,
                     audience: config.authority_audience,
                     skew: config.policy.skew
                   ]
                 ]
               ]}
          },
          %{id: Issuer, start: {Issuer, :start_link, [[config: config, name: Issuer]]}}
        ] ++
          Enum.map(transports(rt), fn {id, transport} ->
            %{
              id: id,
              start:
                {Listener, :start_link,
                 [
                   [
                     issuer: Issuer,
                     mailbox: Mailbox,
                     transport: transport,
                     max_bytes: Keyword.get(rt, :max_bytes, 65_536)
                   ]
                 ]}
            }
          end)

      {:error, reason} ->
        raise "authority_service: configuration refused: #{inspect(reason)}"
    end
  end

  # The primary transport, plus an OPTIONAL second TLS listener (`:tls_transport`, same
  # `{:tls, port, [certfile:, keyfile:, cacertfile:]}` shape) so UDS and mutual TLS can serve
  # side by side. Each listener has its own 64-connection cap.
  defp transports(rt) do
    primary = [{Listener, Keyword.fetch!(rt, :transport)}]

    case Keyword.get(rt, :tls_transport) do
      {:tls, _, _} = t -> primary ++ [{{Listener, :tls}, t}]
      _ -> primary
    end
  end
end
