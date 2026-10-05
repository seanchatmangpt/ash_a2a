# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MockDisciplineTest do
  @moduledoc """
  The fleet mock-discipline grep, run for real over this tree (ERRC Cr4,
  lane P1-A2).

  The fleet gate regex is:

      (use|import) +(Mox|Mimic|Patch)\b|(Mox|Mimic|Patch)\.|:meck\.|mockall|MagicMock

  run with `grep -rnE --include=*.ex --include=*.exs` over `lib/` and `test/`
  (`_build/`, `deps/`, `priv/` are not under those roots, so they are excluded
  structurally). The naive reading -- "exit 1 = clean" -- is false on this
  tree by design: the repo's own zero-mock detection court quotes banned
  tokens verbatim (the ggen precedent: well-formed test files are hits
  against themselves).

  ## Audit (main @ d58f99f) -- every raw hit is a prose position

  | file | lines | position |
  |---|---|---|
  | `lib/ash_a2a/chicago/court.ex` | 43 | moduledoc bullet naming :meck/Mox |
  | `lib/ash_a2a/chicago/collaborators/mock_scan.ex` | 13, 14, 15, 111, 121, 130 | docstrings/comments of the AST scanner itself |
  | `lib/ash_a2a/chicago/courts/real_collaborators.ex` | 46-68, 83-96, 277 | `~S` sigil fixture sources + falsifier prose |
  | `test/ash_a2a/chicago/real_collaborators_test.exs` | 190-193, 207-210, 220, 223-224 | heredoc fixture sources the court's tests scan |

  None is a code position: `AshA2A.Chicago.Collaborators.MockScan` parses the
  same files with `Code.string_to_quoted/2` and flags only real calls,
  directives, captures and apply-shapes into Mox/Hammox/Mock/Mimic/Patch/
  :meck -- comments, docstrings, strings, sigils and atoms are not calls. So
  the fleet regex is evaluated at **code positions** through that AST law,
  and the raw grep is kept as a drift tripwire.

  ## The gate (three assertions, each fails closed)

    1. the fleet regex has teeth: run against a real temp file containing
       `use Mox`, grep must match (exit 0) -- a regex that silently stopped
       matching must fail this test, not the next incident;
    2. the AST scan over `lib/` + `test/` is `:clean` with files scanned > 0
       -- zero code-position violations, unparseable source fails closed;
    3. every raw grep hit lives in the allowlist of disclosure files above
       (keyed by file, not line -- prose shifts, disclosure files do not).
       A banned token quoted in any NEW file turns this red and forces a
       reviewed allowlist extension.

  Red/green proof (session P1-A2): a scratch `use Mox` file under `test/`
  turns assertions 2 and 3 red; deleting it restores green. The scratch file
  is removed; nothing in the tree keeps it.
  """

  use ExUnit.Case, async: true

  @regex ~S[(use|import) +(Mox|Mimic|Patch)\b|(Mox|Mimic|Patch)\.|:meck\.|mockall|MagicMock]

  # Files whose docstrings/comments/sigil fixtures quote banned tokens.
  # Keyed by path (relative to repo root), not line: prose shifts, the
  # disclosure files do not. Extending this list is a reviewed admission.
  @disclosure_files [
    "lib/ash_a2a/chicago/court.ex",
    "lib/ash_a2a/chicago/collaborators/mock_scan.ex",
    "lib/ash_a2a/chicago/courts/real_collaborators.ex",
    "test/ash_a2a/chicago/real_collaborators_test.exs",
    # This file's own moduledoc quotes the banned tokens to document them.
    "test/ash_a2a_mock_discipline_test.exs"
  ]

  test "fleet mock-discipline gate: AST-clean tree, regex with teeth, prose hits allowlisted" do
    # 1. The regex has teeth -- real grep against a real violating file.
    #    (The only double in this suite: the violation itself cannot exist
    #    in the tree, so its stand-in lives in the OS temp dir and dies with
    #    the test process. A real file, real grep, state-based assertion.)
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "ash_a2a-mock-teeth-#{System.unique_integer([:positive])}.exs")
    File.write!(path, "defmodule T do\n  use Mox\nend\n")

    teeth =
      System.cmd("grep", ["-rnE", @regex, path], stderr_to_stdout: true)

    File.rm(path)

    assert {_, exit_teeth} = teeth
    assert exit_teeth == 0, "fleet regex failed to match a real `use Mox` (exit #{exit_teeth})"

    # 2. Code positions: the repo's own AST law over lib/ + test/.
    scan =
      AshA2A.Chicago.Collaborators.MockScan.scan(root: File.cwd!(), dirs: ["lib", "test"])

    assert scan.files > 0, "AST scan saw no files -- gate vacuous"
    assert scan.violations == [], inspect(scan.violations, pretty: true)
    assert scan.unparseable == [], inspect(scan.unparseable, pretty: true)
    assert scan.outcome == :clean

    # 3. Raw fleet grep over the tree: every hit must be a disclosure-file
    #    prose hit, never a new file.
    {out, exit_grep} =
      System.cmd("grep", ["-rnE", @regex, "--include=*.ex", "--include=*.exs", "lib", "test"],
        stderr_to_stdout: true
      )

    assert exit_grep in [0, 1], "grep errored (exit #{exit_grep}): #{out}"

    hits =
      out
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 3) do
          [file, lineno, _text] -> {file, String.to_integer(lineno)}
          _ -> raise("unparseable grep line: #{inspect(line)}")
        end
      end)

    offending =
      hits
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @disclosure_files))

    assert offending == [],
           "banned tokens outside the disclosure allowlist: #{inspect(offending)}" <>
             "\nraw hits:\n#{out}"
  end

end
