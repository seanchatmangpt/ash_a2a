# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.RedactTest do
  use ExUnit.Case, async: true

  alias AshA2A.Telemetry.Redact

  doctest AshA2A.Telemetry.Redact

  test "summaries never carry the data of the reason term" do
    secret = "Bearer eyJsecret"

    reasons = [
      {:invalid_input, %{password: secret}},
      %{code: :dispatch_crashed, detail: secret},
      {:error, secret, :extra},
      %ArgumentError{message: secret},
      [secret],
      secret
    ]

    for reason <- reasons do
      summary = Redact.error_summary(reason)
      assert is_atom(summary.kind)
      refute inspect(summary) =~ "eyJsecret"
    end
  end

  test "actor_id/1 returns the id and never the struct" do
    assert Redact.actor_id(%{id: "a1", api_key: "k"}) == "a1"
    assert Redact.actor_id(%{principal: %{value: "p1"}}) == "p1"
    assert Redact.actor_id(%{api_key: "k"}) == nil
  end
end
