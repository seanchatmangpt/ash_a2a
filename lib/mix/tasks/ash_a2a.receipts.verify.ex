defmodule Mix.Tasks.AshA2a.Receipts.Verify do
  @shortdoc "Verify receipt hashes, cited tests, standing and run-log consistency"

  @moduledoc """
  Verifies Markdown receipts with `AshA2A.Receipts.Verifier`. Read-only.

  ## Usage

      mix ash_a2a.receipts.verify
      mix ash_a2a.receipts.verify receipts/lanes/t11-pplan-census.md --root .

  With no paths it checks `receipts/**/*.md` and
  `docs/archive/jira-releases/*/RECEIPT.md`.

  ## Options

    * `--root` -- directory cited paths resolve against (default: cwd)
    * `--legacy` -- legacy allowlist JSON (default: `receipts/legacy-receipts.json`
      under the root, if present)
    * `--git` -- also check `Commit:` lines with `git cat-file -e`

  Receipts listed in the legacy allowlist with a matching sha256 are reported
  as `warning legacy_exempt` with their reason; a changed receipt is checked
  normally.

  Exits non-zero (via `Mix.raise/1`) when any finding has error severity.
  """

  use Mix.Task

  alias AshA2A.Receipts.Verifier

  @impl true
  def run(args) do
    {opts, paths} =
      OptionParser.parse!(args, strict: [root: :string, git: :boolean, legacy: :string])

    root = Path.expand(opts[:root] || File.cwd!())

    legacy_path = Path.expand(opts[:legacy] || "receipts/legacy-receipts.json", root)

    vopts =
      [root: root, legacy: Verifier.load_legacy(legacy_path)] ++
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
