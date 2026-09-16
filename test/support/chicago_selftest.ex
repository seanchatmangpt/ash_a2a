defmodule AshA2A.Test.ChicagoSelfTest do
  @moduledoc """
  Real, non-discoverable courts that qualify the Chicago court machinery
  itself (`test/ash_a2a/chicago/foundation_test.exs`). They drive the real
  `AshA2A.CommandBus` over the real `AshA2A.Test.Fixture.Item` ETS resource
  with a real `AshA2A.ReceiptStore.Memory`, and read post-state through
  `Ash.read!/1` -- an independent reader, not the actuator's return value.
  """

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Test.Fixture.Item

  @capability "AshA2A.Test.Fixture.Item.create"

  @doc false
  def with_store(fun) do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)

    try do
      fun.(name: name)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  @doc false
  def labels, do: Item |> Ash.read!() |> Enum.map(& &1.label)

  @doc false
  def message(label) do
    A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])
  end

  @doc false
  def command(label, authority) do
    principal = Identity.principal("chicago-subject")

    Command.new(@capability,
      command_id: "chicago-" <> label,
      agent_id: "chicago-agent",
      principal_id: principal,
      authority: authority && Authority.new(principal, @capability, token_id: "tok-" <> label),
      input: %{label: label}
    )
  end

  defmodule Court do
    @moduledoc "Authority non-implication + positive control over the real CommandBus."
    use AshA2A.Chicago.Court, discoverable: false

    alias AshA2A.Test.ChicagoSelfTest, as: T

    @impl true
    def id, do: "CHI-SELFTEST"
    @impl true
    def title, do: "Chicago machinery self-test"
    @impl true
    def gate, do: nil
    @impl true
    def profile, do: :core
    @impl true
    def rfc_sections, do: ["§12", "§65", "§100"]

    @impl true
    def refusal_codes, do: %{chicago_selftest_refusal: :refused_authority}

    @impl true
    def falsifiers do
      [
        Falsifier.new!(
          id: "CHI-SELFTEST-001",
          court_id: "CHI-SELFTEST",
          kind: :negative,
          invariant:
            "Authentication ⇏ Authority: an authenticated principal with no grant cannot actuate a :change capability",
          stimulus: "CommandBus.run/4 of Item.create with a real principal and no Authority",
          boundary: "AshA2A.CommandBus admission",
          forbidden_outcome: "dispatch/actuation of Item.create, or a new Item row",
          attempt_evidence: "brce.admission refused event attributed to this stimulus",
          survival_evidence:
            "brce.actuate.start or dispatch.start attributed to the stimulus; label present in an independent Ash.read!",
          guard: "CommandBus.admit/2 authority_required clause",
          failure_class: :authority_failure,
          attempt_predicate:
            {:observed, "brce.admission",
             %{"outcome" => "refused", "code" => "authority_required"}},
          outcome_predicate:
            {:any, [{:observed, "brce.actuate.start"}, {:observed, "dispatch.start"}]}
        ),
        Falsifier.new!(
          id: "CHI-SELFTEST-002",
          court_id: "CHI-SELFTEST",
          kind: :positive_control,
          invariant: "A matching authority admits a real create: the boundary discriminates",
          stimulus: "CommandBus.run/4 of Item.create with matching Authority",
          boundary: "AshA2A.CommandBus admission + receipt anchor",
          attempt_evidence: "brce.admission admitted",
          survival_evidence:
            "prepared receipt precedes actuation; commit observed; row visible to an independent reader",
          attempt_predicate: {:observed, "brce.admission", %{"outcome" => "admitted"}},
          outcome_predicate:
            {:all,
             [
               {:precedes, "brce.prepare", "brce.actuate.start", "command"},
               {:observed, "brce.commit", %{"outcome" => "committed"}}
             ]}
        )
      ]
    end

    @impl true
    def run(%Context{} = ctx) do
      [negative, positive] = falsifiers()

      T.with_store(fn store_opts ->
        denied = "denied-#{System.unique_integer([:positive])}"

        reply =
          Context.stimulus(ctx, negative, fn ->
            AshA2A.CommandBus.run(
              T.command(denied, false),
              T.message(denied),
              AshA2A.Test.Fixture.Item,
              store_opts: store_opts
            )
          end)

        negative_result =
          Result.negative(negative,
            attempt_observed?: Context.observed?(ctx, negative, "brce.admission"),
            forbidden_outcome_observed?:
              Context.observed?(ctx, negative, "brce.actuate.start") or denied in T.labels(),
            evidence: %{"reply_code" => reply |> elem(1) |> Map.get(:code) |> inspect()}
          )

        allowed = "allowed-#{System.unique_integer([:positive])}"

        {:ok, receipt} =
          Context.stimulus(ctx, positive, fn ->
            CommandBus.run(T.command(allowed, true), T.message(allowed), AshA2A.Test.Fixture.Item,
              store_opts: store_opts
            )
          end)

        positive_result =
          Result.positive(positive,
            attempt_observed?: Context.observed?(ctx, positive, "brce.admission"),
            expected_outcome_observed?:
              allowed in T.labels() and Context.observed?(ctx, positive, "brce.commit"),
            evidence: %{"receipt_id" => receipt.receipt_id}
          )

        [negative_result, positive_result]
      end)
    end
  end

  defmodule LyingCourt do
    @moduledoc "Reports a kill without ever stimulating the SUT: must not count."
    use AshA2A.Chicago.Court, discoverable: false

    @impl true
    def id, do: "CHI-LIAR"
    @impl true
    def title, do: "vacuous court"
    @impl true
    def gate, do: nil
    @impl true
    def profile, do: :core
    @impl true
    def rfc_sections, do: ["§12"]

    @impl true
    def falsifiers do
      [
        Falsifier.new!(
          id: "CHI-LIAR-001",
          court_id: "CHI-LIAR",
          kind: :negative,
          invariant: "vacuous",
          stimulus: "none",
          boundary: "none",
          forbidden_outcome: "none",
          attempt_evidence: "brce.admission",
          survival_evidence: "none",
          guard: "none",
          attempt_predicate: {:observed, "brce.admission"},
          outcome_predicate: {:observed, "brce.actuate.start"}
        ),
        Falsifier.new!(
          id: "CHI-LIAR-002",
          court_id: "CHI-LIAR",
          kind: :negative,
          invariant: "declared but never reported",
          stimulus: "none",
          boundary: "none",
          forbidden_outcome: "none",
          attempt_evidence: "none",
          survival_evidence: "none",
          guard: "none"
        )
      ]
    end

    @impl true
    def run(_ctx) do
      [f | _] = falsifiers()
      # Claims positive attempt evidence it never produced.
      [Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: false)]
    end
  end

  defmodule CrashingCourt do
    @moduledoc "Raises mid-run: every declared falsifier must become :unknown."
    use AshA2A.Chicago.Court, discoverable: false

    @impl true
    def id, do: "CHI-CRASH"
    @impl true
    def title, do: "crashing court"
    @impl true
    def gate, do: 7
    @impl true
    def profile, do: :core
    @impl true
    def rfc_sections, do: ["§130"]

    @impl true
    def falsifiers do
      [
        Falsifier.new!(
          id: "CHI-CRASH-001",
          court_id: "CHI-CRASH",
          kind: :negative,
          invariant: "an exception is never success",
          stimulus: "raise",
          boundary: "runner",
          forbidden_outcome: "pass",
          attempt_evidence: "none",
          survival_evidence: "none",
          guard: "Runner.safe_run/2 rescue"
        )
      ]
    end

    @impl true
    def run(_ctx), do: raise("court exploded")
  end
end
