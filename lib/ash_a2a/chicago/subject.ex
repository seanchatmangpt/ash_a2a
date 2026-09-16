defmodule AshA2A.Chicago.Subject do
  @moduledoc """
  Exact-subject identity (RFC-SA2A-002 §5-§6, Gate 1 §32).

  Conformance attaches to an exact subject, never a repository name, branch
  label, or architecture diagram. `capture/1` records, from the real
  environment:

    * `source_revision` -- `git rev-parse HEAD`, plus `dirty?` (uncommitted
      tracked changes make the source identity non-reproducible)
    * `tag` / `tag_commit` -- when HEAD is exactly tagged; §6 requires
      `TagCommit = VerifiedCommit`
    * `artifact_digests` -- sha256 of each executable artifact (wasm engines,
      host scripts) given via `:artifacts` or discovered under `priv/`
    * `root_manifest_digest` -- from `:root_manifest_digest`, else `nil`
      (an unbound manifest is recorded, never invented)
    * `runtime` -- OTP release, ERTS, Elixir, architecture, relevant dep versions
    * `config_digest` -- sha256 over the sorted `:ash_a2a` application env
    * `lock_digest` -- sha256 of `mix.lock`

  `digest/1` content-addresses the whole subject; `verify/2` compares a
  claimed subject against a freshly captured one field by field so a moved
  branch, substituted artifact, altered manifest, or different runtime is
  detected before standing is issued.
  """

  @enforce_keys [:repo, :source_revision]
  defstruct [
    :repo,
    :source_revision,
    :dirty?,
    :tag,
    :tag_commit,
    :root_manifest_digest,
    :config_digest,
    :lock_digest,
    artifact_digests: %{},
    runtime: %{}
  ]

  @type t :: %__MODULE__{
          repo: Path.t(),
          source_revision: String.t() | nil,
          dirty?: boolean() | nil,
          tag: String.t() | nil,
          tag_commit: String.t() | nil,
          root_manifest_digest: String.t() | nil,
          config_digest: String.t(),
          lock_digest: String.t() | nil,
          artifact_digests: %{String.t() => String.t()},
          runtime: %{String.t() => String.t()}
        }

  @runtime_deps [:ash, :a2a, :wasmex, :rdf, :telemetry]

  @doc """
  Captures the subject. Options: `:repo` (default `File.cwd!/0`),
  `:artifacts` (paths; default every `priv/**/*.{wasm,mjs}` under the repo),
  `:root_manifest_digest`.
  """
  @spec capture(keyword()) :: t()
  def capture(opts \\ []) do
    repo = Keyword.get(opts, :repo, File.cwd!())
    revision = git(repo, ["rev-parse", "HEAD"])
    tag = git(repo, ["describe", "--exact-match", "--tags", "HEAD"])

    %__MODULE__{
      repo: repo,
      source_revision: revision,
      dirty?: dirty?(repo),
      tag: tag,
      tag_commit: tag && git(repo, ["rev-list", "-n", "1", tag]),
      root_manifest_digest: Keyword.get(opts, :root_manifest_digest),
      config_digest: config_digest(),
      lock_digest: file_sha256(Path.join(repo, "mix.lock")),
      artifact_digests: artifact_digests(repo, Keyword.get(opts, :artifacts)),
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
  field. A dirty source tree or a tag whose commit is not the verified
  revision is always a mismatch.
  """
  @spec verify(t(), t()) :: :ok | {:error, {:subject_mismatch, [atom()]}}
  def verify(%__MODULE__{} = claimed, %__MODULE__{} = observed) do
    fields = [
      :source_revision,
      :tag,
      :tag_commit,
      :root_manifest_digest,
      :config_digest,
      :lock_digest,
      :artifact_digests,
      :runtime
    ]

    mismatched = Enum.filter(fields, &(Map.fetch!(claimed, &1) != Map.fetch!(observed, &1)))

    mismatched =
      mismatched ++
        if(observed.dirty? != false, do: [:dirty?], else: []) ++
        if(observed.tag && observed.tag_commit != observed.source_revision,
          do: [:tag_commit],
          else: []
        )

    case Enum.uniq(mismatched) do
      [] -> :ok
      fields -> {:error, {:subject_mismatch, fields}}
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
      "root_manifest_digest" => s.root_manifest_digest,
      "config_digest" => s.config_digest,
      "lock_digest" => s.lock_digest,
      "artifact_digests" => s.artifact_digests,
      "runtime" => s.runtime
    }
  end

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

  defp artifact_digests(repo, nil) do
    repo
    |> Path.join("priv/**/*.{wasm,mjs}")
    |> Path.wildcard()
    |> artifact_digests_for(repo)
  end

  defp artifact_digests(repo, paths) when is_list(paths), do: artifact_digests_for(paths, repo)

  defp artifact_digests_for(paths, repo) do
    paths
    |> Enum.sort()
    |> Map.new(fn path -> {Path.relative_to(path, repo), file_sha256(path)} end)
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
      "architecture" => to_string(:erlang.system_info(:system_architecture))
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
