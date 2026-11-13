# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.W9ExtensionCompileTest.Unversioned do
  @moduledoc false
  @behaviour AshA2A.Protocol.Extension

  @impl true
  def declaration(_state),
    do: %AshA2A.Protocol.AgentExtension{uri: "https://w9.example/ext/unversioned"}
end

defmodule AshA2A.W9ExtensionCompileTest do
  @moduledoc """
  W9 item 2: `AshA2A.Protocol.Extension.compile/1` dedupes repeated URIs and
  warns (A2A extensions topic: SHOULD be versioned) when a URI lacks a `/vN`
  suffix. The warning is emitted when a plug is initialised (compile time under
  Phoenix's `plug` macro).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshA2A.Protocol.Extension
  alias AshA2A.Protocol.Extension.Timestamp
  alias AshA2A.W9ExtensionCompileTest.Unversioned

  test "versioned_uri?/1 recognises /vN and /vN.M suffixes only" do
    assert Extension.versioned_uri?("https://x.example/ext/foo/v1")
    assert Extension.versioned_uri?("https://x.example/ext/foo/v2.1")
    assert Extension.versioned_uri?("https://x.example/ext/foo/v1/")
    refute Extension.versioned_uri?("https://x.example/ext/foo")
    refute Extension.versioned_uri?("https://x.example/ext/foo/v")
    refute Extension.versioned_uri?("https://x.example/ext/v1/foo")
    refute Extension.versioned_uri?(nil)
  end

  test "compile/1 warns for an unversioned URI and stays silent for a versioned one" do
    log = capture_log([level: :warning], fn -> assert [{Unversioned, _, _}] = Extension.compile([Unversioned]) end)
    assert log =~ "without a /vN version suffix"
    assert log =~ "https://w9.example/ext/unversioned"

    quiet = capture_log([level: :warning], fn -> Extension.compile([Timestamp]) end)
    refute quiet =~ "version suffix"
  end

  test "compile/1 keeps the first declaration of a repeated URI" do
    assert [{Timestamp, _, decl}] = Extension.compile([Timestamp, {Timestamp, []}, Timestamp])
    assert decl.uri == Timestamp.uri()
  end

  test "Transport.Plug.init/1 warns too, and still splits advertise-only declarations" do
    declaration = %AshA2A.Protocol.AgentExtension{uri: "https://w9.example/ext/advertised/v1"}

    log =
      capture_log([level: :warning], fn ->
        opts =
          AshA2A.Transport.Plug.init(
            agent: :w9_no_such_agent,
            extensions: [Unversioned, declaration]
          )

        assert [{Unversioned, _, _}] = opts.compiled_extensions
        assert opts.extensions == [declaration]
      end)

    assert log =~ "without a /vN version suffix"
  end
end
