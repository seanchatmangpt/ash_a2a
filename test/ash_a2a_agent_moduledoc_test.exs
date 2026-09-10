defmodule AshA2AAgentModuledocTest do
  @moduledoc """
  Chicago-style test for the `AshA2A.Agent` concurrency-caveat documentation
  fix (Zach-Daniel-review finding: concurrent dispatch to one agent is fully
  serialized through a single GenServer mailbox, so a slow in-flight
  `:message` call blocks `get_task`/`cancel` for every other in-flight task
  on that agent instance).

  Asserts on the real, compiled `@moduledoc` content fetched via
  `Code.fetch_docs/1` against the actual `AshA2A.Agent` module on disk -- no
  Mock/mox/patch, no hand-built string fixture standing in for the module.
  """

  use ExUnit.Case

  test "AshA2A.Agent's real compiled moduledoc documents single-mailbox serialization" do
    assert {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, _docs} =
             Code.fetch_docs(AshA2A.Agent)

    assert moduledoc =~ "one mailbox"
    assert moduledoc =~ "serialized"
    assert moduledoc =~ "multiple named agent instances"
  end
end
