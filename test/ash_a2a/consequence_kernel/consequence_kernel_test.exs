defmodule AshA2A.ConsequenceKernelTest do
 use ExUnit.Case, async: true
 defmodule Store do def claim_request(_, _),do: :ok; def claim_effect(_, _),do: :ok end
 defmodule Auth do def revalidate(_, _),do: :ok end
 defmodule Eff do def apply(_),do: {:ok,:done} end
 test "mediates claims authority class and effect" do
  p=%{instance:%{request_id:"r",effect_id:"e"},consequence_class: :change}; assert {:ok,:done}=AshA2A.ConsequenceKernel.execute(p,store:Store,owner:self(),authority:Auth,principal:"p",effector:Eff)
 end
end
