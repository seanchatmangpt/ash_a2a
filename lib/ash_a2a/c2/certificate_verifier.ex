defmodule AshA2A.C2.CertificateVerifier do
 def verify(c,e,ctx) do
  with :ok<-AshA2A.C2.CompleteMediation.admit(e,c,ctx), true<-Enum.all?(c.signatures,fn s->AshA2A.C2.CryptoVerifier.supported?(s.algorithm) end), do: :ok, else: (_->{:error,:certificate_refused})
 end
end