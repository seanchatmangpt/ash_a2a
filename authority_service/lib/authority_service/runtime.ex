defmodule AuthorityService.Runtime do
  @moduledoc """
  Production wiring from `config :authority_service, :runtime` (see config/runtime.exs).
  The environment supplies file PATHS only; the policy key is read from a 0600 file.
  A configuration that cannot load stops the release (fail closed).
  """
  alias AuthorityService.{Config, Issuer, Listener}

  def children do
    rt = Application.fetch_env!(:authority_service, :runtime)

    case Config.from_files(
           Keyword.take(rt, [
             :key_path,
             :policy_path,
             :registry_path,
             :authority_audience,
             :journal_path
           ])
         ) do
      {:ok, config} ->
        [
          %{id: Issuer, start: {Issuer, :start_link, [[config: config, name: Issuer]]}},
          %{
            id: Listener,
            start:
              {Listener, :start_link,
               [
                 [
                   issuer: Issuer,
                   transport: Keyword.fetch!(rt, :transport),
                   max_bytes: Keyword.get(rt, :max_bytes, 65_536)
                 ]
               ]}
          }
        ]

      {:error, reason} ->
        raise "authority_service: configuration refused: #{inspect(reason)}"
    end
  end
end
