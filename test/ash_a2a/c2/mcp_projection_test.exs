defmodule AshA2A.C2.PolicyEvidence.McpProjectionTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.PolicyEvidence.McpProjection

  test "projects a tool call; digest changes with arguments" do
    {:ok, a} = McpProjection.project("alice", %{"name" => "pay", "arguments" => %{"n" => 1}})
    {:ok, b} = McpProjection.project("alice", %{"name" => "pay", "arguments" => %{"n" => 2}})
    assert a.capability == "mcp.tool:pay"
    assert a.principal == "alice"
    refute a.digest == b.digest
  end

  test "malformed calls are refused" do
    assert {:error, :mcp_tool_name_missing} = McpProjection.project("alice", %{})

    assert {:error, :mcp_arguments_malformed} =
             McpProjection.project("alice", %{"name" => "x", "arguments" => [1]})
  end
end
