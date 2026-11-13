defmodule AshA2A.ApplicationSupervisionWiringTest do
  use ExUnit.Case, async: false

  alias AshA2A.Application, as: App

  setup do
    prev_grpc = Application.fetch_env(:ash_a2a, :grpc)
    prev_server = Application.fetch_env(:ash_a2a, AshA2A.Transport.GRPC.Server)

    on_exit(fn ->
      restore(:grpc, prev_grpc)
      restore(AshA2A.Transport.GRPC.Server, prev_server)
    end)

    :ok
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:ash_a2a, key, v)
  defp restore(key, :error), do: Application.delete_env(:ash_a2a, key)

  test "no grpc config adds no child" do
    Application.delete_env(:ash_a2a, :grpc)
    assert App.grpc_children() == []

    Application.put_env(:ash_a2a, :grpc, port: 0)
    assert App.grpc_children() == []
  end

  test "attach_otel never raises" do
    assert App.attach_otel() in [:ok, {:error, :opentelemetry_not_loaded}] or
             match?({:error, _}, App.attach_otel())
  end

  test "grpc config (keyword and map) yields the supervisor child" do
    Application.put_env(:ash_a2a, :grpc, port: 0, handler: __MODULE__)
    assert [{AshA2A.Transport.GRPC.Supervisor, opts}] = App.grpc_children()
    assert opts[:port] == 0

    Application.put_env(:ash_a2a, :grpc, %{port: 0, handler: __MODULE__})
    assert [{AshA2A.Transport.GRPC.Supervisor, opts}] = App.grpc_children()
    assert opts[:handler] == __MODULE__
  end

  test "child starts under an isolated supervisor on an ephemeral port" do
    name = :"w22_grpc_#{System.unique_integer([:positive])}"
    Application.put_env(:ash_a2a, :grpc, port: 0, handler: __MODULE__, name: name)

    [child] = App.grpc_children()
    {:ok, sup} = Supervisor.start_link([child], strategy: :one_for_one)

    port = AshA2A.Transport.GRPC.Supervisor.port(name)
    assert is_integer(port) and port > 0

    Supervisor.stop(sup)
    refute Process.whereis(name)
  end
end
