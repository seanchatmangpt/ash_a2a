defmodule AshA2A.StandingRef do
  @moduledoc """
  Standing-addressed dependencies (DfCM composition C03, work order
  ASH_A2A-26922-14): resolve the newest commit of a line of history that
  carries a **durable** court receipt at a requested standing, so a consumer
  pins that exact SHA (a git `ref:`) instead of a version number.

      {:ok, %{sha: sha}} =
        AshA2A.StandingRef.resolve(court: "sa2a", standing: "CONFORMANT", ref: "origin/main")

  ## Durable receipt locations

  A receipt is durable only when it is recorded outside process memory and
  outside gitignored scratch space (`tmp/` is gitignored here). Two locations
  are read, both keyed by the exact subject SHA the receipt attests:

    * **repo-local (git-tracked)** -- the tree of the resolved `:ref` holds

          receipts/courts/sa2a/<sha>/chicago/standing_receipt.json
          receipts/courts/sa2a/<sha>/sa2a-conformance.json      (optional)

      A receipt for commit `X` is necessarily committed by a later commit, so
      it is read from the tree of `:ref` (never the working tree): an
      uncommitted receipt is not durable and is never found.

    * **CI artifacts** (`:artifacts_dir`) -- a directory holding downloaded
      `sa2a-conformance-<sha>/` artifact directories with the same two files
      (`gh run download <id>` layout).

  ## Admission (typed, fail-closed)

  Every receipt found for a candidate is admitted or refused with a typed
  reason; a refused receipt never resolves, and the walk continues to older
  commits. A standing receipt (`AshA2A.Chicago.StandingReceipt`) is admitted
  only when:

    * it decodes and carries the `ash_a2a.chicago.standing_receipt/1` schema
    * its `receipt_digest` recomputes (`StandingReceipt.verify_digest/1`)
    * its subject section hashes to its subject identity
      (`AshA2A.Chicago.Subject.from_map/1`)
    * the subject's `source_revision` is exactly the SHA it is filed under,
      and the subject was not dirty
    * its `standing` equals the requested standing (and, with `:profile`,
      its claimed profile matches)
    * a `CONFORMANT` claim is consistent with the receipt's own tallies,
      gate rows, OCEL evidence and claim text -- flipping the standing string
      and re-sealing the digest does not produce an admitted CONFORMANT
    * a co-located `sa2a-conformance.json`, when present, was run over the
      exact graphlaw wasm the subject bound (`validator_digests
      ["graphlaw_wasm"]`), and a `PASS` label is backed by every assertion
      computed and true (a forged `PASS` is refused)

  ## Standing is the court's, not a re-judgement of raw runner output

  The standing that addresses the dependency is the Chicago court's standing
  receipt. The co-located portable-conformance receipt is raw runner output
  that the Chicago `SA2A-XRUNTIME` court already adjudicates: against
  praxis-graphlaw v26.7.5 the full-corpus runner reports `FAIL` because
  `graph_hash/1` of `v006_blank_nodes` is not stable across repetition (a
  deterministic engine property, `AshA2A.SA2A.Conformance` moduledoc), and
  `SA2A-XRUNTIME-008` passes precisely when that unstable identity is refused
  agreement. So by default a present conformance receipt is identity-checked
  and reported (`conformance: "PASS" | "FAIL" | "ABSENT"`), not re-judged;
  `require_conformance: true` (`--require-conformance`) additionally refuses
  any SHA whose conformance receipt is absent or not `PASS` -- the stricter
  ASH_A2A-26922-10 CI-artifact reading.

  Commits are walked newest first along `--first-parent` of `:ref` (the
  states `:ref` itself held); `:max_commits` bounds the walk.
  """

  alias AshA2A.Chicago.{StandingReceipt, Subject}

  @courts %{
    "sa2a" => %{
      root: "receipts/courts/sa2a",
      artifact_prefix: "sa2a-conformance-",
      standing_file: "chicago/standing_receipt.json",
      conformance_file: "sa2a-conformance.json"
    }
  }

  @standings ~w(CONFORMANT PARTIAL_ALIVE NONCONFORMANT BUILD_BROKEN UNKNOWN REFUSED)
  @sha ~r/\A[0-9a-f]{40}\z/
  @default_max_commits 1000

  @type source :: {:git, String.t(), String.t()} | {:artifact, Path.t()}

  @type resolution :: %{
          sha: String.t(),
          court: String.t(),
          standing: String.t(),
          profile: String.t() | nil,
          ref: String.t(),
          ref_sha: String.t(),
          receipt_digest: String.t(),
          receipt_source: String.t(),
          conformance: String.t(),
          refused: [%{sha: String.t(), source: String.t(), reason: term()}],
          commits_walked: non_neg_integer()
        }

  @doc "Courts this resolver understands."
  @spec courts() :: [String.t()]
  def courts, do: Map.keys(@courts)

  @doc "Standings a receipt can carry (`AshA2A.Chicago.StandingReceipt`)."
  @spec standings() :: [String.t()]
  def standings, do: @standings

  @doc "Repo-local, git-tracked receipt directory for `sha` under `court`."
  @spec receipt_dir(String.t(), String.t()) :: String.t()
  def receipt_dir(court, sha), do: Path.join(Map.fetch!(@courts, court).root, sha)

  @doc "Relative path of the standing receipt inside a receipt directory."
  @spec standing_file(String.t()) :: String.t()
  def standing_file(court), do: Map.fetch!(@courts, court).standing_file

  @doc "Relative path of the conformance receipt inside a receipt directory."
  @spec conformance_file(String.t()) :: String.t()
  def conformance_file(court), do: Map.fetch!(@courts, court).conformance_file

  @doc """
  Resolves the newest SHA carrying an admitted durable receipt.

  Options: `:repo` (default `File.cwd!/0`), `:court` (default `"sa2a"`),
  `:standing` (default `"CONFORMANT"`), `:ref` (default `"HEAD"`; on a
  `main` checkout that is the newest main SHA, elsewhere pass
  `"origin/main"`), `:profile` (e.g. `"SA2A-STRICT"`; default any),
  `:require_conformance` (default `false`), `:artifacts_dir`,
  `:max_commits` (default #{@default_max_commits}).

  Returns `{:ok, resolution}` or `{:error, reason}`; the not-found reason
  `{:no_admitted_receipt, refused}` lists every receipt that was refused and
  why.
  """
  @spec resolve(keyword()) :: {:ok, resolution()} | {:error, term()}
  def resolve(opts \\ []) do
    repo = opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()
    court = Keyword.get(opts, :court, "sa2a")
    ref = Keyword.get(opts, :ref, "HEAD")
    max = Keyword.get(opts, :max_commits, @default_max_commits)

    with {:ok, spec} <- court_spec(court),
         {:ok, wanted} <- wanted_standing(Keyword.get(opts, :standing, "CONFORMANT")),
         {:ok, head} <- rev_parse(repo, ref),
         {:ok, shas} <- first_parent(repo, head, max),
         {:ok, git_index} <- git_index(repo, head, spec),
         {:ok, artifact_index} <- artifact_index(Keyword.get(opts, :artifacts_dir), spec) do
      ctx = %{
        repo: repo,
        spec: spec,
        court: court,
        wanted: wanted,
        admit_opts: [
          profile: Keyword.get(opts, :profile),
          require_conformance: Keyword.get(opts, :require_conformance, false)
        ],
        ref: ref,
        head: head,
        git_index: git_index,
        artifact_index: artifact_index
      }

      walk(shas, ctx, [], 0)
    end
  end

  @doc """
  Admits or refuses one receipt for `sha`: `standing_bytes` is the standing
  receipt JSON, `conformance_bytes` the co-located conformance receipt JSON or
  `nil` when absent. Options: `:profile`, `:require_conformance`. Pure.
  """
  @spec admit(String.t(), binary(), binary() | nil, String.t(), keyword()) ::
          {:ok, %{receipt: map(), conformance: String.t()}} | {:error, term()}
  def admit(sha, standing_bytes, conformance_bytes, wanted, opts \\ []) do
    with {:ok, receipt} <- decode(standing_bytes, :standing_receipt_undecodable),
         :ok <-
           check(
             is_map(receipt) and receipt["standing_schema"] == StandingReceipt.schema(),
             :standing_schema_mismatch
           ),
         :ok <- check(digest_ok?(receipt), :receipt_digest_mismatch),
         {:ok, subject} <- subject(receipt),
         :ok <- check(subject.source_revision == sha, :subject_revision_mismatch),
         :ok <- check(subject.dirty? == false, :subject_dirty),
         :ok <- check(receipt["standing"] == wanted, {:standing_mismatch, receipt["standing"]}),
         :ok <- profile_ok(receipt, Keyword.get(opts, :profile)),
         :ok <- consistent(receipt, sha),
         {:ok, conformance} <-
           conformance(conformance_bytes, subject, Keyword.get(opts, :require_conformance, false)) do
      {:ok, %{receipt: receipt, conformance: conformance}}
    end
  rescue
    # A digest-sealed but structurally malformed receipt is refused, never a crash.
    e -> {:error, {:receipt_malformed, Exception.message(e)}}
  end


  @doc "Re-admit one exact durable receipt source previously returned by resolve/1."
  def replay(sha, court, wanted, receipt_source, opts \\ []) do
    repo = opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()
    with {:ok, spec} <- court_spec(court),
         {:ok, source} <- source_from_label(receipt_source, spec),
         {:ok, standing_bytes} <- read(source, spec.standing_file, repo),
         {:ok, conformance_bytes} <- replay_optional(source, spec.conformance_file, repo) do
      admit(sha, standing_bytes, conformance_bytes, wanted,
        profile: Keyword.get(opts, :profile),
        require_conformance: Keyword.get(opts, :require_conformance, false))
    end
  end
  defp source_from_label("git:" <> rest, spec) do
    case String.split(rest, ":", parts: 2) do
      [head, path] ->
        suffix = "/" <> spec.standing_file
        if String.ends_with?(path, suffix),
          do: {:ok, {:git, head, String.replace_suffix(path, suffix, "")}},
          else: {:error, :standing_receipt_source_invalid}
      _ -> {:error, :standing_receipt_source_invalid}
    end
  end
  defp source_from_label("artifact:" <> path, spec) do
    suffix = "/" <> spec.standing_file
    if String.ends_with?(path, suffix),
      do: {:ok, {:artifact, String.replace_suffix(path, suffix, "")}},
      else: {:error, :standing_receipt_source_invalid}
  end
  defp source_from_label(_, _), do: {:error, :standing_receipt_source_invalid}
  defp replay_optional({:git, head, dir} = source, file, repo) do
    case git(repo, ["cat-file", "-e", {:object, head, "#{dir}/#{file}"}]) do
      {:ok, _} -> read(source, file, repo)
      {:error, _} -> {:ok, nil}
    end
  end
  defp replay_optional({:artifact, dir} = source, file, repo) do
    if File.exists?(Path.join(dir, file)), do: read(source, file, repo), else: {:ok, nil}
  end

  # --- walk ------------------------------------------------------------------

  defp walk([], _ctx, refused, walked),
    do: {:error, {:no_admitted_receipt, Enum.reverse(refused), walked}}

  defp walk([sha | rest], ctx, refused, walked) do
    sources =
      Enum.map(Map.get(ctx.git_index, sha, []), &{:git, ctx.head, &1}) ++
        Enum.map(Map.get(ctx.artifact_index, sha, []), &{:artifact, &1})

    case try_sources(sha, sources, ctx, refused) do
      {:ok, resolution, refused} ->
        {:ok,
         Map.merge(resolution, %{
           refused: Enum.reverse(refused),
           commits_walked: walked + 1
         })}

      {:none, refused} ->
        walk(rest, ctx, refused, walked + 1)
    end
  end

  defp try_sources(_sha, [], _ctx, refused), do: {:none, refused}

  defp try_sources(sha, [source | rest], ctx, refused) do
    label = source_label(source, ctx.spec)

    result =
      with {:ok, standing_bytes} <- read(source, ctx.spec.standing_file, ctx.repo),
           {:ok, conformance_bytes} <- read_optional(source, ctx.spec.conformance_file, ctx) do
        admit(sha, standing_bytes, conformance_bytes, ctx.wanted, ctx.admit_opts)
      end

    case result do
      {:ok, %{receipt: receipt, conformance: conformance}} ->
        {:ok,
         %{
           sha: sha,
           court: ctx.court,
           standing: receipt["standing"],
           profile: get_in(receipt, ["subject", "claimed_profile"]),
           ref: ctx.ref,
           ref_sha: ctx.head,
           receipt_digest: receipt["receipt_digest"],
           receipt_source: label,
           conformance: conformance
         }, refused}

      {:error, reason} ->
        try_sources(sha, rest, ctx, [%{sha: sha, source: label, reason: reason} | refused])
    end
  end

  # --- indexes -----------------------------------------------------------------

  defp git_index(repo, head, spec) do
    case git(repo, ["ls-tree", "-r", "--name-only", {:ref, head}, "--", {:path, spec.root}]) do
      {:ok, out} ->
        suffix = "/" <> spec.standing_file
        prefix = spec.root <> "/"

        index =
          out
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn path ->
            with true <- String.starts_with?(path, prefix) and String.ends_with?(path, suffix),
                 dir = String.replace_suffix(path, suffix, ""),
                 sha = String.replace_prefix(dir, prefix, ""),
                 true <- Regex.match?(@sha, sha) do
              [{sha, dir}]
            else
              _ -> []
            end
          end)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        {:ok, index}

      {:error, reason} ->
        {:error, {:receipt_index_unreadable, reason}}
    end
  end

  defp artifact_index(nil, _spec), do: {:ok, %{}}

  defp artifact_index(dir, spec) do
    dir = Path.expand(dir)

    case File.ls(dir) do
      {:ok, entries} ->
        index =
          entries
          |> Enum.flat_map(fn entry ->
            sha = String.replace_prefix(entry, spec.artifact_prefix, "")

            if String.starts_with?(entry, spec.artifact_prefix) and Regex.match?(@sha, sha) and
                 File.regular?(Path.join([dir, entry, spec.standing_file])),
               do: [{sha, Path.join(dir, entry)}],
               else: []
          end)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        {:ok, index}

      {:error, posix} ->
        {:error, {:artifacts_dir_unreadable, dir, posix}}
    end
  end

  # --- reading -------------------------------------------------------------------

  defp read({:git, head, dir}, file, repo) do
    case git(repo, ["cat-file", "blob", {:object, head, "#{dir}/#{file}"}]) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:receipt_unreadable, reason}}
    end
  end

  defp read({:artifact, dir}, file, _repo) do
    case File.read(Path.join(dir, file)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, posix} -> {:error, {:receipt_unreadable, posix}}
    end
  end

  defp read_optional({:git, head, dir} = source, file, ctx) do
    case git(ctx.repo, ["cat-file", "-e", {:object, head, "#{dir}/#{file}"}]) do
      {:ok, _} -> read(source, file, ctx.repo)
      {:error, _} -> {:ok, nil}
    end
  end

  defp read_optional({:artifact, dir} = source, file, ctx) do
    if File.exists?(Path.join(dir, file)), do: read(source, file, ctx.repo), else: {:ok, nil}
  end

  defp source_label({:git, head, dir}, spec), do: "git:#{head}:#{dir}/#{spec.standing_file}"
  defp source_label({:artifact, dir}, spec), do: "artifact:#{Path.join(dir, spec.standing_file)}"

  # --- admission checks ----------------------------------------------------------

  defp digest_ok?(%{"receipt_digest" => d} = receipt) when is_binary(d),
    do: StandingReceipt.verify_digest(receipt) == :ok

  defp digest_ok?(_), do: false

  defp subject(%{"subject" => section}) do
    case Subject.from_map(section) do
      {:ok, subject} -> {:ok, subject}
      :error -> {:error, :subject_identity_mismatch}
    end
  end

  defp subject(_), do: {:error, :subject_identity_mismatch}

  defp profile_ok(_receipt, nil), do: :ok

  defp profile_ok(receipt, profile) do
    claimed = get_in(receipt, ["subject", "claimed_profile"])
    check(claimed == profile, {:profile_mismatch, claimed})
  end

  # A CONFORMANT standing must be what `StandingReceipt.recompute/1` would
  # issue from the receipt's own recorded facts (§130: every required gate
  # passed, nothing survived/unknown/blocked/uncorroborated, OCEL admitted).
  defp consistent(%{"standing" => "CONFORMANT"} = receipt, sha) do
    r = if is_map(receipt["results"]), do: receipt["results"], else: %{}
    e = if is_map(receipt["evidence"]), do: receipt["evidence"], else: %{}
    gates = if is_list(receipt["gates"]), do: receipt["gates"], else: [:malformed]
    zero = &(Map.get(r, &1) == 0)
    int = &if(is_integer(Map.get(r, &1)), do: Map.get(r, &1), else: 0)

    facts = [
      int.("falsifiers_total") - int.("unsupported") - int.("not_applicable") > 0,
      Enum.all?(
        ~w(falsifiers_survived positive_controls_failed build_broken unknown blocked uncorroborated
           gates_failed gates_open gates_missing),
        zero
      ),
      is_integer(r["gates_required"]) and r["gates_required"] == r["gates_passed"],
      Enum.all?(gates, &(is_map(&1) and (&1["required"] != true or &1["status"] == "PASSED"))),
      e["ocel_valid"] == true,
      e["ocel_dropped_records"] == 0,
      e["ocel_gaps"] == 0,
      get_in(receipt, ["subject", "verification", "outcome"]) != "mismatch",
      is_binary(receipt["claim"]) and
        String.contains?(receipt["claim"], "CONFORMANT for exact subject " <> sha)
    ]

    check(Enum.all?(facts), :standing_inconsistent_with_receipt)
  end

  defp consistent(_receipt, _sha), do: :ok

  defp conformance(nil, _subject, true), do: {:error, :conformance_absent}
  defp conformance(nil, _subject, false), do: {:ok, "ABSENT"}

  defp conformance(bytes, subject, require?) do
    with {:ok, doc} <- decode(bytes, :conformance_undecodable),
         :ok <- check(is_map(doc), :conformance_undecodable),
         :ok <-
           check(
             doc["wasm_digest_algorithm"] == "sha256" and
               doc["wasm_digest"] == subject.validator_digests["graphlaw_wasm"],
             :conformance_wasm_not_subject_wasm
           ),
         :ok <- check(doc["result"] in ["PASS", "FAIL"], {:conformance_result, result(doc)}),
         :ok <-
           check(
             doc["result"] != "PASS" or assertions_passed?(doc["assertions"]),
             :conformance_assertion_not_passed
           ),
         :ok <-
           check(not require? or doc["result"] == "PASS", {:conformance_result, doc["result"]}) do
      {:ok, doc["result"]}
    end
  end

  defp result(doc) when is_map(doc), do: doc["result"]
  defp result(_), do: nil

  defp assertions_passed?(assertions) when is_map(assertions) and map_size(assertions) > 0,
    do: Enum.all?(assertions, fn {_, a} -> a["computed"] == true and a["value"] == true end)

  defp assertions_passed?(_), do: false

  # --- plumbing ----------------------------------------------------------------------

  defp court_spec(court) do
    case Map.fetch(@courts, court) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unsupported_court, court}}
    end
  end

  defp wanted_standing(standing) do
    if standing in @standings, do: {:ok, standing}, else: {:error, {:unknown_standing, standing}}
  end

  defp rev_parse(repo, ref) do
    case git(repo, ["rev-parse", "--verify", "--quiet", {:commit_ref, ref}]) do
      {:ok, out} ->
        sha = String.trim(out)
        if Regex.match?(@sha, sha), do: {:ok, sha}, else: {:error, {:ref_unresolvable, ref}}

      {:error, _} ->
        {:error, {:ref_unresolvable, ref}}
    end
  end

  defp first_parent(repo, head, max) do
    case git(repo, ["rev-list", "--first-parent", "--max-count=#{max}", {:ref, head}]) do
      {:ok, out} -> {:ok, String.split(out, "\n", trim: true)}
      {:error, reason} -> {:error, {:history_unreadable, reason}}
    end
  end

  defp decode(bytes, reason) do
    case JSON.decode(bytes) do
      {:ok, doc} -> {:ok, doc}
      {:error, _} -> {:error, reason}
    end
  end

  defp check(true, _reason), do: :ok
  defp check(_, reason), do: {:error, reason}

  defp git(repo, args) do
    case AshA2A.SafeExec.run(:git, args, cd: repo, stderr_to_stdout: true) do
      {:ok, %{output: out, exit: 0}} -> {:ok, out}
      {:ok, %{output: out, exit: code}} -> {:error, {:git_exit, code, String.trim(out)}}
      {:error, %{code: :safe_exec_unavailable} = e} -> {:error, {:git_unavailable, inspect(e)}}
      {:error, refusal} -> {:error, {:git_refused, refusal}}
    end
  end

  @doc false
  # S42 refusal totality: every typed refusal this module returns is classified
  # (merged into AshA2A.Semantic.Refusal.mapping/0 via AshA2A.Chicago.refusal_codes/0).
  def __sa2a_refusal_codes__ do
    %{
      conformance_absent: :refused_receipt,
      subject_identity_mismatch: :refused_identity
    }
  end
end
