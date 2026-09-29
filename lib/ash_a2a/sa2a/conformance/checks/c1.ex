defmodule AshA2A.SA2A.Conformance.Checks.C1 do
  @moduledoc """
  C1 checks: kernel-only DO closure, canonical digests at every boundary,
  durable claim store, keyed non-tmp journal, `:strict` security profile.

  Structural checks inspect the COMPILED module (`:beam_lib` imports chunk of
  the exact `.beam` on the code path, or a binary supplied through
  `ctx.beam_binaries`), never source text. Where a check depends on a module
  another lane is building it is written against the documented interface and
  fails with a precise reason until that module exists:

    * `AshA2A.SecurityProfile.current/0` -> `:strict | :dev_bypass | :legacy_compat`
    * `AshA2A.ConsequenceKernel.ClosureCourt.report/0` -> `%{violating_edges: [term]}`
    * claim store module: `durable?/0` (true) plus the `AshA2A.C2.ClaimStore` callbacks
  """

  alias AshA2A.SA2A.Conformance.{Check, Context}
  alias AshA2A.ConsequenceKernel.KeyCustody

  @spec checks(map()) :: [Check.t()]
  def checks(ctx) do
    ctx = Context.build(ctx)

    [
      Check.run("c1.security_profile_strict", :c1, "SecurityProfile is :strict", fn ->
        security_profile_strict(ctx)
      end),
      Check.run("c1.closure_report", :c1, "kernel-only-DO closure has zero violating edges", fn ->
        closure_report(ctx)
      end),
      Check.run(
        "c1.command_bus_no_direct_dispatch",
        :c1,
        "CommandBus does not call Dispatcher",
        fn ->
          command_bus_no_direct_dispatch(ctx)
        end
      ),
      Check.run(
        "c1.canonical_at_boundaries",
        :c1,
        "Identity.Canonical at every boundary digest",
        fn ->
          canonical_at_boundaries(ctx)
        end
      ),
      Check.run("c1.durable_claim_store", :c1, "durable claim store, not Memory", fn ->
        durable_claim_store(ctx)
      end),
      Check.run("c1.keyed_journal", :c1, "keyed non-tmp journal", fn -> keyed_journal(ctx) end)
    ]
  end

  # -- security profile --

  @doc "Resolved security profile atom (`:unknown` when the module is absent or raises)."
  @spec resolve_security_profile(map()) :: atom()
  def resolve_security_profile(ctx) do
    ctx = Context.build(ctx)
    mod = ctx.security_profile_module

    if Code.ensure_loaded?(mod) and function_exported?(mod, :current, 0) do
      try do
        mod.current()
      rescue
        _ -> :unknown
      end
    else
      :unknown
    end
  end

  def security_profile_strict(ctx) do
    ctx = Context.build(ctx)

    case resolve_security_profile(ctx) do
      :strict ->
        {:pass, "#{inspect(ctx.security_profile_module)}.current() == :strict"}

      :unknown ->
        {:fail, "#{inspect(ctx.security_profile_module)} is absent or has no current/0"}

      other ->
        {:fail, "security profile is #{inspect(other)}; only :strict can earn a claim"}
    end
  end

  # -- closure court --

  def closure_report(ctx) do
    ctx = Context.build(ctx)
    mod = ctx.closure_module

    if Code.ensure_loaded?(mod) and function_exported?(mod, :report, 0) do
      case mod.report() do
        %{violating_edges: []} ->
          {:pass, "#{inspect(mod)}.report/0: 0 violating edges"}

        %{violating_edges: edges} when is_list(edges) ->
          {:fail,
           "#{inspect(mod)}.report/0: #{length(edges)} violating edge(s): #{inspect(edges, limit: 5)}"}

        other ->
          {:fail, "closure report has no violating_edges list: #{inspect(other, limit: 5)}"}
      end
    else
      {:fail, "closure court #{inspect(mod)} is absent (closure lane not landed): no report/0"}
    end
  end

  # -- compiled-import probes --

  def command_bus_no_direct_dispatch(ctx) do
    ctx = Context.build(ctx)

    case imports(ctx, ctx.command_bus) do
      {:ok, imps} ->
        calls = for {m, f, a} <- imps, m == ctx.dispatcher, do: "#{f}/#{a}"

        if calls == [],
          do:
            {:pass,
             "#{inspect(ctx.command_bus)} compiled imports contain no call into #{inspect(ctx.dispatcher)}"},
          else:
            {:fail,
             "#{inspect(ctx.command_bus)} calls #{inspect(ctx.dispatcher)} directly: " <>
               Enum.join(Enum.uniq(calls), ", ") <>
               " (DO must go through the consequence kernel only)"}

      {:error, reason} ->
        {:fail, "cannot inspect #{inspect(ctx.command_bus)}: #{inspect(reason)}"}
    end
  end

  def canonical_at_boundaries(ctx) do
    ctx = Context.build(ctx)

    verdicts =
      Enum.map(ctx.boundary_modules, fn mod ->
        case imports(ctx, mod) do
          {:ok, imps} -> {mod, classify_boundary(imps, ctx.boundary_modules -- [mod])}
          {:error, r} -> {mod, {:violation, "cannot inspect: #{inspect(r)}"}}
        end
      end)

    violations = for {mod, {:violation, why}} <- verdicts, do: "#{inspect(mod)}: #{why}"

    if violations == [],
      do:
        {:pass,
         "#{length(verdicts)} boundary module(s) inspected in compiled form: no term_to_binary; every hashing module uses Identity.Canonical"},
      else: {:fail, Enum.join(violations, "; ")}
  end

  defp classify_boundary(imps, peers) do
    t2b? = Enum.any?(imps, &match?({:erlang, :term_to_binary, _}, &1))
    hashes? = Enum.any?(imps, fn {m, f, _} -> m == :crypto and f in [:hash, :hash_init, :mac] end)

    canonical? =
      Enum.any?(imps, fn {m, _, _} -> m == AshA2A.Identity.Canonical or m in peers end)

    cond do
      t2b? -> {:violation, "calls :erlang.term_to_binary (non-canonical boundary digest)"}
      hashes? and not canonical? -> {:violation, "hashes with :crypto without Identity.Canonical"}
      true -> :ok
    end
  end

  @doc false
  @spec imports(map(), module()) :: {:ok, [{module(), atom(), arity()}]} | {:error, term()}
  def imports(ctx, mod) do
    source =
      case Map.fetch(ctx.beam_binaries, mod) do
        {:ok, bin} ->
          {:ok, bin}

        :error ->
          Code.ensure_loaded(mod)
          AshA2A.BeamFile.path(mod)
      end

    with {:ok, src} <- source,
         {:ok, {_, [imports: imps]}} <- :beam_lib.chunks(src, [:imports]) do
      {:ok, imps}
    else
      {:error, _, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  # -- claim store --

  def durable_claim_store(ctx) do
    ctx = Context.build(ctx)

    case ctx.claim_store do
      nil ->
        {:fail,
         "no claim store configured (:claim_store not configured): nothing durable backs claims"}

      mod when is_atom(mod) ->
        Code.ensure_loaded(mod)

        cond do
          not Code.ensure_loaded?(mod) ->
            {:fail, "claim store #{inspect(mod)} does not exist"}

          mod in [AshA2A.C2.MemoryClaimStore, AshA2A.C2.ClaimStoreETS] or
              Module.split(mod) |> List.last() =~ ~r/Memory|ETS/ ->
            {:fail, "claim store #{inspect(mod)} is in-memory, not durable"}

          not function_exported?(mod, :durable?, 0) ->
            {:fail,
             "claim store #{inspect(mod)} does not export durable?/0; durability is unproven"}

          mod.durable?() != true ->
            {:fail, "claim store #{inspect(mod)}.durable?() is not true"}

          not (function_exported?(mod, :claim, 2) and function_exported?(mod, :complete, 2)) ->
            {:fail, "claim store #{inspect(mod)} lacks claim/2 and complete/2"}

          true ->
            {:pass,
             "claim store #{inspect(mod)} exports the ClaimStore callbacks and durable?() == true"}
        end
    end
  end

  # -- journal --

  def keyed_journal(ctx) do
    ctx = Context.build(ctx)

    with :ok <- journal_dir_ok(ctx.journal_dir),
         :ok <- journal_key_ok(ctx.journal_key_provider) do
      {:pass,
       "journal dir #{ctx.journal_dir} is outside tmp and writable; key provider MACs, verifies and refuses a tampered payload"}
    else
      {:error, why} -> {:fail, why}
    end
  end

  defp journal_dir_ok(nil),
    do: {:error, "journal dir is not configured (:receipt_outbox_dir unset)"}

  defp journal_dir_ok(dir) do
    if AshA2A.ReceiptStore.durable_path?(dir) do
      probe = Path.join(dir, ".sa2a_conformance_probe_#{System.unique_integer([:positive])}")

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(probe, "probe"),
           :ok <- File.rm(probe) do
        :ok
      else
        {:error, r} -> {:error, "journal dir #{dir} is not writable: #{inspect(r)}"}
      end
    else
      {:error, "journal dir #{inspect(dir)} is unset or under a tmp directory"}
    end
  end

  defp journal_key_ok(nil), do: {:error, "journal is unkeyed: no key provider configured"}

  defp journal_key_ok({provider, opts}) do
    payload = "sa2a-conformance-journal-probe"

    with {:ok, tag} <- KeyCustody.mac(provider, payload, opts),
         :ok <- KeyCustody.verify(provider, payload, tag, opts),
         true <- KeyCustody.verify(provider, payload <> "x", tag, opts) != :ok do
      :ok
    else
      {:error, reason} ->
        {:error, "journal key provider unusable (key): #{inspect(reason)}"}

      false ->
        {:error, "journal key provider accepts a tampered payload (key does not authenticate)"}

      other ->
        {:error, "journal key provider misbehaves (key): #{inspect(other)}"}
    end
  end
end
