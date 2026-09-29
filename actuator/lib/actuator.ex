defmodule Actuator do
  @moduledoc """
  Minimal, unintelligent actuator (RFC-SA2A-006 s7.5 / s16).

  `execute/4` parses a typed PreparedEffect (canonical JSON, total schema) and an
  actuation certificate, then hands them to `Actuator.Store`, which performs the 16-check
  fence and exactly one typed effect in one atomic durable transition. Verification plus
  narrowly bounded execution only: no shell, no URL/path/MFA in requests, no LLM, no planner.
  """
  alias Actuator.{Fence, Store}

  @spec execute(GenServer.server(), Actuator.Context.t(), binary(), binary()) ::
          {:ok, %{status: :performed | :replayed, evidence: map()}}
          | {:error, pos_integer() | atom(), atom()}
  def execute(store, ctx, effect_bytes, cert_bytes) do
    case Fence.parse(effect_bytes, cert_bytes) do
      {:ok, req} -> Store.execute(store, ctx, req)
      {:error, code} -> {:error, :parse, code}
    end
  end
end
