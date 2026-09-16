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

  `promote/3` enforces both halves of the RFC requirement:

    1. **Adjacency.** Only the immediately-next class in the chain is
       reachable. Skipping (`LocalTest` -> `Production`) is
       `:non_adjacent_evidence_promotion`.
    2. **New evidence.** The supplied evidence digest must differ from the
       digest already carried by the current value. Re-presenting the evidence
       you already had is `:promotion_without_new_evidence` -- this is the case
       the RFC actually cares about ("promotion without new evidence MUST be
       refused"), because re-running the same local test suite is the natural
       way a caller tries to manufacture a stronger claim.

  Both refusals are typed maps, matching the refusal shape used throughout
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

      @enforce_keys [:evidence_digest, :observed_at]
      defstruct [:evidence_digest, :observed_at, basis: %{}]

      @type t :: %__MODULE__{
              evidence_digest: String.t(),
              observed_at: DateTime.t(),
              basis: map()
            }

      @impl AshA2A.Evidence.Class
      def rank, do: unquote(rank)

      @impl AshA2A.Evidence.Class
      def label, do: unquote(label)

      @doc """
      Builds this evidence class value from a real observation.

      `:basis` is whatever was actually observed (a command, a test run, a
      deploy id). Its `:erlang.term_to_binary/1` SHA-256 becomes
      `:evidence_digest`, which is what `AshA2A.Evidence.Class.promote/3`
      compares to decide whether new evidence was genuinely supplied.
      """
      @spec new(map() | keyword()) :: t()
      def new(basis \\ %{}) do
        basis = Map.new(basis)

        %__MODULE__{
          evidence_digest: AshA2A.Evidence.Class.digest(basis),
          observed_at: DateTime.utc_now(),
          basis: basis
        }
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
  Promotes `current` to `target` using genuinely new evidence.

  Refuses (never raises) when the promotion skips a step, goes backwards, or
  supplies evidence already carried by `current`.

      iex> local = AshA2A.Evidence.LocalTest.new(%{suite: "mix test", run: 1})
      iex> {:ok, ci} = AshA2A.Evidence.Class.promote(local, AshA2A.Evidence.HostedCI, %{job: "ci-42"})
      iex> ci.__struct__
      AshA2A.Evidence.HostedCI

      iex> local = AshA2A.Evidence.LocalTest.new(%{suite: "mix test", run: 1})
      iex> AshA2A.Evidence.Class.promote(local, AshA2A.Evidence.Production, %{deploy: "d-1"})
      {:error, %{code: :non_adjacent_evidence_promotion, detail: "local_test cannot reach production without hosted_ci"}}
  """
  @spec promote(t(), module(), map() | keyword()) :: {:ok, t()} | refusal()
  def promote(current, target, new_basis \\ %{})

  def promote(%from{} = current, target, new_basis) when is_atom(target) do
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

      digest(Map.new(new_basis)) == current.evidence_digest ->
        refuse(
          :promotion_without_new_evidence,
          "#{target.label()} requires evidence distinct from the #{from.label()} evidence already held"
        )

      true ->
        {:ok, target.new(new_basis)}
    end
  end

  def promote(_current, _target, _basis),
    do: refuse(:not_an_evidence_class, "promotion source is not an evidence class value")

  @doc """
  Asserts `value` is at least as strong as `required`.

  This is the read-side guard: a caller that requires `Production` evidence
  calls this rather than comparing labels by hand. It never upgrades anything.
  """
  @spec assert_at_least(t(), module()) :: :ok | refusal()
  def assert_at_least(%from{}, required) when is_atom(required) do
    cond do
      not class?(from) or not class?(required) ->
        refuse(:not_an_evidence_class, "expected evidence classes")

      rank(from) >= rank(required) ->
        :ok

      true ->
        refuse(
          :insufficient_evidence_class,
          "have #{from.label()} (#{rank(from)}), require #{required.label()} (#{rank(required)})"
        )
    end
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
