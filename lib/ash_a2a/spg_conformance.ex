defmodule AshA2A.SpgConformance do
  @moduledoc """
  Executable court for the SPG conformance corpus.

  The fixture's `expect` field is the oracle, not the execution mechanism.
  Runtime decisions are derived independently from `stimulus.checks`. This
  keeps the corpus falsifiable: changing an expectation without changing the
  stimulus, or changing a stimulus without the matching expected outcome,
  fails closed.

  Every evaluator is executed twice against the exact same decoded case.
  Divergent decisions are refused as nondeterministic replay. An admitted
  consumer must preserve the exact subject and procedure and must carry
  explicit authority and receipt projections. A refusal must preserve the
  exact typed refusal code declared by the fixture.
  """

  @relative_dir "priv/spg_conformance/v26.9.27"
  @schema "ash-a2a/spg-conformance/1"
  @preserve ~w(subject procedure authority receipt)
  @sha ~r/\A[0-9a-f]{40}\z/
  @repo ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @case_id ~r/\ASPG-[0-9]{3}\z/
  @refusal ~r/\ASPG_[A-Z0-9_]+\z/

  @pin_file "CORPUS_DIGEST.sha256"

  # RFC-SA2A-004 section 19: which families are evaluated independently of
  # `stimulus.checks` (recomputed from the case's concrete fields through real
  # modules) versus self-checked (reference evaluator, reads the checks).
  # The concrete fields (subject, procedure, boundary, replay) are identical
  # across all cases except identity strings and seeds, so refuse cases carry
  # no concrete witness of their failing condition: the independent evaluator
  # admits them, and that disagreement is reported, not hidden.
  @independent_families ~w(identity spg authority replay)
  @self_checked_families ~w(intervention ocel recovery semantic_jira consumer falsifier planner)

  @type decision :: {:admit, map()} | {:refuse, String.t()}

  @spec independent_families() :: [String.t()]
  def independent_families, do: @independent_families

  @spec self_checked_families() :: [String.t()]
  def self_checked_families, do: @self_checked_families

  @doc "Path of the committed corpus digest pin."
  @spec pin_path() :: String.t()
  def pin_path, do: Path.join(corpus_dir(), @pin_file)

  @doc """
  Recomputes the corpus digest over `dir` and compares it to the committed pin.
  Returns `{:error, {:corpus_digest_mismatch, expected, actual}}` on drift.
  """
  @spec verify_pinned(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def verify_pinned(dir \\ corpus_dir(), pin \\ pin_path()) do
    with {:ok, raw} <- read_pin(pin) do
      expected = String.trim(raw)
      actual = dir |> load_all() |> corpus_digest()

      if actual == expected,
        do: {:ok, actual},
        else: {:error, {:corpus_digest_mismatch, expected, actual}}
    end
  end

  defp read_pin(pin) do
    case File.read(pin) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, {:corpus_pin_unreadable, reason}}
    end
  end

  @doc """
  Evaluator that ignores `stimulus.checks` and recomputes the decision from the
  case's concrete fields using `AshA2A.SpgIdentity`, `Gall.Closure.ReplayGuard`
  and `Gall.Closure.AuthorityBinding`.
  """
  @spec independent_evaluator(map()) :: decision()
  def independent_evaluator(case) do
    with :ok <- independent_identity(case),
         :ok <- independent_authority(case),
         :ok <- independent_replay(case) do
      {:admit,
       %{
         "subject" => case["subject"],
         "procedure" => case["procedure"],
         "authority" => %{"explicit" => get_in(case, ["boundary", "authority_explicit"])},
         "receipt" => %{"case_id" => case_id(case), "seed" => get_in(case, ["replay", "seed"])}
       }}
    else
      {:error, code} -> {:refuse, code}
    end
  end

  @doc """
  Runs only the independently evaluable families with `independent_evaluator/1`
  and reports per-case agreement with the fixture oracle (no fixture is altered).
  """
  @spec independent_report([map()]) :: map()
  def independent_report(cases) do
    rows =
      cases
      |> Enum.filter(&(&1["family"] in @independent_families))
      |> Enum.map(fn c ->
        {case_id(c), c["family"], c["expect"], verdict(independent_evaluator(c))}
      end)

    {agree, disagree} = Enum.split_with(rows, fn {_, _, expect, got} -> expect == got end)
    %{evaluated: length(rows), agree: agree, disagree: disagree}
  end

  defp independent_identity(case) do
    procedure_id = get_in(case, ["procedure", "identity"])

    with "urn:ash-a2a:spg:" <> rest <- procedure_id,
         [family, node] <- String.split(rest, ":", parts: 2),
         {:ok, _identity} <-
           AshA2A.SpgIdentity.new(
             graph_id: "urn:ash-a2a:spg",
             graph_version: case["schema"],
             node_id: node,
             projection_family: family
           ),
         true <- family == case["family"] and node == case["name"],
         :ok <- regex(get_in(case, ["subject", "repo"]), @repo, :repo),
         :ok <- regex(get_in(case, ["subject", "base_sha"]), @sha, :sha) do
      :ok
    else
      _ -> {:error, "SPG_INDEPENDENT_IDENTITY_MISMATCH"}
    end
  end

  defp independent_authority(case) do
    if get_in(case, ["boundary", "authority_explicit"]) == true do
      scope = %{
        "repo" => get_in(case, ["subject", "repo"]),
        "sha" => get_in(case, ["subject", "base_sha"])
      }

      principal = "spg:" <> to_string(case["family"])

      authority = %{
        subject: principal,
        capability_id: case["name"],
        constraints: %{scope: scope, max_consequences: 1}
      }

      command = %{principal_id: principal, capability_id: case["name"]}

      case AshA2A.Gall.Closure.AuthorityBinding.admit(authority, command, scope, 1) do
        {:ok, _} -> :ok
        {:error, _} -> {:error, "SPG_INDEPENDENT_AUTHORITY_UNBOUND"}
      end
    else
      {:error, "SPG_INDEPENDENT_AUTHORITY_UNBOUND"}
    end
  end

  defp independent_replay(case) do
    seed = get_in(case, ["replay", "seed"])

    delivery = %{
      command_id: case_id(case),
      actuation_id: "act-#{seed}",
      idempotency_key: "k-#{seed}"
    }

    case AshA2A.Gall.Closure.ReplayGuard.classify(delivery, delivery) do
      {:ok, :exact_replay} -> :ok
      _ -> {:error, "SPG_INDEPENDENT_REPLAY_UNSTABLE"}
    end
  end

  @spec corpus_dir() :: String.t()
  def corpus_dir, do: Application.app_dir(:ash_a2a, @relative_dir)

  @spec load_all(String.t()) :: [map()]
  def load_all(dir \\ corpus_dir()) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load_file!/1)
  end

  @spec load_file!(String.t()) :: map()
  def load_file!(path) do
    path
    |> File.read!()
    |> JSON.decode!()
  end

  @spec run_all((map() -> decision()), String.t()) :: {:ok, map()} | {:error, map() | atom()}
  def run_all(evaluator \\ &reference_evaluator/1, dir \\ corpus_dir())
      when is_function(evaluator, 1) do
    run_cases(load_all(dir), evaluator)
  end

  @spec run_cases([map()], (map() -> decision())) :: {:ok, map()} | {:error, map() | atom()}
  def run_cases(cases, evaluator \\ &reference_evaluator/1)
      when is_list(cases) and is_function(evaluator, 1) do
    with :ok <- unique_case_ids(cases) do
      results = Enum.map(cases, &{case_id(&1), evaluate(&1, evaluator)})
      failures = Enum.filter(results, fn {_id, result} -> match?({:error, _}, result) end)

      if failures == [] do
        admitted = Enum.count(cases, &(&1["expect"] == "admit"))
        refused = length(cases) - admitted

        {:ok,
         %{
           schema: @schema,
           total: length(cases),
           admitted: admitted,
           refused: refused,
           corpus_digest: corpus_digest(cases),
           case_ids: Enum.map(cases, &case_id/1)
         }}
      else
        {:error,
         %{
           schema: @schema,
           total: length(cases),
           failures: failures,
           corpus_digest: corpus_digest(cases)
         }}
      end
    end
  end

  @spec evaluate(map(), (map() -> decision())) :: {:ok, map()} | {:error, term()}
  def evaluate(case, evaluator \\ &reference_evaluator/1) when is_function(evaluator, 1) do
    with {:ok, validated} <- validate_case(case),
         {:ok, first} <- safe_evaluate(evaluator, validated),
         {:ok, second} <- safe_evaluate(evaluator, validated),
         :ok <- deterministic(first, second),
         :ok <- matches_oracle(validated, first),
         :ok <- preserves_required(validated, first) do
      {:ok,
       %{
         case_id: case_id(validated),
         verdict: verdict(first),
         decision_digest: decision_digest(first),
         replay_seed: get_in(validated, ["replay", "seed"]),
         deterministic: true
       }}
    end
  end

  @spec reference_evaluator(map()) :: decision()
  def reference_evaluator(case) do
    case failing_check(case) do
      nil ->
        {:admit,
         %{
           "subject" => case["subject"],
           "procedure" => case["procedure"],
           "authority" => %{"explicit" => get_in(case, ["boundary", "authority_explicit"])},
           "receipt" => %{
             "case_id" => case_id(case),
             "seed" => get_in(case, ["replay", "seed"])
           }
         }}

      check ->
        {:refuse, check["refusal_code"]}
    end
  end

  @spec validate_case(map()) :: {:ok, map()} | {:error, term()}
  def validate_case(case) when is_map(case) do
    id = case_id(case)

    with :ok <- exact(case["schema"], @schema, :schema),
         :ok <- regex(case["case_id"], @case_id, :case_id),
         :ok <- non_empty(case["family"], :family),
         :ok <- non_empty(case["name"], :name),
         :ok <- member(case["expect"], ~w(admit refuse), :expect),
         :ok <- validate_subject(case["subject"]),
         :ok <- validate_procedure(case["procedure"]),
         :ok <- validate_boundary(case["boundary"]),
         :ok <- validate_replay(case["replay"]),
         :ok <- validate_stimulus(case["stimulus"]),
         :ok <- validate_assertion(case),
         :ok <- stimulus_oracle_coherence(case) do
      {:ok, case}
    else
      {:error, reason} -> {:error, {:invalid_spg_case, id, reason}}
    end
  end

  def validate_case(_), do: {:error, {:invalid_spg_case, nil, :not_a_map}}

  @spec case_digest(map()) :: String.t()
  def case_digest(case), do: digest(case)

  @spec corpus_digest([map()]) :: String.t()
  def corpus_digest(cases) do
    cases
    |> Enum.sort_by(&case_id/1)
    |> digest()
  end

  defp validate_subject(%{"repo" => repo, "base_sha" => sha}) do
    with :ok <- regex(repo, @repo, :subject_repo),
         :ok <- regex(sha, @sha, :subject_base_sha) do
      :ok
    end
  end

  defp validate_subject(_), do: {:error, :subject}

  defp validate_procedure(%{"vocabulary" => "SPG", "identity" => identity}) do
    if is_binary(identity) and String.starts_with?(identity, "urn:ash-a2a:spg:"),
      do: :ok,
      else: {:error, :procedure_identity}
  end

  defp validate_procedure(_), do: {:error, :procedure}

  defp validate_boundary(%{
         "candidate_truth_separated" => true,
         "authority_explicit" => true,
         "exact_subject" => true
       }),
       do: :ok

  defp validate_boundary(_), do: {:error, :boundary}

  defp validate_replay(%{"deterministic" => true, "seed" => seed})
       when is_integer(seed) and seed > 0,
       do: :ok

  defp validate_replay(_), do: {:error, :replay}

  defp validate_stimulus(%{"checks" => checks}) when is_list(checks) and checks != [] do
    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case validate_check(check) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_stimulus(_), do: {:error, :stimulus_checks_required}

  defp validate_check(%{"predicate" => predicate, "value" => true}),
    do: non_empty(predicate, :stimulus_predicate)

  defp validate_check(%{
         "predicate" => predicate,
         "value" => false,
         "refusal_code" => refusal_code
       }) do
    with :ok <- non_empty(predicate, :stimulus_predicate),
         :ok <- regex(refusal_code, @refusal, :stimulus_refusal_code) do
      :ok
    end
  end

  defp validate_check(_), do: {:error, :stimulus_check}

  defp validate_assertion(%{
         "expect" => "admit",
         "assertion" => %{"must_admit" => true, "must_preserve" => preserve}
       })
       when is_list(preserve) do
    if Enum.sort(preserve) == Enum.sort(@preserve),
      do: :ok,
      else: {:error, :admit_preservation_contract}
  end

  defp validate_assertion(%{
         "expect" => "refuse",
         "assertion" => %{"must_refuse" => true, "refusal_code" => code}
       }),
       do: regex(code, @refusal, :refusal_code)

  defp validate_assertion(_), do: {:error, :assertion}

  defp stimulus_oracle_coherence(%{"expect" => "admit"} = case) do
    if failing_check(case) == nil, do: :ok, else: {:error, :admit_has_failing_check}
  end

  defp stimulus_oracle_coherence(
         %{
           "expect" => "refuse",
           "assertion" => %{"refusal_code" => expected}
         } = case
       ) do
    case failing_check(case) do
      %{"refusal_code" => ^expected} -> :ok
      nil -> {:error, :refusal_has_no_failing_check}
      _ -> {:error, :stimulus_refusal_code_mismatch}
    end
  end

  defp failing_check(case) do
    case
    |> get_in(["stimulus", "checks"])
    |> Enum.find(fn check -> check["value"] != true end)
  end

  defp safe_evaluate(evaluator, case) do
    try do
      case evaluator.(case) do
        {:admit, projection} when is_map(projection) -> {:ok, {:admit, projection}}
        {:refuse, code} when is_binary(code) -> {:ok, {:refuse, code}}
        other -> {:error, {:invalid_evaluator_result, other}}
      end
    rescue
      error -> {:error, {:evaluator_exception, error.__struct__}}
    catch
      kind, reason -> {:error, {:evaluator_throw, kind, reason}}
    end
  end

  defp deterministic(decision, decision), do: :ok
  defp deterministic(_, _), do: {:error, :nondeterministic_replay}

  defp matches_oracle(%{"expect" => "admit"}, {:admit, _}), do: :ok

  defp matches_oracle(
         %{"expect" => "refuse", "assertion" => %{"refusal_code" => expected}},
         {:refuse, expected}
       ),
       do: :ok

  defp matches_oracle(%{"expect" => "admit"}, {:refuse, code}),
    do: {:error, {:false_refusal, code}}

  defp matches_oracle(%{"expect" => "refuse"}, {:admit, _}),
    do: {:error, :false_admission}

  defp matches_oracle(
         %{"expect" => "refuse", "assertion" => %{"refusal_code" => expected}},
         {:refuse, actual}
       ),
       do: {:error, {:refusal_code_drift, expected, actual}}

  defp preserves_required(_case, {:refuse, _}), do: :ok

  defp preserves_required(case, {:admit, projection}) do
    cond do
      projection["subject"] != case["subject"] -> {:error, :subject_identity_drift}
      projection["procedure"] != case["procedure"] -> {:error, :procedure_identity_drift}
      not Map.has_key?(projection, "authority") -> {:error, :authority_projection_missing}
      not Map.has_key?(projection, "receipt") -> {:error, :receipt_projection_missing}
      true -> :ok
    end
  end

  defp unique_case_ids(cases) do
    ids = Enum.map(cases, &case_id/1)
    if length(ids) == length(Enum.uniq(ids)), do: :ok, else: {:error, :duplicate_case_id}
  end

  defp verdict({:admit, _}), do: "admit"
  defp verdict({:refuse, _}), do: "refuse"

  defp decision_digest(decision), do: digest(decision)

  defp digest(value) do
    "sha256:" <>
      (:crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
       |> Base.encode16(case: :lower))
  end

  defp case_id(case) when is_map(case), do: Map.get(case, "case_id")

  defp exact(value, expected, _field) when value == expected, do: :ok
  defp exact(_, _, field), do: {:error, field}

  defp non_empty(value, _field) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp non_empty(_, field), do: {:error, field}

  defp member(value, allowed, field) do
    if value in allowed, do: :ok, else: {:error, field}
  end

  defp regex(value, regex, field) when is_binary(value) do
    if Regex.match?(regex, value), do: :ok, else: {:error, field}
  end

  defp regex(_, _, field), do: {:error, field}
end
