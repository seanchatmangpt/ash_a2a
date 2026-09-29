defmodule AshA2A.OcelProjectionTest do
 use ExUnit.Case, async: true
 test "projection preserves exact identity" do
  p=%{instance:%{effect_id:"e",subject_digest:"s"},prepared_digest:"p"}; x=AshA2A.ConsequenceKernel.Ocel.project(p,:ok); assert x["effect_id"]=="e"; assert x["subject_digest"]=="s"
 end
end
