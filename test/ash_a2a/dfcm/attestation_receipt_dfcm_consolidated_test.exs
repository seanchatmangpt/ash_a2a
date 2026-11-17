# NOTE: 3 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Attestation, Receipt Store & DFCM
# Contains 23 original test files:
#   - test/ash_a2a/crypto_standing/certificate_verifier_test.exs
#   - test/ash_a2a/dfcm/court_test.exs
#   - test/ash_a2a/dfcm/fleet_intake_test.exs
#   - test/ash_a2a/dfcm/generated_drift_test.exs
#   - test/ash_a2a/dfcm/generated_projection_test.exs
#   - test/ash_a2a/dfcm/reverse_chesterton_test.exs
#   - test/ash_a2a/durable_claim_store/durable_file_test.exs
#   - test/ash_a2a/durable_conformance/strict_c1_checks_test.exs
#   - test/ash_a2a/durable_prepared_journal/journal_test.exs
#   - test/ash_a2a/evidence/affidavit_test.exs
#   - test/ash_a2a/graph_law/subprocess_test.exs
#   - test/ash_a2a/graph_law/unpinned_refusal_test.exs
#   - test/ash_a2a/graph_law/wasmex_host_hardening_test.exs
#   - test/ash_a2a/graph_law/wasmtime_runtime_test.exs
#   - test/ash_a2a/receipt_store/actuation_claim_lease_test.exs
#   - test/ash_a2a/receipt_store/boot_check_test.exs
#   - test/ash_a2a/receipt_store/store_hardening_test.exs
#   - test/ash_a2a/research/erc_sanitize_test.exs
#   - test/ash_a2a/sa2a/conformance/mix_project_stack_test.exs
#   - test/ash_a2a/sa2a/conformance/profiles_test.exs
#   - test/attestation/attestation_gate_test.exs
#   - test/attestation/gate_grant_allowlist_test.exs
#   - test/attestation/lane01_hardening_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/crypto_standing/certificate_verifier_test.exs ---

# --- SECTION 2: Original test/ash_a2a/dfcm/court_test.exs ---
defmodule AshA2A.DfCM.CourtTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.{Court, FleetIntake}

  test "every donor has one exact-subject negative court" do
    assert :ok = Court.validate_all()

    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert {:ok, court} = Court.load(id)
      assert court["donor"] == id
      assert court["subject"] == donor["subject"]
      assert court["capability"] == donor["capability"]
      assert court["falsifier"] == donor["falsifier"]
      assert court["authority"] == "NONE"
      assert court["consequence"] == "EVIDENCE_ONLY"
      assert court["expected"] in ["REFUSED", "UNKNOWN", "UNSUPPORTED"]
    end
  end
end

# --- SECTION 3: Original test/ash_a2a/dfcm/fleet_intake_test.exs ---
defmodule AshA2A.DfCM.FleetIntakeTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.FleetIntake

  test "canonical fleet manifest is structurally admitted" do
    assert :ok = FleetIntake.validate()
    assert length(FleetIntake.ids()) == 15
  end

  test "every donor stays powerless at the SA2A boundary" do
    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert donor["authority"] == "NONE"
      assert donor["consequence"] == "EVIDENCE_ONLY"
      assert donor["subject"] == donor["repository"] <> "@" <> donor["sha"]
      assert donor["reuse"] != []
      assert donor["negative_knowledge"] != []

      assert {:ok, envelope} = FleetIntake.envelope(id)
      assert envelope.standing == :candidate
      assert envelope.authority_requirement == "none"
      assert envelope.consequence_class == "none"
      assert envelope.subjects == [donor["subject"]]
    end
  end

  test "projections bind exact donor identity and refuse authority smuggling" do
    for id <- FleetIntake.ids() do
      assert {:ok, projection} = FleetIntake.project(id, %{"case" => "positive"})
      assert {:ok, ^projection} = FleetIntake.admit_projection(id, projection)

      assert {:error, %{code: :refused_dfcm_projection, field: :authority}} =
               FleetIntake.admit_projection(id, %{projection | "authority" => "DO"})

      assert {:error, %{code: :refused_dfcm_projection, field: :subject}} =
               FleetIntake.admit_projection(id, %{projection | "subject" => "repo@wrong"})
    end
  end
end

# --- SECTION 4: Original test/ash_a2a/dfcm/generated_drift_test.exs ---
defmodule AshA2A.DfCM.GeneratedDriftTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.FleetIntake

  @root Path.expand("../../..", __DIR__)

  test "generated module and court surfaces stay aligned with the manifest" do
    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)

      module_path = Path.join([@root, "lib", "ash_a2a", "dfcm", "generated", id <> ".ex"])
      court_path = Path.join([@root, "priv", "dfcm", "fleet", "courts", id <> ".json"])

      assert File.exists?(module_path), "missing generated module for #{id}"
      assert File.exists?(court_path), "missing generated court for #{id}"

      module_text = File.read!(module_path)
      assert module_text =~ "Generated from priv/ggen/ash_a2a/dfcm/ontology.ttl"
      assert module_text =~ ~s(@donor_id "#{id}")

      court = court_path |> File.read!() |> Jason.decode!()
      assert court["subject"] == donor["subject"]
      assert court["falsifier"] == donor["falsifier"]
    end
  end

  test "canonical ontology remains the declared semantic owner" do
    manifest = FleetIntake.manifest()
    assert manifest["generated_from"] == "priv/ggen/ash_a2a/dfcm/ontology.ttl"

    ontology_path = Path.join([@root, "priv", "ggen", "ash_a2a", "dfcm", "ontology.ttl"])
    assert File.exists?(ontology_path)
    ontology = File.read!(ontology_path)

    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert ontology =~ donor["repository"]
      assert ontology =~ donor["sha"]
      assert ontology =~ donor["falsifier"]
    end
  end
end

# --- SECTION 5: Original test/ash_a2a/dfcm/generated_projection_test.exs ---
defmodule AshA2A.DfCM.GeneratedProjectionTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.Generated

  @modules [
    Generated.GraphLaw,
    Generated.Affidavit,
    Generated.AshR2RML,
    Generated.GgenCreate,
    Generated.Ferroplan,
    Generated.GymAct,
    Generated.GgenIgniter,
    Generated.GgenEcosystem,
    Generated.Wasm4pm,
    Generated.Bcinr,
    Generated.Castle,
    Generated.Xaas,
    Generated.GgenMarketplace,
    Generated.ChatmanEcosystem
  ]

  test "all generated donor modules resolve through the shared DfCM membrane" do
    assert length(@modules) == 14

    for module <- @modules do
      id = module.donor_id()
      contract = module.contract()
      assert contract["id"] == id
      assert contract["authority"] == "NONE"
      assert contract["consequence"] == "EVIDENCE_ONLY"

      assert {:ok, projection} = module.project(%{"module" => inspect(module)})
      assert projection["donor"] == id
      assert {:ok, ^projection} = module.admit_projection(projection)
    end
  end
end

# --- SECTION 6: Original test/ash_a2a/dfcm/reverse_chesterton_test.exs ---
defmodule AshA2A.DfCM.ReverseChestertonTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.FleetIntake

  test "every imported capability preserves mature negative knowledge" do
    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert length(donor["reuse"]) >= 1
      assert length(donor["negative_knowledge"]) >= 1
      assert is_binary(donor["falsifier"]) and donor["falsifier"] != ""
    end
  end

  test "recent universal laws and qualification algebra are references, not parallel owners" do
    universal = FleetIntake.fetch!("chatman_ecosystem")
    graphlaw = FleetIntake.fetch!("graphlaw")

    assert universal["capability"] == "universal_laws_formal_core"
    assert graphlaw["capability"] == "qualification_algebra"
    assert universal["owner"] == "chatman-ecosystem"
    assert graphlaw["owner"] == "GraphLaw"
    assert universal["authority"] == "NONE"
    assert graphlaw["authority"] == "NONE"
  end
end

# --- SECTION 7: Original test/ash_a2a/durable_claim_store/durable_file_test.exs ---
defmodule AshA2A.DurableClaimStore.DurableFileTest do
  @moduledoc """
  Court for the durable `AshA2A.C2.ClaimStore` (`EffectClaimStore.DurableFile`).

  Chicago style: real filesystem under the build path (never tmp, so the
  durable-path guard is exercised for real), real concurrent processes and a
  real second BEAM (`elixir` subprocess) standing in for a restart. The
  verifier check `c1.durable_claim_store` is run against the real module.
  """
  use ExUnit.Case, async: false

  alias AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile, as: Store
  alias AshA2A.SA2A.Conformance.Checks.C1

  @key :binary.copy(<<7>>, 32)

  setup do
    prev = Application.get_env(:ash_a2a, :claim_store_key)
    Application.put_env(:ash_a2a, :claim_store_key, @key)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ash_a2a, :claim_store_key, prev),
        else: Application.delete_env(:ash_a2a, :claim_store_key)
    end)
  end

  defp dir do
    d =
      Path.join([
        Mix.Project.build_path(),
        "durable_courts",
        "claims_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(d)
    on_exit(fn -> File.rm_rf!(d) end)
    d
  end

  defp other_beam(code) do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])
    System.cmd("elixir", paths ++ ["-e", code], stderr_to_stdout: true)
  end

  test "is durable and passes the verifier check" do
    assert Store.durable?()
    assert {:pass, _} = C1.durable_claim_store(%{claim_store: Store})
  end

  test "claim is compare-and-set: second claim of the same digest is refused" do
    d = dir()
    assert :ok = Store.claim("digest-a", 1, d)
    assert {:error, :already_claimed} = Store.claim("digest-a", 1, d)
    assert {:error, :already_claimed} = Store.claim("digest-a", 7, d)
    assert :ok = Store.claim("digest-b", 1, d)
  end

  test "complete records the result once; a completed claim stays claimed" do
    d = dir()
    assert {:error, :not_claimed} = Store.complete("nope", :r, d)
    :ok = Store.claim("c1", 1, d)
    assert :ok = Store.complete("c1", {:done, 1}, d)
    assert {:error, {:already_complete, {:done, 1}}} = Store.complete("c1", {:done, 2}, d)
    assert {:error, :already_claimed} = Store.claim("c1", 1, d)
    assert {:ok, %{state: :complete, result: {:done, 1}, generation: 1}} = Store.fetch("c1", d)
  end

  test "fence: a generation below the highest ever claimed is refused, atomically with the write" do
    d = dir()
    :ok = Store.claim("g5", 5, d)
    assert {:error, :stale_generation} = Store.claim("g3", 3, d)
    assert :not_found = Store.fetch("g3", d)
    assert :ok = Store.claim("g5b", 5, d)
    assert :ok = Store.claim("g9", 9, d)
    assert {:error, :stale_generation} = Store.claim("g5c", 5, d)
  end

  test "exactly one of many concurrent claimers wins" do
    d = dir()

    results =
      1..40
      |> Task.async_stream(fn _ -> Store.claim("race", 1, d) end,
        max_concurrency: 40,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_claimed})) == 39
  end

  test "survives a real BEAM restart in both directions" do
    d = dir()
    :ok = Store.claim("parent-claim", 2, d)

    {out, 0} =
      other_beam("""
      alias AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile, as: S
      Application.put_env(:ash_a2a, :claim_store_key, #{inspect(@key)})
      dir = #{inspect(d)}
      IO.puts("parent:" <> inspect(S.claim("parent-claim", 2, dir)))
      IO.puts("child:" <> inspect(S.claim("child-claim", 2, dir)))
      IO.puts("stale:" <> inspect(S.claim("late", 1, dir)))
      """)

    assert out =~ "parent:{:error, :already_claimed}"
    assert out =~ "child::ok"
    assert out =~ "stale:{:error, :stale_generation}"
    assert {:error, :already_claimed} = Store.claim("child-claim", 2, d)
    assert {:ok, %{state: :claimed}} = Store.fetch("child-claim", d)
  end

  test "a tampered claim record is refused, never trusted" do
    d = dir()
    :ok = Store.claim("t", 1, d)
    [file] = Path.wildcard(Path.join([d, "claims", "*"]))
    bin = File.read!(file)
    File.write!(file, binary_part(bin, 0, byte_size(bin) - 1) <> <<0>>)
    assert {:error, :claim_record_corrupt} = Store.fetch("t", d)
    assert {:error, :claim_record_corrupt} = Store.claim("t", 1, d)
    assert {:error, :claim_record_corrupt} = Store.complete("t", :x, d)
  end

  test "a directory under tmp is refused (guard; anti-vacuity for the durable-path rule)" do
    tmp = Path.join(System.tmp_dir!(), "claims_tmp_#{System.unique_integer([:positive])}")
    assert {:error, :claim_store_dir_not_durable} = Store.claim("x", 1, tmp)
    refute File.exists?(tmp)
    assert {:error, :claim_store_dir_not_durable} = Store.claim("x", 1, nil)
  end

  test "the arity-2 ClaimStore callbacks read :claim_store_dir from app env" do
    d = dir()
    prev = Application.get_env(:ash_a2a, :claim_store_dir)
    Application.put_env(:ash_a2a, :claim_store_dir, d)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ash_a2a, :claim_store_dir, prev),
        else: Application.delete_env(:ash_a2a, :claim_store_dir)
    end)

    assert :ok = Store.claim("env-digest", 1)
    assert {:error, :already_claimed} = Store.claim("env-digest", 1)
    assert :ok = Store.complete("env-digest", :ok)
  end

  defp claim_file(d, digest),
    do: Path.join([d, "claims", Base.encode16(:crypto.hash(:sha256, digest), case: :lower)])

  test "D1: a record forged with a recomputed unkeyed SHA-256 is refused" do
    d = dir()
    :ok = Store.claim("f1", 1, d)
    path = claim_file(d, "f1")

    body =
      :erlang.term_to_binary(%{state: :complete, generation: 1, result: :forged}, [:deterministic])

    File.write!(path, [:crypto.hash(:sha256, body), body])
    assert {:error, :claim_record_corrupt} = Store.fetch("f1", d)
    assert {:error, :claim_record_corrupt} = Store.complete("f1", :x, d)
  end

  test "D1: a record forged under a different key is refused" do
    d = dir()
    :ok = Store.claim("f2", 1, d)
    path = claim_file(d, "f2")
    good = File.read!(path)
    Application.put_env(:ash_a2a, :claim_store_key, :binary.copy(<<9>>, 32))
    assert {:error, :claim_record_corrupt} = Store.fetch("f2", d)
    Application.put_env(:ash_a2a, :claim_store_key, @key)
    assert {:ok, %{state: :claimed}} = Store.fetch("f2", d)
    assert File.read!(path) == good
  end

  test "D1: a record copied onto another digest's path is refused" do
    d = dir()
    :ok = Store.claim("src", 1, d)
    :ok = Store.claim("dst", 1, d)
    :ok = Store.complete("src", :real, d)
    File.cp!(claim_file(d, "src"), claim_file(d, "dst"))
    assert {:error, :claim_record_corrupt} = Store.fetch("dst", d)
  end

  test "D1: no key configured refuses with claim_key_missing / claim_key_unavailable" do
    d = dir()
    Application.delete_env(:ash_a2a, :claim_store_key)
    Application.delete_env(:ash_a2a, :receipt_outbox_key)
    Application.delete_env(:ash_a2a, :receipt_binding_key)
    assert {:error, :claim_key_missing} = Store.claim("k", 1, d)
    Application.put_env(:ash_a2a, :claim_store_key, "short")
    assert {:error, :claim_key_unavailable} = Store.claim("k", 1, d)
  end

  test "D2: deleting a claim record does not re-open the claim" do
    d = dir()
    :ok = Store.claim("gone", 1, d)
    File.rm!(claim_file(d, "gone"))
    assert {:error, :claim_log_corrupt} = Store.claim("gone", 1, d)
    assert {:error, :claim_log_corrupt} = Store.fetch("gone", d)
  end

  test "D2: deleting the head/fence while claims exist is refused" do
    d = dir()
    :ok = Store.claim("h", 1, d)
    File.rm!(Path.join(d, "fence"))
    assert {:error, :claim_log_corrupt} = Store.claim("h2", 1, d)
  end

  test "D2: deleting a completed record is refused too" do
    d = dir()
    :ok = Store.claim("c", 1, d)
    :ok = Store.complete("c", :r, d)
    File.rm!(claim_file(d, "c"))
    assert {:error, :claim_log_corrupt} = Store.claim("c", 1, d)
  end

  test "D2: rolling a completed record back to its claimed state is refused" do
    d = dir()
    :ok = Store.claim("rb", 1, d)
    old = File.read!(claim_file(d, "rb"))
    :ok = Store.complete("rb", :r, d)
    File.write!(claim_file(d, "rb"), old)
    assert {:error, :claim_log_corrupt} = Store.complete("rb", :other, d)
  end
