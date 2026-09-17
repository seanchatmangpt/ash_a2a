defmodule AshA2A.Chicago.Release.ExactSubjectTest do
  @moduledoc """
  Qualifies `AshA2A.Chicago.Release.ExactSubject` Chicago style: real
  `build!/1` against this actual repository's own `lib/ash_a2a/chicago/*.ex`
  sources, real git HEAD, and the real 11-repo topology court
  (`AshA2A.Chicago.Courts.SA2AV269_17Topology`) -- zero mocks. Assertions are
  state-based (the real returned struct/map/digest), never interaction-based.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Chicago.Release.ExactSubject
  alias AshA2A.Chicago.Courts.SA2AV269_17Topology, as: Topology
  alias AshA2A.Chicago.Subject

  describe "schema/0 and scope_disclosure/0" do
    test "reports the real §84 schema identity" do
      assert ExactSubject.schema() == "ash_a2a.chicago.release.exact_subject/1"
    end

    test "the scope-disclosure text names autofde-lab as the out-of-scope primary integration court" do
      assert ExactSubject.scope_disclosure() =~ "autofde-lab"
      assert ExactSubject.scope_disclosure() =~ "BOUNDED TO ash_a2a's own subject"
    end
  end

  describe "build!/1 against this real repo" do
    setup do
      %{subject: ExactSubject.build!()}
    end

    test "release/contract fields are the real fixed v26.9.17 identity", %{subject: s} do
      assert s.release == "26.9.17"
      assert s.release_contract == "RFC-SA2A-003-v26.9.17"
      assert s.architecture_contract == "RFC-SA2A-001-v26.9.16"
      assert s.conformance_contract == "RFC-SA2A-002-v26.9.16"
      assert s.claimed_profile == "SA2A-STRICT"
    end

    test "claimed_profile is overridable", %{subject: _s} do
      s = ExactSubject.build!(claimed_profile: "SA2A-CORE")
      assert s.claimed_profile == "SA2A-CORE"
    end

    test "court_revision is this real repo's actual git HEAD", %{subject: s} do
      expected = Subject.capture(repo: File.cwd!()).source_revision

      assert s.court_revision == expected
      assert is_binary(s.court_revision)
      assert Regex.match?(~r/\A[0-9a-f]{40}\z/, s.court_revision)
    end

    test "root_manifest_sha256 is a real sha256 over the real lib/ash_a2a/chicago/*.ex sources",
         %{subject: s} do
      assert is_binary(s.root_manifest_sha256)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, s.root_manifest_sha256)

      # Recomputed independently (not from the module's own helper) against
      # the real files on disk, to catch the digest silently drifting from
      # what it claims to cover.
      independent =
        "lib/ash_a2a/chicago/*.ex"
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(&File.read!/1)
        |> Enum.join()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert s.root_manifest_sha256 == independent
    end

    test "falsifier_corpus_sha256 is a real, non-empty sha256 over every discoverable court's falsifiers",
         %{subject: s} do
      assert is_binary(s.falsifier_corpus_sha256)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, s.falsifier_corpus_sha256)
    end

    test "repositories/0 reports the real 11-repo topology, reusing Topology.check_repo/1", %{
      subject: s
    } do
      assert length(s.repositories) == length(Topology.repos())

      by_repo = Map.new(s.repositories, &{&1["repo"], &1})
      assert Map.has_key?(by_repo, "autofde-lab")
      assert by_repo["autofde-lab"]["capability"] == "cap-crown"
      assert by_repo["autofde-lab"]["critical"] == true

      # ash-a2a is itself one of the 11 declared objects and, being this real
      # repo, MUST resolve real? true on this machine.
      assert by_repo["ash-a2a"]["real"] == true
      assert is_binary(by_repo["ash-a2a"]["head"])
    end

    test "scope_disclosure travels with the built document verbatim", %{subject: s} do
      assert s.scope_disclosure == ExactSubject.scope_disclosure()
    end
  end

  describe "root_manifest_sha256/1 is deterministic and empty-safe" do
    test "returns the identical digest across two independent calls against the real repo" do
      a = ExactSubject.root_manifest_sha256(File.cwd!())
      b = ExactSubject.root_manifest_sha256(File.cwd!())
      assert a == b
    end

    test "returns nil for a real directory with no matching chicago/*.ex files" do
      empty_repo =
        System.tmp_dir!()
        |> Path.join("sa2a-exact-subject-empty-#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty_repo)

      on_exit(fn -> File.rm_rf!(empty_repo) end)

      assert ExactSubject.root_manifest_sha256(empty_repo) == nil
    end
  end

  describe "to_map/1, to_json/1, digest/1" do
    test "to_map/1 produces the §84 JSON-map shape with every field present" do
      map = ExactSubject.build!() |> ExactSubject.to_map()

      assert %{
               "schema" => "ash_a2a.chicago.release.exact_subject/1",
               "release" => "26.9.17",
               "release_contract" => "RFC-SA2A-003-v26.9.17",
               "architecture_contract" => "RFC-SA2A-001-v26.9.16",
               "conformance_contract" => "RFC-SA2A-002-v26.9.16",
               "claimed_profile" => "SA2A-STRICT",
               "repositories" => repositories,
               "root_manifest_sha256" => root_sha,
               "court_revision" => revision,
               "falsifier_corpus_sha256" => corpus_sha,
               "scope_disclosure" => disclosure
             } = map

      assert is_list(repositories)
      assert is_binary(root_sha)
      assert is_binary(revision)
      assert is_binary(corpus_sha)
      assert disclosure =~ "autofde-lab"
    end

    test "digest/1 is a real, deterministic sha256 over the canonical JSON form" do
      subject = ExactSubject.build!()

      d1 = ExactSubject.digest(subject)
      d2 = ExactSubject.digest(subject)

      assert d1 == d2
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, d1)

      independent =
        subject
        |> ExactSubject.to_json()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert d1 == independent
    end

    test "digest/1 changes when claimed_profile changes (content-addressed, not a placeholder)" do
      strict = ExactSubject.build!(claimed_profile: "SA2A-STRICT")
      core = ExactSubject.build!(claimed_profile: "SA2A-CORE")

      refute ExactSubject.digest(strict) == ExactSubject.digest(core)
    end
  end
end
