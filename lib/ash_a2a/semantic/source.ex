defmodule AshA2A.Semantic.Source do
  @moduledoc """
  Immutable source material for semantic compilation.

  A source is evidence, not executable authority. Its identity is content-based
  so the same admitted input can be replayed without manufacturing a new
  semantic subject.
  """

  @enforce_keys [:id, :text, :media_type, :provenance]
  defstruct [:id, :text, :media_type, :observed_at, :provenance]

  @type t :: %__MODULE__{
          id: String.t(),
          text: String.t(),
          media_type: String.t(),
          observed_at: DateTime.t() | nil,
          provenance: map()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(text, opts \\ []) when is_binary(text) do
    media_type = Keyword.get(opts, :media_type, "text/plain")
    provenance = Keyword.get(opts, :provenance, %{})

    id =
      Keyword.get_lazy(opts, :id, fn ->
        fingerprint({media_type, provenance, text})
      end)

    %__MODULE__{
      id: to_string(id),
      text: text,
      media_type: media_type,
      observed_at: Keyword.get(opts, :observed_at),
      provenance: provenance
    }
  end

  @spec uri(t()) :: String.t()
  def uri(%__MODULE__{id: id}), do: "urn:ash-a2a:source:#{id}"

  defp fingerprint(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
