defmodule AshA2A.Chicago.Subject do
  @moduledoc """
  Exact-subject identity (RFC-SA2A-002 §5-§6, Gate 1 §32, §126).

  Conformance attaches to an exact subject, never a repository name, branch
  label, or architecture diagram. `capture/1` records, from the real
  environment:

    * `source_revision` -- `git rev-parse --verify HEAD^{commit}` (validated
      as a hex object id), plus `dirty?` (uncommitted tracked changes make
      the source identity non-reproducible). A branch name is never recorded
      as identity: a mutable label confers nothing (§5).
    * `tag` / `tag_commit` -- the tag under qualification (`:tag`, else the
      tag exactly at HEAD) and the commit `refs/tags/<tag>^{commit}` really
      resolves to NOW; §5 requires `TagCommit = VerifiedCommit`
    * `version` -- the release CalVer (`:version`, else derived from the tag);
      identity, never an ordering (§120)
    * `artifact_digests` -- sha256 of each executable artifact (wasm engines,
      host scripts) given via `:artifacts` or discovered under `priv/`
    * `root_manifest_digest` -- sha256 of the `:root_manifest` file, or an
      explicit `:root_manifest_digest`; `nil` when unbound (recorded, never
      invented)
    * `validator_digests` -- sha256 of each validator / rule-set file
      (`:validators`; default: the SHACL/ShEx/N3/SPARQL files under `priv/`
      plus the GraphLaw wasm the admission boundary loads)
    * `runtime` -- OTP release, ERTS, Elixir, architecture, relevant dep
      versions, and `emulator_sha256`: the digest of the emulator executable
      the OS reports for this node, so two runtimes carrying the same
      version strings are not normalized into one identity (§126)
    * `config_digest` -- sha256 over the sorted `:ash_a2a` application env
    * `lock_digest` -- sha256 of `mix.lock`

  `digest/1` content-addresses the whole subject; `verify/2` compares a
  claimed subject against a freshly captured one field by field, and emits
  `[:ash_a2a, :chicago, :subject, :verified]` with `outcome: :match |
  :mismatch` and the mismatched `fields`, so a moved branch, moved tag,
  substituted artifact, altered manifest, changed rule set, or different
  runtime is detected -- observably -- before standing is issued.
  `AshA2A.Chicago.Runner` verifies its `:claimed_subject` option through
  `verify_claim/2` and issues `REFUSED` standing on a mismatch.
  """

  @enforce_keys [:repo, :source_revision]
  defstruct [
    :repo,
    :source_revision,
    :dirty?,
    :tag,
    :tag_commit,
    :version,
    :root_manifest_digest,
    :config_digest,
    :lock_digest,
    artifact_digests: %{},
    validator_digests: %{},
    runtime: %{}
  ]

  @type t :: %__MODULE__{
          repo: Path.t() | nil,
          source_revision: String.t() | nil,
          dirty?: boolean() | nil,
          tag: String.t() | nil,
          tag_commit: String.t() | nil,
          version: String.t() | nil,
          root_manifest_digest: String.t() | nil,
          config_digest: String.t() | nil,
          lock_digest: String.t() | nil,
          artifact_digests: %{String.t() => String.t() | nil},
          validator_digests: %{String.t() => String.t() | nil},
          runtime: %{String.t() => String.t() | nil}
        }

  @type verification ::
          :not_claimed
          | {:match, String.t()}
          | {:mismatch, String.t() | nil, [atom()]}

  @identity_fields [
    :source_revision,
    :tag,
    :tag_commit,
    :version,
    :root_manifest_digest,
    :validator_digests,
    :config_digest,
    :lock_digest,
    :artifact_digests,
    :runtime
  ]

  @verified_event [:ash_a2a, :chicago, :subject, :verified]

  @runtime_deps [:ash, :a2a, :wasmex, :rdf, :telemetry]
  @object_id ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @calver ~r/\Av?(\d{2,4}\.\d{1,2}\.\d{1,3}(?:[-+][0-9A-Za-z.\-]+)?)\z/

  @doc "The fields `verify/2` compares, in report order."
  @spec identity_fields() :: [atom()]
  def identity_fields, do: @identity_fields

  @doc "The telemetry event `verify/2` emits."
  @spec verified_event() :: [atom()]
  def verified_event, do: @verified_event

  @doc """
  Captures the subject. Options: `:repo` (default `File.cwd!/0`), `:tag`,
  `:version`, `:artifacts` (paths; default every `priv/**/*.{wasm,mjs}` under
  the repo), `:root_manifest` (path) or `:root_manifest_digest`,
  `:validators` (paths).
  """
  @spec capture(keyword()) :: t()
  def capture(opts \\ []) do
    repo = opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()
    tag = Keyword.get_lazy(opts, :tag, fn -> exact_tag(repo) end)

    %__MODULE__{
      repo: repo,
      source_revision: commit(repo, "HEAD"),
      dirty?: dirty?(repo),
      tag: tag,
      tag_commit: tag && commit(repo, "refs/tags/" <> tag),
      version: Keyword.get_lazy(opts, :version, fn -> calver(tag) end),
      root_manifest_digest: root_manifest_digest(opts),
      config_digest: config_digest(),
      lock_digest: file_sha256(Path.join(repo, "mix.lock")),
      artifact_digests: artifact_digests(repo, Keyword.get(opts, :artifacts)),
      validator_digests: validator_digests(repo, Keyword.get(opts, :validators)),
      runtime: runtime()
    }
  end

  @doc "sha256 over the JSON form (repo path excluded: identity is content, not location)."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = subject) do
    subject
    |> to_map()
    |> Map.delete("repo")
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Compares a claimed subject to an observed one. Returns `:ok` or
  `{:error, {:subject_mismatch, [field]}}` naming every differing identity
  field. A dirty observed source tree, or an observed tag whose commit is not
  the observed revision (`TagCommit != VerifiedCommit`), is always a mismatch.

  Emits `[:ash_a2a, :chicago, :subject, :verified]` either way.
  """
  @spec verify(t(), t()) :: :ok | {:error, {:subject_mismatch, [atom()]}}
  def verify(%__MODULE__{} = claimed, %__MODULE__{} = observed) do
    mismatched =
      Enum.filter(@identity_fields, &(Map.get(claimed, &1) != Map.get(observed, &1))) ++
        if(observed.dirty? != false, do: [:dirty?], else: []) ++
        if(observed.tag && observed.tag_commit != observed.source_revision,
          do: [:tag_commit],
          else: []
        )

    result =
      case Enum.uniq(mismatched) do
        [] -> :ok
        fields -> {:error, {:subject_mismatch, fields}}
      end

    emit_verified(claimed, observed, result)
    result
  end

  @doc """
  Verifies a claim (a `t()`, or its JSON map form as found in a durable
  standing receipt) against the observed subject. A claim that cannot be
  read, or whose recorded `identity` does not match its own content, is a
  mismatch on `:claimed_subject` -- never silently ignored.
  """
  @spec verify_claim(t() | map() | nil, t()) :: verification()
  def verify_claim(nil, %__MODULE__{}), do: :not_claimed

  def verify_claim(claim, %__MODULE__{} = observed) do
    case from_claim(claim) do
      {:ok, claimed} ->
        case verify(claimed, observed) do
          :ok -> {:match, digest(claimed)}
          {:error, {:subject_mismatch, fields}} -> {:mismatch, digest(claimed), fields}
        end

      :error ->
        emit(:mismatch, [:claimed_subject], nil, observed)
        {:mismatch, nil, [:claimed_subject]}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = s) do
    %{
      "repo" => s.repo,
      "source_revision" => s.source_revision,
      "dirty" => s.dirty?,
      "tag" => s.tag,
      "tag_commit" => s.tag_commit,
      "version" => s.version,
      "root_manifest_digest" => s.root_manifest_digest,
      "config_digest" => s.config_digest,
      "lock_digest" => s.lock_digest,
      "artifact_digests" => s.artifact_digests,
      "validator_digests" => s.validator_digests,
      "runtime" => s.runtime
    }
  end

  @doc """
  Rebuilds a subject from its JSON map (`to_map/1`, or a standing receipt's
  `"subject"` section). When the map carries an `"identity"`, it must equal
  the digest of the rebuilt subject, so a tampered subject section is refused.
  """
  @spec from_map(map()) :: {:ok, t()} | :error
  def from_map(%{"source_revision" => revision} = map) do
    subject = %__MODULE__{
      repo: map["repo"],
      source_revision: revision,
      dirty?: map["dirty"],
      tag: map["tag"],
      tag_commit: map["tag_commit"],
      version: map["version"],
      root_manifest_digest: map["root_manifest_digest"],
      config_digest: map["config_digest"],
      lock_digest: map["lock_digest"],
      artifact_digests: map["artifact_digests"] || %{},
      validator_digests: map["validator_digests"] || %{},
      runtime: map["runtime"] || %{}
    }

    case map["identity"] do
      nil -> {:ok, subject}
      identity -> if identity == digest(subject), do: {:ok, subject}, else: :error
    end
  end

  def from_map(_), do: :error

  @doc "Deterministic JSON: object keys sorted recursively."
  @spec canonical_json(term()) :: String.t()
  def canonical_json(term), do: AshA2A.Chicago.Json.canonical(term)

  @spec file_sha256(Path.t()) :: String.t() | nil
  def file_sha256(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      {:error, _} -> nil
    end
  end

  # --- claim / telemetry -----------------------------------------------------

  defp from_claim(%__MODULE__{} = subject), do: {:ok, subject}
  defp from_claim(%{} = map), do: from_map(map)
  defp from_claim(_), do: :error

  defp emit_verified(claimed, observed, :ok), do: emit(:match, [], claimed, observed)

  defp emit_verified(claimed, observed, {:error, {:subject_mismatch, fields}}),
    do: emit(:mismatch, fields, claimed, observed)

  defp emit(outcome, fields, claimed, observed) do
    :telemetry.execute(@verified_event, %{field_count: length(fields)}, %{
      outcome: outcome,
      fields: fields,
      claimed_identity: claimed && digest(claimed),
      observed_identity: digest(observed),
      claimed_source_revision: claimed && claimed.source_revision,
      source_revision: observed.source_revision
    })
  end

  # --- capture ---------------------------------------------------------------

  defp exact_tag(repo) do
    case git(repo, ["describe", "--exact-match", "--tags", "HEAD"]) do
      nil -> nil
      tag -> if String.contains?(tag, ["\n", " "]), do: nil, else: tag
    end
  end

  defp commit(repo, ref) do
    case git(repo, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]) do
      nil -> nil
      out -> if Regex.match?(@object_id, out), do: out, else: nil
    end
  end

  defp calver(nil), do: nil

  defp calver(tag) do
    case Regex.run(@calver, tag, capture: :all_but_first) do
      [version] -> version
      _ -> nil
    end
  end

  defp root_manifest_digest(opts) do
    case Keyword.fetch(opts, :root_manifest_digest) do
      {:ok, digest} ->
        digest

      :error ->
        case Keyword.get(opts, :root_manifest) do
          nil -> nil
          path -> file_sha256(path)
        end
    end
  end

  defp artifact_digests(repo, nil) do
    repo
    |> Path.join("priv/**/*.{wasm,mjs}")
    |> Path.wildcard()
    |> digests_for(repo)
  end

  defp artifact_digests(repo, paths) when is_list(paths), do: digests_for(paths, repo)

  defp validator_digests(repo, nil) do
    rule_files =
      [
        "priv/**/*.shacl.ttl",
        "priv/**/*.shex",
        "priv/**/*.n3",
        "priv/**/*.rq"
      ]
      |> Enum.flat_map(&Path.wildcard(Path.join(repo, &1)))
      |> Enum.uniq()
      |> digests_for(repo)

    wasm = AshA2A.GraphLaw.Runtime.wasm_path()

    if File.regular?(wasm),
      do: Map.put(rule_files, "graphlaw_wasm", file_sha256(wasm)),
      else: rule_files
  end

  defp validator_digests(repo, paths) when is_list(paths), do: digests_for(paths, repo)

  defp digests_for(paths, repo) do
    paths
    |> Enum.map(&Path.expand/1)
    |> Enum.sort()
    |> Map.new(fn path -> {relative_key(path, repo), file_sha256(path)} end)
  end

  defp relative_key(path, repo) do
    if String.starts_with?(path, repo <> "/"), do: Path.relative_to(path, repo), else: path
  end

  defp runtime do
    deps =
      Map.new(@runtime_deps, fn app ->
        {"dep:" <> Atom.to_string(app), app |> Application.spec(:vsn) |> to_string()}
      end)

    Map.merge(deps, %{
      "otp_release" => to_string(:erlang.system_info(:otp_release)),
      "erts" => to_string(:erlang.system_info(:version)),
      "elixir" => System.version(),
      "architecture" => to_string(:erlang.system_info(:system_architecture)),
      "emulator_sha256" => AshA2A.RuntimeIdentity.os_executable_sha256(System.pid())
    })
  end

  defp config_digest do
    :ash_a2a
    |> Application.get_all_env()
    |> Enum.sort()
    |> inspect(limit: :infinity, printable_limit: :infinity)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp dirty?(repo) do
    case System.cmd("git", ["status", "--porcelain", "--untracked-files=no"],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out) != ""
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp git(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
