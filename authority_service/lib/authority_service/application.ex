defmodule AuthorityService.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:authority_service, :start_service, false),
        do: AuthorityService.Runtime.children(),
        else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: AuthorityService.Supervisor)
  end
end
