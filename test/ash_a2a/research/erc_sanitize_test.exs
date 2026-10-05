# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Research.ERCSanitizeTest do
  @moduledoc "CWE-22 court: traversal ids never write outside the receipt dir. DB-free."
  use ExUnit.Case, async: true

  alias AshA2A.Research.ERC

  defp attrs(id),
    do: %{id: id, claim: "c", falsifier: "f", state: :observed, evidence: %{"n" => 1}}

  defp tree(dir), do: dir |> Path.join("**/*") |> Path.wildcard(match_dot: true) |> Enum.sort()

  @tag :tmp_dir
  test "traversal and separator ids are refused; nothing escapes the dir", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "erc")
    before = tree(tmp)

    for bad <- [
          "../evil",
          "../../evil",
          "a/b",
          "a\\b",
          "..",
          "x/../../y",
          "/abs",
          "",
          ".hidden",
          "a\0b",
          String.duplicate("a", 200)
        ] do
      assert_raise ArgumentError, ~r/refused_erc_id/, fn -> ERC.emit!(attrs(bad), dir: dir) end
    end

    assert tree(tmp) == before
    refute File.exists?(Path.join(tmp, "evil-1.json"))
  end

  @tag :tmp_dir
  test "a normal id writes exactly one file inside dir", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "erc")
    assert {:ok, path} = ERC.emit!(attrs("ERC-001"), dir: dir)
    assert Path.dirname(path) == dir
    assert File.exists?(path)
    assert [_] = File.ls!(dir)
  end
end
