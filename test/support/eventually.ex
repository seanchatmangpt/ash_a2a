# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TestSupport.Eventually do
  @moduledoc """
  The single audited bounded poll for tests (no-sleep doctrine).

  `eventually/2` re-evaluates a fun until it returns a truthy value or a
  monotonic deadline passes. `pause/1` blocks on a `receive ... after` timer
  and is the only wait primitive in the test tree that models a REAL interval
  (a lease/TTL/window that must genuinely lapse on the wall clock); it is not
  an outcome wait.

  Options for `eventually/2`: `:timeout` (ms, default 5_000), `:interval`
  (ms between attempts, default 5), `:message` (failure text).
  """

  # SLEEP-CLASS: POLL-STEP (the one audited timer for the poll loop)
  @doc "Waits `ms` on a selective receive timer (real-interval modelling only)."
  def pause(ms) when is_integer(ms) and ms >= 0 do
    receive do
      {:__ash_a2a_never_sent__, _} -> :ok
    after
      ms -> :ok
    end
  end

  @doc "Polls `fun` until truthy; returns its value or raises ExUnit-style on deadline."
  def eventually(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :interval, 5)
    message = Keyword.get(opts, :message, "condition not met")
    deadline = System.monotonic_time(:millisecond) + timeout
    loop(fun, interval, deadline, message, timeout)
  end

  defp loop(fun, interval, deadline, message, timeout) do
    case fun.() do
      v when v in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise ExUnit.AssertionError, message: "#{message} (not met within #{timeout}ms)"
        else
          pause(interval)
          loop(fun, interval, deadline, message, timeout)
        end

      v ->
        v
    end
  end
end
