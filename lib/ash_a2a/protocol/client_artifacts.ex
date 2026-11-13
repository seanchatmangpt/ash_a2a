defmodule AshA2A.Protocol.ClientArtifacts do
  @moduledoc """
  A2A v1.1.0 request-side helpers: `ifGenerationMatch`, client-written
  `artifactUpdates` (capability `user_artifacts`) and the long-poll deadline.

  Pure functions returning tagged errors so every transport can map them:

    * `{:error, :generation_mismatch}` -> `-32010` / HTTP 409 / gRPC ABORTED
    * `{:error, {:unsupported_operation, :user_artifacts}}` -> `-32004`
  """

  alias AshA2A.Protocol.{Artifact, Task}
  alias AshA2A.Protocol.JSONRPC.Error

  @doc """
  `ifGenerationMatch` check against an existing task. `nil` expected, or a
  task that does not exist yet (`nil`), always passes.
  """
  @spec check_generation(Task.t() | nil, non_neg_integer() | nil) ::
          :ok | {:error, :generation_mismatch}
  def check_generation(nil, _expected), do: :ok
  def check_generation(_task, nil), do: :ok

  def check_generation(task, expected) do
    if Task.Generation.matches?(task, expected), do: :ok, else: {:error, :generation_mismatch}
  end

  @doc "Whether the card declares `capabilities.user_artifacts == true`."
  @spec user_artifacts?(map() | struct() | nil) :: boolean()
  def user_artifacts?(card) do
    case fetch(card, :capabilities) do
      nil -> false
      caps -> fetch(caps, :user_artifacts) == true or fetch(caps, :userArtifacts) == true
    end
  end

  @doc "`:ok` when updates are empty or the card allows them."
  @spec check_user_artifacts(map() | struct() | nil, list()) ::
          :ok | {:error, {:unsupported_operation, :user_artifacts}}
  def check_user_artifacts(_card, []), do: :ok

  def check_user_artifacts(card, _updates) do
    if user_artifacts?(card), do: :ok, else: {:error, {:unsupported_operation, :user_artifacts}}
  end

  @doc "Maps the tagged errors above to `Error` structs."
  @spec to_error(term(), keyword()) :: Error.t() | nil
  def to_error(reason, opts \\ [])

  def to_error(:generation_mismatch, opts), do: Error.task_generation_mismatch(nil, opts)

  def to_error({:unsupported_operation, :user_artifacts}, _opts),
    do: Error.unsupported_operation("userArtifacts capability is not declared")

  def to_error(_other, _opts), do: nil

  @doc """
  Decodes wire `artifactUpdates` into `[{artifact, append?, last_chunk?}]`.
  Any client-supplied `generation` is dropped by construction.
  """
  @spec decode_updates([map()]) ::
          {:ok, [{Artifact.t(), boolean(), boolean() | nil}]} | {:error, term()}
  def decode_updates(updates) when is_list(updates) do
    Enum.reduce_while(updates, {:ok, []}, fn update, {:ok, acc} ->
      with %{} = artifact_map <- update["artifact"],
           {:ok, artifact} <- AshA2A.Protocol.JSON.decode(artifact_map, :artifact) do
        {:cont, {:ok, [{artifact, update["append"] == true, update["lastChunk"]} | acc]}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :invalid_artifact_update}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc """
  Applies decoded updates to `task` in list order. The artifact is stamped
  `role: :user`, any client generation fields are reset, and
  `Task.Generation.record_artifact/3` assigns the authoritative generation.
  `append` merges parts into the existing artifact with the same id.
  """
  @spec apply_updates(Task.t(), [{Artifact.t(), boolean(), boolean() | nil}]) :: Task.t()
  def apply_updates(task, decoded) do
    Enum.reduce(decoded, task, fn {artifact, append?, last_chunk}, acc ->
      artifact = %{artifact | start_generation: nil, end_generation: nil, role: :user}

      # record_artifact/3 merges a chunk into the artifact with the same id.
      completed? = last_chunk != false and (not append? or last_chunk == true)
      {acc, _recorded} = Task.Generation.record_artifact(acc, artifact, completed?)
      acc
    end)
  end

  @doc "Long-poll deadline in ms (`config :ash_a2a, :long_poll_timeout_ms`, default 30_000)."
  @spec long_poll_timeout_ms() :: non_neg_integer()
  def long_poll_timeout_ms do
    case Application.get_env(:ash_a2a, :long_poll_timeout_ms, 30_000) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> 30_000
    end
  end

  @doc """
  Caps a per-call long-poll wait at the configured maximum:
  `min(requested, long_poll_timeout_ms())`. A nil or invalid request yields the configured value.
  """
  @spec long_poll_timeout_ms(term()) :: non_neg_integer()
  def long_poll_timeout_ms(requested) when is_integer(requested) and requested >= 0,
    do: min(requested, long_poll_timeout_ms())

  def long_poll_timeout_ms(_), do: long_poll_timeout_ms()

  defp fetch(nil, _key), do: nil
  defp fetch(%{} = map, key), do: Map.get(map, key)
  defp fetch(_, _), do: nil
end