end

# --- SECTION 8: Original test/ash_a2a/durable_conformance/strict_c1_checks_test.exs ---
defmodule AshA2A.DurableConformance.StrictC1ChecksTest do
  @moduledoc """
  The verifier's `c1.security_profile_strict`, `c1.durable_claim_store` and
  `c1.keyed_journal` checks are PASSABLE by real configuration and still
  refuse weak configuration (anti-vacuity: each weakening flips its check).

  In-process: a real `:strict` profile module compiled from the real template,
  the real durable claim store, a real keyed journal directory and a real HMAC
  key custody provider. The full subprocess run under `MIX_ENV=conformance`
  is opt-in (`ASH_A2A_STRICT_CONFORMANCE_COURT=1`) because it compiles a whole
  build environment; see docs/reference/conformance-profiles.md.
  """
  use ExUnit.Case, async: false

  alias AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile
  alias AshA2A.ConsequenceKernel.KeyCustody.HmacSha256
  alias AshA2A.SA2A.Conformance.Checks.C1

  @key String.duplicate("s", 32)

  defmodule StrictProfile do
    use AshA2A.SecurityProfile.Template, env: :prod, requested: :strict
  end

  defmodule DevProfile do
    use AshA2A.SecurityProfile.Template, env: :test, requested: :dev_bypass
  end

  defp dir do
    d =
      Path.join([
        Mix.Project.build_path(),
        "durable_courts",
        "conf_#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf!(d) end)
    d
  end

  defp ctx(over \\ %{}) do
    Map.merge(
      %{
        security_profile_module: StrictProfile,
        claim_store: DurableFile,
        journal_dir: dir(),
        journal_key_provider: {HmacSha256, [key: @key]}
      },
      over
    )
  end

  test "all three checks pass under real strict configuration" do
    c = ctx()
    assert {:pass, _} = C1.security_profile_strict(c)
    assert {:pass, _} = C1.durable_claim_store(c)
    assert {:pass, _} = C1.keyed_journal(c)
  end

  test "the keyed journal check passes against a journal the real Journal module wrote" do
    d = dir()

    {:ok, h} =
      AshA2A.ConsequenceKernel.PreparedEffectStore.Journal.open(d, {HmacSha256, [key: @key]})

    :ok =
      AshA2A.ConsequenceKernel.PreparedEffectStore.Journal.put(h, %{
        digest: "x",
        bytes: "b",
        tag: "t",
        state: :prepared
      })

    assert {:pass, _} = C1.keyed_journal(ctx(%{journal_dir: d}))
  end

  test "anti-vacuity: weakening each input flips its check to fail" do
    assert {:fail, _} = C1.security_profile_strict(ctx(%{security_profile_module: DevProfile}))
    assert {:fail, _} = C1.durable_claim_store(ctx(%{claim_store: AshA2A.C2.MemoryClaimStore}))
    assert {:fail, _} = C1.durable_claim_store(ctx(%{claim_store: AshA2A.C2.ClaimStoreETS}))
    assert {:fail, _} = C1.durable_claim_store(ctx(%{claim_store: nil}))
    tmp = Path.join(System.tmp_dir!(), "j_#{System.unique_integer([:positive])}")
    assert {:fail, _} = C1.keyed_journal(ctx(%{journal_dir: tmp}))
    assert {:fail, _} = C1.keyed_journal(ctx(%{journal_key_provider: nil}))

    assert {:fail, _} =
             C1.keyed_journal(ctx(%{journal_key_provider: {HmacSha256, [key: "short"]}}))
  end

  test "the profile cannot be selected by task options or request data" do
    # current/0 takes no arguments and the check reads only the compiled module.
    refute function_exported?(StrictProfile, :current, 1)

    assert {:fail, _} =
             C1.security_profile_strict(
               ctx(%{security_profile_module: DevProfile, profile: :strict})
             )
  end

  @tag skip:
         System.get_env("ASH_A2A_STRICT_CONFORMANCE_COURT") != "1" &&
           "opt-in: set ASH_A2A_STRICT_CONFORMANCE_COURT=1 (compiles the conformance build env)"
  test "MIX_ENV=conformance mix ash_a2a.verify_conformance --profile c1 passes the three checks" do
    data = dir()
    File.mkdir_p!(data)

    {out, _status} =
      System.cmd("mix", ["ash_a2a.verify_conformance", "--profile", "c1", "--report"],
        env: [
          {"MIX_ENV", "conformance"},
          {"ASH_A2A_DATA_DIR", data},
          {"ASH_A2A_OUTBOX_KEY_B64", Base.encode64(@key)}
        ],
        stderr_to_stdout: true
      )

    for id <- ~w(c1.security_profile_strict c1.durable_claim_store c1.keyed_journal) do
      assert out =~ ~r/PASS\s+#{Regex.escape(id)}/, "#{id} did not PASS:\n#{out}"
    end
  end
end

# --- SECTION 9: Original test/ash_a2a/durable_prepared_journal/journal_test.exs ---
defmodule AshA2A.DurablePreparedJournal.JournalTest do
  @moduledoc """
  Court for the keyed, sequence-numbered `PreparedEffectStore.Journal`.

  Real files under the build path (non-tmp), real HMAC key custody, real
  second BEAM for the restart case. Tampering is done by editing the real
  journal bytes; the oracle is the refusal code, not a call count.
  """
  use ExUnit.Case, async: false

  alias AshA2A.ConsequenceKernel.KeyCustody.HmacSha256
  alias AshA2A.ConsequenceKernel.PreparedEffectStore
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Journal

  @key String.duplicate("k", 32)

  defp dir do
    d =
      Path.join([
        Mix.Project.build_path(),
        "durable_courts",
        "journal_#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf!(d) end)
    d
  end

  defp open!(d, key \\ @key) do
    {:ok, h} = Journal.open(d, {HmacSha256, [key: key]})
    h
  end

  defp record(digest),
    do: %{digest: digest, bytes: "bytes-" <> digest, tag: "t", state: :prepared}

  defp other_beam(code) do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])
    System.cmd("elixir", paths ++ ["-e", code], stderr_to_stdout: true)
  end

  test "put/fetch/transition/claim/complete follow the store contract" do
    h = open!(dir())
    assert :ok = Journal.put(h, record("d1"))
    assert {:error, :prepared_duplicate} = Journal.put(h, record("d1"))
    assert {:ok, %{digest: "d1", state: :prepared}} = Journal.fetch(h, "d1")
    assert :not_found = Journal.fetch(h, "zz")

    assert {:error, :prepared_transition_refused} =
             Journal.transition(h, "d1", :prepared, :completed)

    assert :ok = Journal.transition(h, "d1", :prepared, :claimed)

    assert {:error, :prepared_transition_refused} =
             Journal.transition(h, "d1", :prepared, :claimed)

    assert :ok = Journal.claim_request(h, "r1", :owner_a)
    assert :ok = Journal.claim_request(h, "r1", :owner_a)
    assert {:error, :claim_conflict} = Journal.claim_request(h, "r1", :owner_b)
    assert :ok = Journal.claim_effect(h, "e1", :owner_a)
    assert {:error, :claim_conflict} = Journal.claim_effect(h, "e1", :owner_b)
    assert {:error, :prepared_not_completed} = Journal.complete(h, "d1", :out)
    :ok = Journal.transition(h, "d1", :claimed, :applying)
    :ok = Journal.transition(h, "d1", :applying, :completed)
    assert :ok = Journal.complete(h, "d1", :out)
    assert {:ok, %{state: :completed, outcome: :out}} = Journal.fetch(h, "d1")
  end

  test "entries are sequence-numbered 1..n without gaps" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("a"))
    :ok = Journal.put(h, record("b"))
    :ok = Journal.transition(h, "a", :prepared, :claimed)
    assert {:ok, [1, 2, 3]} = Journal.sequence(h)
    assert {:ok, 3} = Journal.head(h)
  end

  test "PreparedEffectStore.prepare/3 seals a real PreparedEffect into the journal and is idempotent" do
    d = dir()
    h = open!(d)

    {:ok, i} =
      AshA2A.EffectInstance.new(%{
        request: %{"n" => System.unique_integer([:positive])},
        subject: %{"id" => 1},
        effect: %{"op" => "update"}
      })

    {:ok, p} = AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change)
    opts = [key_provider: HmacSha256, key_opts: [key: @key]]

    assert :ok = PreparedEffectStore.prepare({Journal, h}, p, opts)
    assert :ok = PreparedEffectStore.prepare({Journal, h}, p, opts)
    assert {:ok, %{digest: digest}} = Journal.fetch(open!(d), p.prepared_digest)
    assert digest == p.prepared_digest
    assert {:ok, 1} = Journal.head(h)

    assert {:error, :claim_conflict} =
             PreparedEffectStore.claim_request({Journal, h}, "rq", :o)
             |> then(fn :ok -> PreparedEffectStore.claim_request({Journal, h}, "rq", :p) end)
  end

  test "state survives a real BEAM restart; the second BEAM continues the sequence" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("r1"))

    {out, 0} =
      other_beam("""
      alias AshA2A.ConsequenceKernel.PreparedEffectStore.Journal
      {:ok, h} = Journal.open(#{inspect(d)}, {AshA2A.ConsequenceKernel.KeyCustody.HmacSha256, [key: #{inspect(@key)}]})
      IO.puts("dup:" <> inspect(Journal.put(h, %{digest: "r1", bytes: "x", tag: "t", state: :prepared})))
      IO.puts("put:" <> inspect(Journal.put(h, %{digest: "r2", bytes: "x", tag: "t", state: :prepared})))
      IO.puts("seq:" <> inspect(Journal.sequence(h)))
      """)

    assert out =~ "dup:{:error, :prepared_duplicate}"
    assert out =~ "put::ok"
    assert out =~ "seq:{:ok, [1, 2]}"
    assert {:ok, %{digest: "r2"}} = Journal.fetch(h, "r2")
  end

  test "opening with a different key is refused (authentication, not silence)" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("k1"))
    h2 = open!(d, String.duplicate("z", 32))
    assert {:error, :prepared_authentication_failed} = Journal.fetch(h2, "k1")
    assert {:error, :prepared_authentication_failed} = Journal.put(h2, record("k2"))
  end

  test "a flipped byte in the journal is refused" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("t1"))
    :ok = Journal.put(h, record("t2"))
    log = Path.join(d, "journal.log")
    bin = File.read!(log)
    pos = div(byte_size(bin), 2)
    <<pre::binary-size(^pos), b, post::binary>> = bin
    File.write!(log, <<pre::binary, Bitwise.bxor(b, 1), post::binary>>)
    assert {:error, e} = Journal.fetch(h, "t1")
    assert e in [:prepared_authentication_failed, :journal_corrupt]
  end

  test "a truncated journal (dropped tail entry) is refused against the MAC'd head" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("a"))
    size1 = File.stat!(Path.join(d, "journal.log")).size
    :ok = Journal.put(h, record("b"))

    File.write!(
      Path.join(d, "journal.log"),
      binary_part(File.read!(Path.join(d, "journal.log")), 0, size1)
    )

    assert {:error, :journal_truncated} = Journal.fetch(h, "a")
  end

  test "a swapped/reordered entry is refused (chain)" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("a"))
    :ok = Journal.put(h, record("b"))
    log = Path.join(d, "journal.log")
    File.write!(log, File.read!(log) <> File.read!(log))
    assert {:error, e} = Journal.fetch(h, "a")
    assert e in [:prepared_authentication_failed, :journal_corrupt, :journal_sequence_gap]
  end

  test "an entry spliced in from another journal under the same key is refused (chain)" do
    frames = fn d ->
      bin = File.read!(Path.join(d, "journal.log"))
      <<l1::32, _::binary-size(l1), t1::16, _::binary-size(t1), _::binary>> = bin
      first = 4 + l1 + 2 + t1
      {binary_part(bin, 0, first), binary_part(bin, first, byte_size(bin) - first)}
    end

    da = dir()
    ha = open!(da)
    :ok = Journal.put(ha, record("a1"))
    :ok = Journal.put(ha, record("a2"))
    db = dir()
    hb = open!(db)
    :ok = Journal.put(hb, record("b1"))
    :ok = Journal.put(hb, record("b2"))
    {a_first, _} = frames.(da)
    {_, b_second} = frames.(db)
    File.write!(Path.join(da, "journal.log"), a_first <> b_second)
    assert {:error, :prepared_authentication_failed} = Journal.fetch(ha, "a1")
  end

  test "mandatory key: no key, short key, and no provider are refused at open" do
    d = dir()
    assert {:error, :journal_key_missing} = Journal.open(d, nil)
    assert {:error, :prepared_key_unavailable} = Journal.open(d, {HmacSha256, [key: "short"]})
    assert {:error, :prepared_key_unavailable} = Journal.open(d, {HmacSha256, []})
  end

  test "a tmp directory is refused at open" do
    tmp = Path.join(System.tmp_dir!(), "journal_tmp_#{System.unique_integer([:positive])}")
    assert {:error, :journal_dir_not_durable} = Journal.open(tmp, {HmacSha256, [key: @key]})
    assert {:error, :journal_dir_not_durable} = Journal.open(nil, {HmacSha256, [key: @key]})
    refute File.exists?(tmp)
  end

  test "from_config/0 builds the handle from real app env" do
    d = dir()
    keys = [:receipt_outbox_dir, :receipt_outbox_key, :prepared_journal_dir]
    prev = for k <- keys, do: {k, Application.get_env(:ash_a2a, k)}
    Application.put_env(:ash_a2a, :receipt_outbox_dir, d)
    Application.put_env(:ash_a2a, :receipt_outbox_key, @key)
    Application.delete_env(:ash_a2a, :prepared_journal_dir)

    on_exit(fn ->
      for {k, v} <- prev,
          do:
            if(v == nil,
              do: Application.delete_env(:ash_a2a, k),
              else: Application.put_env(:ash_a2a, k, v)
            )
    end)

    assert {:ok, h} = Journal.from_config()
    assert :ok = Journal.put(h, record("cfg"))
    assert File.exists?(Path.join([d, "prepared_journal", "journal.log"]))
  end
