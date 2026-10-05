# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4.EffectorToken do
  @moduledoc false
  @enforce_keys [:exact_subject, :prepared_digest]
  defstruct [:exact_subject, :prepared_digest]

  def mint(subject, digest) when is_binary(subject) and is_binary(digest),
    do: %__MODULE__{exact_subject: subject, prepared_digest: digest}
end
