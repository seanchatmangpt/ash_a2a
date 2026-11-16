defmodule DocsTruthWave2Test do
  @moduledoc """
  Docs-truth court (wave 2).

  Asserts from the files: cited test paths/titles exist, no row is CONFORMANT or
  REAL_INTEGRATED while its text says UNVERIFIED, every mix task is mentioned in docs,
  relative links resolve (docs/archive skipped), and CHANGELOG [Unreleased] entries do
  not claim "verified" without a test path or "unverified".
  """

  use ExUnit.Case, async: true

  @root File.cwd!()
  @index_docs ~w(docs/reference/index.md docs/reference/conformance-claim.md
                 docs/reference/conformance-profiles.md docs/reference/module-coverage.md)

  defp read(rel), do: File.read!(Path.join(@root, rel))

  defp rows(rel) do
    if File.exists?(Path.join(@root, rel)) do
      rel |> read() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "|"))
    else
      []
    end
  end

  defp doc_files do
    docs =
      Path.join(@root, "docs/**/*.md")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "/docs/archive/"))

    docs ++ [Path.join(@root, "README.md")]
  end

  defp test_files, do: Path.wildcard(Path.join(@root, "test/**/*.{ex,exs}"))

  test "(1) test files and describe/test titles cited by index rows exist in test/" do
    files = test_files()
    basenames = MapSet.new(files, &Path.basename/1)
    sources = Enum.map(files, &File.read!/1)

    missing_files =
      for rel <- @index_docs,
          row <- rows(rel),
          [cite] <- Regex.scan(~r{[A-Za-z0-9_/.-]*_test\.exs}, row),
          not MapSet.member?(basenames, Path.basename(cite)),
          do: {rel, cite}

    assert missing_files == [], "docs cite missing test files: #{inspect(missing_files)}"

    missing_titles =
      for rel <- @index_docs,
          row <- rows(rel),
          [_, title] <- Regex.scan(~r/(?:describe|test) "([^"]+)"/, row),
          not Enum.any?(sources, &String.contains?(&1, title)),
          do: {rel, title}

    assert missing_titles == [], "docs cite missing test titles: #{inspect(missing_titles)}"
  end

  test "(2) no row is CONFORMANT/REAL_INTEGRATED while its text says UNVERIFIED" do
    offenders =
      for path <- doc_files(),
          row <- rows(Path.relative_to(path, @root)),
          row =~ ~r/\b(CONFORMANT|REAL_INTEGRATED)\b/,
          row =~ "UNVERIFIED",
          do: {Path.relative_to(path, @root), String.slice(row, 0, 80)}

    assert offenders == [], "rows labelled conformant yet UNVERIFIED: #{inspect(offenders)}"
  end

  test "(3) every mix task file in lib/mix/tasks has a docs mention" do
    docs_text = doc_files() |> Enum.map_join("\n", &File.read!/1)

    undocumented =
      Path.join(@root, "lib/mix/tasks/*.ex")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".ex"))
      |> Enum.reject(&String.contains?(docs_text, &1))

    assert undocumented == [], "mix tasks with no docs mention: #{inspect(undocumented)}"
  end

  test "(4) every relative link in docs/ (except docs/archive) and README.md resolves" do
    broken =
      for path <- doc_files(),
          [_, link] <- Regex.scan(~r/\]\(([^)\s]+)\)/, File.read!(path)),
          not Regex.match?(~r/^[a-z][a-z0-9+.-]*:/, link),
          not String.starts_with?(link, "#"),
          target = link |> String.split("#") |> hd() |> String.split("?") |> hd(),
          target != "",
          not File.exists?(Path.expand(target, Path.dirname(path))),
          do: {Path.relative_to(path, @root), link}

    assert broken == [], "broken relative links: #{inspect(broken)}"
  end

  test "(5) CHANGELOG [Unreleased] entries say verified only with unverified or a test path" do
    unreleased =
      read("CHANGELOG.md")
      |> String.split("## [Unreleased]")
      |> Enum.at(1)
      |> String.split(~r/\n## \[/)
      |> hd()

    entries =
      unreleased
      |> String.split(~r/\n(?=- )/)
      |> Enum.filter(&String.starts_with?(&1, "- "))

    offenders =
      Enum.filter(entries, fn e ->
        e =~ ~r/(?<![A-Za-z])verified/i and not (e =~ ~r/unverified/i) and
          not (e =~ ~r{test/|_test\.exs})
      end)

    assert offenders == [],
           "CHANGELOG entries claim verified without evidence: #{inspect(Enum.map(offenders, &String.slice(&1, 0, 80)))}"
  end
end
