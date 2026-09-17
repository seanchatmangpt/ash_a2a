defmodule AshA2A.Semantic.Admission do
  @moduledoc "Deterministic admission for candidate semantic state."

  alias AshA2A.Semantic.{IR, Source, Vocabulary}

  # Real, deterministic, conservative defense-in-depth check (not the
  # primary safety mechanism -- that is `source_quote` grounding below,
  # which already structurally prevents an entity referencing anything not
  # verbatim present in the caller's own source text; a caller whose own
  # scenario text never names a real company cannot have one admitted
  # regardless of this list). Catches the common real corporate legal-entity
  # suffix patterns (`X Corp`, `X Inc`, `X LLC`, ...) as a whole-word
  # boundary match against `entities[].label` -- a deliberately narrow,
  # explainable, real pattern, not an attempt at fuzzy real-company
  # classification (`AshA2A.BoardPersona`'s own moduledoc names the same
  # boundary). Does not attempt to enumerate specific real company names
  # (a list like "the current Fortune 5" would itself be a stale,
  # unverifiable claim to hardcode) -- a bare famous brand name with no
  # legal-entity suffix is not caught by this list alone.
  # Deliberately narrow to unambiguous formal-registration suffixes only --
  # "Group"/"Holdings"/"Co." were considered and excluded as too generic
  # (real risk of false-positive against ordinary English, e.g. a persona's
  # own "Activist-Pressured" framing or "working group" language).
  @real_entity_suffix_pattern ~r/\b(Inc\.?|Corp\.?|Corporation|LLC|L\.L\.C\.|Ltd\.?|PLC|N\.V\.|S\.A\.|AG|GmbH)\b/

  defp real_named_entity_suffix?(label) when is_binary(label),
    do: Regex.match?(@real_entity_suffix_pattern, label)

  defp real_named_entity_suffix?(_), do: false

  @required %{
    entities: ~w(id kind type label source_quote),
    relations: ~w(id kind subject predicate object source_quote),
    goals: ~w(id kind description source_quote),
    constraints: ~w(id kind description source_quote),
    capabilities: ~w(id kind description source_quote),
    authorities: ~w(id kind subject scope mode source_quote),
    observations: ~w(id kind description source_quote),
    uncertainties: ~w(id kind description source_quote),
    exclusions: ~w(id kind description source_quote)
  }

  def admit(%Source{} = source, %IR{} = ir) do
    with :ok <- fence(ir),
         :ok <- source_match(source, ir),
         :ok <- require_goal(ir),
         :ok <- unique_ids(ir),
         :ok <- validate_items(source, ir) do
      {:ok, %{ir | standing: :admitted}}
    end
    |> emit_admission(source, ir)
  end

  # `[:ash_a2a, :semantic, :ir_admission]`: the deterministic admission
  # decision over candidate (typically model-extracted) semantic IR, with the
  # standing the result carries (RFC-SA2A-002 §81 evidence) and, on refusal,
  # the refusal `code` (RFC-SA2A-002 §12 attempt evidence -- a sibling branch
  # had emitted this same decision under a second event name,
  # `[:ash_a2a, :semantic, :ir_admission, :decision]`; collapsed here into
  # this one canonical event so every court (llm_boundary.ex and
  # canonical_mutation.ex alike) observes the same record for the same real
  # decision -- see `InferenceMappings.ir_admission/0`'s `Map.take(meta,
  # [:outcome, :code, :standing, :authority])`, which already anticipated
  # `:code`). Observational.
  defp emit_admission(result, source, ir) do
    meta =
      case result do
        {:ok, %IR{} = admitted} ->
          %{
            outcome: :admitted,
            standing: admitted.standing,
            authority: admitted.authority,
            code: nil
          }

        {:error, reason} ->
          %{
            outcome: :refused,
            code: Map.get(reason, :code),
            standing: ir.standing,
            authority: ir.authority
          }
      end

    :telemetry.execute(
      [:ash_a2a, :semantic, :ir_admission],
      %{items: length(IR.items(ir))},
      Map.merge(meta, %{source_id: source.id})
    )

    result
  end

  defp fence(%IR{standing: :candidate, authority: :none}), do: :ok
  defp fence(_), do: error(:semantic_authority_ceiling_violated)

  defp source_match(%Source{id: id}, %IR{source_id: id}), do: :ok
  defp source_match(_, _), do: error(:semantic_source_mismatch)

  defp require_goal(%IR{goals: [_ | _]}), do: :ok
  defp require_goal(_), do: error(:semantic_goal_missing)

  defp unique_ids(ir) do
    ids =
      Enum.map(IR.items(ir), fn
        {_field, item} when is_map(item) -> Map.get(item, "id")
        {_field, _item} -> nil
      end)

    if Enum.all?(ids, &is_binary/1) and length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      error(:semantic_identity_invalid)
    end
  end

  defp validate_items(source, ir) do
    Enum.reduce_while(IR.items(ir), :ok, fn {field, item}, :ok ->
      case validate_item(source, field, item) do
        :ok -> {:cont, :ok}
        {:error, _} = result -> {:halt, result}
      end
    end)
  end

  defp validate_item(%Source{text: text}, field, item) when is_map(item) do
    required = Map.get(@required, field, ~w(id kind source_quote))
    missing = Enum.reject(required, &(is_binary(Map.get(item, &1)) and Map.get(item, &1) != ""))
    quote = Map.get(item, "source_quote", "")

    cond do
      missing != [] ->
        error(:semantic_fields_missing, %{field: field, missing: missing})

      not String.contains?(text, quote) ->
        error(:ungrounded_assertion, Map.get(item, "id"))

      field == :authorities and Map.get(item, "mode") not in ["described", "denied", "unknown"] ->
        error(:authority_grant_not_admissible)

      field == :entities and real_named_entity_suffix?(Map.get(item, "label")) ->
        error(:real_named_entity_not_admissible, Map.get(item, "id"))

      invented = invented_namespace_term(field, item) ->
        error(:ontology_term_not_admitted, %{id: Map.get(item, "id"), term: invented})

      true ->
        :ok
    end
  end

  defp validate_item(_, field, _), do: error(:semantic_item_invalid, field)

  # RFC-SA2A-002 §81 (SA2A-LLM-003): the ontology terms `Ontology.from_ir/1`
  # expands -- an entity `type` and a relation `predicate` -- must not name a
  # namespace no admission ever saw. A prefixed term (`acme:Widget`, a full
  # IRI) whose prefix is not in `Vocabulary.prefixes/0` would otherwise be
  # silently minted into `urn:ash-a2a:semantic:` inside admitted semantics.
  # Unprefixed local terms are unchanged (they stay private, see
  # `AshA2A.Semantic.Iri`).
  defp invented_namespace_term(field, item) when field in [:entities, :relations] do
    term = Map.get(item, if(field == :entities, do: "type", else: "predicate"))

    with term when is_binary(term) <- term,
         [prefix, _local] <- String.split(term, ":", parts: 2),
         false <- Map.has_key?(Vocabulary.prefixes(), prefix) do
      term
    else
      _ -> nil
    end
  end

  defp invented_namespace_term(_field, _item), do: nil
  defp error(code, detail \\ nil), do: {:error, %{code: code, detail: detail}}
end
