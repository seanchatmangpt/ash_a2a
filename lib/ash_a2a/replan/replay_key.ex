defmodule AshA2A.Replan.ReplayKey do
  def build(subject, provider, attempt),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary({subject, provider, attempt}))
      |> Base.encode16(case: :lower)
end
