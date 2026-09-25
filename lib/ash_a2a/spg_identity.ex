defmodule AshA2A.SpgIdentity do
  @moduledoc """
  Stable Semantic Procedural Graph identity carried across SA2A, BRCE, receipts,
  and OCEL projections.

  This is evidence identity only. It grants neither capability nor authority.
  """

  @enforce_keys [:graph_id, :graph_version, :node_id]
  defstruct [:graph_id, :graph_version, :node_id, :edge_id, :projection_family]

  @type t :: %__MODULE__{
          graph_id: String.t(),
          graph_version: String.t(),
          node_id: String.t(),
          edge_id: String.t() | nil,
          projection_family: String.t() | nil
        }

  @type refusal :: {:refused_spg_identity, atom()}

  @spec new(keyword()) :: {:ok, t()} | {:error, refusal()}
  def new(opts) when is_list(opts) do
    identity = %__MODULE__{
      graph_id: Keyword.fetch!(opts, :graph_id),
      graph_version: Keyword.fetch!(opts, :graph_version),
      node_id: Keyword.fetch!(opts, :node_id),
      edge_id: Keyword.get(opts, :edge_id),
      projection_family: Keyword.get(opts, :projection_family)
    }

    with :ok <- non_empty(:graph_id, identity.graph_id),
         :ok <- non_empty(:graph_version, identity.graph_version),
         :ok <- non_empty(:node_id, identity.node_id),
         :ok <- optional_non_empty(:edge_id, identity.edge_id),
         :ok <- optional_non_empty(:projection_family, identity.projection_family) do
      {:ok, identity}
    end
  end

  @spec fingerprint_token(t() | nil) :: tuple() | nil
  def fingerprint_token(nil), do: nil

  def fingerprint_token(%__MODULE__{} = identity) do
    {
      identity.graph_id,
      identity.graph_version,
      identity.node_id,
      identity.edge_id,
      identity.projection_family
    }
  end

  @spec attributes(t() | nil) :: map()
  def attributes(nil), do: %{}

  def attributes(%__MODULE__{} = identity) do
    %{
      spg_graph_id: identity.graph_id,
      spg_graph_version: identity.graph_version,
      spg_node_id: identity.node_id,
      spg_edge_id: identity.edge_id,
      spg_projection_family: identity.projection_family
    }
  end

  defp non_empty(field, value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp non_empty(field, _value), do: {:error, {:refused_spg_identity, field}}

  defp optional_non_empty(_field, nil), do: :ok
  defp optional_non_empty(field, value), do: non_empty(field, value)
end
