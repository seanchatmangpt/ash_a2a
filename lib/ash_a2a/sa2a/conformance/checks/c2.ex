# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SA2A.Conformance.Checks.C2 do
  @moduledoc """
  C2 checks: signature verification is real, the authority service and the
  actuator are separate mix projects that do not depend on the control plane,
  no signing key material is reachable from the control-plane config, and the
  separate releases run with `RELEASE_DISTRIBUTION=none`.

  ## Certificate verifier probe

  `verify(certificate, effect, ctx)` is called with a real
  `AshA2A.C2.Certificate` bound to a real `AshA2A.C2.PreparedEffect`, `ctx`
  carrying a real `Sa2aCrypto` registry view and audience
  (`AshA2A.SA2A.Conformance.Checks.ProbeFixtures`). Garbage signatures, a
  signature by an unregistered key, a signature over a different effect and an
  unsigned certificate MUST be refused; a validly signed certificate MUST be
  accepted (positive control), so a verifier that refuses everything is not
  mistaken for a verifying one.
  """

  alias AshA2A.C2.CompleteMediation
  alias AshA2A.SA2A.Conformance.Checks.ProbeFixtures, as: Fx
  alias AshA2A.SA2A.Conformance.{Check, Context}

  @spec checks(map()) :: [Check.t()]
  def checks(ctx) do
    ctx = Context.build(ctx)

    [
      Check.run(
        "c2.certificate_verifier_signatures",
        :c2,
        "CertificateVerifier verifies signatures",
        fn ->
          certificate_verifier_signatures(ctx)
        end
      ),
      Check.run(
        "c2.crypto_verifier_primitives",
        :c2,
        "crypto primitives verify and fail closed",
        fn ->
          crypto_verifier_primitives(ctx)
        end
      ),
      Check.run(
        "c2.authority_service_project",
        :c2,
        "authority_service/ separate mix project",
        fn ->
          separate_project(ctx, "authority_service")
        end
      ),
      Check.run("c2.actuator_project", :c2, "actuator/ separate mix project", fn ->
        separate_project(ctx, "actuator")
      end),
      Check.run(
        "c2.no_signing_key_material",
        :c2,
        "no signing key material in control-plane config",
        fn ->
          no_signing_key_material(ctx)
        end
      ),
      Check.run(
        "c2.release_distribution_none",
        :c2,
        "RELEASE_DISTRIBUTION=none in the separate releases",
        fn ->
          release_distribution_none(ctx, [{"authority_service", nil}, {"actuator", nil}])
        end
      )
    ]
  end

  # -- certificate verifier --

  def certificate_verifier_signatures(ctx) do
    ctx = Context.build(ctx)
    verifier = ctx.certificate_verifier

    if not (Code.ensure_loaded?(verifier) and function_exported?(verifier, :verify, 3)) do
      {:fail, "#{inspect(verifier)} has no verify/3"}
    else
      probe_verifier(verifier)
    end
  end

  defp probe_verifier(verifier) do
    if not Fx.available?() do
      {:fail, "Sa2aCrypto (sa2a_crypto) is not loadable: no cryptographic standing provider"}
    else
      run_probe(verifier)
    end
  end

  defp run_probe(verifier) do
    signer = Fx.signer("probe-custodian")
    stranger = Fx.signer("stranger-custodian")
    effect = Fx.effect()
    other_effect = Fx.effect(%{n: 2})
    vctx = Fx.verify_ctx([signer])
    cert = &Fx.certificate(effect, &1)
    good = Fx.sign(effect, signer)

    garbage = [
      {"64 random bytes over a registered kid",
       %{good | signature: :crypto.strong_rand_bytes(64)}},
      {"wrong-size signature", %{good | signature: <<1, 2, 3>>}},
      {"empty signature", %{good | signature: <<>>}},
      {"legacy algorithm-atom entry with garbage bytes",
       %{signer: "s", algorithm: :eddsa, signature: :crypto.strong_rand_bytes(64)}},
      {"valid signature by an unregistered key", Fx.sign(effect, stranger)},
      {"valid signature over a different effect", Fx.sign(other_effect, signer)}
    ]

    with :ok <- mediation_admits?(effect, cert.([good]), vctx) do
      accepted =
        for {label, sig} <- garbage, verifier.verify(cert.([sig]), effect, vctx) == :ok, do: label

      unsigned_accepted? = verifier.verify(cert.([]), effect, vctx) == :ok
      positive = verifier.verify(cert.([good]), effect, vctx)

      cond do
        accepted != [] ->
          {:fail, "garbage signature ACCEPTED: #{Enum.join(accepted, ", ")}"}

        unsigned_accepted? ->
          {:fail, "certificate with no signatures ACCEPTED"}

        positive == :ok ->
          {:pass,
           "#{length(garbage)} bad signatures (garbage, wrong-size, unregistered key, wrong effect) and an unsigned certificate refused; a real Ed25519 signature accepted"}

        true ->
          {:unverified,
           "bad signatures refused but the validly signed positive control was also refused (#{inspect(positive, limit: 5)}): cannot distinguish verification from refuse-all"}
      end
    end
  end

  defp mediation_admits?(effect, cert, vctx) do
    case CompleteMediation.admit(effect, cert, vctx) do
      :ok ->
        :ok

      other ->
        {:unverified,
         "probe fixture not admitted by CompleteMediation (#{inspect(other)}); probe invalid"}
    end
  end

  # -- crypto primitives --

  def crypto_verifier_primitives(ctx) do
    ctx = Context.build(ctx)
    v = ctx.crypto_verifier
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    msg = "sa2a conformance message"
    sig = :crypto.sign(:eddsa, :none, msg, [priv, :ed25519])

    results = %{
      good: safe(fn -> v.verify(:eddsa, msg, sig, pub) end),
      tampered: safe(fn -> v.verify(:eddsa, msg <> "x", sig, pub) end),
      garbage: safe(fn -> v.verify(:eddsa, msg, :crypto.strong_rand_bytes(64), pub) end),
      short_key: safe(fn -> v.verify(:eddsa, msg, sig, <<1, 2, 3>>) end),
      short_sig: safe(fn -> v.verify(:eddsa, msg, <<1>>, pub) end),
      ml_dsa: safe(fn -> v.verify(:ml_dsa, msg, sig, pub) end)
    }

    refused? = fn r -> r in [false] or match?({:error, _}, r) end

    cond do
      results.good != true ->
        {:fail, "real Ed25519 signature not verified: #{inspect(results.good)}"}

      not Enum.all?([:tampered, :garbage, :short_key, :short_sig], &refused?.(results[&1])) ->
        {:fail,
         "invalid inputs not refused: #{inspect(Map.take(results, [:tampered, :garbage, :short_key, :short_sig]))}"}

      not match?({:error, _}, results.ml_dsa) ->
        {:fail, "ML-DSA did not fail closed with a typed refusal: #{inspect(results.ml_dsa)}"}

      true ->
        {:pass,
         "Ed25519 verifies real signature, refuses tampered/garbage/wrong-size (no raise); ML-DSA fails closed with #{inspect(results.ml_dsa)}"}
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> {:raised, Exception.message(e)}
  end

  # -- separate projects --

  @doc false
  def project_info(ctx, dir) do
    path = Path.join(ctx.root, dir)
    mix_exs = Path.join(path, "mix.exs")

    if File.regular?(mix_exs) do
      load_mix_exs(path, mix_exs)
    else
      {:error, "#{dir}/ does not exist under #{ctx.root} (no mix.exs)"}
    end
  end

  # Evaluates the project's real mix.exs (its `project/0`, with private `deps/0`
  # already evaluated) in an isolated compile, then purges the module so a
  # later evaluation of a different tree cannot see a cached one.
  defp load_mix_exs(path, mix_exs) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    project_before = Mix.Project.get()

    try do
      {mods, _diagnostics} = Code.with_diagnostics(fn -> Code.compile_file(mix_exs) end)

      result =
        Enum.find_value(mods, fn {mod, _bin} ->
          if function_exported?(mod, :project, 0), do: mod.project()
        end)

      Enum.each(mods, fn {mod, _} ->
        :code.purge(mod)
        :code.delete(mod)
      end)

      case result do
        config when is_list(config) ->
          {:ok, %{path: path, app: config[:app], deps: List.wrap(config[:deps])}}

        _ ->
          {:error, "#{mix_exs} defines no project/0"}
      end
    rescue
      e -> {:error, "#{mix_exs} failed to load: #{Exception.message(e)}"}
    after
      restore_project_stack(project_before)
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  # `use Mix.Project` pushes the evaluated module onto the process-global Mix
  # project stack when it compiles. Left there, every later
  # `Mix.Task.run("app.start")` in this VM would compile the sibling project
  # and prune the code path. Pop exactly what evaluation pushed.
  defp restore_project_stack(project_before) do
    if Mix.Project.get() != project_before and Mix.Project.get() != nil do
      Mix.Project.pop()
      restore_project_stack(project_before)
    end
  end

  def separate_project(ctx, dir) do
    ctx = Context.build(ctx)

    with {:ok, info} <- project_info(ctx, dir),
         :ok <- not_control_plane(ctx, dir, info) do
      {:pass,
       "#{dir}/ is mix project :#{info.app} with #{length(info.deps)} dep(s), none on the control plane (:#{ctx.control_plane_app})"}
    else
      {:error, why} -> {:fail, why}
    end
  end

  defp not_control_plane(ctx, dir, info) do
    root = Path.expand(ctx.root)

    offending =
      Enum.filter(info.deps, fn dep ->
        name = if is_tuple(dep), do: elem(dep, 0), else: dep
        opts = dep |> Tuple.to_list() |> Enum.filter(&Keyword.keyword?/1) |> List.flatten()

        path_dep =
          case opts[:path] do
            p when is_binary(p) -> Path.expand(p, info.path) == root
            _ -> false
          end

        name == ctx.control_plane_app or path_dep
      end)

    cond do
      info.app == ctx.control_plane_app ->
        {:error,
         "#{dir}/ is the control plane app :#{ctx.control_plane_app}, not a separate project"}

      offending != [] ->
        {:error,
         "#{dir}/ depends on the control plane (:#{ctx.control_plane_app}): #{inspect(offending, limit: 3)}"}

      true ->
        :ok
    end
  end

  # -- key material --

  @key_name ~r/(private|signing|secret)[_-]?key|^signing[_-]?seed$/i

  def no_signing_key_material(ctx) do
    ctx = Context.build(ctx)

    found =
      scan(ctx.app_env, [:ash_a2a]) ++
        for {name, val} <- ctx.env,
            name =~ ~r/\A(SA2A|ASH_A2A)_.*(SIGNING|PRIVATE)[A-Z_]*KEY/,
            val not in [nil, ""],
            do: "env var #{name} set"

    if found == [],
      do:
        {:pass,
         "scanned :ash_a2a application env (PEM private keys, JWK d, *signing/private/secret_key entries) and SA2A_/ASH_A2A_ signing env vars: none"},
      else:
        {:fail, "signing key material reachable from control plane: " <> Enum.join(found, "; ")}
  end

  defp scan(term, path) when is_binary(term) do
    if term =~ ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,
      do: ["PEM private key at #{fmt(path)}"],
      else: []
  end

  defp scan(term, path) when is_list(term) do
    if Keyword.keyword?(term) and term != [],
      do: scan_pairs(term, path),
      else: term |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> scan(v, [i | path]) end)
  end

  defp scan(%{} = term, path) when not is_struct(term) do
    jwk =
      if (Map.has_key?(term, "d") or Map.has_key?(term, :d)) and
           (Map.has_key?(term, "kty") or Map.has_key?(term, :kty)),
         do: ["JWK private component d at #{fmt(path)}"],
         else: []

    jwk ++ scan_pairs(Map.to_list(term), path)
  end

  defp scan(term, path) when is_tuple(term), do: scan(Tuple.to_list(term), path)
  defp scan(_, _), do: []

  defp scan_pairs(pairs, path) do
    Enum.flat_map(pairs, fn
      {k, v} ->
        here =
          if to_string(k) =~ @key_name and v not in [nil, "", []],
            do: ["#{fmt([k | path])} carries a key-named value"],
            else: []

        here ++ scan(v, [k | path])

      other ->
        scan(other, path)
    end)
  end

  defp fmt(path), do: path |> Enum.reverse() |> Enum.map_join(".", &to_string/1)

  # -- release distribution --

  def release_distribution_none(ctx, projects) do
    ctx = Context.build(ctx)

    results =
      Enum.map(projects, fn {dir, app} -> release_verdict(ctx, dir, app) end)

    fails = for {:fail, why} <- results, do: why
    unver = for {:unverified, why} <- results, do: why

    cond do
      fails != [] ->
        {:fail, Enum.join(fails, "; ")}

      unver != [] ->
        {:unverified, Enum.join(unver, "; ")}

      true ->
        {:pass,
         "release env.sh of #{length(projects)} project(s) sets RELEASE_DISTRIBUTION=none in template and built release"}
    end
  end

  @none ~r/^\s*(export\s+)?RELEASE_DISTRIBUTION=["']?none["']?\s*$/m

  defp release_verdict(ctx, dir, app) do
    base = Path.join(ctx.root, dir)
    template = Path.join(base, "rel/env.sh.eex")

    app =
      app ||
        case project_info(ctx, dir) do
          {:ok, %{app: a}} -> a
          _ -> nil
        end

    built = Path.wildcard(Path.join(base, "_build/*/rel/#{app}/releases/*/env.sh"))

    cond do
      is_nil(app) or not File.dir?(base) ->
        {:fail, "#{dir}/ is not a mix project: no release to configure"}

      not (File.regular?(template) and File.read!(template) =~ @none) ->
        {:fail, "#{dir}/rel/env.sh.eex does not set RELEASE_DISTRIBUTION=none"}

      built == [] ->
        {:unverified,
         "#{dir}: template sets RELEASE_DISTRIBUTION=none but no built release exists to inspect (build with MIX_ENV=prod mix release)"}

      Enum.all?(built, &(File.read!(&1) =~ @none)) ->
        {:pass, "ok"}

      true ->
        {:fail, "#{dir}: built release env.sh does not set RELEASE_DISTRIBUTION=none"}
    end
  end
end
