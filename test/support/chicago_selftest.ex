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
      # `nil` -- never `false` -- is "no authority" (`Command.t()`): a `false`
      # authority reaches `AshA2A.Receipt.authority_grant/1` whenever admission
      # is bypassed (e.g. under a mutant) and crashes the court instead of
      # letting the forbidden actuation be observed.
      authority:
        if(authority, do: Authority.new(principal, @capability, token_id: "tok-" <> label)),
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

  defmodule ReplayCourt do
    @moduledoc """
    Real, non-discoverable court alongside `AshA2A.Test.ChicagoSelfTest.Court`
    proving `AshA2A.CommandBus`'s replay guard (`claim_receipt/3` ->
    `AshA2A.ReceiptStore.claim/2` `{:replay, receipt}` branch) is not vacuous
    for RFC-SA2A-002 §97's `AshA2A.Chicago.Mutation.Catalog`
    `"replay_calls_actuator"` mutation.

    `AshA2A.Test.ChicagoSelfTest.Court` (CHI-SELFTEST) deliberately never
    drives a replay -- it exists to prove authority non-implication -- and
    `AshA2A.Chicago.MutationHarnessTest` "a vacuous court for the guard is
    reported as mutant_survived" documents the anti-vacuity engine correctly
    catching exactly that gap for CHI-SELFTEST. This court closes the gap for
    real, as its own court: it resubmits the identical, already-committed
    `Item.create` command a second time through the real `AshA2A.CommandBus`
    and asserts, via the independent OCEL observer, that the second
    submission's stimulus bracket observes only a `brce.claim` decision and
    never `brce.actuate.start` / `dispatch.start`.

    Attempt evidence is outcome-neutral (`{:observed, "brce.claim"}`, not
    filtered to `outcome=replay`), for the same reason
    `AshA2A.Chicago.Fixtures.MutationHarness.GuardCourt`'s moduledoc gives:
    the `replay_calls_actuator` mutant rewrites `claim_receipt/3` so the
    boundary itself reports `outcome=execute` on what is really a replay --
    filtering attempt evidence on that value would make the exact mutation
    under test look like an uncorroborated `:unknown` (evidence destroyed)
    rather than the real, corroborated `FALSIFIER_SURVIVED` the removed guard
    actually causes.
    """
    use AshA2A.Chicago.Court, discoverable: false

    alias AshA2A.Test.ChicagoSelfTest, as: T

    @impl true
    def id, do: "CHI-SELFTEST-REPLAY"
    @impl true
    def title, do: "Chicago machinery self-test: CommandBus replay guard"
    @impl true
    def gate, do: nil
    @impl true
    def profile, do: :core
    @impl true
    def rfc_sections, do: ["§38", "§71", "§97"]

    @impl true
    def falsifiers do
      [
        Falsifier.new!(
          id: "CHI-SELFTEST-REPLAY-001",
          court_id: "CHI-SELFTEST-REPLAY",
          kind: :negative,
          invariant: "§38/§71: a replayed command never re-actuates",
          stimulus:
            "the identical, already-committed Item.create command (same command_id and fingerprint) resubmitted via CommandBus.run/4",
          boundary: "AshA2A.CommandBus claim_receipt/3 (AshA2A.ReceiptStore.claim/2)",
          forbidden_outcome: "a second actuation / a second Item row for the same label",
          attempt_evidence: "brce.claim decided for this (second, replay) submission",
          survival_evidence:
            "brce.actuate.start or dispatch.start attributed to the replay submission; label count > 1 in an independent Ash.read!",
          guard:
            "CommandBus.claim_receipt/3 -> ReceiptStore.Memory.claim/2 {:replay, receipt} branch",
          failure_class: :replay_failure,
          attempt_predicate: {:observed, "brce.claim"},
          outcome_predicate:
            {:any, [{:observed, "brce.actuate.start"}, {:observed, "dispatch.start"}]}
        )
      ]
    end

    @impl true
    def run(%Context{} = ctx) do
      [falsifier] = falsifiers()

      T.with_store(fn store_opts ->
        label = "replay-#{System.unique_integer([:positive])}"
        command = T.command(label, true)
        message = T.message(label)

        {:ok, first_receipt} =
          CommandBus.run(command, message, AshA2A.Test.Fixture.Item, store_opts: store_opts)

        count_before_replay = Enum.count(T.labels(), &(&1 == label))

        replayed =
          Context.stimulus(ctx, falsifier, fn ->
            CommandBus.run(command, message, AshA2A.Test.Fixture.Item, store_opts: store_opts)
          end)

        count_after_replay = Enum.count(T.labels(), &(&1 == label))
        second_call_records = Context.observed(ctx, falsifier)

        [
          Result.negative(falsifier,
            attempt_observed?: Context.observed?(ctx, falsifier, "brce.claim"),
            forbidden_outcome_observed?:
              Context.observed?(ctx, falsifier, "brce.actuate.start") or
                Context.observed?(ctx, falsifier, "dispatch.start") or
                count_after_replay > count_before_replay,
            evidence: %{
              "first_receipt_id" => inspect(Map.get(first_receipt, :receipt_id)),
              "count_before_replay" => count_before_replay,
              "count_after_replay" => count_after_replay,
              "replayed?" => match?({:ok, %{replayed?: true}}, replayed),
              "second_call_activities" =>
                Enum.map(second_call_records, &inspect({&1.activity, &1.attributes["outcome"]}))
            }
          )
        ]
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
