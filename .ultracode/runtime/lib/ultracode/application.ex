defmodule Ultracode.Application do
  @moduledoc """
  Durable Ultracode operating-loop application: real Postgres-backed
  `Ultracode.Run`/`Ultracode.Epoch` state plus a real `AshOban` scheduler
  that survives terminal/session death (`TerminalDeath ⇏ LoopDeath`),
  provided this application itself stays running -- that is the real
  durability boundary this design buys, not an unconditional guarantee.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Ultracode.Repo,
      {Oban, Application.fetch_env!(:ultracode, Oban)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Ultracode.Supervisor)
  end
end
