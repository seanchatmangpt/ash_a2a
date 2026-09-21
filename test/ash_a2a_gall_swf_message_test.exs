defmodule AshA2A.GallSwfMessageTest do
  @moduledoc """
  PRD §43.5 GALL Semantic Work Fabric message shapes: checkpoint identity,
  PRD §41 work lease, closed capability vocabulary with the PRD §30
  child-subset rule, evidence/receipt transport with the closed standing
  vocabulary, and the central transport-is-not-authority refusals.

  Real structs, real JSON round-trips through Jason, real refusal tuples.
  No doubles -- there is nothing external here to double.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Gall.{Capability, Checkpoint, EvidenceReceipt, Message, WorkLease}

  # The PRD §41 canonical work-lease JSON shape, verbatim. MUST validate.
  @lease_json ~s({"type": "gall:WorkLease", "checkpoint": "urn:gall:checkpoint:xaas:001", "epoch": "urn:xaas:epoch:001", "lease": "urn:xaas:lease:001", "graphDigest": "sha256:..."})

  @base_sha "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"

  defp checkpoint_message do
    %{
      "type" => "gall:CodingCheckpoint",
      "checkpoint" => "urn:gall:checkpoint:xaas:001",
      "repository" => "https://example.org/repo",
      "baseSha" => @base_sha,
      "graphDigest" => "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    }
  end

  defp receipt_message(standing \\ "ALIVE") do
    %{
      "type" => "gall:EvidenceReceipt",
      "receiptId" => "urn:xaas:receipt:001",
      "checkpointIri" => "urn:gall:checkpoint:xaas:001",
      "checkpointDigest" =>
        "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
      "candidateSha" => @base_sha,
      "verifierId" => "urn:xaas:verifier:mix-test",
      "verifiedOutcome" => "pass",
      "standing" => standing
    }
  end

  defp lease_message(capabilities \\ nil) do
    base = %{
      "type" => "gall:WorkLease",
      "checkpoint" => "urn:gall:checkpoint:xaas:001",
      "epoch" => "urn:xaas:epoch:001",
      "lease" => "urn:xaas:lease:001",
      "graphDigest" => "sha256:..."
    }

    if capabilities, do: Map.put(base, "capabilities", capabilities), else: base
  end

  # --- requirement 1: checkpoint identity message -------------------------

  test "a well-formed gall:CodingCheckpoint message validates to its typed struct" do
    assert {:ok, %Checkpoint{} = checkpoint} = Message.validate(checkpoint_message())
    assert checkpoint.type == "gall:CodingCheckpoint"
    assert checkpoint.checkpoint == "urn:gall:checkpoint:xaas:001"
    assert checkpoint.repository == "https://example.org/repo"
    assert checkpoint.base_sha == @base_sha
    assert String.starts_with?(checkpoint.graph_digest, "sha256:")
  end

  test "checkpoint base_sha must be 40 hex; graph_digest must be sha256-typed" do
    assert {:refused, "REFUSED_STRUCTURE"} =
             Message.validate(%{checkpoint_message() | "baseSha" => "nothex"})

    assert {:refused, "REFUSED_STRUCTURE"} =
             Message.validate(%{checkpoint_message() | "baseSha" => String.duplicate("a", 41)})

    assert {:refused, "REFUSED_STRUCTURE"} =
             Message.validate(%{checkpoint_message() | "graphDigest" => "md5:abc"})
  end

  # --- requirement 2: the PRD §41 canonical work-lease shape --------------

  test "the exact PRD §41 WorkLease JSON shape parses into the WorkLease struct" do
    assert {:ok, %WorkLease{} = lease} = Message.validate(@lease_json)
    assert lease.type == "gall:WorkLease"
    assert lease.checkpoint == "urn:gall:checkpoint:xaas:001"
    assert lease.epoch == "urn:xaas:epoch:001"
    assert lease.lease == "urn:xaas:lease:001"
    assert lease.graph_digest == "sha256:..."
    assert lease.capabilities == %{requires: [], forbids: []}
  end

  test "a work lease validates with decoded capability sets" do
    assert {:ok, %WorkLease{} = lease} =
             Message.validate(
               lease_message(%{"requires" => ["Read", "Commit"], "forbids" => ["Push"]})
             )

    assert lease.capabilities == %{requires: [:commit, :read], forbids: [:push]}
  end

  # --- requirement 3: capability semantics --------------------------------

  test "the capability vocabulary is exactly the eight closed values" do
    assert Capability.labels() == [
             "Read",
             "Write",
             "Edit",
             "Commit",
             "Push",
             "Publish",
             "Deploy",
             "Merge"
           ]

    assert Enum.map(Capability.all(), &Capability.encode/1) |> Enum.all?(&match?({:ok, _}, &1))
  end

  test "an unknown capability name is REFUSED_CAPABILITY" do
    assert {:refused, "REFUSED_CAPABILITY"} =
             Message.validate(
               lease_message(%{"requires" => ["Read", "Transmute"], "forbids" => []})
             )

    assert {:refused, "REFUSED_CAPABILITY"} =
             Message.validate(lease_message(%{"requires" => [], "forbids" => ["Nuke"]}))

    # Downcased aliasing is not decoding: the vocabulary is closed.
    assert {:refused, "REFUSED_CAPABILITY"} =
             Message.validate(lease_message(%{"requires" => ["push"], "forbids" => []}))
  end

  test "child capabilities not a subset of the parent grant are refused (PRD §30)" do
    {:ok, child} = Message.validate(lease_message(%{"requires" => ["Read", "Edit"]}))

    assert {:ok, ^child} = Message.validate(child, parent: ["Read", "Edit", "Commit"])
    assert {:ok, ^child} = Message.validate(child, parent: ["Read", "Edit"])
    assert {:refused, "REFUSED_CAPABILITY"} = Message.validate(child, parent: ["Read"])
    assert {:refused, "REFUSED_CAPABILITY"} = Message.validate(child, parent: [])
    assert {:refused, "REFUSED_CAPABILITY"} = Message.validate(child, parent: ["Push"])

    # A parent grant carrying an unknown capability refuses too -- fail closed.
    assert {:refused, "REFUSED_CAPABILITY"} =
             Message.validate(child, parent: ["Read", "Teleport"])
  end

  test "a child requiring a capability the parent forbids is refused" do
    {:ok, child} = Message.validate(lease_message(%{"requires" => ["Push"]}))

    {:ok, %WorkLease{} = parent} =
      Message.validate(lease_message(%{"requires" => ["Read", "Push"], "forbids" => ["Push"]}))

    assert {:refused, "REFUSED_CAPABILITY"} = Message.validate(child, parent: parent)
  end

  test "the parent grant may be a WorkLease struct, a map, or a plain list" do
    {:ok, child} = Message.validate(lease_message(%{"requires" => ["Commit"]}))
    {:ok, parent_lease} = Message.validate(lease_message(%{"requires" => ["Commit", "Push"]}))

    assert {:ok, _} = Message.validate(child, parent: parent_lease)
    assert {:ok, _} = Message.validate(child, parent: %{"requires" => ["Commit"]})
    assert {:ok, _} = Message.validate(child, parent: [:commit])
    assert {:refused, "REFUSED_CAPABILITY"} = Message.validate(child, parent: %{"requires" => []})
  end

  test "the child-subset rule is only enforced when a parent grant is presented" do
    # No parent presented -> nothing to compare against; shape still validates.
    assert {:ok, %WorkLease{}} =
             Message.validate(lease_message(%{"requires" => ["Push", "Deploy"]}))
  end

  # --- requirement 4: evidence/receipt transport + standing vocabulary ----

  test "a well-formed gall:EvidenceReceipt message validates" do
    assert {:ok, %EvidenceReceipt{} = receipt} = Message.validate(receipt_message())
    assert receipt.type == "gall:EvidenceReceipt"
    assert receipt.receipt_id == "urn:xaas:receipt:001"
    assert receipt.candidate_sha == @base_sha
    assert receipt.standing == "ALIVE"
  end

  test "the standing vocabulary is exactly the six values, each accepted" do
    assert EvidenceReceipt.standing_values() == [
             "UNKNOWN",
             "PARTIAL_ALIVE",
             "ALIVE",
             "BLOCKED",
             "BUILD_BROKEN",
             "UNSUPPORTED"
           ]

    for standing <- EvidenceReceipt.standing_values() do
      assert {:ok, %EvidenceReceipt{standing: ^standing}} =
               Message.validate(receipt_message(standing))
    end
  end

  test "standing round-trips through the receipt message" do
    for standing <- EvidenceReceipt.standing_values() do
      {:ok, receipt} = Message.validate(receipt_message(standing))
      wire = EvidenceReceipt.to_map(receipt)
      assert wire["standing"] == standing
      assert {:ok, %EvidenceReceipt{standing: ^standing}} = EvidenceReceipt.from_json(wire)
    end
  end

  test "an unknown standing value is refused, never coined" do
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(receipt_message("alive"))
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(receipt_message("ALIVE-ish"))
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(receipt_message("WIZARD"))
  end

  # --- requirement 5: transport is not authority --------------------------

  test "an unregistered type is REFUSED_UNREGISTERED_ACTUATION" do
    assert {:refused, "REFUSED_UNREGISTERED_ACTUATION"} =
             Message.validate(Map.put(lease_message(), "type", "gall:ActuateEverything"))

    assert {:refused, "REFUSED_UNREGISTERED_ACTUATION"} =
             Message.validate(%{"type" => "urn:xaas:do:now"})

    assert {:refused, "REFUSED_UNREGISTERED_ACTUATION"} = Message.validate(%{"no" => "type"})
    refute Message.registered_type?("gall:ActuateEverything")
  end

  test "an execute/actuate/authorize directive field is REFUSED_AUTHORITY" do
    for directive <- ["execute", "actuate", "authorize"] do
      assert {:refused, "REFUSED_AUTHORITY"} =
               Message.validate(Map.put(lease_message(), directive, true))
    end

    # Casing/separators do not launder the directive, and the value is
    # irrelevant: asserting the field at all is the overreach.
    assert {:refused, "REFUSED_AUTHORITY"} =
             Message.validate(Map.put(lease_message(), "EXECUTE", false))

    # A directive one level down is still an authority-bearing payload.
    assert {:refused, "REFUSED_AUTHORITY"} =
             Message.validate(%{
               "type" => "gall:WorkLease",
               "checkpoint" => "urn:gall:checkpoint:xaas:001",
               "epoch" => "urn:xaas:epoch:001",
               "lease" => "urn:xaas:lease:001",
               "graphDigest" => "sha256:...",
               "details" => %{"authorization" => %{"actuate" => "now"}}
             })

    # Receipts and checkpoints are equally bound.
    assert {:refused, "REFUSED_AUTHORITY"} =
             Message.validate(Map.put(receipt_message(), "execute", true))

    assert {:refused, "REFUSED_AUTHORITY"} =
             Message.validate(Map.put(checkpoint_message(), "authorize", "yes"))
  end

  test "messages that merely describe work validate -- description is not directive" do
    # "authorized"/"execution" are not directive fields; the vocabulary is
    # exact, so a receipt ABOUT an execution still transports.
    assert {:ok, %EvidenceReceipt{}} =
             Message.validate(%{receipt_message() | "verifierId" => "execution-runner"})

    assert match?({:ok, %WorkLease{}}, Message.validate(@lease_json))
  end

  # --- malformed shapes ----------------------------------------------------

  test "malformed payloads refuse REFUSED_STRUCTURE" do
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate("not json {")
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(~s(["a","json","array"]))
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(42)
    assert {:refused, "REFUSED_STRUCTURE"} = Message.validate(%{"type" => "gall:WorkLease"})

    assert {:refused, "REFUSED_STRUCTURE"} =
             Message.validate(%{checkpoint_message() | "checkpoint" => "not-an-iri"})
  end

  # --- requirement 6: Jason encode/decode round-trips ----------------------

  test "all three message shapes JSON round-trip through Jason" do
    {:ok, checkpoint} = Message.validate(checkpoint_message())
    {:ok, lease} = Message.validate(lease_message(%{"requires" => ["Read", "Push"]}))
    {:ok, receipt} = Message.validate(receipt_message("PARTIAL_ALIVE"))

    for {message, module} <- [
          {checkpoint, Checkpoint},
          {lease, WorkLease},
          {receipt, EvidenceReceipt}
        ] do
      json = module.to_json(message)
      assert is_binary(json)
      assert {:ok, decoded} = module.from_json(json)
      assert decoded == message
    end
  end

  test "the PRD §41 JSON string round-trips: parse -> encode -> parse is stable" do
    {:ok, lease} = Message.validate(@lease_json)
    json = WorkLease.to_json(lease)
    assert {:ok, same} = Message.validate(json)
    assert same == lease
    assert Jason.decode!(json)["graphDigest"] == "sha256:..."
  end

  # --- namespace -----------------------------------------------------------

  test "the GALL namespace is the PRD namespace" do
    assert Message.namespace() == "https://semantic-a2a.dev/gall#"

    assert Message.types() == [
             "gall:CodingCheckpoint",
             "gall:WorkLease",
             "gall:EvidenceReceipt"
           ]
  end
end
