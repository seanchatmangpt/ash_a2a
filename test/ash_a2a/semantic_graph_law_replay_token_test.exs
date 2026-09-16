defmodule AshA2A.SemanticGraphLawReplayTokenTest do
  @moduledoc """
  Regression cover for the unreachable replay-divergence branch in
  `AshA2A.Semantic.GraphLaw.verdict/1`.

  The defect, as reproduced before the fix: the branch tested
  `replay_status == "REFUSED"`, a token the engine never emits for replay,
  so a real divergence was admitted.

      verdict(%{"replay" => %{"status" => "REPLAY_MISMATCH"}, ...})
        -> {:admitted, "deadbeef"}
      verdict(%{"replay" => %{"status" => "HASH_MISMATCH"}, ...})
        -> {:admitted, "deadbeef"}

  The engine's real vocabulary is read out of the real vendored wasm
  artifact, not out of documentation -- see
  `reads the status vocabulary out of the real vendored wasm` below.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.GraphLaw

  defp report(replay_status) do
    %{
      "graph_hash" => "deadbeef",
      "dialects" => [],
      "replay" => %{
        "status" => replay_status,
        "first_hash" => "aa",
        "second_hash" => "bb"
      }
    }
  end

  describe "the verifier's minimal reproducing input" do
    test "REPLAY_MISMATCH is refused, not admitted" do
      assert {:refused, :semantic_replay_divergence, detail} =
               GraphLaw.verdict(report("REPLAY_MISMATCH"))

      assert detail =~ "REPLAY_MISMATCH"
    end

    test "HASH_MISMATCH is refused, not admitted" do
      assert {:refused, :semantic_replay_divergence, _detail} =
               GraphLaw.verdict(report("HASH_MISMATCH"))
    end
  end

  describe "fail-closed over the whole token space" do
    test "an agreement token still admits" do
      assert {:admitted, "deadbeef"} = GraphLaw.verdict(report("ADMITTED"))
    end

    test "a not-exercised replay slot still admits" do
      assert {:admitted, "deadbeef"} = GraphLaw.verdict(report("UNSUPPORTED"))
      assert {:admitted, "deadbeef"} = GraphLaw.verdict(report("PROFILE_NOT_ADMITTED"))
    end

    test "an absent replay section is not a divergence" do
      assert {:admitted, "deadbeef"} =
               GraphLaw.verdict(%{"graph_hash" => "deadbeef", "dialects" => []})
    end

    test "REFUSED still refuses, so nothing the old branch caught is lost" do
      assert {:refused, :semantic_replay_divergence, _} = GraphLaw.verdict(report("REFUSED"))
    end

    test "a token this module has never seen refuses rather than admits" do
      assert {:refused, :semantic_replay_divergence, _} =
               GraphLaw.verdict(report("SOME_FUTURE_ENGINE_TOKEN"))

      assert {:refused, :semantic_replay_divergence, _} = GraphLaw.verdict(report(42))
    end
  end

  describe "the accepted token set matches the real engine artifact" do
    @wasm_candidates [
      "priv/graphlaw/praxis_graphlaw.wasm",
      "priv/graphlaw/praxis_graphlaw_wasm_bg.wasm"
    ]

    test "reads the status vocabulary out of the real vendored wasm" do
      case Enum.find(@wasm_candidates, &File.exists?(Path.join(File.cwd!(), &1))) do
        nil ->
          # The artifact is not vendored into this working tree. Report that
          # rather than silently passing on a substitute: there is no mock
          # engine standing in for it.
          IO.puts(
            "\n  [skipped] no vendored praxis_graphlaw wasm in this tree; " <>
              "the engine-vocabulary assertion needs the real artifact"
          )

        relative ->
          bytes = File.read!(Path.join(File.cwd!(), relative))

          # The engine's status enum is one contiguous run in the wasm data
          # segment, in declaration order.
          assert bytes =~
                   "ADMITTEDREFUSEDUNSUPPORTEDREPLAY_MISMATCHHASH_MISMATCHPROFILE_NOT_ADMITTED"

          # Every token this module treats as agreement is really a token the
          # engine can emit ...
          for token <- GraphLaw.replay_agreement_tokens() do
            assert bytes =~ token
          end

          # ... and the divergence tokens the engine really emits are NOT in
          # the agreement set. This is the assertion that would have failed
          # before the fix, when "REFUSED" was the only token checked.
          for token <- ["REPLAY_MISMATCH", "HASH_MISMATCH", "REFUSED"] do
            refute token in GraphLaw.replay_agreement_tokens()
          end
      end
    end
  end

  describe "S51: received is not admitted -- preserved" do
    test "a dialect the engine refused still refuses regardless of replay" do
      report = %{
        "graph_hash" => "deadbeef",
        "dialects" => [%{"dialect" => "SHACL", "status" => "REFUSED", "detail" => "minCount"}],
        "replay" => %{"status" => "ADMITTED"}
      }

      assert {:refused, :semantic_shape_violation, detail} = GraphLaw.verdict(report)
      assert detail =~ "SHACL"
    end

    test "an unhashable graph is refused, never admitted on a sender's word" do
      assert {:refused, :semantic_graph_unhashable, _} =
               GraphLaw.verdict(%{"dialects" => [], "replay" => %{"status" => "ADMITTED"}})
    end
  end
end
