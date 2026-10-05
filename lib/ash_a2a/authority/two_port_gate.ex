# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.TwoPortGate do
  @moduledoc """
  The algebraic two-port gate (loops-of-loops spec §1 Loop 1):

      Gate(Command, Lease, S_t) =
        Admitted  if H(Scope_Lease) == H(Scope_Cmd)
                  and Root_Lease == H(RDFC10(S_t))
                  and Clock_mono ∈ [T_start, T_exp]
                  and Verify_Ed25519(sigma_Lease, PK_Auth) = 1
        Refused   otherwise

  ## Branchless evaluation

  `evaluate/3` evaluates ALL FOUR conjuncts unconditionally into a boolean
  each, folds them into a 4-bit mask, and only then selects between
  `:admitted` and the refusal. There is no early exit. Two documented
  reasons:

    1. **Constant-time discipline** (spec §1: "Refusals produce a branchless
       null-mask to ensure constant-time evaluation"): the refused path does
       not reveal, through timing, which conjunct failed — every evaluation
       performs the same work regardless of the outcome. (Honest boundary:
       Elixir's `if` is not a cryptographic constant-time primitive; this is
       constant-work discipline — the same conjuncts always run — not a
       timing-attack-hardened implementation.)
    2. **Complete evidence**: the refusal mask tells the caller exactly which
       conjuncts failed, in one observation.

  ## Mask semantics (the null-mask law)

    * `0x0` — admitted (the spec's null-mask)
    * `0x1` — scope conjunct failed (`:lease_scope_mismatch`)
    * `0x2` — root conjunct failed (`:lease_root_mismatch`)
    * `0x4` — clock conjunct failed (`:lease_expired`)
    * `0x8` — signature conjunct failed (`:lease_signature_invalid`)

  `decode/1` bit-decodes a mask into
  `[%{bit:, name:, code:, detail:}]`. The refusal the gate returns is
  `{:error, {:refused_lease, mask, %{codes: [...]}}}`.

  ## Conjunct (a) — scope

  `Lease.scope_digest == Actuation.digest(scope_of(command))`:
  `AshA2A.Actuation.digest/1` (deterministic term SHA-256, prefixed
  `sha256:`) over the command's target scope map. `Actuation.digest/1` is
  the right digest here, not `AshA2A.Semantic.CanonicalGraph`: the scope map
  is a plain term, not RDF.

  ## Conjunct (b) — root

  When `opts[:rdf_state]` carries RDF state (Turtle binary), the gate
  recomputes the root via `AshA2A.Semantic.CanonicalGraph.canonical_digest/1`
  (RDFC-1.0/SHA-256, the S12 identity machinery — previously unused at an
  admission boundary) and compares against `lease.root_digest`. When absent,
  the existing opaque-string law applies: the carried
  `semantic_subject.graph_digest` is compared as an opaque string. Fail
  closed: an RDF state that fails canonicalization refuses. Digest FORMS are
  compared like-for-like — an RDFC bare-hex digest never equals a
  `sha256:`-prefixed one — so a lease must pin the root in the form of the
  source it was issued from.

  ## Conjunct (c) — clock (the hybrid law)

  Same-VM lease (`issued_monotonic_ms != nil`): the window is
  `Clock_mono ∈ [T_start, T_exp]` with `T_start = issued_monotonic_ms`,
  `T_exp = T_start + (expires_at - not_before)`, `Clock_mono` captured at
  gate entry. Cross-VM lease (`issued_monotonic_ms == nil`): the persisted
  wall-clock window `[not_before, expires_at]`. Full law on
  `AshA2A.Authority.Lease`.

  ## Conjunct (d) — signature

  `AshA2A.Authority.Lease.verify/3` over the lease with
  `opts[:lease_public_key]`. Missing signature or missing key refuses (fail
  closed).

  ## Opt-in at the CommandBus

  `AshA2A.CommandBus.run/4` applies this gate ONLY when `opts[:lease]` is
  present (mirroring the HILT work-order law: absence = skip, byte-identical
  path for every existing caller). Default-on is a separate flip with its
  own witness.

  Measured budget (test/ash_a2a_two_port_gate_test.exs "budget" test,
  admission path, real signed lease, real Ed25519 verify, 25 samples,
  `MIX_BUILD_ROOT=_build-l1`): median 105µs (0.105ms), max 123µs — two-plus
  orders of magnitude inside the ≤10ms budget. The test asserts a generous
  50ms CI bound and prints the measured numbers; the ≤10ms spec budget is
  met with ~100x headroom.
  """

  alias AshA2A.Authority.Lease
  alias AshA2A.Command

  @type mask :: 0x0..0xF
  @type refusal :: {:refused_lease, mask(), %{codes: [atom()]}}

  @conjuncts [
    {:scope, 0x1, :lease_scope_mismatch},
    {:root, 0x2, :lease_root_mismatch},
    {:clock, 0x4, :lease_expired},
    {:signature, 0x8, :lease_signature_invalid}
  ]

  @doc false
  def __sa2a_refusal_codes__ do
    Map.new(@conjuncts, fn {_name, _bit, code} -> {code, :refused_authority} end)
  end

  @doc "The conjunct table: `[{name, mask_bit, refusal_code}]`."
  @spec conjuncts() :: [{atom(), mask(), atom()}]
  def conjuncts, do: @conjuncts

  @doc """
  Bit-decodes a refusal mask into
  `[%{bit:, name:, code:, detail:}]`, highest-relevance first (scope, root,
  clock, signature). The null-mask decodes to `[]`.
  """
  @spec decode(mask()) :: [%{bit: pos_integer(), name: atom(), code: atom(), detail: String.t()}]
  def decode(0), do: []

  def decode(mask) when is_integer(mask) and mask in 0x1..0xF do
    for {name, bit, code} <- @conjuncts, Bitwise.band(mask, bit) != 0 do
      %{
        bit: bit,
        name: name,
        code: code,
        detail: "#{code} (mask bit 0x#{Integer.to_string(bit, 16)})"
      }
    end
  end

  @doc """
  The gate. `:admitted` when the mask is null; otherwise
  `{:error, {:refused_lease, mask, %{codes: [...]}}}`.

  Options:

    * `:rdf_state` — Turtle binary; when present the root conjunct recomputes
      the RDFC-1.0 canonical digest of this state instead of comparing the
      carried `semantic_subject.graph_digest` opaquely.
    * `:lease_public_key` — the Ed25519 public key of the authorizing
      authority (`PK_Auth`). Required for the signature conjunct to pass.
    * `:conjunct_hook` — evidence-only `fun.(conjunct_name, failed?)` invoked
      UNCONDITIONALLY for each of the four conjuncts, in table order, before
      the mask is selected. It can never influence the mask. This is the
      branchless witness the CHI-TWO-PORT court asserts on.
  """
  @spec evaluate(Command.t(), Lease.t(), keyword()) :: :admitted | {:error, refusal()}
  def evaluate(%Command{} = command, %Lease{} = lease, opts \\ []) when is_list(opts) do
    now_mono = System.monotonic_time(:millisecond)
    now_wall = DateTime.utc_now()

    # Branchless: every conjunct is evaluated, unconditionally. No early exit.
    scope_failed? = scope_failed?(command, lease)
    root_failed? = root_failed?(command, lease, opts)
    clock_failed? = clock_failed?(lease, now_mono, now_wall)
    signature_failed? = signature_failed?(lease, opts)

    conjunct_results = [
      {:scope, scope_failed?},
      {:root, root_failed?},
      {:clock, clock_failed?},
      {:signature, signature_failed?}
    ]

    case Keyword.get(opts, :conjunct_hook) do
      nil ->
        :ok

      hook when is_function(hook, 2) ->
        # Evidence-only; the return value is discarded. The fold over ALL
        # results (not a filtered subset) is what makes the witness real:
        # a gate that short-circuits would call the hook fewer than four
        # times on a multi-bit refusal.
        Enum.each(conjunct_results, fn {name, failed?} -> hook.(name, failed?) end)
        :ok
    end

    mask =
      Enum.reduce(conjunct_results, 0x0, fn {name, failed?}, acc ->
        if failed?, do: Bitwise.bor(acc, bit_for(name)), else: acc
      end)

    if mask == 0x0 do
      :admitted
    else
      {:error, {:refused_lease, mask, %{codes: Enum.map(decode(mask), & &1.code)}}}
    end
  end

  @doc "The scope digest the gate computes for `command` (conjunct a)."
  @spec scope_digest(Command.t()) :: String.t()
  def scope_digest(%Command{} = command), do: Lease.scope_digest_for(command)

  # --- conjuncts (each returns a boolean; called unconditionally) ------------

  defp scope_failed?(%Command{} = command, %Lease{} = lease) do
    Lease.scope_digest_for(command) != lease.scope_digest
  end

  defp root_failed?(%Command{} = command, %Lease{} = lease, opts) do
    case Keyword.get(opts, :rdf_state) do
      nil ->
        Lease.root_of(command) != lease.root_digest

      rdf_state when is_binary(rdf_state) ->
        case AshA2A.Semantic.CanonicalGraph.canonical_digest(rdf_state) do
          {:ok, digest} -> digest != lease.root_digest
          {:error, _reason} -> true
        end
    end
  end

  defp clock_failed?(%Lease{issued_monotonic_ms: nil} = lease, _now_mono, now_wall) do
    not (DateTime.compare(lease.not_before, now_wall) in [:lt, :eq]) or
      DateTime.compare(now_wall, lease.expires_at) == :gt
  end

  defp clock_failed?(%Lease{issued_monotonic_ms: t_start} = lease, now_mono, _now_wall)
       when is_integer(t_start) do
    duration_ms = DateTime.diff(lease.expires_at, lease.not_before, :millisecond)

    t_start > now_mono or
      duration_ms <= 0 or
      now_mono > t_start + duration_ms
  end

  defp signature_failed?(%Lease{} = lease, opts) do
    public_key = Keyword.get(opts, :lease_public_key)

    cond do
      is_nil(public_key) -> true
      is_nil(lease.signature) -> true
      true -> Lease.verify(lease, lease.signature, public_key) != :ok
    end
  end

  defp bit_for(name), do: elem(List.keyfind!(@conjuncts, name, 0), 1)
end
