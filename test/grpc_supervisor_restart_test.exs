defmodule AshA2A.GRPCSupervisorRestartTest.Endpoint do
  @moduledoc false
  use GRPC.Endpoint

  run(AshA2A.Transport.GRPC.Server)
end

defmodule AshA2A.GRPCSupervisorRestartTest do
  @moduledoc """
  `AshA2A.Transport.GRPC.Supervisor` starts on an endpoint whose previous
  listener is still being stopped.

  Stopping a listener is two steps in ranch: terminate the listener (which
  waits for its open connections) and delete its child spec. A start that
  lands between them is answered `:already_present`. That window was the
  intermittent `failed to start child ... :already_present` of the gRPC tests
  (run 5 of 40, seed 23388, of `test/grpc_generation_gaps_test.exs`): the
  previous test's listener was still draining a long-poll connection when the
  supervisor's 5 s shutdown expired. The window is entered here on purpose,
  with the real ranch supervisor, instead of waiting for it.
  """

  use ExUnit.Case, async: false

  alias AshA2A.GRPCSupervisorRestartTest.Endpoint
  alias AshA2A.Transport.GRPC.Supervisor, as: GRPCSupervisor

  @listener {:ranch_listener_sup, inspect(Endpoint)}

  test "a listener left terminated but not deleted does not fail the next start" do
    {:ok, first} = GRPCSupervisor.start_link(endpoint: Endpoint, port: 0)
    assert GRPCSupervisor.port(first) > 0

    # Step one of ranch's stop only: the child spec stays registered.
    :ok = :supervisor.terminate_child(:ranch_sup, @listener)
    assert {:error, :already_present} = :supervisor.start_child(:ranch_sup, listener_spec())

    {:ok, second} = GRPCSupervisor.start_link(endpoint: Endpoint, port: 0)
    port = GRPCSupervisor.port(second)
    assert port > 0

    # The new listener really accepts connections.
    assert {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 2_000)
    :gen_tcp.close(socket)

    GenServer.stop(second)
    Process.unlink(first)
    Process.exit(first, :kill)
  end

  test "the child spec gives the listener time to drain before the supervisor is killed" do
    assert %{shutdown: shutdown} = GRPCSupervisor.child_spec(port: 0)
    # ranch gives each open connection up to 5 s.
    assert shutdown > 5_000
  end

  test "the listener's last route answers unknown gRPC methods" do
    start_supervised!({GRPCSupervisor, endpoint: Endpoint, port: 0})

    assert [{_host, _constraints, paths}] =
             :persistent_term.get(Module.concat(Endpoint, Dispatch))

    assert {:_, [], AshA2A.Transport.GRPC.UnknownMethod, %{}} = List.last(paths)

    # Installing twice adds nothing.
    assert :ok = AshA2A.Transport.GRPC.UnknownMethod.install(Endpoint)
    assert [{_, _, ^paths}] = :persistent_term.get(Module.concat(Endpoint, Dispatch))
  end

  defp listener_spec do
    %{id: @listener, start: {:erlang, :apply, [fn -> :ignore end, []]}}
  end
end
