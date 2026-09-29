defmodule Actuator.Effector.NoopProbe do
  @moduledoc "A probe effect: passes the whole fence and claim path, performs no consequence."
  @behaviour Actuator.EffectorRegistry

  @impl true
  def validate_params(p) when p == %{}, do: :ok
  def validate_params(_), do: :error

  @impl true
  def size(_), do: 0

  @impl true
  def perform(_handles, _effect, _digest), do: {:ok, %{}}
end
