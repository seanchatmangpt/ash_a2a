defmodule AshA2A.ConsequenceKernel.ClosureCourt do
  @moduledoc """
  Kernel-only DO closure court (conformance `c1.closure_report`).

  Computes, from the compiled call topology (BEAM abstract code through
  `AshA2A.Chicago.Closure`, never source text), every caller of every DO entry point and proves
  the consequence kernel (`AshA2A.ConsequenceKernel.*`, whose runtime is
  `AshA2A.ConsequenceKernel.Runtime.Pipeline`) is the only path to actuation.

  ## DO entry points

    * `AshA2A.Dispatcher.dispatch/3..6` and `dispatch_observe/3..6`
    * `AshA2A.BrceAnchor.put/1` (anchor forgery surface)
    * `AshA2A.C2.Actuator`, `AshA2A.C2.ActuatorClient`, `AshA2A.C2.ActuationPipeline`,
      `AshA2A.C2.EffectorRegistry` (C2 actuation)
    * Ash write actions (`Ash.create/update/destroy/run_action/bulk_*`) from authored code
      (spark-generated code interfaces are excluded: they are projections of the resource)

  ## Verdict

  `report/0` returns `%{violating_edges: [...]}` (the shape `c1.closure_report` reads). An edge
  is violating when its caller is outside the kernel and not an exact typed exception in
  `AshA2A.ConsequenceKernel.Closure.Exceptions`; when a dynamic call site inside a DO-adjacent
  module (Agent, CommandBus, Dispatcher, BrceAnchor, C2) is not an enumerated exception; when an
  exception is STALE (declared, no longer observed); or when a kernel module other than the
  pinned gateway calls a Dispatcher entry.
  """

  alias AshA2A.Chicago.Closure
  alias AshA2A.ConsequenceKernel.Closure.Exceptions

  @schema "ash_a2a.consequence_kernel.closure_court/v1"
  @sole_path AshA2A.ConsequenceKernel.Runtime.Pipeline
  @kernel_prefix "AshA2A.ConsequenceKernel"
  @gateways ["AshA2A.ConsequenceKernel.W4.DispatchInversion.execute/2"]

  @doc "The DO entry point classification (effector list in `Chicago.Closure` format)."
  @spec entry_points() :: [Closure.effector()]
  def entry_points do
    ash = Enum.filter(Closure.default_effectors(), &(&1.module == Ash))

    [
      %{
        module: AshA2A.Dispatcher,
        functions: [:dispatch, :dispatch_observe],
        kind: :dispatcher,
        wrapper: true
      },
      %{module: AshA2A.BrceAnchor, functions: [:put], kind: :brce_anchor, wrapper: false},
      %{module: AshA2A.C2.Actuator, functions: :all, kind: :c2_actuator, wrapper: false},
      %{
        module: AshA2A.C2.ActuatorClient,
        functions: :all,
        kind: :c2_actuator_client,
        wrapper: false
      },
      %{
        module: AshA2A.C2.ActuationPipeline,
        functions: :all,
        kind: :c2_pipeline,
        wrapper: false
      },
      %{
        module: AshA2A.C2.EffectorRegistry,
        functions: :all,
        kind: :c2_registry,
        wrapper: false
      }
      | ash
    ]
  end

  @doc "The sole DO path module."
  @spec sole_path() :: module()
  def sole_path, do: @sole_path

  @doc """
  Closure report over the whole compiled application. Memoized per code identity (the md5s of
  every application module), so repeated conformance runs do not rescan.
  """
  @spec report() :: map()
  def report do
    modules = Closure.app_modules()

    key =
      {__MODULE__, :report,
       :erlang.md5(IO.iodata_to_binary(Enum.map(modules, &[Atom.to_string(&1), md5(&1)])))}

    case :persistent_term.get(key, nil) do
      nil ->
        report = report(modules: modules, stale_check: true)
        :persistent_term.put(key, report)
        report

      report ->
        report
    end
  end

  @doc """
  Closure report over explicit `:modules` (plus `:extra_modules`, e.g. a mutant). Options:
  `:stale_check` (default false: a partial module set cannot judge staleness).
  """
  @spec report(keyword()) :: map()
  def report(opts) do
    modules =
      Keyword.get_lazy(opts, :modules, &Closure.app_modules/0) ++
        Keyword.get(opts, :extra_modules, [])

    analysis =
      Closure.analyze(modules,
        effectors: entry_points(),
        allowed_callers: ["AshA2A.ClosureCourt.NoCallerIsPreAllowed"],
        unresolved: :report
      )

    {kernel_edges, outside_edges} =
      Enum.split_with(analysis.violating_edges, &prefix?(&1.caller_module, @kernel_prefix))

    # The kernel prefix is a name, not a proof: a kernel-named module is trusted only as the
    # exact pinned gateway calling a Dispatcher entry. Every other kernel-named edge (any
    # entry kind) is a violation.

    edge_exceptions = Exceptions.edges()
    dyn_exceptions = Exceptions.dynamic_sites()

    {excepted, open} =
      outside_edges
      |> Enum.reject(&generated_or_fixture_effect?/1)
      |> Enum.split_with(fn e -> Enum.any?(edge_exceptions, &edge_match?(&1, e)) end)

    sensitive_dynamic =
      Enum.filter(analysis.unresolved_edges, fn u ->
        sensitive?(u.caller_module) or do_shaped_site?(u.site)
      end)

    {dyn_excepted, dyn_open} =
      Enum.split_with(sensitive_dynamic, fn u ->
        Enum.any?(dyn_exceptions, &(&1.caller == u.caller and &1.site == u.site))
      end)

    gateway_edges =
      for e <- kernel_edges, e.effector_kind == "dispatcher", e.caller in @gateways, do: e

    bad_gateways = for e <- kernel_edges, e not in gateway_edges, do: e

    stale =
      if Keyword.get(opts, :stale_check, false) do
        stale_edges(edge_exceptions, outside_edges) ++ stale_dynamic(dyn_exceptions, analysis)
      else
        []
      end

    violating =
      Enum.map(open, &Map.put(&1, :violation, "non_kernel_caller_of_do_entry")) ++
        Enum.map(
          dyn_open,
          &Map.put(&1, :violation, "unlisted_dynamic_site_in_do_adjacent_module")
        ) ++
        Enum.map(bad_gateways, &Map.put(&1, :violation, "unpinned_kernel_gateway")) ++
        Enum.map(stale, &Map.put(&1, :violation, "stale_exception")) ++
        Enum.map(analysis.unanalyzable, &Map.put(&1, :violation, "unanalyzable_module"))

    %{
      schema: @schema,
      verdict: if(violating == [], do: "closed", else: "violations"),
      sole_path: inspect(@sole_path),
      violating_edges: violating,
      typed_exceptions:
        Enum.map(excepted, &Map.take(&1, [:caller, :callee, :effector_kind])) ++
          Enum.map(dyn_excepted, &Map.take(&1, [:caller, :site])),
      kernel_gateways: Enum.map(gateway_edges, & &1.caller) |> Enum.uniq() |> Enum.sort(),
      unresolved_edges_total: length(analysis.unresolved_edges),
      modules_analyzed: analysis.modules_analyzed,
      entry_points: for(e <- entry_points(), do: "#{inspect(e.module)}:#{e.kind}")
    }
  end

  # -- classification --

  defp edge_match?(exc, edge), do: exc.caller == edge.caller and exc.callee == edge.callee

  # Spark-generated code interfaces (`Domain`/`Resource` projections) and court fixture resources
  # perform Ash effects as projections of a resource, not as authored callers.
  defp generated_or_fixture_effect?(%{effector_kind: "ash_effect", caller_module: caller}) do
    spark_module?(caller) or
      (fixture_module?(caller) and (spark_ancestor?(caller) or spark_descendant?(caller)))
  end

  defp generated_or_fixture_effect?(_), do: false

  defp fixture_module?(name),
    do: Enum.any?(Exceptions.fixture_prefixes(), &prefix?(name, &1))

  # A fixture-prefixed module is exempt only when it is generated inside a real Spark resource or
  # domain (an ancestor in its module namespace is one); a bare fixture-named module is not.
  defp spark_ancestor?(name) do
    parts = String.split(name, ".")

    Enum.any?(1..(length(parts) - 1)//1, fn n ->
      parts |> Enum.take(n) |> Enum.join(".") |> spark_module?()
    end)
  end

  # ...or when it is the namespace owner of a real Spark resource/domain (fixture helper modules
  # that own nested resources). A bare fixture-named module owns none.
  defp spark_descendant?(name) do
    prefix = "Elixir." <> name <> "."

    Enum.any?(:code.all_loaded(), fn {mod, _} ->
      String.starts_with?(Atom.to_string(mod), prefix) and
        function_exported?(mod, :spark_dsl_config, 0)
    end)
  end

  # An unresolved call site whose function name is a DO entry name (or a fully dynamic
  # apply/remote) can reach a DO entry from any module, not only DO-adjacent ones.
  defp do_shaped_site?(site) do
    case Regex.run(~r/^\?:(.+)\/\d+$/, site) do
      [_, "?"] -> true
      [_, fun] -> fun in do_function_names()
      nil -> String.starts_with?(site, "apply/")
    end
  end

  defp do_function_names do
    named =
      for %{functions: fs} <- entry_points(), is_list(fs), f <- fs, do: Atom.to_string(f)

    ["execute" | named]
    |> Enum.flat_map(&[&1, String.trim_trailing(&1, "!") <> "!"])
    |> Enum.uniq()
  end

  defp spark_module?(name) do
    module = Module.concat([name])
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0)
  end

  defp sensitive?(name),
    do: Enum.any?(Exceptions.dynamic_sensitive_prefixes(), &prefix?(name, &1))

  defp prefix?(name, prefix), do: name == prefix or String.starts_with?(name, prefix <> ".")

  defp stale_edges(exceptions, outside_edges) do
    observed = MapSet.new(outside_edges, &{&1.caller, &1.callee})

    for exc <- exceptions, not MapSet.member?(observed, {exc.caller, exc.callee}) do
      %{caller: exc.caller, callee: exc.callee, exception_id: exc.id}
    end
  end

  defp stale_dynamic(exceptions, analysis) do
    observed = MapSet.new(analysis.unresolved_edges, &{&1.caller, &1.site})

    for exc <- exceptions, not MapSet.member?(observed, {exc.caller, exc.site}) do
      %{caller: exc.caller, site: exc.site, exception_id: exc.id}
    end
  end

  defp md5(module), do: AshA2A.BeamFile.md5(module)
end
