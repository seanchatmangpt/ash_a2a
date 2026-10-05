# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.AuthorityClient do
  @callback authorize(AshA2A.C2.AuthorityRequest.t() | map(), map()) ::
              {:ok, term()} | {:error, term()}
  def authorize(client, request, ctx) when is_atom(client), do: client.authorize(request, ctx)
end
