defmodule AshA2A.Reactor.CommandWorkflow do
  @moduledoc """
  Real `Reactor` DAG exercising the actual `Reactor.run/2..4` scheduler over
  the receipted `AshA2A.CommandBus` boundary end to end.

  Closes a real gap: `test/ash_a2a/lifecycle_reactor_test.exs` only ever
  called `AshA2A.Reactor.ExecuteCommand.run` as a plain function
  (`grep -rn "Reactor.run\\|Reactor.Builder" test/ lib/` returned zero
  matches repo-wide before this module) -- so the real Reactor
  dependency-resolution/execution engine had never actually run in this
  repository, only the `Reactor.Step` callback contract in isolation. This
  module is a real, compiled `use Reactor` DSL module composed of three
  genuine steps wired as a dependency graph:

  1. `:build_command` (`AshA2A.Reactor.BuildCommand`) -- builds/validates a
     real `AshA2A.Command` envelope from workflow inputs.
  2. `:execute_command` (`AshA2A.Reactor.ExecuteCommand`) -- the existing,
     unmodified Reactor step adapter that routes the built command through
     the real `AshA2A.CommandBus` (admission -> claim -> dispatch ->
     receipt). Reactor coordinates this step; it gains no independent
     authority and never calls `AshA2A.Dispatcher` itself --
     `ExecuteCommand`'s own moduledoc states this invariant and this
     workflow does not weaken it.
  3. `:confirm_receipt` (`AshA2A.Reactor.ConfirmReceipt`) -- reads the real
     committed `AshA2A.Receipt` and confirms its real `status`.

  Because `:execute_command` genuinely depends on `:build_command`'s real
  output (`result(:build_command)`) and `:confirm_receipt` genuinely depends
  on `:execute_command`'s real output, a consequence-bearing command with no
  admitted `AshA2A.Authority` is refused inside `AshA2A.CommandBus.admit/2`
  (a real `:authority_required` code) and `:execute_command` returns
  `{:error, ...}` -- the real Reactor engine halts the run there:
  `:confirm_receipt` never executes and `Reactor.run/2` surfaces the real
  `CommandBus` refusal wrapped in a `Reactor.Error.Invalid.RunStepError`,
  never a raw unguarded `Ash` exception and never a silently-continued DAG.
  """

  use Reactor

  input(:capability_id)
  input(:agent_id)
  input(:principal_id)
  input(:command_input)
  input(:resource_or_domain)
  input(:message)
  input(:authority)
  input(:command_id)

  step :build_command, AshA2A.Reactor.BuildCommand do
    argument(:capability_id, input(:capability_id))
    argument(:agent_id, input(:agent_id))
    argument(:principal_id, input(:principal_id))
    argument(:input, input(:command_input))
    argument(:authority, input(:authority))
    argument(:command_id, input(:command_id))
  end

  step :execute_command, AshA2A.Reactor.ExecuteCommand do
    argument(:command, result(:build_command))
    argument(:message, input(:message))
    argument(:resource_or_domain, input(:resource_or_domain))
  end

  step :confirm_receipt, AshA2A.Reactor.ConfirmReceipt do
    argument(:receipt, result(:execute_command))
  end

  return(:confirm_receipt)
end
