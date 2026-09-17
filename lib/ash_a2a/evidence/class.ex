defmodule AshA2A.Evidence.Class do
  @moduledoc """
  RFC-SA2A-001 S70 evidence boundaries as a real type-level separation.

  The RFC states the boundary as a chain of *non-implications*:

      LocalTest !=> HostedCI !=> Production !=> RuntimeAlive !=> Publication !=> Merge

  Each arrow is crossed out: passing at one class is not evidence for the next.
  This module makes that structural rather than documentary. Every class is its
  own distinct struct module (`AshA2A.Evidence.LocalTest`,
  `AshA2A.Evidence.HostedCI`, ...), so:

    * a function head written `def f(%AshA2A.Evidence.Production{})` simply does
      not match a `%AshA2A.Evidence.LocalTest{}` -- there is no coercion path,
      no shared tagged tuple, and no `String.to_existing_atom/1` conversion;
    * `Kernel.struct/2` cannot turn one class into another, because struct
      update syntax is compile-time-bound to a single module;
    * there is deliberately no `coerce/2`, `to_class/2`, or `cast/2`. The only
      way to obtain a stronger class value is `promote/3`, which refuses unless
      genuinely new evidence is supplied.

  ## Promotion refuses without new evidence

  `promote/3` enforces five separate conditions, each a distinct refusal:

    1. **Adjacency.** Only the immediately-next class in the chain is
       reachable. Skipping (`LocalTest` -> `Production`) is
       `:non_adjacent_evidence_promotion`.
    2. **An intact predecessor.** The current value's own chain link is
       recomputed and must match; a value whose link does not verify is
       `:evidence_chain_broken` and cannot promote at all.
    3. **Non-empty evidence.** `%{}` is not evidence.
       `:promotion_without_new_evidence`. Without this, an empty basis
       promotes any class one step for free, because an empty map is
       trivially "different from" the current basis.
    4. **Evidence not already held.** The supplied digest must differ from
       the digest carried by the current value --
       `:promotion_without_new_evidence`, the case the RFC names directly.
    5. **Evidence never consumed anywhere in this chain.** Each value
       remembers every evidence digest spent to reach it
       (`consumed_evidence`), so the `LocalTest` basis cannot be re-presented
       two steps later to buy `Production`. That is `:evidence_replayed`.

  Conditions 2, 3 and 5 are what make the boundary impermeable rather than
  merely adjacent-and-different: a check that only compares against the
  *immediately preceding* basis has no memory, and one that discards the
  current class entirely leaves the successor with no link to its
  predecessor, so a hand-built struct at any rank is indistinguishable from
  an earned one.

  ## Every value is chained to its predecessor

  Each class value carries `prior_digest` (its predecessor's `chain_digest`,
  `nil` at the root) and its own `chain_digest`, a digest over
  `{label, evidence_digest, prior_digest, sorted consumed_evidence}`.
  `verify_chain/1` recomputes that link and additionally requires that a
  value above rank 1 actually has a predecessor and has consumed at least
  one distinct evidence per step climbed. `promote/3` and
  `assert_at_least/2` both run it, so a forged class -- a `%Merge{}` built
  by hand with a plausible-looking `evidence_digest` -- is refused at the
  read side instead of riding into an attestation.

  `new/1` builds a *root*: valid on its own at rank 1, and refused by
  `verify_chain/1` above rank 1 (`:evidence_class_not_earned`). A strong
  class is earned by promotion or it is not held.

  All refusals are typed maps, matching the refusal shape used throughout
  `AshA2A.CommandBus`.

  ## Default class is the weakest one

  `default/0` reads `:ash_a2a, :evidence_class` and falls back to
  `AshA2A.Evidence.LocalTest`. The runtime cannot observe whether it is in
  production; claiming `Production` by default would be exactly the
  overclaim S70 exists to prevent.
  """

  @typedoc "Any one of the six evidence class structs."
  @type t ::
          AshA2A.Evidence.LocalTest.t()
          | AshA2A.Evidence.HostedCI.t()
          | AshA2A.Evidence.Production.t()
          | AshA2A.Evidence.RuntimeAlive.t()
          | AshA2A.Evidence.Publication.t()
          | AshA2A.Evidence.Merge.t()

  @type refusal :: {:error, %{code: atom(), detail: String.t()}}

  @callback rank() :: pos_integer()
  @callback label() :: atom()

  @chain [
    AshA2A.Evidence.LocalTest,
    AshA2A.Evidence.HostedCI,
    AshA2A.Evidence.Production,
    AshA2A.Evidence.RuntimeAlive,
    AshA2A.Evidence.Publication,
    AshA2A.Evidence.Merge
  ]

  @doc """
  Injects one evidence class struct.

  Each class carries the same three observation fields and nothing else --
  the class *is* the type; the payload is only the evidence that justified
  reaching it.
  """
  defmacro __using__(opts) do
    rank = Keyword.fetch!(opts, :rank)
    label = Keyword.fetch!(opts, :label)

    quote do
      @behaviour AshA2A.Evidence.Class

      @enforce_keys [:evidence_digest, :observed_at, :chain_digest]
      defstruct [
        :evidence_digest,
        :observed_at,
        :chain_digest,
        prior_digest: nil,
        basis: %{},
        consumed_evidence: []
      ]

      @type t :: %__MODULE__{
              evidence_digest: String.t(),
              observed_at: DateTime.t(),
              chain_digest: String.t(),
              prior_digest: String.t() | nil,
              basis: map(),
              consumed_evidence: [String.t()]
            }

      @impl AshA2A.Evidence.Class
      def rank, do: unquote(rank)

      @impl AshA2A.Evidence.Class
      def label, do: unquote(label)

      @doc """
      Builds this evidence class value as a chain **root** from a real
      observation.

      `:basis` is whatever was actually observed (a command, a test run, a
      deploy id). Its `:erlang.term_to_binary/1` SHA-256 becomes
      `:evidence_digest`, which is what `AshA2A.Evidence.Class.promote/3`
      compares to decide whether new evidence was genuinely supplied.

      A root has `prior_digest: nil`. That is lawful only at rank 1:
      `AshA2A.Evidence.Class.verify_chain/1` refuses an unlinked value
      above rank 1 with `:evidence_class_not_earned`, so calling
      `new/1` on a strong class does not confer that class -- it has to
      be reached by real promotions from a real `LocalTest`.
      """
      @spec new(map() | keyword()) :: t()
      def new(basis \\ %{}) do
        AshA2A.Evidence.Class.build(__MODULE__, Map.new(basis), nil, [])
      end
    end
  end

  @doc "The ordered evidence chain, weakest first."
  @spec chain() :: [module()]
  def chain, do: @chain

  @doc "The configured default class -- deliberately the weakest one."
  @spec default() :: module()
  def default do
    Application.get_env(:ash_a2a, :evidence_class, AshA2A.Evidence.LocalTest)
  end

  @doc "Whether `module` is one of the six evidence classes."
  @spec class?(term()) :: boolean()
  def class?(module) when is_atom(module), do: module in @chain
  def class?(_), do: false

  @doc "Whether `value` is an evidence class *value* (a struct of one of the six)."
  @spec value?(term()) :: boolean()
  def value?(%module{}), do: class?(module)
  def value?(_), do: false

  @doc "The module of an evidence class value."
  @spec module(t()) :: module()
  def module(%module{}), do: module

  @doc "Rank of a class value or class module (1..6, weakest first)."
  @spec rank(t() | module()) :: pos_integer()
  def rank(%module{}), do: module.rank()
  def rank(module) when is_atom(module), do: module.rank()

  @doc "Label of a class value or class module."
  @spec label(t() | module()) :: atom()
  def label(%module{}), do: module.label()
  def label(module) when is_atom(module), do: module.label()

  @doc "SHA-256 of any term, used as the evidence digest."
  @spec digest(term()) :: String.t()
  def digest(term) do
    "sha256:" <>
      (term
       |> :erlang.term_to_binary()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower))
  end

  @doc """
  Builds a class value of `module` with a real link to its predecessor.

  `prior_digest` is the predecessor's `chain_digest` (`nil` for a root) and
  `prior_consumed` is every evidence digest already spent to reach the
  predecessor. The new value's `consumed_evidence` is that list plus this
  step's own digest, so the chain carries its whole spend history and
  `promote/3` can refuse a replay of anything already used.

  Public because `__using__/1`'s `new/1` and `promote/3` both need it and
  neither should re-derive the link shape.
  """
  @spec build(module(), map(), String.t() | nil, [String.t()]) :: t()
  def build(module, basis, prior_digest, prior_consumed) do
    evidence_digest = digest(basis)
    consumed = Enum.uniq([evidence_digest | prior_consumed])

    struct!(module,
      evidence_digest: evidence_digest,
      observed_at: DateTime.utc_now(),
      chain_digest: link_digest(module, evidence_digest, prior_digest, consumed),
      prior_digest: prior_digest,
      basis: basis,
      consumed_evidence: consumed
    )
  end

  @doc """
  The tamper-evident link for a class value: a digest over its label, its
  evidence digest, its predecessor's link, and the sorted set of evidence
  already consumed in the chain.

  Sorted, so the link is a function of the *set* of spent evidence and not
  of the order a caller happened to build the list in. `observed_at` is
  deliberately excluded: a timestamp is an observation about the value, not
  part of what was proved.
  """
  @spec link_digest(module(), String.t(), String.t() | nil, [String.t()]) :: String.t()
  def link_digest(module, evidence_digest, prior_digest, consumed_evidence) do
    digest({module.label(), evidence_digest, prior_digest, Enum.sort(consumed_evidence)})
  end

  @doc """
  Verifies that `value` is a genuinely earned class, not a hand-built one.

  Four conditions, each separately refusable:

    * the recomputed `chain_digest` matches the recorded one
      (`:evidence_chain_broken`);
    * the value's own evidence digest is in its `consumed_evidence`
      (`:evidence_chain_broken`);
    * a value above rank 1 has a predecessor link
      (`:evidence_class_not_earned`);
    * a value at rank N has spent at least N distinct evidences
      (`:evidence_class_not_earned`) -- one per step climbed.

      iex> local = AshA2A.Evidence.LocalTest.new(%{suite: "mix test"})
      iex> AshA2A.Evidence.Class.verify_chain(local)
      :ok

      iex> forged = %AshA2A.Evidence.Merge{
      ...>   evidence_digest: AshA2A.Evidence.Class.digest(%{forged: true}),
      ...>   observed_at: DateTime.utc_now(),
      ...>   chain_digest: "sha256:whatever"
      ...> }
      iex> {:error, %{code: code}} = AshA2A.Evidence.Class.verify_chain(forged)
      iex> code
      :evidence_chain_broken
  """
  @spec verify_chain(t()) :: :ok | refusal()
  def verify_chain(%module{} = value) when is_atom(module) do
    if class?(module) do
      verify_class_chain(module, value)
    else
      refuse(:not_an_evidence_class, "#{inspect(module)} is not an evidence class")
    end
  end

  def verify_chain(_other),
    do: refuse(:not_an_evidence_class, "not an evidence class value")

  defp verify_class_chain(module, value) do
    recomputed =
      link_digest(module, value.evidence_digest, value.prior_digest, value.consumed_evidence)

    cond do
      recomputed != value.chain_digest ->
        refuse(
          :evidence_chain_broken,
          "#{module.label()} chain link does not match its own contents; recorded " <>
            "#{inspect(value.chain_digest)}, recomputed #{inspect(recomputed)}"
        )

      value.evidence_digest not in value.consumed_evidence ->
        refuse(
          :evidence_chain_broken,
          "#{module.label()} does not carry its own evidence in its consumed set"
        )

      rank(module) > 1 and is_nil(value.prior_digest) ->
        refuse(
          :evidence_class_not_earned,
          "#{module.label()} (rank #{rank(module)}) has no predecessor link; a class above " <>
            "local_test is reached by promotion, never constructed"
        )

      length(value.consumed_evidence) < rank(module) ->
        refuse(
          :evidence_class_not_earned,
          "#{module.label()} (rank #{rank(module)}) carries only " <>
            "#{length(value.consumed_evidence)} distinct evidence(s); one per step is required"
        )

      true ->
        :ok
    end
  end

  @doc """
  The class immediately above `class`, or `:error` at the top of the chain.
  """
  @spec next(t() | module()) :: {:ok, module()} | :error
  def next(%module{}), do: next(module)

  def next(module) when is_atom(module) do
    case Enum.drop_while(@chain, &(&1 != module)) do
      [^module, next | _] -> {:ok, next}
      _ -> :error
    end
  end

  @doc """
  Promotes `current` to `target` using genuinely new evidence, carrying the
  chain link and the consumed-evidence memory forward.

  Refuses (never raises) when the promotion skips a step, goes backwards,
  starts from a value whose own chain link does not verify, supplies empty
  evidence, supplies the evidence `current` already holds, or replays
  evidence spent anywhere earlier in the chain.

      iex> local = AshA2A.Evidence.LocalTest.new(%{suite: "mix test", run: 1})
      iex> {:ok, ci} = AshA2A.Evidence.Class.promote(local, AshA2A.Evidence.HostedCI, %{job: "ci-42"})
      iex> ci.__struct__
      AshA2A.Evidence.HostedCI

      iex> local = AshA2A.Evidence.LocalTest.new(%{suite: "mix test", run: 1})
      iex> AshA2A.Evidence.Class.promote(local, AshA2A.Evidence.Production, %{deploy: "d-1"})
      {:error, %{code: :non_adjacent_evidence_promotion, detail: "local_test cannot reach production without hosted_ci"}}

      iex> local = AshA2A.Evidence.LocalTest.new(%{suite: "mix test", run: 1})
      iex> {:error, %{code: code}} = AshA2A.Evidence.Class.promote(local, AshA2A.Evidence.HostedCI, %{})
      iex> code
      :promotion_without_new_evidence
  """
  @spec promote(t(), module(), map() | keyword()) :: {:ok, t()} | refusal()
  def promote(current, target, new_basis \\ %{}) do
    result = do_promote(current, target, new_basis)

    # RFC-SA2A-002 §72 boundary decision (observational only).
    emit(:promote, result, %{
      from: class_label(current),
      to: class_label(target),
      prior_chain_digest: chain_of(current),
      offered_evidence_digest: offered_digest(new_basis)
    })

    result
  end

  defp do_promote(%from{} = current, target, new_basis)
       when is_atom(target) and (is_map(new_basis) or is_list(new_basis)) do
    cond do
      not class?(from) ->
        refuse(:not_an_evidence_class, "#{inspect(from)} is not an evidence class")

      not class?(target) ->
        refuse(:not_an_evidence_class, "#{inspect(target)} is not an evidence class")

      next(from) != {:ok, target} ->
        refuse(
          :non_adjacent_evidence_promotion,
          "#{from.label()} cannot reach #{target.label()}#{via(from, target)}"
        )

      true ->
        promote_verified(current, from, target, Map.new(new_basis))
    end
  end

  defp do_promote(_current, _target, _basis),
    do: refuse(:not_an_evidence_class, "promotion source is not an evidence class value")

  defp promote_verified(current, from, target, new_basis) do
    new_digest = digest(new_basis)

    cond do
      match?({:error, _}, verify_chain(current)) ->
        verify_chain(current)

      map_size(new_basis) == 0 ->
        refuse(
          :promotion_without_new_evidence,
          "#{target.label()} requires real evidence; an empty basis is not an observation"
        )

      new_digest == current.evidence_digest ->
        refuse(
          :promotion_without_new_evidence,
          "#{target.label()} requires evidence distinct from the #{from.label()} evidence already held"
        )

      new_digest in current.consumed_evidence ->
        refuse(
          :evidence_replayed,
          "#{target.label()} was offered evidence already consumed earlier in this chain; " <>
            "re-presenting spent evidence does not climb the chain"
        )

      true ->
        {:ok, build(target, new_basis, current.chain_digest, current.consumed_evidence)}
    end
  end

  @doc """
  Asserts `value` is at least as strong as `required`.

  This is the read-side guard: a caller that requires `Production` evidence
  calls this rather than comparing labels by hand. It never upgrades anything.

  It also runs `verify_chain/1` first, so a forged class value -- the right
  struct module with a plausible `evidence_digest` and no real promotion
  behind it -- is refused here rather than satisfying the guard and riding
  into an attestation. A strong class must be *earned*, and this is where
  that is checked on the way in.
  """
  @spec assert_at_least(t(), module()) :: :ok | refusal()
  def assert_at_least(value, required) when is_atom(required) do
    result = do_assert_at_least(value, required)

    emit(:assert, result, %{
      from: class_label(value),
      to: class_label(required),
      prior_chain_digest: chain_of(value),
      offered_evidence_digest: nil
    })

    result
  end

  defp do_assert_at_least(%from{} = value, required) do
    cond do
      not class?(from) or not class?(required) ->
        refuse(:not_an_evidence_class, "expected evidence classes")

      match?({:error, _}, verify_chain(value)) ->
        verify_chain(value)

      rank(from) >= rank(required) ->
        :ok

      true ->
        refuse(
          :insufficient_evidence_class,
          "have #{from.label()} (#{rank(from)}), require #{required.label()} (#{rank(required)})"
        )
    end
  end

  defp class_label(%module{}), do: class_label(module)

  defp class_label(module) when is_atom(module),
    do: if(class?(module), do: module.label(), else: :not_an_evidence_class)

  defp class_label(_other), do: :not_an_evidence_class

  defp chain_of(%module{chain_digest: chain_digest}) when is_atom(module), do: chain_digest
  defp chain_of(_other), do: nil

  defp offered_digest(basis) when is_map(basis), do: digest(basis)

  defp offered_digest(basis) when is_list(basis) do
    if Enum.all?(basis, &match?({_, _}, &1)), do: digest(Map.new(basis))
  end

  defp offered_digest(_basis), do: nil

  defp emit(decision, result, meta) do
    {outcome, code, chain_digest} =
      case result do
        {:ok, value} -> {:promoted, nil, chain_of(value)}
        :ok -> {:admitted, nil, meta.prior_chain_digest}
        {:error, %{code: code}} -> {:refused, code, nil}
      end

    :telemetry.execute(
      [:ash_a2a, :evidence, decision],
      %{system_time: System.system_time()},
      Map.merge(meta, %{outcome: outcome, code: code, chain_digest: chain_digest})
    )
  end

  defp via(from, target) do
    case next(from) do
      {:ok, step} when step != target -> " without #{step.label()}"
      _ -> ""
    end
  end

  defp refuse(code, detail), do: {:error, %{code: code, detail: detail}}
