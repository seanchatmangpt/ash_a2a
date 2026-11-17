# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TestSupport.RootGuard do
  @moduledoc """
  Skip guard for tests whose property genuinely needs POSIX permission bits.

  The superuser ignores `chmod`, so a test that makes a directory unreadable or
  unwritable with `File.chmod!/2` cannot observe the failure when the suite runs
  as uid 0 (a container, for example). Prefer rebuilding the setup so it does not
  depend on permissions (make the path a regular file, a dangling symlink, or a
  child of a non-directory). Only when the property truly is a permission
  failure, tag the test:

      @tag skip: AshA2A.TestSupport.RootGuard.skip_reason()

  `skip_reason/0` is `false` for a non-root user (the test runs, as on CI) and an
  explicit message as root, so the skip is visible in the ExUnit summary.
  """

  @doc "True when the current OS user is uid 0."
  @spec root?() :: boolean()
  def root?, do: uid() == 0

  @doc "`false` for a non-root user, otherwise a skip message naming the reason."
  @spec skip_reason() :: false | String.t()
  def skip_reason do
    if root?(),
      do: "requires POSIX permission enforcement; running as root (uid 0) ignores chmod",
      else: false
  end

  defp uid do
    case :os.cmd(~c"id -u") |> List.to_string() |> String.trim() |> Integer.parse() do
      {n, ""} -> n
      _ -> -1
    end
  end
end