end

# --- SECTION 10: Original test/ash_a2a/evidence/affidavit_test.exs ---
defmodule AshA2A.Evidence.AffidavitTest do
  use ExUnit.Case, async: true

  alias AshA2A.Evidence.Affidavit

  setup do
    if Affidavit.available?() and is_nil(Process.whereis(AshAffidavit.Pool)) do
      start_supervised!({AshAffidavit.Pool, size: 2})
    end

    :ok
  end

  describe "AshA2A.Evidence.Affidavit" do
    test "available?/0 returns true when ash_affidavit is loaded" do
      assert Affidavit.available?() == true
    end

    test "assemble_receipt/1 and verify_receipt/1 execute with real WASM engine" do
      events = [
        %{"event_type" => "start", "objects" => ["task:1"], "payload" => "init"},
        %{"event_type" => "finish", "objects" => ["task:1"], "payload" => "done"}
      ]

      assert {:ok, assembled} = Affidavit.assemble_receipt(events)
      assert is_map(assembled)
      assert Map.has_key?(assembled, "receipt")

      assert {:ok, true} = Affidavit.verify_receipt(assembled["receipt"])
    end
  end
end

# --- SECTION 11: Original test/ash_a2a/graph_law/subprocess_test.exs ---
defmodule AshA2A.GraphLaw.SubprocessTest do
  @moduledoc """
  Chicago-school court for `AshA2A.GraphLaw.Subprocess` (PERF-03, PERF-12):
  real OS processes (`sh`, `sleep`, `kill -0`), no doubles. `async: false`
  because the concurrency cap is a node-wide counter.
  """

  use ExUnit.Case, async: false

  alias AshA2A.GraphLaw.Subprocess

  test "a completed process returns stdout and its exit status; stderr is not merged" do
    assert {:ok, {"out\n", 3}} =
             Subprocess.run("sh", ["-c", "echo out; echo err 1>&2; exit 3"], timeout_ms: 5_000)
  end

  test "a hung process is killed at the deadline and typed :graphlaw_host_timeout" do
    started = System.monotonic_time(:millisecond)

    assert {:error, %{code: :graphlaw_host_timeout, os_pid: os_pid}} =
             Subprocess.run("sleep", ["30"], timeout_ms: 200)

    assert System.monotonic_time(:millisecond) - started < 5_000
    # The OS process is really gone, not merely abandoned.
    AshA2A.TestSupport.Eventually.eventually(
      fn ->
        {_, status} =
          System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

        status != 0
      end,
      message: "OS process #{os_pid} still alive"
    )

    assert Subprocess.in_flight() == 0
    refute_received {_port, {:exit_status, _}}
  end

  test "a spawn over the concurrency cap is shed, not queued" do
    parent = self()

    holder =
      Task.async(fn ->
        send(parent, :holding)
        Subprocess.run("sleep", ["2"], timeout_ms: 5_000, max_concurrency: 1)
      end)

    assert_receive :holding
    wait_until(fn -> Subprocess.in_flight() >= 1 end)

    assert {:error, %{code: :graphlaw_host_saturated, max_concurrency: 1}} =
             Subprocess.run("sh", ["-c", "echo x"], max_concurrency: 1)

    assert {:ok, {"", 0}} = Task.await(holder, 10_000)
    assert Subprocess.in_flight() == 0
    assert {:ok, {"x\n", 0}} = Subprocess.run("sh", ["-c", "echo x"], max_concurrency: 1)
  end

  test "run/3 returns only after its slot is released: back-to-back runs at cap 1 are never shed" do
    # The slot used to be released by a watcher process asynchronously, so `run/3`
    # could return while `in_flight/0` was still 1 and an immediate re-run at the
    # cap was spuriously shed (`:graphlaw_host_saturated`).
    results =
      for _ <- 1..300 do
        {Subprocess.run("true", [], max_concurrency: 1), Subprocess.in_flight()}
      end

    assert Enum.all?(results, fn {run, in_flight} ->
             match?({:ok, {"", 0}}, run) and in_flight == 0
           end),
           "a run was shed or returned before releasing its slot: " <>
             inspect(
               Enum.find(results, fn {run, n} -> not match?({:ok, {"", 0}}, run) or n != 0 end)
             )
  end

  test "a caller killed mid-run releases its slot and its OS process" do
    marker = "31.#{System.unique_integer([:positive])}"
    task = Task.async(fn -> Subprocess.run("sleep", [marker], timeout_ms: 60_000) end)

    wait_until(fn -> Subprocess.in_flight() >= 1 end)
    wait_until(fn -> match?({_, 0}, System.cmd("pgrep", ["-f", "sleep #{marker}"])) end)
    assert Task.shutdown(task, :brutal_kill) == nil

    wait_until(fn -> Subprocess.in_flight() == 0 end)
    wait_until(fn -> match?({_, 1}, System.cmd("pgrep", ["-f", "sleep #{marker}"])) end)
  end

  test "a missing executable is a typed spawn failure" do
    assert {:error, %{code: :graphlaw_host_spawn_failed}} =
             Subprocess.run("definitely-not-an-executable-xyz", [])
  end

  test "the peer transport's availability probe spawns node at most once per artifact" do
    if System.find_executable("node") do
      assert AshA2A.Semantic.GraphLaw.Wasm.available?()
      {us, true} = :timer.tc(&AshA2A.Semantic.GraphLaw.Wasm.available?/0)
      # A node spawn + 3.2 MB instantiation measured ~100 ms; a memo hit is
      # two stat calls and a persistent_term read.
      assert us < 10_000, "memoized available?/0 took #{us} us"
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
      true -> AshA2A.TestSupport.Eventually.pause(10) && wait_until(fun, tries - 1)
    end
  end
end

# --- SECTION 12: Original test/ash_a2a/graph_law/unpinned_refusal_test.exs ---
defmodule AshA2A.GraphLaw.UnpinnedRefusalTest do
  use ExUnit.Case, async: false

  alias AshA2A.GraphLaw.EngineLoad

  setup do
    prev = Application.fetch_env(:ash_a2a, :graphlaw_allow_unpinned)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:ash_a2a, :graphlaw_allow_unpinned, v)
        :error -> Application.delete_env(:ash_a2a, :graphlaw_allow_unpinned)
      end
    end)

    :ok
  end

  test ":unpinned is refused by default (runtime config)" do
    Application.delete_env(:ash_a2a, :graphlaw_allow_unpinned)

    assert {:error, %{code: :graphlaw_wasm_unpinned_refused}} =
             EngineLoad.check_digest("abc", :unpinned)
  end

  test ":unpinned is admitted only when explicitly enabled" do
    Application.put_env(:ash_a2a, :graphlaw_allow_unpinned, true)
    assert :ok = EngineLoad.check_digest("abc", :unpinned)
  end

  test "resolve_wasm_path refuses a missing path with a typed error" do
    path = Path.join(System.tmp_dir!(), "no-such-#{System.unique_integer([:positive])}.wasm")

    assert {:error, %{code: :graphlaw_wasm_missing}} =
             AshA2A.GraphLaw.resolve_wasm_path(wasm_path: path)
  end
end

# --- SECTION 13: Original test/ash_a2a/graph_law/wasmex_host_hardening_test.exs ---

