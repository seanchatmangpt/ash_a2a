# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SA2A.Conformance.Checks.C0 do
  @moduledoc """
  C0 checks (RFC-006 C0 profile): subject identity, refusal totality in both
  directions, standing derived from evidence, canonical digest determinism.
  Every probe calls the real code.
  """

  alias AshA2A.SA2A.Conformance.{Check, Context}
  alias AshA2A.ConsequenceKernel.{Refusal, RefusalCodes, Standing}

  @spec checks(map()) :: [Check.t()]
  def checks(ctx) do
    ctx = Context.build(ctx)

    [
      Check.run("c0.subject_identity", :c0, "subject SHA names a clean tree", fn ->
        subject_identity(ctx)
      end),
      Check.run("c0.refusal_totality", :c0, "refusal totality both ways", &refusal_totality/0),
      Check.run(
        "c0.standing_derived",
        :c0,
        "standing is derived, never literal",
        &standing_derived/0
      ),
      Check.run("c0.canonical_digest", :c0, "canonical digest deterministic", &canonical_digest/0)
    ]
  end

  @doc "Subject SHA of `ctx.root` via git; nil when not a checkout."
  @spec subject_sha(map()) :: String.t() | nil
  def subject_sha(ctx) do
    case git(ctx.root, ["rev-parse", "HEAD"]) do
      {:ok, sha} -> if sha =~ ~r/\A[0-9a-f]{40}\z/, do: sha
      _ -> nil
    end
  end

  def subject_identity(ctx) do
    ctx = Context.build(ctx)

    with {:ok, sha} <- git(ctx.root, ["rev-parse", "HEAD"]),
         {:ok, porcelain} <- git(ctx.root, ["status", "--porcelain"]) do
      if porcelain == "" do
        {:pass, "HEAD #{sha}; `git status --porcelain` empty (tree equals the named commit)"}
      else
        n = porcelain |> String.split("\n", trim: true) |> length()

        {:fail,
         "dirty tree: #{n} uncommitted path(s); SHA #{sha} does not describe the tree under test"}
      end
    else
      _ -> {:unverified, "#{ctx.root} is not a git checkout; no subject SHA can be named"}
    end
  end

  def refusal_totality do
    known_bad =
      for code <- RefusalCodes.codes(),
          not match?({:error, %{code: ^code, class: _}}, Refusal.new(code)),
          do: code

    unknown = [:__conformance_probe_unknown_code__, "not-an-atom", nil]

    unknown_bad =
      for code <- unknown,
          not match?(
            {:error, %{code: :unknown_refusal_code, class: :blocked_unknown}},
            Refusal.new(code)
          ),
          do: code

    cond do
      known_bad != [] ->
        {:fail, "registered codes that do not refuse as themselves: #{inspect(known_bad)}"}

      unknown_bad != [] ->
        {:fail, "unknown codes not refused as unknown_refusal_code: #{inspect(unknown_bad)}"}

      true ->
        {:pass,
         "#{length(RefusalCodes.codes())} registered codes each refuse as themselves; " <>
           "#{length(unknown)} unknown inputs refuse as unknown_refusal_code/blocked_unknown"}
    end
  end

  def standing_derived do
    cases = [
      {%{outcome: :observed, receipt_verified?: true}, {:ok, :evidenced}},
      {%{outcome: :observed, receipt_verified?: false}, {:error, :standing_evidence_missing}},
      {%{outcome: :unknown}, {:error, :standing_unknown_outcome}},
      {%{standing: :evidenced}, {:error, :standing_evidence_missing}},
      {%{}, {:error, :standing_evidence_missing}}
    ]

    bad = for {input, want} <- cases, Standing.derive(input) != want, do: {input, want}

    if bad == [],
      do:
        {:pass,
         "#{length(cases)} cases: evidence derives standing; unknown outcome, unverified receipt and a literal standing all refuse"},
      else: {:fail, "standing derivation disagrees with oracle: #{inspect(bad)}"}
  end

  def canonical_digest do
    a = %{"b" => 1, "a" => [1, 2, %{"y" => "z", "x" => true}]}
    b = %{"a" => [1, 2, %{"x" => true, "y" => "z"}], "b" => 1}
    c = %{"a" => [1, 2, %{"x" => true, "y" => "z"}], "b" => 2}

    with {:ok, da} <- AshA2A.Identity.Canonical.digest(a),
         {:ok, db} <- AshA2A.Identity.Canonical.digest(b),
         {:ok, dc} <- AshA2A.Identity.Canonical.digest(c) do
      cond do
        da != db ->
          {:fail, "key order changes the digest"}

        da == dc ->
          {:fail, "a differing value does not change the digest"}

        true ->
          {:pass, "Identity.Canonical.digest is key-order invariant and value sensitive (#{da})"}
      end
    else
      other ->
        {:fail, "Identity.Canonical.digest refused a plain map: #{inspect(other, limit: 5)}"}
    end
  end

  @doc false
  def git(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
