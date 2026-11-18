# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.WasmDefaultResolutionTest do
  @moduledoc """
  Permanent guard for `errc/ash-a2a-format` (ash_a2a#27): with NO override set
  (no `opts[:wasm_path]`, no application env, no environment variable), every
  praxis-graphlaw wasm resolver in this library resolves to the vendored,
  git-tracked, MANIFEST-pinned artifact `priv/graphlaw/praxis_graphlaw.wasm`.

  ash_a2a#27 run 35539819401 failed 103 tests on a hosted runner because seven
  resolvers defaulted to `/Users/sac/praxis/...`, a path that exists only on the
  author's machine, although the identical bytes ship in every checkout. This
  module asserts the resolved *state* -- the path, that a real file exists
  there, and that its real sha256 equals the digest `priv/graphlaw/MANIFEST.json`
  pins -- for each resolver. No collaborator is faked; the environment is the
  real process environment, saved and restored around each test.

  `async: false`: it mutates process-global application/OS environment, and
  ExUnit runs every `async: false` module only after all async modules finish,
  so no async module can observe the temporarily cleared overrides.
  """

  use ExUnit.Case, async: false

  alias AshA2A.GraphLaw

  @env_vars ~w(
    SA2A_GRAPHLAW_WASM
    PRAXIS_GRAPHLAW_WASM
    GRAPHLAW_WASM_PATH
    ASH_A2A_GRAPHLAW_WASM
    GRAPHLAW_WASM
  )
  @app_keys [:graphlaw_wasm_path, :sa2a_graphlaw_wasm]
  @semantic_wasm_module AshA2A.Semantic.GraphLaw.Wasm

  @resolvers [
    {"GraphLaw.WasmDriver", AshA2A.GraphLaw.WasmDriver},
    {"GraphLaw.Wasm", AshA2A.GraphLaw.Wasm},
    {"GraphLaw.Runtime", AshA2A.GraphLaw.Runtime},
    {"Semantic.GraphLawBridge", AshA2A.Semantic.GraphLawBridge},
    {"SA2A.Graphlaw", AshA2A.SA2A.Graphlaw},
    {"RootManifest.EngineProbe", AshA2A.Semantic.RootManifest.EngineProbe}
  ]

  setup do
    saved_env = for var <- @env_vars, do: {var, System.get_env(var)}
    saved_app = for key <- @app_keys, do: {key, Application.fetch_env(:ash_a2a, key)}
    saved_semantic = Application.fetch_env(:ash_a2a, @semantic_wasm_module)

    Enum.each(@env_vars, &System.delete_env/1)
    Enum.each(@app_keys, &Application.delete_env(:ash_a2a, &1))
    Application.delete_env(:ash_a2a, @semantic_wasm_module)

    on_exit(fn ->
      for {var, value} <- saved_env do
        if value, do: System.put_env(var, value), else: System.delete_env(var)
      end

      for {key, saved} <- saved_app do
        case saved do
          {:ok, value} -> Application.put_env(:ash_a2a, key, value)
          :error -> Application.delete_env(:ash_a2a, key)
        end
      end

      case saved_semantic do
        {:ok, value} -> Application.put_env(:ash_a2a, @semantic_wasm_module, value)
        :error -> Application.delete_env(:ash_a2a, @semantic_wasm_module)
      end
    end)

    :ok
  end

  defp pinned_sha256 do
    GraphLaw.manifest_path() |> File.read!() |> Jason.decode!() |> get_in(["artifact", "sha256"])
  end

  defp sha256_of(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp assert_is_pinned_vendored_artifact(label, path) do
    assert path == GraphLaw.wasm_path(),
           "#{label} default resolved to #{path}, not the vendored #{GraphLaw.wasm_path()}"

    assert File.regular?(path), "#{label} default #{path} is not a real file"
    assert sha256_of(path) == pinned_sha256()
  end

  for {label, mod} <- @resolvers do
    test "#{label}.wasm_path/0 with no override resolves to the vendored, pinned artifact" do
      assert_is_pinned_vendored_artifact(unquote(label), unquote(mod).wasm_path())
    end
  end

  test "Semantic.GraphLaw.Wasm.wasm_path/0 with no override resolves to the vendored, pinned artifact" do
    assert_is_pinned_vendored_artifact(
      "Semantic.GraphLaw.Wasm",
      @semantic_wasm_module.wasm_path()
    )
  end

  test "AshA2A.SA2A.Graphlaw.available?/0 agrees with node presence alone: the default artifact is never the missing piece" do
    result = AshA2A.SA2A.Graphlaw.available?()

    if System.find_executable("node") do
      assert result == :ok
    else
      assert {:unavailable, reason} = result
      refute reason == :wasm_not_built
    end
  end

  test "an explicit override still wins over the vendored default (precedence is unchanged)" do
    explicit = "/nonexistent/override/praxis_graphlaw.wasm"

    assert AshA2A.GraphLaw.WasmDriver.wasm_path(wasm_path: explicit) == explicit
    assert AshA2A.GraphLaw.Wasm.wasm_path(wasm_path: explicit) == explicit
    assert AshA2A.GraphLaw.Runtime.wasm_path(wasm_path: explicit) == explicit
    assert AshA2A.Semantic.GraphLawBridge.wasm_path(wasm_path: explicit) == explicit
    assert AshA2A.SA2A.Graphlaw.wasm_path(wasm_path: explicit) == explicit
    assert AshA2A.Semantic.RootManifest.EngineProbe.wasm_path(wasm_path: explicit) == explicit

    System.put_env("GRAPHLAW_WASM", explicit)
    assert @semantic_wasm_module.wasm_path() == explicit
  end
end
