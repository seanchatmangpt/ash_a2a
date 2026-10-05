# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Domain.Verifiers.VerifyMounts do
  @moduledoc """
  Verifies `AshA2A.Domain`'s `transport.mount` declarations:

  - every per-agent mount's `agent` module must exist (`Code.ensure_compiled/1`
    -- a misdeclared agent is a compile-time `Spark.Error.DslError` refusal).
  - mount paths must be unique across all declared mounts.
  - an agent may not be mounted twice over the same binding.
  """

  use Spark.Dsl.Verifier

  alias AshA2A.Domain.Mount

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    mounts =
      dsl_state
      |> Spark.Dsl.Verifier.get_entities([:transport])
      |> Enum.filter(&match?(%Mount{}, &1))

    with :ok <- verify_agents_exist(mounts, module),
         :ok <- verify_unique_paths(mounts, module) do
      verify_unique_agent_bindings(mounts, module)
    end
  end

  defp verify_agents_exist(mounts, module) do
    Enum.reduce_while(mounts, :ok, fn
      %Mount{agent: nil}, :ok ->
        {:cont, :ok}

      %Mount{agent: agent, path: path}, :ok ->
        case Code.ensure_compiled(agent) do
          {:module, _} ->
            {:cont, :ok}

          {:error, _} ->
            {:halt,
             {:error,
              Spark.Error.DslError.exception(
                module: module,
                path: [:transport, :mount],
                message:
                  "mount `#{path}` references agent `#{inspect(agent)}`, which does not exist " <>
                    "-- mounted agents must be compiled before the domain that mounts them"
              )}}
        end
    end)
  end

  defp verify_unique_paths(mounts, module) do
    mounts
    |> Enum.group_by(& &1.path)
    |> Enum.find(fn {_path, group} -> length(group) > 1 end)
    |> case do
      nil ->
        :ok

      {path, _group} ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:transport, :mount],
           message: "mount path `#{path}` is declared more than once"
         )}
    end
  end

  defp verify_unique_agent_bindings(mounts, module) do
    mounts
    |> Enum.filter(&Mount.agent_mount?/1)
    |> Enum.group_by(fn %Mount{agent: agent, binding: binding} -> {agent, binding} end)
    |> Enum.find(fn {_key, group} -> length(group) > 1 end)
    |> case do
      nil ->
        :ok

      {{agent, binding}, _group} ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:transport, :mount],
           message:
             "agent `#{inspect(agent)}` is mounted more than once over the `#{binding}` binding"
         )}
    end
  end
end
