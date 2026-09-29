defmodule AshA2A.C2.PreparedEffect do
  @moduledoc """
  Powerless, portable description of a proposed protected effect.

  Identity is SHA-256 over RFC 8785/JCS canonical bytes, never Erlang external
  term format. The canonical view contains only JSON-domain values so another
  runtime can recompute the same digest without BEAM knowledge.
  """

  alias AshA2A.Identity.Canonical

  @enforce_keys [:principal, :capability, :subject, :payload, :digest]
  defstruct [:version | @enforce_keys]

  @version 1

  @spec build(term(), term(), term(), term()) :: {:ok, t()} | {:error, atom()}
  def build(principal, capability, subject, payload) do
    with {:ok, portable_subject} <- portable(subject),
         {:ok, portable_payload} <- portable(payload),
         canonical = %{
           "version" => @version,
           "principal" => to_string(principal),
           "capability" => to_string(capability),
           "subject" => portable_subject,
           "payload" => portable_payload
         },
         {:ok, digest} <- Canonical.digest(canonical) do
      {:ok,
       %__MODULE__{
         version: @version,
         principal: principal,
         capability: capability,
         subject: subject,
         payload: payload,
         digest: digest
       }}
    end
  end

  @spec new(term(), term(), term(), term()) :: t()
  def new(principal, capability, subject, payload) do
    case build(principal, capability, subject, payload) do
      {:ok, effect} -> effect
      {:error, reason} -> raise ArgumentError, "non-portable PreparedEffect: #{inspect(reason)}"
    end
  end

  @spec portable_view(t()) :: {:ok, map()} | {:error, atom()}
  def portable_view(%__MODULE__{} = effect) do
    with {:ok, subject} <- portable(effect.subject),
         {:ok, payload} <- portable(effect.payload) do
      {:ok,
       %{
         "version" => effect.version || @version,
         "principal" => to_string(effect.principal),
         "capability" => to_string(effect.capability),
         "subject" => subject,
         "payload" => payload
       }}
    end
  end

  defp portable(nil), do: {:ok, nil}

  defp portable(v) when is_boolean(v) or is_integer(v) or is_float(v) or is_binary(v),
    do: {:ok, v}

  defp portable(v) when is_atom(v), do: {:ok, Atom.to_string(v)}

  defp portable(v) when is_list(v) do
    Enum.reduce_while(v, {:ok, []}, fn item, {:ok, acc} ->
      case portable(item) do
        {:ok, p} -> {:cont, {:ok, [p | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, xs} -> {:ok, Enum.reverse(xs)}
      error -> error
    end
  end

  defp portable(v) when is_map(v) do
    Enum.reduce_while(v, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if is_binary(key) or is_atom(key) do
        case portable(value) do
          {:ok, p} -> {:cont, {:ok, Map.put(acc, to_string(key), p)}}
          {:error, _} = error -> {:halt, error}
        end
      else
        {:halt, {:error, :canonical_key_type_forbidden}}
      end
    end)
  end

  defp portable(_), do: {:error, :canonical_type_forbidden}

  @type t :: %__MODULE__{
          version: pos_integer(),
          principal: term(),
          capability: term(),
          subject: term(),
          payload: term(),
          digest: binary()
        }
end
