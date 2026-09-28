defmodule AshA2A.GallClosure.AuthorityCeiling do
  @moduledoc """
  Bounded GALL-029/030 guard for authority.

  Admits only authority values inside the closed ceiling set
  `none, witness, observe, propose, select` (strings or atoms, case-insensitive).
  Anything else, including DO-grade authority, is refused.
  """
  @ceiling ~w(none witness observe propose select)

  def admit(%{authority: v} = s) do
    if within_ceiling?(v),
      do: {:ok, Map.put(s, :gall_guard, :authority_ceiling)},
      else: {:error, :authority_exceeded}
  end

  def admit(_), do: {:error, :authority_exceeded}

  defp within_ceiling?(v) when is_binary(v), do: String.downcase(v) in @ceiling

  defp within_ceiling?(v) when is_atom(v) and v not in [nil, true, false],
    do: within_ceiling?(Atom.to_string(v))

  defp within_ceiling?(_), do: false
end
