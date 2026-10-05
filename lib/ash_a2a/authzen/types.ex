# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthZEN.Types do
  @moduledoc """
  Lossless internal projection of OpenID AuthZEN Authorization API 1.0 SARC values.
  These values are policy inputs/outputs, never ActuationCertificates.
  """

  defmodule Entity do
    @enforce_keys [:type, :id]
    defstruct [:type, :id, properties: %{}]
  end

  defmodule Action do
    @enforce_keys [:name]
    defstruct [:name, properties: %{}]
  end

  defmodule Request do
    @enforce_keys [:subject, :action, :resource]
    defstruct [:subject, :action, :resource, context: %{}]
  end

  defmodule Decision do
    @enforce_keys [:decision]
    defstruct [:decision, context: %{}, source: nil, observed_at: nil]

    @type t :: %__MODULE__{
            decision: boolean(),
            context: map(),
            source: term(),
            observed_at: integer() | nil
          }
  end
end
