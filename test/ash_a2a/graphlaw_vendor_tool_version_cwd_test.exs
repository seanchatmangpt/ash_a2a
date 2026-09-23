defmodule AshA2A.GraphLawVendorToolVersionCwdTest do
  @moduledoc """
  Regression cover for `AshA2A.GraphLaw.Vendor.provenance/2` recording a
  compiler that did not build the artifact.

  The defect: `tool_version/1` called `System.cmd/3` with no `:cd`, so
  `rustc --version` and `wasm-pack --version` ran in `ash_a2a`'s working
  directory while `build/1` really runs `wasm-pack` with `cd: crate_dir`
  inside the praxis checkout. `rustup` resolves the toolchain by walking up
  from the *current* directory looking for a `rust-toolchain.toml` pin, so
  the two directories can (and here do) resolve different toolchains, and the
  manifest recorded the wrong one.

  This test does not mock `System.cmd/3`. It builds a real directory tree,
  writes a **real executable** onto a real `PATH`, and has that executable
  report its own real working directory -- so the assertion is over the cwd
  the probe subprocess actually ran in, which is exactly the fact the defect
  was about. `System.find_executable/1` and `System.cmd/3` are the real ones
  throughout.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.GraphLaw.Vendor

  @wasm_crate "crates/praxis-graphlaw-wasm"

  setup do
    root = Path.join(System.tmp_dir!(), "sa2a-vendor-cwd-#{System.unique_integer([:positive])}")
    crate_dir = Path.join(root, @wasm_crate)
    bin_dir = Path.join(root, "bin")
    elsewhere = Path.join(root, "elsewhere")

    Enum.each([crate_dir, bin_dir, elsewhere], &File.mkdir_p!/1)

    # A real toolchain pin in the real build directory, which is the thing
    # rustup would resolve differently from ash_a2a's cwd.
    File.write!(
      Path.join(crate_dir, "rust-toolchain.toml"),
      ~s([toolchain]\nchannel = "nightly"\n)
    )

    # A real executable that reports the directory it was actually run in.
    probe = Path.join(bin_dir, "sa2a-cwd-probe")
    File.write!(probe, "#!/bin/sh\npwd\n")
    File.chmod!(probe, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> original_path)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(root)
    end)

    %{root: root, crate_dir: crate_dir, elsewhere: elsewhere}
  end

  describe "tool_version_cwd/2 derives the same directory build/1 builds in" do
    test "it is <praxis_root>/#{@wasm_crate}, byte-for-byte how build/1 computes crate_dir", %{
      root: root,
      crate_dir: crate_dir
    } do
      assert Vendor.tool_version_cwd(root) == crate_dir
    end

    test "an explicit :cd wins", %{root: root, elsewhere: elsewhere} do
      assert Vendor.tool_version_cwd(root, cd: elsewhere) == elsewhere
    end

    test "it falls back to the praxis root when the crate directory is absent" do
      bare = Path.join(System.tmp_dir!(), "sa2a-bare-#{System.unique_integer([:positive])}")
      File.mkdir_p!(bare)
      on_exit(fn -> File.rm_rf!(bare) end)

      assert Vendor.tool_version_cwd(bare) == bare
    end

    test "it falls back to the current directory only when there is no praxis root" do
      assert Vendor.tool_version_cwd(nil) == File.cwd!()
    end
  end

  describe "the probe subprocess really runs in that directory" do
    test "rustc_version is measured in the crate directory, not in ash_a2a's cwd", %{
      root: root,
      crate_dir: crate_dir
    } do
      provenance = Vendor.provenance(root, rustc: "sa2a-cwd-probe", wasm_pack: "sa2a-cwd-probe")

      # The probe prints its own cwd, so this IS the directory the subprocess
      # ran in -- not a claim about it.
      assert Path.expand(provenance["rustc_version"]) == Path.expand(crate_dir)
      assert Path.expand(provenance["wasm_pack_version"]) == Path.expand(crate_dir)

      # The defect: before the fix both of these ran here instead.
      refute Path.expand(provenance["rustc_version"]) == Path.expand(File.cwd!())
    end

    test "the directory used is recorded in the manifest so a reader can check it", %{
      root: root,
      crate_dir: crate_dir
    } do
      provenance = Vendor.provenance(root, rustc: "sa2a-cwd-probe")

      assert provenance["tool_version_cwd"] == crate_dir

      assert Path.expand(provenance["rustc_version"]) ==
               Path.expand(provenance["tool_version_cwd"])
    end

    test "an explicit :cd moves the probe with it", %{root: root, elsewhere: elsewhere} do
      provenance =
        Vendor.provenance(root, rustc: "sa2a-cwd-probe", cd: elsewhere)

      assert Path.expand(provenance["rustc_version"]) == Path.expand(elsewhere)
      assert provenance["tool_version_cwd"] == elsewhere
    end

    test "an absent tool is still nil rather than a guess", %{root: root} do
      provenance = Vendor.provenance(root, rustc: "sa2a-definitely-not-on-path")

      assert provenance["rustc_version"] == nil
    end
  end
end
