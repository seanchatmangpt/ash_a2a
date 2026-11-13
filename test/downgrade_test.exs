defmodule AshA2A.Protocol.DowngradeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Downgrade

  @task %{
    "id" => "t1",
    "generation" => 3,
    "timeline" => [%{"g" => 1}],
    "status" => %{"state" => "TASK_STATE_WORKING", "message" => %{"role" => "ROLE_AGENT"}},
    "artifacts" => [
      %{
        "artifactId" => "a1",
        "role" => "x",
        "startGeneration" => 1,
        "endGeneration" => 2,
        "parts" => [%{"text" => "hi"}]
      }
    ]
  }

  test "applies?/1" do
    assert Downgrade.applies?("1.0")
    assert Downgrade.applies?("0.3")
    refute Downgrade.applies?("1.1")
    refute Downgrade.applies?("2.0")
    refute Downgrade.applies?(nil)
    refute Downgrade.applies?("garbage")
  end

  test "nil and >=1.1 pass through unchanged" do
    assert Downgrade.to_wire(@task, nil) == @task
    assert Downgrade.to_wire(@task, "1.1") == @task
  end

  test "1.0 drops v1.1 fields, keeps message role" do
    out = Downgrade.to_wire(@task, "1.0")
    refute Map.has_key?(out, "generation")
    refute Map.has_key?(out, "timeline")
    assert out["status"]["message"]["role"] == "ROLE_AGENT"
    [art] = out["artifacts"]
    assert art == %{"artifactId" => "a1", "parts" => [%{"text" => "hi"}]}
  end

  test "event maps lose generation" do
    ev = %{"result" => %{"statusUpdate" => %{"taskId" => "t", "generation" => 2}}}
    assert Downgrade.to_wire(ev, "1.0") == %{"result" => %{"statusUpdate" => %{"taskId" => "t"}}}
  end

  test "messageUpdate frames dropped" do
    frame = %{"result" => %{"messageUpdate" => %{"x" => 1}}}
    assert Downgrade.drop_frame?(frame, "1.0")
    assert Downgrade.drop_frame?(%{"messageUpdate" => %{}}, "1.0")
    refute Downgrade.drop_frame?(frame, nil)
    refute Downgrade.drop_frame?(%{"statusUpdate" => %{}}, "1.0")
    assert Downgrade.to_wire(frame, "1.0") == :drop
    assert Downgrade.to_wire(frame, nil) == frame
    assert Downgrade.to_wire([frame, %{"a" => 1}], "1.0") == [%{"a" => 1}]
  end
end
