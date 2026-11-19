defmodule AshA2A.GraphLaw.UnpinnedRefusalTest do
  use ExUnit.Case, async: false

  alias AshA2A.GraphLaw.EngineLoad

  setup do
    prev = Application.fetch_env(:ash_a2a, :graphlaw_allow_unpinned)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:ash_a2a, :graphlaw_allow_unpinned, v)
        :error -> Application.delete_env(:ash_a2a, :graphlaw_allow_unpinned)
      end
    end)

    :ok
  end

  test ":unpinned is refused by default (runtime config)" do
    Application.delete_env(:ash_a2a, :graphlaw_allow_unpinned)

    assert {:error, %{code: :graphlaw_wasm_unpinned_refused}} =
             EngineLoad.check_digest("abc", :unpinned)
  end

  test ":unpinned is admitted only when explicitly enabled" do
    Application.put_env(:ash_a2a, :graphlaw_allow_unpinned, true)
    assert :ok = EngineLoad.check_digest("abc", :unpinned)
  end

  test "resolve_wasm_path refuses a missing path with a typed error" do
    path = Path.join(System.tmp_dir!(), "no-such-#{System.unique_integer([:positive])}.wasm")

    assert {:error, %{code: :graphlaw_wasm_missing}} =
             AshA2A.GraphLaw.resolve_wasm_path(wasm_path: path)
  end
end
