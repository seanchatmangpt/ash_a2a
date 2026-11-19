# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PackReplayCourtTest do
  @moduledoc """
  Byte-identical replay court for the self-hosted marketplace projection (`ggen.toml`).

  Copies the consumer inputs (`ggen.toml`, `priv/sa2a/AllSA2A.ttl`, empty `templates/`) into two
  fresh temp dirs, runs `ggen sync run` in each, and asserts:

    1. REPLAY: both runs produce byte-identical `generated/` trees.
    2. COMMITTED: that tree is byte-identical to the repo's committed `generated/`.

  Skips loudly (compile-time stderr line plus an ExUnit skip reason) when `ggen` is not on PATH,
  or when the pack path pinned in `ggen.toml` is absent on this machine.

  ## Mutation note (what flips it)

    * Insert a nondeterministic value (timestamp, random id, map-order dependent output) into a
      `canonical-ash-projection-generator` template: REPLAY flips red.
    * Edit `priv/sa2a/AllSA2A.ttl` (or a pack template) without re-running `ggen sync run` and
      committing `generated/`: COMMITTED flips red.
    * Hand-edit any file under `generated/`: COMMITTED flips red.
  """
  use ExUnit.Case, async: false

  @root Path.expand("..", __DIR__)

  @skip_reason (cond do
                  is_nil(System.find_executable("ggen")) ->
                    "ggen not found on PATH"

                  true ->
                    case File.read(Path.join(Path.expand("..", __DIR__), "ggen.toml")) do
                      {:ok, toml} ->
                        case Regex.run(~r/path\s*=\s*"([^"]+)"/, toml) do
                          [_, pack] ->
                            if File.dir?(pack), do: nil, else: "pack path absent: #{pack}"

                          _ ->
                            "no pack path in ggen.toml"
                        end

                      _ ->
                        "ggen.toml unreadable"
                    end
                end)

  if @skip_reason do
    IO.puts(:stderr, "[SKIP] pack replay court: #{@skip_reason}")
    @moduletag skip: @skip_reason
  end

  @moduletag :pack_replay

  defp project!(label) do
    dir =
      Path.join(System.tmp_dir!(), "pack_replay_#{label}_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(Path.join(dir, "templates"))
    File.mkdir_p!(Path.join(dir, "priv/sa2a"))
    File.cp!(Path.join(@root, "ggen.toml"), Path.join(dir, "ggen.toml"))
    File.cp!(Path.join(@root, "priv/sa2a/AllSA2A.ttl"), Path.join(dir, "priv/sa2a/AllSA2A.ttl"))

    {out, status} =
      System.cmd("ggen", ["sync", "run", "--skip-ea-admission"],
        cd: dir,
        stderr_to_stdout: true
      )

    assert status == 0, "ggen sync run failed (#{status}):\n#{out}"
    dir
  end

  defp tree(dir) do
    base = Path.join(dir, "generated")

    base
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Map.new(fn f -> {Path.relative_to(f, base), File.read!(f)} end)
  end

  test "two fresh ggen sync runs produce byte-identical generated/ trees" do
    a = tree(project!("a"))
    b = tree(project!("b"))
    assert map_size(a) > 0, "ggen produced no generated/ files"
    assert a == b
  end

  test "replayed generated/ is byte-identical to the committed generated/" do
    replay = tree(project!("c"))
    committed = tree(@root)
    assert committed != %{}, "no committed generated/ tree"
    assert Map.keys(replay) == Map.keys(committed)

    for {rel, bytes} <- replay do
      assert bytes == Map.fetch!(committed, rel), "generated/#{rel} drifted from committed bytes"
    end
  end
end
