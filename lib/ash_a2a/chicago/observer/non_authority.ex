defmodule AshA2A.Chicago.Observer.NonAuthority do
  @moduledoc """
  Static proof of observer non-authority (RFC-SA2A-002 §108:
  `Observe ⇏ DO`).

  Walks the BEAM abstract code (`AshA2A.Chicago.AbstractCode`) of the
  observer's code closure and refuses the proof when any reachable function
  can call into a consequence boundary:

    * `AshA2A.CommandBus`, `AshA2A.Dispatcher`, `AshA2A.KillSwitch`,
      `AshA2A.ReceiptOutbox`, `AshA2A.Authority*`, `AshA2A.ReceiptStore*`
    * Ash action entry points (`Ash`, `Ash.Changeset`, `Ash.ActionInput`,
      `Ash.BulkResult`)
    * remote execution (`:rpc`, `:erpc`)

  A call the walker cannot resolve statically -- a dynamic remote call other
  than `module_info/0,1`, or a non-literal `apply` -- makes the proof
  `:unprovable`, never `:proved`. A module without debug info is
  `:unprovable`. Closure applications (`fun.(...)`) are the observer applying
  *admitted* mapping closures; they are counted, and the proof scope is
  extended to the code that defines those closures (`default_scope/1`).

  Emits `[:ash_a2a, :chicago, :observer, :non_authority]` with the outcome,
  so the independent OCEL consumer can corroborate that the proof ran.

  Scope limit (stated, not assumed away): the proof is over call sites.
  Message sends are not modelled; in the observer closure they are
  `GenServer` calls/stops addressed to observer incarnations and the owner
  monitor. The complementary dynamic check -- an observer outage around a
  real `AshA2A.CommandBus` run produces no extra execution -- is falsifier
  `SA2A-OCEL-OBSERVER-009`.
  """

  alias AshA2A.Chicago.AbstractCode
  alias AshA2A.Chicago.Ocel.Mapping

  @forbidden_modules [
    AshA2A.CommandBus,
    AshA2A.Dispatcher,
    AshA2A.KillSwitch,
    AshA2A.ReceiptOutbox,
    Ash,
    Ash.Changeset,
    Ash.ActionInput,
    Ash.BulkResult,
    :rpc,
    :erpc
  ]

  @forbidden_prefixes ["AshA2A.Authority", "AshA2A.ReceiptStore"]

  @observer_core [
    AshA2A.Chicago.Observer,
    AshA2A.Chicago.Observer.Journal,
    AshA2A.Chicago.Ocel.Log,
    AshA2A.Chicago.Ocel.Mapping
  ]

  @type target :: module() | {module(), :all | [{atom(), arity()}]}

  @type report :: %{
          outcome: :proved | :violated | :unprovable,
          modules: [String.t()],
          modules_scanned: non_neg_integer(),
          functions_scanned: non_neg_integer(),
          remote_calls: non_neg_integer(),
          closure_applications: non_neg_integer(),
          violations: [String.t()],
          unprovable: [String.t()]
        }

  @doc "The observer's own modules (proved over every function)."
  @spec observer_core() :: [module()]
  def observer_core, do: @observer_core

  @doc """
  Observer core plus the code that defines the admitted mapping closures the
  observer applies: for each mapping source, the functions reachable from
  `ocel_mappings/0` (courts) or `mappings/0` (SUT mapping modules).
  """
  @spec default_scope([Mapping.t()]) :: [target()]
  def default_scope(mappings) do
    sources =
      mappings
      |> Enum.map(& &1.source)
      |> Enum.uniq()
      |> Enum.map(fn source ->
        _ = Code.ensure_loaded(source)

        roots =
          [ocel_mappings: 0, mappings: 0]
          |> Enum.filter(fn {f, a} -> function_exported?(source, f, a) end)

        {source, roots}
      end)

    @observer_core ++ sources
  end

  @doc "Runs the proof over `targets` and emits the non-authority telemetry."
  @spec prove([target()]) :: report()
  def prove(targets) do
    scans = Enum.map(targets, &scan/1)

    violations = Enum.flat_map(scans, & &1.violations)
    unprovable = Enum.flat_map(scans, & &1.unprovable)

    outcome =
      cond do
        violations != [] -> :violated
        unprovable != [] -> :unprovable
        true -> :proved
      end

    report = %{
      outcome: outcome,
      modules: Enum.map(scans, & &1.module),
      modules_scanned: length(scans),
      functions_scanned: Enum.sum(Enum.map(scans, & &1.functions)),
      remote_calls: Enum.sum(Enum.map(scans, & &1.remote_calls)),
      closure_applications: Enum.sum(Enum.map(scans, & &1.closures)),
      violations: violations,
      unprovable: unprovable
    }

    :telemetry.execute(
      [:ash_a2a, :chicago, :observer, :non_authority],
      %{system_time: System.system_time()},
      %{
        outcome: outcome,
        modules_scanned: report.modules_scanned,
        functions_scanned: report.functions_scanned,
        remote_calls: report.remote_calls,
        violations: length(violations),
        unprovable: length(unprovable)
      }
    )

    report
  end

  defp scan(module) when is_atom(module), do: scan({module, :all})

  defp scan({module, roots}) do
    name = inspect(module)

    case AbstractCode.reachable(module, roots) do
      {:ok, by_fun} ->
        Enum.reduce(
          by_fun,
          %{
            module: name,
            functions: map_size(by_fun),
            remote_calls: 0,
            closures: 0,
            violations: [],
            unprovable: []
          },
          fn {{f, a}, calls}, acc ->
            where = "#{name}.#{f}/#{a}"
            Enum.reduce(calls, acc, &classify(&1, where, &2))
          end
        )

      {:error, reason} ->
        %{
          module: name,
          functions: 0,
          remote_calls: 0,
          closures: 0,
          violations: [],
          unprovable: ["#{name}: abstract code unavailable (#{inspect(reason)})"]
        }
    end
  end

  defp classify({kind, m, f, a}, where, acc) when kind in [:remote, :fun_ref] do
    acc = %{acc | remote_calls: acc.remote_calls + 1}

    if forbidden?(m),
      do: %{acc | violations: ["#{where} -> #{inspect(m)}.#{f}/#{a}" | acc.violations]},
      else: acc
  end

  defp classify({:dynamic_remote, :module_info, _a}, _where, acc), do: acc

  defp classify({:dynamic_remote, f, a}, where, acc),
    do: %{acc | unprovable: ["#{where} -> <dynamic>.#{f || "<dynamic>"}/#{a}" | acc.unprovable]}

  defp classify({:dynamic_apply, a}, where, acc),
    do: %{acc | unprovable: ["#{where} -> apply/#{a} with a non-literal target" | acc.unprovable]}

  defp classify({:closure_apply, _a}, _where, acc), do: %{acc | closures: acc.closures + 1}
  defp classify(_other, _where, acc), do: acc

  @doc "True when a call into `module` would reach a consequence boundary."
  @spec forbidden?(module()) :: boolean()
  def forbidden?(module) when is_atom(module) do
    name = inspect(module)

    module in @forbidden_modules or
      Enum.any?(@forbidden_prefixes, &(name == &1 or String.starts_with?(name, &1 <> ".")))
  end
end
