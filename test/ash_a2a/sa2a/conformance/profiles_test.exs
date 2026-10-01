defmodule AshA2A.SA2A.Conformance.ProfilesTest do
  @moduledoc """
  Courts for the computed conformance gate (`mix ash_a2a.verify_conformance
  --profile c0|c1|c2|c3`).

  Chicago style: every collaborator is real. Fixtures are real git repositories,
  real mix projects, real compiled BEAM binaries and real Ed25519 keys; oracles
  (`:crypto.generate_key/2`, `git`, the filesystem) are independent of the code
  under test. DB-free: no Repo, no Oban, no app-env mutation (every input is
  passed through `opts`).

  The only test double is a fake `gh` executable script in the supply-chain
  tests: a real `gh` needs network and an authenticated GitHub repository, which
  is not realistically available in-process; the script is a real executable
  that answers on stdout/exit code, not an interaction-verifying mock.
  """
  use ExUnit.Case, async: false

  alias AshA2A.SA2A.Conformance.{Check, Claim, Profiles}
  alias AshA2A.SA2A.Conformance.Checks.{C0, C1, C2, C3, Supply}

  @moduletag :conformance_profiles

  # ---------------------------------------------------------------- helpers

  defp uniq, do: System.unique_integer([:positive])

  defp tmp_dir(label) do
    dir = Path.join(System.tmp_dir!(), "sa2a_conf_#{label}_#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] ++
          args,
        cd: dir,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp git_repo(label) do
    dir = tmp_dir(label)
    git!(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "a.txt"), "a")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "init"])
    dir
  end

  defp compile_fixture(source) do
    # The compiler may warn about fixture type mismatches; that noise is irrelevant.
    {result, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(source) end)

    [{mod, bin}] = result
    {mod, bin}
  end

  defp fixture_module(body) do
    name = "AshA2A.Test.ConfFixture#{uniq()}"
    compile_fixture("defmodule #{name} do\n#{body}\nend")
  end

  # ------------------------------------------------------------- Check core

  describe "Check" do
    test "run/2 converts a raising probe into :fail, never a crash or a pass" do
      check = Check.run("x.boom", :c0, "boom", fn -> raise "kaboom" end)
      assert check.status == :fail
      assert check.evidence =~ "kaboom"
    end

    test "run/2 rejects a probe that returns something other than a status tuple" do
      check = Check.run("x.bad", :c0, "bad", fn -> :ok end)
      assert check.status == :fail
      assert check.evidence =~ "malformed"
    end

    test "run/2 keeps pass, fail and unverified distinct" do
      assert Check.run("a", :c0, "t", fn -> {:pass, "e"} end).status == :pass
      assert Check.run("a", :c0, "t", fn -> {:fail, "e"} end).status == :fail
      assert Check.run("a", :c0, "t", fn -> {:unverified, "e"} end).status == :unverified
    end
  end

  # -------------------------------------------------------------------- C0

  describe "C0 checks" do
    test "refusal totality holds both ways on the real refusal registry" do
      assert {:pass, ev} = C0.refusal_totality()
      assert ev =~ "unknown"
    end

    test "standing is derived from evidence, never accepted as a literal" do
      assert {:pass, _} = C0.standing_derived()
    end

    test "canonical digest is key-order invariant and value sensitive" do
      assert {:pass, _} = C0.canonical_digest()
    end

    test "subject identity passes on a clean git checkout and names the sha" do
      repo = git_repo("clean")
      sha = git!(repo, ["rev-parse", "HEAD"])
      assert {:pass, ev} = C0.subject_identity(%{root: repo})
      assert ev =~ sha
    end

    test "subject identity fails on a dirty tree (sha does not describe the tree)" do
      repo = git_repo("dirty")
      File.write!(Path.join(repo, "b.txt"), "uncommitted")
      assert {:fail, ev} = C0.subject_identity(%{root: repo})
      assert ev =~ "dirty"
    end

    test "subject identity is unverified outside a git checkout" do
      assert {:unverified, _} = C0.subject_identity(%{root: tmp_dir("nogit")})
    end
  end

  # -------------------------------------------------------------------- C1

  describe "C1 security profile" do
    test ":strict passes; :dev_bypass and :legacy_compat fail; absent module fails" do
      {strict, _} = fixture_module("def current, do: :strict")
      {bypass, _} = fixture_module("def current, do: :dev_bypass")
      {legacy, _} = fixture_module("def current, do: :legacy_compat")

      assert {:pass, _} = C1.security_profile_strict(%{security_profile_module: strict})
      assert {:fail, ev} = C1.security_profile_strict(%{security_profile_module: bypass})
      assert ev =~ "dev_bypass"
      assert {:fail, _} = C1.security_profile_strict(%{security_profile_module: legacy})
      assert {:fail, ev} = C1.security_profile_strict(%{security_profile_module: Nope.Missing})
      assert ev =~ "absent"
    end
  end

  describe "C1 closure report" do
    test "zero violating edges passes, any edge fails, absent court fails" do
      {clean, _} = fixture_module("def report, do: %{violating_edges: []}")

      {dirty, _} =
        fixture_module("def report, do: %{violating_edges: [{A, :b}, {C, :d}]}")

      assert {:pass, _} = C1.closure_report(%{closure_module: clean})
      assert {:fail, ev} = C1.closure_report(%{closure_module: dirty})
      assert ev =~ "2"
      assert {:fail, ev} = C1.closure_report(%{closure_module: Nope.Missing})
      assert ev =~ "absent"
    end
  end

  describe "C1 command bus does not call the dispatcher directly" do
    test "compiled imports with a Dispatcher.dispatch call fail; without pass" do
      {direct, direct_bin} =
        fixture_module("def go(a), do: AshA2A.Dispatcher.dispatch(a, a, a, a, a, [])")

      {via_kernel, kernel_bin} = fixture_module("def go(a), do: {:ok, a}")

      assert {:fail, ev} =
               C1.command_bus_no_direct_dispatch(%{
                 command_bus: direct,
                 beam_binaries: %{direct => direct_bin}
               })

      assert ev =~ "Dispatcher"

      assert {:pass, _} =
               C1.command_bus_no_direct_dispatch(%{
                 command_bus: via_kernel,
                 beam_binaries: %{via_kernel => kernel_bin}
               })
    end

    test "the real CommandBus in this tree routes every dispatch through the kernel (PASS)" do
      # W4 moved the CommandBus's dispatcher call behind ConsequenceKernel.W4.DispatchInversion;
      # the compiled CommandBus no longer imports AshA2A.Dispatcher (this was a known FAIL).
      assert {:pass, _} = C1.command_bus_no_direct_dispatch(%{})
    end
  end

  describe "C1 canonical digest boundary" do
    test "term_to_binary in a listed module fails; Canonical.digest passes" do
      {legacy, legacy_bin} =
        fixture_module(
          "def d(t), do: :crypto.hash(:sha256, :erlang.term_to_binary(t, [:deterministic]))"
        )

      {canon, canon_bin} =
        fixture_module("def d(t), do: AshA2A.Identity.Canonical.digest(t)")

      {pure, pure_bin} = fixture_module("def d(t), do: t")

      assert {:fail, ev} =
               C1.canonical_at_boundaries(%{
                 boundary_modules: [legacy],
                 beam_binaries: %{legacy => legacy_bin}
               })

      assert ev =~ "term_to_binary"

      assert {:pass, _} =
               C1.canonical_at_boundaries(%{
                 boundary_modules: [canon, pure],
                 beam_binaries: %{canon => canon_bin, pure => pure_bin}
               })
    end

    test "a module that hashes without Canonical fails" do
      {raw, raw_bin} = fixture_module("def d(t), do: :crypto.hash(:sha256, inspect(t))")

      assert {:fail, ev} =
               C1.canonical_at_boundaries(%{
                 boundary_modules: [raw],
                 beam_binaries: %{raw => raw_bin}
               })

      assert ev =~ "Canonical"
    end

    test "the real C2.PreparedEffect no longer uses term_to_binary (portable RFC 8785 identity, PR #62)" do
      assert {:pass, ev} = C1.canonical_at_boundaries(%{})
      assert ev =~ "no term_to_binary"
      assert ev =~ "Identity.Canonical"
    end
  end

  describe "C1 durable claim store" do
    test "a durable store passes; Memory and ETS stores fail; unset fails" do
      {durable, _} =
        fixture_module("""
        def durable?, do: true
        def claim(_d, _g), do: :ok
        def complete(_d, _r), do: :ok
        """)

      assert {:pass, _} = C1.durable_claim_store(%{claim_store: durable})
      assert {:fail, ev} = C1.durable_claim_store(%{claim_store: AshA2A.C2.MemoryClaimStore})
      assert ev =~ "durable"
      assert {:fail, _} = C1.durable_claim_store(%{claim_store: AshA2A.C2.ClaimStoreETS})
      assert {:fail, ev} = C1.durable_claim_store(%{claim_store: nil})
      assert ev =~ "not configured"
    end
  end

  describe "C1 keyed non-tmp journal" do
    defp keyed(key), do: {AshA2A.ConsequenceKernel.KeyCustody.HmacSha256, [key: key]}

    test "durable dir plus a working key provider passes" do
      dir = Path.join(File.cwd!(), "tmp/conf_journal_#{uniq()}")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:pass, _} =
               C1.keyed_journal(%{
                 journal_dir: dir,
                 journal_key_provider: keyed(:crypto.strong_rand_bytes(32))
               })
    end

    test "a tmp journal dir fails even with a key" do
      dir = Path.join(tmp_dir("journal"), "j")

      assert {:fail, ev} =
               C1.keyed_journal(%{
                 journal_dir: dir,
                 journal_key_provider: keyed(:crypto.strong_rand_bytes(32))
               })

      assert ev =~ "tmp"
    end

    test "a missing or short key fails; an unset dir fails" do
      dir = Path.join(File.cwd!(), "tmp/conf_journal_#{uniq()}")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:fail, _} = C1.keyed_journal(%{journal_dir: dir, journal_key_provider: nil})

      assert {:fail, ev} =
               C1.keyed_journal(%{journal_dir: dir, journal_key_provider: keyed("short")})

      assert ev =~ "key"
      assert {:fail, _} = C1.keyed_journal(%{journal_dir: nil, journal_key_provider: nil})
    end
  end

  # -------------------------------------------------------------------- C2

  describe "C2 certificate verifier refuses garbage signatures" do
    test "the real CertificateVerifier (crypto lane landed) refuses bad signatures and accepts a good one" do
      assert {:pass, ev} = C2.certificate_verifier_signatures(%{})
      assert ev =~ "refused"
    end

    test "REVERT-MUTATION: the pre-crypto verifier (algorithm-atom check only) is FAILED as ACCEPTING garbage" do
      {legacy, _} =
        fixture_module("""
        def verify(c, e, ctx) do
          with :ok <- AshA2A.C2.CompleteMediation.admit(e, c, ctx),
               true <-
                 Enum.all?(c.signatures, fn s ->
                   Map.get(s, :alg, Map.get(s, :algorithm)) in [:eddsa, "EdDSA"] or true
                 end),
               do: :ok,
               else: (_ -> {:error, :certificate_refused})
        end
        """)

      assert {:fail, ev} = C2.certificate_verifier_signatures(%{certificate_verifier: legacy})
      assert ev =~ "ACCEPTED"
    end

    test "a verifier that refuses everything is not mistaken for one that verifies" do
      {always_refuse, _} = fixture_module("def verify(_c, _e, _ctx), do: {:error, :refused}")

      assert {:unverified, ev} =
               C2.certificate_verifier_signatures(%{certificate_verifier: always_refuse})

      assert ev =~ "positive control"
    end

    test "a verifier that accepts an unsigned certificate fails" do
      {lax, _} =
        fixture_module("""
        def verify(c, e, ctx) do
          with :ok <- AshA2A.C2.CompleteMediation.admit(e, c, ctx), do: (
            if Enum.any?(c.signatures, &(Map.get(&1, :signature) == <<>>)), do: {:error, :x}, else: :ok
          )
        end
        """)

      assert {:fail, _} = C2.certificate_verifier_signatures(%{certificate_verifier: lax})
    end
  end

  describe "C2 crypto verifier primitives" do
    test "real Ed25519 verifies, garbage/wrong-size inputs are refused without raising, ML-DSA refuses a wrong-suite key" do
      assert {:pass, ev} = C2.crypto_verifier_primitives(%{})
      assert ev =~ "ML-DSA"
    end
  end

  describe "C2 separate authority_service and actuator projects" do
    defp project(root, dir, app, deps, opts \\ []) do
      path = Path.join(root, dir)
      File.mkdir_p!(path)
      mod = "Fixture#{uniq()}.MixProject"

      File.write!(Path.join(path, "mix.exs"), """
      defmodule #{mod} do
        use Mix.Project
        def project, do: [app: :#{app}, version: "0.1.0", deps: deps()]
        def application, do: []
        defp deps, do: #{inspect(deps)}
      end
      """)

      if env_sh = opts[:env_sh] do
        rel = Path.join(path, "_build/prod/rel/#{app}/releases/0.1.0")
        File.mkdir_p!(rel)
        File.write!(Path.join(rel, "env.sh"), env_sh)
      end

      if tpl = opts[:env_template] do
        File.mkdir_p!(Path.join(path, "rel"))
        File.write!(Path.join(path, "rel/env.sh.eex"), tpl)
      end

      path
    end

    test "absent projects fail with a precise reason" do
      root = tmp_dir("noproj")
      assert {:fail, ev} = C2.separate_project(%{root: root}, "authority_service")
      assert ev =~ "authority_service"
      assert {:fail, _} = C2.separate_project(%{root: root}, "actuator")
    end

    test "a project with no dependency on the control plane passes" do
      root = tmp_dir("proj_ok")
      project(root, "actuator", :fixture_actuator, [])

      assert {:pass, _} =
               C2.separate_project(%{root: root, control_plane_app: :ash_a2a}, "actuator")
    end

    test "a project depending on the control plane app fails" do
      root = tmp_dir("proj_dep")
      project(root, "actuator", :fixture_actuator2, [{:ash_a2a, path: ".."}])

      assert {:fail, ev} =
               C2.separate_project(%{root: root, control_plane_app: :ash_a2a}, "actuator")

      assert ev =~ "ash_a2a"
    end

    test "release distribution none: source and built release both required" do
      root = tmp_dir("dist")
      env = "export RELEASE_DISTRIBUTION=none\n"

      project(root, "actuator", :dist_full, [], env_template: env, env_sh: env)

      assert {:pass, _} =
               C2.release_distribution_none(%{root: root, control_plane_app: :ash_a2a}, [
                 {"actuator", :dist_full}
               ])

      root2 = tmp_dir("dist_src_only")
      project(root2, "actuator", :dist_src, [], env_template: env)

      assert {:unverified, ev} =
               C2.release_distribution_none(%{root: root2}, [{"actuator", :dist_src}])

      assert ev =~ "release"

      root3 = tmp_dir("dist_bad")
      project(root3, "actuator", :dist_bad, [], env_template: "# nothing\n")

      assert {:fail, _} = C2.release_distribution_none(%{root: root3}, [{"actuator", :dist_bad}])

      root4 = tmp_dir("dist_builtbad")

      project(root4, "actuator", :dist_bb, [],
        env_template: env,
        env_sh: "export RELEASE_DISTRIBUTION=sname\n"
      )

      assert {:fail, _} = C2.release_distribution_none(%{root: root4}, [{"actuator", :dist_bb}])
    end
  end

  describe "C2 no signing key material reachable from control-plane config" do
    test "PEM private key, private-key named entries and signing env vars fail" do
      pem = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"

      assert {:fail, ev} =
               C2.no_signing_key_material(%{app_env: [some: [nested: pem]], env: %{}})

      assert ev =~ "PEM"

      assert {:fail, _} =
               C2.no_signing_key_material(%{app_env: [signing_key: "abc"], env: %{}})

      assert {:fail, _} =
               C2.no_signing_key_material(%{
                 app_env: [],
                 env: %{"SA2A_SIGNING_KEY" => "abc"}
               })

      assert {:fail, _} =
               C2.no_signing_key_material(%{
                 app_env: [jwk: %{"kty" => "EC", "d" => "secret"}],
                 env: %{}
               })
    end

    test "public-only config passes" do
      assert {:pass, _} =
               C2.no_signing_key_material(%{
                 app_env: [public_key: "MFkw", registry_url: "https://x"],
                 env: %{"PATH" => "/bin"}
               })
    end

    test "the real control-plane config currently carries no signing key material" do
      assert {:pass, _} = C2.no_signing_key_material(%{})
    end
  end

  # -------------------------------------------------------------------- C3

  describe "C3 signer-set quorum" do
    defp quorum_module(body \\ nil) do
      fixture_module(
        body ||
          """
          def quorum(standings, k) do
            valid = for {:valid, %{custodian_id: c} = s} <- standings, do: {c, s}
            custodians = valid |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
            kids = valid |> Enum.map(fn {_, s} -> s.kid end) |> Enum.uniq()

            if length(custodians) >= k and length(kids) == length(valid) and
                 Enum.all?(standings, &match?({:valid, _}, &1)) do
              tier = valid |> Enum.map(fn {_, s} -> s.tier end) |> Enum.min_by(&Atom.to_string/1)
              {:ok, %{custodians: custodians, tier: tier}}
            else
              {:error, :quorum_not_met}
            end
          end
          """
      )
    end

    test "the current SignerSet is a standing-based custodian-distinct quorum (landed, PASS)" do
      assert {:pass, ev} = C3.signer_set_quorum(%{})
      assert ev =~ "custodian-distinct quorum accepted"
      assert ev =~ "two keys of one custodian refused"
    end

    test "a standing-based custodian-distinct quorum, proven end to end with real keys, passes" do
      {mod, _} = quorum_module()
      assert {:pass, ev} = C3.signer_set_quorum(%{signer_set: mod})
      assert ev =~ "custodian"
    end

    test "a quorum that counts distinct kids under one custodian fails" do
      {lax, _} =
        fixture_module("""
        def quorum(standings, k) do
          kids = for {:valid, %{kid: kid}} <- standings, uniq: true, do: kid
          if length(kids) >= k, do: {:ok, %{custodians: kids, tier: :i2}}, else: {:error, :no}
        end
        """)

      assert {:fail, ev} = C3.signer_set_quorum(%{signer_set: lax})
      assert ev =~ "ACCEPTED"
    end

    test "a quorum that ignores invalid standings fails" do
      {lax, _} =
        fixture_module("""
        def quorum(standings, k) do
          if length(standings) >= k, do: {:ok, %{custodians: [1, 2], tier: :i1}}, else: {:error, :no}
        end
        """)

      assert {:fail, _} = C3.signer_set_quorum(%{signer_set: lax})
    end
  end

  # ---------------------------------------------------------- supply chain

  describe "supply chain block" do
    defp fake_gh(dir, body) do
      path = Path.join(dir, "gh")
      File.write!(path, "#!/bin/sh\n" <> body <> "\n")
      File.chmod!(path, 0o755)
      path
    end

    test "without --github every supply check is :unverified" do
      checks = Supply.checks(%{github: false, root: tmp_dir("nogh")})
      assert length(checks) == 3
      assert Enum.all?(checks, &(&1.status == :unverified))
      assert Enum.all?(checks, &(&1.evidence =~ "--github"))
    end

    test "protected main: real gh-shaped answers" do
      dir = tmp_dir("gh")
      ok = fake_gh(dir, ~s(echo '{"enforce_admins":{"enabled":true}}'))
      assert {:pass, _} = Supply.protected_main(%{github: true, gh: ok, root: dir})

      dir2 = tmp_dir("gh2")

      unprotected =
        fake_gh(dir2, ~s(echo '{"message":"Branch not protected","status":"404"}' >&2\nexit 1))

      assert {:fail, ev} = Supply.protected_main(%{github: true, gh: unprotected, root: dir2})
      assert ev =~ "not protected"

      dir3 = tmp_dir("gh3")
      broken = fake_gh(dir3, "echo 'auth required' >&2\nexit 4")
      assert {:unverified, _} = Supply.protected_main(%{github: true, gh: broken, root: dir3})
    end

    test "signed tag: lightweight tag on HEAD fails, no tag fails" do
      repo = git_repo("tags")
      assert {:fail, ev} = Supply.signed_tag(%{github: true, root: repo})
      assert ev =~ "no tag"
      git!(repo, ["tag", "v1"])
      assert {:fail, ev} = Supply.signed_tag(%{github: true, root: repo})
      assert ev =~ "annotated"
    end

    test "signed tag: an ssh-signed annotated tag verifies and passes" do
      repo = git_repo("signed")
      key = Path.join(repo, "..") |> Path.expand() |> Path.join("sa2a_key_#{uniq()}")
      on_exit(fn -> File.rm_rf!(key) && File.rm_rf!(key <> ".pub") end)
      {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key])
      pub = File.read!(key <> ".pub") |> String.trim()
      signers = key <> ".signers"
      on_exit(fn -> File.rm(signers) end)
      File.write!(signers, "t@example.com " <> pub <> "\n")

      git!(repo, ["config", "gpg.format", "ssh"])
      git!(repo, ["config", "user.signingkey", key <> ".pub"])
      git!(repo, ["config", "gpg.ssh.allowedSignersFile", signers])
      git!(repo, ["tag", "-s", "v2", "-m", "release"])

      assert {:pass, ev} = Supply.signed_tag(%{github: true, root: repo})
      assert ev =~ "v2"
    end

    test "single release workflow: exactly one release-triggered workflow passes" do
      root = tmp_dir("wf1")
      wf = Path.join(root, ".github/workflows")
      File.mkdir_p!(wf)

      File.write!(Path.join(wf, "release.yml"), """
      name: release
      on:
        push:
          tags: ["v*"]
      jobs: {}
      """)

      File.write!(Path.join(wf, "ci.yml"), """
      name: ci
      on:
        push:
          branches: [main]
      jobs: {}
      """)

      assert {:pass, ev} = Supply.single_release_workflow(%{github: true, root: root})
      assert ev =~ "release.yml"

      File.write!(Path.join(wf, "release2.yml"), """
      name: release2
      on:
        release:
          types: [published]
      jobs: {}
      """)

      assert {:fail, ev} = Supply.single_release_workflow(%{github: true, root: root})
      assert ev =~ "release2.yml"
    end

    test "no release workflow fails" do
      root = tmp_dir("wf0")
      File.mkdir_p!(Path.join(root, ".github/workflows"))
      assert {:fail, _} = Supply.single_release_workflow(%{github: true, root: root})
    end
  end

  # ---------------------------------------------------- claims (the gate)

  describe "Claim grammar" do
    test "the claim line follows RFC-007 section 4" do
      line =
        Claim.statement(
          :c1,
          %{version: "v26.9.29", tier: "I1", scope: "same-host-os-user"},
          "a" |> String.duplicate(40)
        )

      assert line ==
               "SA2A v26.9.29 conforms to profile C1 at independence tier I1, hosting scope same-host-os-user, on subject SHA #{String.duplicate("a", 40)}"
    end
  end

  describe "CURRENT TREE STATUS (coordinator: update as lanes land)" do
    test "CURRENT_TREE c1 is NOT CONFORMANT" do
      report = Profiles.evaluate(:c1, %{})
      refute report.conformant?
      assert report.claim =~ "NOT CONFORMANT to C1"
      assert report.failing != []
    end

    test "CURRENT_TREE c2 is NOT CONFORMANT" do
      report = Profiles.evaluate(:c2, %{})
      refute report.conformant?
      assert report.claim =~ "NOT CONFORMANT to C2"
      ids = Enum.map(report.failing, & &1.id)
      # The authority_service/ and actuator/ projects have landed; C2 stays
      # withdrawn on the C1 prerequisites the dev/test profile cannot satisfy.
      assert "c1.security_profile_strict" in ids
      assert "c1.durable_claim_store" in ids
      assert "c1.keyed_journal" in ids
    end

    test "CURRENT_TREE c3 is NOT CONFORMANT" do
      report = Profiles.evaluate(:c3, %{})
      refute report.conformant?
      assert report.claim =~ "NOT CONFORMANT to C3"
      ids = Enum.map(report.failing, & &1.id)
      # signer-set quorum landed (custodian-distinct); C3 is withdrawn on the
      # C1/C2 prerequisites that remain unmet in this tree.
      refute "c3.signer_set_quorum" in ids
      assert "c1.security_profile_strict" in ids
      assert "c1.durable_claim_store" in ids
    end

    test "supply-chain checks are :unverified without --github and block c2/c3" do
      report = Profiles.evaluate(:c2, %{})
      sup = Enum.filter(report.checks, &String.starts_with?(&1.id, "supply."))
      assert sup != []
      assert Enum.all?(sup, &(&1.status == :unverified))
      assert Enum.all?(sup, &(&1.id in Enum.map(report.unverified, fn c -> c.id end)))
    end
  end

  describe "the gate: all-pass fixture context earns the claim, one break withdraws it" do
    defp c1_context(overrides \\ %{}) do
      repo = git_repo("gate")
      {strict, _} = fixture_module("def current, do: :strict")
      {clean, _} = fixture_module("def report, do: %{violating_edges: []}")
      {bus, bus_bin} = fixture_module("def go(a), do: {:ok, a}")
      {canon, canon_bin} = fixture_module("def d(t), do: AshA2A.Identity.Canonical.digest(t)")

      {store, _} =
        fixture_module("""
        def durable?, do: true
        def claim(_d, _g), do: :ok
        def complete(_d, _r), do: :ok
        """)

      dir = Path.join(File.cwd!(), "tmp/conf_gate_#{uniq()}")
      on_exit(fn -> File.rm_rf!(dir) end)

      Map.merge(
        %{
          root: repo,
          security_profile_module: strict,
          closure_module: clean,
          command_bus: bus,
          boundary_modules: [canon],
          beam_binaries: %{bus => bus_bin, canon => canon_bin},
          claim_store: store,
          journal_dir: dir,
          journal_key_provider: keyed(:crypto.strong_rand_bytes(32))
        },
        overrides
      )
    end

    test "C1 with every dependency satisfied by real fixtures is CONFORMANT" do
      ctx = c1_context()
      report = Profiles.evaluate(:c1, ctx)
      assert report.failing == [], inspect(report.failing)
      assert report.unverified == []
      assert report.conformant?

      assert report.claim ==
               "SA2A v26.9.29 conforms to profile C1 at independence tier I1, hosting scope same-host-os-user, on subject SHA #{report.subject_sha}"
    end

    test "reverting one guard (Memory claim store) withdraws the claim" do
      ctx = c1_context(%{claim_store: AshA2A.C2.MemoryClaimStore})
      report = Profiles.evaluate(:c1, ctx)
      refute report.conformant?
      assert report.claim =~ "NOT CONFORMANT to C1"
      assert "c1.durable_claim_store" in Enum.map(report.failing, & &1.id)
    end

    test ":dev_bypass forces NOT CONFORMANT even when every other check passes" do
      {bypass, _} = fixture_module("def current, do: :dev_bypass")
      report = Profiles.evaluate(:c1, c1_context(%{security_profile_module: bypass}))
      refute report.conformant?
      assert report.claim =~ "NOT CONFORMANT to C1"
      assert report.claim =~ "dev_bypass"
    end

    test ":legacy_compat forces NOT CONFORMANT even on c0" do
      {legacy, _} = fixture_module("def current, do: :legacy_compat")
      repo = git_repo("legacyc0")
      report = Profiles.evaluate(:c0, %{root: repo, security_profile_module: legacy})
      refute report.conformant?
      assert report.claim =~ "legacy_compat"
    end

    test "C0 alone is conformant on a clean fixture checkout with a strict/absent-neutral profile" do
      repo = git_repo("c0ok")
      {strict, _} = fixture_module("def current, do: :strict")
      report = Profiles.evaluate(:c0, %{root: repo, security_profile_module: strict})
      assert report.conformant?, inspect(report.failing)
    end

    test "a declared tier above I1 at C1 is :unverified evidence, not a claim" do
      report = Profiles.evaluate(:c1, c1_context(%{tier: "I2"}))
      refute report.conformant?
      assert "claim.tier_supported" in Enum.map(report.unverified, & &1.id)
    end

    test "a declared scope beyond same-host-os-user needs deployment evidence" do
      report = Profiles.evaluate(:c1, c1_context(%{scope: "physical-host"}))
      refute report.conformant?
      assert "claim.scope_supported" in Enum.map(report.unverified, & &1.id)
    end

    test "JSON projection carries subject, profile, status and every check" do
      report = Profiles.evaluate(:c1, c1_context())
      json = report |> Profiles.to_json_map() |> Jason.encode!() |> Jason.decode!()
      assert json["profile"] == "c1"
      assert json["conformant"] == true
      assert json["subject_sha"] == report.subject_sha
      assert length(json["checks"]) == length(report.checks)
      assert Enum.all?(json["checks"], &(&1["status"] in ["pass", "fail", "unverified"]))
    end
  end

  # ------------------------------------------------------------ mix task

  describe "mix task" do
    test "--profile with --json writes the machine report and raises when NOT CONFORMANT" do
      out = Path.join(tmp_dir("json"), "r.json")

      assert_raise Mix.Error, ~r/NOT CONFORMANT to C1/, fn ->
        Mix.Tasks.AshA2a.VerifyConformance.run(["--profile", "c1", "--json", out])
      end

      json = out |> File.read!() |> Jason.decode!()
      assert json["profile"] == "c1"
      assert json["conformant"] == false
    end

    test "--profile with --report never raises" do
      out = Path.join(tmp_dir("json2"), "r.json")

      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.AshA2a.VerifyConformance.run(["--profile", "c3", "--report", "--json", out])
      end)

      assert File.exists?(out)
    end

    test "unknown --profile is rejected" do
      assert_raise Mix.Error, ~r/unknown --profile/, fn ->
        Mix.Tasks.AshA2a.VerifyConformance.run(["--profile", "c9"])
      end
    end
  end
end
