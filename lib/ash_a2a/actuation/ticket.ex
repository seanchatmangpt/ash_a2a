# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Actuation.Ticket do
  @moduledoc """
  Content-addressed obligation ticket for the Sovereign Actuation Engine.

  A ticket is an immutable obligation to perform exactly one actuation
  (`action_iri` over `payload`). Its `id` is the sha256 (hex) of the canonical
  serialization of its fields, so tampering with any field invalidates the
  identity itself: the Engine recomputes the digest at `submit/3` and refuses
  a mismatch as `{:refused, :tampered_ticket}`.

  Mint via `AshA2A.Actuation.Ticket.Mint.ticket/2`; never build the struct
  by hand.
  """

  defstruct [:id, :action_iri, :payload, :issued_by, :issued_at, :correlation]

  @enforce_keys [:id, :action_iri, :payload, :issued_by, :issued_at, :correlation]

  @type correlation :: %{run_id: term(), step_ref: term()}

  @type t :: %__MODULE__{
          id: String.t(),
          action_iri: String.t(),
          payload: term(),
          issued_by: term(),
          issued_at: integer(),
          correlation: correlation()
        }

  defmodule Mint do
    @moduledoc """
    Constructor for `AshA2A.Actuation.Ticket`: derives the content address.

    `fields` map requires `:action_iri`, `:payload`, `:issued_by`,
    `:correlation` (`%{run_id:, step_ref:}`). `:issued_at` may be pinned via
    opts (unix seconds) for deterministic tests; defaults to
    `System.system_time(:second)`.
    """

    alias AshA2A.Actuation.Ticket

    @canonical_keys [:action_iri, :payload, :issued_by, :issued_at, :correlation]

    @spec ticket(map(), Keyword.t()) :: Ticket.t()
    def ticket(fields, opts \\ []) when is_map(fields) do
      issued_at = Keyword.get(opts, :issued_at, System.system_time(:second))

      base = %{
        action_iri: Map.fetch!(fields, :action_iri),
        payload: Map.fetch!(fields, :payload),
        issued_by: Map.fetch!(fields, :issued_by),
        issued_at: issued_at,
        correlation: Map.fetch!(fields, :correlation)
      }

      %Ticket{id: digest(base), action_iri: base.action_iri, payload: base.payload,
              issued_by: base.issued_by, issued_at: issued_at,
              correlation: base.correlation}
    end

    @doc """
    Recomputes the content address for a ticket's fields. Used by the Engine
    to detect tampering; canonical serialization must match Mint's.
    """
    @spec digest(Ticket.t() | map()) :: String.t()
    def digest(%Ticket{} = t) do
      digest(%{action_iri: t.action_iri, payload: t.payload, issued_by: t.issued_by,
               issued_at: t.issued_at, correlation: t.correlation})
    end

    def digest(fields) when is_map(fields) do
      canonical =
        @canonical_keys
        |> Enum.map(&{&1, stable(Map.fetch!(fields, &1))})
        |> :erlang.term_to_binary()

      :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
    end

    defp stable(term), do: stable(term, 0)

    defp stable(%{__struct__: _} = s, depth), do: stable(Map.from_struct(s), depth)
    defp stable(%{} = m, depth) when depth < 8 do
      m |> Enum.map(fn {k, v} -> {stable(k, depth + 1), stable(v, depth + 1)} end)
        |> Enum.sort()
    end
    defp stable(m, _depth) when is_map(m), do: Enum.sort(Map.to_list(m))
    defp stable(l, depth) when is_list(l) and depth < 8, do: Enum.map(l, &stable(&1, depth + 1))
    defp stable(l, _depth) when is_list(l), do: l
    defp stable(other, _depth), do: other
  end
end
