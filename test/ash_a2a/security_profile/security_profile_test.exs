# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityProfileTest do
  @moduledoc """
  RFC-SA2A-007 profile court. Real modules, real compilation, real BEAM
  inspection; no doubles. `async: false` because it mutates `:ash_a2a` env.

  Prod-mode behaviour is exercised by really compiling fixture modules from
  `AshA2A.SecurityProfile.Template` with `env: :prod`, because the suite
  itself runs under `MIX_ENV=test` and the real `AshA2A.SecurityProfile` is
  compiled as `:dev_bypass` there (config/config.exs).
  """
  use ExUnit.Case, async: false

  alias AshA2A.SecurityProfile

  defp compile_fixture(env, requested) do
    name = "AshA2A.SecurityProfileTest.Fixture#{System.unique_integer([:positive])}"

    src = """
    defmodule #{name} do
      use AshA2A.SecurityProfile.Template, env: #{inspect(env)}, requested: #{inspect(requested)}
    end
    """

    # The BEAM scan reads debug_info, which the test env may compile without.
    prior = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    [{mod, bin}] =
      try do
        Code.compile_string(src, "security_profile_fixture.ex")
      after
        Code.put_compiler_option(:debug_info, prior)
      end

    on_exit(fn -> :code.purge(mod) && :code.delete(mod) end)
    {mod, bin}
  end

  # Every atom appearing in the module's compiled definitions (Elixir
  # debug_info: function heads, bodies and specs after macro expansion).
  defp atom_literals(bin) do
    {:ok, {mod, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(bin, [:debug_info])

    {:ok, forms} = backend.debug_info(:elixir_v1, mod, data, [])
    collect(forms, MapSet.new())
  end

  defp collect(a, acc) when is_atom(a), do: MapSet.put(acc, a)
  defp collect(m, acc) when is_map(m), do: m |> Map.to_list() |> collect(acc)
  defp collect(t, acc) when is_tuple(t), do: t |> Tuple.to_list() |> collect(acc)
  defp collect(l, acc) when is_list(l), do: Enum.reduce(l, acc, &collect/2)
  defp collect(_, acc), do: acc

  describe "the real module under MIX_ENV=test" do
    test "selects dev_bypass from build config and reports it consistently" do
      assert SecurityProfile.current() == :dev_bypass
      assert SecurityProfile.dev_bypass?()
      refute SecurityProfile.strict?()
      assert SecurityProfile.dev_bypass_compiled?()
    end

    test "stamp/1 adds the profile and overwrites caller-supplied values" do
      assert %{a: 1, security_profile: :dev_bypass} = SecurityProfile.stamp(%{a: 1})

      forged =
        SecurityProfile.stamp(%{"security_profile" => "strict", :security_profile => :strict})

      assert forged.security_profile == :dev_bypass
      refute Map.has_key?(forged, "security_profile")
    end

    test "no call-site knob exists: current is arity 0 and runtime env cannot switch it" do
      refute function_exported?(SecurityProfile, :current, 1)
      refute function_exported?(SecurityProfile, :strict?, 1)

      prior = Application.fetch_env(:ash_a2a, :security_profile)
      on_exit(fn -> restore(:security_profile, prior) end)

      Application.put_env(:ash_a2a, :security_profile, :strict)
      assert SecurityProfile.current() == :dev_bypass
    end

    test "request data cannot switch the profile through stamp/1" do
      meta = %{"security_profile" => "strict", :security_profile => :strict, :profile => :strict}
      assert SecurityProfile.stamp(meta).security_profile == SecurityProfile.current()
    end
  end

  describe "template profiles" do
    test "default-less strict build" do
      {m, _} = compile_fixture(:dev, :strict)
      assert m.current() == :strict
      assert m.strict?()
      refute m.dev_bypass?()
      assert m.stamp(%{}) == %{security_profile: :strict}
    end

    test "legacy_compat is explicit and not strict" do
      {m, _} = compile_fixture(:prod, :legacy_compat)
      assert m.current() == :legacy_compat
      assert m.legacy_compat?()
      refute m.strict?()
    end

    test "an unknown profile is a compile error" do
      err =
        assert_raise CompileError, fn -> compile_fixture(:dev, :yolo) end

      assert err.description =~ "unknown security profile"
    end
  end

  describe "dev_bypass is compiled out of prod" do
    test "requesting dev_bypass in a prod build raises CompileError with a clear message" do
      err = assert_raise CompileError, fn -> compile_fixture(:prod, :dev_bypass) end
      assert err.description =~ "dev_bypass"
      assert err.description =~ "prod"
    end

    test "BEAM scan: prod build has no dev_bypass functions, literals or banner" do
      {prod, prod_bin} = compile_fixture(:prod, :strict)
      {dev, dev_bin} = compile_fixture(:dev, :dev_bypass)

      # Positive control: the scan can see dev_bypass when it exists.
      assert function_exported?(dev, :announce_dev_bypass, 0)
      assert function_exported?(dev, :dev_bypass_banner, 0)
      assert MapSet.member?(atom_literals(dev_bin), :dev_bypass)

      # Prod: functions absent, atom literal absent, predicate constant false.
      refute function_exported?(prod, :announce_dev_bypass, 0)
      refute function_exported?(prod, :dev_bypass_banner, 0)
      refute MapSet.member?(atom_literals(prod_bin), :dev_bypass)
      refute prod.dev_bypass?()
      refute prod.dev_bypass_compiled?()
    end
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:ash_a2a, key, v)
  defp restore(key, :error), do: Application.delete_env(:ash_a2a, key)
end
