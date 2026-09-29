defmodule AshA2A.ConsequenceKernel.W5.CrashWindow do
 def classify(:before_do), do: :not_applied
 def classify(:after_do_before_receipt), do: :unknown_outcome
 def classify(:after_receipt), do: :recorded
 def classify(_), do: :unknown_outcome
end
