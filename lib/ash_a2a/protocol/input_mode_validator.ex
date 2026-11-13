defmodule AshA2A.Protocol.InputModeValidator do
  @moduledoc """
  Media-type admission for `message/send`.

  * `validate_input/3` checks every part of an inbound message against the
    agent card's `default_input_modes` (or the named skill's `input_modes`
    when the skill is known) and answers `ContentTypeNotSupported` (-32005)
    for a part the agent cannot consume.
  * `apply_output_modes/3` enforces `SendMessageConfiguration.accepted_output_modes`
    on a task's artifacts: parts outside the accepted set are dropped
    (`:filter`, default) or the whole result is refused (`:refuse`).

  Both are opt-out: pass `validate_input_modes: false` / an empty or `nil`
  accepted-mode list to skip. Media types compare case-insensitively with
  parameters (`;charset=...`) stripped; `type/*` and `*/*` wildcards match.
  """

  alias AshA2A.Protocol.{Artifact, Message, Part, Task}
  alias AshA2A.Protocol.JSONRPC.Error

  @type card :: map() | struct() | nil

  @doc """
  Validates `message` parts against the card's accepted input modes.

  Options: `:skill_id` (use that skill's `input_modes` when present),
  `:validate_input_modes` (`false` opts out).
  """
  @spec validate_input(Message.t(), card(), keyword()) ::
          :ok | {:error, {:content_type_not_supported, map()}}
  def validate_input(message, card, opts \\ [])

  def validate_input(_message, nil, _opts), do: :ok

  def validate_input(%Message{parts: parts}, card, opts) when is_list(parts) do
    if Keyword.get(opts, :validate_input_modes, true) == false do
      :ok
    else
      case accepted_input_modes(card, Keyword.get(opts, :skill_id)) do
        [] ->
          :ok

        modes ->
          case Enum.find(parts, &(not part_allowed?(&1, modes))) do
            nil ->
              :ok

            part ->
              {:error,
               {:content_type_not_supported,
                %{mediaType: part_media_type(part), acceptedInputModes: modes}}}
          end
      end
    end
  end

  def validate_input(_message, _card, _opts), do: :ok

  @doc """
  Applies `accepted_output_modes` to a task's artifacts.

  `strategy: :filter` (default) drops disallowed parts and any artifact left
  empty; `strategy: :refuse` returns
  `{:error, {:content_type_not_supported, _}}` when anything would be dropped.
  A `nil`/empty mode list leaves the task untouched. Non-task replies pass
  through.
  """
  @spec apply_output_modes(term(), [String.t()] | nil, keyword()) ::
          {:ok, term()} | {:error, {:content_type_not_supported, map()}}
  def apply_output_modes(result, modes, opts \\ [])
  def apply_output_modes(result, nil, _opts), do: {:ok, result}
  def apply_output_modes(result, [], _opts), do: {:ok, result}

  def apply_output_modes(%Task{artifacts: artifacts} = task, modes, opts)
      when is_list(artifacts) do
    filtered =
      artifacts
      |> Enum.map(fn %Artifact{parts: parts} = artifact ->
        %{artifact | parts: Enum.filter(parts, &part_allowed?(&1, modes))}
      end)
      |> Enum.reject(&(&1.parts == []))

    dropped? = filtered != artifacts

    cond do
      not dropped? ->
        {:ok, task}

      Keyword.get(opts, :strategy, :filter) == :refuse ->
        {:error, {:content_type_not_supported, %{acceptedOutputModes: modes}}}

      true ->
        {:ok, %{task | artifacts: filtered}}
    end
  end

  def apply_output_modes(result, _modes, _opts), do: {:ok, result}

  @doc "Converts a validator refusal to the JSON-RPC -32005 error."
  @spec to_error({:content_type_not_supported, map()}) :: Error.t()
  def to_error({:content_type_not_supported, data}), do: Error.content_type_not_supported(data)

  @doc "Effective accepted input modes for a card (+ optional skill id)."
  @spec accepted_input_modes(card(), String.t() | nil) :: [String.t()]
  def accepted_input_modes(card, skill_id) do
    skill_modes =
      if is_binary(skill_id) do
        card
        |> Map.get(:skills, [])
        |> List.wrap()
        |> Enum.find(&(Map.get(&1, :id) == skill_id))
        |> case do
          nil -> nil
          skill -> Map.get(skill, :input_modes)
        end
      end

    case skill_modes do
      modes when is_list(modes) and modes != [] -> modes
      # A card that omits `default_input_modes` advertises the AgentCard
      # default (`["text/plain"]`); an explicit `[]`/`nil` still opts out.
      _ -> List.wrap(Map.get(card, :default_input_modes, ["text/plain"]))
    end
  end

  # -- private ---------------------------------------------------------------

  defp part_allowed?(part, modes) do
    case part_media_type(part) do
      nil -> true
      type -> Enum.any?(modes, &mode_matches?(&1, type))
    end
  end

  # A part without an explicit media type is "unspecified" and always admitted;
  # only an explicit mediaType can be refused.
  defp part_media_type(%Part.Text{media_type: mt}), do: normalize(mt)
  defp part_media_type(%Part.Data{media_type: mt}), do: normalize(mt)
  defp part_media_type(%Part.File{file: %{mime_type: mt}}), do: normalize(mt)
  defp part_media_type(_), do: nil

  defp normalize(mt) when is_binary(mt) and mt != "" do
    mt |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
  end

  defp normalize(_), do: nil

  defp mode_matches?(mode, type) when is_binary(mode) do
    case normalize(mode) do
      nil -> false
      "*/*" -> true
      ^type -> true
      pattern -> wildcard_match?(pattern, type)
    end
  end

  defp mode_matches?(_, _), do: false

  defp wildcard_match?(pattern, type) do
    case String.split(pattern, "/", parts: 2) do
      [major, "*"] -> String.starts_with?(type, major <> "/")
      _ -> false
    end
  end
end
