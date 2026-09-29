defmodule AshA2A.ConsequenceKernel.PreparedEffectStore.Memory do
  use Agent
  @behaviour AshA2A.ConsequenceKernel.PreparedEffectStore
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  def start_link(opts \\ []), do: Agent.start_link(fn -> %{records: %{}, requests: %{}, effects: %{}} end, opts)
  def put(pid, %{digest: d}=r), do: Agent.get_and_update(pid, fn s -> if Map.has_key?(s.records,d), do: {{:error,:prepared_duplicate},s}, else: {:ok,put_in(s,[:records,d],r)} end)
  def fetch(pid, d), do: Agent.get(pid, fn s -> case Map.fetch(s.records,d) do {:ok,r}->{:ok,r}; :error->:not_found end end)
  def transition(pid, d, from, to), do: Agent.get_and_update(pid, fn s -> with {:ok,r}<-Map.fetch(s.records,d), true<-r.state==from, :ok<-Transition.admit(from,to) do {:ok,put_in(s,[:records,d,:state],to)} else _->{{:error,:prepared_transition_refused},s} end end)
  def claim_request(pid,id,owner), do: claim(pid,:requests,id,owner)
  def claim_effect(pid,id,owner), do: claim(pid,:effects,id,owner)
  defp claim(pid,k,id,owner), do: Agent.get_and_update(pid, fn s -> case get_in(s,[k,id]) do nil->{:ok,put_in(s,[k,id],owner)}; ^owner->{:ok,s}; _->{{:error,:claim_conflict},s} end end)
end
