defmodule AshA2A.CommandFingerprintDeterminismTest do
  @moduledoc """
  Regression coverage for `AshA2A.Command.fingerprint/1`'s cross-node/replay
  stability (RFC-SA2A-002 §41, CHI-REPLAY-001).

  `Command.fingerprint/1` hashes via
  `:erlang.term_to_binary(term, [:deterministic])`. Per the Erlang/OTP
  `:erlang.term_to_binary/2` documentation, the plain (no-option) encoding
  gives *no* guarantee that the same term encodes to the same bytes across
  separate runtime-system instances -- only `[:deterministic]` gives that
  guarantee (within one OTP major release). `ReceiptStore.claim/2` keys its
  replay/conflict decision on `Command.fingerprint/1`, so a caller that
  reconstructs the identical semantic command with its atom-keyed `input`
  map built via a different code path -- a different node in a multi-node
  deployment, a different decode path, a fresh replay process -- must still
  fingerprint identically, or a legitimate retry could be spuriously refused
  as a `:command_conflict`, or a real conflict could be masked.

  This mirrors the existing `AshA2A.Actuation.digest/1` doctest pattern
  (`lib/ash_a2a/actuation.ex:58-73`) and the fix already applied there,
  at `AshA2A.Authority`'s and `AshA2A.Receipt.Binding`'s digests, and at
  `AshA2A.Semantic.MetaAdmission`/`HookReactor.Hook`/`HookReactor.Intent` --
  applied here to `Command.fingerprint/1`, the single most load-bearing
  stable-command-identity hash in the system.

  Real collaborators throughout: real `AshA2A.Command` structs, real
  `Command.fingerprint/1` calls, state-based equality assertions on the
  real returned hash strings. No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Command

  @capability "AshA2A.Test.Fixture.CountingActuator.actuate"

  defp base_opts(input) do
    [
      command_id: "cmd-#{System.unique_integer([:positive])}",
      agent_id: "s41-agent",
      principal_id: "s41-principal",
      input: input,
      submitted_at: ~U[2026-01-01 00:00:00Z]
    ]
  end

  test "fingerprint is identical for atom-keyed input maps built in different key-insertion order" do
    forward =
      Map.new(a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7)

    reversed =
      Enum.reduce([{:g, 7}, {:f, 6}, {:e, 5}, {:d, 4}, {:c, 3}, {:b, 2}, {:a, 1}], %{}, fn {k, v},
                                                                                           acc ->
        Map.put(acc, k, v)
      end)

    assert forward == reversed

    command_forward = Command.new(@capability, base_opts(forward))
    command_reversed = Command.new(@capability, base_opts(reversed))

    assert Command.fingerprint(command_forward) == Command.fingerprint(command_reversed)
  end

  test "fingerprint is identical across a small-map/large-map representation boundary" do
    keys = for i <- 1..40, do: String.to_atom("k#{i}")
    pairs = Enum.map(keys, fn k -> {k, Atom.to_string(k)} end)

    # Built directly as a 40-entry map (large/HAMT-representation path).
    direct = Map.new(pairs)

    # Built by growing past the flatmap/HAMT threshold with an extra key,
    # then deleting it back down -- a value-equal map that may carry a
    # different internal representation depending on runtime/version.
    grown = pairs |> Kernel.++([{:k_extra, "extra"}]) |> Map.new() |> Map.delete(:k_extra)

    assert direct == grown

    command_direct = Command.new(@capability, base_opts(direct))
    command_grown = Command.new(@capability, base_opts(grown))

    assert Command.fingerprint(command_direct) == Command.fingerprint(command_grown)
  end

  test "fingerprint is a stable, reproducible lowercase-hex sha256 digest for the same command" do
    command = Command.new(@capability, base_opts(%{effect_key: "e-1"}))

    assert Command.fingerprint(command) == Command.fingerprint(command)
    assert String.length(Command.fingerprint(command)) == 64
    assert Command.fingerprint(command) =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "the implementation encodes with the :deterministic option, matching Command.fingerprint/1's own contract" do
    command = Command.new(@capability, base_opts(%{effect_key: "e-2"}))

    expected =
      {
        AshA2A.Identity.external(command.agent_id),
        AshA2A.Identity.external(command.principal_id),
        command.task_id && AshA2A.Identity.external(command.task_id),
        command.capability_id,
        command.input,
        nil,
        AshA2A.SemanticSubject.fingerprint_token(command.semantic_subject)
      }
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert Command.fingerprint(command) == expected
  end

  test "a different effect (different capability_id) is NOT deduplicated by the fingerprint" do
    command_a = Command.new(@capability, base_opts(%{effect_key: "e-3"}))

    command_b =
      Command.new("AshA2A.Test.Fixture.CountingActuator.other", base_opts(%{effect_key: "e-3"}))

    refute Command.fingerprint(command_a) == Command.fingerprint(command_b)
  end
end
