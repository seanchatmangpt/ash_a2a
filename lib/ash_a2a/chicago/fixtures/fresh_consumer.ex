defmodule AshA2A.Chicago.Fixtures.FreshConsumer do
  @moduledoc """
  Real fixtures for the Gate 11 fresh-consumer court
  (`AshA2A.Chicago.Courts.FreshConsumer`, RFC-SA2A-002 §42, §74).

  The court needs genuine durable conformance packages to verify, so these
  fixtures are real, non-discoverable producer courts that drive the real
  `AshA2A.CommandBus` over a real ETS-backed Ash resource (`Ledger`) with a
  real `AshA2A.ReceiptStore.Memory`; `AshA2A.Chicago.Runner` writes their
  packages exactly as it writes any qualification package.

    * `ProducerCourt` -- a clean producer: a no-grant create refused
      (negative) and an authorized create committed (positive control).
    * `HiddenStateCourt` -- its falsifier's attempt predicate reads mutable
      singleton state (`:persistent_term`) the producer VM sets and no package
      file records: a package whose standing depends on hidden producer state.
    * `MisaimedCourt` -- its attempt predicate names a refusal code the SUT
      does not emit for its stimulus, so the runner honestly downgrades the
      reported kill to UNKNOWN (a package a verdict tamper would promote).

  Compiled in every environment; nothing here references `test/support`.
  """

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Chicago.{Context, Result}
  alias AshA2A.Chicago.Fixtures.FreshConsumer.Ledger

  @capability "AshA2A.Chicago.Fixtures.FreshConsumer.Ledger.create"
  @hidden_key {__MODULE__, :hidden_refusal_code}

  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "Runs `fun` with a fresh, real in-memory receipt store."
  @spec with_store((keyword() -> result)) :: result when result: var
  def with_store(fun) do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)

    try do
      fun.(name: name)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  @doc "Independent post-state reader: every ledger label, via `Ash.read!/1`."
  @spec labels() :: [String.t()]
  def labels, do: Ledger |> Ash.read!() |> Enum.map(& &1.label)

  @doc "A real create command through the real CommandBus, with or without a matching grant."
  @spec submit(String.t(), boolean(), keyword()) :: CommandBus.result()
  def submit(label, authorized?, store_opts) do
    principal = Identity.principal("chicago-fresh-consumer")

    command =
      Command.new(@capability,
        command_id: "chicago-fresh-" <> label,
        agent_id: "chicago-fresh-agent",
        principal_id: principal,
        authority:
          authorized? && Authority.new(principal, @capability, token_id: "tok-fresh-" <> label),
        input: %{label: label}
      )

    message = A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])
    CommandBus.run(command, message, Ledger, store_opts: store_opts)
  end

  @doc "Unique label for one stimulus."
  @spec label(String.t()) :: String.t()
  def label(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Hidden producer state for `HiddenStateCourt`: deliberately NOT written to
  # any package file.

  @spec put_hidden_state(String.t()) :: :ok
  def put_hidden_state(code), do: :persistent_term.put(@hidden_key, code)

  @spec erase_hidden_state() :: boolean()
  def erase_hidden_state, do: :persistent_term.erase(@hidden_key)

  @spec hidden_state() :: String.t()
  def hidden_state, do: :persistent_term.get(@hidden_key, "hidden-producer-state-absent")

  @doc false
  def refusal_falsifier(court_id, id, code, invariant) do
    AshA2A.Chicago.Falsifier.new!(
      id: id,
      court_id: court_id,
      kind: :negative,
      invariant: invariant,
      stimulus: "CommandBus.run/4 of Ledger.create with a real principal and no Authority",
      boundary: "AshA2A.CommandBus admission",
      forbidden_outcome: "actuation of Ledger.create, or a new Ledger row",
      attempt_evidence: "brce.admission refused with code #{code}",
      survival_evidence: "brce.actuate.start or dispatch.start attributed to the stimulus",
      guard: "CommandBus.admit/2 authority clauses",
      failure_class: :authority_failure,
      attempt_predicate: {:observed, "brce.admission", %{"outcome" => "refused", "code" => code}},
      outcome_predicate:
        {:any, [{:observed, "brce.actuate.start"}, {:observed, "dispatch.start"}]}
    )
  end

  @doc false
  def run_refusal(ctx, falsifier, store_opts) do
    denied = label("denied")

    Context.stimulus(ctx, falsifier, fn -> submit(denied, false, store_opts) end)

    Result.negative(falsifier,
      attempt_observed?: Context.observed?(ctx, falsifier, "brce.admission"),
      forbidden_outcome_observed?:
        Context.observed?(ctx, falsifier, "brce.actuate.start") or denied in labels(),
      evidence: %{"label" => denied}
    )
  end
end

defmodule AshA2A.Chicago.Fixtures.FreshConsumer.Ledger do
  @moduledoc "Real ETS-backed Ash resource the fresh-consumer producer courts act on."

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.FreshConsumer.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, create: [:label]])
  end

  a2a do
    skill(:create_entry, :create)
  end
