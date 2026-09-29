defmodule Sa2aCrypto.Registry do
  @moduledoc """
  Read-only registry VIEW behaviour. Write side (enrolment, quorum, revocation) is a
  later lane. A view is `{module, state}`; `lookup/2` returns `{:ok, %KeyRecord{}}` or `:error`.
  """
  @callback lookup(state :: term(), kid :: String.t()) ::
              {:ok, Sa2aCrypto.KeyRecord.t()} | :error

  @spec lookup({module(), term()}, term()) :: {:ok, Sa2aCrypto.KeyRecord.t()} | :error
  def lookup({mod, state}, kid) when is_atom(mod) and is_binary(kid), do: mod.lookup(state, kid)
  def lookup(_, _), do: :error
end
