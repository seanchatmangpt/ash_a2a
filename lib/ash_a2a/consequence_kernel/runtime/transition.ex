defmodule AshA2A.ConsequenceKernel.Runtime.Transition do
  @moduledoc "Fail-closed C1 prepared-effect state transition relation."
  @allowed MapSet.new([{:prepared,:claimed},{:prepared,:released},{:claimed,:applying},{:claimed,:released},{:applying,:completed},{:applying,:unknown_outcome},{:unknown_outcome,:reconciled},{:unknown_outcome,:compensated}])
  def valid?(from, to), do: MapSet.member?(@allowed, {from, to})
  def admit(from, to), do: if(valid?(from, to), do: :ok, else: {:error, {:transition_forbidden, from, to}})
end
