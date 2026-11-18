defmodule AshA2A.Telemetry.OcelBootWarningTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias AshA2A.Telemetry.OcelForwarder

  setup do
    prev = Application.get_env(:ash_a2a, :ocel_ingest_url)
    on_exit(fn -> Application.put_env(:ash_a2a, :ocel_ingest_url, prev) end)
  end

  test "warns and returns :disabled without ingest url" do
    Application.delete_env(:ash_a2a, :ocel_ingest_url)
    log = capture_log(fn -> assert OcelForwarder.warn_if_unconfigured() == :disabled end)
    assert log =~ "ASH_A2A_OCEL_INGEST_URL"
  end

  test "silent when configured" do
    Application.put_env(:ash_a2a, :ocel_ingest_url, "http://127.0.0.1:1")
    log = capture_log(fn -> assert OcelForwarder.warn_if_unconfigured() == :ok end)
    refute log =~ "no :ocel_ingest_url"
  end

  test "catch-all increments ignored counter" do
    before = OcelForwarder.ignored_count()
    assert :ok = OcelForwarder.handle_event([:other, :event], %{}, %{}, nil)
    assert OcelForwarder.ignored_count() == before + 1
  end

  describe "runtime.exs hook" do
    defp read_runtime(env_value) do
      prev = System.get_env("ASH_A2A_OCEL_INGEST_URL")

      if env_value,
        do: System.put_env("ASH_A2A_OCEL_INGEST_URL", env_value),
        else: System.delete_env("ASH_A2A_OCEL_INGEST_URL")

      try do
        Config.Reader.read!("config/runtime.exs", env: :test)
      after
        if prev,
          do: System.put_env("ASH_A2A_OCEL_INGEST_URL", prev),
          else: System.delete_env("ASH_A2A_OCEL_INGEST_URL")
      end
    end

    test "env var sets :ocel_ingest_url" do
      cfg = read_runtime("http://ocel.example:9/ingest")
      assert get_in(cfg, [:ash_a2a, :ocel_ingest_url]) == "http://ocel.example:9/ingest"
    end

    test "unset or empty env var leaves it unconfigured" do
      refute Keyword.has_key?(Keyword.get(read_runtime(nil), :ash_a2a, []), :ocel_ingest_url)
      refute Keyword.has_key?(Keyword.get(read_runtime(""), :ash_a2a, []), :ocel_ingest_url)
    end
  end

  test "boot sequence calls warn_if_unconfigured/0 after attach!/0 (structural pin)" do
    src = File.read!("lib/ash_a2a/application.ex")

    assert src =~
             ~r/OcelForwarder\.attach!\(\)\s*\n\s*_ = AshA2A\.Telemetry\.OcelForwarder\.warn_if_unconfigured\(\)/
  end
end
