# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Docs.ModuleIndexCourtTest do
  @moduledoc """
  Module-citation and doc-link court (v26.10.2 ERRC RD4 + RA2), re-derived
  from the real tree at test time:

    * every `AshA2A.*` module citation in the indexed docs (README and the
      reference/how-to/tutorial/explanation pages; the CHANGELOG history log
      is out of scope) resolves to a real module defined under `lib/` (or an
      explicit registered-name allowlist entry);
    * every relative `docs/...` link from those pages resolves to a file;
    * every doc linked from README is either in `mix.exs`'s ExDoc `extras`
      (HexDocs-bound) or explicitly marked `repo-only` on its README line.

  Pure `findings/...` functions + red-first witnesses (CR1).
  """

  use ExUnit.Case, async: true

  @root File.cwd!()
  @indexed_dirs ~w(docs/reference docs/tutorials docs/how-to docs/explanation)

  # Modules docs may legitimately cite: lib/ plus the real fixture/support
  # and test modules named in the how-tos. Relative nested modules
  # (`defmodule Error do` inside its parent) are allowlisted explicitly.
  @doc false
  def lib_modules do
    for path <-
          Path.wildcard(Path.join(@root, "lib/**/*.ex")) ++
            Path.wildcard(Path.join(@root, "lib/*.ex")) ++
            Path.wildcard(Path.join(@root, "test/**/*.exs")) ++
            Path.wildcard(Path.join(@root, "test/*.exs")) ++
            Path.wildcard(Path.join(@root, "test/support/**/*.ex")) ++
            Path.wildcard(Path.join(@root, "test/support/*.ex")),
        text = File.read!(path),
        m <- Regex.scan(~r/^\s*defmodule\s+([A-Z][\w.]+) do/m, text),
        into: MapSet.new(),
        do: hd(tl(m))
  end

  # Relative nested defmodules (declared without a fully-qualified name).
  @registered_names MapSet.new([
                      "AshA2A.Telemetry.TaskSupervisor",
                      "AshA2A.Authority.SecurityPreflight.Error"
                    ])

  @doc false
  def indexed_files do
    # CHANGELOG is deliberately excluded: it is an append-only history log
    # whose entries legitimately name past-era modules that no longer exist.
    (["README.md"] ++
       Enum.flat_map(@indexed_dirs, &Path.wildcard(Path.join(@root, &1 <> "/*.md"))))
    |> MapSet.new()
  end

  @doc false
  def citation_findings(modules, files) do
    unresolved =
      for path <- files,
          text = File.read!(path),
          token <- Regex.scan(~r/AshA2A(?:\.[A-Z]\w+)+/, text) |> Enum.map(&hd/1) |> Enum.uniq(),
          not MapSet.member?(modules, token),
          not MapSet.member?(@registered_names, token),
          not Enum.any?(modules, &String.starts_with?(&1, token <> ".")),
          do: {Path.relative_to(path, @root), token}

    %{unresolved: Enum.uniq(unresolved)}
  end

  @doc false
  def link_findings(files) do
    broken =
      for path <- files,
          text = File.read!(path),
          link <- Regex.scan(~r/\]\((docs\/[^)#\s]+)\)/, text) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq(),
          not File.exists?(Path.join(@root, link)),
          do: {Path.relative_to(path, @root), link}

    %{broken: Enum.uniq(broken)}
  end

  @doc false
  def extras_paths do
    mix_exs = File.read!(Path.join(@root, "mix.exs"))

    Regex.scan(~r/"((?:docs\/|README\.md|CHANGELOG\.md)[^"]*)"/, mix_exs)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.uniq()
    |> MapSet.new()
  end

  @doc false
  def readme_doc_findings(readme_text, extras) do
    unaccounted =
      for link <- Regex.scan(~r/\]\((docs\/[^)#\s]+)\)/, readme_text) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq(),
          line = readme_text |> String.split("\n") |> Enum.find(&String.contains?(&1, "(" <> link <> ")")),
          not MapSet.member?(extras, link),
          not String.contains?(line, "repo-only"),
          do: link

    %{unaccounted: Enum.sort(unaccounted)}
  end

  test "every AshA2A.* citation in the indexed docs resolves (RD4)" do
    findings = citation_findings(lib_modules(), indexed_files())

    assert findings.unresolved == [],
           "docs cite modules that do not exist under lib/ " <>
             "(fix the citation or register the name): #{inspect(findings.unresolved)}"
  end

  test "every relative docs/ link in the indexed docs resolves (RD4)" do
    findings = link_findings(indexed_files())

    assert findings.broken == [],
           "broken relative docs links: #{inspect(findings.broken)}"
  end

  test "every README-linked doc is HexDocs-bound or marked repo-only (RA2)" do
    findings = readme_doc_findings(File.read!(Path.join(@root, "README.md")), extras_paths())

    assert findings.unaccounted == [],
           "README links docs that are neither in mix.exs docs extras nor marked " <>
             "repo-only: #{inspect(findings.unaccounted)}"
  end

  test "red-first: planted citations, links, and an unaccounted README doc are detected (CR1)" do
    modules = MapSet.new(["AshA2A.Real"])
    planted_text = "see AshA2A.Ghost.Module and [ghost](docs/ghost.md)\n"

    # Feed the detectors mutated text through the same pure functions the
    # real tests use: a temp file exercises citation/link findings without
    # touching the shared README.
    tmp = Path.join([@root, "tmp", "module_index_court_witness_#{System.unique_integer()}.md"])
    File.mkdir_p!(Path.dirname(tmp))
    File.write!(tmp, planted_text)

    try do
      assert citation_findings(modules, MapSet.new([tmp])).unresolved ==
               [{Path.relative_to(tmp, @root), "AshA2A.Ghost.Module"}]

      assert link_findings(MapSet.new([tmp])).broken ==
               [{Path.relative_to(tmp, @root), "docs/ghost.md"}]
    after
      File.rm(tmp)
    end

    assert readme_doc_findings(planted_text, MapSet.new()).unaccounted == ["docs/ghost.md"]
  end
end
