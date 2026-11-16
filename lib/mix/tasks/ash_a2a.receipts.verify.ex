defmodule Mix.Tasks.AshA2a.Receipts.Verify do
  @shortdoc "Verify receipt hashes, cited tests, standing and run-log consistency"

  @moduledoc """
  Verifies Markdown receipts with `AshA2A.Receipts.Verifier`. Read-only.
  UNVERIFIED: never compiled or run.

  ## Usage

      mix ash_a2a.receipts.verify
      mix ash_a2a.receipts.verify receipts/lanes/t11-pplan-census.md --root .

  With no paths it checks `receipts/**/*.md` and
  `docs/archive/jira-releases/*/RECEIPT.md`.

  ## Options

    * `--root` -- directory cited paths resolve against (default: cwd)
    * `--git` -- also check `Commit:` lines with `git cat-file -e`

  Exits non-zero (via `Mix.raise/1`) when any finding has error severity.
  """

  use Mix.Task

  alias AshA2A.Receipts.Verifier

  @impl true
  def run(args) do
    {opts, paths} = OptionParser.parse!(args, strict: [root: :string, git: :boolean])
    root = Path.expand(opts[:root] || File.cwd!())

    vopts =
      [root: root] ++
        if(opts[:git], do: [commit_exists: &commit_exists?(&1, root)], else: [])

    files = if paths == [], do: default_files(root), else: paths

    findings = Enum.flat_map(files, &Verifier.verify_file(&1, vopts))

    for f <- findings do
      Mix.shell().info("#{f.severity} #{f.code} #{f.receipt}: #{f.detail}")
    end

    Mix.shell().info("#{length(files)} receipt(s), #{length(findings)} finding(s)")

    unless Verifier.ok?(findings) do
      Mix.raise("receipt verification failed")
    end

    :ok
  end

  defp default_files(root) do
    Path.wildcard(Path.join(root, "receipts/**/*.md")) ++
      Path.wildcard(Path.join(root, "docs/archive/jira-releases/*/RECEIPT.md"))
  end

  defp commit_exists?(sha, root) do
    case System.cmd("git", ["cat-file", "-e", sha <> "^{commit}"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
