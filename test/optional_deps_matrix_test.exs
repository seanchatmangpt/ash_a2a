defmodule AshA2A.OptionalDepsMatrixTest do
  # UNVERIFIED: written without an Elixir toolchain; never run.
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  defp mix_optional_deps do
    @root
    |> Path.join("mix.exs")
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*\{:(\w+),.*optional: true/, line) do
        [_, name] -> [name]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  defp script_deps do
    script = File.read!(Path.join(@root, "scripts/check_optional_deps.sh"))
    [_, list] = Regex.run(~r/^OPTIONAL_DEPS="([^"]*)"/m, script)
    list |> String.split() |> Enum.sort()
  end

  test "the script's dependency list equals the optional: true deps in mix.exs" do
    assert mix_optional_deps() != []
    assert script_deps() == mix_optional_deps()
  end

  test "the script has no duplicate entries" do
    assert script_deps() == Enum.uniq(script_deps())
  end

  test "the workflow runs the script" do
    wf = File.read!(Path.join(@root, ".github/workflows/optional-deps.yml"))
    assert wf =~ "scripts/check_optional_deps.sh"
  end
end
