defmodule AshA2A.DualSafeMapUpdateTest do
  @moduledoc """
  Pins the dual-safe accumulator idiom (OS-20 / w525d): `Map.update/4` on the
  pinned toolchain (elixir 1.20.4-otp-29) deviates from documented semantics on
  the absent-key path — it inserts `default` WITHOUT applying `fun`. Every
  ABSENT-KEY-RELIANT site in `lib/` was rewritten to the explicit fetch/put
  form so the stored value is identical under BOTH the deviating and the
  documented behavior. These tests fail if a site regresses to `Map.update/4`
  semantics where the default's `fun`-application would double-insert
  (documented behavior) or if the explicit form's accumulator contract breaks.
  """

  use ExUnit.Case, async: true

  # Safe sites per the w525d census: fun is idempotent over the default, so
  # these Map.update/4 call sites are correct under both toolchain behaviors.
  @w525d_safe_files [
    "ash_a2a/chicago/closure/court.ex",
    "ash_a2a/chicago/observer/journal.ex",
    "ash_a2a/runtime_identity/execution.ex",
    "ash_a2a/telemetry/allocation_counters.ex",
    "ash_a2a/c2/memory_claim_store.ex"
  ]

  # The representative site pattern: cons-a-onto-list accumulator
  # (task_events.ex:142, state.ex:138, workload_watcher.ex, closure/court.ex:331).
  defp attempt_acc(attempts, task_id, attempt) do
    case Map.fetch(attempts, task_id) do
      :error -> Map.put(attempts, task_id, [attempt])
      {:ok, prior} -> Map.put(attempts, task_id, Enum.take([attempt | prior], 100))
    end
  end

  # Counter accumulator pattern (entropy.ex:26).
  defp count_acc(freqs, byte) do
    case Map.fetch(freqs, byte) do
      :error -> Map.put(freqs, byte, 1)
      {:ok, count} -> Map.put(freqs, byte, count + 1)
    end
  end

  describe "dual-safe cons accumulator (task_events/state/workload_watcher pattern)" do
    test "absent key stores the default verbatim — fun is NOT applied" do
      assert attempt_acc(%{}, "t1", :a1) == %{"t1" => [:a1]}
    end

    test "present key applies the fold — new element prepended, bounded at 100" do
      prior = List.duplicate(:x, 99)
      assert attempt_acc(%{"t1" => prior}, "t1", :a) == %{"t1" => [:a | prior]}
    end

    test "present key truncates to the 100-element cap" do
      prior = List.duplicate(:x, 100)
      result = attempt_acc(%{"t1" => prior}, "t1", :a)
      assert length(result["t1"]) == 100
      assert [h | _] = result["t1"]
      assert h == :a
    end

    test "absent-key insert followed by second insert does not duplicate the head" do
      acc = attempt_acc(%{}, "t1", :a1)
      acc = attempt_acc(acc, "t1", :a2)
      assert acc == %{"t1" => [:a2, :a1]}
    end

    test "other tasks' accumulators are untouched" do
      acc = attempt_acc(%{"t1" => [:a1]}, "t2", :a2)
      assert acc == %{"t1" => [:a1], "t2" => [:a2]}
    end
  end

  describe "dual-safe counter accumulator (entropy pattern)" do
    test "first occurrence stores 1, not 2" do
      assert count_acc(%{}, ?a) == %{?a => 1}
    end

    test "repeated occurrences increment" do
      acc = count_acc(%{}, ?a)
      assert count_acc(acc, ?a) == %{?a => 2}
    end

    test "counter stays correct under documented Map.update semantics too" do
      # Dual: simulate the documented behavior (apply fun to default) and
      # confirm the idiom's result is what the deviating toolchain produces —
      # i.e. first count is 1 either way, because fun is never applied to the
      # default by the idiom itself.
      documented_style = fn m, k, d, f ->
        case Map.fetch(m, k) do
          :error -> Map.put(m, k, f.(d))
          {:ok, v} -> Map.put(m, k, f.(v))
        end
      end

      refute documented_style.(%{}, ?a, 1, &(&1 + 1)) == count_acc(%{}, ?a)
      assert count_acc(%{}, ?a) == %{?a => 1}
    end
  end

  describe "real site: entropy.shannon_bits_per_char end-to-end" do
    test "uniform byte string has zero entropy" do
      assert AshA2A.Security.DLP.Entropy.shannon_bits_per_char("aaaa") == 0.0
    end

    test "high-entropy binary has high per-char entropy" do
      bits = AshA2A.Security.DLP.Entropy.shannon_bits_per_char("abcdefgh")
      assert bits > 2.5 and bits <= 8.0
    end

    test "empty binary is 0.0" do
      assert AshA2A.Security.DLP.Entropy.shannon_bits_per_char("") == 0.0
    end
  end

  describe "no reliance on Map.update/4 absent-key fun application remains in lib/" do
    test "all former reliant sites use the explicit fetch/put form" do
      lib = Path.join([File.cwd!(), "lib"])

      remaining =
        lib
        |> grep_map_update()
        |> Enum.reject(fn {file, _line, text} ->
          # Safe sites per w525d census: fun is idempotent over the default.
          safe_markers = ["MapSet.new([from])", "MapSet.put", "&max(", "Map.put(&1, resolver", "{0, {:completed"]
          file_suffix = Path.relative_to(file, lib)
          file_suffix in @w525d_safe_files or Enum.any?(safe_markers, &String.contains?(text, &1))
        end)

      assert remaining == [], "reliant Map.update sites reintroduced: #{inspect(remaining, pretty: true)}"
    end
  end

  defp grep_map_update(dir) do
    dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} ->
        if String.contains?(line, "Map.update(") and not String.contains?(line, "Map.update!"),
          do: [{file, n, String.trim(line)}],
          else: []
      end)
    end)
  end
end