end

defmodule AshA2A.Chicago.Fixtures.FreshConsumer.Domain do
  @moduledoc "Real Ash domain for `AshA2A.Chicago.Fixtures.FreshConsumer.Ledger`."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Fixtures.FreshConsumer.Ledger)
  end
end

defmodule AshA2A.Chicago.Fixtures.FreshConsumer.ProducerCourt do
  @moduledoc """
  Clean producer court: no-grant refusal (negative) + authorized create
  (positive control) over the real CommandBus. Its package must reproduce in a
  fresh consumer.
  """

  use AshA2A.Chicago.Court, discoverable: false

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.FreshConsumer, as: F

  @impl true
  def id, do: "CHI-FRESHFIX-PRODUCER"
  @impl true
  def title, do: "Fresh-consumer fixture: clean producer"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§42", "§65", "§100"]

  @impl true
  def falsifiers do
    [
      F.refusal_falsifier(
        id(),
        "CHI-FRESHFIX-PRODUCER-001",
        "authority_required",
        "Authentication ⇏ Authority: no grant, no actuation"
      ),
      Falsifier.new!(
        id: "CHI-FRESHFIX-PRODUCER-002",
        court_id: id(),
        kind: :positive_control,
        invariant: "A matching authority admits a real create",
        stimulus: "CommandBus.run/4 of Ledger.create with matching Authority",
        boundary: "AshA2A.CommandBus admission + receipt anchor",
        attempt_evidence: "brce.admission admitted",
        survival_evidence: "prepare precedes actuation; commit observed; row readable",
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

    F.with_store(fn store_opts ->
      negative_result = F.run_refusal(ctx, negative, store_opts)
      allowed = F.label("allowed")
      reply = Context.stimulus(ctx, positive, fn -> F.submit(allowed, true, store_opts) end)

      positive_result =
        Result.positive(positive,
          attempt_observed?: Context.observed?(ctx, positive, "brce.admission"),
          expected_outcome_observed?:
            match?({:ok, _}, reply) and allowed in F.labels() and
              Context.observed?(ctx, positive, "brce.commit"),
          evidence: %{"label" => allowed}
        )

      [negative_result, positive_result]
    end)
  end
end

defmodule AshA2A.Chicago.Fixtures.FreshConsumer.HiddenStateCourt do
  @moduledoc """
  Producer court whose falsifier declaration depends on hidden producer state:
  the refusal code in its attempt predicate is read from `:persistent_term`,
  which the producer VM sets before the run and no package file records. In
  the producer VM the predicate corroborates; in a fresh OS process it does
  not, so the standing cannot be reproduced there (§42).
  """

  use AshA2A.Chicago.Court, discoverable: false

  alias AshA2A.Chicago.Context
  alias AshA2A.Chicago.Fixtures.FreshConsumer, as: F

  @impl true
  def id, do: "CHI-FRESHFIX-HIDDEN"
  @impl true
  def title, do: "Fresh-consumer fixture: hidden producer-state dependency"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§42"]

  @impl true
  def falsifiers do
    [
      F.refusal_falsifier(
        id(),
        "CHI-FRESHFIX-HIDDEN-001",
        F.hidden_state(),
        "no grant, no actuation (predicate read from hidden producer state)"
      )
    ]
  end

  @impl true
  def run(%Context{} = ctx) do
    [negative] = falsifiers()
    F.with_store(fn store_opts -> [F.run_refusal(ctx, negative, store_opts)] end)
  end
end

defmodule AshA2A.Chicago.Fixtures.FreshConsumer.MisaimedCourt do
  @moduledoc """
  Producer court whose attempt predicate names `authority_mismatch` while its
  stimulus (no Authority at all) makes the real CommandBus refuse with
  `authority_required`. The court reports a kill; the independent OCEL
  consumer cannot corroborate the attempt, so the runner records UNKNOWN.
  """

  use AshA2A.Chicago.Court, discoverable: false

  alias AshA2A.Chicago.Context
  alias AshA2A.Chicago.Fixtures.FreshConsumer, as: F

  @impl true
  def id, do: "CHI-FRESHFIX-MISAIMED"
  @impl true
  def title, do: "Fresh-consumer fixture: misaimed attempt predicate"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§12", "§104"]

  @impl true
  def falsifiers do
    [
      F.refusal_falsifier(
        id(),
        "CHI-FRESHFIX-MISAIMED-001",
        "authority_mismatch",
        "a mismatched grant cannot actuate (stimulus sends no grant: misaimed)"
      )
    ]
  end

  @impl true
  def run(%Context{} = ctx) do
    [negative] = falsifiers()
    F.with_store(fn store_opts -> [F.run_refusal(ctx, negative, store_opts)] end)
  end
end
