defmodule AshA2A.Chicago.Closure do
  @moduledoc """
  Graph-derived architecture closure court (RFC-SA2A-006 s27).

  Replaces regex / hand-listed checks with the remote-call graph read from the
  BEAM abstract code of the compiled subject (`AshA2A.Chicago.AbstractCode`,
  cover-safe through `AshA2A.BeamFile`). The court proves:

      every edge INTO an effector originates from an allowed caller set
      (the ConsequenceKernel modules)

  and reports every violating edge with the caller MFA and a call chain from
  the nearest graph root down to the effector.

  ## Edges

    * resolved: `{:remote, m, f, a}` and `{:fun_ref, m, f, a}` call sites
      (including literal `apply/3`)
    * UNRESOLVED (never ignored): `apply/2,3` with a non-literal target
      (`dynamic_apply`) and `expr:f(...)` with a non-literal module
      (`dynamic_remote`). A dynamic site can reach any effector, so an
      unresolved edge outside the allowed caller set is refused in
      `:enforce` mode unless `unresolved: :report` is given.

  ## Effector classification

  A list of `%{module: m, functions: :all | [atom], kind: atom, wrapper: bool}`.
  `functions` matches by function name (any arity, so defaulted arities are
  covered). Callers that are themselves in a `wrapper: true` effector module
  are internal to the effector and never violations.

  ## Modes

    * `:report` (default) -- always returns `{:ok, report}`; violations are data
    * `:enforce` -- returns `{:refused, report}` when `report.verdict` is
      `"violations"`
  """

  alias AshA2A.Chicago.{AbstractCode, Json}

  @schema "ash_a2a.chicago.closure/v1"
  @max_chain 12

  @type effector :: %{
          module: module(),
          functions: :all | [atom()],
          kind: atom(),
          wrapper: boolean()
        }

  @doc "Default effector classification for this repository."
  @spec default_effectors() :: [effector()]
  def default_effectors do
    ash = [
      :create,
      :create!,
      :update,
      :update!,
      :destroy,
      :destroy!,
      :run_action,
      :run_action!,
      :bulk_create,
      :bulk_create!,
      :bulk_update,
      :bulk_update!,
      :bulk_destroy,
      :bulk_destroy!
    ]

    file = [
      :write,
      :write!,
      :rm,
      :rm!,
      :rm_rf,
      :rmdir,
      :mkdir,
      :mkdir_p,
      :cp,
      :cp!,
      :cp_r,
      :cp_r!,
      :rename,
      :rename!,
      :touch,
      :touch!,
      :ln_s,
      :chmod,
      :chown,
      :chgrp
    ]

    [
      %{module: Ash, functions: ash, kind: :ash_effect, wrapper: false},
      %{module: AshA2A.Dispatcher, functions: [:dispatch], kind: :dispatcher, wrapper: true},
      %{module: Req, functions: :all, kind: :http_client, wrapper: false},
      %{module: Finch, functions: :all, kind: :http_client, wrapper: false},
      %{module: System, functions: [:cmd, :shell], kind: :os_process, wrapper: false},
      %{module: Port, functions: [:open, :command], kind: :os_process, wrapper: false},
      %{module: :erlang, functions: [:open_port], kind: :os_process, wrapper: false},
      %{module: File, functions: file, kind: :file_write, wrapper: false},
      %{
        module: :file,
        functions: [:write_file, :delete, :del_dir, :make_dir, :rename, :copy, :write, :pwrite],
        kind: :file_write,
        wrapper: false
      },
      %{
        module: :gen_tcp,
        functions: [:connect, :send, :listen],
        kind: :network,
        wrapper: false
      },
      %{module: :gen_udp, functions: [:send, :open], kind: :network, wrapper: false},
      %{module: :ssl, functions: [:connect, :send, :listen], kind: :network, wrapper: false},
      %{module: :httpc, functions: :all, kind: :http_client, wrapper: false}
    ]
  end

  @doc """
  Default allowed caller set: the ConsequenceKernel and the C2 actuation
  pipeline. Entries are exact modules or module-name prefixes (strings).
  """
  @spec default_allowed_callers() :: [module() | String.t()]
  def default_allowed_callers, do: ["AshA2A.ConsequenceKernel", "AshA2A.C2"]

  @doc """
  Every module of the `:ash_a2a` application compiled from `lib/` (modules
  whose compile source lies under `test/support` are excluded).
  """
  @spec app_modules() :: [module()]
  def app_modules do
    _ = Application.load(:ash_a2a)

    (Application.spec(:ash_a2a, :modules) || [])
    |> Enum.reject(&test_support?/1)
    |> Enum.sort()
  end

  defp test_support?(module) do
    case AshA2A.BeamFile.path(module) do
      {:ok, path} ->
        case :beam_lib.chunks(path, [:compile_info]) do
          {:ok, {_, [compile_info: info]}} ->
            source = info |> Keyword.get(:source, ~c"") |> List.to_string()
            String.contains?(source, "/test/")

          _ ->
            false
        end

      _ ->
        false
    end
  end

  @doc """
  Analyse `modules`. Options: `:mode` (`:report | :enforce`), `:effectors`,
  `:allowed_callers`, `:unresolved` (`:refuse | :report`, default `:refuse`).
  """
  @spec run([module()], keyword()) :: {:ok, map()} | {:refused, map()}
  def run(modules, opts \\ []) do
    mode = Keyword.get(opts, :mode, :report)
    report = analyze(modules, opts)

    if mode == :enforce and report.verdict == "violations",
      do: {:refused, report},
      else: {:ok, report}
  end

  @spec analyze([module()], keyword()) :: map()
  def analyze(modules, opts \\ []) do
    mode = Keyword.get(opts, :mode, :report)
    effectors = Keyword.get(opts, :effectors, default_effectors())
    allowed = Keyword.get(opts, :allowed_callers, default_allowed_callers())
    unresolved_policy = Keyword.get(opts, :unresolved, :refuse)

    {facts, unanalyzable} = read_modules(modules)
    defined = MapSet.new(for {mfa, _} <- facts, do: mfa)
    sites = for {caller, calls} <- facts, call <- calls, do: {caller, call}

    graph = build_graph(sites, defined)
    preds = predecessors(graph)

    resolved =
      for {caller, call} <- sites,
          {kind, {m, f, a}} <- resolved_target(call),
          do: {caller, kind, {m, f, a}}

    violating =
      for {caller, kind, {m, f, _a} = callee} <- resolved,
          eff = classify(effectors, m, f),
          not internal?(effectors, caller),
          not allowed?(allowed, elem(caller, 0)) do
        %{
          caller: mfa_string(caller),
          caller_module: inspect(elem(caller, 0)),
          callee: mfa_string(callee),
          effector_kind: Atom.to_string(eff.kind),
          edge_kind: Atom.to_string(kind),
          chain:
            chain(caller, preds) |> Enum.map(&mfa_string/1) |> Kernel.++([mfa_string(callee)])
        }
      end
      |> Enum.uniq()
      |> Enum.sort_by(&{&1.caller, &1.callee, &1.edge_kind})

    unresolved =
      for {caller, call} <- sites,
          kind = unresolved_kind(call),
          not internal?(effectors, caller),
          not allowed?(allowed, elem(caller, 0)) do
        %{
          caller: mfa_string(caller),
          caller_module: inspect(elem(caller, 0)),
          edge_kind: Atom.to_string(kind),
          site: unresolved_site(call),
          chain: chain(caller, preds) |> Enum.map(&mfa_string/1)
        }
      end
      |> Enum.uniq()
      |> Enum.sort_by(&{&1.caller, &1.edge_kind, &1.site})

    refusing_unresolved = if unresolved_policy == :refuse, do: unresolved, else: []

    %{
      schema: @schema,
      mode: Atom.to_string(mode),
      unresolved_policy: Atom.to_string(unresolved_policy),
      verdict: if(violating == [] and refusing_unresolved == [], do: "clean", else: "violations"),
      modules_analyzed: length(modules) - length(unanalyzable),
      unanalyzable: unanalyzable,
      allowed_callers: Enum.map(allowed, &allowed_string/1),
      effectors: for(e <- effectors, do: effector_json(e)),
      summary: %{
        call_sites: length(sites),
        resolved_edges: length(resolved),
        violating_edges: length(violating),
        unresolved_edges: length(unresolved)
      },
      violating_edges: violating,
      unresolved_edges: unresolved
    }
  end

  @doc "Canonical JSON encoding of a report."
  @spec to_json(map()) :: String.t()
  def to_json(report), do: Json.canonical(report)

  # --- facts -----------------------------------------------------------------

  defp read_modules(modules) do
    Enum.reduce(modules, {%{}, []}, fn module, {facts, bad} ->
      case AbstractCode.calls_by_function(module) do
        {:ok, by_fun} ->
          facts =
            Enum.reduce(by_fun, facts, fn {{f, a}, calls}, acc ->
              Map.put(acc, {module, f, a}, calls)
            end)

          {facts, bad}

        {:error, reason} ->
          {facts, [%{module: inspect(module), reason: inspect(reason)} | bad]}
      end
    end)
    |> then(fn {facts, bad} -> {facts, Enum.reverse(bad)} end)
  end

  defp resolved_target({:remote, m, f, a}), do: [{:remote, {m, f, a}}]
  defp resolved_target({:fun_ref, m, f, a}), do: [{:fun_ref, {m, f, a}}]
  defp resolved_target(_), do: []

  defp unresolved_kind({:dynamic_apply, _}), do: :dynamic_apply
  defp unresolved_kind({:dynamic_remote, _, _}), do: :dynamic_remote
  defp unresolved_kind(_), do: nil

  defp unresolved_site({:dynamic_apply, n}), do: "apply/#{n}"
  defp unresolved_site({:dynamic_remote, nil, n}), do: "?:?/#{n}"
  defp unresolved_site({:dynamic_remote, f, n}), do: "?:#{f}/#{n}"

  # --- classification --------------------------------------------------------

  defp classify(effectors, m, f) do
    Enum.find(effectors, fn %{module: em, functions: fs} ->
      em == m and (fs == :all or f in fs)
    end)
  end

  defp internal?(effectors, {caller_module, _, _}),
    do: Enum.any?(effectors, &(&1.wrapper and &1.module == caller_module))

  defp allowed?(allowed, module), do: Enum.any?(allowed, &allowed_match?(&1, module))

  defp allowed_match?(m, module) when is_atom(m), do: m == module

  defp allowed_match?(prefix, module) when is_binary(prefix) do
    name = inspect(module)
    name == prefix or String.starts_with?(name, prefix <> ".")
  end

  defp allowed_string(m) when is_atom(m), do: inspect(m)
  defp allowed_string(s), do: s

  defp effector_json(%{module: m, functions: fs, kind: k, wrapper: w}),
    do: %{
      module: inspect(m),
      functions: if(fs == :all, do: "all", else: Enum.map(fs, &Atom.to_string/1)),
      kind: Atom.to_string(k),
      wrapper: w
    }

  # --- graph -----------------------------------------------------------------

  defp build_graph(sites, defined) do
    Enum.reduce(sites, %{}, fn {caller, call}, acc ->
      target =
        case call do
          {:local, f, a} -> resolve({elem(caller, 0), f, a}, defined)
          {:remote, m, f, a} -> resolve({m, f, a}, defined)
          {:fun_ref, m, f, a} -> resolve({m, f, a}, defined)
          _ -> nil
        end

      if target && MapSet.member?(defined, target),
        do: Map.update(acc, caller, [target], &[target | &1]),
        else: acc
    end)
  end

  # A call with defaulted arguments targets a higher-arity definition.
  defp resolve({m, f, a} = mfa, defined) do
    if MapSet.member?(defined, mfa) do
      mfa
    else
      defined
      |> Enum.filter(fn {dm, df, da} -> dm == m and df == f and da > a end)
      |> Enum.min_by(&elem(&1, 2), fn -> nil end) || mfa
    end
  end

  defp predecessors(graph) do
    Enum.reduce(graph, %{}, fn {from, tos}, acc ->
      Enum.reduce(tos, acc, fn to, acc2 ->
        if to == from,
          do: acc2,
          else: Map.update(acc2, to, MapSet.new([from]), &MapSet.put(&1, from))
      end)
    end)
  end

  # Shortest path from the nearest predecessor-free root down to `node`.
  defp chain(node, preds), do: bfs([[node]], MapSet.new([node]), preds)

  defp bfs([], _seen, _preds), do: []

  defp bfs([[head | _] = path | queue], seen, preds) do
    ps =
      preds
      |> Map.get(head, MapSet.new())
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.sort()

    cond do
      ps == [] or length(path) >= @max_chain ->
        path

      true ->
        seen = Enum.reduce(ps, seen, &MapSet.put(&2, &1))
        bfs(queue ++ Enum.map(ps, &[&1 | path]), seen, preds)
    end
  end

  defp mfa_string({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
end
