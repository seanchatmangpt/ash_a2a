defmodule AshA2A.Chicago.Query do
  @moduledoc """
  Independent OCEL consumer and semantic-level conformance predicates
  (RFC-SA2A-002 §104-§107, §141).

  Loads a durable OCEL 2.0 JSON artifact from disk -- never from observer
  memory or producer structs -- verifies its content digest, and evaluates
  predicates that ask *questions* about the observed process rather than
  comparing against a golden trace (§13-§14).

  Predicates are evaluated over a scope: by default the events related to
  object `falsifier:<id>` (the events the observer attributed to one
  falsifier's stimulus); `{:run_scope, p}` widens `p` to every event in the
  run.

  ## Predicate language

      {:observed, activity}
      {:observed, activity, %{"attr" => value}}      # every listed attr equals value (string compare)
      {:not_observed, activity}
      {:not_observed, activity, %{"attr" => value}}
      {:count, activity, :eq | :gte | :lte, n}
      {:precedes, activity_a, activity_b}             # every b has an earlier a (by chicago_seq)
      {:precedes, activity_a, activity_b, object_type} # ... sharing an object of object_type
      {:all, [predicate]}
      {:any, [predicate]}
      {:not, predicate}
      {:run_scope, predicate}
  """

  @type predicate ::
          {:observed, String.t()}
          | {:observed, String.t(), map()}
          | {:not_observed, String.t()}
          | {:not_observed, String.t(), map()}
          | {:count, String.t(), :eq | :gte | :lte, non_neg_integer()}
          | {:precedes, String.t(), String.t()}
          | {:precedes, String.t(), String.t(), String.t()}
          | {:all, [predicate()]}
          | {:any, [predicate()]}
          | {:not, predicate()}
          | {:run_scope, predicate()}

  @type event :: %{
          id: String.t(),
          type: String.t(),
          seq: integer(),
          attributes: %{String.t() => term()},
          objects: [{String.t(), String.t()}]
        }

  @type index :: %{
          path: Path.t(),
          sha256: String.t(),
          events: [event()],
          object_types: %{String.t() => String.t()},
          identity_unique: boolean(),
          array_ordered: boolean()
        }

  @doc """
  Loads and indexes an OCEL JSON artifact. When `expected_sha256` is given the
  bytes on disk must hash to it. An artifact repeating an event id or a
  `chicago_seq` is refused (`:ocel_duplicate_event_identity`). Emits
  `[:ash_a2a, :chicago, :ocel, :load]` with the outcome.
  """
  @spec load(Path.t(), String.t() | nil) :: {:ok, index()} | {:error, term()}
  def load(path, expected_sha256 \\ nil) do
    result =
      with {:ok, bytes} <- File.read(path),
           sha <- :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
           :ok <- check_digest(sha, expected_sha256),
           {:ok, doc} <- decode(bytes),
           {:ok, index} <- index(doc) do
        {:ok, Map.merge(index, %{path: path, sha256: sha})}
      end

    emit_load(result, expected_sha256)
    result
  end

  # Consumer-boundary telemetry (RFC-SA2A-002 §138): whether the independent
  # consumer admitted or refused the bytes, and why. Observational only.
  defp emit_load({:ok, index}, expected) do
    :telemetry.execute(
      [:ash_a2a, :chicago, :ocel, :load],
      %{system_time: System.system_time()},
      %{
        outcome: :loaded,
        sha256: index.sha256,
        digest_verified: expected != nil,
        events: length(index.events),
        identity_unique: index.identity_unique,
        array_ordered: index.array_ordered
      }
    )
  end

  defp emit_load({:error, reason}, expected) do
    code =
      case reason do
        {code, _} when is_atom(code) -> code
        code when is_atom(code) -> code
        _ -> :ocel_unreadable
      end

    :telemetry.execute(
      [:ash_a2a, :chicago, :ocel, :load],
      %{system_time: System.system_time()},
      %{
        outcome: :refused,
        code: code,
        digest_verified: expected != nil
      }
    )
  end

  defp check_digest(_sha, nil), do: :ok
  defp check_digest(sha, sha), do: :ok

  defp check_digest(sha, expected),
    do: {:error, {:ocel_digest_mismatch, expected: expected, actual: sha}}

  defp decode(bytes) do
    case JSON.decode(bytes) do
      {:ok, %{} = doc} -> {:ok, doc}
      {:ok, _} -> {:error, :ocel_not_an_object}
      {:error, reason} -> {:error, {:ocel_non_json, reason}}
    end
  end

  defp index(%{"events" => events, "objects" => objects})
       when is_list(events) and is_list(objects) do
    object_types =
      Map.new(objects, fn
        %{"id" => id, "type" => type} -> {id, type}
        _ -> {nil, nil}
      end)

    indexed =
      events
      |> Enum.map(fn e ->
        attrs = Map.new(List.wrap(e["attributes"]), fn a -> {a["name"], a["value"]} end)

        %{
          id: e["id"],
          type: e["type"],
          seq: seq(attrs),
          attributes: attrs,
          objects: Enum.map(List.wrap(e["relationships"]), &{&1["objectId"], &1["qualifier"]})
        }
      end)

    with :ok <- unique_identities(indexed) do
      array_ordered = indexed |> Enum.map(& &1.seq) |> then(&(&1 == Enum.sort(&1)))

      {:ok,
       %{
         events: Enum.sort_by(indexed, & &1.seq),
         object_types: object_types,
         identity_unique: true,
         array_ordered: array_ordered
       }}
    end
  end

  defp index(_), do: {:error, :ocel_missing_events_or_objects}

  # Event identity (RFC-SA2A-002 §138 duplicated events, §20 ordering): OCEL
  # event ids are unique, and a `chicago_seq` names exactly one observation.
  # An artifact that repeats either is a duplicated or replayed serialization
  # and is refused rather than silently deduplicated or double counted.
  defp unique_identities(events) do
    duplicate_ids = events |> Enum.map(& &1.id) |> duplicates_of()

    duplicate_seqs =
      events
      |> Enum.filter(&Map.has_key?(&1.attributes, "chicago_seq"))
      |> Enum.map(& &1.seq)
      |> duplicates_of()

    if duplicate_ids == [] and duplicate_seqs == [],
      do: :ok,
      else:
        {:error,
         {:ocel_duplicate_event_identity,
          ids: Enum.take(duplicate_ids, 10), chicago_seqs: Enum.take(duplicate_seqs, 10)}}
  end

  defp duplicates_of(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_v, n} -> n > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc """
  Content-duplicate detector: groups of distinct events (distinct ids and
  `chicago_seq`) whose type, attributes (other than `chicago_seq`) and object
  relationships are identical -- e.g. the same telemetry delivered twice.
  Duplicated deliveries are evidence to report, never to collapse.
  """
  @spec duplicates(index()) :: [%{type: String.t(), count: pos_integer(), seqs: [integer()]}]
  def duplicates(index) do
    index.events
    |> Enum.group_by(fn e ->
      {e.type, Map.delete(e.attributes, "chicago_seq"), Enum.sort(e.objects)}
    end)
    |> Enum.filter(fn {_key, events} -> length(events) > 1 end)
    |> Enum.map(fn {{type, _attrs, _objects}, events} ->
      %{type: type, count: length(events), seqs: Enum.map(events, & &1.seq)}
    end)
    |> Enum.sort_by(&{&1.type, hd(&1.seqs)})
  end

  defp seq(%{"chicago_seq" => s}) when is_integer(s), do: s
  defp seq(_), do: 0

  @doc "Events related to `falsifier:<id>`."
  @spec scope(index(), String.t()) :: [event()]
  def scope(index, falsifier_id) do
    oid = "falsifier:" <> falsifier_id
    Enum.filter(index.events, fn e -> Enum.any?(e.objects, &(elem(&1, 0) == oid)) end)
  end

  @doc "Evaluates `predicate` for one falsifier. Returns `{boolean, detail}`."
  @spec eval(index(), String.t(), predicate()) :: {boolean(), String.t()}
  def eval(index, falsifier_id, predicate) do
    do_eval(predicate, scope(index, falsifier_id), index)
  end

  defp do_eval({:run_scope, p}, _scoped, index), do: do_eval(p, index.events, index)

  defp do_eval({:observed, activity}, events, _i) do
    n = count(events, activity, %{})
    {n > 0, "#{activity} observed #{n}x"}
  end

  defp do_eval({:observed, activity, attrs}, events, _i) do
    n = count(events, activity, attrs)
    {n > 0, "#{activity} #{inspect(attrs)} observed #{n}x"}
  end

  defp do_eval({:not_observed, activity}, events, i) do
    {seen, detail} = do_eval({:observed, activity}, events, i)
    {not seen, detail}
  end

  defp do_eval({:not_observed, activity, attrs}, events, i) do
    {seen, detail} = do_eval({:observed, activity, attrs}, events, i)
    {not seen, detail}
  end

  defp do_eval({:count, activity, op, n}, events, _i) do
    c = count(events, activity, %{})

    ok =
      case op do
        :eq -> c == n
        :gte -> c >= n
        :lte -> c <= n
      end

    {ok, "#{activity} count #{c} #{op} #{n}"}
  end

  defp do_eval({:precedes, a, b}, events, _i) do
    bs = Enum.filter(events, &(&1.type == b))
    as = Enum.filter(events, &(&1.type == a))
    violations = Enum.reject(bs, fn eb -> Enum.any?(as, &(&1.seq < eb.seq)) end)
    {violations == [], "#{length(bs)} #{b}; #{length(violations)} without an earlier #{a}"}
  end

  defp do_eval({:precedes, a, b, object_type}, events, index) do
    bs = Enum.filter(events, &(&1.type == b))
    as = Enum.filter(events, &(&1.type == a))

    violations =
      Enum.reject(bs, fn eb ->
        shared = typed_objects(eb, object_type, index)

        shared != MapSet.new() and
          Enum.any?(as, fn ea ->
            ea.seq < eb.seq and
              not MapSet.disjoint?(shared, typed_objects(ea, object_type, index))
          end)
      end)

    {violations == [],
     "#{length(bs)} #{b}; #{length(violations)} without an earlier #{a} sharing a #{object_type}"}
  end

  defp do_eval({:all, ps}, events, i) do
    results = Enum.map(ps, &do_eval(&1, events, i))

    {Enum.all?(results, &elem(&1, 0)),
     "all(" <> Enum.map_join(results, "; ", &elem(&1, 1)) <> ")"}
  end

  defp do_eval({:any, ps}, events, i) do
    results = Enum.map(ps, &do_eval(&1, events, i))

    {Enum.any?(results, &elem(&1, 0)),
     "any(" <> Enum.map_join(results, "; ", &elem(&1, 1)) <> ")"}
  end

  defp do_eval({:not, p}, events, i) do
    {v, d} = do_eval(p, events, i)
    {not v, "not(#{d})"}
  end

  defp count(events, activity, attrs) do
    Enum.count(events, fn e ->
      e.type == activity and
        Enum.all?(attrs, fn {k, v} ->
          to_string(Map.get(e.attributes, to_string(k))) == to_string(v)
        end)
    end)
  end

  defp typed_objects(event, type, index) do
    event.objects
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&(Map.get(index.object_types, &1) == type))
    |> MapSet.new()
  end

  @doc "Structural validation of a predicate."
  @spec validate_predicate(term()) :: :ok | {:error, String.t()}
  def validate_predicate({:observed, a}) when is_binary(a), do: :ok
  def validate_predicate({:observed, a, attrs}) when is_binary(a) and is_map(attrs), do: :ok
  def validate_predicate({:not_observed, a}) when is_binary(a), do: :ok
  def validate_predicate({:not_observed, a, attrs}) when is_binary(a) and is_map(attrs), do: :ok

  def validate_predicate({:count, a, op, n})
      when is_binary(a) and op in [:eq, :gte, :lte] and is_integer(n) and n >= 0,
      do: :ok

  def validate_predicate({:precedes, a, b}) when is_binary(a) and is_binary(b), do: :ok

  def validate_predicate({:precedes, a, b, t})
      when is_binary(a) and is_binary(b) and is_binary(t),
      do: :ok

  def validate_predicate({op, ps}) when op in [:all, :any] and is_list(ps) and ps != [] do
    Enum.find_value(ps, :ok, fn p ->
      case validate_predicate(p) do
        :ok -> nil
        error -> error
      end
    end)
  end

  def validate_predicate({:not, p}), do: validate_predicate(p)
  def validate_predicate({:run_scope, p}), do: validate_predicate(p)

  def validate_predicate(other),
    do: {:error, "is not a valid Chicago query predicate: #{inspect(other)}"}

  @doc "JSON form of a predicate (for the query-set digest, §137)."
  @spec predicate_to_json(predicate()) :: list()
  def predicate_to_json({op, ps}) when op in [:all, :any],
    do: [Atom.to_string(op), Enum.map(ps, &predicate_to_json/1)]

  def predicate_to_json({op, p}) when op in [:not, :run_scope],
    do: [Atom.to_string(op), predicate_to_json(p)]

  def predicate_to_json(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(fn
      a when is_atom(a) ->
        Atom.to_string(a)

      m when is_map(m) ->
        m |> Enum.map(fn {k, v} -> [to_string(k), to_string(v)] end) |> Enum.sort()

      other ->
        other
    end)
  end
end
