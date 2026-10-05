# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.EnvKeyFixture do
  @moduledoc """
  Shared compile-time `~/.env` key extraction, used by the Z.AI-backed
  FreedomGym LLM tests (`ash_a2a_freedom_gym_llm_test.exs` and
  `ash_a2a_freedom_gym_zai_test.exs`).

  Both tests need a real API key read from `~/.env` before `@moduletag` /
  `@describetag skip:` are evaluated -- i.e. at compile time, before any
  `setup`/`setup_all` callback runs. Module-attribute evaluation happens at
  compile time, but a call to a function in an already-compiled *external*
  module (this one) resolves fine at that point -- Elixir compiles this
  support module first since the test modules reference it. What does NOT
  work is calling a `defp` in the *same* module from its own module
  attribute, since that function isn't yet defined during that module's own
  compilation -- confirmed by a real `CompileError` when that was tried
  originally, which is why the extraction logic was inlined (duplicated,
  and drifted) in both test files before this extraction.

  No mocking: this reads the real `~/.env` file on disk.
  """

  @doc """
  Reads `env_var_name=VALUE` from `~/.env` and returns the trimmed value, or
  `nil` if the file or the key doesn't exist.
  """
  def read_key(env_var_name) when is_binary(env_var_name) do
    env_path = Path.expand("~/.env")

    case File.exists?(env_path) && File.read(env_path) do
      {:ok, contents} ->
        case Regex.run(~r/^#{Regex.escape(env_var_name)}=(.+)$/m, contents) do
          [_, key] -> String.trim(key)
          nil -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Named skip reason for a live-LLM round-trip test, or `nil` to run it.

  Live calls require an explicit opt-in (`ASH_A2A_LIVE_LLM=1`, e.g. via
  `mix test.live`), not merely a key in `~/.env`: `mix test.all` includes
  `:serial` modules, which would otherwise pull paid, slow, nondeterministic
  network calls into the default suite whenever a developer has a key.
  """
  def live_llm_skip_reason(env_var_name \\ "ZAI_API_KEY") do
    cond do
      System.get_env("ASH_A2A_LIVE_LLM") != "1" ->
        "live LLM round-trip: set ASH_A2A_LIVE_LLM=1 (mix test.live) to run"

      is_nil(read_key(env_var_name)) ->
        "#{env_var_name} not found in ~/.env"

      true ->
        nil
    end
  end
end
