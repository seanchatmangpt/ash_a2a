# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Ocel do
  def project(prepared, outcome) do
    %{
      "ocel:type" => "SA2A.Consequence",
      "effect_id" => prepared.instance.effect_id,
      "prepared_digest" => prepared.prepared_digest,
      "outcome" => to_string(outcome),
      "subject_digest" => prepared.instance.subject_digest
    }
  end
end
