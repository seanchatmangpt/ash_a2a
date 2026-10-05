# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.Supervisor do
  @moduledoc """
  The ARD v26.10.4 §2 enterprise supervision subtree
  (`docs/jira/v26.10.4/ARD.md` §2): an optional, config-gated layer of
  enterprise children under the application root (`AshA2A.Supervisor`,
  `AshA2A.Application`).

  Every enterprise child is default-OFF. Each child starts only when its
  config key is present under `:ash_a2a`, so dev/test boots are unchanged
  and production opts in per key. `nil` and `false` both mean OFF. The
  child table:

  | config key (`config :ash_a2a, ...`) | child | value shape |
  |---|---|---|
  | `:spiffe_socket` | `AshA2A.SPIFFE.WorkloadWatcher` | SPIRE agent UDS path (`String.t`) |
  | `:authzen_pdp_url` | `AshA2A.AuthZEN.DecisionPool` | PDP endpoint URL (`String.t`); the URL is passed per-call by `AshA2A.AuthZEN.Client`, so the key's presence gates the pool, not the endpoint string |
  | `:kms` | `AshA2A.Security.KeyManager` | `[client: module(), kek_id: String.t()]` |
  | `:finops` | `AshA2A.FinOps.BudgetStore` | quota keyword list (`keyword()`) |
  | `:drain` | `AshA2A.Cluster.DrainManager` + `AshA2A.TaskSupervisor` | `true` or `keyword()` of DrainManager opts |
  | `:affidavit` | `AshA2A.Evidence.AffidavitPool` | `[wasm_path: String.t()]` |
  | `:siem` | `AshA2A.Telemetry.OcelBroadcaster` | `[endpoints: [String.t()]]` |

  `:drain` starts two children: the drain manager plus the
  `AshA2A.TaskSupervisor` `Task.Supervisor` it drains (ARD §3.4 Phase 2 gives
  in-flight tasks under `AshA2A.TaskSupervisor` until the drain deadline), so
  one key gates exactly the pair it governs.

  `:drain` installs the real OS signal disposition (`:os.set_signal(:sigterm,
  :handle)` inside `AshA2A.Cluster.DrainManager.init/1`, default on): the OS
  `SIGTERM` arrives as a `:sigterm` message and the two-phase drain begins.
  Pass `install_signal_handler: false` in the `:drain` keyword when another
  component owns the node's signal disposition.

  ## Fail-closed semantics

  The supervision layer never fakes a capability. Two typed skips are
  logged (`Logger.warning`) and never silent:

    * `{:module_unavailable, module}` — the child module is not compiled into
      this release. The capability is ABSENT, not degraded: the enforcement
      points behind it refuse fail-closed on their own surfaces
      (`AshA2A.Security.KeyManager` refuses `:refused_cmek_kms_unavailable`
      without a KMS binding, `AshA2A.AuthZEN.Client` refuses
      `:pdp_unreachable` when the PDP is unreachable,
      `AshA2A.SPIFFE.SvidValidator` refuses on an absent/expired bundle).
      Configure the key only when the release carrying the child is pinned.
    * `{:not_startable, module}` — the module is compiled but defines no
      `child_spec/1`. No process is fabricated for a stateless module. As of
      V4-22 every gated child (`AshA2A.Security.KeyManager` included, via its
      supervised `child_spec/1`) is startable, so this skip is a fail-closed
      guard for future children, not a live case.

  Exception: the `:kms` binding is applied even while no process child is
  startable. When `kms: [client: mod, ...]` names a client and the host has
  not set `:cmek_kms_client`, it is projected onto
  `config :ash_a2a, :cmek_kms_client` at supervisor start (explicit host
  config wins; the fail-closed resolution order inside
  `AshA2A.Security.KeyManager` is untouched). This is what makes the `:kms`
  key real today instead of advisory-only.

  ## Options

    * `:name` — supervisor registered name (default `__MODULE__`).
    * `:overrides` — keyword keyed by child module, merged over the
      builder-derived child opts (test seam for unique registered names;
      the children are the real GenServers, never fakes).

  A supervisor with no enabled children returns `:ignore` from `init/1`: dev
  and test boots are literally unchanged (no extra process), and the
  application root lists this child unconditionally without paying a process
  for it until an enterprise key is configured.
  """

  use Supervisor

  require Logger

  @typedoc "Gate keys; `nil`/`false` = OFF, anything else enables the key's children."
  @type gate_key ::
          :spiffe_socket
          | :authzen_pdp_url
          | :kms
          | :finops
          | :drain
          | :affidavit
          | :siem

  @typedoc "Why a gated-on child is not started (logged, never silent)."
  @type skip_reason :: {:module_unavailable | :not_startable, module()}

  @doc "The enterprise gate keys, in child order."
  @spec gates() :: [gate_key()]
  def gates do
    [
      :spiffe_socket,
      :authzen_pdp_url,
      :kms,
      :finops,
      :drain,
      :affidavit,
      :siem
    ]
  end

  @doc """
  Starts the enterprise subtree for the current config. Returns `:ignore`
  when no enterprise key is configured (dev/test default).
  """
  @spec start_link(keyword()) :: {:ok, pid()} | :ignore | {:error, term()}
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Reads the current `:ash_a2a` enterprise config into child specs and typed
  skips. Reads the real app env (no injection seam): courts set the real
  keys with `Application.put_env/3`. `overrides` merges per-module child
  opts (test seam for unique registered names).
  """
  @spec resolve(keyword()) :: %{
          children: [Supervisor.child_spec()],
          skipped: [{gate_key(), module(), skip_reason()}]
        }
  def resolve(overrides \\ []) do
    acc =
      %{children: [], skipped: []}
      |> add_spiffe(overrides)
      |> add_authzen(overrides)
      |> add_kms(overrides)
      |> add_finops(overrides)
      |> add_drain(overrides)
      |> add_affidavit(overrides)
      |> add_siem(overrides)

    %{acc | children: Enum.reverse(acc.children)}
  end

  @impl true
  def init(opts) do
    :ok = apply_kms_binding()
    resolution = resolve(Keyword.get(opts, :overrides, []))

    Enum.each(resolution.skipped, fn {key, module, reason} ->
      Logger.warning(
        "AshA2A.Enterprise.Supervisor: config :ash_a2a, #{inspect(key)} is set but " <>
          "#{inspect(module)} is not startable (#{inspect(reason)}); " <>
          "the capability stays ABSENT and its enforcement points refuse fail-closed"
      )
    end)

    case resolution.children do
      [] -> :ignore
      children -> Supervisor.init(children, strategy: :one_for_one)
    end
  end

  # ------------------------------------------------------------------
  # Gate builders (declaration order = child order under the supervisor)
  # ------------------------------------------------------------------

  defp add_spiffe(acc, overrides) do
    case gate(:spiffe_socket) do
      :off ->
        acc

      {:on, socket_path} ->
        opts =
          [
            name: AshA2A.SPIFFE.WorkloadWatcher,
            socket_path: socket_path,
            trust_domain: Application.get_env(:ash_a2a, :spiffe_trust_domain)
          ]
          |> Keyword.merge(override(overrides, AshA2A.SPIFFE.WorkloadWatcher))

        put_child(acc, :spiffe_socket, AshA2A.SPIFFE.WorkloadWatcher, opts)
    end
  end

  defp add_authzen(acc, overrides) do
    case gate(:authzen_pdp_url) do
      :off ->
        acc

      {:on, _url} ->
        opts = override(overrides, AshA2A.AuthZEN.DecisionPool)
        put_child(acc, :authzen_pdp_url, AshA2A.AuthZEN.DecisionPool, opts)
    end
  end

  defp add_kms(acc, overrides) do
    case gate(:kms) do
      :off ->
        acc

      {:on, _binding} ->
        opts = override(overrides, AshA2A.Security.KeyManager)
        put_child(acc, :kms, AshA2A.Security.KeyManager, opts)
    end
  end

  defp add_finops(acc, overrides) do
    case gate(:finops) do
      :off ->
        acc

      {:on, value} ->
        opts =
          value_opts(value)
          |> Keyword.merge(override(overrides, AshA2A.FinOps.BudgetStore))

        put_child(acc, :finops, AshA2A.FinOps.BudgetStore, opts)
    end
  end

  defp add_drain(acc, overrides) do
    case gate(:drain) do
      :off ->
        acc

      {:on, value} ->
        drain_opts = value_opts(value)

        task_supervisor_name =
          overrides
          |> override(AshA2A.TaskSupervisor)
          |> Keyword.get(:name, AshA2A.TaskSupervisor)

        ts_opts =
          [name: task_supervisor_name]
          |> Keyword.merge(override(overrides, AshA2A.TaskSupervisor))

        dm_opts =
          [
            name: AshA2A.Cluster.DrainManager,
            task_supervisor: task_supervisor_name
          ]
          |> Keyword.merge(drain_opts)
          |> Keyword.merge(override(overrides, AshA2A.Cluster.DrainManager))

        acc
        |> put_child(:drain, Task.Supervisor, ts_opts, AshA2A.TaskSupervisor)
        |> put_child(:drain, AshA2A.Cluster.DrainManager, dm_opts)
    end
  end

  defp add_affidavit(acc, overrides) do
    case gate(:affidavit) do
      :off ->
        acc

      {:on, value} ->
        opts =
          value_opts(value)
          |> Keyword.merge(override(overrides, AshA2A.Evidence.AffidavitPool))

        put_child(acc, :affidavit, AshA2A.Evidence.AffidavitPool, opts)
    end
  end

  defp add_siem(acc, overrides) do
    case gate(:siem) do
      :off ->
        acc

      {:on, value} ->
        opts =
          value_opts(value)
          |> Keyword.merge(override(overrides, AshA2A.Telemetry.OcelBroadcaster))

        put_child(acc, :siem, AshA2A.Telemetry.OcelBroadcaster, opts)
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp gate(key) do
    case Application.get_env(:ash_a2a, key) do
      value when value in [nil, false] -> :off
      value -> {:on, value}
    end
  end

  defp override(overrides, module), do: Keyword.get(overrides, module, [])

  defp value_opts(value) when is_list(value), do: value
  defp value_opts(_other), do: []

  defp put_child(acc, key, module, opts) do
    cond do
      not Code.ensure_loaded?(module) ->
        skip(acc, key, module, {:module_unavailable, module})

      not function_exported?(module, :child_spec, 1) ->
        skip(acc, key, module, {:not_startable, module})

      true ->
        spec = Supervisor.child_spec({module, opts}, [])
        %{acc | children: [spec | acc.children]}
    end
  end

  # `AshA2A.TaskSupervisor` is a registered name over the real
  # `Task.Supervisor`, not a module, so its spec is built explicitly.
  defp put_child(acc, _key, Task.Supervisor, opts, id) do
    spec = %{id: id, start: {Task.Supervisor, :start_link, [opts]}}
    %{acc | children: [spec | acc.children]}
  end

  defp skip(acc, key, module, reason) do
    Logger.warning(
      "AshA2A.Enterprise.Supervisor: config :ash_a2a, #{inspect(key)} is set but " <>
        "#{inspect(module)} is not startable (#{inspect(reason)}); " <>
        "the capability stays ABSENT and its enforcement points refuse fail-closed"
    )

    %{acc | skipped: [{key, module, reason} | acc.skipped]}
  end

  defp apply_kms_binding do
    case Application.get_env(:ash_a2a, :kms) do
      binding when is_list(binding) ->
        client = Keyword.get(binding, :client)

        if is_atom(client) and client != nil and
             Application.get_env(:ash_a2a, :cmek_kms_client) in [nil, false] do
          Application.put_env(:ash_a2a, :cmek_kms_client, client)
        end

        :ok

      _other ->
        :ok
    end
  end
end
