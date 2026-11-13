# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.GraphPin do
  @moduledoc """
  Persistent graph-digest pin seam for the HILT work-order plane (lane Z12).

  `AshA2A.Hilt.WorkOrder.checkpoint_graph_digest/2` compares the carried
  graph digest against the executing command's semantic subject inline at
  admission — a stateless, per-call check. This module adds the missing
  half: a persistent, order-keyed pin so freshness is asserted against the
  digest pinned AT ADMISSION, not merely against whatever the order carries
  at actuation time.

  Contract (operator-specified vocabulary):

      pin = GraphPin.pin(order_id, digest)              # at admit
      :ok = GraphPin.assert_fresh(order_id, digest)     # at actuation, unchanged
      {:error, :stale_graph_identity} =
        GraphPin.assert_fresh(order_id, mutated_digest) # graph moved under the order
      :ok = GraphPin.pin(order_id, new_digest)          # re-pin recovers

  This is the ASH_A2A-SIDE seam only. Digest PRODUCTION — hashing the
  work-order / semantic-subject graph itself — lives where those graphs are
  built: `AshA2A.Hilt.WorkOrder.for_command!/3` carries the subject's
  graph_digest via `AshA2A.SemanticSubject` (production), and
  `AshA2A.Actuation.digest/1` is the canonical hash function. GraphPin
  stores and compares digests; it never computes them and never grants
  authority.

  STATUS: currently UNCONSUMED by `AshA2A.Authority.PEP`
  (`PEP.pin_graph_digest/2` is a stateless `WorkOrder.identity_digest/1`
  passthrough and ignores opts). GraphPin is a standalone seam.

  State is a pure map by default (`AshA2A.Authority.GraphPin.Store.Memory`)
  behind the `AshA2A.Authority.GraphPin.Store` behaviour; pass
  `store: MyStore` to `pin/4` / `assert_fresh/3` to plug a durable backend.
  """

  defmodule Store do
    @moduledoc """
    Behaviour for graph-pin persistence. Keys are work-order ids; values are
    `"sha256:" <> 64-hex` digest strings.
    """

    @callback get(order_id :: String.t()) :: String.t() | nil
    @callback put(order_id :: String.t(), digest :: String.t()) :: :ok | {:error, term()}
  end

  defmodule Store.Memory do
    @moduledoc """
    Default in-process pin store. Pure map state wrapped in an Agent so the
    same default works from concurrent callers; use a real store in
    production.
    """

    @behaviour Store

    name = __MODULE__
    defstruct pins: %{}

    @doc "Starts the default store (idempotent)."
    def start_link(_opts \\ []) do
      case Agent.start_link(fn -> %__MODULE__{} end, name: unquote(name)) do
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end
    end

    @impl Store
    def get(order_id) do
      ensure_started()
      Agent.get(unquote(name), fn %__MODULE__{pins: pins} -> Map.get(pins, order_id) end)
    end

    @impl Store
    def put(order_id, digest) do
      ensure_started()

      Agent.update(unquote(name), fn %__MODULE__{pins: pins} = state ->
        %{state | pins: Map.put(pins, order_id, digest)}
      end)
    end

    defp ensure_started do
      case Process.whereis(unquote(name)) do
        nil ->
          case start_link() do
            {:ok, _} -> :ok
            {:error, {:already_started, _}} -> :ok
          end

        _pid ->
          :ok
      end
    end
  end

  @default_store AshA2A.Authority.GraphPin.Store.Memory
  @digest_format ~r/\Asha256:[0-9a-f]{64}\z/

  @doc """
  Pins `digest` as the admitted graph identity for `order_id`. Overwrites any
  prior pin (re-pin is the recovery path after a legitimate graph change).
  """
  @spec pin(term(), term(), keyword()) ::
          :ok | {:error, :invalid_digest | :invalid_order_id | {:store_error, term()}}
  def pin(order_id, digest, opts \\ []) do
    store = Keyword.get(opts, :store, @default_store)

    cond do
      not (is_binary(order_id) and order_id != "") ->
        {:error, :invalid_order_id}

      not (is_binary(digest) and digest =~ @digest_format) ->
        {:error, :invalid_digest}

      true ->
        case store.put(order_id, digest) do
          :ok -> :ok
          {:error, reason} -> {:error, {:store_error, reason}}
          other -> {:error, {:store_error, {:invalid_return, other}}}
        end
    end
  end

  @doc """
  Asserts `current_digest` matches the digest pinned at admission for
  `order_id`. Refuses {:error, :stale_graph_identity} when the graph moved
  under the order, {:error, :unpinned} when no pin exists (fail-closed:
  actuation of a never-admitted order is not fresh by definition).
  """
  @spec assert_fresh(term(), term(), keyword()) ::
          :ok
          | {:error, :stale_graph_identity | :unpinned | :invalid_digest | :invalid_order_id}
  def assert_fresh(order_id, current_digest, opts \\ [])

  def assert_fresh(order_id, _current_digest, _opts)
      when not is_binary(order_id) or order_id == "",
      do: {:error, :invalid_order_id}

  def assert_fresh(order_id, current_digest, opts) do
    store = Keyword.get(opts, :store, @default_store)

    case store.get(order_id) do
      nil ->
        {:error, :unpinned}

      pinned ->
        cond do
          not is_binary(current_digest) or not (current_digest =~ @digest_format) ->
            {:error, :invalid_digest}

          pinned == current_digest ->
            :ok

          true ->
            {:error, :stale_graph_identity}
        end
    end
  end
end
