# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthZEN.Monotonic do
  @moduledoc """
  FR-01.4 -- monotonic grant narrowing for agent-spawned subtask delegation
  chains.

  ## The law

  A child spawned by a delegation hop may never hold more than its parent:
  `C_child ⊆ C_parent`, at every hop, for the whole lifetime of the chain.
  The child's effective capability set is the intersection of its parent
  permission set(s) with what it requests; an expansion attempt -- requesting
  a capability the parent does not itself hold -- is an immediate typed
  refusal `:refused_non_monotonic_grant` (`REFUSED_NON_MONOTONIC_GRANT`),
  with a real refusal receipt (canonical `sha256:` digest, offending excess
  set, chain depth, and the instant of refusal), emitted telemetry, and zero
  downstream dispatch: nothing was ever granted, so nothing can actuate.

  ## Two delegation shapes

    * `delegate/2` (single parent, the spawn gate): the requested set MUST be
      a subset of the parent's effective set. Anything else is an escalation
      attempt and is refused -- never silently clamped. This is the
      enforcement point the court drives: an attempted escalation at hop 2
      returns `{:error, %AshA2A.AuthZEN.Monotonic.Refusal{}}` before any
      subtask is created, and the returned receipt records the exact excess
      capabilities and a canonical digest for replay/audit.

    * `delegate/2` over a LIST of parent chains (co-spawned subtask under
      overlapping parent grants): the child's effective set is exactly the
      intersection of the parent sets, narrowed by what was requested. This
      clause never refuses -- a multi-parent child cannot expand beyond any
      one parent, because its set is built as the intersection itself;
      requesting beyond the intersection clamps to it. Intersection semantics
      is the total, always-monotone projection.

  The pure layer (`set/1`, `narrow/2`, `intersect/2`, `intersection/1`) is
  the total intersection semantics; the chain layer (`root/1`, `delegate/2`,
  `authorize/2`) is the enforcement layer. `AshA2A.AuthZEN.DecisionGate
  .admit_delegated/4` composes the two: evidence-only AuthZEN admission from
  `admit/3`, plus a monotonic chain check on the effect's capability, so an
  expanded capability cannot be re-admitted at the gate either.
  """

  alias AshA2A.Identity.Canonical

  @refusal_code :refused_non_monotonic_grant
  @refusal_schema "sa2a.monotonic-grant-refusal.v1"

  @typedoc "A canonical capability id."
  @type id :: String.t()

  @typedoc "A canonical capability set: deduplicated, sorted id list."
  @type set :: [id()]

  defmodule Refusal do
    @moduledoc """
    Typed refusal receipt for a non-monotonic (expansion) grant attempt.

    A value, not a process: it records code, parent effective set, requested
    set, the exact excess (the expansion), the chain depth at which the
    attempt happened, a canonical `sha256:` digest of the refusal body, and
    the instant of refusal. Emitted telemetry
    `[:ash_a2a, :authzen, :monotonic, :refused]` carries the same fields.
    """

    @enforce_keys [:code, :parent_effective, :requested, :excess, :depth, :digest, :refused_at]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            code: :refused_non_monotonic_grant,
            parent_effective: [String.t()],
            requested: [String.t()],
            excess: [String.t()],
            depth: pos_integer(),
            digest: String.t(),
            refused_at: DateTime.t()
          }
  end

  @enforce_keys [:effective, :depth, :parents]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          effective: set(),
          depth: non_neg_integer(),
          parents: [t()]
        }

  @doc "The typed refusal code this module refuses with."
  @spec refusal_code() :: :refused_non_monotonic_grant
  def refusal_code, do: @refusal_code

  @doc """
  Canonical capability set: deduplicated, sorted. Atoms are accepted and
  stringified, so a caller can pass skill selectors straight through.
  """
  @spec set(term()) :: set()
  def set(ids) when is_list(ids) do
    ids |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()
  end

  def set(id), do: set([id])

  @doc """
  The always-lawful projection: the child's effective set is the intersection
  of the parent set with what it requested. `narrow(p, r) ⊆ p`, always -- the
  property the stream_data court pins.

  Never refuses: refusing on expansion is `delegate/2`'s job; `narrow/2` is
  the total intersection semantics underneath it.
  """
  @spec narrow(set(), set()) :: set()
  def narrow(parent, requested) do
    requested_set = set(requested)
    parent_set = set(parent)
    requested_set -- requested_set -- parent_set
  end

  @doc "Symmetric intersection of two capability sets."
  @spec intersect(a :: set(), b :: set()) :: set()
  def intersect(a, b), do: narrow(a, b)

  @doc "Intersection of a list of capability sets."
  @spec intersection([set()]) :: set()
  def intersection([]), do: []

  def intersection([first | rest]) do
    Enum.reduce(rest, set(first), fn next, acc ->
      intersect(acc, next)
    end)
  end

  @doc """
  Opens a delegation chain: the root grant set, at depth 0.
  """
  @spec root(set()) :: t()
  def root(capabilities) do
    %__MODULE__{effective: set(capabilities), depth: 0, parents: []}
  end

  @doc """
  Spawn-time narrowing gate.

    * `delegate(%Monotonic{} = parent, requested)` -- the child's requested
      set must be a subset of `parent.effective`; any expansion attempt
      returns `{:error, %Refusal{}}` -- the typed refusal receipt -- with
      `[:ash_a2a, :authzen, :monotonic, :refused]` telemetry emitted, and
      nothing else happens: no grant is issued, no subtask is spawned, no
      dispatch follows.
    * `delegate([p1, p2, ...], requested)` -- co-spawned subtask under
      overlapping parent grants: the child's effective set is exactly the
      intersection of the parent effective sets, narrowed by the request.
      Never refuses (see moduledoc).
  """
  @spec delegate(t() | [t(), ...], set()) :: {:ok, t()} | {:error, Refusal.t()}
  def delegate(%__MODULE__{} = parent, requested) do
    requested_set = set(requested)
    parent_set = parent.effective
    excess = requested_set -- parent_set

    if excess == [] do
      {:ok, %__MODULE__{effective: requested_set, depth: parent.depth + 1, parents: [parent]}}
    else
      {:error, refusal_receipt(parent_set, requested_set, parent.depth + 1)}
    end
  end

  def delegate([%__MODULE__{} | _] = parents, requested) do
    covered = parents |> Enum.map(& &1.effective) |> intersection()

    {:ok,
     %__MODULE__{
       effective: narrow(covered, requested),
       depth: Enum.max(Enum.map(parents, & &1.depth)) + 1,
       parents: parents
     }}
  end

  @doc """
  Chain admission check: `:ok` iff `capability` lies in the chain's effective
  (narrowed) set; otherwise `{:error, %Refusal{}}` -- the same typed refusal
  receipt `delegate/2` emits, so a capability that was never delegated is
  refused identically when it is *used*.
  """
  @spec authorize(t(), term()) :: :ok | {:error, Refusal.t()}
  def authorize(%__MODULE__{effective: effective} = chain, capability) do
    requested = set(capability)

    if requested -- effective == [] do
      :ok
    else
      {:error, refusal_receipt(effective, requested, chain.depth + 1)}
    end
  end

  ## Receipt + evidence

  # One canonical refusal receipt. `Canonical.digest/1` is total here: the
  # refusal body is pure JSON-domain values (strings, sorted string lists,
  # an integer).
  defp refusal_receipt(parent_effective, requested, depth) do
    excess = requested -- parent_effective

    body = %{
      "schema" => @refusal_schema,
      "code" => to_string(@refusal_code),
      "parent_effective" => parent_effective,
      "requested" => requested,
      "excess" => excess,
      "depth" => depth
    }

    {:ok, digest} = Canonical.digest(body)

    :telemetry.execute(
      [:ash_a2a, :authzen, :monotonic, :refused],
      %{system_time: System.system_time()},
      %{
        code: @refusal_code,
        digest: digest,
        depth: depth,
        parent_effective: parent_effective,
        requested: requested,
        excess: excess
      }
    )

    %Refusal{
      code: @refusal_code,
      parent_effective: parent_effective,
      requested: requested,
      excess: excess,
      depth: depth,
      digest: digest,
      refused_at: DateTime.utc_now()
    }
  end
end
