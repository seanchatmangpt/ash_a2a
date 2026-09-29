defmodule AshA2A.C2.FencingToken do
 def valid?(cert,current) when is_integer(current), do: cert.generation>=current
end