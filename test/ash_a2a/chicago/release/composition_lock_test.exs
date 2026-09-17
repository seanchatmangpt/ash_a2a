defmodule AshA2A.Chicago.Release.CompositionLockTest do
  @moduledoc """
  Qualifies `AshA2A.Chicago.Release.CompositionLock` Chicago style: real
  `build!/1` against this actual repository's own real `mix.lock` and
  `native/hddl_cli/Cargo.toml` -- zero mocks. Assertions are state-based (the
  real returned struct/map fields), never interaction-based.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Chicago.Release.CompositionLock

  describe "schema/0, tracked/0, scope_disclosure/0" do
    test "reports the real §85 schema identity" do
      assert CompositionLock.schema() == "ash_a2a.chicago.release.composition_lock/1"
    end

    test "tracked/0 is the fixed load-bearing package set" do
      assert CompositionLock.tracked() == ~w(ash a2a ekv wasmex rdf)
    end

    test "the scope-disclosure text names autofde-lab as the out-of-scope primary integration court" do
      assert CompositionLock.scope_disclosure() =~ "autofde-lab"
      assert CompositionLock.scope_disclosure() =~ "BOUNDED TO ash_a2a's own"
    end
  end

  describe "build!/1 against this real repo's mix.lock and Cargo.toml" do
    setup do
      %{lock: CompositionLock.build!()}
    end

    test "tracked_dependencies pins real {version, checksum} for every tracked package present in mix.lock",
         %{lock: lock} do
      assert Map.keys(lock.tracked_dependencies) |> Enum.sort() ==
               Enum.sort(~w(ash a2a ekv wasmex rdf))

      for package <- ~w(ash a2a) do
        pin = lock.tracked_dependencies[package]
        assert is_binary(pin["version"]), "#{package}: #{inspect(pin)}"
        assert is_binary(pin["checksum"]), "#{package}: #{inspect(pin)}"
      end
    end

    test "tracked_dependencies matches this repo's real mix.lock read independently via Code.eval_file/1",
         %{lock: lock} do
      {raw, _bindings} = Code.eval_file(Path.join(File.cwd!(), "mix.lock"))

      for package <- ~w(ash a2a ekv wasmex rdf) do
        entry = Map.get(raw, String.to_atom(package))
        pin = lock.tracked_dependencies[package]

        case entry do
          nil ->
            assert pin == %{"version" => nil, "checksum" => nil}

          entry when is_tuple(entry) ->
            values = Tuple.to_list(entry)
            assert pin["version"] == Enum.at(values, 2)
            assert pin["checksum"] == List.last(values)
        end
      end
    end

    test "native_pins reports this real repo's real ferroplan git-rev pin", %{lock: lock} do
      assert lock.native_pins["ferroplan"] == "29134d7bc2c578aa39e05bceeee43a6893f2026b"
      assert lock.native_pins["ferroplan-hddl"] == "29134d7bc2c578aa39e05bceeee43a6893f2026b"
    end

    test "mix_lock_sha256 is a real sha256 over the real mix.lock file, verified independently",
         %{lock: lock} do
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, lock.mix_lock_sha256)

      independent =
        File.cwd!()
        |> Path.join("mix.lock")
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert lock.mix_lock_sha256 == independent
    end

    test "scope_disclosure travels with the built document verbatim", %{lock: lock} do
      assert lock.scope_disclosure == CompositionLock.scope_disclosure()
    end
  end

  describe "tracked_dependencies/2 and native_pins/1 record-never-invent on missing input" do
    test "an absent mix.lock yields nil version/checksum for every tracked package, never raises" do
      missing_lock =
        Path.join(
          System.tmp_dir!(),
          "sa2a-composition-lock-missing-#{System.unique_integer([:positive])}.lock"
        )

      pins = CompositionLock.tracked_dependencies(missing_lock, ~w(ash a2a))

      assert pins == %{
               "ash" => %{"version" => nil, "checksum" => nil},
               "a2a" => %{"version" => nil, "checksum" => nil}
             }
    end

    test "a package absent from a real mix.lock yields nil for that package only" do
      pins =
        CompositionLock.tracked_dependencies(
          Path.join(File.cwd!(), "mix.lock"),
          ["ash", "this_package_does_not_exist_in_any_lockfile"]
        )

      assert is_binary(pins["ash"]["version"])

      assert pins["this_package_does_not_exist_in_any_lockfile"] == %{
               "version" => nil,
               "checksum" => nil
             }
    end

    test "an unreadable native manifest yields nil for both ferroplan pins, never raises" do
      missing_manifest =
        Path.join(
          System.tmp_dir!(),
          "sa2a-composition-lock-missing-cargo-#{System.unique_integer([:positive])}.toml"
        )

      assert CompositionLock.native_pins(missing_manifest) == %{
               "ferroplan" => nil,
               "ferroplan-hddl" => nil
             }
    end
  end

  describe "to_map/1" do
    test "produces the §85 JSON-map shape with every field present" do
      map = CompositionLock.build!() |> CompositionLock.to_map()

      assert %{
               "schema" => "ash_a2a.chicago.release.composition_lock/1",
               "tracked_dependencies" => tracked,
               "native_pins" => native,
               "mix_lock_sha256" => mix_sha,
               "scope_disclosure" => disclosure
             } = map

      assert is_map(tracked)
      assert is_map(native)
      assert is_binary(mix_sha)
      assert disclosure =~ "autofde-lab"
    end
  end
end
