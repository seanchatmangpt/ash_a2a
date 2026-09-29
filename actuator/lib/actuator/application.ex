defmodule Actuator.Application do
  @moduledoc """
  Starts the Store and the configured wire listeners when `:start_server` is true (releases
  read `ACTUATOR_CONFIG`; there is no default: a missing config is a boot refusal).
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = if Application.get_env(:actuator, :start_server, false), do: server(), else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Actuator.Supervisor)
  end

  defp server do
    path = System.get_env("ACTUATOR_CONFIG") || raise "ACTUATOR_CONFIG is required"
    ctx_fun = fn -> Actuator.Config.load(path) end
    {:ok, ctx} = ctx_fun.()
    raw = path |> File.read!() |> Jason.decode!()
    wire = raw["wire"] || %{}

    [{Actuator.Store, [state_dir: ctx.state_dir, name: Actuator.Store]}] ++
      uds(wire["uds_path"], ctx_fun) ++ tls(wire["tls"], ctx_fun)
  end

  defp uds(nil, _), do: []

  defp uds(p, f),
    do: [
      %{
        id: :uds,
        start: {Actuator.Wire.UDS, :start_link, [[path: p, store: Actuator.Store, ctx_fun: f]]}
      }
    ]

  defp tls(nil, _), do: []

  defp tls(t, f) do
    o = [
      store: Actuator.Store,
      ctx_fun: f,
      port: t["port"],
      certfile: t["certfile"],
      keyfile: t["keyfile"],
      cacertfile: t["cacertfile"]
    ]

    [%{id: :tls, start: {Actuator.Wire.TLS, :start_link, [o]}}]
  end
end
