defmodule AshA2A.SupplyChain.ReleasePathTest do
  @moduledoc """
  Release-path court: one publisher, no scheduled publisher, EKV_BUILD wherever
  `mix` runs, authority admitted first, and version coherence across mix.exs and
  the one admitted restatement site (`docs/reference/a2a-spec-version-mapping.md`),
  refusing any second restatement (v26.10.2 EL1). Reads the real workflow files
  with the real `YamlElixir` parser; the version comparison is a pure function
  that is also exercised on a deliberately mismatched pair (red-first: the
  detector must report the mismatch).
  """

  use ExUnit.Case, async: true

  @root File.cwd!()
  @workflows Path.wildcard(Path.join(@root, ".github/workflows/*.yml"))

  defp yaml!(path), do: YamlElixir.read_from_file!(path)

  defp steps(wf), do: for({_j, job} <- wf["jobs"] || %{}, step <- job["steps"] || [], do: step)

  defp run_lines(wf) do
    wf
    |> steps()
    |> Enum.flat_map(&String.split(&1["run"] || "", "\n"))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&String.starts_with?(&1, "#"))
  end

  defp publishes?(wf), do: Enum.any?(run_lines(wf), &(&1 =~ ~r/\bmix hex\.publish\b/))

  @doc false
  def version_findings(mix_version, docs) when is_binary(mix_version) and is_map(docs) do
    for {name, text} <- docs,
        found = doc_version(text),
        found != mix_version,
        do: {name, found, mix_version}
  end

  defp doc_version(text) do
    case Regex.run(~r/Version:\s*v?(\d+\.\d+\.\d+)/, text) do
      [_, v] -> v
      nil -> "MISSING"
    end
  end

  defp mix_version do
    [_, v] = Regex.run(~r/^\s*version:\s*"([^"]+)"/m, File.read!(Path.join(@root, "mix.exs")))
    v
  end

  test "exactly one workflow can run `mix hex.publish`, and it is release.yml" do
    publishers = for p <- @workflows, publishes?(yaml!(p)), do: Path.basename(p)
    assert publishers == ["release.yml"]
  end

  # `on:` may be a bare string (`on: push`) — Access would crash on a binary.
  defp trigger(wf, key) do
    case Map.get(wf, "on") do
      m when is_map(m) -> Map.get(m, key)
      _ -> nil
    end
  end

  test "no workflow with a schedule trigger publishes, and release.yml has none" do
    scheduled =
      for p <- @workflows, wf = yaml!(p), trigger(wf, "schedule"), do: {p, wf}

    assert scheduled != [], "anti-vacuity: flake-hunt/conformance are scheduled"
    assert Enum.all?(scheduled, fn {_p, wf} -> not publishes?(wf) end)

    release = yaml!(Path.join(@root, ".github/workflows/release.yml"))
    refute trigger(release, "schedule")
    refute get_in(release, ["on", "push", "branches"])
    refute File.exists?(Path.join(@root, ".github/workflows/release-v26.9.29.yml"))
  end

  test "every workflow that runs mix sets EKV_BUILD" do
    offenders =
      for p <- @workflows,
          wf = yaml!(p),
          Enum.any?(run_lines(wf), &(&1 =~ ~r/(^|\s)mix\s/)),
          not ekv_build_set?(wf),
          do: Path.basename(p)

    assert offenders == []
  end

  # EKV_BUILD is lawful at workflow, job, or step level.
  defp ekv_build_set?(wf) do
    workflow_level = get_in(wf, ["env", "EKV_BUILD"]) == "1"

    job_level =
      wf
      |> Map.get("jobs", %{})
      |> Map.values()
      |> Enum.any?(fn job ->
        get_in(job, ["env", "EKV_BUILD"]) == "1" or
          Enum.any?(job["steps"] || [], fn step ->
            get_in(step, ["env", "EKV_BUILD"]) == "1"
          end)
      end)

    workflow_level or job_level
  end

  test "release.yml's first step admits HEX_API_KEY presence before any build work" do
    release = yaml!(Path.join(@root, ".github/workflows/release.yml"))
    [first | _] = steps(release)
    refute first["uses"], "first step must be the authority check, not a checkout"
    assert first["env"]["HEX_API_KEY"] =~ "secrets.HEX_API_KEY"
    assert first["run"] =~ "BLOCKED(authority:HEX_API_KEY)"
  end

  test "release.yml has a non-publishing dry run that verifies attestations and attests crate SBOMs" do
    release = yaml!(Path.join(@root, ".github/workflows/release.yml"))
    assert Map.has_key?(release["on"], "workflow_dispatch")

    publish = Enum.find(steps(release), &(&1["name"] == "Publish to Hex"))
    assert publish["if"] =~ "github.event_name == 'push'"

    text = Enum.join(run_lines(release), "\n")
    assert text =~ ~s(gh attestation verify "ash_a2a-$VERSION.tar")

    sboms =
      for s <- steps(release),
          String.starts_with?(s["uses"] || "", "actions/attest-sbom@"),
          do: get_in(s, ["with", "sbom-path"])

    assert Enum.any?(sboms, &(&1 =~ "hddl_cli-"))
    assert Enum.any?(sboms, &(&1 =~ "graphlaw_host-"))
  end

  test "supporting supply-chain files exist (dependabot, CODEOWNERS, scorecard)" do
    dep = yaml!(Path.join(@root, ".github/dependabot.yml"))
    ecosystems = for u <- dep["updates"], do: {u["package-ecosystem"], u["directory"]}

    for e <- [
          {"mix", "/"},
          {"cargo", "/native/hddl_cli"},
          {"cargo", "/native/graphlaw_host"},
          {"github-actions", "/"}
        ],
        do: assert(e in ecosystems)

    assert File.exists?(Path.join(@root, ".github/CODEOWNERS"))
    score = yaml!(Path.join(@root, ".github/workflows/scorecard.yml"))

    assert Enum.any?(
             steps(score),
             &String.starts_with?(&1["uses"] || "", "ossf/scorecard-action@")
           )
  end

  describe "version coherence" do
    test "the comparison detects a mismatched pair (red-first)" do
      docs = %{
        "a" => "Version: v26.9.27\n",
        "b" => "no version line",
        "c" => "Version: v26.9.28."
      }

      assert Enum.sort(version_findings("26.9.28", docs)) ==
               [{"a", "26.9.27", "26.9.28"}, {"b", "MISSING", "26.9.28"}]

      assert version_findings("26.9.28", %{"c" => "Version: v26.9.28."}) == []
    end

    test "mix.exs and the one admitted restatement site (spec-version mapping) agree" do
      docs = %{
        "docs/reference/a2a-spec-version-mapping.md" =>
          File.read!(Path.join(@root, "docs/reference/a2a-spec-version-mapping.md"))
      }

      assert version_findings(mix_version(), docs) == []
    end

    test "no other doc restates the package version (EL1: one admitted site)" do
      guarded =
        [
          "README.md",
          "CHANGELOG.md",
          "docs/reference",
          "docs/how-to",
          "docs/tutorials",
          "docs/explanation",
          "docs/jira"
        ]
        |> Enum.flat_map(fn path ->
          full = Path.join(@root, path)

          if File.dir?(full) do
            Path.wildcard(Path.join(full, "**/*.md"))
          else
            [full]
          end
        end)
        |> List.delete(Path.join(@root, "docs/reference/a2a-spec-version-mapping.md"))

      restatements =
        for path <- guarded,
            Regex.match?(~r/Version:\s*v?\d+\.\d+\.\d+/, File.read!(path)),
            do: Path.relative_to(path, @root)

      assert restatements == [],
             "docs outside mix.exs restate the package version; the one admitted " <>
               "site is docs/reference/a2a-spec-version-mapping.md — remove the " <>
               "restatements instead of syncing them: #{inspect(restatements)}"
    end
  end
end
