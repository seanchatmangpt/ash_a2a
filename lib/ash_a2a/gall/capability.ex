defmodule AshA2A.Gall.Capability do
  @moduledoc """
  The closed GALL capability vocabulary (PRD §43.5): exactly

      Read, Write, Edit, Commit, Push, Publish, Deploy, Merge

  The vocabulary is closed. There is no extension point, no registry, and
  no "other" bucket: a capability name outside this set is not a new
  capability, it is a `REFUSED_CAPABILITY` refusal. Openness in a
  capability vocabulary is an escalation primitive -- a name invented by a
  message sender must never resolve into authority.

  Messages carry capabilities as `requires`/`forbids` sets (see
  `AshA2A.Gall.WorkLease`). The child-subset rule lives in
  `AshA2A.Gall.Message.validate/2`: `Capabilities(child) ⊆
  Capabilities(parent)` (PRD §30), enforced only when a parent grant is
  actually presented -- presenting evidence is the receiver's job, not the
  sender's.

  Wire spelling is the capitalized label (`"Push"`); the Elixir side uses
  lowercase atoms (`:push`).
  """

  @labels ["Read", "Write", "Edit", "Commit", "Push", "Publish", "Deploy", "Merge"]
  @pairs @labels |> Enum.zip(~w(read write edit commit push publish deploy merge)a) |> Map.new()

  @type t :: :read | :write | :edit | :commit | :push | :publish | :deploy | :merge

  @doc "The full closed vocabulary as Elixir atoms."
  @spec all() :: [t()]
  def all, do: @labels |> Enum.map(&Map.fetch!(@pairs, &1))

  @doc "The full closed vocabulary as wire labels, in canonical order."
  @spec labels() :: [String.t()]
  def labels, do: @labels

  @doc """
  True when `value` is a member of the closed vocabulary (atom or exact
  wire label). No normalization, no downcasing aliasing: `"push"` the
  string is NOT the capability `"Push"`.
  """
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_atom(value), do: value in Map.values(@pairs)
  def valid?(value) when is_binary(value), do: value in @labels
  def valid?(_other), do: false

  @doc """
  Decodes a wire label or atom to the canonical atom, or `:error`.

      iex> AshA2A.Gall.Capability.decode("Push")
      {:ok, :push}
      iex> AshA2A.Gall.Capability.decode(:push)
      {:ok, :push}
      iex> AshA2A.Gall.Capability.decode("Transmute")
      :error
  """
  @spec decode(term()) :: {:ok, t()} | :error
  def decode(value) when is_binary(value) do
    case Map.fetch(@pairs, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> :error
    end
  end

  def decode(value) when is_atom(value) do
    if value in Map.values(@pairs), do: {:ok, value}, else: :error
  end

  def decode(_other), do: :error

  @doc "Decodes a whole list, failing closed on the first non-member."
  @spec decode_all(term()) :: {:ok, [t()]} | :error
  def decode_all(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case decode(value) do
        {:ok, atom} -> {:cont, {:ok, [atom | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  def decode_all(_other), do: :error

  @doc "Encodes a capability atom to its wire label, or `:error`."
  @spec encode(term()) :: {:ok, String.t()} | :error
  def encode(atom) when is_atom(atom) do
    case Enum.find(@pairs, fn {_label, value} -> value == atom end) do
      {label, _value} -> {:ok, label}
      nil -> :error
    end
  end

  def encode(_other), do: :error
end
