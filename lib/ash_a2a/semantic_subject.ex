defmodule AshA2A.SemanticSubject do
  @moduledoc """
  Exact semantic/manufacture identity bound to an A2A command.

  This is evidence identity only. It grants no capability and no authority.
  A command may carry the subject so retries/replay are scoped to the exact
  semantic graph and generated projection that produced the capability
  surface in use.
  """

  @enforce_keys [:graph_digest, :projection_digest, :manufacturer_digest]
  defstruct [:graph_digest, :projection_digest, :manufacturer_digest, ephemeral?: true]

  @type t :: %__MODULE__{
          graph_digest: String.t(),
          projection_digest: String.t(),
          manufacturer_digest: String.t(),
          ephemeral?: boolean()
        }

  @type refusal :: {:refused_semantic_subject, atom()}

  @spec new(keyword()) :: {:ok, t()} | {:error, refusal()}
  def new(opts) when is_list(opts) do
    subject = %__MODULE__{
      graph_digest: Keyword.fetch!(opts, :graph_digest),
      projection_digest: Keyword.fetch!(opts, :projection_digest),
      manufacturer_digest: Keyword.fetch!(opts, :manufacturer_digest),
      ephemeral?: Keyword.get(opts, :ephemeral?, true)
    }

    with :ok <- digest(:graph_digest, subject.graph_digest),
         :ok <- digest(:projection_digest, subject.projection_digest),
         :ok <- digest(:manufacturer_digest, subject.manufacturer_digest) do
      {:ok, subject}
    end
  end

  @spec fingerprint_token(t() | nil) :: tuple() | nil
  def fingerprint_token(nil), do: nil

  def fingerprint_token(%__MODULE__{} = subject) do
    {
      subject.graph_digest,
      subject.projection_digest,
      subject.manufacturer_digest,
      subject.ephemeral?
    }
  end

  defp digest(field, "sha256:" <> hex) when byte_size(hex) == 64 do
    if String.match?(hex, ~r/\A[0-9a-f]{64}\z/) do
      :ok
    else
      {:error, {:refused_semantic_subject, field}}
    end
  end

  defp digest(field, _), do: {:error, {:refused_semantic_subject, field}}
end