# --- SECTION 14: Original test/ash_a2a/graph_law/wasmtime_runtime_test.exs ---
defmodule AshA2A.GraphLaw.WasmtimeRuntimeTest do
  @moduledoc """
  Real, non-mocked exercise of `AshA2A.GraphLaw.WasmtimeRuntime`, the native
  Wasmtime host: every assertion below is on a value that came back from a
  real OS subprocess (`native/graphlaw_host`) that really compiled and ran
  `priv/graphlaw/praxis_graphlaw.wasm` under Wasmtime.

  There is no test double anywhere in this file. No wasm result is
  hand-constructed, no collaborator is stubbed, and nothing asserts "was X
  called" -- the assertions are on real returned digests, real JSON, and real
  typed errors.

  The expected digests are not this test's invention either: they are the
  values the same artifact produces under a *different* host (a hand-written
  JavaScript shim over `WebAssembly.instantiate` in Node), recorded as the
  conformance vectors for RFC-SA2A-001 S12/S51. That is the whole experiment:
  same bytes, different host, same answers.

  When `native/graphlaw_host/target/release/graphlaw_host` has not been built
  the wasm-executing tests are **skipped by name and loudly**, never silently
  replaced by a double. Build it with:

      cd native/graphlaw_host && cargo build --release
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.GraphLaw.ConformanceVectors
  alias AshA2A.GraphLaw.{Runtime, RuntimeB, WasmexSession, WasmtimeRuntime}

  # --- Conformance vectors (RFC-SA2A-001 S12 canonical graph identity) -------

  @base """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:c .
  """

  # Same graph, different prefix *label* and different triple *order*.
  # A canonicalizing hash must not be able to tell it apart from @base.
  @reordered """
  @prefix zz: <http://example.org/> .
  zz:b zz:p zz:c .
  zz:a zz:p zz:b .
  """

  # One object term changed: must hash differently.
  @different """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:ZZZ .
  """

  @base_hash "9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d"
  @different_hash "610ccbcd4ed4b23cf4179fde360625da286557d18a15403f76797e28c1c68f66"

  # The published BLAKE3 test vector for the input "abc".
  @blake3_abc "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"

  # The published BLAKE3 test vector for the *empty* input, which is also what
  # an empty graph's canonical N-Quads form hashes to.
  @empty_graph_hash "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"

  @vendored_wasm_sha256 "187688d9e7e33a575713d6911d75687adb38713ed37412e211af263dfcbe0c28"

  @junk_inputs ["this is not turtle <<<", "@@@ bad", "<http://a> <http://b"]

  # The pure digest/parse tests below all read from ONE real native-host batch
  # (one subprocess, one wasm compile) instead of one spawn (~1.4s) per call.
  # Every job is a real wasm call in the real host; only the spawn is shared.
  # Tests that assert process isolation, timeout, artifact identity or error
  # paths keep their own fresh spawns.
  setup_all do
    if WasmtimeRuntime.available?() == :ok do
      keyed_jobs =
        [
          {:base, {"graph_hash", [@base]}},
          {:reordered, {"graph_hash", [@reordered]}},
          {:different, {"graph_hash", [@different]}},
          {:blake3_abc, {"blake3_hex", ["abc"]}},
          {:empty_graph, {"graph_hash", [""]}},
          {:blake3_empty, {"blake3_hex", [""]}}
        ] ++
          Enum.map(@junk_inputs, &{{:junk, &1}, {"graph_hash", [&1]}})

      {:ok, %{results: results}} = WasmtimeRuntime.batch(Enum.map(keyed_jobs, &elem(&1, 1)))
      %{pure: keyed_jobs |> Enum.map(&elem(&1, 0)) |> Enum.zip(results) |> Map.new()}
    else
      %{pure: %{}}
    end
  end

  describe "path resolution and availability (no subprocess)" do
    test "wasm_digest/1 hashes the real vendored artifact on disk" do
      assert {:ok, @vendored_wasm_sha256} = WasmtimeRuntime.wasm_digest()
    end

    test "a missing native binary is a typed refusal, not a crash" do
      assert {:error, error} =
               WasmtimeRuntime.graph_hash(@base, binary_path: "/nonexistent/graphlaw_host")

      assert error.code == :graphlaw_host_not_built
      assert error.path == "/nonexistent/graphlaw_host"
      assert error.message =~ "cargo build --release"
    end

    test "a missing wasm artifact is a typed refusal, not a crash" do
      # `/bin/sh` really exists, so the binary check passes and the wasm check
      # is the one that fires -- and no subprocess is ever spawned, because the
      # refusal happens before that.
      assert {:error, error} =
               WasmtimeRuntime.graph_hash(@base,
                 binary_path: "/bin/sh",
                 wasm_path: "/nonexistent/graphlaw.wasm"
               )

      assert error.code == :graphlaw_wasm_missing
    end

    test "available?/1 reports real on-disk state as the Runtime behaviour shape" do
      assert {:error, %{code: :graphlaw_host_not_built}} =
               WasmtimeRuntime.available?(binary_path: "/nonexistent/graphlaw_host")

      assert {:error, %{code: :graphlaw_wasm_missing}} =
               WasmtimeRuntime.available?(
                 binary_path: "/bin/sh",
                 wasm_path: "/nonexistent/graphlaw.wasm"
               )
    end
  end

  describe "AshA2A.GraphLaw.Runtime identity (no subprocess)" do
    test "declares the Runtime behaviour" do
      behaviours = WasmtimeRuntime.module_info(:attributes) |> Keyword.get_values(:behaviour)
      assert Runtime in List.flatten(behaviours)
    end

    test "is a distinct {host_id, engine_id} from both court default runtimes" do
      assert Runtime.identity(WasmtimeRuntime) == {"Native/graphlaw_host", "wasmtime"}
      assert Runtime.identity(WasmtimeRuntime) != Runtime.identity(WasmexSession)
      assert Runtime.identity(WasmtimeRuntime) != Runtime.identity(RuntimeB)
    end

    test "open/1 over an unbuilt host is the typed refusal, not a session" do
      assert {:error, %{code: :graphlaw_host_not_built}} =
               WasmtimeRuntime.open(binary_path: "/nonexistent/graphlaw_host")
    end
  end

  if AshA2A.GraphLaw.WasmtimeRuntime.available?() == :ok do
    describe "AshA2A.GraphLaw.Runtime callbacks over the native host" do
      test "open/call/close drive the real host and return verbatim wasm strings" do
        assert {:ok, %{session: session, wasm_digest: digest}} = WasmtimeRuntime.open()

        try do
          # The host-reported digest of the bytes it compiled, equal to the
          # BEAM's own digest of the same file via the behaviour's helper.
          assert digest == @vendored_wasm_sha256
          assert digest == Runtime.bytes_digest(File.read!(WasmtimeRuntime.wasm_path()))

          assert {:ok, version} = WasmtimeRuntime.call(session, :graphlaw_version, [])
          assert version =~ "praxis-graphlaw v"
          assert {:ok, @base_hash} = WasmtimeRuntime.call(session, :graph_hash, [@base])
          assert {:ok, @blake3_abc} = WasmtimeRuntime.call(session, :blake3_hex, ["abc"])
        after
          assert :ok = WasmtimeRuntime.close(session)
        end
      end

      test "call/3 refuses a wrong arity and an unknown function with typed errors" do
        assert {:ok, %{session: session}} = WasmtimeRuntime.open()

        assert {:error, %{code: :graphlaw_arity_mismatch, expected: 1, got: 0}} =
                 WasmtimeRuntime.call(session, :graph_hash, [])

        assert {:error, %{code: :graphlaw_unsupported_function, function: :no_such_function}} =
                 WasmtimeRuntime.call(session, :no_such_function, [])

        assert :ok = WasmtimeRuntime.close(session)
      end

      test "a session replays its call sequence, so instance-state-dependent answers match" do
        # v006's blank-node graph_hash depends on the wasm instance's state, not
        # only on the graph: one live instance answers a deterministic sequence
        # of different digests. A session must reproduce that sequence, not the
        # first digest every time (which is what a fresh instance per call gives).
        # This pins the same open praxis-graphlaw v26.7.5 defect that
        # test/ash_a2a/sa2a_conformance_test.exs pins; update both together.
        [v006] = v006_vectors()
        assert {:ok, %{session: session}} = WasmtimeRuntime.open()

        sequence =
          try do
            for _ <- 1..3 do
              assert {:ok, digest} = WasmtimeRuntime.call(session, :graph_hash, [v006.base])
              digest
            end
          after
            WasmtimeRuntime.close(session)
          end

        assert {:ok, fresh} = WasmtimeRuntime.graph_hash(v006.base)
        assert hd(sequence) == fresh.value
        assert length(Enum.uniq(sequence)) > 1

        # The same three calls issued in ONE real host process, independently.
        assert {:ok, batch} =
                 WasmtimeRuntime.batch(List.duplicate({"graph_hash", [v006.base]}, 3))

        assert sequence == Enum.map(batch.results, fn {:ok, r} -> r.value end)
      end

      test "the SA2A court accepts it as a runtime and it agrees with the in-BEAM host" do
        wasm = WasmtimeRuntime.wasm_path()

        case WasmexSession.available?(wasm_path: wasm) do
          :ok ->
            # One-vector corpus (the instance-state-dependent v006) copied from
            # the real corpus, so the court runs in seconds rather than a minute.
            dir =
              Path.join(System.tmp_dir!(), "sa2a_wasmtime_#{System.unique_integer([:positive])}")

            File.mkdir_p!(dir)

            try do
              File.cp_r!(
                Path.join(AshA2A.SA2A.Vector.corpus_dir(), "v006_blank_nodes"),
                Path.join(dir, "v006_blank_nodes")
              )

              assert {:error, %{"assertions" => assertions} = receipt} =
                       AshA2A.SA2A.Conformance.run(
                         runtime_a: WasmexSession,
                         runtime_b: WasmtimeRuntime,
                         wasm_path: wasm,
                         corpus_dir: dir
                       )

              assert receipt["runtime_a"]["wasm_digest"] == @vendored_wasm_sha256
              assert receipt["runtime_b"]["wasm_digest"] == @vendored_wasm_sha256

              for name <-
                    ~w(same_wasm same_admission same_output_semantics same_evidence_identity) do
                assert assertions[name]["computed"], "#{name} not computed"
                assert assertions[name]["value"], "#{name} diverged: #{inspect(assertions[name])}"
              end

              # The open v006 falsifier fires identically in both hosts: the
              # unstable digests agree digit-for-digit across the two runtimes.
              identity = assertions["same_input_identity"]
              assert identity["computed"]
              refute identity["value"]

              by_runtime = Map.new(identity["divergences"], &{&1["runtime"], &1})

              assert Map.keys(by_runtime) |> Enum.sort() == [
                       "BEAM/Wasmex",
                       "Native/graphlaw_host"
                     ]

              assert Map.take(by_runtime["BEAM/Wasmex"], ["first", "repeat"]) ==
                       Map.take(by_runtime["Native/graphlaw_host"], ["first", "repeat"])
            after
              File.rm_rf!(dir)
            end

          {:error, reason} ->
            IO.puts("skipped: in-BEAM runtime unavailable: #{inspect(reason)}")
        end
      end

      test "the SA2A court refuses a relabelled native host before any vector runs (S126)" do
        # Both delegates really open, call and close the real native host; only
        # their caller-controlled labels differ. A whitespace-only relabel is
        # refused on the normalized label, an entirely different label on the
        # identity observed from the open sessions (the same session resource
        # is started by WasmtimeRuntime itself, whatever the module says).
        assert {:error, padded} =
                 AshA2A.SA2A.Conformance.run(
                   runtime_a: WasmtimeRuntime,
                   runtime_b: __MODULE__.PaddedNativeRuntime
                 )

        assert padded.code == :sa2a_identical_runtimes
        assert padded.basis == :label

        assert Runtime.identity(__MODULE__.PaddedNativeRuntime) !=
                 Runtime.identity(WasmtimeRuntime)

        assert {:error, relabelled} =
                 AshA2A.SA2A.Conformance.run(
                   runtime_a: WasmtimeRuntime,
                   runtime_b: __MODULE__.RelabelledNativeRuntime
                 )

        assert relabelled.code == :sa2a_identical_runtimes
        assert relabelled.basis == :observed_executable

        assert [%{"engine_module" => "AshA2A.GraphLaw.WasmtimeRuntime"}] =
                 relabelled.observed_identity
      end
    end

    describe "the native host executes the vendored artifact under Wasmtime" do
      test "reports the engine version out of the wasm itself" do
        assert {:ok, result} = WasmtimeRuntime.graphlaw_version()
        assert result.value =~ "praxis-graphlaw"
        assert result.runtime == "wasmtime"
      end

      test "every result carries cross-checked artifact identity" do
        assert {:ok, result} = WasmtimeRuntime.graph_hash(@base)
        assert {:ok, expected} = WasmtimeRuntime.wasm_digest()

        # The native host independently hashed the bytes it compiled; this
        # assertion is what turns `WASM_A = WASM_B` from an assumption into a
        # checked fact (falsifier #1).
        assert result.wasm_sha256 == expected
        assert result.wasm_sha256 == @vendored_wasm_sha256
        assert result.wasm_bytes == 3_249_361
        assert result.runtime == "wasmtime"
        assert is_binary(result.runtime_version)
        assert result.host =~ "graphlaw_host/"
      end

      test "host graph_hash job (one shared batch) reproduces the S12 canonical identity vector",
           %{pure: pure} do
        assert {:ok, %{value: @base_hash}} = pure[:base]
      end

      test "host graph_hash job (one shared batch) is invariant to prefix label and triple order",
           %{pure: pure} do
        assert {:ok, %{value: base}} = pure[:base]
        assert {:ok, %{value: reordered}} = pure[:reordered]

        assert base == reordered
        assert base == @base_hash
      end

      test "host graph_hash job (one shared batch) separates a graph that differs by one term", %{
        pure: pure
      } do
        assert {:ok, %{value: base}} = pure[:base]
        assert {:ok, %{value: different}} = pure[:different]

        refute base == different
        assert different == @different_hash
      end

      test "host blake3_hex job (one shared batch) reproduces the published BLAKE3 vector for \"abc\"",
           %{pure: pure} do
        assert {:ok, %{value: @blake3_abc}} = pure[:blake3_abc]
      end

      test "run_hooks/3 returns the real admission JSON from the engine" do
        event = """
        @prefix ex: <http://example.org/> .
        ex:c ex:p ex:d .
        """

        assert {:ok, result} = WasmtimeRuntime.run_hooks(@base, event)
        assert {:ok, decoded} = JSON.decode(result.value)
        assert decoded["status"] == "ADMITTED"
        assert is_list(decoded["verdicts"])
      end
    end

    describe "batch/2 (one subprocess, one wasm compile, many jobs)" do
      test "runs the whole conformance vector set in a single host process" do
        jobs = [
          {"graph_hash", [@base]},
          {"graph_hash", [@reordered]},
          {"graph_hash", [@different]},
          {"blake3_hex", ["abc"]}
        ]

        assert {:ok, batch} = WasmtimeRuntime.batch(jobs)
        assert batch.wasm_sha256 == @vendored_wasm_sha256

        assert [
                 {:ok, %{value: @base_hash}},
                 {:ok, %{value: @base_hash}},
                 {:ok, %{value: @different_hash}},
                 {:ok, %{value: @blake3_abc}}
               ] = batch.results
      end

      test "a bad job inside a batch is typed and does not poison its siblings" do
        assert {:ok, batch} =
                 WasmtimeRuntime.batch([
                   {"graph_hash", [@base]},
                   {"no_such_function", []}
                 ])

        assert [{:ok, %{value: @base_hash}}, {:error, bad}] = batch.results
        assert bad.code == :unsupported_fn
        assert bad.message =~ "no_such_function"
      end

      test "wrong arity is refused by the host rather than trapping the module" do
        assert {:ok, batch} = WasmtimeRuntime.batch([{"graph_hash", []}])
        assert [{:error, bad}] = batch.results
        assert bad.code == :bad_arity
      end
    end

    describe "the finite conformance suite, driven from priv/graphlaw/conformance_vectors.json" do
      test "every recorded vector reproduces exactly under the native Wasmtime host" do
        assert {:ok, doc} = ConformanceVectors.load()
        assert {:ok, jobs} = ConformanceVectors.jobs()
        assert {:ok, batch} = WasmtimeRuntime.batch(jobs)

        # Same artifact the expectations were recorded against -- otherwise
        # agreement would prove nothing about host independence.
        assert batch.wasm_sha256 == doc["wasm_sha256"]
        assert batch.wasm_bytes == doc["wasm_bytes"]

        pairs = Enum.zip(doc["vectors"], batch.results)
        assert length(pairs) == length(doc["vectors"])

        for {vector, result} <- pairs do
          assert {:ok, %{value: value}} = result

          assert value == vector["expect"],
                 "vector #{vector["id"]} diverged under WasmtimeRuntime"
        end
      end

      test "the suite really covers the S12 identity triple and both BLAKE3 vectors" do
        assert {:ok, vectors} = ConformanceVectors.vectors()
        ids = MapSet.new(vectors, & &1["id"])

        for required <- [
              "S12-canonical-base",
              "S12-prefix-label-and-order-invariance",
              "S12-one-term-changed",
              "blake3-abc"
            ] do
          assert MapSet.member?(ids, required), "conformance suite lost vector #{required}"
        end
      end

      test "a missing vector document is a typed refusal, not a crash" do
        assert {:error, %{code: :conformance_vectors_missing}} =
                 ConformanceVectors.load(vectors_path: "/nonexistent/vectors.json")
      end
    end

    describe "real failure modes" do
      # Measured, not assumed: this engine's `graph_hash` is *lenient*. Feeding
      # it malformed Turtle does NOT produce its `{"error": ...}` object -- it
      # produces the canonical hash of whatever triples it managed to parse,
      # which for wholly unparseable input is the empty graph. A caller cannot
      # use "did graph_hash error" as a syntax check; a conformance suite must
      # therefore pin this behaviour rather than assume strictness.
      test "malformed Turtle still hashes: `graph_hash` never reports a syntax error",
           %{pure: pure} do
        for junk <- @junk_inputs do
          assert {:ok, %{value: value}} = pure[{:junk, junk}]
          # A 64-char lowercase hex digest, not an `{"error": ...}` object.
          assert value =~ ~r/\A[0-9a-f]{64}\z/, "unexpected result for #{inspect(junk)}"
        end
      end

      test "input the parser recovers nothing from yields the empty-graph digest",
           %{pure: pure} do
        for empty_equivalent <- ["@@@ bad", "<http://a> <http://b"] do
          assert {:ok, %{value: @empty_graph_hash}} = pure[{:junk, empty_equivalent}]
        end
      end

      test "a lenient parse is still deterministic across separate host processes" do
        junk = "this is not turtle <<<"
        assert {:ok, %{value: first}} = WasmtimeRuntime.graph_hash(junk)
        assert {:ok, %{value: second}} = WasmtimeRuntime.graph_hash(junk)

        # Two independent subprocesses, two independent wasm instantiations.
        assert first == second
        refute first == @empty_graph_hash
      end

      test "the empty-graph digest is BLAKE3 of the empty canonical N-Quads form",
           %{pure: pure} do
        assert {:ok, %{value: @empty_graph_hash}} = pure[:empty_graph]
        assert {:ok, %{value: @empty_graph_hash}} = pure[:blake3_empty]
      end

      test "a non-wasm file is refused at compile time with artifact identity intact" do
        path =
          Path.join(System.tmp_dir!(), "ash_a2a_not_a_wasm_#{System.unique_integer([:positive])}")

        File.write!(path, "definitely not webassembly")

        try do
          assert {:error, error} = WasmtimeRuntime.graph_hash(@base, wasm_path: path)
          assert error.code == :wasm_compile_failed
          # Identity is still reported for the (wrong) artifact: the host
          # hashes what it was handed before it tries to compile it.
          assert error.wasm_sha256 ==
                   Base.encode16(
                     :crypto.hash(:sha256, "definitely not webassembly"),
                     case: :lower
                   )
        after
          File.rm(path)
        end
      end

      test "a deadline that cannot be met kills the subprocess and returns :timeout" do
        # Compiling a 3.2 MB module is seconds-scale work; 1 ms cannot finish.
        assert {:error, %{code: :timeout, timeout_ms: 1}} =
                 WasmtimeRuntime.graph_hash(@base, timeout: 1)
      end
    end

    defp v006_vectors do
      {:ok, vectors} = AshA2A.SA2A.Vector.load_all()
      Enum.filter(vectors, &(&1.id == "v006_blank_nodes"))
    end
  else
    test "SKIPPED: graphlaw_host is not built, so WasmtimeRuntime was not executed" do
      IO.warn("""
      WasmtimeRuntime wasm-execution tests were SKIPPED because the native host is \
      not built at #{WasmtimeRuntime.binary_path()}.

      These tests are never replaced by a mock or a stub. Build the real host \
      and re-run:

          cd native/graphlaw_host && cargo build --release
      """)

      assert {:error, %{code: :graphlaw_host_not_built}} = WasmtimeRuntime.available?()
    end
  end

  defmodule PaddedNativeRuntime do
    @moduledoc """
    A real runtime that IS `AshA2A.GraphLaw.WasmtimeRuntime` (every call runs
    the real native host) whose host id carries one trailing space -- the
    one-space relabel RFC-SA2A-002 S126 refuses. Records no interaction.
    """
    @behaviour AshA2A.GraphLaw.Runtime
    alias AshA2A.GraphLaw.WasmtimeRuntime

    @impl true
    def host_id, do: WasmtimeRuntime.host_id() <> " "
    @impl true
    def engine_id, do: WasmtimeRuntime.engine_id()
    @impl true
    def available?(opts \\ []), do: WasmtimeRuntime.available?(opts)
    @impl true
    def open(opts \\ []), do: WasmtimeRuntime.open(opts)
    @impl true
    def call(session, fun, args), do: WasmtimeRuntime.call(session, fun, args)
    @impl true
    def close(session), do: WasmtimeRuntime.close(session)
  end

  defmodule RelabelledNativeRuntime do
    @moduledoc """
    A real runtime that IS `AshA2A.GraphLaw.WasmtimeRuntime` under entirely
    different caller-controlled labels (`"WASI/StandaloneHost"`, `"wasm3"`).
    Only identity observed from the open session (S126) tells it apart.
    """
    @behaviour AshA2A.GraphLaw.Runtime
    alias AshA2A.GraphLaw.WasmtimeRuntime

    @impl true
    def host_id, do: "WASI/StandaloneHost"
    @impl true
    def engine_id, do: "wasm3"
    @impl true
    def available?(opts \\ []), do: WasmtimeRuntime.available?(opts)
    @impl true
    def open(opts \\ []), do: WasmtimeRuntime.open(opts)
    @impl true
    def call(session, fun, args), do: WasmtimeRuntime.call(session, fun, args)
    @impl true
    def close(session), do: WasmtimeRuntime.close(session)
  end
end

# --- SECTION 15: Original test/ash_a2a/receipt_store/actuation_claim_lease_test.exs ---
defmodule AshA2A.ReceiptStore.ActuationClaimLeaseTest do
  @moduledoc """
  RFC-SA2A-001 S55 actuation-claim liveness -- RFC-SA2A-002 ARD S40's
  idempotency-store robustness requirement, one index below the primary
  command claim `AshA2A.ReceiptStore.ClaimLease` already covers (qualified by
  `test/ash_a2a/chicago/crash_reconciliation_test.exs`).

  Exercises `AshA2A.ReceiptStore.ActuationClaimLease` through both real
  backends -- a real `AshA2A.ReceiptStore.Memory` GenServer and a real
  on-disk `EKV` instance (`cluster_size: 1`, the same real-local-EKV pattern
  `test/ash_a2a/receipt_store_ekv_test.exs` uses) -- against a real
  filesystem `AshA2A.ReceiptOutbox`. No Mock/mox/patch/monkeypatch anywhere
  in this file: "abandoned" and "reclaimed" are asserted on the real claim
  results the stores return, not on interaction expectations.

  TQ-06: the lease is injected per call (`claim_lease_ms:` in the store opts)
  at 500ms -- long enough that the "still held" assertion cannot race a GC
  pause or a loaded scheduler -- and expiry is observed with a deadline poll
  instead of a fixed sleep. Nothing here mutates the global
  `:claim_lease_ms`.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduletag :tmp_dir

  alias AshA2A.{Actuation, Command, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.ReceiptStore.{Ekv, Memory}

  @lease_ms 500
  @expiry_deadline_ms 2_000

  setup %{tmp_dir: tmp_dir} do
    previous_outbox = Application.get_env(:ash_a2a, :receipt_outbox_dir)

    Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(tmp_dir, "outbox"))

    on_exit(fn ->
      case previous_outbox do
        nil -> Application.delete_env(:ash_a2a, :receipt_outbox_dir)
        value -> Application.put_env(:ash_a2a, :receipt_outbox_dir, value)
      end
    end)

    :ok
  end

  # Polls `fun` until it returns `expected` or the deadline passes; returns the
  # last observed value so a failing assertion shows the real result.
  defp eventually(expected, fun, deadline_ms \\ @expiry_deadline_ms) do
    stop = System.monotonic_time(:millisecond) + deadline_ms
    poll(expected, fun, stop)
  end

  defp poll(expected, fun, stop) do
    case fun.() do
      ^expected ->
        expected

      other ->
        if System.monotonic_time(:millisecond) >= stop do
          other
        else
          # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
          AshA2A.TestSupport.Eventually.pause(25)
          poll(expected, fun, stop)
        end
    end
  end

  defp effect_command(command_id, effect_key) do
    Command.new("AshA2A.Test.Fixture.CountingActuator.actuate",
      command_id: command_id,
      agent_id: "s55-lease-agent",
      principal_id: "s55-lease-principal",
      input: %{effect_key: effect_key}
    )
  end

  describe "Memory backend" do
    test "an in-flight actuation is reclaimed once its claimant's primary claim is abandoned (lease elapsed, no outbox anchor)" do
      name = :"actuation_lease_memory_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      opts = [name: name, claim_lease_ms: @lease_ms]

      key = "actuation-lease-#{System.unique_integer([:positive])}"
      crashed = effect_command("crashed-claimant", key)
      actuation = Actuation.identity(crashed)

      # The crashed claimant's primary command claim...
      assert {:execute, _execution_id} = Memory.claim(crashed, opts)
      # ...and its actuation (effect) claim -- exactly the state a process
      # that died before ever preparing a receipt anchor leaves behind.
      assert :proceed = Memory.claim_actuation(actuation, crashed, opts)

      fresh = effect_command("fresh-claimant", key)

      # Before the lease elapses, a second claimant is refused.
      assert {:error, :actuation_in_flight} = Memory.claim_actuation(actuation, fresh, opts)

      # Past the lease, with no outbox anchor for the crashed claimant's
      # command id -- DO could not have started -- a fresh claimant reclaims
      # the effect instead of being refused forever.
      assert :proceed =
               eventually(:proceed, fn -> Memory.claim_actuation(actuation, fresh, opts) end)

      receipt =
        Receipt.from_reply(
          fresh,
          Identity.execution("lease-memory-exec"),
          :external_do,
          {:reply, []}
        )

      assert :ok = Memory.commit_actuation(actuation, receipt, opts)

      later = effect_command("later-claimant", key)

      assert {:duplicate, %Receipt{replayed?: true}} =
               Memory.claim_actuation(actuation, later, opts)
    end

    test "an in-flight actuation is never reclaimed once its claimant's primary claim reached the outbox anchor, no matter how long the lease has passed" do
      name = :"actuation_lease_anchored_memory_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      opts = [name: name, claim_lease_ms: 20]

      key = "actuation-anchored-#{System.unique_integer([:positive])}"
      claimant = effect_command("anchored-claimant", key)
      actuation = Actuation.identity(claimant)

      assert {:execute, execution_id} = Memory.claim(claimant, opts)
      assert :proceed = Memory.claim_actuation(actuation, claimant, opts)

      # The claimant reached the pre-DO receipt boundary before "crashing" --
      # DO may already have run.
      anchor = Receipt.pending(claimant, execution_id, :external_do)
      :ok = ReceiptOutbox.append(anchor)

      # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
      AshA2A.TestSupport.Eventually.pause(60)

      fresh = effect_command("fresh-claimant-anchored", key)

      # Well past the lease, but the anchor exists: this effect may already
      # have actuated, so the actuation claim must stay in-flight -- the
      # lease alone never reclaims it.
      assert {:error, :actuation_in_flight} = Memory.claim_actuation(actuation, fresh, opts)
    end
  end

  describe "Ekv backend" do
    setup do
      ekv_name = :"actuation_lease_ekv_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_actuation_claim_lease_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(data_dir) end)

      # cluster_size: 1 -- a real single-voter setup, the same real-local-EKV
      # pattern test/ash_a2a/receipt_store_ekv_test.exs already uses.
      start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

      %{store_opts: [name: ekv_name, claim_lease_ms: @lease_ms]}
    end

    test "an in-flight actuation is reclaimed once its claimant's primary claim is abandoned", %{
      store_opts: store_opts
    } do
      key = "actuation-lease-ekv-#{System.unique_integer([:positive])}"
      crashed = effect_command("crashed-claimant-ekv", key)
      actuation = Actuation.identity(crashed)

      assert {:execute, _execution_id} = Ekv.claim(crashed, store_opts)
      assert :proceed = Ekv.claim_actuation(actuation, crashed, store_opts)

      fresh = effect_command("fresh-claimant-ekv", key)
      assert {:error, :actuation_in_flight} = Ekv.claim_actuation(actuation, fresh, store_opts)

      assert :proceed =
               eventually(:proceed, fn -> Ekv.claim_actuation(actuation, fresh, store_opts) end)

      receipt =
        Receipt.from_reply(
          fresh,
          Identity.execution("lease-ekv-exec"),
          :external_do,
          {:reply, []}
        )

      assert :ok = Ekv.commit_actuation(actuation, receipt, store_opts)

      later = effect_command("later-claimant-ekv", key)

      assert {:duplicate, %Receipt{replayed?: true}} =
               Ekv.claim_actuation(actuation, later, store_opts)
    end

    test "an in-flight actuation is never reclaimed once its claimant's primary claim reached the outbox anchor",
         %{store_opts: store_opts} do
      store_opts = Keyword.put(store_opts, :claim_lease_ms, 20)
      key = "actuation-anchored-ekv-#{System.unique_integer([:positive])}"
      claimant = effect_command("anchored-claimant-ekv", key)
      actuation = Actuation.identity(claimant)

      assert {:execute, execution_id} = Ekv.claim(claimant, store_opts)
      assert :proceed = Ekv.claim_actuation(actuation, claimant, store_opts)

      anchor = Receipt.pending(claimant, execution_id, :external_do)
      :ok = ReceiptOutbox.append(anchor)

      # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
      AshA2A.TestSupport.Eventually.pause(60)

      fresh = effect_command("fresh-claimant-ekv-anchored", key)
      assert {:error, :actuation_in_flight} = Ekv.claim_actuation(actuation, fresh, store_opts)
    end
  end