end

defmodule AshA2A.Evidence.LocalTest do
  @moduledoc "RFC-SA2A-001 S70 class 1: a test run on a developer machine."
  use AshA2A.Evidence.Class, rank: 1, label: :local_test
end

defmodule AshA2A.Evidence.HostedCI do
  @moduledoc "RFC-SA2A-001 S70 class 2: a run on hosted continuous integration."
  use AshA2A.Evidence.Class, rank: 2, label: :hosted_ci
end

defmodule AshA2A.Evidence.Production do
  @moduledoc "RFC-SA2A-001 S70 class 3: the code is deployed to production."
  use AshA2A.Evidence.Class, rank: 3, label: :production
end

defmodule AshA2A.Evidence.RuntimeAlive do
  @moduledoc "RFC-SA2A-001 S70 class 4: observed executing in production."
  use AshA2A.Evidence.Class, rank: 4, label: :runtime_alive
end

defmodule AshA2A.Evidence.Publication do
  @moduledoc "RFC-SA2A-001 S70 class 5: the claim has been published."
  use AshA2A.Evidence.Class, rank: 5, label: :publication
end

defmodule AshA2A.Evidence.Merge do
  @moduledoc "RFC-SA2A-001 S70 class 6: the change is merged."
  use AshA2A.Evidence.Class, rank: 6, label: :merge
end
