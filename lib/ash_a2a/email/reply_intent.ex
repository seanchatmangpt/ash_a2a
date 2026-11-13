defmodule AshA2A.Email.ReplyIntent do
  @moduledoc """
  Deterministic first-tier parser mapping an email reply onto the numbered actions of a brief.

  No LLM, no IO. Fail closed:

    * an action the reply never mentions is `:unknown`, never approved;
    * a number outside the brief's action numbers yields `{:error, :ambiguous}`;
    * conflicting decisions for one action yield `{:error, :ambiguous}`;
    * a reply with no recognisable decision yields `{:error, :no_decisions}`.

  Verbs: approve/yes/ok/okay/go/execute/do it => `:approve`; hold/wait/later/not yet => `:hold`;
  reject/no/deny/cancel => `:reject`. Number specs: `1 and 3`, `1,3`, `1-3`, `all`,
  `all except 2`. Text following the number spec in a clause becomes the `note`.
  Skill names such as "ban" are not decisions and are ignored.
  """

  @type decision :: :approve | :hold | :reject | :unknown
  @type entry :: %{n: integer(), decision: decision(), note: String.t() | nil}

  @verb_src "not yet|do it|approved?|yes|okay|ok|go|execute|hold|wait|later|reject(?:ed)?|no|deny|cancel"
  @verb_re Regex.compile!("\\b(#{@verb_src})\\b", "i")
  @split_re Regex.compile!(
              "[.;\\n!?]+|(?:,\\s*)?\\b(?:and|then|but)\\s+(?=(?:#{@verb_src})\\b)|,\\s*(?=(?:#{@verb_src})\\b)",
              "i"
            )
  @except_re ~r/\A\s*(?:except|besides|other than|apart from|excluding)\b(.*)\z/is

  @doc "Parse a reply into one entry per action number (sorted). Pure."
  @spec parse(String.t(), [pos_integer()]) ::
          {:ok, [entry()]} | {:error, :no_decisions | :ambiguous}
  def parse(reply_text, action_numbers)
      when is_binary(reply_text) and is_list(action_numbers) do
    clauses = Regex.split(@split_re, reply_text, trim: true)

    with {:ok, triples} <- collect(clauses, action_numbers),
         {:ok, merged} <- merge(triples) do
      if map_size(merged) == 0 do
        {:error, :no_decisions}
      else
        entries =
          action_numbers
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.map(fn n ->
            case Map.fetch(merged, n) do
              {:ok, {d, note}} -> %{n: n, decision: d, note: note}
              :error -> %{n: n, decision: :unknown, note: nil}
            end
          end)

        {:ok, entries}
      end
    end
  end

  def parse(_, _), do: {:error, :no_decisions}

  @doc """
  Return only the brief actions whose number was decided `:approve`.

  Brief actions are maps (or keyword lists) carrying `:n`. Anything not explicitly approved,
  or lacking `:n`, is excluded.
  """
  @spec resolve([entry()], [map() | keyword()]) :: [map() | keyword()]
  def resolve(decisions, brief_actions) when is_list(decisions) and is_list(brief_actions) do
    approved =
      for %{n: n, decision: :approve} <- decisions, into: MapSet.new(), do: n

    Enum.filter(brief_actions, fn a ->
      case action_n(a) do
        nil -> false
        n -> MapSet.member?(approved, n)
      end
    end)
  end

  def resolve(_, _), do: []

  defp action_n(%{n: n}) when is_integer(n), do: n
  defp action_n(a) when is_list(a), do: if(Keyword.keyword?(a), do: int_or_nil(a[:n]), else: nil)
  defp action_n(_), do: nil

  defp int_or_nil(n) when is_integer(n), do: n
  defp int_or_nil(_), do: nil

  # -- clause handling ------------------------------------------------------

  defp collect(clauses, nums) do
    Enum.reduce_while(clauses, {:ok, []}, fn clause, {:ok, acc} ->
      case parse_clause(clause, nums) do
        {:ok, triples} -> {:cont, {:ok, acc ++ triples}}
        :skip -> {:cont, {:ok, acc}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  defp merge(triples) do
    Enum.reduce_while(triples, {:ok, %{}}, fn {n, d, note}, {:ok, m} ->
      case Map.fetch(m, n) do
        :error -> {:cont, {:ok, Map.put(m, n, {d, note})}}
        {:ok, {^d, old}} -> {:cont, {:ok, Map.put(m, n, {d, old || note})}}
        {:ok, _} -> {:halt, {:error, :ambiguous}}
      end
    end)
  end

  defp parse_clause(clause, nums) do
    {pre_items, rest0} = take_spec(clause, [])

    {items, decision, rest} =
      if pre_items != [] do
        case find_verb(rest0) do
          {d, after_verb} -> {pre_items, d, after_verb}
          nil -> {pre_items, nil, ""}
        end
      else
        case find_verb(clause) do
          {d, after_verb} ->
            {its, r} = take_spec(after_verb, [])
            {its, d, r}

          nil ->
            {[], nil, ""}
        end
      end

    cond do
      decision == nil or items == [] ->
        :skip

      true ->
        {excluded, rest} =
          case Regex.run(@except_re, rest) do
            [_, tail] -> take_spec(tail, [])
            _ -> {[], rest}
          end

        with {:ok, ns} <- expand(items, nums),
             {:ok, ex} <- expand(excluded, nums) do
          note = clean_note(rest)

          case ns -- ex do
            [] -> :skip
            keep -> {:ok, Enum.map(Enum.uniq(keep), &{&1, decision, note})}
          end
        end
    end
  end

  defp find_verb(text) do
    case Regex.run(@verb_re, text, return: :index) do
      [{start, len} | _] ->
        word = text |> binary_part(start, len) |> String.downcase()
        after_verb = binary_part(text, start + len, byte_size(text) - start - len)
        {verb_decision(word), after_verb}

      _ ->
        nil
    end
  end

  defp verb_decision(w) when w in ["hold", "wait", "later", "not yet"], do: :hold
  defp verb_decision(w) when w in ["no", "deny", "cancel", "reject", "rejected"], do: :reject
  defp verb_decision(_), do: :approve

  defp take_spec(s, acc) do
    s1 = Regex.replace(~r/\A(?:[\s,#&:]+|(?:and|actions?|items?|numbers?)\b\s*)+/i, s, "")

    cond do
      m = Regex.run(~r/\A(\d+)\s*-\s*(\d+)/, s1) ->
        [whole, a, b] = m
        take_spec(drop(s1, whole), acc ++ [{:range, String.to_integer(a), String.to_integer(b)}])

      m = Regex.run(~r/\A(\d+)/, s1) ->
        [whole, a] = m
        take_spec(drop(s1, whole), acc ++ [{:int, String.to_integer(a)}])

      m = Regex.run(~r/\Aall\b/i, s1) ->
        take_spec(drop(s1, hd(m)), acc ++ [:all])

      true ->
        {acc, s1}
    end
  end

  defp drop(s, prefix), do: binary_part(s, byte_size(prefix), byte_size(s) - byte_size(prefix))

  defp expand(items, nums) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case expand_item(item, nums) do
        {:ok, ns} -> {:cont, {:ok, acc ++ ns}}
        :error -> {:halt, {:error, :ambiguous}}
      end
    end)
  end

  defp expand_item(:all, nums), do: {:ok, nums}

  defp expand_item({:int, n}, nums), do: if(n in nums, do: {:ok, [n]}, else: :error)

  defp expand_item({:range, a, b}, nums) when a <= b do
    ns = Enum.to_list(a..b)
    if Enum.all?(ns, &(&1 in nums)), do: {:ok, ns}, else: :error
  end

  defp expand_item({:range, _, _}, _), do: :error

  defp clean_note(rest) do
    case Regex.replace(~r/\A[\s,;:\-]+|[\s,;:\-]+\z/, rest, "") do
      "" -> nil
      note -> note
    end
  end
end
