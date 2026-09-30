defmodule AshA2A.AuthZEN.Types do
  @moduledoc """
  Lossless internal projection of OpenID AuthZEN Authorization API 1.0 SARC values.
  These values are policy inputs/outputs, never ActuationCertificates.
  """
  defmodule Entity do
    @enforce_keys [:type, :id]
    defstruct [:type, :id, properties: %{}]
  end
  defmodule Request do
    @enforce_keys [:subject, :action, :resource]
    defstruct [:subject, :action, :resource, context: %{}]
  end
  defmodule Decision do
    @enforce_keys [:decision]
    defstruct [:decision, context: %{}, source: nil, observed_at: nil]
  end
end
