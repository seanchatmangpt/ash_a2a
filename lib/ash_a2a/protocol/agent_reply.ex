defmodule AshA2A.Protocol.AgentReply do
  @moduledoc false
  # Validates the parts an agent handler answers with against the A2A types
  # (Part: text, file, data holding a JSON value). A reply that fails is an
  # InvalidAgentResponseError (-32006): the agent produced something that is
  # not a valid A2A response, which is the agent's fault, not the caller's.

  alias AshA2A.Protocol.Part

  @doc "`:ok`, or `{:error, reason}` naming what is not an A2A part (no secrets)."
  @spec validate_parts(term()) :: :ok | {:error, String.t()}
  def validate_parts(parts) when is_list(parts) do
    Enum.find_value(parts, :ok, fn part ->
      case validate_part(part) do
        :ok -> nil
        {:error, _} = error -> error
      end
    end)
  end

  def validate_parts(_other), do: {:error, "reply parts are not a list"}

  defp validate_part(%Part.Text{text: text}) when is_binary(text), do: :ok
  defp validate_part(%Part.File{file: %AshA2A.Protocol.FileContent{}}), do: :ok

  defp validate_part(%Part.Data{data: data}) do
    case Jason.encode(data) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "data part is not a JSON value"}
    end
  rescue
    _ -> {:error, "data part is not a JSON value"}
  end

  defp validate_part(_other), do: {:error, "reply element is not a Part"}
end