end

# --- SECTION 16: Original test/ash_a2a/receipt_store/boot_check_test.exs ---
defmodule AshA2A.ReceiptStore.BootCheckTest do
  @moduledoc """
  Findings R2 / R12 / PERF-09: `AshA2A.ReceiptStore.boot_check/1` refuses
  configurations whose at-most-once proof would not survive a reboot. All
  inputs are passed as opts, so no application env is mutated; paths are
  real directories (the real tmp dir vs. a real non-tmp directory).
  """

  use ExUnit.Case, async: true

  alias AshA2A.ReceiptStore
  alias AshA2A.ReceiptStore.{Ekv, Memory}

  @durable_dir Path.expand("_build_boot_check_durable", File.cwd!())
  @tmp_dir Path.join(System.tmp_dir!(), "ash_a2a_boot_check")

  defp check(opts) do
    ReceiptStore.boot_check(
      Keyword.merge(
        [
          production: false,
          receipt_store: Memory,
          receipt_outbox_dir: nil,
          receipt_store_ekv_opts: [],
          kill_switch_path: nil,
          allow_memory_receipt_store: false
        ],
        opts
      )
    )
  end

  test "a durable store with a tmp or unset outbox dir is refused" do
    ekv = [data_dir: @durable_dir]

    assert {:error, {:non_durable_outbox_dir, nil}} =
             check(receipt_store: Ekv, receipt_store_ekv_opts: ekv)

    assert {:error, {:non_durable_outbox_dir, @tmp_dir}} =
             check(receipt_store: Ekv, receipt_store_ekv_opts: ekv, receipt_outbox_dir: @tmp_dir)

    assert :ok =
             check(
               receipt_store: Ekv,
               receipt_store_ekv_opts: ekv,
               receipt_outbox_dir: @durable_dir
             )
  end

  test "Ekv with a tmp data_dir is refused" do
    assert {:error, {:non_durable_receipt_store_data_dir, @tmp_dir}} =
             check(
               receipt_store: Ekv,
               receipt_store_ekv_opts: [data_dir: @tmp_dir],
               receipt_outbox_dir: @durable_dir
             )
  end

  test "production refuses an implicit store, the Memory store, a small cluster, and a volatile kill switch" do
    assert {:error, :receipt_store_not_configured} =
             ReceiptStore.boot_check(production: true, receipt_store: nil)

    assert {:error, {:non_durable_receipt_store, Memory}} =
             check(production: true, receipt_store: Memory)

    durable_ekv = [
      production: true,
      receipt_store: Ekv,
      receipt_outbox_dir: @durable_dir,
      receipt_store_ekv_opts: [data_dir: @durable_dir, cluster_size: 1]
    ]

    assert {:error, {:insufficient_cluster_size, 1}} = check(durable_ekv)

    three =
      Keyword.put(durable_ekv, :receipt_store_ekv_opts, data_dir: @durable_dir, cluster_size: 3)

    assert {:error, {:non_durable_kill_switch_path, nil}} = check(three)

    assert :ok = check(Keyword.put(three, :kill_switch_path, Path.join(@durable_dir, "ks.dets")))

    # Escape hatch for Memory is explicit and still needs a durable kill switch.
    assert :ok =
             check(
               production: true,
               receipt_store: Memory,
               allow_memory_receipt_store: true,
               kill_switch_path: Path.join(@durable_dir, "ks.dets")
             )
  end

  test "non-production Memory with defaults stays bootable (backwards compatible)" do
    assert :ok = check([])
  end

  test "durable_path?/1 rejects the tmp dir under any spelling" do
    refute ReceiptStore.durable_path?(nil)
    refute ReceiptStore.durable_path?("")
    refute ReceiptStore.durable_path?(System.tmp_dir!())
    refute ReceiptStore.durable_path?(Path.join(System.tmp_dir!(), "x/y"))
    refute ReceiptStore.durable_path?("/tmp/ash_a2a")
    assert ReceiptStore.durable_path?(@durable_dir)
  end
