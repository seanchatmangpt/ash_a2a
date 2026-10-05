# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Port.AshPPlan do
  # MERGE NOTE: main's owner-adapter-first port kept (candidates only: authority :none, standing
  # :candidate). r2's legacy direct-AshPPlan behaviour is preserved in legacy_propose/2, including
  # r2's `{:ok, plan}` unwrapping for :powl plans.
  #
  # SEAM DIVISION (docs/explanation/pplan-seams.md): this port is the REPLAN
  # CANDIDATE POLICY seam — it never touches
  # `AshPPlan.Reactor.Durable.Engine` and never starts a durable run. Task
  # durability (Engine start/attempt/signal/fetch/cancel) lives exclusively in
  # `AshA2A.Providers.PPlan`. xaas consumes this port via
  # `AshA2A.Replan.Loop.run/4`; `supports?/1` and `propose/2` are
  # source-compatible contracts. Do not delegate one seam to the other.
  @behaviour AshA2A.Replan.Provider

  @owner_provider AshPPlan.SA2A.Provider

  def supports?(formalism), do: formalism in [:fond, :powl]

  def propose(request, opts) when is_map(request) do
    owner = Keyword.get(opts, :ash_pplan_provider_module, @owner_provider)

    if owner_provider?(owner) do
      owner.propose(request, Keyword.delete(opts, :ash_pplan_provider_module))
    else
      legacy_propose(request, opts)
    end
  end

  def propose(_request, _opts), do: {:error, :unsupported_formalism}

  defp owner_provider?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :supports?, 1) and
      function_exported?(module, :propose, 2)
  end

  defp legacy_propose(%{formalism: :fond} = request, opts) do
    mod = Keyword.get(opts, :ash_pplan_module, AshPPlan)

    with true <- Code.ensure_loaded?(mod),
         true <- function_exported?(mod, :select_policy, 3),
         {:ok, domain} <- fetch_domain(request),
         {:ok, initial} <- fetch_initial(request) do
      case apply(mod, :select_policy, [domain, initial, Keyword.get(opts, :policy_opts, [])]) do
        {:ok, selection} ->
          {:ok,
           selection
           |> Map.put(:subject, Map.get(request, :subject))
           |> Map.put_new(:authority, :none)
           |> Map.put_new(:standing, :candidate)}

        {:error, _} = error ->
          error

        other ->
          {:error, {:invalid_ash_pplan_result, other}}
      end
    else
      false -> {:error, :ash_pplan_unavailable}
      {:error, _} = error -> error
    end
  end

  defp legacy_propose(%{formalism: :powl} = request, opts) do
    mod = Keyword.get(opts, :ash_pplan_module, AshPPlan)

    if Code.ensure_loaded?(mod) and function_exported?(mod, :plan, 1) do
      case apply(mod, :plan, [Map.fetch!(request, :plan_iri)]) do
        nil ->
          {:error, :plan_not_found}

        {:ok, plan} ->
          {:ok,
           %{
             subject: Map.get(request, :subject),
             plan: plan,
             formalism: :powl,
             authority: :none,
             standing: :candidate
           }}

        plan ->
          {:ok,
           %{
             subject: Map.get(request, :subject),
             plan: plan,
             formalism: :powl,
             authority: :none,
             standing: :candidate
           }}
      end
    else
      {:error, :ash_pplan_unavailable}
    end
  end

  defp legacy_propose(_request, _opts), do: {:error, :unsupported_formalism}

  defp fetch_domain(%{domain: domain}), do: {:ok, domain}
  defp fetch_domain(_), do: {:error, :missing_domain}
  defp fetch_initial(%{initial: initial}), do: {:ok, initial}
  defp fetch_initial(_), do: {:error, :missing_initial}
end
