defmodule AshA2A.C2.Principal do
 def preserved?(effect,cert,caller), do: effect.principal==caller and cert.principal==caller
end