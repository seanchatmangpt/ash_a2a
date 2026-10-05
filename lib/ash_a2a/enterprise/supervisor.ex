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
  and production opts in per key. `nil` and `false` both mean OFF.
  """

  use Supervisor

  require Logger

  @gates [:spiffe_socket, :authzen_pdp_url, :kms, :finops, :drain, :affidavit, :siem]

  @spec start_link(keyword()) :: {:ok, pid()} | :ignore | {:error, term()}
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @spec resolve(keyword()) :: map()
  def resolve(overrides \\ []) do
    acc =
      %{children: [], skipped: []}
      |> add_spiffe(overrides)

    %{acc | children: Enum.reverse(acc.children)}
  end

  @impl true
  def init(opts) do
    :ok = apply_kms_binding()
    resolution = resolve(overrides(opts))

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

  # -- gate builders (declaration order = child order) --

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

  # -- internals --

  defp gate(key) do
    case Application.get_env(:ash_a2a, key) do
      value when value in [nil, false] -> :off
      value -> {:on, value}
    end
  end

  defp override(overrides, module), do: Keyword.get(overrides, module, [])

  defp overrides(opts), do: Keyword.get(opts, :overrides, [])

  defp put_child(acc, key, module, opts) do
    cond do
      not Code.ensure_loaded?(module) ->
        skip(acc, key, module, {:module_unavailable, module})

      not function_exported?(module, :child_spec, 1) ->
        skip(acc, key, module, {:not_startable, module})

      true ->
        spec = Supervisor.child_spec({module, opts})
        %{acc | children: [spec | acc.children]}
    end
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
