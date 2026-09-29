defmodule AshA2A.ConsequenceKernel.W4C.AdmittedTopology do
  @kernel_prefix "Elixir.AshA2A.ConsequenceKernel"
  def admitted?(caller, kind) when kind in [:effect, :dynamic_effect, :dispatcher] do
    String.starts_with?(to_string(caller), @kernel_prefix)
  end

  def admitted?(_caller, :observe), do: true
  def admitted?(_, _), do: false
end
