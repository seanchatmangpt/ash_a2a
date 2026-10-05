# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CallbackRegistry do
  @moduledoc """
  Compile-time-closed registry of permitted `{module, function, arity}` callbacks
  (RFC-SA2A-006 s23; CWE-94). Replaces free `apply(module, function, args)` at
  kernel-adjacent dispatch sites: a callback chosen by config or DSL must be a
  member of this set, otherwise it is refused with
  `{:error, %{code: :callback_not_permitted}}` and never executed.

  The set is fixed when this module is compiled; nothing extends it at runtime
  and no atom is created from a string (non-atom inputs are refused).
  """

  @members [
    {BeamPM.Ferroplan, :plan_production, 4},
    {AshR2RML, :mapping_result, 1}
  ]

  # Test-only member: the extended-card provider court invokes a callback defined
  # in its own test module through the `{m, f, extra}` provider form.
  @test_members if Mix.env() == :test,
                  do: [{AshA2A.A2ATransport.ExtendedCardTest, :add_admin_skill, 2}],
                  else: []

  @registry MapSet.new(@members ++ @test_members)

  @doc "All permitted callbacks."
  @spec members() :: [{module(), atom(), non_neg_integer()}]
  def members, do: MapSet.to_list(@registry)

  @doc "Is `{module, function, arity}` a registry member?"
  @spec permitted?(term(), term(), term()) :: boolean()
  def permitted?(m, f, arity) when is_atom(m) and is_atom(f) and is_integer(arity),
    do: MapSet.member?(@registry, {m, f, arity})

  def permitted?(_, _, _), do: false

  @doc "Invokes a permitted callback; refuses any non-member without executing it."
  @spec invoke(term(), term(), term()) :: term() | {:error, map()}
  def invoke(m, f, args) when is_list(args) do
    if permitted?(m, f, length(args)) do
      apply(m, f, args)
    else
      refused(m, f, length(args))
    end
  end

  def invoke(m, f, _args), do: refused(m, f, nil)

  defp refused(m, f, arity),
    do:
      {:error,
       %{
         code: :callback_not_permitted,
         callback: inspect({m, f, arity}, limit: 5, printable_limit: 80)
       }}
end
