# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthZEN.MetadataTest do
  use ExUnit.Case, async: true
  alias AshA2A.AuthZEN.Metadata

  test "retains unknown metadata and binds exact PDP identifier" do
    assert {:ok, metadata} =
             Metadata.decode(%{
               "policy_decision_point" => "https://pdp.example",
               "vendor_extension" => %{"v" => 1}
             })

    assert metadata.access_evaluation_endpoint == "https://pdp.example/access/v1/evaluation"
    assert metadata.extensions["vendor_extension"] == %{"v" => 1}
    assert :ok = Metadata.bind_expected(metadata, "https://pdp.example")
    assert {:error, :pdp_mixup} = Metadata.bind_expected(metadata, "https://evil.example")
  end

  test "rejects non HTTPS PDP identity" do
    assert {:error, _} = Metadata.decode(%{"policy_decision_point" => "http://pdp.example"})
  end
end
