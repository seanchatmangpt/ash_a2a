defmodule AshA2A.NoPersonalNamesTest do
  @moduledoc """
  Repo-hygiene guard: personal first names of individuals must not appear in
  any tracked file. Roles (CEO, COO) are used instead. The forbidden names are
  assembled from fragments so this file does not itself contain them.
  """

  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @forbidden [~w(Vi nce), ~w(To ny)] |> Enum.map(&Enum.join/1)

  test "no tracked file contains a forbidden personal name" do
    {files, 0} = System.cmd("git", ["ls-files", "-z"], cd: @root)

    offenders =
      for path <- String.split(files, <<0>>, trim: true),
          full = Path.join(@root, path),
          File.regular?(full),
          content = File.read!(full),
          String.valid?(content),
          name <- @forbidden,
          Regex.match?(~r/(?<![a-z])#{name}(?![a-z])/i, content) or
            (Regex.match?(~r/#{name}/, content) and
               not Regex.match?(~r/(province|antony|stony)/i, content)),
          do: {path, name}

    assert offenders == [], "personal names found: #{inspect(Enum.uniq(offenders))}"
  end
end
