defmodule AshA2A.V1SpecCorpusTest do
  @moduledoc """
  Lane X6: frozen spec-example wire corpus conformance.

  Every example in `priv/a2a_v1_spec_corpus/v1_spec_examples.json` was
  extracted programmatically (byte-faithful) from the official A2A v1.0
  specification. This test proves the REAL codec decode paths
  (`AshA2A.Protocol.JSON.decode/2`, `decode_agent_card/1`,
  `AshA2A.Protocol.JSONRPC.Request.parse/1`) accept every spec-real member
  into its corresponding struct, and that accepted members survive
  decode -> encode -> decode with struct equality.

  Members the codec demonstrably does not accept are pinned as `codec_gap`
  regression specs (exact decode error asserted); findings live in the
  corpus header. Zero mocks — the corpus is real wire data and the codec is
  the real implementation.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.JSONRPC

  @corpus_path "priv/a2a_v1_spec_corpus/v1_spec_examples.json"
  @corpus @corpus_path |> File.read!() |> Jason.decode!()
  @examples @corpus["examples"]

  @required_families [
    "agent_card",
    "message",
    "task",
    "status",
    "artifact",
    "part",
    "event",
    "jsonrpc_request",
    "jsonrpc_error"
  ]

  # ------------------------------------------------------------------
  # Corpus integrity
  # ------------------------------------------------------------------

  describe "corpus integrity" do
    test "corpus file exists, parses, and carries the spec provenance header" do
      assert File.exists?(@corpus_path)
      assert @corpus["corpus"] == "a2a_v1_spec_corpus"
      assert @corpus["spec_source"]["url"] == "https://a2a-protocol.org/latest/specification/"
      assert is_list(@corpus["findings_summary"]) and @corpus["findings_summary"] != []
    end

    test "covers every required spec member family" do
      families = MapSet.new(@examples, & &1["family"])
      for family <- @required_families do
        assert family in families, "corpus is missing family #{family}"
      end
    end

    test "every example has a unique id and the required keys" do
      ids = Enum.map(@examples, & &1["id"])
      assert length(ids) == length(Enum.uniq(ids))
      assert length(ids) >= 30

      for entry <- @examples do
        for key <- ["id", "family", "source", "expect", "decode", "deviations", "wire"] do
          assert Map.has_key?(entry, key), "#{entry["id"]} missing key #{key}"
        end

        assert entry["expect"] in ["decode", "codec_gap"]

        if entry["expect"] == "codec_gap" do
          assert is_binary(entry["finding"]) and entry["finding"] != "",
                 "#{entry["id"]} gap entry must document its finding"
        end
      end
    end
  end

  # ------------------------------------------------------------------
  # Per-example conformance (generated from the frozen corpus)
  # ------------------------------------------------------------------

  for entry <- @examples do
    @tag entry: entry
    test "spec example #{entry["id"]} (#{entry["family"]})", %{entry: entry} do
      case entry["expect"] do
        "decode" -> assert_decodes_and_round_trips(entry)
        "codec_gap" -> assert_pinned_gap(entry)
      end
    end
  end

  @decode_type_atoms %{
    "task" => :task,
    "status" => :status,
    "message" => :message,
    "artifact" => :artifact,
    "part" => :part,
    "event" => :event
  }

  @error_kind_atoms %{"missing_field" => :missing_field}

  defp assert_decodes_and_round_trips(entry) do
    wire = entry["wire"]

    case entry["decode"] do
      "agent_card" ->
        {:ok, card} = JSON.decode_agent_card(wire)
        assert %AshA2A.Protocol.AgentCard{} = card

        reencoded = JSON.encode_agent_card(card, url: card.url)
        assert {:ok, ^card} = JSON.decode_agent_card(reencoded)

      "jsonrpc_request" ->
        {:ok, request} = JSONRPC.Request.parse(wire)
        assert %JSONRPC.Request{} = request
        assert request.jsonrpc == "2.0"
        # Envelopes have no codec-side encoder; decode stability (idempotence)
        # is the round-trip analogue for this family.
        assert {:ok, ^request} = JSONRPC.Request.parse(wire)

      type_name ->
        type = Map.fetch!(@decode_type_atoms, type_name)
        {:ok, struct} = JSON.decode(wire, type)
        assert is_atom(struct.__struct__)

        {:ok, encoded} = JSON.encode(struct)
        assert {:ok, ^struct} = JSON.decode(encoded, type)
    end
  end

  defp assert_pinned_gap(entry) do
    wire = entry["wire"]

    case entry["decode"] do
      "jsonrpc_error" ->
        # F2: no decode path into %JSONRPC.Error{} (Error is encode-only).
        # Pinned probes of the real paths:
        assert {:error, %JSONRPC.Error{code: -32_600}} = JSONRPC.Request.parse(wire)
        assert {:error, _} = JSON.decode(wire, :event)

      "agent_card" ->
        # F5: codec requires AgentCard.version (proto REQUIRED); the spec's
        # own L1008 example omits it.
        [kind, value] = entry["expected_error"]
        pinned = {Map.fetch!(@error_kind_atoms, kind), value}
        assert JSON.decode_agent_card(wire) == {:error, pinned}

      type_name ->
        type = Map.fetch!(@decode_type_atoms, type_name)
        [kind, value] = entry["expected_error"]
        pinned = {Map.fetch!(@error_kind_atoms, kind), value}
        assert JSON.decode(wire, type) == {:error, pinned}
    end
  end
end
