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

  @pack_commit "697870ec2"
  @crosswalk_sha256 "00763e2346076d7795acd2840569ace01311147c55a884909bc86abb40cf67b0"
  @ontology_sha256 "bd4993b6a947bf430627efd4604c843db573ab5142c86e379ddcba039e1d31e9"

  # Additional pinned pack artifacts (L162 A2A wire column landing).
  @extra_pins %{
    "gates/030_jsonrpc_law.rq" => "c6ad2529dbbfbcb2b667188d141d7328dee15009cc1dd5cb9e3e755f78092751",
    "gates/060_a2a_wire_totality.rq" => "0182aa796e0fc1646c5710f96a6b48c55ff3f0fdf61cd2e4257c2cff5872b699",
    "queries/crosswalk.rq" => "63277a3e6634e990a234e1abf87200a29cd5f7de0678cf464d5ed34f80fcc815",
    "templates/crosswalk.rs.tera" => "d8053907e4b7e68ff6627b4f35c17435883a537f6437eb13a86ca19201ea783c",
    "ggen.toml" => "7faf313186da970872919414e4d9129fdee6b1d738026a047f930f6ecfda5c29",
    "README.md" => "9f65382359aa2be027944cab61d7b30e5df78d56a1ea33139f5dc04184ee4ec1"
  }

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

  # Parse generated/crosswalk.rs A2A_WIRE_CROSSWALK (fourth column):
  # a2a_atom -> {ash_a2a_class, json_rpc_code}.
  defp parse_a2a_wire_crosswalk(text) do
    text
    |> String.split("A2A_WIRE_CROSSWALK: [A2aWireEntry;")
    |> Enum.drop(1)
    |> Enum.flat_map(fn chunk ->
      Regex.scan(
        ~r/a2a_atom: "([a-z_]+)",\s*ash_a2a_class: "([a-z_]+)",\s*json_rpc_code: (-?\d+)/s,
        chunk
      )
      |> Enum.map(fn [_, atom, class, code] ->
        {atom, {class, String.to_integer(code)}}
      end)
    end)
    |> Map.new()
  end

  # Parse generated/crosswalk.rs JSON_RPC_LAW_CODES into a code multiset.
  defp parse_json_rpc_law_codes(text) do
    text
    |> String.split("JSON_RPC_LAW_CODES: [i32;")
    |> Enum.drop(1)
    |> List.first("")
    |> then(fn chunk ->
      case Regex.run(~r/\A[^=]*=\s*\[([^\]]*)\]/s, chunk) do
        [_, body] ->
          body
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&String.to_integer/1)

        nil ->
          []
      end
    end)
  end

  defp a2a_wire_crosswalk_map do
    crosswalk_path = assert_provenance!("crosswalk.rs", @crosswalk_sha256)
    parse_a2a_wire_crosswalk(File.read!(crosswalk_path))
  end

  defp json_rpc_law_codes do
    crosswalk_path = assert_provenance!("crosswalk.rs", @crosswalk_sha256)
    parse_json_rpc_law_codes(File.read!(crosswalk_path))
  end

  defp native_mapping, do: AshA2A.Semantic.Refusal.mapping()

  describe "pack artifact provenance" do
    test "fixtures pin the pack artifacts at #{@pack_commit} byte-for-byte" do
      assert map_size(crosswalk_map()) == 51
      assert map_size(macro_map()) == 51

      # The six additional pack artifacts pinned at the same commit.
      for {rel_path, expected_sha} <- @extra_pins do
        assert_provenance!(rel_path, expected_sha)
      end
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

  # Fourth column: ash_a2a transport-native refusal atoms -> ash_a2a classes
  # via the designated -32000 wire code (L162 pack landing, ggen-marketplace
  # 697870ec2). Read from the pinned crosswalk.rs, never hardcoded.
  describe "a2a wire column (transport crosswalk)" do
    @wire_atoms ~w(server_busy rate_limited)

    test "A2A_WIRE_CROSSWALK has exactly 2 entries" do
      wire = a2a_wire_crosswalk_map()
      assert map_size(wire) == 2

      for atom <- @wire_atoms do
        assert Map.has_key?(wire, atom), "a2a atom #{atom} missing from A2A_WIRE_CROSSWALK"
      end
    end

    test "wire entries map the transport-native atoms to the pinned classes" do
      wire = a2a_wire_crosswalk_map()

      # Presence witnesses measured from the pinned artifact, pinned here so a
      # silent class or wire-code flip fails:
      assert wire["rate_limited"] == {"refused_bounds", -32000}
      assert wire["server_busy"] == {"blocked_resource", -32000}

      # Every wire entry carries the designated -32000 code.
      for {_atom, {_class, code}} <- wire do
        assert code == -32000
      end
    end

    test "wire classes exist in the native class vocabulary" do
      native_classes = MapSet.new(AshA2A.Semantic.Refusal.classes(), &Atom.to_string/1)

      bad =
        a2a_wire_crosswalk_map()
        |> Map.values()
        |> Enum.map(fn {class, _code} -> class end)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(native_classes, &1))

      assert bad == [], "wire crosswalk targets classes unknown to refusal.ex: #{inspect(bad)}"
    end

    test "JSON_RPC_LAW_CODES has exactly 15 entries, -32000 exactly once, -31999 absent" do
      codes = json_rpc_law_codes()

      assert length(codes) == 15
      assert Enum.count(codes, &(&1 == -32000)) == 1
      refute -31999 in codes

      # duplicates nowhere else in the law set
      assert Enum.uniq(codes) |> length() == 15
    end
  end
end
