# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SupplyChain.SupplyChainPolicyTest do
  @moduledoc """
  Supply-chain policy court over this repository's REAL build/release inputs
  (`.github/workflows/*.yml`, `.github/cargo-deny.toml`, `mix.exs`,
  `.gitignore`, `native/*/Cargo.toml`, `.tool-versions`). Chicago style:
  every assertion reads the actual file (workflows parsed with the real
  `YamlElixir` parser, ignore rules resolved by the real `git check-ignore`,
  the package closure exercised through the real
  `AshA2A.Chicago.Release.CompositionLock.build!/1`) -- nothing is faked.

  Each test is a guard for one audit finding (SC-02, SC-03, SC-06, SC-08,
  SC-09, SC-10, SC-12, TQ-09, TQ-10): removing the guarded line from the
  real file makes the corresponding test fail.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Chicago.Release.CompositionLock

  @root File.cwd!()
  @workflows Path.wildcard(Path.join(@root, ".github/workflows/*.yml"))
  # Local composite actions hold CI steps too; the guards that scan steps must
  # not go blind when a step moves into one.
  @composites Path.wildcard(Path.join(@root, ".github/actions/*/action.yml"))
  @ci_files @workflows ++ @composites
  @sha_pin ~r/^[^@\s]+@[0-9a-f]{40}$/

  defp read!(rel), do: File.read!(Path.join(@root, rel))
  defp yaml!(path), do: YamlElixir.read_from_file!(path)

  defp steps(%{"runs" => %{"steps" => steps}}) when is_list(steps), do: steps

  defp steps(workflow) do
    for {_job, job} <- workflow["jobs"] || %{}, step <- job["steps"] || [], do: step
  end

  defp run_text(workflow), do: workflow |> steps() |> Enum.map_join("\n", &(&1["run"] || ""))

  test "the workflow set is non-empty (anti-vacuity for the per-workflow guards)" do
    assert length(@workflows) >= 5
  end

  describe "SC-06 action pinning and release authority" do
    test "every third-party action is pinned to a full 40-hex commit SHA" do
      unpinned =
        for path <- @ci_files,
            step <- steps(yaml!(path)),
            uses = step["uses"],
            is_binary(uses),
            not String.starts_with?(uses, "./"),
            not Regex.match?(@sha_pin, uses),
            do: {Path.basename(path), uses}

      assert unpinned == []
    end

    test "every workflow declares read-only workflow-scope permissions" do
      # A missing `permissions:` key inherits the repository default token
      # scope (possibly write-all), so absence is an offence, not a pass.
      offenders =
        for path <- @workflows,
            # A generator, not `perms = ...`: in `for`, a match on a nil value
            # is a falsy filter and would silently drop the offender.
            perms <- [yaml!(path)["permissions"]],
            not (is_map(perms) and perms != %{} and
                   Enum.all?(Map.values(perms), &(&1 in ["read", "none"]))),
            do: {Path.basename(path), perms}

      assert offenders == []
    end

    test "checkouts never persist the job token into .git/config" do
      offenders =
        for path <- @workflows,
            step <- steps(yaml!(path)),
            String.starts_with?(step["uses"] || "", "actions/checkout@"),
            get_in(step, ["with", "persist-credentials"]) != false,
            do: Path.basename(path)

      assert offenders == []
    end

    test "the Hex release is tag-triggered, environment-protected and fails closed without HEX_API_KEY" do
      release = yaml!(Path.join(@root, ".github/workflows/release.yml"))
      # YamlElixir decodes the `on:` key as the string "on".
      assert get_in(release, ["on", "push", "tags"]) == ["v*"]
      refute get_in(release, ["on", "push", "branches"])

      job = release["jobs"]["release"]
      assert job["environment"] == "hex-release"
      assert job["permissions"]["contents"] == "write"
      assert job["permissions"]["id-token"] == "write"

      text = run_text(release)
      assert text =~ "BLOCKED(authority:HEX_API_KEY)"
      assert text =~ ~s(test "$tag" = "$version")
      refute File.exists?(Path.join(@root, ".github/workflows/release-v26.9.25.yml"))
    end

    test "SC-07: release produces CycloneDX SBOMs and provenance/SBOM attestations" do
      release = yaml!(Path.join(@root, ".github/workflows/release.yml"))
      uses = release |> steps() |> Enum.map(&(&1["uses"] || ""))
      assert Enum.any?(uses, &String.starts_with?(&1, "actions/attest-build-provenance@"))
      assert Enum.any?(uses, &String.starts_with?(&1, "actions/attest-sbom@"))

      text = run_text(release)
      assert text =~ "mix_sbom\" cyclonedx --only prod"
      assert text =~ "cargo +1.97.1 cyclonedx"
      assert text =~ "gh release upload"

      # The published registry artifact must be the attested one: Hex's outer
      # checksum is compared with the sha256 of the attested tarball.
      verify = Enum.find(steps(release), &(&1["name"] == "Verify Hex consequence"))
      assert verify["run"] =~ ~s(sha256sum "ash_a2a-$VERSION.tar")
      assert verify["run"] =~ ~s([ "$remote_sum" = "$local_sum" ])
      assert verify["run"] =~ "REFUSED(release:hex checksum"
    end

    test "SC-12: release proves the consumer prod closure compiles before publishing" do
      release = yaml!(Path.join(@root, ".github/workflows/release.yml"))

      prod_step =
        Enum.find(steps(release), &(get_in(&1, ["env", "MIX_ENV"]) == "prod"))

      assert prod_step, "no MIX_ENV=prod verification step"
      assert prod_step["run"] =~ "mix deps.get --only prod"
      assert prod_step["run"] =~ "mix compile --warnings-as-errors"
    end
  end

  describe "SC-02 advisory and lock-drift gates" do
    test "CI refuses lock drift, Hex advisories and Rust advisories for both crates" do
      text = run_text(yaml!(Path.join(@root, ".github/workflows/ci.yml")))
      assert text =~ "mix deps.get --check-locked"
      assert text =~ "mix hex.audit"

      for crate <- ~w(hddl_cli graphlaw_host) do
        assert text =~
                 "cargo deny --manifest-path native/#{crate}/Cargo.toml " <>
                   "--config .github/cargo-deny.toml --locked " <>
                   "check advisories bans licenses sources"
      end
    end

    test "the release refuses lock drift and advisories before building" do
      text = run_text(yaml!(Path.join(@root, ".github/workflows/release.yml")))
      assert text =~ "mix deps.get --check-locked"
      assert text =~ "mix hex.audit"
    end

    test "cargo-deny policy denies yanked crates and unknown git/registry sources" do
      deny = read!(".github/cargo-deny.toml")
      assert deny =~ ~s(yanked = "deny")
      assert deny =~ ~s(unknown-git = "deny")
      assert deny =~ ~s(unknown-registry = "deny")
      assert deny =~ ~s(allow-git = ["https://github.com/seanchatmangpt/ferroplan.git"])
    end
  end

  describe "SC-08 native crate identity" do
    test "every cargo build in every workflow uses the pinned toolchain and --locked" do
      offenders =
        for path <- @ci_files,
            line <- String.split(run_text(yaml!(path)), "\n"),
            line =~ ~r/\bcargo\b.*\bbuild\b/,
            not (line =~ "cargo +1.97.1" and line =~ "--locked"),
            do: {Path.basename(path), String.trim(line)}

      assert offenders == []
    end

    test "native crates pin every dependency exactly, are unpublishable and carry a toolchain pin" do
      for crate <- ~w(hddl_cli graphlaw_host) do
        manifest = read!("native/#{crate}/Cargo.toml")
        [_, deps] = String.split(manifest, "[dependencies]", parts: 2)

        for line <- String.split(deps, "\n", trim: true),
            not String.starts_with?(String.trim(line), "#") do
          assert line =~ ~r/(=\s*"=\d|version\s*=\s*"=\d)/,
                 "#{crate}: dependency not exactly pinned: #{line}"
        end

        assert manifest =~ "publish = false"
        assert read!("native/#{crate}/rust-toolchain.toml") =~ ~s(channel = "1.97.1")
      end
    end
  end

  describe "SC-09 one BEAM toolchain identity" do
    test "every setup-beam step reads .tool-versions strictly (no inline versions)" do
      beam_steps =
        for path <- @ci_files,
            step <- steps(yaml!(path)),
            String.starts_with?(step["uses"] || "", "erlef/setup-beam@"),
            do: {Path.basename(path), step["with"]}

      assert beam_steps != []

      for {file, with} <- beam_steps do
        assert with["version-file"] == ".tool-versions", file
        assert with["version-type"] == "strict", file
        refute Map.has_key?(with, "otp-version"), file
        refute Map.has_key?(with, "elixir-version"), file
      end
    end
  end

  describe "SC-03 deliberate ekv source build" do
    test "every workflow that runs mix sets EKV_BUILD=1 and refuses lock drift" do
      mix_workflows =
        for path <- @workflows,
            wf = yaml!(path),
            text = run_text(wf),
            text =~ ~r/(^|\s)mix\s/m,
            do: {Path.basename(path), wf, text}

      # Anti-vacuity: the release, CI and court workflows all run mix.
      assert length(mix_workflows) >= 8

      for {file, wf, text} <- mix_workflows do
        assert get_in(wf, ["env", "EKV_BUILD"]) == "1", file

        for line <- String.split(text, "\n"), line =~ ~r/\bmix deps\.get\b/ do
          assert line =~ "--check-locked", "#{file}: unlocked deps.get: #{String.trim(line)}"
        end
      end
    end
  end

  describe "SC-10 package closure" do
    test "the Hex package ships the native sources lib/ reads, never build output" do
      files = Mix.Project.config()[:package][:files]

      for crate <- ~w(hddl_cli graphlaw_host), f <- ~w(Cargo.toml Cargo.lock src) do
        path = "native/#{crate}/#{f}"
        assert path in files, "package omits #{path}"
        assert File.exists?(Path.join(@root, path)), "#{path} missing on disk"
      end

      refute Enum.any?(files, &String.contains?(&1, "target"))
    end

    @tag :tmp_dir
    test "CompositionLock resolves every native pin from a package-shaped tree", %{tmp_dir: dir} do
      files = Mix.Project.config()[:package][:files]

      for rel <- files, String.starts_with?(rel, "native/") do
        src = Path.join(@root, rel)
        dst = Path.join(dir, rel)
        File.mkdir_p!(Path.dirname(dst))
        File.cp_r!(src, dst)
      end

      # No mix.lock in the tree: Hex tarballs do not carry it, and the native
      # pins must resolve without it.
      lock = CompositionLock.build!(repo: dir)

      assert lock.native_pins == %{
               "ferroplan" => "e90928d7b0687a959831553c4eacca3d75ca6c88",
               "ferroplan-hddl" => "e90928d7b0687a959831553c4eacca3d75ca6c88"
             }
    end
  end

  describe "SC-12 lane build roots are ignored" do
    test "git ignores per-lane build roots" do
      {out, 0} =
        System.cmd("git", ["check-ignore", "-v", "_build-lane7/x", "_build-merge/y"], cd: @root)

      assert out =~ "_build-lane7/x"
      assert out =~ "_build-merge/y"
    end
  end

  describe "TQ-09/TQ-10 test-quality gates" do
    test "coverage is measured with a non-zero threshold and CI runs it" do
      threshold = get_in(Mix.Project.config(), [:test_coverage, :summary, :threshold])
      assert is_integer(threshold) and threshold > 0

      lines =
        Path.join(@root, ".github/workflows/ci.yml")
        |> yaml!()
        |> run_text()
        |> String.split("\n")

      # Any `mix test[.alias]` run under --cover counts: the suite is split into
      # lanes (fast / serial_solo / serial_shard) that together are `test.all`.
      cover_runs = Enum.filter(lines, &(&1 =~ ~r/mix test(\.\w+)*\b.*--cover\b/))
      assert cover_runs != [], "CI does not run the suite under --cover"

      # `--export-coverage` makes Mix write .coverdata and skip the threshold
      # (witnessed exit 0 at 33% under a 99% floor), so a gated run must not
      # carry it unless a later `mix test.coverage` evaluates the export.
      for line <- cover_runs, line =~ "--export-coverage" do
        assert Enum.any?(lines, &(&1 =~ ~r/^\s*mix test\.coverage\b/)),
               "coverage threshold is never evaluated: #{line}"
      end
    end

    @tag :tmp_dir
    test "the coverage threshold is enforced by a real mix run (exit 3 below the floor)",
         %{tmp_dir: dir} do
      # Real collaborator: a throwaway Mix project run through the same
      # `mix test --cover` invocation CI uses, with this repo's threshold
      # config shape, and one uncovered function to push coverage below it.
      File.write!(Path.join(dir, "mix.exs"), """
      defmodule CovProbe.MixProject do
        use Mix.Project
        def project,
          do: [app: :cov_probe, version: "0.1.0", test_coverage: [summary: [threshold: 99]]]
      end
      """)

      File.mkdir_p!(Path.join(dir, "lib"))
      File.mkdir_p!(Path.join(dir, "test"))

      File.write!(Path.join(dir, "lib/cov_probe.ex"), """
      defmodule CovProbe do
        def a, do: 1
        def b(x), do: x * 2 + 1
      end
      """)

      File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n")

      File.write!(Path.join(dir, "test/cov_probe_test.exs"), """
      defmodule CovProbeTest do
        use ExUnit.Case
        test "a", do: assert(CovProbe.a() == 1)
      end
      """)

      env = [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", Path.join(dir, "_build")}]

      {out, gated} =
        System.cmd("mix", ["test", "--cover"], cd: dir, env: env, stderr_to_stdout: true)

      assert gated == 3, out

      {_, exported} =
        System.cmd("mix", ["test", "--cover", "--export-coverage", "all"],
          cd: dir,
          env: env,
          stderr_to_stdout: true
        )

      assert exported == 0, "Mix now gates exports; revisit the CI coverage step"
    end

    test "a scheduled flake hunt runs a seed matrix and repeat-until-failure" do
      wf = yaml!(Path.join(@root, ".github/workflows/flake-hunt.yml"))
      assert [%{"cron" => _}] = get_in(wf, ["on", "schedule"])
      assert get_in(wf, ["jobs", "seeds", "strategy", "matrix", "seed"]) |> length() >= 5

      text = run_text(wf)
      assert text =~ ~s(--seed "$SEED")
      assert text =~ "--repeat-until-failure 50"
    end
  end
end
