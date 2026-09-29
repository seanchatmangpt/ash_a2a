defmodule AshA2A.C2.PreparedEffect do
  @enforce_keys [:principal, :capability, :subject, :payload, :digest]
  defstruct @enforce_keys

  def new(p, c, s, payload) do
    canonical = {p, c, s, payload}

    d =
      :crypto.hash(:sha256, :erlang.term_to_binary(canonical, [:deterministic]))
      |> Base.encode16(case: :lower)

    %__MODULE__{principal: p, capability: c, subject: s, payload: payload, digest: "sha256:" <> d}
  end
end
