defmodule DocsNavCoverageTest do
  @moduledoc """
  Nav-coverage court: every file in the Diátaxis quadrants
  (docs/{tutorials,how-to,reference,explanation}) must be indexed in docs/README.md,
  and every docs/README.md entry must point at a real file. Also checks that every
  relative .md fragment link inside docs/ resolves to a real heading.
  Ported from the xaas docs/claude/diataxis/README.md pattern.
  """

  use ExUnit.Case, async: true

  @docs_dir Path.join(File.cwd!(), "docs")
  @readme Path.join(@docs_dir, "README.md")
  @quadrants ~w(tutorials how-to reference explanation)

  defp readme_entries do
    readme = File.read!(@readme)

    ~r{\]\(([^)#\s]+\.md)\)}
    |> Regex.scan(readme, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  defp quadrant_files do
    @quadrants
    |> Enum.flat_map(fn q ->
      @docs_dir
      |> Path.join("#{q}/*.md")
      |> Path.wildcard()
      |> Enum.map(fn f -> "#{q}/#{Path.basename(f)}" end)
    end)
    |> MapSet.new()
  end

  defp slugify(line) do
    line
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "-")
  end

  defp headings(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ ~r/^#+\s/))
    |> Enum.map(&(slugify(String.replace(&1, ~r/^#+\s/, ""))))
  end

  test "docs/README.md exists and is the nav surface" do
    assert File.exists?(@readme)
  end

  # README -> files
  test "every docs/README.md entry points at a real file" do
    orphan_entries =
      readme_entries()
      |> Enum.reject(&File.exists?(Path.join(@docs_dir, &1)))

    assert orphan_entries == [],
           "docs/README.md links to missing files: #{inspect(orphan_entries)}"
  end

  # files -> README
  test "every quadrant file is indexed in docs/README.md (both directions)" do
    entries = readme_entries()
    files = quadrant_files()

    assert MapSet.subset?(files, entries),
           "quadrant files missing from docs/README.md: #{inspect(MapSet.difference(files, entries) |> MapSet.to_list())}"
  end

  # fragment anchors inside docs/
  test "every relative .md fragment link in docs/ resolves to a real heading" do
    files = MapSet.to_list(quadrant_files()) ++ ["README.md"]
    Enum.each(files, fn f ->
      path = Path.join(@docs_dir, f)
      dir = Path.dirname(path)
      text = File.read!(path)

      ~r{\]\(([^)#\s]+\.md)(#[^)\s]+)\)}
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.each(fn [rel, frag] ->
        target = Path.join(dir, rel)

        # only in-docs relative targets are in scope; skip anything outside docs/
        if File.exists?(target) and String.contains?(Path.expand(target), @docs_dir) do
          frag = String.trim_leading(frag, "#")
          heads = headings(target)

          assert frag in heads,
                 "broken anchor in #{f}: #{rel}##{frag} " <>
                   "(headings: #{inspect(heads)})"
        end
      end)
    end)
  end
end
