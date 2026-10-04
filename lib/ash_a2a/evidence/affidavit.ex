defmodule AshA2A.Evidence.Affidavit do
  @moduledoc """
  Adapter bridging SA2A receipts, process traces, and identity claims
  with the `AshAffidavit` WASM engine (authority NONE, pure evidence).
  """

  @doc "Whether AshAffidavit is available and loaded in the runtime."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(AshAffidavit) and function_exported?(AshAffidavit, :call, 1)
  end

  @doc "Assembles a certified WASM receipt over a list of lifecycle events."
  @spec assemble_receipt([map()]) :: {:ok, map()} | {:error, term()}
  def assemble_receipt(events) when is_list(events) do
    if available?() do
      case AshAffidavit.call(%{"op" => "assemble", "events" => events}) do
        {:ok, res} -> {:ok, res}
        {:refused, ref} -> {:error, {:refused_affidavit, ref}}
        {:trap, trap} -> {:error, {:affidavit_trap, trap}}
        {:unsupported, unsup} -> {:error, {:unsupported_affidavit, unsup}}
        other -> {:error, other}
      end
    else
      {:error, :ash_affidavit_unavailable}
    end
  end

  @doc "Verifies an assembled affidavit receipt."
  @spec verify_receipt(map() | binary()) :: {:ok, boolean()} | {:error, term()}
  def verify_receipt(receipt) do
    if available?() do
      case AshAffidavit.call(%{"op" => "verify", "receipt" => receipt}) do
        {:ok, %{"accepted" => accepted}} -> {:ok, accepted}
        {:refused, ref} -> {:error, {:refused_affidavit, ref}}
        {:trap, trap} -> {:error, {:affidavit_trap, trap}}
        {:unsupported, unsup} -> {:error, {:unsupported_affidavit, unsup}}
        other -> {:error, other}
      end
    else
      {:error, :ash_affidavit_unavailable}
    end
  end

  @doc "Verifies process model conformance over an event trace."
  @spec conform_trace(map(), [map()]) :: {:ok, map()} | {:error, term()}
  def conform_trace(model, trace) do
    if available?() do
      case AshAffidavit.call(%{"op" => "conform", "model" => model, "trace" => trace}) do
        {:ok, res} -> {:ok, res}
        {:refused, ref} -> {:error, {:refused_affidavit, ref}}
        {:trap, trap} -> {:error, {:affidavit_trap, trap}}
        {:unsupported, unsup} -> {:error, {:unsupported_affidavit, unsup}}
        other -> {:error, other}
      end
    else
      {:error, :ash_affidavit_unavailable}
    end
  end
end
