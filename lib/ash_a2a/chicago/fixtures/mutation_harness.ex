defmodule AshA2A.Chicago.Fixtures.MutationHarness do
  @moduledoc """
  Real collaborators for the mutation-harness slice (RFC-SA2A-002 §22, §97):
  a genuine Ash ETS resource with one `:change` skill, driven through the real
  `AshA2A.CommandBus` with a real `AshA2A.ReceiptStore.Memory` and a real,
  uniquely-named `AshA2A.Authority.Broker.InMemory`. Post-state is read with
  `Ash.read!/1` -- an independent reader, not the actuator's reply.

  Compiled in every environment so the `SA2A-MUTATION` court and
  `mix ash_a2a.chicago.mutate` have a reference killer court
  (`GuardCourt`, id `CHI-MUTGUARD`) without referencing `test/support`.
  """

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Authority.Broker
  alias AshA2A.Chicago.Fixtures.MutationHarness.Ledger

  @subject "mutguard-subject"

  @doc "The Ledger `:record_entry` capability id, read from the compiled DSL."
  @spec capability() :: String.t()
  def capability do
    {:ok, skill} = AshA2A.Info.skill(Ledger, :record_entry)
    skill.id
  end

  @spec labels() :: [String.t()]
  def labels, do: Ledger |> Ash.read!() |> Enum.map(& &1.label)

  @spec unique(String.t()) :: String.t()
  def unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  @spec principal(String.t()) :: Identity.t()
  def principal(name \\ @subject), do: Identity.principal(name)

  @spec message(String.t()) :: A2A.Message.t()
  def message(label), do: A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])

  @doc "A real authority for the Ledger capability (`opts` go to `Authority.new/3`)."
  @spec authority(Identity.t(), keyword()) :: Authority.t()
  def authority(%Identity{} = principal, opts \\ []) do
    Authority.new(
      principal,
      capability(),
      Keyword.put_new(opts, :token_id, unique("mutguard-token"))
    )
  end

  @doc "A real command. Options: `:principal`, `:authority`, `:metadata`."
  @spec command(String.t(), keyword()) :: Command.t()
  def command(label, opts \\ []) do
    Command.new(capability(),
      command_id: "mutguard-" <> label,
      agent_id: "mutguard-agent",
      principal_id: Keyword.get(opts, :principal, principal()),
      authority: Keyword.get(opts, :authority),
      input: %{label: label},
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Runs `command` through the real CommandBus against the Ledger resource."
  @spec run(Command.t(), String.t(), keyword()) :: CommandBus.result()
  def run(%Command{} = command, label, store_opts),
    do: CommandBus.run(command, message(label), Ledger, store_opts: store_opts)

  @doc "Runs `fun.(store_opts)` against a fresh, real receipt store."
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

  @doc "Runs `fun.({Broker.InMemory, opts})` against a fresh, real authority broker."
  @spec with_broker(({module(), keyword()} -> result)) :: result when result: var
  def with_broker(fun) do
    name = Module.concat(__MODULE__, "Broker#{System.unique_integer([:positive])}")
    {:ok, pid} = Broker.InMemory.start_link(name: name)

    try do
      fun.({Broker.InMemory, [name: name]})
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end
end

defmodule AshA2A.Chicago.Fixtures.MutationHarness.Ledger do
  @moduledoc "Real Ash ETS resource: one `:change` skill (`:record_entry`, a create)."

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.MutationHarness.Domain,
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
    skill(:record_entry, :create)
  end
end

defmodule AshA2A.Chicago.Fixtures.MutationHarness.Domain do
  @moduledoc "Real Ash domain for the mutation-harness Ledger."

  use Ash.Domain, validate_config_inclusion?: false, extensions: [AshA2A]

  resources do
    resource(AshA2A.Chicago.Fixtures.MutationHarness.Ledger)
  end
end

defmodule AshA2A.Chicago.Fixtures.MutationHarness.GuardCourt do
  @moduledoc """
  Reference killer court `CHI-MUTGUARD`: the authority, expiry, revocation,
  prepared-receipt, consequence-classification and replay guards of the real
  BRCE path, each attacked through `AshA2A.Chicago.Context.stimulus/3`, plus
  positive controls proving the boundary discriminates (§100).

  Non-discoverable: it exists so `AshA2A.Chicago.Mutation.Catalog` has a
  real court whose falsifiers the §97 mutants must break, not to stand in for
  the Gate 7 / authority courts in a qualification run.

  Attempt predicates are outcome-neutral (the boundary decided at all), so a
  mutant that flips the decision yields a corroborated survival rather than
  an uncorroborated unknown.
  """

  use AshA2A.Chicago.Court, discoverable: false

  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.MutationHarness, as: H

  @id "CHI-MUTGUARD"
  @actuated {:any, [{:observed, "brce.actuate.start"}, {:observed, "dispatch.start"}]}
  @no_do "dispatch/actuation of Ledger.create, or the stimulus label visible to an independent Ash.read!"

  @impl true
  def id, do: @id
  @impl true
  def title, do: "Mutation-harness reference guards over the real BRCE path"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§22", "§64", "§67", "§68", "§69", "§71", "§97", "§100"]

  @impl true
  def falsifiers do
    [
      neg("001",
        invariant: "Authentication ⇏ Authority: no authority, no :change actuation",
        stimulus: "CommandBus.run/4 of Ledger.create with a real principal and no Authority",
        boundary: "AshA2A.CommandBus.admit/2",
        guard: "CommandBus.admit/2 :authority_required clause",
        failure_class: :authority_failure,
        attempt_predicate: {:observed, "brce.admission"},
        outcome_predicate: @actuated
      ),
      neg("002",
        invariant: "an authority bound to another principal does not authorize this principal",
        stimulus: "CommandBus.run/4 with an Authority whose subject is a different principal",
        boundary: "AshA2A.CommandBus.admit/2 via AshA2A.Authority.admits?/2",
        guard: "Authority.admits?/2 subject binding",
        failure_class: :authority_failure,
        attempt_predicate: {:observed, "brce.admission"},
        outcome_predicate: @actuated
      ),
      neg("003",
        invariant: "an expired authority does not authorize (§99 expired authority grant)",
        stimulus: "CommandBus.run/4 with an Authority whose expires_at is one hour in the past",
        boundary: "AshA2A.CommandBus.admit/2 via AshA2A.Authority.expired?/1",
        guard: "Authority.expired?/1 real-clock bound",
        failure_class: :authority_failure,
        attempt_predicate: {:observed, "brce.admission"},
        outcome_predicate: @actuated
      ),
      neg("004",
        invariant: "a revoked broker grant does not authorize (§99 revoked authority grant)",
        stimulus:
          "Grant.grant/3 then Broker.InMemory.revoke/2 then Grant.authorize/3 then CommandBus.run/4",
        boundary: "AshA2A.Authority.Grant + Broker.InMemory.granted?/3 -> CommandBus.admit/2",
        guard: "Broker.InMemory grant_status/2 revoked-set check",
        failure_class: :authority_failure,
        attempt_predicate: {:observed, "brce.admission"},
        outcome_predicate: @actuated
      ),
      neg("005",
        invariant: "no consequence-bearing DO without a prepared receipt anchor (§69)",
        stimulus: "authorized CommandBus.run/4 of Ledger.create",
        boundary: "AshA2A.CommandBus prepare_receipt_anchor/4 before actuate",
        forbidden_outcome: "brce.actuate.start not preceded by brce.prepare outcome=prepared",
        survival_evidence:
          "actuation observed with no prepared receipt anchor sharing its command before it",
        guard: "CommandBus.prepare_receipt_anchor/4",
        failure_class: :receipt_failure,
        attempt_predicate: {:observed, "brce.prepare"},
        outcome_predicate:
          {:any,
           [
             {:all,
              [
                {:observed, "brce.actuate.start"},
                {:not_observed, "brce.prepare", %{"outcome" => "prepared"}}
              ]},
             {:not, {:precedes, "brce.prepare", "brce.actuate.start", "command"}}
           ]}
      ),
      neg("006",
        invariant:
          "the caller does not classify its own consequence: metadata consequence=observe cannot downgrade a :change skill",
        stimulus:
          "CommandBus.run/4 with no Authority and Command.metadata %{consequence: :observe}",
        boundary: "AshA2A.CommandBus.inspect_target/2",
        forbidden_outcome: "consequence resolved as observe, or actuation without authority",
        survival_evidence:
          "brce.target consequence=observe, brce.actuate.start or dispatch.start; label visible to Ash.read!",
        guard: "CommandBus.inspect_target/2 DSL-derived consequence",
        failure_class: :authority_failure,
        attempt_predicate: {:observed, "brce.target"},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.actuate.start"},
             {:observed, "dispatch.start"},
             {:observed, "brce.target", %{"consequence" => "observe"}}
           ]}
      ),
      neg("007",
        invariant:
          "re-submitting a committed command replays its receipt and never re-actuates (§71)",
        stimulus: "the same authorized Command run twice through one receipt store",
        boundary: "AshA2A.CommandBus claim/replay branch",
        forbidden_outcome: "a second actuation / a second Ledger row for the command",
        survival_evidence: "brce.actuate.start observed twice; label row count 2 via Ash.read!",
        guard: "CommandBus.claim_receipt/3 {:replay, receipt} -> {:ok, receipt}",
        failure_class: :replay_failure,
        attempt_predicate: {:count, "brce.claim", :gte, 2},
        outcome_predicate: {:count, "brce.actuate.start", :gte, 2}
      ),
      pos("008",
        invariant:
          "a matching, unexpired authority actuates behind a prepared receipt and commits",
        stimulus: "CommandBus.run/4 with an Authority expiring in one hour",
        boundary: "AshA2A.CommandBus admission + receipt anchor + commit",
        attempt_evidence: "brce.admission",
        survival_evidence:
          "brce.prepare prepared precedes actuation; brce.commit committed; label visible to Ash.read!",
        attempt_predicate: {:observed, "brce.admission"},
        outcome_predicate:
          {:all,
           [
             {:observed, "brce.admission", %{"outcome" => "admitted"}},
             {:observed, "brce.prepare", %{"outcome" => "prepared"}},
             {:precedes, "brce.prepare", "brce.actuate.start", "command"},
             {:observed, "brce.commit", %{"outcome" => "committed"}}
           ]}
      ),
      pos("009",
        invariant: "a standing, unrevoked broker grant authorizes (revocation discriminates)",
        stimulus: "Grant.grant/3 then Grant.authorize/3 then CommandBus.run/4",
        boundary: "AshA2A.Authority.Grant + Broker.InMemory -> CommandBus",
        attempt_evidence: "brce.admission",
        survival_evidence: "brce.admission admitted; brce.commit committed; label visible",
        attempt_predicate: {:observed, "brce.admission"},
        outcome_predicate:
          {:all,
           [
             {:observed, "brce.admission", %{"outcome" => "admitted"}},
             {:observed, "brce.commit", %{"outcome" => "committed"}}
           ]}
      ),
      pos("010",
        invariant:
          "a re-submitted committed command is answered by replay (replay is not refused)",
        stimulus: "the same authorized Command run twice through one receipt store",
        boundary: "AshA2A.CommandBus claim/replay branch",
        attempt_evidence: "two brce.claim decisions",
        survival_evidence: "brce.claim outcome=replay; both submissions return {:ok, receipt}",
        attempt_predicate: {:count, "brce.claim", :gte, 2},
        outcome_predicate: {:observed, "brce.claim", %{"outcome" => "replay"}}
      )
    ]
  end

  defp neg(n, fields) do
    Falsifier.new!(
      [
        id: "#{@id}-#{n}",
        court_id: @id,
        kind: :negative,
        forbidden_outcome: @no_do,
        attempt_evidence: "the real boundary emitted its decision event for this stimulus",
        survival_evidence:
          "brce.actuate.start or dispatch.start attributed to the stimulus; " <> @no_do,
        rfc_sections: ["§22", "§97"]
      ]
      |> Keyword.merge(fields)
    )
  end

  defp pos(n, fields) do
    Falsifier.new!(
      [id: "#{@id}-#{n}", court_id: @id, kind: :positive_control, rfc_sections: ["§100"]]
      |> Keyword.merge(fields)
    )
  end

  @impl true
  def run(%Context{} = ctx) do
    f = Map.new(falsifiers(), &{&1.id, &1})
    at = fn n -> Map.fetch!(f, "#{@id}-#{n}") end

    H.with_store(fn store ->
      H.with_broker(fn broker ->
        [
          denied(ctx, at.("001"), store, fn label -> H.command(label) end),
          denied(ctx, at.("002"), store, fn label ->
            H.command(label, authority: H.authority(H.principal("mutguard-other-principal")))
          end),
          denied(ctx, at.("003"), store, fn label ->
            p = H.principal()
            expired = DateTime.add(DateTime.utc_now(), -3600, :second)
            H.command(label, principal: p, authority: H.authority(p, expires_at: expired))
          end),
          denied(ctx, at.("004"), store, fn label -> revoked_command(label, broker) end),
          unprepared(ctx, at.("005"), store),
          caller_consequence(ctx, at.("006"), store),
          replay_reactuation(ctx, at.("007"), store),
          authorized(ctx, at.("008"), store),
          standing_grant(ctx, at.("009"), store, broker),
          replay_control(ctx, at.("010"), store)
        ]
      end)
    end)
  end

  # --- negatives ---------------------------------------------------------------

  defp denied(ctx, f, store, build) do
    label = H.unique("mutguard-denied")
    reply = Context.stimulus(ctx, f, fn -> H.run(build.(label), label, store) end)

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "brce.admission"),
      forbidden_outcome_observed?: actuated?(ctx, f) or label in H.labels(),
      evidence: %{"label" => label, "reply" => reply_summary(reply)}
    )
  end

  defp revoked_command(label, {broker_module, broker_opts} = broker) do
    name = "mutguard-revoked-" <> label
    subject = H.principal(name)
    cap = H.capability()
    {:ok, issued} = Grant.grant(subject, cap, broker: broker)
    :ok = broker_module.revoke(issued, broker_opts)
    authority = Grant.authorize(name, cap, policy: :broker, broker: broker)
    H.command(label, principal: subject, authority: authority)
  end

  defp unprepared(ctx, f, store) do
    label = H.unique("mutguard-prepared")
    p = H.principal()

    reply =
      Context.stimulus(ctx, f, fn ->
        H.run(H.command(label, principal: p, authority: H.authority(p)), label, store)
      end)

    records = Context.observed(ctx, f)
    actuate = Enum.find(records, &(&1.activity == "brce.actuate.start"))

    prepared =
      Enum.find(
        records,
        &(&1.activity == "brce.prepare" and &1.attributes["outcome"] == "prepared")
      )

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "brce.prepare"),
      forbidden_outcome_observed?:
        actuate != nil and (prepared == nil or prepared.seq > actuate.seq),
      evidence: %{"label" => label, "reply" => reply_summary(reply)}
    )
  end

  defp caller_consequence(ctx, f, store) do
    label = H.unique("mutguard-consequence")

    reply =
      Context.stimulus(ctx, f, fn ->
        H.run(H.command(label, metadata: %{consequence: :observe}), label, store)
      end)

    downgraded =
      ctx
      |> Context.observed(f)
      |> Enum.any?(&(&1.activity == "brce.target" and &1.attributes["consequence"] == "observe"))

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "brce.target"),
      forbidden_outcome_observed?: downgraded or actuated?(ctx, f) or label in H.labels(),
      evidence: %{"label" => label, "reply" => reply_summary(reply)}
    )
  end

  defp replay_reactuation(ctx, f, store) do
    label = H.unique("mutguard-replay")
    p = H.principal()
    command = H.command(label, principal: p, authority: H.authority(p))

    replies =
      Context.stimulus(ctx, f, fn ->
        [H.run(command, label, store), H.run(command, label, store)]
      end)

    records = Context.observed(ctx, f)

    Result.negative(f,
      attempt_observed?: count(records, "brce.claim") >= 2,
      forbidden_outcome_observed?:
        count(records, "brce.actuate.start") >= 2 or Enum.count(H.labels(), &(&1 == label)) >= 2,
      evidence: %{"label" => label, "replies" => Enum.map(replies, &reply_summary/1)}
    )
  end

  # --- positive controls ---------------------------------------------------------

  defp authorized(ctx, f, store) do
    label = H.unique("mutguard-authorized")
    p = H.principal()
    expires = DateTime.add(DateTime.utc_now(), 3600, :second)

    reply =
      Context.stimulus(ctx, f, fn ->
        H.run(
          H.command(label, principal: p, authority: H.authority(p, expires_at: expires)),
          label,
          store
        )
      end)

    records = Context.observed(ctx, f)
    actuate = Enum.find(records, &(&1.activity == "brce.actuate.start"))

    prepared =
      Enum.find(
        records,
        &(&1.activity == "brce.prepare" and &1.attributes["outcome"] == "prepared")
      )

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "brce.admission"),
      expected_outcome_observed?:
        match?({:ok, _}, reply) and label in H.labels() and actuate != nil and prepared != nil and
          prepared.seq < actuate.seq and committed?(records),
      evidence: %{"label" => label, "reply" => reply_summary(reply)}
    )
  end

  defp standing_grant(ctx, f, store, broker) do
    label = H.unique("mutguard-granted")
    name = "mutguard-granted-" <> label
    subject = H.principal(name)
    cap = H.capability()

    reply =
      Context.stimulus(ctx, f, fn ->
        {:ok, _issued} = Grant.grant(subject, cap, broker: broker)
        authority = Grant.authorize(name, cap, policy: :broker, broker: broker)
        H.run(H.command(label, principal: subject, authority: authority), label, store)
      end)

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "brce.admission"),
      expected_outcome_observed?:
        match?({:ok, _}, reply) and label in H.labels() and committed?(Context.observed(ctx, f)),
      evidence: %{"label" => label, "reply" => reply_summary(reply)}
    )
  end

  defp replay_control(ctx, f, store) do
    label = H.unique("mutguard-replayed")
    p = H.principal()
    command = H.command(label, principal: p, authority: H.authority(p))

    replies =
      Context.stimulus(ctx, f, fn ->
        [H.run(command, label, store), H.run(command, label, store)]
      end)

    records = Context.observed(ctx, f)

    replayed =
      Enum.any?(records, &(&1.activity == "brce.claim" and &1.attributes["outcome"] == "replay"))

    Result.positive(f,
      attempt_observed?: count(records, "brce.claim") >= 2,
      expected_outcome_observed?: replayed and Enum.all?(replies, &match?({:ok, _}, &1)),
      evidence: %{"label" => label, "replies" => Enum.map(replies, &reply_summary/1)}
    )
  end

  # --- helpers ---------------------------------------------------------------------

  defp actuated?(ctx, f),
    do:
      Context.observed?(ctx, f, "brce.actuate.start") or
        Context.observed?(ctx, f, "dispatch.start")

  defp committed?(records),
    do:
      Enum.any?(
        records,
        &(&1.activity == "brce.commit" and &1.attributes["outcome"] == "committed")
      )

  defp count(records, activity), do: Enum.count(records, &(&1.activity == activity))

  defp reply_summary({:ok, receipt}), do: "ok:" <> inspect(Map.get(receipt, :status))
  defp reply_summary({:error, %{} = error}), do: "error:" <> inspect(Map.get(error, :code))
  defp reply_summary(other), do: inspect(other, limit: 5)
end
