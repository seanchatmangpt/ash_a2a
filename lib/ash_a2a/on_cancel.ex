defmodule AshA2A.OnCancel do
  @moduledoc """
  Behaviour for a resource author's real Ash-side compensation hook, run when
  a task is genuinely canceled through `AshA2A.Agent.__cancel__/2`.

  Before this module existed, the only observable effect of a real cancel was
  a `:telemetry.execute/3` event (`[:ash_a2a, :agent, :cancel]`) -- a caller
  could *attach* to that and run compensation from the handler, but there was
  no first-class DSL-level hook a resource author could declare directly on
  the `a2a do skill ... end` entry itself (see the real-gap comment this
  module resolves, `AshA2A.Agent.__cancel__/2`'s moduledoc-adjacent note,
  pre-fix). `on_cancel:` on a skill entity closes that gap, additively: a
  skill with no `on_cancel:` declared behaves exactly as before (telemetry
  only).

  ## Declaring a hook

      a2a do
        skill :my_skill, :some_action, on_cancel: MyApp.MySkillCancelHook
      end

  or, with extra static args appended after the required three:

      a2a do
        skill :my_skill, :some_action, on_cancel: {MyApp.MySkillCancelHook, :on_cancel, [:extra]}
      end

  A bare `module()` is called as `module.on_cancel(exec_context, task_id,
  context_id)` -- the module must implement this behaviour. An `mfa()` tuple
  is called as `apply(module, function, [exec_context, task_id, context_id |
  extra_args])`, so an existing function of a different name/arity can be
  reused without wrapping it.

  `exec_context` is the same `AshA2A.ExecutionContext` (`actor`, `tenant`,
  `context`, `domain`) that `AshA2A.Agent.__cancel__/2` already resolves via
  `AshA2A.ContextResolver.from_a2a_message/4` for its telemetry metadata --
  the identical, trust-boundary-crossed identity, never a value read
  straight from unauthenticated cancel-request metadata a remote caller
  could spoof.

  ## Failure handling

  `AshA2A.Agent.__cancel__/2` always returns `:ok` -- that is the contract
  `A2A.Agent`'s own state machine requires from `handle_cancel/1`
  (`~/xaas/deps/a2a/lib/a2a/agent.ex:148-153`), and the task is already
  being transitioned to `:canceled` regardless of what a resource author's
  hook does. A hook that raises, exits, or returns anything other than `:ok`
  is therefore never allowed to crash the agent's cancel call: `__cancel__/2`
  catches both, and reports the failure via a *second* telemetry event,
  `[:ash_a2a, :agent, :cancel_hook_error]`, carrying the resolved
  `exec_context`/`task_id`/`context_id` plus the real error/reason -- an
  additional, real, observable signal, not a silent swallow.
  """

  @doc """
  Runs real Ash-side compensation for a canceled task.

  Returns `:ok` on success. Any other return value, or a raised
  exception/exit, is recorded (never re-raised) by the caller as a
  `[:ash_a2a, :agent, :cancel_hook_error]` telemetry event.
  """
  @callback on_cancel(
              exec_context :: AshA2A.ExecutionContext.t(),
              task_id :: term(),
              context_id :: term()
            ) :: :ok | {:error, term()}
end
