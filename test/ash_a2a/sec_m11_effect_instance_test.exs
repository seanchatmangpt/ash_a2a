defmodule AshA2A.SecM11EffectInstanceTest do
 use ExUnit.Case, async: true
 test "effect identity binds request and subject" do
  assert {:ok,x}=AshA2A.EffectInstance.new(%{request:%{"x"=>1},subject:%{"id"=>"s"},effect:%{"op"=>"create"}}); assert x.request_id != x.effect_id; assert x.subject_digest =~ "sha256:"
 end
end
