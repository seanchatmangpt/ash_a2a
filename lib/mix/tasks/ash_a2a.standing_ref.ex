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
    * `--require-conformance` -- also refuse a SHA whose co-located
      portable-conformance receipt is absent or not `PASS` (by default it is
      identity-checked and reported, since the Chicago standing already
      adjudicates it; see `AshA2A.StandingRef`)
    * `--artifacts` -- directory of downloaded `sa2a-conformance-<sha>/` CI
      artifacts, read in addition to the git-tracked receipts
    * `--max-commits` -- bound on the history walk (default 1000)
    * `--format` -- `sha` (default: the SHA alone), `dep` (a `mix.exs`
      dependency tuple pinned to the SHA), or `json` (the full resolution,
      including every refused receipt and why)
    * `--git-url` -- repository URL for `--format dep` (default: the
      `origin` remote)

  ## Output

  stdout carries the resolution and nothing else, so
  `ref=$(mix ash_a2a.standing_ref ...)` captures exactly the SHA (or the
  `dep`/`json` rendering). The compile this task runs first -- which on a cold
  or stale `_build` prints `Compiling N files (.ex)` / `Generated ash_a2a app`
  -- is redirected to stderr, as are the refusals. In this repository the
  `ash_a2a.standing_ref` alias in `mix.exs` compiles the same way before Mix
  dispatches the task, which covers a `_build` so cold that the task module
  itself is not compiled yet. Where `ash_a2a` is a dependency, Mix compiles
  dependencies before any task runs: `MIX_QUIET=1` silences that, and the
  resolution is still printed (it is written to stdout directly, not through
  `Mix.shell().info/1`).

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
    require_conformance: :boolean,
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

    on_stderr(fn -> Mix.Task.run("compile", []) end)

    resolve_opts =
      [
        repo: opts[:repo],
        court: opts[:court],
        standing: opts[:standing],
        ref: opts[:ref],
        profile: opts[:profile],
        require_conformance: opts[:require_conformance],
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

  @doc false
  # Runs `fun` with this process's group leader -- inherited by every process
  # it spawns, e.g. the parallel compiler -- set to stderr, so `:stdio` output
  # such as `Mix.Shell.IO.info/1`'s compile progress never reaches stdout.
  def on_stderr(fun) do
    stdout = Process.group_leader()
    Process.group_leader(self(), Process.whereis(:standard_error))

    try do
      fun.()
    after
      Process.group_leader(self(), stdout)
    end
  end

  # The resolution is the task's product, not an informational message: it is
  # written to stdout directly so `MIX_QUIET=1` (`Mix.Shell.Quiet`) keeps it.
  defp emit("sha", resolution, _opts), do: IO.puts(resolution.sha)

  defp emit("dep", resolution, opts) do
    url = opts[:git_url] || origin_url(Keyword.get(opts, :repo, File.cwd!()))
    IO.puts(~s({:ash_a2a, git: "#{url}", ref: "#{resolution.sha}"}))
  end

  defp emit("json", resolution, _opts) do
    resolution
    |> Map.update!(:refused, fn refused ->
      Enum.map(refused, &%{&1 | reason: inspect(&1.reason)})
    end)
    |> JSON.encode!()
    |> IO.puts()
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