end

# --- SECTION 17: Original test/ash_a2a/receipt_store/store_hardening_test.exs ---
defmodule AshA2A.ReceiptStore.StoreHardeningTest do
  @moduledoc """
  Findings R1 (lost actuation commit must not re-open a completed effect),
  R4 (execution-id fencing), and R12/PERF-09 (bounded Memory state) against
  both real backends: a real `AshA2A.ReceiptStore.Memory` GenServer and a
  real on-disk `EKV` (`cluster_size: 1`), with a real filesystem
  `AshA2A.ReceiptOutbox`. Assertions are on the real results the stores
  return; no mocks.

  Leases are injected per call (`claim_lease_ms:` in store opts, TQ-06), so
  nothing here mutates the global `:claim_lease_ms`.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduletag :tmp_dir

  alias AshA2A.{Actuation, Command, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.ReceiptStore.{ActuationClaimLease, Ekv, Memory}

  setup %{tmp_dir: tmp_dir} do
    previous_outbox = Application.get_env(:ash_a2a, :receipt_outbox_dir)
    Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(tmp_dir, "outbox"))

    on_exit(fn ->
      case previous_outbox do
        nil -> Application.delete_env(:ash_a2a, :receipt_outbox_dir)
        value -> Application.put_env(:ash_a2a, :receipt_outbox_dir, value)
      end
    end)

    :ok
  end

  defp effect_command(command_id, effect_key) do
    Command.new("AshA2A.Test.Fixture.CountingActuator.actuate",
      command_id: command_id,
      agent_id: "hardening-agent",
      principal_id: "hardening-principal",
      input: %{effect_key: effect_key}
    )
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp memory_opts(extra \\ []) do
    name = :"store_hardening_memory_#{System.unique_integer([:positive])}"
    start_supervised!({Memory, [name: name] ++ extra})
    [name: name]
  end

  defp ekv_opts do
    ekv_name = :"store_hardening_ekv_#{System.unique_integer([:positive])}"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_store_hardening_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(data_dir) end)
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})
    [name: ekv_name]
  end

  # --- R1 ------------------------------------------------------------------

  for backend <- [Memory, Ekv] do
    @backend backend

    describe "R1 #{inspect(backend)}" do
      setup do
        %{opts: if(@backend == Memory, do: memory_opts(), else: ekv_opts())}
      end

      test "a completed effect whose actuation commit was lost answers {:duplicate, primary receipt}, never :proceed",
           %{opts: opts} do
        store = @backend
        key = unique("r1")
        first = effect_command(unique("r1-first"), key)
        actuation = Actuation.identity(first)

        assert {:execute, execution_id} = store.claim(first, opts)
        assert :proceed = store.claim_actuation(actuation, first, opts)

        # DO ran and the PRIMARY receipt committed, but commit_actuation/3
        # was lost (process died / store call failed between the two).
        receipt =
          first
          |> Receipt.pending(execution_id, :external_do)
          |> Receipt.finalize({:reply, 1})

        assert :ok = store.commit(receipt, opts)

        # No anchor remains (commit removed it) and the lease is 0: before
        # R1 this reclaimed the effect and DO ran a second time.
        retry = effect_command(unique("r1-retry"), key)

        assert {:duplicate, %Receipt{replayed?: true} = dup} =
                 store.claim_actuation(actuation, retry, opts ++ [claim_lease_ms: 0])

        assert dup.receipt_id == receipt.receipt_id

        # The entry was healed: a later claimant is answered from the
        # actuation index itself.
        assert {:duplicate, _} =
                 store.claim_actuation(
                   actuation,
                   effect_command(unique("r1-later"), key),
                   opts ++ [claim_lease_ms: 0]
                 )
      end

      test "a claimant whose primary receipt is a pre-DO refusal is reclaimable", %{opts: opts} do
        store = @backend
        key = unique("r1-refused")
        first = effect_command(unique("r1-refused-first"), key)
        actuation = Actuation.identity(first)

        assert {:execute, execution_id} = store.claim(first, opts)
        assert :proceed = store.claim_actuation(actuation, first, opts)

        refusal =
          Receipt.from_reply(
            first,
            execution_id,
            :external_do,
            {:error, %{code: :receipt_anchor_unavailable, detail: "anchor"}}
          )

        assert refusal.terminal_status == :refused
        assert :ok = store.commit(refusal, opts)

        assert :proceed =
                 store.claim_actuation(
                   actuation,
                   effect_command(unique("r1-refused-retry"), key),
                   opts ++ [claim_lease_ms: 0]
                 )
      end

      test "a claimant whose primary receipt is still :pending stays in flight", %{opts: opts} do
        store = @backend
        key = unique("r1-pending")
        first = effect_command(unique("r1-pending-first"), key)
        actuation = Actuation.identity(first)

        assert {:execute, execution_id} = store.claim(first, opts)
        assert :proceed = store.claim_actuation(actuation, first, opts)
        assert :ok = store.commit(Receipt.pending(first, execution_id, :external_do), opts)

        assert {:error, :actuation_in_flight} =
                 store.claim_actuation(
                   actuation,
                   effect_command(unique("r1-pending-retry"), key),
                   opts ++ [claim_lease_ms: 0]
                 )
      end

      # --- R4 --------------------------------------------------------------

      test "commit is fenced on execution id: a reclaimed claim refuses the stale executor",
           %{opts: opts} do
        store = @backend
        command = effect_command(unique("r4"), unique("r4-key"))

        assert {:execute, stale} = store.claim(command, opts)
        # Lease 0 and no anchor: the claim is abandoned and reclaimed.
        assert {:execute, current} = store.claim(command, opts ++ [claim_lease_ms: 0])
        refute stale == current

        assert {:error, :stale_execution} = store.confirm_claim(command.command_id, stale, opts)
        assert :ok = store.confirm_claim(command.command_id, current, opts)

        stale_receipt =
          command |> Receipt.pending(stale, :external_do) |> Receipt.finalize({:reply, :stale})

        current_receipt =
          command
          |> Receipt.pending(current, :external_do)
          |> Receipt.finalize({:reply, :current})

        assert {:error, :stale_execution} = store.commit(stale_receipt, opts)
        assert :ok = store.commit(current_receipt, opts)
        # The stale executor still cannot overwrite after the fact.
        assert {:error, :stale_execution} = store.commit(stale_receipt, opts)

        assert {:ok, %Receipt{reply: {:reply, :current}}} = store.fetch(command.command_id, opts)
      end
    end
  end

  test "ActuationClaimLease.decide/3 never reclaims behind a finalized primary receipt" do
    command = effect_command(unique("decide"), unique("decide-key"))
    execution_id = Identity.execution("decide-exec")

    receipt =
      command |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

    assert {:duplicate, ^receipt} =
             ActuationClaimLease.decide(
               %{receipt: receipt, claimed_at: nil},
               command.command_id,
               claim_lease_ms: 0
             )

    refute ActuationClaimLease.abandoned?(
             %{receipt: receipt, claimed_at: nil},
             command.command_id,
             claim_lease_ms: 0
           )

    assert :reclaim =
             ActuationClaimLease.decide(
               %{receipt: nil, claimed_at: nil},
               command.command_id,
               claim_lease_ms: 0
             )
  end

  # --- R12 / PERF-09 ---------------------------------------------------------

  test "Memory TTL sweep evicts only committed entries older than the TTL" do
    opts = memory_opts(receipt_ttl_ms: 50, sweep_interval_ms: 3_600_000)

    committed = effect_command(unique("ttl-committed"), unique("k"))
    in_flight = effect_command(unique("ttl-inflight"), unique("k"))

    assert {:execute, execution_id} = Memory.claim(committed, opts)
    assert {:execute, _} = Memory.claim(in_flight, opts)

    receipt =
      committed |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

    assert :ok = Memory.commit(receipt, opts)
    assert Memory.size(opts) == 2

    # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
    AshA2A.TestSupport.Eventually.pause(80)

    assert 1 = Memory.sweep(opts)
    assert Memory.size(opts) == 1
    assert :error = Memory.fetch(committed.command_id, opts)
    # The in-flight claim survives the sweep.
    assert {:error, :in_flight} = Memory.claim(in_flight, opts)
  end

  test "Memory max_entries evicts the oldest committed receipts first, never in-flight claims" do
    opts = memory_opts(max_entries: 2)

    [a, b, c] =
      for label <- ["a", "b", "c"] do
        command = effect_command(unique("max-#{label}"), unique("k"))
        assert {:execute, execution_id} = Memory.claim(command, opts)

        receipt =
          command |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

        assert :ok = Memory.commit(receipt, opts)
        command
      end

    assert Memory.size(opts) == 2
    assert :error = Memory.fetch(a.command_id, opts)
    assert {:ok, _} = Memory.fetch(b.command_id, opts)
    assert {:ok, _} = Memory.fetch(c.command_id, opts)

    # In-flight entries are never evicted, even over the bound.
    for label <- ["x", "y", "z"] do
      assert {:execute, _} =
               Memory.claim(effect_command(unique("inflight-#{label}"), unique("k")), opts)
    end

    assert Memory.size(opts) == 5
  end

  test "Memory TTL sweep keeps a committed primary still referenced by an in-flight actuation entry" do
    opts = memory_opts(receipt_ttl_ms: 20, sweep_interval_ms: 3_600_000)
    key = unique("pinned")
    first = effect_command(unique("pinned-first"), key)
    actuation = Actuation.identity(first)

    assert {:execute, execution_id} = Memory.claim(first, opts)
    assert :proceed = Memory.claim_actuation(actuation, first, opts)

    receipt =
      first |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

    # The primary commit landed; the actuation commit was lost (R1 shape).
    assert :ok = Memory.commit(receipt, opts)
    # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
    AshA2A.TestSupport.Eventually.pause(40)

    # The expired primary is the only evidence the effect completed: the
    # sweep must keep it, or the effect would be refused forever.
    assert 0 = Memory.sweep(opts)
    assert {:ok, _} = Memory.fetch(first.command_id, opts)

    assert {:duplicate, %Receipt{} = dup} =
             Memory.claim_actuation(
               actuation,
               effect_command(unique("pinned-retry"), key),
               opts ++ [claim_lease_ms: 0]
             )

    assert dup.receipt_id == receipt.receipt_id
  end

  test "Ekv.confirm_claim/3 answers a failed consistent read with a typed refusal, never a raise",
       %{tmp_dir: tmp_dir} do
    # A real EKV member with no CAS config: `EKV.get(_, _, consistent: true)`
    # raises there, exactly as it does on quorum loss.
    name = :"store_hardening_ekv_nocas_#{System.unique_integer([:positive])}"
    start_supervised!({EKV, name: name, data_dir: Path.join(tmp_dir, "ekv-nocas")})
    command = effect_command(unique("nocas"), unique("k"))

    assert {:error, :receipt_store_unavailable} =
             Ekv.confirm_claim(command.command_id, Identity.execution("nocas-exec"), name: name)
  end

  test "a legacy bare-map start still yields a working store (backwards compatible init)" do
    name = :"store_hardening_legacy_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start(Memory, %{}, name: name)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)

    command = effect_command(unique("legacy"), unique("k"))
    assert {:execute, _} = Memory.claim(command, name: name)
  end

  test "an outbox entry for one command does not anchor another (R5 scoping at the store)" do
    opts = memory_opts()
    torn_owner = effect_command(unique("torn-owner"), unique("k"))
    other = effect_command(unique("other"), unique("k"))

    File.mkdir_p!(ReceiptOutbox.dir())

    File.write!(
      ReceiptOutbox.entry_path_for(torn_owner.command_id, Identity.runtime("torn")),
      <<131, 104>>
    )

    assert {:execute, _} = Memory.claim(torn_owner, opts)
    assert {:execute, _} = Memory.claim(other, opts)

    # The torn file blocks reclaim of its own command only.
    assert {:error, :in_flight} = Memory.claim(torn_owner, opts ++ [claim_lease_ms: 0])
    assert {:execute, _} = Memory.claim(other, opts ++ [claim_lease_ms: 0])
  end
end

# --- SECTION 18: Original test/ash_a2a/research/erc_sanitize_test.exs ---
defmodule AshA2A.Research.ERCSanitizeTest do
  @moduledoc "CWE-22 court: traversal ids never write outside the receipt dir. DB-free."
  use ExUnit.Case, async: true

  alias AshA2A.Research.ERC

  defp attrs(id),
    do: %{id: id, claim: "c", falsifier: "f", state: :observed, evidence: %{"n" => 1}}

  defp tree(dir), do: dir |> Path.join("**/*") |> Path.wildcard(match_dot: true) |> Enum.sort()

  @tag :tmp_dir
  test "traversal and separator ids are refused; nothing escapes the dir", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "erc")
    before = tree(tmp)

    for bad <- [
          "../evil",
          "../../evil",
          "a/b",
          "a\\b",
          "..",
          "x/../../y",
          "/abs",
          "",
          ".hidden",
          "a\0b",
          String.duplicate("a", 200)
        ] do
      assert_raise ArgumentError, ~r/refused_erc_id/, fn -> ERC.emit!(attrs(bad), dir: dir) end
    end

    assert tree(tmp) == before
    refute File.exists?(Path.join(tmp, "evil-1.json"))
  end

  @tag :tmp_dir
  test "a normal id writes exactly one file inside dir", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "erc")
    assert {:ok, path} = ERC.emit!(attrs("ERC-001"), dir: dir)
    assert Path.dirname(path) == dir
    assert File.exists?(path)
    assert [_] = File.ls!(dir)
  end
end

# --- SECTION 19: Original test/ash_a2a/sa2a/conformance/mix_project_stack_test.exs ---
defmodule AshA2A.SA2A.Conformance.MixProjectStackTest do
  # Not async: asserts on the process-global Mix project stack.
  use ExUnit.Case, async: false

  alias AshA2A.SA2A.Conformance.Checks.C2

  # `project_info/2` evaluates a sibling project's real mix.exs. `use
  # Mix.Project` pushes that module onto the global Mix project stack when it
  # compiles, and a stack that still holds the sibling makes every later
  # `Mix.Task.run("app.start")` in this VM compile the sibling project and
  # prune the code path (whole-suite `{:error, :bad_name}` / "module not
  # available" cascade). Evaluating a project must leave the stack as found.
  test "evaluating a sibling mix.exs leaves the Mix project stack unchanged" do
    root = Path.join(System.tmp_dir!(), "mps-#{System.unique_integer([:positive])}")
    dir = Path.join(root, "sibling")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule MixProjectStackTest.Sibling#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :mps_sibling, version: "0.0.1", deps: []]
    end
    """)

    on_exit(fn -> File.rm_rf!(root) end)

    before = Mix.Project.get()
    assert {:ok, %{app: :mps_sibling}} = C2.project_info(%{root: root}, "sibling")
    assert Mix.Project.get() == before
    assert Mix.Project.get() == AshA2A.MixProject
  end

  test "the real actuator/ and authority_service/ projects evaluate without leaking either" do
    root = File.cwd!()
    before = Mix.Project.get()
    assert {:ok, %{app: :actuator}} = C2.project_info(%{root: root}, "actuator")
    assert {:ok, %{app: :authority_service}} = C2.project_info(%{root: root}, "authority_service")
    assert Mix.Project.get() == before
  end
