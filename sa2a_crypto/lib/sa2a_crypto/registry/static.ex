defmodule Sa2aCrypto.Registry.Static do
  @moduledoc "Static in-memory registry view (tests and fixtures)."
  @behaviour Sa2aCrypto.Registry
  alias Sa2aCrypto.KeyRecord

  @spec view([KeyRecord.t()]) :: {module(), %{String.t() => KeyRecord.t()}}
  def view(records), do: {__MODULE__, Map.new(records, &{&1.kid, &1})}

  @impl true
  def lookup(map, kid), do: Map.fetch(map, kid)
end
