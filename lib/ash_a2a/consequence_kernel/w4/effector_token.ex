defmodule AshA2A.ConsequenceKernel.W4.EffectorToken do
  @moduledoc false
  @enforce_keys [:exact_subject, :prepared_digest]
  defstruct [:exact_subject, :prepared_digest]
  def mint(subject, digest) when is_binary(subject) and is_binary(digest),
    do: %__MODULE__{exact_subject: subject, prepared_digest: digest}
end
