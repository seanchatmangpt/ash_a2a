defmodule C2Harness.ControlPlane do
  @moduledoc """
  Everything the ATTACKER (arbitrary code playing the compromised control-plane node) is
  given. By construction it holds: socket paths and the mTLS port it dials, its own
  client credential files, the public key registry, protocol constants, and the private
  keys of the signers the threat model explicitly compromises (`compromised`: "A"/"A2" of
  custodian custA, approver "alice": fewer than k). It holds no authority or actuator
  private key, no key file path and no state directory.
  """
  defstruct [
    :actuator_sock,
    :authority_sock,
    :tls_port,
    :tls_client_cert,
    :tls_client_key,
    :tls_server_ca,
    :rogue_client_cert,
    :rogue_client_key,
    :audience,
    :authority_audience,
    :policy_epoch,
    :revocation_epoch,
    :public_registry,
    :max_frame,
    compromised: %{}
  ]

  @type t :: %__MODULE__{}
end

defmodule C2Harness.Fleet do
  @moduledoc """
  Boots and controls the separate OS processes of one court run:

    * KEYMASTER (`authority_service` project, test env): holds every private key, writes the
      operator-side files, signs on request
    * ACTUATOR (`actuator` project, test env, instrumented host): the real `Actuator.Store`
      and UDS/mTLS wire from a pinned config, own state dir, crash points and mutants
    * AUTHORITY (`authority_service` project, prod env): the real `AuthorityService`
      release entrypoint over a unix socket

  Hosting scope, recorded honestly in every report: **separate-process, same-host, same OS
  uid**. State directories are mode 0700 and never handed to the attacker API, but the
  attacker is the test process running as the same uid, so an attacker that ignores the
  API and opens the state directory is outside what this court can constrain (a separate
  OS user or cluster is an operator/infra follow-up). Erlang distribution is disabled: no
  child is started with `--name/--sname`, `ERL_FLAGS=-start_epmd false`, and each child
  reports `Node.alive?() == false` in its READY line.
  """
  use GenServer
  alias C2Harness.{ControlPlane, Proc, Wire}

  @root Path.expand("../../..", __DIR__)
  @support Path.expand(".", __DIR__)
  @audience "actuator:court"
  @authority_audience "authority:court"
  @policy_epoch 3
  @revocation_epoch 7

  def repo_root, do: @root
  def audience, do: @audience
  def authority_audience, do: @authority_audience
  def policy_epoch, do: @policy_epoch
  def revocation_epoch, do: @revocation_epoch

  # ---- build ------------------------------------------------------------------

  @builds [
    {"actuator", "test", "actuator-test"},
    {"actuator", "prod", "actuator-prod"},
    {"authority_service", "test", "authority-test"},
    {"authority_service", "prod", "authority-prod"}
  ]

  @doc "Compile each child project once into its own build root. Raises on failure."
  def ensure_built(build_root) do
    for {proj, env, name} <- @builds do
      {out, code} =
        System.cmd("mix", ["compile"],
          cd: Path.join(@root, proj),
          env: [{"MIX_ENV", env}, {"MIX_BUILD_ROOT", Path.join(build_root, name)}],
          stderr_to_stdout: true
        )

      if code != 0,
        do: raise("child build failed #{proj}/#{env}: #{String.slice(out, -1500, 1500)}")
    end

    :ok
  end

  def default_build_root do
    System.get_env("C2_COURT_BUILD_ROOT") || Path.join(System.tmp_dir!(), "c2-court-build")
  end

  # ---- lifecycle -----------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, timeout: 600_000)
  end

  def stop(fleet) do
    GenServer.call(fleet, :stop, 60_000)
  catch
    :exit, _ -> :ok
  end

  def info(fleet), do: GenServer.call(fleet, :info)

  def start_actuator(fleet, opts \\ []),
    do: GenServer.call(fleet, {:start_actuator, opts}, 180_000)

  def kill_actuator(fleet), do: GenServer.call(fleet, :kill_actuator, 60_000)
  def actuator_pid(fleet), do: GenServer.call(fleet, :actuator_pid)
  def start_authority(fleet), do: GenServer.call(fleet, :start_authority, 180_000)
  def kill_authority(fleet), do: GenServer.call(fleet, :kill_authority, 60_000)
  def authority_pid(fleet), do: GenServer.call(fleet, :authority_pid)
  def control_plane(fleet), do: GenServer.call(fleet, :control_plane)
  def actuator_alive?(fleet), do: GenServer.call(fleet, :actuator_alive?)

  @doc "Operator action: write the actuator's revocation view (`:delete` removes the file)."
  def write_revocation(fleet, view), do: GenServer.call(fleet, {:write_revocation, view})

  @doc "Operator action: arm (`point`) or disarm (`nil`) an actuator crash point."
  def arm_crash(fleet, point), do: GenServer.call(fleet, {:arm_crash, point})

  @doc """
  Start the actuator through its PRODUCTION entrypoint (`MIX_ENV=prod mix run --no-halt`,
  `Actuator.Application` starts the Store and listeners from `ACTUATOR_CONFIG`; no court
  script, no fault hook compiled in). Options: `config: false` omits `ACTUATOR_CONFIG` (the
  entrypoint must refuse to boot), `env: [{name, value}]` extra child environment.
  """
  def start_prod_actuator(fleet, opts \\ []),
    do: GenServer.call(fleet, {:start_prod_actuator, opts}, 180_000)

  @doc "The fault point the actuator is currently parked at (rendezvous), or nil."
  def at_fault(fleet), do: GenServer.call(fleet, :at_fault)

  @doc "Ask the keymaster to sign/issue/approve. Returns the decoded reply."
  def km(fleet, req), do: GenServer.call(fleet, {:km, req}, 60_000)

  @impl true
  def init(opts) do
    root =
      Path.join(
        System.tmp_dir!(),
        "c2-" <> Base.url_encode64(:crypto.strong_rand_bytes(5), padding: false)
      )

    dirs = for d <- ~w(act auth cp km sock), into: %{}, do: {d, Path.join(root, d)}
    for {_, d} <- dirs, do: File.mkdir_p!(d)
    for d <- ~w(act auth km), do: File.chmod!(dirs[d], 0o700)
    # sockets live OUTSIDE the state-owning directories: the attacker must know a socket
    # path, and the key-material scan treats the act/auth/km directory paths as protected
    # (an earlier layout put the sockets under act/ and auth/ and the scan caught it)
    File.mkdir_p!(Path.join(dirs["act"], "state"))
    File.mkdir_p!(Path.join(dirs["act"], "ctl"))

    build_root = Keyword.get(opts, :build_root, default_build_root())
    unless Keyword.get(opts, :skip_build, false), do: ensure_built(build_root)

    st = %{
      root: root,
      dirs: dirs,
      build_root: build_root,
      km_sock: Path.join(dirs["km"], "k.sock"),
      act_sock: Path.join(dirs["sock"], "act.sock"),
      auth_sock: Path.join(dirs["sock"], "auth.sock"),
      cfg_path: Path.join(dirs["act"], "config.json"),
      state_dir: Path.join(dirs["act"], "state"),
      ctl_dir: Path.join(dirs["act"], "ctl"),
      auth_journal: Path.join(dirs["auth"], "journal.log"),
      tls_port: free_port(),
      km: nil,
      hello: nil,
      actuator: nil,
      authority: nil,
      compromised: %{},
      mutant_skip: Keyword.get(opts, :mutant_skip, []),
      procs_log: Path.join(root, "logs")
    }

    with {:ok, kmp} <-
           Proc.start("keymaster", Path.join(@root, "authority_service"),
             script: Path.join(@support, "keymaster_child.exs"),
             log: Path.join(st.procs_log, "keymaster.log"),
             env:
               child_env("test", Path.join(build_root, "authority-test")) ++
                 [
                   {"KM_ACT_DIR", dirs["act"]},
                   {"KM_AUTH_DIR", dirs["auth"]},
                   {"KM_CP_DIR", dirs["cp"]},
                   {"KM_DIR", dirs["km"]},
                   {"KM_SOCK", st.km_sock},
                   {"KM_ACTUATOR_AUDIENCE", @audience}
                 ]
           ),
         {:ok, hello} <- Wire.lp(st.km_sock, %{"op" => "hello"}) do
      st = %{st | km: kmp, hello: hello}
      write_config!(st)

      write_revocation_file!(st, %{
        "refreshed_at" => now(),
        "epoch" => @revocation_epoch,
        "revoked" => []
      })

      case Keyword.get(opts, :actuator, true) && do_start_actuator(st, []) do
        false -> {:ok, st}
        {:ok, st} -> maybe_authority(st, opts)
        {:error, why} -> {:stop, {:actuator_start_failed, why}}
      end
    else
      {:error, why} -> {:stop, {:keymaster_start_failed, why}}
      other -> {:stop, {:keymaster_start_failed, other}}
    end
  end

  defp maybe_authority(st, opts) do
    if Keyword.get(opts, :authority, false) do
      case do_start_authority(st) do
        {:ok, st} -> {:ok, st}
        {:error, why} -> {:stop, {:authority_start_failed, why}}
      end
    else
      {:ok, st}
    end
  end

  # ---- callbacks -------------------------------------------------------------------

  @impl true
  def handle_call(:info, _, st) do
    {:reply,
     Map.take(st, [
       :root,
       :dirs,
       :km_sock,
       :act_sock,
       :auth_sock,
       :cfg_path,
       :state_dir,
       :auth_journal,
       :tls_port,
       :hello,
       :build_root,
       :procs_log
     ]), st}
  end

  def handle_call({:start_actuator, opts}, _, st) do
    case do_start_actuator(st, opts) do
      {:ok, st} -> {:reply, :ok, st}
      {:error, why} -> {:reply, {:error, why}, st}
    end
  end

  def handle_call({:start_prod_actuator, opts}, _, st) do
    Proc.stop(st.actuator)
    _ = File.rm(st.act_sock)

    config_env =
      if Keyword.get(opts, :config, true), do: [{"ACTUATOR_CONFIG", st.cfg_path}], else: []

    result =
      Proc.start("actuator-prod", Path.join(@root, "actuator"),
        script: Path.join(@support, "watchdog.exs"),
        log: Path.join(st.procs_log, "actuator-prod-#{System.unique_integer([:positive])}.log"),
        env:
          child_env("prod", Path.join(st.build_root, "actuator-prod")) ++
            config_env ++ Keyword.get(opts, :env, []),
        timeout: 60_000,
        ready:
          {:poll,
           fn ->
             match?({:ok, %{"ok" => true}}, Wire.uds(st.act_sock, ~s({"op":"health"}), 1_000))
           end}
      )

    case result do
      {:ok, p} -> {:reply, {:ok, p.os_pid}, %{st | actuator: p}}
      {:error, why} -> {:reply, {:error, why}, %{st | actuator: nil}}
    end
  end

  def handle_call(:kill_actuator, _, st) do
    Proc.stop(st.actuator)
    {:reply, :ok, %{st | actuator: nil}}
  end

  def handle_call(:actuator_pid, _, st), do: {:reply, st.actuator && st.actuator.os_pid, st}

  def handle_call(:actuator_alive?, _, st),
    do: {:reply, st.actuator != nil and Proc.alive?(st.actuator), st}

  def handle_call(:start_authority, _, st) do
    case do_start_authority(st) do
      {:ok, st} -> {:reply, :ok, st}
      {:error, why} -> {:reply, {:error, why}, st}
    end
  end

  def handle_call(:kill_authority, _, st) do
    Proc.stop(st.authority)
    {:reply, :ok, %{st | authority: nil}}
  end

  def handle_call(:authority_pid, _, st), do: {:reply, st.authority && st.authority.os_pid, st}

  def handle_call({:write_revocation, :delete}, _, st) do
    File.rm(Path.join(st.state_dir, "revocation.json"))
    {:reply, :ok, st}
  end

  def handle_call({:write_revocation, view}, _, st) do
    defaults = %{"refreshed_at" => now(), "epoch" => @revocation_epoch, "revoked" => []}
    write_revocation_file!(st, Map.merge(defaults, view))
    {:reply, :ok, st}
  end

  def handle_call(:at_fault, _, st) do
    case File.read(Path.join(st.ctl_dir, "at_fault")) do
      {:ok, point} -> {:reply, String.trim(point), st}
      _ -> {:reply, nil, st}
    end
  end

  def handle_call({:arm_crash, point}, _, st) do
    path = Path.join(st.ctl_dir, "crash.point")

    if point do
      File.write!(path, Atom.to_string(point))
    else
      File.rm(path)
    end

    {:reply, :ok, st}
  end

  def handle_call({:km, req}, _, st), do: {:reply, Wire.lp(st.km_sock, req), st}

  def handle_call(:control_plane, _, st) do
    {comp, st} = compromised(st)
    h = st.hello
    d = st.dirs["cp"]

    cp = %ControlPlane{
      actuator_sock: st.act_sock,
      authority_sock: st.auth_sock,
      tls_port: st.tls_port,
      tls_client_cert: Path.join(d, "client.crt"),
      tls_client_key: Path.join(d, "client.key"),
      tls_server_ca: Path.join(d, "server_ca.crt"),
      rogue_client_cert: Path.join(d, "rogue_client.crt"),
      rogue_client_key: Path.join(d, "rogue_client.key"),
      audience: @audience,
      authority_audience: @authority_audience,
      policy_epoch: @policy_epoch,
      revocation_epoch: @revocation_epoch,
      public_registry: %{signers: h["signers"], approvers: h["approvers"]},
      max_frame: 131_072,
      compromised: comp
    }

    {:reply, cp, st}
  end

  def handle_call(:stop, _, st) do
    Proc.stop(st.actuator)
    Proc.stop(st.authority)
    Proc.stop(st.km)
    File.rm_rf(st.root)
    {:stop, :normal, :ok, st}
  end

  @impl true
  def handle_info(_msg, st), do: {:noreply, st}

  # ---- internals -------------------------------------------------------------------

  defp compromised(%{compromised: c} = st) when map_size(c) > 0, do: {c, st}

  defp compromised(st) do
    c =
      for name <- ["A", "A2", "alice"], into: %{} do
        {:ok, %{"ok" => true, "private_key" => p, "kid" => kid}} =
          Wire.lp(st.km_sock, %{"op" => "compromise", "name" => name})

        {name, %{priv: Base.url_decode64!(p, padding: false), kid: kid}}
      end

    {c, %{st | compromised: c}}
  end

  defp child_env(mix_env, build_root) do
    [
      {"MIX_ENV", mix_env},
      {"MIX_BUILD_ROOT", build_root},
      {"ERL_FLAGS", "-start_epmd false"},
      {"RELEASE_DISTRIBUTION", "none"},
      {"C2_PARENT_PID", System.pid()}
    ]
  end

  defp do_start_actuator(st, opts) do
    Proc.stop(st.actuator)
    _ = File.rm(st.act_sock)
    _ = opts
    skip = st.mutant_skip
    skip_env = if skip == :all, do: "all", else: Enum.join(skip, ",")

    File.rm(Path.join(st.ctl_dir, "crash.point"))
    File.rm(Path.join(st.ctl_dir, "at_fault"))

    case Proc.start("actuator", Path.join(@root, "actuator"),
           script: Path.join(@support, "actuator_child.exs"),
           log: Path.join(st.procs_log, "actuator-#{System.unique_integer([:positive])}.log"),
           env:
             child_env("test", Path.join(st.build_root, "actuator-test")) ++
               [
                 {"ACTUATOR_CONFIG", st.cfg_path},
                 {"C2_CTL_DIR", st.ctl_dir},
                 {"C2_FAULT_RENDEZVOUS", "1"},
                 {"ACTUATOR_MUTANT_SKIP", skip_env}
               ]
         ) do
      {:ok, p} ->
        if p.ready["node_alive"] != false,
          do: raise("actuator child has Erlang distribution alive")

        {:ok, %{st | actuator: p}}

      {:error, why} ->
        {:error, why}
    end
  end

  defp do_start_authority(st) do
    Proc.stop(st.authority)
    _ = File.rm(st.auth_sock)
    a = st.dirs["auth"]

    case Proc.start("authority", Path.join(@root, "authority_service"),
           script: Path.join(@support, "watchdog.exs"),
           log: Path.join(st.procs_log, "authority-#{System.unique_integer([:positive])}.log"),
           env:
             child_env("prod", Path.join(st.build_root, "authority-prod")) ++
               [
                 {"AUTHORITY_KEY_FILE", Path.join([a, "key", "policy.key"])},
                 {"AUTHORITY_CONFIG_DIR", a},
                 {"AUTHORITY_LISTEN_UNIX", st.auth_sock},
                 {"AUTHORITY_AUDIENCE", @authority_audience},
                  {"AUTHORITY_ACTUATOR_AUDIENCE", @audience},
                 {"AUTHORITY_JOURNAL", st.auth_journal}
               ],
           ready:
             {:poll,
              fn ->
                match?(
                  {:ok, %{"refusal" => "unknown_op"}},
                  Wire.lp(st.auth_sock, %{"op" => "probe"}, 2_000)
                )
              end}
         ) do
      {:ok, p} -> {:ok, %{st | authority: p}}
      {:error, why} -> {:error, why}
    end
  end

  defp write_config!(st) do
    signers =
      for s <- st.hello["signers"],
          do: Map.take(s, ~w(kid alg public_key custodian_id custody_tier state revocation_epoch))

    cfg = %{
      "state_dir" => st.state_dir,
      "audience" => @audience,
      "policy_epoch" => @policy_epoch,
      "allowed_subjects" => ["subject:orders/42"],
      "quorum" => %{"internal_append" => 2, "none" => 2},
      "quorum_default" => 2,
      "skew" => 30,
      "max_ttl" => 900,
      "max_revocation_staleness" => 300,
      "registry" => signers,
      "wire" => %{
        "uds_path" => st.act_sock,
        "tls" => %{
          "port" => st.tls_port,
          "certfile" => Path.join([st.dirs["act"], "tls", "server.crt"]),
          "keyfile" => Path.join([st.dirs["act"], "tls", "server.key"]),
          "cacertfile" => Path.join([st.dirs["act"], "tls", "client_ca.crt"])
        }
      }
    }

    File.write!(st.cfg_path, Jason.encode!(cfg))
    File.chmod!(st.cfg_path, 0o600)
  end

  defp write_revocation_file!(st, view) do
    File.write!(Path.join(st.state_dir, "revocation.json"), Jason.encode!(view))
  end

  defp free_port do
    {:ok, s} = :gen_tcp.listen(0, [])
    {:ok, p} = :inet.port(s)
    :gen_tcp.close(s)
    p
  end

  defp now, do: System.os_time(:second)
end
