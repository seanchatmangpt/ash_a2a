# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Compiled only when Bandit is available, like the rest of the simulation
# server (see AshA2A.Sim.Server).
if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.Agent do
    @moduledoc """
    The simulation server's agent: `use AshA2A.Agent` over `AshA2A.Sim.Note`,
    with no hand-written message handling. Every task state is reached through
    an ordinary skill call:

    | Task state | How to reach it |
    |---|---|
    | completed | `list_notes`, `count_notes`, or a granted `create_note` |
    | a bare Message, no task | `ping` (optionally with `echo`) |
    | streamed artifacts | `list_notes` with `"stream" => true` in the data part |
    | input-required, then continued | `create_note` without `title`, then send `title` with the same `taskId` |
    | working, then canceled | `slow_count` with a large `delay_ms`, then `tasks/cancel` |
    | auth-required, then continued | `step_up` without `otp`, then send `otp` with the same `taskId` |
    | rejected | `unclassified_note` |
    | failed | `update_note` naming an id that does not exist, or any `:change` skill without a grant |

    Callers must be authenticated. `AshA2A.Sim.Server` puts the bearer scheme in
    front of every mount and files the standing grants for the writer identity.
    """

    use AshA2A.Agent,
      resource_or_domain: AshA2A.Sim.Note,
      name: "ash-a2a-sim",
      description:
        "Simulation agent: an ETS note store with one skill per action type and consequence class.",
      require_authenticated_caller: true,
      observe_generic_actions: [:count_notes, :ping, :slow_count, :step_up],
      security_schemes: %{
        "bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}
      },
      security: [%{"bearer_auth" => ["a2a:invoke"]}]
  end
end
