defmodule AshA2A.ConsequenceKernel.W4.DispatcherFence do
  @moduledoc false
  @token_key {__MODULE__, :token}
  def enter(fun) when is_function(fun, 0) do
    prior = Process.get(@token_key)
    Process.put(@token_key, true)

    try do
      fun.()
    after
      if prior, do: Process.put(@token_key, prior), else: Process.delete(@token_key)
    end
  end

  def admitted?, do: Process.get(@token_key) == true
end
