defmodule AshA2A.Transport.GRPC.Supervisor do
  @moduledoc """
  Supervised owner of the A2A gRPC listener (`AshA2A.Transport.GRPC.Server`).

  A host (or `AshA2A.Application`, for a domain with a `:grpc` mount) adds it
  to a supervision tree:

      children = [
        {AshA2A.Transport.GRPC.Supervisor,
         port: 50051,
         handler: MyApp.A2APlug,
         ctx: %{agent: MyAgent, opts: []}}
      ]

  Options:

    * `:port` - listen port; `0` picks an ephemeral port (see `port/1`).
      Default `50051`.
    * `:endpoint` - `GRPC.Endpoint` module, default
      `AshA2A.Transport.GRPC.Server.Endpoint`.
    * `:handler` / `:ctx` / `:versions` / `:extensions` - written into the
      `AshA2A.Transport.GRPC.Server` application env (see its moduledoc).
    * `:auth` - `{module, opts}` interceptor, written into the endpoint env.
    * `:cred` - `GRPC.Credential.new(ssl: [...])` for TLS; plain HTTP/2 when
      absent.
    * `:name` - registered name of this process.

  The listener starts in `init/1` and is stopped when the process terminates,
  so a crash or shutdown releases the port. `start_link/1` returns
  `{:error, reason}` when the listener cannot bind.
  """

  use GenServer

  @default_port 50_051

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    gen_opts = if name = opts[:name], do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The bound port (useful when started with `port: 0`)."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    endpoint = Keyword.get(opts, :endpoint, AshA2A.Transport.GRPC.Server.Endpoint)
    port = Keyword.get(opts, :port, @default_port)

    put_server_env(opts)
    put_endpoint_env(endpoint, opts)

    start_opts = if cred = opts[:cred], do: [cred: cred], else: []

    case GRPC.Server.start_endpoint(endpoint, port, start_opts) do
      {:ok, _pid, bound} -> {:ok, %{endpoint: endpoint, port: bound}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, %{endpoint: endpoint}) do
    GRPC.Server.stop_endpoint(endpoint)
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp put_server_env(opts) do
    kw =
      for key <- [:handler, :ctx, :versions, :extensions],
          Keyword.has_key?(opts, key),
          do: {key, opts[key]}

    if kw != [] do
      existing = Application.get_env(:ash_a2a, AshA2A.Transport.GRPC.Server, [])
      Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server, Keyword.merge(existing, kw))
    end
  end

  # The Server reads its auth seam from the default endpoint's env key
  # regardless of which endpoint module hosts it.
  defp put_endpoint_env(_endpoint, opts) do
    if auth = opts[:auth] do
      key = AshA2A.Transport.GRPC.Server.Endpoint
      existing = Application.get_env(:ash_a2a, key, [])
      Application.put_env(:ash_a2a, key, Keyword.put(existing, :auth, auth))
    end
  end
end
