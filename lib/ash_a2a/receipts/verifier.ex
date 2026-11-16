defmodule AshA2A.Receipts.Verifier do
  @moduledoc """
  Checks a Markdown receipt against the files it cites.

  The core only reads files (through `:root`) and never writes. Each receipt
  is checked for:

    * `hash_mismatch` / `hash_file_missing` (error): a claim written as
      `` `path` sha256:<64 hex> `` must match the SHA-256 of the file at
      `path` under `:root`.
    * `commit_malformed` / `commit_unknown` (error): a `Commit: <hex>` line
      must be 7 to 40 hex characters and, when a `:commit_exists` function is
      given, must be accepted by it.
    * `test_missing` (error): a cited `` `test/.../*_test.exs` `` must exist.
    * `standing_missing` (warning): no `Standing:` line.
    * `verified_without_run_log` (error): a verified standing (ALIVE,
      VERIFIED, CONFORMANT, PASS) with no `Run log: <path>` naming an existing
      file.
    * `run_log_missing` (error): a `Run log:` path that does not exist.
    * `unverified_with_run_log` (warning): `UNVERIFIED` standing while a run
      log is attached; the standing is stale or the log is not evidence.
    * `conformant_on_unverified` (error): a table row that says CONFORMANT
      while the row itself, or a cited `.md` doc with a `Status:` or
      `Standing:` line, says UNVERIFIED.

  Findings are maps with `:severity`, `:code`, `:receipt` and `:detail`.
  """

  @verified ~w(ALIVE VERIFIED CONFORMANT PASS)
  @hash_re ~r/`([^`\s]+)`\s+sha256[:=]([0-9a-fA-F]{64})/
  @test_re ~r/`(test\/[^`\s]+_test\.exs)`/
  @doc_re ~r/`([^`\s]+\.md)`/

  @type finding :: %{
          severity: :error | :warning,
          code: atom(),
          receipt: String.t(),
          detail: String.t()
        }

  @doc """
  Verifies one receipt's text. `receipt` is its display name. Options:
  `:root` (base directory for cited paths, default `File.cwd!/0`) and
  `:commit_exists` (`(String.t() -> boolean())`).
  """
  @spec verify_text(String.t(), String.t(), keyword()) :: [finding()]
  def verify_text(text, receipt, opts \\ []) do
    root = Keyword.get_lazy(opts, :root, &File.cwd!/0)
    commit_exists = Keyword.get(opts, :commit_exists)
    lines = String.split(text, ~r/\R/)
    standing = standing(lines)
    run_logs = run_logs(lines)

    hash_findings(text, receipt, root) ++
      commit_findings(lines, receipt, commit_exists) ++
      test_findings(text, receipt, root) ++
      standing_findings(standing, run_logs, receipt, root) ++
      row_findings(lines, receipt, root)
  end

  @doc "Verifies a receipt file; an unreadable file is a single error finding."
  @spec verify_file(Path.t(), keyword()) :: [finding()]
  def verify_file(path, opts \\ []) do
    case File.read(path) do
      {:ok, text} ->
        verify_text(text, Path.basename(path), opts)

      {:error, reason} ->
        [finding(:error, :receipt_unreadable, path, inspect(reason))]
    end
  end

  @doc "Returns true when no finding has `:error` severity."
  @spec ok?([finding()]) :: boolean()
  def ok?(findings), do: not Enum.any?(findings, &(&1.severity == :error))

  defp finding(severity, code, receipt, detail),
    do: %{severity: severity, code: code, receipt: receipt, detail: detail}

  defp standing(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/^\s*\**Standing\**:\s*\**\s*([A-Za-z_]+)/, line) do
        [_, word] -> String.upcase(word)
        _ -> nil
      end
    end)
  end

  defp run_logs(lines) do
    for line <- lines,
        [_, path] <- [Regex.run(~r/^\s*[-*]?\s*\**Run log\**:\s*`?([^`\s]+)`?/i, line)],
        do: path
  end

  defp hash_findings(text, receipt, root) do
    for [_, path, hex] <- Regex.scan(@hash_re, text) do
      full = Path.expand(path, root)

      case File.read(full) do
        {:ok, bin} ->
          actual = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

          if actual == String.downcase(hex) do
            nil
          else
            finding(:error, :hash_mismatch, receipt, "#{path}: claimed #{hex}, actual #{actual}")
          end

        {:error, _} ->
          finding(:error, :hash_file_missing, receipt, "#{path}: cannot read hashed file")
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp commit_findings(lines, receipt, commit_exists) do
    lines
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*[-*]?\s*\**Commit\**:\s*`?([^`\s]+)`?/i, line) do
        [_, sha] ->
          cond do
            not Regex.match?(~r/\A[0-9a-fA-F]{7,40}\z/, sha) ->
              [finding(:error, :commit_malformed, receipt, "#{sha} is not 7-40 hex characters")]

            is_function(commit_exists, 1) and not commit_exists.(sha) ->
              [finding(:error, :commit_unknown, receipt, "#{sha} not found in the repository")]

            true ->
              []
          end

        _ ->
          []
      end
    end)
  end

  defp test_findings(text, receipt, root) do
    @test_re
    |> Regex.scan(text)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
    |> Enum.reject(&File.regular?(Path.expand(&1, root)))
    |> Enum.map(&finding(:error, :test_missing, receipt, "#{&1} does not exist"))
  end

  defp standing_findings(standing, run_logs, receipt, root) do
    present = Enum.filter(run_logs, &File.regular?(Path.expand(&1, root)))

    missing_logs =
      for path <- run_logs,
          path not in present,
          do: finding(:error, :run_log_missing, receipt, "#{path} does not exist")

    claim =
      cond do
        is_nil(standing) ->
          [finding(:warning, :standing_missing, receipt, "no Standing: line")]

        standing in @verified and present == [] ->
          [
            finding(
              :error,
              :verified_without_run_log,
              receipt,
              "standing #{standing} claimed without an attached run log"
            )
          ]

        standing == "UNVERIFIED" and present != [] ->
          [
            finding(
              :warning,
              :unverified_with_run_log,
              receipt,
              "standing UNVERIFIED but run log #{hd(present)} is attached"
            )
          ]

        true ->
          []
      end

    missing_logs ++ claim
  end

  defp row_findings(lines, receipt, root) do
    lines
    |> Enum.filter(&(String.starts_with?(String.trim(&1), "|") and &1 =~ ~r/CONFORMANT/i))
    |> Enum.reject(&(&1 =~ ~r/NON[-_ ]?CONFORMANT/i))
    |> Enum.flat_map(fn row ->
      cells =
        row |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

      cond do
        Enum.any?(cells, &(&1 =~ ~r/\bUNVERIFIED\b/)) ->
          [conformant_finding(receipt, row, "the same row says UNVERIFIED")]

        doc = Enum.find(doc_paths(row), &doc_unverified?(&1, root)) ->
          [conformant_finding(receipt, row, "doc #{doc} status is UNVERIFIED")]

        true ->
          []
      end
    end)
  end

  defp conformant_finding(receipt, row, why),
    do:
      finding(
        :error,
        :conformant_on_unverified,
        receipt,
        "row claims CONFORMANT but #{why}: #{String.slice(String.trim(row), 0, 120)}"
      )

  defp doc_paths(row), do: for([_, p] <- Regex.scan(@doc_re, row), do: p)

  defp doc_unverified?(path, root) do
    case File.read(Path.expand(path, root)) do
      {:ok, text} ->
        Regex.match?(~r/^\s*\**(Status|Standing)\**:\s*\**\s*UNVERIFIED\b/mi, text)

      _ ->
        false
    end
  end
end
