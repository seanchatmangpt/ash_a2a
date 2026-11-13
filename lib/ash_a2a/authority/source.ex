# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.Source do
  @moduledoc """
  Pluggable standing source for `AshA2A.Authority.PEP`.

  One callback:

      @callback check(actor_id, action :: String.t(), context, opts :: keyword()) ::
                  :ok | {:ok, extra :: term()} | :deny | {:deny, reason :: term()}

  Sources MUST be fail-closed: any unexpected return is treated as a typed
  refusal by the PEP (reason `:invalid_source_return`), never as admission.
  """

  @callback check(term(), String.t(), term(), keyword()) ::
              :ok | {:ok, term()} | :deny | {:deny, term()}

  @doc "Refusal-vocabulary surface for architecture scanners."
  def __sa2a_refusal_codes__,
    do: %{insufficient_authority: :refused_authority, invalid_source_return: :refused_meta_rigor}

  @doc """
  Resolve a configured source into `{:ok, {module, opts}}` or a typed
  `{:error, :invalid_source}` (nil, strings, `{mod}`, `{mod, non_list}`, ...).
  Single implementation shared with `AshA2A.Authority.PEP`.
  """
  @spec resolve(term()) :: {:ok, {module(), keyword()}} | {:error, :invalid_source}
  def resolve({mod, opts}) when is_atom(mod) and not is_nil(mod) and is_list(opts),
    do: {:ok, {mod, opts}}

  def resolve(mod) when is_atom(mod) and not is_nil(mod) and not is_boolean(mod),
    do: {:ok, {mod, []}}

  def resolve(_other), do: {:error, :invalid_source}
end