end

# --- SECTION 20: Original test/ash_a2a/sa2a/conformance/profiles_test.exs ---

# --- SECTION 21: Original test/attestation/attestation_gate_test.exs ---
defmodule AshA2A.Attestation.GateTest do
  @moduledoc """
  Chicago-style tests: real :crypto ECDSA P-256 sign/verify round-trips, no
  mocks. Asserts on final typed outcomes (tokens, {:refused, reason}).
  """
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.{Gate, Key}

  @now 1_700_000_000

  defp fresh_claims(nonce, extra) do
    Map.merge(
      %{
        "nonce" => nonce,
        "device_id" => "device-abc",
        "os_fingerprint" => "google/raven/raven:13/TQ3A.230901.001",
        "is_virtual" => false,
        "issued_at" => @now - 10
      },
      extra
    )
  end

  defp signed(extra \\ %{}, nonce \\ "nonce-123") do
    key = Key.generate()
    token = Key.sign(fresh_claims(nonce, extra), key)
    {key, token}
  end

  describe "Key sign/verify round-trip" do
    test "sign then verify with the matching public key returns the claims" do
      key = Key.generate()
      claims = %{"nonce" => "n1", "device_id" => "d1"}
      token = Key.sign(claims, key)
      assert {:ok, ^claims} = Key.verify(token, key)
    end

    test "tampered payload is refused with :bad_signature" do
      key = Key.generate()
      token = Key.sign(%{"nonce" => "n1"}, key)
      [pfx, payload, sig] = String.split(token, ".", parts: 3)

      # Tamper the payload (flip a byte of the JSON by re-encoding altered claims)
      forged_payload =
        payload
        |> then(fn p -> Base.url_decode64!(p, padding: false) end)
        |> String.replace("n1", "n2")
        |> Base.url_encode64(padding: false)

      tampered = Enum.join([pfx, forged_payload, sig], ".")
      assert {:error, :bad_signature} = Key.verify(tampered, key)
    end

    test "signature from a different key is refused" do
      k1 = Key.generate()
      k2 = Key.generate()
      token = Key.sign(%{"nonce" => "n1"}, k1)
      assert {:error, :bad_signature} = Key.verify(token, k2)
    end

    test "malformed token is typed-refused" do
      key = Key.generate()
      assert {:error, :malformed_token} = Key.verify("not-a-token", key)
    end
  end

  describe "verify_enclave/2" do
    test "fresh, real-shaped payload passes" do
      {key, token} = signed()

      assert {:ok, %{"device_id" => "device-abc"}} =
               Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "virtual claim triggers {:refused, :emulator_detected}" do
      {key, token} = signed(%{"is_virtual" => true})
      assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "emulator-flavored os_fingerprint triggers :emulator_detected" do
      {key, token} = signed(%{"os_fingerprint" => "google/sdk_gphone_x86/generic:13"})
      assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "known emulator package triggers :emulator_detected" do
      {key, token} = signed(%{"installed_packages" => ["com.bluestacks.something"]})
      assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "tampered token is refused with :bad_signature" do
      {key, token} = signed()
      [pfx, payload, _sig] = String.split(token, ".", parts: 3)

      forged_payload =
        Base.url_decode64!(payload, padding: false)
        |> String.replace("\"device-abc\"", "\"device-hax\"")
        |> Base.url_encode64(padding: false)

      tampered = Enum.join([pfx, forged_payload, "AAAA"], ".")
      assert {:refused, :bad_signature} = Gate.verify_enclave({tampered, "nonce-123"}, key: key)
    end

    test "nonce mismatch is typed-refused" do
      {key, token} = signed()
      assert {:refused, :nonce_mismatch} = Gate.verify_enclave({token, "other-nonce"}, key: key)
    end
  end

  describe "verify_freshness/2" do
    test "fresh claim passes" do
      assert :ok = Gate.verify_freshness(%{"issued_at" => @now - 30}, now: @now)
    end

    test "stale claim is refused" do
      assert {:refused, :stale} = Gate.verify_freshness(%{"issued_at" => @now - 91}, now: @now)
    end

    test "boundary: exactly max_staleness_sec old passes, +1s refuses" do
      assert :ok = Gate.verify_freshness(%{"issued_at" => @now - 90}, now: @now)

      assert {:refused, :stale} =
               Gate.verify_freshness(%{"issued_at" => @now - 91},
                 now: @now,
                 max_staleness_sec: 90
               )
    end

    test "missing issued_at is malformed" do
      assert {:refused, :malformed_token} = Gate.verify_freshness(%{}, now: @now)
    end

    test "future-issued beyond small skew is refused :clock_skew (typed, not :stale)" do
      assert {:refused, :clock_skew} =
               Gate.verify_freshness(%{"issued_at" => @now + 60}, now: @now)
    end

    test "boundary: exactly 5s forward skew accepted, +1s refused" do
      assert :ok = Gate.verify_freshness(%{"issued_at" => @now + 5}, now: @now)

      assert {:refused, :clock_skew} =
               Gate.verify_freshness(%{"issued_at" => @now + 6}, now: @now)
    end
  end

  describe "verify_sensor_metadata/2" do
    defp good_sensor do
      %{
        "camera_make" => "Apple",
        "camera_model" => "iPhone 15 Pro",
        "gps" => %{"lat" => 35.68, "lon" => 139.76, "timestamp" => @now - 20, "accuracy" => 8.0}
      }
    end

    test "well-formed fresh sensor metadata passes" do
      assert :ok = Gate.verify_sensor_metadata(good_sensor(), now: @now)
    end

    test "missing camera_make is spoofed_payload" do
      claims = Map.delete(good_sensor(), "camera_make")
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "missing gps block is spoofed_payload" do
      claims = Map.delete(good_sensor(), "gps")
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "absurd gps accuracy is spoofed_payload" do
      claims = put_in(good_sensor(), ["gps", "accuracy"], 5_000_000.0)
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "out-of-range lat is spoofed_payload" do
      claims = put_in(good_sensor(), ["gps", "lat"], 123.0)
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "stale gps timestamp is refused :stale" do
      claims = put_in(good_sensor(), ["gps", "timestamp"], @now - 300)
      assert {:refused, :stale} = Gate.verify_sensor_metadata(claims, now: @now)
    end
  end

  describe "verify_gps_trajectory/1 (mock-GPS rejection)" do
    defp obs(lat, lon, ts), do: %{"lat" => lat, "lon" => lon, "timestamp" => ts}

    test "realistic walk passes" do
      # Tokyo station -> ~200m away, 30s later
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(35.6830, 139.7690, @now + 30)
               ])
    end

    test "teleport Tokyo->Sapporo within 60s is :gps_impossible_jump" do
      assert {:refused, :gps_impossible_jump} =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(43.0618, 141.3545, @now + 45)
               ])
    end

    test "sub-threshold jump Tokyo->Osaka (~392km < 500km) is allowed" do
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(34.6937, 135.5023, @now + 45)
               ])
    end

    test "large jump with >60s elapsed is allowed (flight-speed travel)" do
      # Same Tokyo->Sapporo jump but 2 hours later
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(43.0618, 141.3545, @now + 7200)
               ])
    end

    test "unsorted observations are sorted before checking" do
      assert {:refused, :gps_impossible_jump} =
               Gate.verify_gps_trajectory([
                 obs(43.0618, 141.3545, @now + 45),
                 obs(35.6812, 139.7671, @now)
               ])
    end

    test "identical-coordinate no-movement sequence is lawful (replay closed by nonce ledger, not geometry)" do
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(35.6812, 139.7671, @now + 30)
               ])
    end

    # Platform law (OTP 28): NaN floats are unconstructible — float bit-pattern
    # matches, :math domain errors (sqrt(-1), log(0)), arithmetic overflow, and
    # binary_to_term NEW_FLOAT_EXT all raise. The substrate itself refuses NaN,
    # so the reachable form of this attack here is the adversarially huge
    # integer below (which would crash :math on unguarded code paths).
    test "sqrt(-1) raises badarg (platform law: :math never returns NaN)" do
      assert_raise ArithmeticError, fn -> :math.sqrt(-1.0) end
    end

    test "adversarially huge integer coordinate is refused :spoofed_payload (no :math badarg crash)" do
      huge = String.duplicate("9", 400) |> String.to_integer()

      assert {:refused, :spoofed_payload} =
               Gate.verify_gps_trajectory([
                 obs(huge, 139.7671, @now),
                 obs(35.6812, 139.7671, @now + 30)
               ])
    end

    test "non-numeric coordinate string is refused :spoofed_payload" do
      assert {:refused, :spoofed_payload} =
               Gate.verify_gps_trajectory([
                 obs("35.6812", 139.7671, @now),
                 obs(35.6812, 139.7671, @now + 30)
               ])
    end
  end

  # ECDSA malleability: (r, s) and (r, n - s) both verify against the same
  # pubkey; the low-s gate must refuse the malleated twin before crypto.
  describe "signature malleability (canonical low-s)" do
    @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

    test "canonical token verifies" do
      {key, token} = signed()
      assert {:ok, _} = Key.verify(token, key)
    end

    test "malleated twin (s' = n - s) is refused :non_canonical_signature" do
      {key, token} = signed()
      twin = malleate(token)

      # the twin differs from the original but is still a valid ECDSA signature
      assert twin != token
      assert {:error, :non_canonical_signature} = Key.verify(twin, key)
    end

    test "malleated twin through verify_enclave is {:refused, :non_canonical_signature}" do
      {key, token} = signed()

      assert {:refused, :non_canonical_signature} =
               Gate.verify_enclave({malleate(token), "nonce-123"}, key: key)
    end

    defp malleate(token) do
      [pfx, payload, sig] = String.split(token, ".", parts: 3)
      der = Base.url_decode64!(sig, padding: false)
      <<0x30, _len, body::binary>> = der
      <<0x02, rlen, r::binary-size(rlen), 0x02, slen, s_bin::binary-size(slen)>> = body

      s = :binary.decode_unsigned(s_bin)
      s2_bin = der_int(@n - s)
      body2 = <<0x02, byte_size(r), r::binary, 0x02, byte_size(s2_bin), s2_bin::binary>>
      der2 = <<0x30, byte_size(body2), body2::binary>>

      Enum.join([pfx, payload, Base.url_encode64(der2, padding: false)], ".")
    end

    defp der_int(v) do
      bin = :binary.encode_unsigned(v)

      case bin do
        <<first, _::binary>> when first >= 128 -> <<0, bin::binary>>
        <<0, _::binary>> = padded -> padded
        _ -> bin
      end
    end
  end
