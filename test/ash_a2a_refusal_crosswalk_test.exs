defmodule AshA2A.RefusalCrosswalkTest do
  @moduledoc """
  Cross-repo agreement court: the ggen-marketplace `refusal-vocabulary-pack`
  crosswalk (pack commit 50a458f60, ggen-marketplace repo) against
  `AshA2A.Semantic.Refusal`'s native code -> class mapping.

  The pack artifacts are PINNED COPIES under `test/fixtures/refusal_vocabulary_pack/`
  with sha256 provenance asserted below. A pack edit that changes the crosswalk
  must re-pin and re-verify here -- a silent pack drift fails this suite.

  Join law: an erlmcp code "overlaps" the native mapping when its .hrl macro
  name (`rv:macro` in the pack ontology), lowercased and with the `refusal_`
  prefix stripped, is a key of `AshA2A.Semantic.Refusal.mapping/0`.

  Known deviations are a PINNED ledger: the test asserts the deviation set is
  exactly the documented set, so a future pack change that introduces or fixes
  a disagreement must update this file rather than pass silently.
  """

  use ExUnit.Case, async: true

  @pack_commit "50a458f60"
  @crosswalk_sha256 "994938e50b92830e9ca0c81eb6dfeaa00c64a6d4befc602fcf2fc2c47510b170"
  @ontology_sha256 "4c22ae1914cc0987aa9ed73093bd902030492c381042f21dc04e720a599249b4"

  @fixture_dir Path.join([__DIR__, "fixtures", "refusal_vocabulary_pack"])

  # ---------------------------------------------------------------------------
  # Pinned deviation ledger. Join key => {native_class, crosswalk_class, note}.
  # Empty except the one measured disagreement (see "timeout" below).
  # ---------------------------------------------------------------------------
  @expected_deviations %{
    # erlmcp REFUSAL_TIMEOUT (1069) is placed in refused_bounds by the pack;
    # ash_a2a's native :timeout classifies as :blocked_resource. The pack
    # reads an erlmcp timeout as a declared-bound breach; ash_a2a reads a
    # timeout as a local resource/dependency failing to answer in time.
    # Both readings are internally coherent, but they DISAGREE on the same
    # concept name -- recorded here as a real crosswalk deviation, not
    # papered over. Requires pack-side adjudication note (ontology.ttl has
    # FORCED-placement notes for 1012/1023/1040/1077 but none for 1069).
    "timeout" => {:blocked_resource, "refused_bounds"}
  }

  defp assert_provenance!(name, expected_sha) do
    path = Path.join(@fixture_dir, name)
    assert File.exists?(path), "missing pinned fixture #{path}"

    actual =
      path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert actual == expected_sha,
           "pinned fixture #{name} sha256 drift: got #{actual}, want #{expected_sha}"

    path
  end

  # Parse generated/crosswalk.rs VALVE_CROSSWALK (third column):
  # valve_name -> ash_a2a class string.
  defp parse_valve_crosswalk(text) do
    text
    |> String.split("VALVE_CROSSWALK: [ValveEntry;")
    |> Enum.drop(1)
    |> Enum.flat_map(fn chunk ->
      Regex.scan(
        ~r/valve_name: "([a-z_]+)",.*?ash_a2a_class: "([a-z_]+)",/s,
        chunk
      )
      |> Enum.map(fn [_, name, class] -> {name, class} end)
    end)
    |> Map.new()
  end

  # Parse generated/crosswalk.rs: erlmcp integer code -> ash_a2a class string.
  defp parse_crosswalk(text) do
    text
    |> String.split("erlmcp_code:")
    |> Enum.drop(1)
    |> Enum.flat_map(fn chunk ->
      case Regex.run(~r/\A\s*(\d+),.*ash_a2a_class: "([a-z_]+)"/s, chunk) do
        [_, code, class] -> [{String.to_integer(code), class}]
        nil -> []
      end
    end)
    |> Map.new()
  end

  # Parse ontology.ttl: erlmcp integer code -> macro name (REFUSAL_*).
  defp parse_macros(text) do
    text
    |> String.split("rv:erlmcpCode")
    |> Enum.drop(1)
    |> Enum.flat_map(fn chunk ->
      case Regex.run(~r/\A\s*(\d+)\s*;.*rv:macro "([A-Z_]+)"/s, chunk) do
        [_, code, macro] -> [{String.to_integer(code), macro}]
        nil -> []
      end
    end)
    |> Map.new()
  end

  defp crosswalk_map do
    crosswalk_path = assert_provenance!("crosswalk.rs", @crosswalk_sha256)
    parse_crosswalk(File.read!(crosswalk_path))
  end

  defp valve_crosswalk_map do
    crosswalk_path = assert_provenance!("crosswalk.rs", @crosswalk_sha256)
    parse_valve_crosswalk(File.read!(crosswalk_path))
  end

  defp macro_map do
    ontology_path = assert_provenance!("ontology.ttl", @ontology_sha256)
    parse_macros(File.read!(ontology_path))
  end

  # Join key: lowercase macro minus the `refusal_` prefix.
  defp join_key(macro) do
    macro
    |> String.downcase()
    |> String.trim_leading("refusal_")
  end

  defp native_mapping, do: AshA2A.Semantic.Refusal.mapping()

  describe "pack artifact provenance" do
    test "fixtures pin the pack artifacts at #{@pack_commit} byte-for-byte" do
      assert map_size(crosswalk_map()) == 51
      assert map_size(macro_map()) == 51
    end
  end

  describe "native <-> crosswalk agreement (overlapping codes)" do
    test "every overlapping code agrees except the pinned deviation ledger" do
      cw = crosswalk_map()
      macros = macro_map()
      native = native_mapping()

      overlaps =
        for {code, macro} <- macros,
            key = join_key(macro),
            Map.has_key?(native, String.to_atom(key)),
            do: {code, String.to_atom(key), macro}

      assert length(overlaps) >= 1, "expected at least one overlapping code"

      {agreements, disagreements} =
        Enum.split_with(overlaps, fn {code, atom, _macro} ->
          native[atom] == String.to_atom(cw[code])
        end)

      # Any disagreement must be a documented, pinned deviation -- exactly.
      undocumented =
        for {code, atom, macro} = entry <- disagreements,
            Map.get(@expected_deviations, join_key(macro)) != {native[atom], cw[code]} do
          entry
        end

      assert undocumented == [],
             "unpinned crosswalk/native disagreements: #{inspect(undocumented)}"

      # The pinned ledger must be exactly satisfied (no stale entries either).
      deviation_keys = MapSet.new(disagreements, fn {_c, _a, m} -> join_key(m) end)
      assert MapSet.equal?(MapSet.new(Map.keys(@expected_deviations)), deviation_keys),
             "deviation ledger mismatch: measured #{inspect(MapSet.to_list(deviation_keys))}, " <>
               "pinned #{inspect(Map.keys(@expected_deviations))}"

      assert length(agreements) == length(overlaps) - length(disagreements)
    end

    test "measured overlap summary is stable" do
      cw = crosswalk_map()
      macros = macro_map()
      native = native_mapping()

      overlap_count =
        Enum.count(macros, fn {code, macro} ->
          Map.has_key?(native, String.to_atom(join_key(macro))) and Map.has_key?(cw, code)
        end)

      # Measured 2026-10-13 on pack 50a458f60 / refusal.ex: 2 overlaps —
      # `timeout` (pinned deviation) and `internal_error` (agreement:
      # native blocked_unknown == pack blocked_unknown for code 1079).
      assert overlap_count == 2
    end

    test "the timeout deviation is real: native blocked_resource vs pack refused_bounds" do
      assert AshA2A.Semantic.Refusal.classify(:timeout) == :blocked_resource
      assert crosswalk_map()[1069] == "refused_bounds"
    end
  end

  describe "forced placements vs native mapping" do
    test "no FORCED placement collides with a native @mapping entry" do
      macros = macro_map()
      native = native_mapping()

      # Pack FORCED placements (ontology.ttl, pack 50a458f60): 1012, 1023, 1040, 1077.
      forced_codes = [1012, 1023, 1040, 1077]

      collisions =
        for code <- forced_codes,
            macro = macros[code],
            atom = String.to_atom(join_key(macro)),
            Map.has_key?(native, atom) do
          {code, macro, native[atom]}
        end

      assert collisions == [],
             "FORCED placements colliding with native mapping: #{inspect(collisions)}"
    end

    test "pack flags exactly the 4 FORCED placements this suite knows about" do
      ontology = File.read!(Path.join(@fixture_dir, "ontology.ttl"))
      assert Enum.count(Regex.scan(~r/FORCED placement/, ontology)) == 4
    end
  end

  describe "totality from the Elixir side" do
    test "every native mapping entry's class is one of the 18 S42 classes" do
      classes = MapSet.new(AshA2A.Semantic.Refusal.classes())
      refused = MapSet.new(AshA2A.Semantic.Refusal.refused_classes())
      blocked = MapSet.new(AshA2A.Semantic.Refusal.blocked_classes())
      unsupported = MapSet.new(AshA2A.Semantic.Refusal.unsupported_classes())

      # class vocabulary partitions cleanly
      assert MapSet.size(refused) == 15
      assert MapSet.size(blocked) == 2
      assert MapSet.size(unsupported) == 1
      assert MapSet.equal?(classes, MapSet.union(refused, blocked |> MapSet.union(unsupported)))

      bad =
        native_mapping()
        |> Enum.reject(fn {_code, class} -> MapSet.member?(classes, class) end)

      assert bad == [], "native codes mapped to non-taxonomy classes: #{inspect(bad)}"
    end

    test "every crosswalk class exists in the native class vocabulary" do
      native_classes = MapSet.new(AshA2A.Semantic.Refusal.classes(), &Atom.to_string/1)

      bad =
        crosswalk_map()
        |> Map.values()
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(native_classes, &1))

      assert bad == [], "crosswalk targets classes unknown to refusal.ex: #{inspect(bad)}"
    end
  end

  # Third column: strata-valve refusal classes -> ash_a2a classes (L104 pack
  # landing, ggen-marketplace 1d16f2472 lineage). Asserted by reading the
  # pinned crosswalk.rs — mapping values are asserted as presence, never
  # hardcoded a second time here.
  describe "valve third column (strata-valve crosswalk)" do
    @valve_names ~w(malformed_frame fuel_exhausted parent_discontinuity
                    arena_failure window_run_capacity window_tau_capacity)

    test "VALVE_CROSSWALK has exactly 6 entries" do
      assert map_size(valve_crosswalk_map()) == 6
    end

    test "every declared valve class maps exactly once" do
      text = File.read!(Path.join(@fixture_dir, "crosswalk.rs"))

      for name <- @valve_names do
        occurrences =
          Enum.count(Regex.scan(~r/valve_name: "#{name}",/, text), fn _ -> true end)

        assert occurrences == 1,
               "valve #{name} appears #{occurrences} times in VALVE_CROSSWALK, want exactly 1"

        assert Map.has_key?(valve_crosswalk_map(), name),
               "valve #{name} missing from parsed VALVE_CROSSWALK"
      end
    end

    test "the 6 valve mappings match the pack's table (presence, not duplication)" do
      valve_map = valve_crosswalk_map()

      for name <- @valve_names do
        assert Map.has_key?(valve_map, name), "valve #{name} not parsed from pinned crosswalk.rs"
      end

      # The mapping values are the pack's, read from the pinned artifact:
      # assert the parsed table equals a projection of the pinned file itself.
      assert valve_map == parse_valve_crosswalk(File.read!(Path.join(@fixture_dir, "crosswalk.rs")))

      # Class placement witnesses (measured from the pinned file, then pinned
      # here so a silent class flip fails):
      assert valve_map["malformed_frame"] == "refused_structure"
      assert valve_map["fuel_exhausted"] == "refused_bounds"
      assert valve_map["parent_discontinuity"] == "refused_receipt"
      assert valve_map["arena_failure"] == "refused_consequence"
      assert valve_map["window_run_capacity"] == "refused_bounds"
      assert valve_map["window_tau_capacity"] == "refused_bounds"
    end
  end
end
