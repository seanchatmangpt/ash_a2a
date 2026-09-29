defmodule AshA2A.C2.Actuator do
 def execute(effect,cert,ctx,store,effector) do
  with :ok<-AshA2A.C2.CompleteMediation.admit(effect,cert,ctx), :ok<-store.claim(effect.digest,cert.generation), {:ok,r}<-effector.perform(effect) do store.complete(effect.digest,r); {:ok,r} end
 end
end