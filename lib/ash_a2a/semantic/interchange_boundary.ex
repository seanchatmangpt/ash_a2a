defmodule AshA2A.Semantic.InterchangeBoundary do
  @moduledoc false
  @required [:subject, :contract, :projection, :runtime, :technical_standing, :external_standing, :runtime_authority]
  defstruct @required

  def complete?(%__MODULE__{} = boundary),
    do: Enum.all?(@required, fn field -> present?(Map.fetch!(boundary, field)) end)

  def complete?(_), do: false
  def authorized?(%__MODULE__{} = boundary), do: complete?(boundary)
  def authorized?(_), do: false

  def standing_separated?(%__MODULE__{} = b),
    do: b.technical_standing != b.external_standing and b.technical_standing != b.runtime_authority and b.external_standing != b.runtime_authority

  def standing_separated?(_), do: false
  def admit?(%__MODULE__{} = boundary), do: complete?(boundary) and standing_separated?(boundary)
  def admit?(_), do: false

  def portable_identity(%__MODULE__{} = b),
    do: digest({b.subject, b.contract, b.projection, b.runtime})

  def replay_identity(%__MODULE__{} = b),
    do: digest({portable_identity(b), b.technical_standing, b.external_standing, b.runtime_authority})

  def stale_subject?(%__MODULE__{subject: subject}, observed), do: not present?(subject) or subject != observed
  def stale_subject?(_, _), do: true

  def projection_matches?(%__MODULE__{projection: projection}, observed), do: present?(projection) and projection == observed
  def projection_matches?(_, _), do: false

  def runtime_matches?(%__MODULE__{runtime: runtime}, observed), do: present?(runtime) and runtime == observed
  def runtime_matches?(_, _), do: false

  def authority_for?(%__MODULE__{} = b, authority), do: admit?(b) and b.runtime_authority == authority
  def authority_for?(_, _), do: false

  defp digest(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic])) |> Base.encode16(case: :lower)
  defp present?(value), do: value not in [nil, "", false]
end
