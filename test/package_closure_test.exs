defmodule AshA2A.PackageClosureTest do
  use ExUnit.Case, async: true

  test "vendored sa2a_crypto is compiled and shipped without an invalid path dependency" do
    project = Mix.Project.config()
    package_files = get_in(project, [:package, :files]) || []
    deps = project[:deps] || []

    assert "sa2a_crypto/lib" in package_files
    refute Enum.any?(deps, fn
             {:sa2a_crypto, _requirement} -> true
             {:sa2a_crypto, _requirement, _opts} -> true
             _ -> false
           end)

    assert Code.ensure_loaded?(Sa2aCrypto)
    assert Code.ensure_loaded?(Sa2aCrypto.Standing)
  end
end
