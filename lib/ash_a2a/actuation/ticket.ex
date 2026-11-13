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

    @doc """
    Mint a ticket; raises `ArgumentError` on invalid fields (see `new/2`).
    """
    @spec ticket(map(), Keyword.t()) :: Ticket.t()
    def ticket(fields, opts \\ []) when is_map(fields) do
      case new(fields, opts) do
        {:ok, t} -> t
        {:error, reason} -> raise ArgumentError, "invalid ticket: #{inspect(reason)}"
      end
    end

    @doc """
    Validating constructor.

        iex> alias AshA2A.Actuation.Ticket.Mint
        iex> {:ok, t} = Mint.new(%{action_iri: "urn:x", payload: 1, issued_by: "a",
        ...>   correlation: %{run_id: 1, step_ref: 2}}, issued_at: 5)
        iex> byte_size(t.id)
        64
        iex> Mint.new(%{action_iri: "", payload: 1, issued_by: "a",
        ...>   correlation: %{run_id: 1, step_ref: 2}})
        {:error, {:invalid_field, :action_iri}}
        iex> Mint.new(%{payload: 1})
        {:error, {:missing_field, :action_iri}}
    """
    @spec new(map(), Keyword.t()) :: {:ok, Ticket.t()} | {:error, term()}
    def new(fields, opts \\ []) when is_map(fields) do
      issued_at = Keyword.get(opts, :issued_at, System.system_time(:second))
      base = Map.put(Map.take(fields, @canonical_keys), :issued_at, issued_at)

      with :ok <- check_present(base),
           :ok <- check_valid(base) do
        {:ok,
         %Ticket{id: digest(base), action_iri: base.action_iri, payload: base.payload,
                 issued_by: base.issued_by, issued_at: issued_at,
                 correlation: base.correlation}}
      end
    end

    defp check_present(base) do
      case Enum.find(@canonical_keys, &(not Map.has_key?(base, &1))) do
        nil -> :ok
        k -> {:error, {:missing_field, k}}
      end
    end

    defp check_valid(b) do
      cond do
        not (is_binary(b.action_iri) and b.action_iri != "") -> {:error, {:invalid_field, :action_iri}}
        is_nil(b.issued_by) -> {:error, {:invalid_field, :issued_by}}
        not is_integer(b.issued_at) -> {:error, {:invalid_field, :issued_at}}
        not (is_map(b.correlation) and Map.has_key?(b.correlation, :run_id) and
                 Map.has_key?(b.correlation, :step_ref)) ->
          {:error, {:invalid_field, :correlation}}
        true -> :ok
      end
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
        |> :erlang.term_to_binary([:deterministic])

      :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
    end

    # Deterministic at any depth; struct name is kept so %A{} and %B{} differ.
    defp stable(%{__struct__: name} = s), do: {:struct, name, stable(Map.from_struct(s))}

    defp stable(%{} = m) do
      m |> Enum.map(fn {k, v} -> {stable(k), stable(v)} end) |> Enum.sort()
    end

    defp stable(l) when is_list(l), do: Enum.map(l, &stable/1)
    defp stable(t) when is_tuple(t), do: {:tuple, t |> Tuple.to_list() |> Enum.map(&stable/1)}
    defp stable(other), do: other
  end
end
