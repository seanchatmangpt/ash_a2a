# Removes stale top-level `defmodule` blocks from consolidated test files.
#
#   mix run --no-start scripts/dedupe_consolidated_tests.exs <plan.json> <repo_root>
#
# plan.json maps a consolidated test file to the module names to remove from it:
# the modules that are also defined in a separate original test file. See
# docs/reference/test-consolidation-merge.md. Uses the AST for exact line ranges.
[json_path, root] = System.argv()
plan = json_path |> File.read!() |> Jason.decode!()

name_of = fn {:defmodule, _, [{:__aliases__, _, parts} | _]} -> Enum.join(parts, ".") ; _ -> nil end

for {file, mods} <- plan do
  path = Path.join(root, file)
  src = File.read!(path)
  {:ok, ast} = Code.string_to_quoted(src, columns: true, token_metadata: true, file: path)
  nodes = case ast do {:__block__, _, ns} -> ns; n -> [n] end
  mods = MapSet.new(mods)
  ranges =
    for {:defmodule, meta, _} = n <- nodes, name_of.(n) in mods do
      {meta[:line], meta[:end][:line]}
    end
  lines = String.split(src, "\n")
  kept =
    lines
    |> Enum.with_index(1)
    |> Enum.reject(fn {_l, i} -> Enum.any?(ranges, fn {a, b} -> i >= a and i <= b end) end)
    |> Enum.map(&elem(&1, 0))
  note = "# NOTE: #{length(ranges)} module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.\n"
  File.write!(path, note <> Enum.join(kept, "\n"))
  IO.puts("#{file}: removed #{length(ranges)}/#{MapSet.size(mods)}")
end
