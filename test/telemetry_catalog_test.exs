# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TelemetryCatalogTest do
  @moduledoc """
  Keeps `AshA2A.Telemetry.Events.all/0` in step with `lib/`.

  Textual scan, not a proof of emission:

    * every event-name list `[:ash_a2a | :a2a, ...]` found in `lib/**/*.ex`
      (docs and comments stripped, the conformance-court harness under
      `lib/ash_a2a/chicago/` and the catalog itself excluded) must equal, or be
      a prefix of, a catalogued event, unless it is a declared unemitted prefix;
    * every catalogued event must equal, or have as a prefix, a name list found
      in `lib/`.

  Prefix matching is how spans (`:start/:stop/:exception`) and dynamic-suffix
  emitters are covered, so for those the check is only as strong as the prefix.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Telemetry.Events

  @catalog_file "lib/ash_a2a/telemetry/events.ex"
  @harness_dir "lib/ash_a2a/chicago/"

  # `[:ash_a2a | :a2a, :atom, ...]` followed by `]`, by `| suffix`, or by a
  # trailing variable (`, event]`).
  @event_list ~r/\[\s*:(ash_a2a|a2a)((?:\s*,\s*:[a-z_0-9]+)*)\s*(?:\]|\||,\s*[a-z_@][A-Za-z_0-9.]*\s*\])/

  defp scanned_files do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&(&1 == @catalog_file or String.starts_with?(&1, @harness_dir)))
  end

  defp strip(source) do
    source
    |> String.replace(~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""[\s\S]*?"""/, "")
    |> String.replace(~r/#.*$/m, "")
  end

  defp lists_in(source) do
    @event_list
    |> Regex.scan(strip(source))
    |> Enum.map(fn [_whole, root, atoms] ->
      tail =
        ~r/:([a-z_0-9]+)/
        |> Regex.scan(atoms)
        |> Enum.map(fn [_, name] -> String.to_atom(name) end)

      [String.to_atom(root) | tail]
    end)
    |> Enum.filter(&(length(&1) >= 2))
  end

  defp found_lists do
    scanned_files()
    |> Enum.flat_map(fn file -> file |> File.read!() |> lists_in() |> Enum.map(&{&1, file}) end)
  end

  defp prefix?(prefix, list), do: Enum.take(list, length(prefix)) == prefix

  test "the scan finds a meaningful number of event lists (guards against a dead regex)" do
    assert length(found_lists()) > 100
  end

  test "catalog entries are well formed and unique" do
    all = Events.all()

    for entry <- all do
      assert Map.keys(entry) |> Enum.sort() == [:description, :event, :measurements, :metadata]
      assert [root | _] = entry.event
      assert root in [:ash_a2a, :a2a]
      assert Enum.all?(entry.event, &is_atom/1)
      assert Enum.all?(entry.measurements, &is_atom/1)
      assert Enum.all?(entry.metadata, &is_atom/1)
      assert is_binary(entry.description) and entry.description != ""
    end

    events = Enum.map(all, & &1.event)
    assert events == Enum.uniq(events), "duplicate catalog events: #{inspect(events -- Enum.uniq(events))}"
  end

  test "every event-name list in lib/ is catalogued" do
    catalog = Enum.map(Events.all(), & &1.event)
    unemitted = Events.unemitted_prefixes()

    missing =
      for {list, file} <- found_lists(),
          not Enum.any?(catalog, &prefix?(list, &1)),
          list not in unemitted,
          uniq: true do
        {list, file}
      end

    assert missing == [],
           "event names found in lib/ but missing from AshA2A.Telemetry.Events.all/0 " <>
             "(add them there, in docs/reference/telemetry.md, or list the prefix in " <>
             "unemitted_prefixes/0): #{inspect(missing)}"
  end

  test "every catalogued event matches a name list found in lib/" do
    lists = found_lists() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    orphans =
      for %{event: event} <- Events.all(),
          not Enum.any?(lists, &prefix?(&1, event)) do
        event
      end

    assert orphans == [],
           "catalogued events nothing in lib/ names (remove them or fix the name): " <>
             inspect(orphans)
  end

  test "declared unemitted prefixes are still present in lib/ and still unemitted" do
    lists = found_lists() |> Enum.map(&elem(&1, 0))
    catalog = Enum.map(Events.all(), & &1.event)

    for prefix <- Events.unemitted_prefixes() do
      refute Enum.any?(catalog, &prefix?(prefix, &1)),
             "#{inspect(prefix)} is catalogued, so drop it from unemitted_prefixes/0"

      assert Enum.any?(lists, &prefix?(prefix, &1)),
             "#{inspect(prefix)} no longer appears in lib/, drop it from unemitted_prefixes/0"
    end
  end

  test "the logger helper attaches to a real emit and logs metadata keys, not values" do
    handler_id = Events.logger_handler_id()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        assert :ok = Events.attach_logger(events: [[:ash_a2a, :health, :checked]])
        assert {:error, :already_exists} = Events.attach_logger()

        :telemetry.execute([:ash_a2a, :health, :checked], %{duration: 7}, %{
          status: :ok,
          secret: "do-not-log-this-value"
        })

        :ok = Events.detach_logger()
      end)

    assert log =~ "[:ash_a2a, :health, :checked]"
    assert log =~ "duration: 7"
    assert log =~ ":secret"
    refute log =~ "do-not-log-this-value"
  end
end
