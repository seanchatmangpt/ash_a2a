defmodule AshA2A.Gall.Closure.VocabularyPolicy do
  @moduledoc "Admits only explicit public semantic vocabularies; private/secret vocabularies fail closed."

  def admit(candidate, public_vocabularies) when is_map(candidate) and is_list(public_vocabularies) do
    vocabulary = field(candidate, :vocabulary)

    cond do
      not is_binary(vocabulary) or vocabulary == "" ->
        {:error, {:refused_gall, :vocabulary_policy, :missing_vocabulary}}

      String.starts_with?(String.downcase(vocabulary), ["private:", "secret:"]) ->
        {:error, {:refused_gall, :vocabulary_policy, :private_vocabulary}}

      vocabulary not in public_vocabularies ->
        {:error, {:refused_gall, :vocabulary_policy, {:unknown_vocabulary, vocabulary}}}

      true ->
        {:ok, candidate}
    end
  end

  def admit(_, _), do: {:error, {:refused_gall, :vocabulary_policy, :invalid_policy}}

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
