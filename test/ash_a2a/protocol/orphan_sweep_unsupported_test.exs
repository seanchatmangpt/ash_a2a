defmodule AshA2A.Protocol.OrphanSweepUnsupportedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defmodule NoListStore do
    def get(_ref, _id), do: {:error, :not_found}
    def put(_ref, _task), do: :ok
  end

  test "a store without list_all/2 is a loud typed error with telemetry" do
    id = {:orphan_sweep_unsupported, make_ref()}

    :telemetry.attach(
      id,
      [:ash_a2a, :task, :orphan_sweep_unsupported],
      fn _e, m, meta, pid -> send(pid, {:unsupported, m, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)

    log =
      capture_log([level: :error], fn ->
        assert {:error, {:unsupported, :list_all}} =
                 AshA2A.Protocol.Task.OrphanSweep.sweep({NoListStore, nil})
      end)

    assert log =~ "does not export list_all/2"
    assert_receive {:unsupported, %{count: 1}, %{store: NoListStore}}
  end
end
