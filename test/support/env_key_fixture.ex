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
end