end

# --- SECTION 22: Original test/attestation/gate_grant_allowlist_test.exs ---
defmodule AshA2A.Attestation.GateGrantAllowlistTest do
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.Gate

  # Hand-pinned from /Users/sac/xaas/lib/xaas/governance/approval_geofence_exception_grant.ex
  # attributes (id/org_id/identifier_or_cidr/ttl_hours); approved_at + area are the
  # enforcement-side projections recorded at approve time (see GateGrantAllowlist moduledoc).
  @now 1_700_000_000

  defp grant(overrides \\ []) do
    {area_overrides, top} = Keyword.split(overrides, [:area])

    Map.merge(
      %{
        grant_id: "g-1",
        org_id: "org-1",
        identifier_or_cidr: "203.0.113.0/24",
        ttl_hours: 24,
        approved_at: @now - 60,
        area:
          Map.merge(
            %{"lat" => 37.0, "lon" => -122.0, "radius_km" => 2000.0},
            case area_overrides[:area] do
              nil -> %{}
              %{} = m -> m
              kw -> Map.new(kw, fn {k, v} -> {Atom.to_string(k), v} end)
            end
          )
      },
      Map.new(top)
    )
  end

  # ~1255 km apart in under 60s — an impossible jump unless granted.
  defp jumping_obs do
    [
      %{"lat" => 37.0, "lon" => -122.0, "timestamp" => @now - 30},
      %{"lat" => 47.0, "lon" => -115.0, "timestamp" => @now}
    ]
  end

  test "approved in-scope grant overrides the jump; same coordinates without/expired/out-of-scope still refuse" do
    assert Gate.verify_gps_trajectory(jumping_obs()) == {:refused, :gps_impossible_jump}

    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [grant()]
           ) == :ok

    unapproved_area =
      grant(area: %{"lat" => 35.0, "lon" => 139.0, "radius_km" => 10.0})

    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [unapproved_area]
           ) == {:refused, :gps_impossible_jump}

    expired = grant(approved_at: @now - 24 * 3600 - 1)

    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [expired]
           ) == {:refused, :gps_impossible_jump}
  end

  test "no grants supplied: /2 is outcome-identical to /1, and non-jump refusals are never overridden" do
    assert Gate.verify_gps_trajectory(jumping_obs(), now: @now) ==
             Gate.verify_gps_trajectory(jumping_obs())

    malformed = [%{"lat" => "x", "lon" => 0.0, "timestamp" => 1}]

    assert Gate.verify_gps_trajectory(malformed,
             now: @now,
             approved_grants: [grant()]
           ) == {:refused, :spoofed_payload}
  end

  test "mutation probe: grant cover is computed on real distances, not constant-true" do
    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [grant(area: [radius_km: 0.0])]
           ) == {:refused, :gps_impossible_jump}
  end
end

# --- SECTION 23: Original test/attestation/lane01_hardening_test.exs ---
defmodule AshA2A.Attestation.Lane01HardeningTest do
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.{Gate, GateGrantAllowlist, Key}

  @now 1_700_000_000

  defp b64(d), do: Base.url_encode64(d, padding: false)

  defp signed_raw(raw_payload, key) do
    sig = :crypto.sign(:ecdsa, :sha256, raw_payload, [key.priv, :prime256v1])
    "v1." <> b64(raw_payload) <> "." <> b64(sig)
  end

  test "bad base64 token yields typed :malformed_token" do
    key = Key.generate()
    assert {:error, :malformed_token} = Key.verify("v1.!!!.@@@", key)
    assert {:refused, :malformed_token} = Gate.verify_enclave({"v1.!!!.@@@", "n"}, key)
  end

  test "non-JSON and non-map signed payloads yield typed errors" do
    key = Key.generate()
    # Retry until the random signature is low-s (verify enforces canonical form).
    non_json = find_canonical("not json at all", key)
    assert {:error, :malformed_token} = Key.verify(non_json, key)
    list_payload = find_canonical("[1,2,3]", key)
    assert {:error, :malformed_token} = Key.verify(list_payload, key)
  end

  defp find_canonical(raw, key) do
    Enum.find_value(1..64, fn _ ->
      tok = signed_raw(raw, key)

      case Key.verify(tok, key) do
        {:error, :non_canonical_signature} -> nil
        _ -> tok
      end
    end)
  end

  test "bad private key is {:error, :bad_key}; verify without :pub or non-binary token is typed" do
    assert {:error, :bad_key} = Key.sign(%{"a" => 1}, %{priv: :nope, pub: "x"})
    assert {:error, :bad_key} = Key.sign(%{"a" => 1}, %{})
    assert {:error, :malformed_token} = Key.verify("v1.a.b", %{})
    assert {:error, :malformed_token} = Key.verify(nil, Key.generate())
    assert {:refused, :malformed_token} = Gate.verify_enclave({nil, "n"}, nil)
  end

  test "emulator detection type guards refuse non-binary fingerprint / non-list packages" do
    key = Key.generate()

    for extra <- [%{"os_fingerprint" => 42}, %{"installed_packages" => "com.bluestacks"}] do
      token = Key.sign(Map.merge(%{"nonce" => "n"}, extra), key)
      assert {:refused, :spoofed_payload} = Gate.verify_enclave({token, "n"}, key)
    end

    token = Key.sign(%{"nonce" => "n", "installed_packages" => ["com.android.fly.x"]}, key)
    assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "n"}, key)
  end

  defp grant(extra \\ %{}) do
    Map.merge(
      %{
        grant_id: "g",
        org_id: "org-1",
        identifier_or_cidr: "id-1",
        ttl_hours: 24,
        approved_at: @now - 60,
        area: %{"lat" => 37.0, "lon" => -122.0, "radius_km" => 2000.0}
      },
      extra
    )
  end

  defp jumping do
    [
      %{"lat" => 37.0, "lon" => -122.0, "timestamp" => @now - 30},
      %{"lat" => 47.0, "lon" => -115.0, "timestamp" => @now}
    ]
  end

  test "grant missing :area is not covering; no crash" do
    g = Map.delete(grant(), :area)

    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(), approved_grants: [g], now: @now)
  end

  test "unsorted observations are sorted like the base check" do
    assert :ok =
             Gate.verify_gps_trajectory(Enum.reverse(jumping()),
               approved_grants: [grant()],
               now: @now
             )
  end

  test "future approved_at grant is rejected" do
    g = grant(%{approved_at: @now + 1000})

    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(), approved_grants: [g], now: @now)
  end

  test "grants are scoped by org_id / identifier when supplied" do
    assert :ok =
             Gate.verify_gps_trajectory(jumping(),
               approved_grants: [grant()],
               now: @now,
               org_id: "org-1"
             )

    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(),
               approved_grants: [grant()],
               now: @now,
               org_id: "org-2"
             )

    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(),
               approved_grants: [grant()],
               now: @now,
               identifier: "other"
             )

    assert :ok = GateGrantAllowlist.override?(jumping(), [grant()], @now, identifier: "id-1")
  end

  test "malformed grant entries are ignored" do
    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(), approved_grants: [:junk, %{}, nil], now: @now)
  end
end
