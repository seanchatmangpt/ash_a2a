defmodule AshA2A.PreparedEffectTest do
 use ExUnit.Case, async: true
 test "prepared digest binds effect" do
  {:ok,i}=AshA2A.EffectInstance.new(%{request:%{},subject:%{"id"=>1},effect:%{"op"=>"update"}}); assert {:ok,p}=AshA2A.PreparedEffect.new(i,%{"op"=>"update"},:change); assert p.prepared_digest =~ "sha256:"
 end
end
