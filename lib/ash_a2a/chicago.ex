defmodule AshA2A.Chicago do
  @moduledoc """
  RFC-SA2A-002 v26.9.16 Chicago conformance court for Semantic A2A.

  Conformance is earned by executing qualification courts that attempt to
  falsify the architecture against the exact implementation subject -- not by
  green unit tests, valid plans, or serializable envelopes:

      Conformant(S) ⇒ ExactIdentity(S) ∧ FalsifiersAttempted(S)
                      ∧ ForbiddenStandingAbsent(S)
                      ∧ RequiredConsequencesObserved(S) ∧ IndependentEvidence(S)

      PASS = AttemptObserved ∧ ViolationDidNotAcquireStanding

  ## Pieces

    * `AshA2A.Chicago.Court` -- behaviour every court implements (discovered)
    * `AshA2A.Chicago.Falsifier` -- §11 declaration
    * `AshA2A.Chicago.Result` -- §12 verdict algebra
    * `AshA2A.Chicago.Context` -- stimulus bracketing for attribution
    * `AshA2A.Chicago.Subject` -- §5 exact subject identity
    * `AshA2A.Chicago.Observer` -- independent OCEL 2.0 process observer
    * `AshA2A.Chicago.Query` -- independent consumer + semantic predicates
    * `AshA2A.Chicago.Runner` -- §104 execution order
    * `AshA2A.Chicago.StandingReceipt` -- §115 standing receipt
    * `mix ash_a2a.chicago` -- command-line entry point

  The full specification is `docs/rfc/RFC-SA2A-002-v26.9.16.md`.
  """

  alias AshA2A.Chicago.{Court, Profile, Runner}

  @doc """
  Every discoverable court compiled into `:ash_a2a`, ordered by crown gate
  then id. Discovery reads the application's module list; nothing registers.
  """
  @spec courts() :: [module()]
  def courts do
    _ = Application.load(:ash_a2a)

    :ash_a2a
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.filter(&Court.discoverable?/1)
    |> Enum.sort_by(&{&1.gate() || 99, &1.id()})
  end

  @doc "Discoverable courts applicable to `profile` (cumulative, §25)."
  @spec courts_for(Profile.t()) :: [module()]
  def courts_for(profile), do: Enum.filter(courts(), &Profile.applicable?(&1.profile(), profile))

  @doc "Runs the court. See `AshA2A.Chicago.Runner.run/1`."
  @spec run(keyword()) :: {:ok, Runner.Run.t()} | {:error, term()}
  def run(opts \\ []), do: Runner.run(opts)

  @doc """
  `%{refusal_code => class}` contributed by every compiled module exporting
  `__sa2a_refusal_codes__/0` (courts get it from `use AshA2A.Chicago.Court`).
  Consumed by `AshA2A.Semantic.Refusal.mapping/0`.
  """
  @spec refusal_codes() :: %{atom() => atom()}
  def refusal_codes do
    _ = Application.load(:ash_a2a)

    :ash_a2a
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.filter(
      &(Code.ensure_loaded?(&1) and function_exported?(&1, :__sa2a_refusal_codes__, 0))
    )
    |> Enum.reduce(%{}, fn module, acc -> Map.merge(acc, module.__sa2a_refusal_codes__()) end)
  end
end
