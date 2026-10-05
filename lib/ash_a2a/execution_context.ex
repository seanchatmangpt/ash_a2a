# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ExecutionContext do
  @moduledoc """
  The resolved, trust-boundary-crossed execution context for one A2A skill
  dispatch. Built exclusively by `AshA2A.ContextResolver.from_a2a_message/3` —
  never constructed directly from raw `AshA2A.Protocol.Message` metadata at a call site
  (ash_a2a PRD/ARD §3.5).

  Field shape mirrors the opts `AshAi.Tool.Execution.build_opts/2` feeds into
  `Ash.Changeset.for_create/3` / `Ash.Query.for_read/3` / `Ash.ActionInput.for_action/3`
  (`~/xaas/deps/ash_ai/lib/ash_ai/tool/execution.ex:100-107`), plus `domain` since
  ash_a2a threads the domain explicitly rather than closing over it, and
  `history` since ash_a2a threads the caller's `AshA2A.Protocol.Agent` task transcript
  explicitly rather than discarding it (see `AshA2A.Dispatcher.dispatch/4`).
  """

  @type t :: %__MODULE__{
          actor: term(),
          tenant: term(),
          context: map(),
          domain: module(),
          history: [AshA2A.Protocol.Message.t()]
        }

  defstruct [:actor, :tenant, :domain, context: %{}, history: []]
end
