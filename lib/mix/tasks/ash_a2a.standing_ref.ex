defmodule Mix.Tasks.AshA2a.StandingRef do
  @shortdoc "Prints the newest SHA with a durable court receipt at a given standing"

  @moduledoc """
  Standing-addressed dependency resolution (DfCM composition C03): prints the
  newest commit whose durable court receipt is admitted at the requested
  standing, so consumers pin that exact SHA as a git `ref:` instead of a
  version number. See `AshA2A.StandingRef` for the durable receipt locations
  and the admission checks.

      mix ash_a2a.standing_ref --court sa2a --standing CONFORMANT
      mix ash_a2a.standing_ref --court sa2a --standing CONFORMANT --ref origin/main --format dep
      mix ash_a2a.standing_ref --court sa2a --artifacts ./ci-artifacts --format json

  ## Options

    * `--court` -- court whose receipts address the dependency (default `sa2a`)
    * `--standing` -- required standing (default `CONFORMANT`)
    * `--ref` -- line of history to walk, first-parent (default `HEAD`; on a
      `main` checkout that is the newest main SHA)
    * `--repo` -- repository path (default: current directory)
    * `--profile` -- require this claimed profile, e.g. `SA2A-STRICT`
    * `--artifacts` -- directory of downloaded `sa2a-conformance-<sha>/` CI
      artifacts, read in addition to the git-tracked receipts
    * `--max-commits` -- bound on the history walk (default 1000)
    * `--format` -- `sha` (default: the SHA alone), `dep` (a `mix.exs`
      dependency tuple pinned to the SHA), or `json` (the full resolution,
      including every refused receipt and why)
    * `--git-url` -- repository URL for `--format dep` (default: the
      `origin` remote)

  ## Exit status

  `0` with the SHA printed when a receipt is admitted; non-zero, with the
  typed refusals on stderr, when none is -- an absent or refused receipt
  never resolves to a SHA.
  """

  use Mix.Task

  alias AshA2A.StandingRef

  @switches [
    court: :string,
    standing: :string,
    ref: :string,
    repo: :string,
    profile: :string,
    artifacts: :string,
    max_commits: :integer,
    format: :string,
    git_url: :string
  ]

  @formats ~w(sha dep json)

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [] or rest != [], do: Mix.raise("invalid options: #{inspect(invalid ++ rest)}")

    format = Keyword.get(opts, :format, "sha")

    unless format in @formats,
      do: Mix.raise("--format must be one of #{Enum.join(@formats, ", ")}")

    Mix.Task.run("compile", [])

    resolve_opts =
      [
        repo: opts[:repo],
        court: opts[:court],
        standing: opts[:standing],
        ref: opts[:ref],
        profile: opts[:profile],
        artifacts_dir: opts[:artifacts],
        max_commits: opts[:max_commits]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case StandingRef.resolve(resolve_opts) do
      {:ok, resolution} ->
        emit(format, resolution, opts)

      {:error, {:no_admitted_receipt, refused, walked}} ->
        Enum.each(refused, fn r ->
          Mix.shell().error("refused #{r.sha} (#{r.source}): #{inspect(r.reason)}")
        end)

        Mix.raise(
          "no durable #{Keyword.get(opts, :court, "sa2a")} receipt admitted at standing " <>
            "#{Keyword.get(opts, :standing, "CONFORMANT")} in #{walked} commit(s) of " <>
            "#{Keyword.get(opts, :ref, "HEAD")}; #{length(refused)} receipt(s) refused"
        )

      {:error, reason} ->
        Mix.raise("standing_ref refused: #{inspect(reason)}")
    end
  end

  defp emit("sha", resolution, _opts), do: Mix.shell().info(resolution.sha)

  defp emit("dep", resolution, opts) do
    url = opts[:git_url] || origin_url(Keyword.get(opts, :repo, File.cwd!()))
    Mix.shell().info(~s({:ash_a2a, git: "#{url}", ref: "#{resolution.sha}"}))
  end

  defp emit("json", resolution, _opts) do
    resolution
    |> Map.update!(:refused, fn refused ->
      Enum.map(refused, &%{&1 | reason: inspect(&1.reason)})
    end)
    |> JSON.encode!()
    |> Mix.shell().info()
  end

  defp origin_url(repo) do
    case System.cmd("git", ["config", "--get", "remote.origin.url"],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {url, 0} -> String.trim(url)
      _ -> Mix.raise("no origin remote in #{repo}; pass --git-url")
    end
  end
end
