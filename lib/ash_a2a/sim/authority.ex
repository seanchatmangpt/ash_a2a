# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Compiled only when Bandit is available, like the rest of the simulation
# server (see AshA2A.Sim.Server).
if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.Authority.RevokingBroker do
    @moduledoc """
    A real `AshA2A.Authority.Broker` for the simulation server that wraps
    `AshA2A.Authority.Broker.InMemory` and can be armed to withdraw a grant
    between admission and the pre-DO revalidation of `AshA2A.CommandBus`.

    While a principal is armed, the first `granted?/3` answer is the broker's
    real one (the dispatch path asks it to admit the caller) and every later
    answer is `false`, as if the grant had been revoked a moment after
    admission. `AshA2A.CommandBus` then refuses before DO and commits a refusal
    receipt: the one deterministic way to reach that receipt over the wire.
    Every other call, and every principal that is not armed, is answered by
    `InMemory` unchanged.

    `AshA2A.Sim.Authority` swaps it in as `:authority_broker` for the length of
    one probe and puts the configured broker back afterwards.
    """

    @behaviour AshA2A.Authority.Broker

    alias AshA2A.Authority.Broker.InMemory

    @key {__MODULE__, :armed}

    @doc "Arms `principal` (an `AshA2A.Identity` or its value): `granted?/3` answers truthfully `allow` times, then `false`."
    @spec arm(AshA2A.Identity.t() | String.t(), non_neg_integer()) :: :ok
    def arm(principal, allow \\ 1) do
      :persistent_term.put(@key, Map.put(armed(), value(principal), allow))
    end

    @doc "Stops withdrawing the grants of `principal`."
    @spec disarm(AshA2A.Identity.t() | String.t()) :: :ok
    def disarm(principal) do
      :persistent_term.put(@key, Map.delete(armed(), value(principal)))
    end

    @impl AshA2A.Authority.Broker
    def issue(subject, capability_id, opts), do: InMemory.issue(subject, capability_id, opts)

    @impl AshA2A.Authority.Broker
    def revoke(authority, opts), do: InMemory.revoke(authority, opts)

    @impl AshA2A.Authority.Broker
    def verify(authority, opts), do: InMemory.verify(authority, opts)

    @impl AshA2A.Authority.Broker
    def granted?(subject, capability_id, opts) do
      key = value(subject)

      case Map.fetch(armed(), key) do
        {:ok, remaining} when remaining > 0 ->
          :persistent_term.put(@key, Map.put(armed(), key, remaining - 1))
          InMemory.granted?(subject, capability_id, opts)

        {:ok, _spent} ->
          false

        :error ->
          InMemory.granted?(subject, capability_id, opts)
      end
    end

    @impl AshA2A.Authority.Broker
    def grant_expires_at(subject, capability_id, opts),
      do: InMemory.grant_expires_at(subject, capability_id, opts)

    @impl AshA2A.Authority.Broker
    def list_grants(subject, opts), do: InMemory.list_grants(subject, opts)

    @impl AshA2A.Authority.Broker
    def renew(subject, capability_id, expires_at, opts),
      do: InMemory.renew(subject, capability_id, expires_at, opts)

    defp armed, do: :persistent_term.get(@key, %{})
    defp value(%AshA2A.Identity{value: value}), do: value
    defp value(value) when is_binary(value), do: value
  end

  defmodule AshA2A.Sim.Authority do
    @moduledoc """
    The authority surface of the simulation server: what makes the mutating
    skills of `AshA2A.Sim.Note` admit or refuse, mirrored as surface items and
    proven over the real wire.

    `items/0` lists the `:authority` items of `AshA2A.Sim.Surface`; the prover
    asks `scenarios/1` for the probes of each. Every probe drives a real
    request through the JSON-RPC (`/a2a`), HTTP+JSON and gRPC bindings and then
    reads the Ash rows (or the `publish_note` effect list) to confirm what the
    gate let through. Two things cannot be reached over the wire and are driven
    through the real `AshA2A.CommandBus.run/4` instead, with the real data
    layer behind it: the `AshA2A.Authority.TwoPortGate` (the agent's dispatch
    path presents no lease) and the identity mismatch of a grant presented by a
    different caller.

    | Item | What it proves |
    |---|---|
    | `authority:grant` | a standing grant admits the caller on every binding, on the in-memory and the durable (EKV) broker |
    | `authority:revoke` | a revoked grant refuses the next call and writes nothing |
    | `authority:verify` | `Broker.verify/2` accepts a standing authority and refuses a revoked or expired one |
    | `authority:token_id_taken` | a second grant of a standing `(principal, capability)` is refused with `token_id_taken` |
    | `authority:expiry` | an expired grant is refused; a grant renewed into the past is refused and cannot be renewed back |
    | `authority:reissue_after_revoke` | a revoked grant can be granted again and admits again, while the revoked authority stays revoked |
    | `authority:principal_scope` | a grant for one principal does not admit another |
    | `authority:capability_scope` | a grant for one capability does not admit another |
    | `authority:presenter_binding` | a grant presented by a different caller is refused |
    | `authority:authority_required` | no grant ends `TASK_STATE_REJECTED` with `authority_required` and no row change |
    | `authority:kill_switch` | a tripped class is refused on all three bindings and works again after reset |
    | `authority:kill_switch_reset` | resetting a class needs the reset authority |
    | `authority:two_port_gate:scope` ... `:signature` | a lease failing exactly one of the gate's four checks is refused with that check's code |
    | `authority:receipt_executed` | a performed effect commits a receipt that verifies |
    | `authority:receipt_refused` | a refusal before DO commits a refusal receipt that verifies |
    | `authority:outcome:<class>:<outcome>` | each consequence class (`observe`, `change`, `external_do`, `unknown`) by outcome |

    The kill switch is host-wide in the library: `AshA2A.CommandBus` consults
    the one class named by `config :ash_a2a, :kill_switch_class`, for every
    consequence-bearing skill. The simulation names the class
    `#{inspect("ash_a2a_sim")}` (`kill_switch_class/0`); tripping it refuses
    `:change` and `:external_do` skills alike, and never an `:observe` skill.

    A refusal that happens before the command is claimed (`authority_required`,
    `kill_switch_tripped`, `consequence_unclassified`, a failed lease) commits no
    receipt. A refusal at the pre-DO gate (a grant withdrawn after admission)
    does, and `authority:receipt_refused` proves it.
    """

    alias AshA2A.{Authority, Command, CommandBus, Identity, KillSwitch, Receipt}
    alias AshA2A.Authority.{Grant, Lease, TwoPortGate}
    alias AshA2A.Authority.Broker.{Ekv, InMemory}
    alias AshA2A.Protocol.{Message, Part}
    alias AshA2A.Sim.{Auth, Note}
    alias AshA2A.Sim.Authority.RevokingBroker
    alias AshA2A.Sim.MCP.Wire
    alias AshA2A.Sim.Prover.Failure

    @bindings [:jsonrpc, :http_json, :grpc]
    @completed "TASK_STATE_COMPLETED"
    @rejected "TASK_STATE_REJECTED"
    @kill_class "ash_a2a_sim"
    @operator "sim-kill-switch-operator"
    @mutating ~w(create_note update_note delete_note publish_note)

    @items [
      {"grant", "AshA2A.Authority.Grant.grant/3"},
      {"revoke", "AshA2A.Authority.Grant.revoke/3"},
      {"verify", "AshA2A.Authority.Broker.verify/2"},
      {"token_id_taken", "AshA2A.Authority.Broker.issue/3"},
      {"expiry", "AshA2A.Authority.Grant.renew/3"},
      {"reissue_after_revoke", "AshA2A.Authority.Broker.issue/3"},
      {"principal_scope", "AshA2A.Authority.Grant.authorize/3"},
      {"capability_scope", "AshA2A.Authority.Grant.authorize/3"},
      {"presenter_binding", "AshA2A.Authority.admits?/2"},
      {"authority_required", "AshA2A.CommandBus.admit/2"},
      {"kill_switch", "AshA2A.KillSwitch.trip/3"},
      {"kill_switch_reset", "AshA2A.KillSwitch.reset/4"},
      {"two_port_gate:scope", "AshA2A.Authority.TwoPortGate"},
      {"two_port_gate:root", "AshA2A.Authority.TwoPortGate"},
      {"two_port_gate:clock", "AshA2A.Authority.TwoPortGate"},
      {"two_port_gate:signature", "AshA2A.Authority.TwoPortGate"},
      {"receipt_executed", "AshA2A.ReceiptStore"},
      {"receipt_refused", "AshA2A.ReceiptStore"},
      {"outcome:observe:admitted", "AshA2A.Skill consequence"},
      {"outcome:change:admitted", "AshA2A.Skill consequence"},
      {"outcome:change:refused", "AshA2A.Skill consequence"},
      {"outcome:external_do:admitted", "AshA2A.Skill consequence"},
      {"outcome:external_do:refused", "AshA2A.Skill consequence"},
      {"outcome:unknown:refused", "AshA2A.Skill consequence"}
    ]

    @doc "The `:authority` items of `AshA2A.Sim.Surface`."
    @spec items() :: [%{id: String.t(), kind: :authority, name: String.t(), source: String.t()}]
    def items do
      for {name, source} <- @items,
          do: %{id: "authority:" <> name, kind: :authority, name: name, source: source}
    end

    @doc "The kill switch class the simulation halts: every consequence-bearing skill belongs to it."
    @spec kill_switch_class() :: String.t()
    def kill_switch_class, do: @kill_class

    # == kill switch ============================================================

    @doc """
    Trips `class` and points the host's `:kill_switch_class` at it, so
    `AshA2A.CommandBus` refuses every consequence-bearing skill until
    `reset_kill_switch/1`. Answers `:ok`.
    """
    @spec trip_kill_switch(String.t(), String.t()) :: :ok
    def trip_kill_switch(class \\ @kill_class, reason \\ "sim_trip_kill_switch") do
      ensure_kill_switch!()
      remember_class()
      Application.put_env(:ash_a2a, :kill_switch_class, class)
      KillSwitch.trip(class, reason)
    end

    @doc """
    Resets `class` with a reset authority minted for the simulation operator
    (`AshA2A.KillSwitch.reset/4` requires one), then puts the host's previous
    `:kill_switch_class` back. Answers `:ok` or `{:error, reason}`.
    """
    @spec reset_kill_switch(String.t()) :: :ok | {:error, term()}
    def reset_kill_switch(class \\ @kill_class) do
      ensure_kill_switch!()
      operator = Identity.principal(@operator)
      authority = Authority.new(operator, KillSwitch.reset_capability_id(class))

      with :ok <- KillSwitch.reset(class, authority, operator) do
        restore_class()
        :ok
      end
    end

    @doc "Whether `class` is tripped: `{true, reason}` or `false`."
    @spec kill_switch_state(String.t()) :: {true, term()} | false
    def kill_switch_state(class \\ @kill_class) do
      ensure_kill_switch!()
      KillSwitch.tripped?(class)
    end

    defp ensure_kill_switch! do
      if is_nil(Process.whereis(KillSwitch)) do
        {:ok, pid} = KillSwitch.start_link([])
        Process.unlink(pid)
      end

      :ok
    end

    @previous_class {__MODULE__, :previous_kill_class}

    defp remember_class do
      if is_nil(:persistent_term.get(@previous_class, nil)),
        do:
          :persistent_term.put(
            @previous_class,
            {:previous, Application.fetch_env(:ash_a2a, :kill_switch_class)}
          )
    end

    defp restore_class do
      case :persistent_term.get(@previous_class, nil) do
        {:previous, {:ok, value}} -> Application.put_env(:ash_a2a, :kill_switch_class, value)
        {:previous, :error} -> Application.delete_env(:ash_a2a, :kill_switch_class)
        nil -> :ok
      end

      :persistent_term.erase(@previous_class)
      :ok
    end

    # == receipts ===============================================================

    @doc """
    The receipt `AshA2A.CommandBus` committed for the message with `message_id`
    (the command id of a wire call is its message id): `{:ok, receipt}` or
    `:error`.
    """
    @spec fetch_receipt(String.t()) :: {:ok, Receipt.t()} | :error
    def fetch_receipt(message_id) do
      id = Identity.command(message_id)

      case CommandBus.default_store() do
        AshA2A.ReceiptStore.Memory -> AshA2A.ReceiptStore.Memory.fetch(id, [])
        AshA2A.ReceiptStore.Ekv -> AshA2A.ReceiptStore.Ekv.fetch(id, [])
        _other -> :error
      end
    end

    @doc """
    A receipt as plain data, with the verdict of `AshA2A.Receipt.Binding.verify/2`
    under `binding_verified` (and `binding_code` when it refuses).
    """
    @spec describe_receipt(Receipt.t()) :: map()
    def describe_receipt(%Receipt{} = receipt) do
      {verified, code} =
        case Receipt.Binding.check(receipt) do
          {:ok, _report} -> {true, nil}
          {:error, %{code: code}} -> {false, Atom.to_string(code)}
        end

      %{
        "receipt_id" => Identity.external(receipt.receipt_id),
        "command_id" => Identity.external(receipt.command_id),
        "capability_id" => receipt.capability_id,
        "principal_id" => Identity.external(receipt.principal_id),
        "consequence" => to_string(receipt.consequence),
        "status" => to_string(receipt.status),
        "terminal_status" => receipt.terminal_status && to_string(receipt.terminal_status),
        "standing" => to_string(receipt.standing),
        "binding_verified" => verified,
        "binding_code" => code,
        "binding_links" => binding_links(receipt)
      }
    end

    defp binding_links(%Receipt{binding: %{links: links}}), do: length(links)
    defp binding_links(_receipt), do: 0

    # == probes =================================================================

    @doc """
    The probes of one `:authority` item as `[{label, fun}]`; `fun` takes the
    `AshA2A.Sim.Server.info/0` map and answers a detail string, or raises
    `AshA2A.Sim.Prover.Failure`.
    """
    @spec scenarios(String.t()) :: [{String.t(), (map() -> String.t())}]
    def scenarios("grant") do
      [
        {"a granted principal is admitted on every binding and the row changes",
         fn info ->
           with_agent(fn agent ->
             {:ok, authority} = grant!(agent, "create_note")
             capability = cap("create_note")

             check!(
               authority.subject == agent.principal and authority.capability_id == capability,
               "the authority is not bound to the principal and capability"
             )

             check!(
               Grant.granted?(agent.principal, capability),
               "granted?/3 is false after grant"
             )

             for binding <- @bindings do
               title = "authority-grant-#{binding}-" <> unique()
               result = send_skill(info, binding, agent.token, "create_note", %{"title" => title})
               expect_state!(result, @completed)
               check!(note_by_title(title) != nil, "no row titled #{title} over #{binding}")
             end

             "granted create_note admitted over JSON-RPC, HTTP+JSON and gRPC; three rows exist"
           end)
         end},
        {"the durable (EKV) broker grants and admits over the wire",
         fn info ->
           with_ekv(fn broker ->
             with_broker(broker.ref, fn ->
               with_agent(broker, fn agent ->
                 {:ok, _authority} = grant!(agent, "create_note", broker: broker.ref)
                 title = "authority-ekv-grant-" <> unique()

                 result =
                   send_skill(info, :http_json, agent.token, "create_note", %{"title" => title})

                 expect_state!(result, @completed)
                 check!(note_by_title(title) != nil, "no row titled #{title}")
                 "EKV broker: grant admitted create_note over HTTP+JSON and the row exists"
               end)
             end)
           end)
         end}
      ]
    end

    def scenarios("revoke") do
      [
        {"a revoked grant is refused on every binding and writes nothing",
         fn info ->
           with_agent(fn agent ->
             {:ok, _authority} = grant!(agent, "create_note")

             admitted =
               send_skill(info, :jsonrpc, agent.token, "create_note", %{
                 "title" => "authority-revoke-ok-" <> unique()
               })

             expect_state!(admitted, @completed)

             :ok = Grant.revoke(agent.principal, cap("create_note"))

             check!(
               not Grant.granted?(agent.principal, cap("create_note")),
               "still granted after revoke"
             )

             before = note_count()

             for binding <- @bindings do
               title = "authority-revoked-#{binding}-" <> unique()
               result = send_skill(info, binding, agent.token, "create_note", %{"title" => title})
               expect_refused!(result, "authority_required")

               check!(
                 note_by_title(title) == nil,
                 "the revoked caller wrote a row over #{binding}"
               )
             end

             check!(note_count() == before, "row count changed from #{before} to #{note_count()}")

             "revoke refused authority_required over all three bindings; row count stays #{before}"
           end)
         end},
        {"the durable (EKV) broker refuses a revoked grant over the wire",
         fn info ->
           with_ekv(fn broker ->
             with_broker(broker.ref, fn ->
               with_agent(broker, fn agent ->
                 {:ok, _authority} = grant!(agent, "create_note", broker: broker.ref)
                 :ok = Grant.revoke(agent.principal, cap("create_note"), broker: broker.ref)
                 title = "authority-ekv-revoked-" <> unique()
                 result = send_skill(info, :grpc, agent.token, "create_note", %{"title" => title})
                 expect_refused!(result, "authority_required")
                 check!(note_by_title(title) == nil, "the revoked caller wrote a row")
                 "EKV broker: revoke refused authority_required over gRPC; no row"
               end)
             end)
           end)
         end}
      ]
    end

    def scenarios("verify") do
      for broker_name <- [:memory, :ekv] do
        {"#{label(broker_name)}: verify accepts a standing authority, refuses a revoked and an expired one",
         fn _info ->
           with_broker_under_test(broker_name, fn broker ->
             principal = fresh_principal()
             capability = cap("create_note")
             {:ok, authority} = Grant.grant(principal, capability, broker: broker.ref)

             check!(
               match?({:ok, _}, broker.verify.(authority)),
               "a standing authority did not verify"
             )

             :ok = Grant.revoke(principal, capability, broker: broker.ref)
             revoked = broker.verify.(authority)

             check!(
               match?({:error, %{reason: :revoked}}, revoked),
               "revoked authority: #{clip(inspect(revoked))}"
             )

             other = fresh_principal()

             {:ok, expired} =
               Grant.grant(other, capability, broker: broker.ref, expires_at: past())

             verdict = broker.verify.(expired)

             check!(
               match?({:error, %{reason: :expired}}, verdict),
               "expired authority: #{clip(inspect(verdict))}"
             )

             "#{broker.label}: standing verified; revoked refused (revoked); expired refused (expired)"
           end)
         end}
      end
    end

    def scenarios("token_id_taken") do
      for broker_name <- [:memory, :ekv] do
        {"#{label(broker_name)}: a second grant of a standing (principal, capability) is refused token_id_taken",
         fn _info ->
           with_broker_under_test(broker_name, fn broker ->
             principal = fresh_principal()
             capability = cap("create_note")
             {:ok, _first} = Grant.grant(principal, capability, broker: broker.ref)

             second = Grant.grant(principal, capability, broker: broker.ref)

             check!(
               match?({:error, %{reason: :token_id_taken}}, second),
               "second grant: #{clip(inspect(second))}"
             )

             check!(
               Grant.granted?(principal, capability, broker: broker.ref),
               "the standing grant was lost"
             )

             check!(
               match?({:ok, _}, Grant.grant(principal, cap("update_note"), broker: broker.ref)),
               "another capability was refused"
             )

             check!(
               match?({:ok, _}, Grant.grant(fresh_principal(), capability, broker: broker.ref)),
               "another principal was refused"
             )

             "#{broker.label}: second grant refused token_id_taken; other capability and principal granted"
           end)
         end}
      end
    end

    def scenarios("expiry") do
      [
        {"a grant whose expires_at has passed is refused on every binding",
         fn info ->
           with_agent(fn agent ->
             {:ok, _authority} = grant!(agent, "create_note", expires_at: past())

             check!(
               not Grant.granted?(agent.principal, cap("create_note")),
               "an expired grant stands"
             )

             for binding <- @bindings do
               title = "authority-expired-#{binding}-" <> unique()
               result = send_skill(info, binding, agent.token, "create_note", %{"title" => title})
               expect_refused!(result, "authority_required")

               check!(
                 note_by_title(title) == nil,
                 "the expired caller wrote a row over #{binding}"
               )
             end

             "expired grant refused authority_required over all three bindings; no rows"
           end)
         end},
        {"a grant renewed into the past is refused and cannot be renewed back",
         fn info ->
           with_agent(fn agent ->
             capability = cap("create_note")
             later = DateTime.add(DateTime.utc_now(), 3600, :second)
             {:ok, _authority} = grant!(agent, "create_note", expires_at: later)

             ok =
               send_skill(info, :http_json, agent.token, "create_note", %{
                 "title" => "authority-bounded-" <> unique()
               })

             expect_state!(ok, @completed)

             :ok = Grant.renew(agent.principal, capability, expires_at: past())
             title = "authority-renewed-past-" <> unique()
             refused = send_skill(info, :jsonrpc, agent.token, "create_note", %{"title" => title})
             expect_refused!(refused, "authority_required")

             back = Grant.renew(agent.principal, capability, expires_at: later)

             check!(
               match?({:error, %{reason: :grant_not_standing}}, back),
               "renew of an expired grant: #{clip(inspect(back))}"
             )

             again = send_skill(info, :grpc, agent.token, "create_note", %{"title" => title})
             expect_refused!(again, "authority_required")
             check!(note_by_title(title) == nil, "the expired caller wrote a row")

             "time-bounded grant admitted; renewed into the past refused on two bindings; renew back refused grant_not_standing"
           end)
         end}
      ]
    end

    def scenarios("reissue_after_revoke") do
      [
        {"over the wire: revoke then grant again admits again",
         fn info ->
           with_agent(fn agent ->
             capability = cap("create_note")
             {:ok, first} = grant!(agent, "create_note")

             one =
               send_skill(info, :jsonrpc, agent.token, "create_note", %{
                 "title" => "authority-reissue-1-" <> unique()
               })

             expect_state!(one, @completed)

             :ok = Grant.revoke(agent.principal, capability)
             title = "authority-reissue-2-" <> unique()

             refused =
               send_skill(info, :http_json, agent.token, "create_note", %{"title" => title})

             expect_refused!(refused, "authority_required")
             check!(note_by_title(title) == nil, "the revoked caller wrote a row")

             {:ok, second} = grant!(agent, "create_note")

             check!(
               DateTime.compare(second.issued_at, first.issued_at) == :gt,
               "the new authority is not newer than the revoked one"
             )

             for binding <- @bindings do
               t = "authority-reissue-#{binding}-" <> unique()
               result = send_skill(info, binding, agent.token, "create_note", %{"title" => t})
               expect_state!(result, @completed)
               check!(note_by_title(t) != nil, "no row titled #{t}")
             end

             revoked = InMemory.verify(first, [])

             check!(
               match?({:error, %{reason: :revoked}}, revoked),
               "the revoked authority verifies again: #{clip(inspect(revoked))}"
             )

             check!(
               match?({:ok, _}, InMemory.verify(second, [])),
               "the re-issued authority does not verify"
             )

             "re-granted after revoke: admitted on all bindings; the revoked authority still verifies as revoked"
           end)
         end},
        {"EKV broker: a revoked grant can be granted again, the revoked authority stays revoked",
         fn _info ->
           with_broker_under_test(:ekv, fn broker ->
             principal = fresh_principal()
             capability = cap("create_note")
             {:ok, first} = Grant.grant(principal, capability, broker: broker.ref)
             :ok = Grant.revoke(principal, capability, broker: broker.ref)

             check!(
               not Grant.granted?(principal, capability, broker: broker.ref),
               "granted after revoke"
             )

             {:ok, second} = Grant.grant(principal, capability, broker: broker.ref)

             check!(
               Grant.granted?(principal, capability, broker: broker.ref),
               "not granted after re-grant"
             )

             check!(
               match?({:error, %{reason: :revoked}}, broker.verify.(first)),
               "the revoked authority verifies again"
             )

             check!(
               match?({:ok, _}, broker.verify.(second)),
               "the re-issued authority does not verify"
             )

             "EKV: re-grant after revoke stands; first authority refused (revoked), second verifies"
           end)
         end}
      ]
    end

    def scenarios("principal_scope") do
      [
        {"a grant for one principal admits it and no other on every binding",
         fn info ->
           with_agent(fn holder ->
             with_agent(fn other ->
               {:ok, _authority} = grant!(holder, "create_note")

               for binding <- @bindings do
                 title = "authority-principal-#{binding}-" <> unique()

                 refused =
                   send_skill(info, binding, other.token, "create_note", %{"title" => title})

                 expect_refused!(refused, "authority_required")

                 check!(
                   note_by_title(title) == nil,
                   "the ungranted principal wrote a row over #{binding}"
                 )

                 admitted =
                   send_skill(info, binding, holder.token, "create_note", %{"title" => title})

                 expect_state!(admitted, @completed)

                 check!(
                   note_by_title(title) != nil,
                   "the granted principal's row is missing over #{binding}"
                 )
               end

               "the holder was admitted and the other principal refused on all three bindings"
             end)
           end)
         end}
      ]
    end

    def scenarios("capability_scope") do
      [
        {"a grant for one capability admits it and no other",
         fn info ->
           with_agent(fn agent ->
             {:ok, _authority} = grant!(agent, "publish_note")
             title = "authority-capability-" <> unique()

             refused = send_skill(info, :jsonrpc, agent.token, "create_note", %{"title" => title})
             expect_refused!(refused, "authority_required")
             check!(note_by_title(title) == nil, "a publish grant admitted create_note")

             update =
               send_skill(info, :http_json, agent.token, "update_note", %{
                 "id" => Ash.UUID.generate(),
                 "title" => title
               })

             expect_refused!(update, "authority_required")

             admitted = send_skill(info, :grpc, agent.token, "publish_note", %{"title" => title})
             expect_state!(admitted, @completed)
             check!(title in Note.publications(), "the granted publish has no effect")

             "a publish_note grant admitted publish_note and refused create_note and update_note"
           end)
         end}
      ]
    end

    def scenarios("presenter_binding") do
      [
        {"an authority presented as another principal does not verify (both brokers)",
         fn _info ->
           for broker_name <- [:memory, :ekv] do
             with_broker_under_test(broker_name, fn broker ->
               holder = fresh_principal()
               {:ok, authority} = Grant.grant(holder, cap("create_note"), broker: broker.ref)
               presented = %{authority | subject: fresh_principal()}
               verdict = broker.verify.(presented)

               check!(
                 match?({:error, %{reason: :token_binding_mismatch}}, verdict),
                 "#{broker.label}: an authority presented as another principal verified: #{clip(inspect(verdict))}"
               )

               :ok
             end)
           end

           "InMemory and EKV refuse a rewritten subject with token_binding_mismatch"
         end},
        {"the bus refuses one caller's grant presented on another caller's command",
         fn _info ->
           with_agent(fn holder ->
             with_agent(fn presenter ->
               {:ok, _authority} = grant!(holder, "create_note")
               title = "authority-presented-" <> unique()
               borrowed = Grant.authorize(Auth.identity(holder.token), cap("create_note"))
               check!(match?(%Authority{}, borrowed), "the holder has no authority to borrow")

               command =
                 Command.new(cap("create_note"),
                   command_id: "sim-borrowed-" <> unique(),
                   agent_id: "AshA2A.Sim.Note",
                   principal_id: presenter.principal,
                   authority: borrowed,
                   input: %{"title" => title}
                 )

               result = run_bus(command, presenter, title)

               check!(
                 match?({:error, %{code: :authority_mismatch}}, result),
                 "bus answered #{clip(inspect(result))}"
               )

               check!(note_by_title(title) == nil, "the borrowed grant wrote a row")

               "CommandBus refused authority_mismatch for a grant held by another principal; no row"
             end)
           end)
         end}
      ]
    end

    def scenarios("authority_required") do
      [
        {"a caller with no grant ends TASK_STATE_REJECTED on every binding with no change",
         fn info ->
           agent = fresh_agent()
           before = note_count()
           published = length(Note.publications())

           for binding <- @bindings, skill <- ["create_note", "publish_note"] do
             title = "authority-none-#{binding}-" <> unique()
             result = send_skill(info, binding, agent.token, skill, %{"title" => title})
             expect_refused!(result, "authority_required")

             check!(
               note_by_title(title) == nil and title not in Note.publications(),
               "#{skill} had an effect over #{binding}"
             )
           end

           check!(note_count() == before, "row count changed from #{before} to #{note_count()}")
           check!(length(Note.publications()) == published, "a publication was recorded")

           "create_note and publish_note refused authority_required on three bindings; rows and publications unchanged"
         end}
      ]
    end

    def scenarios("kill_switch") do
      [
        {"a tripped class refuses change and external_do on every binding; reset admits again",
         fn info ->
           with_kill_switch(fn ->
             with_agent(fn agent ->
               {:ok, _a} = grant!(agent, "create_note")
               {:ok, _b} = grant!(agent, "publish_note")
               before = note_count()

               :ok = trip_kill_switch(@kill_class, "authority probe")
               check!(match?({true, _}, kill_switch_state()), "the class is not tripped")

               for binding <- @bindings do
                 title = "authority-killed-#{binding}-" <> unique()

                 refused =
                   send_skill(info, binding, agent.token, "create_note", %{"title" => title})

                 expect_refused!(refused, "kill_switch_tripped")

                 check!(
                   note_by_title(title) == nil,
                   "a row was written while tripped over #{binding}"
                 )

                 external =
                   send_skill(info, binding, agent.token, "publish_note", %{"title" => title})

                 expect_refused!(external, "kill_switch_tripped")

                 check!(
                   title not in Note.publications(),
                   "an effect happened while tripped over #{binding}"
                 )
               end

               check!(note_count() == before, "row count changed while tripped")

               observed = send_skill(info, :http_json, agent.token, "count_notes", %{})
               expect_state!(observed, @completed)

               :ok = reset_kill_switch()
               check!(kill_switch_state() == false, "the class is still tripped after reset")

               for binding <- @bindings do
                 title = "authority-reset-#{binding}-" <> unique()

                 admitted =
                   send_skill(info, binding, agent.token, "create_note", %{"title" => title})

                 expect_state!(admitted, @completed)
                 check!(note_by_title(title) != nil, "no row after reset over #{binding}")
               end

               "tripped: create_note and publish_note refused kill_switch_tripped on 3 bindings, count_notes ran; reset: admitted on 3 bindings"
             end)
           end)
         end}
      ]
    end

    def scenarios("kill_switch_reset") do
      [
        {"resetting a class without the reset authority is refused and the class stays tripped",
         fn _info ->
           with_kill_switch(fn ->
             :ok = trip_kill_switch(@kill_class, "authority probe")
             operator = Identity.principal(@operator)
             wrong = Authority.new(operator, KillSwitch.reset_capability_id("some_other_class"))
             stranger = Identity.principal("sim-stranger")
             right = Authority.new(operator, KillSwitch.reset_capability_id(@kill_class))

             for {label, authority, who} <- [
                   {"no authority", nil, operator},
                   {"another class's authority", wrong, operator},
                   {"the authority of another principal", right, stranger}
                 ] do
               result = KillSwitch.reset(@kill_class, authority, who)

               check!(
                 match?({:error, :authority_mismatch}, result),
                 "#{label}: #{clip(inspect(result))}"
               )

               check!(match?({true, _}, kill_switch_state()), "#{label} cleared the trip")
             end

             :ok = reset_kill_switch()
             check!(kill_switch_state() == false, "the right authority did not reset")

             "three wrong resets refused authority_mismatch and left the trip; the reset authority cleared it"
           end)
         end}
      ]
    end

    def scenarios("two_port_gate:" <> check) do
      {conjunct, bit, code} =
        Enum.find(TwoPortGate.conjuncts(), fn {name, _bit, _code} ->
          Atom.to_string(name) == check
        end)

      [
        {"a lease failing only the #{check} check is refused with its code; a valid lease admits",
         fn _info ->
           with_agent(fn agent ->
             {:ok, _authority} = grant!(agent, "create_note")

             control = "authority-gate-ok-" <> unique()
             {lease, key} = gate_lease(agent, control, :valid)
             admitted = run_gate(agent, control, lease, key)

             check!(
               match?({:ok, _}, admitted),
               "the valid lease was refused: #{clip(inspect(admitted))}"
             )

             check!(note_by_title(control) != nil, "the valid lease wrote no row")

             title = "authority-gate-#{check}-" <> unique()
             {lease, key} = gate_lease(agent, title, conjunct)
             refused = run_gate(agent, title, lease, key)

             case refused do
               {:error, %{code: :refused_lease, mask: ^bit, codes: [^code]}} ->
                 :ok

               other ->
                 fail!("expected refused_lease mask #{bit} #{code}, got #{clip(inspect(other))}")
             end

             check!(note_by_title(title) == nil, "the refused lease wrote a row")

             "valid lease admitted; #{check} tamper refused refused_lease mask 0x#{Integer.to_string(bit, 16)} (#{code}); no row"
           end)
         end}
      ]
    end

    def scenarios("receipt_executed") do
      [
        {"a performed effect commits a receipt that verifies, on every binding",
         fn info ->
           with_agent(fn agent ->
             {:ok, _authority} = grant!(agent, "create_note")

             for binding <- @bindings do
               message_id = "msg-receipt-#{binding}-" <> unique()
               title = "authority-receipt-#{binding}-" <> unique()

               result =
                 send_skill(info, binding, agent.token, "create_note", %{"title" => title},
                   message_id: message_id
                 )

               expect_state!(result, @completed)

               receipt = receipt!(message_id)
               described = describe_receipt(receipt)

               check!(
                 receipt.capability_id == cap("create_note") and receipt.consequence == :change and
                   receipt.terminal_status == :executed,
                 "receipt over #{binding}: #{clip(inspect(Map.take(described, ["capability_id", "consequence", "terminal_status"])))}"
               )

               check!(
                 described["binding_verified"],
                 "receipt over #{binding} does not verify: #{described["binding_code"]}"
               )
             end

             "three performed creates each committed an executed receipt whose binding verifies"
           end)
         end}
      ]
    end

    def scenarios("receipt_refused") do
      [
        {"a grant withdrawn after admission is refused before DO and commits a verifying refusal receipt",
         fn info ->
           with_broker(
             {RevokingBroker, []},
             fn ->
               with_agent(fn agent ->
                 {:ok, _authority} = grant!(agent, "create_note")
                 RevokingBroker.arm(agent.principal, 1)

                 try do
                   message_id = "msg-receipt-refused-" <> unique()
                   title = "authority-receipt-refused-" <> unique()

                   result =
                     send_skill(info, :http_json, agent.token, "create_note", %{"title" => title},
                       message_id: message_id
                     )

                   check!(
                     result.state == @rejected and result.text =~ "authority_revoked",
                     "wire answer #{result.state}: #{clip(result.text)}"
                   )

                   check!(note_by_title(title) == nil, "the refused request wrote a row")
                   receipt = receipt!(message_id)
                   described = describe_receipt(receipt)

                   check!(
                     match?({:error, %{code: :authority_revoked}}, receipt.reply),
                     "the receipt does not record the refusal: #{clip(inspect(receipt.reply))}"
                   )

                   check!(
                     described["binding_verified"],
                     "the refusal receipt does not verify: #{described["binding_code"]}"
                   )

                   "authority_revoked before DO committed a refusal receipt (terminal_status #{receipt.terminal_status}, binding verified); no row"
                 after
                   RevokingBroker.disarm(agent.principal)
                 end
               end)
             end
           )
         end}
      ]
    end

    def scenarios("outcome:observe:admitted") do
      [
        {"an observe skill runs for a caller with no grant on every binding and commits no receipt",
         fn info ->
           agent = fresh_agent()

           for binding <- @bindings do
             message_id = "msg-observe-#{binding}-" <> unique()

             result =
               send_skill(info, binding, agent.token, "count_notes", %{}, message_id: message_id)

             expect_state!(result, @completed)

             check!(
               fetch_receipt(message_id) == :error,
               "an observe skill committed a receipt over #{binding}"
             )
           end

           "count_notes completed on three bindings for a caller with no grant; no receipt (observe skips the bus)"
         end}
      ]
    end

    def scenarios("outcome:" <> rest) when rest in ["change:admitted", "external_do:admitted"] do
      [class, _outcome] = String.split(rest, ":")

      {skill, class_atom} =
        if class == "change", do: {"create_note", :change}, else: {"publish_note", :external_do}

      [
        {"#{skill} (#{class}) with a grant is admitted on every binding; the effect and a verifying receipt exist",
         fn info ->
           with_agent(fn agent ->
             {:ok, _authority} = grant!(agent, skill)

             for binding <- @bindings do
               message_id = "msg-#{class}-#{binding}-" <> unique()
               title = "authority-#{class}-#{binding}-" <> unique()

               result =
                 send_skill(info, binding, agent.token, skill, %{"title" => title},
                   message_id: message_id
                 )

               expect_state!(result, @completed)
               check!(effect?(skill, title), "no #{class} effect for #{title} over #{binding}")

               receipt = receipt!(message_id)

               check!(
                 receipt.consequence == class_atom and receipt.terminal_status == :executed,
                 "receipt over #{binding} says #{receipt.consequence}/#{receipt.terminal_status}"
               )

               check!(
                 describe_receipt(receipt)["binding_verified"],
                 "receipt over #{binding} does not verify"
               )
             end

             "#{skill} admitted over three bindings; each effect exists and each receipt (#{class}, executed) verifies"
           end)
         end}
      ]
    end

    def scenarios("outcome:" <> rest) when rest in ["change:refused", "external_do:refused"] do
      [class, _outcome] = String.split(rest, ":")
      skill = if class == "change", do: "create_note", else: "publish_note"

      [
        {"#{skill} (#{class}) without a grant is REJECTED with authority_required on every binding and has no effect",
         fn info ->
           agent = fresh_agent()
           before = note_count()

           for binding <- @bindings do
             title = "authority-#{class}-refused-#{binding}-" <> unique()
             result = send_skill(info, binding, agent.token, skill, %{"title" => title})
             expect_refused!(result, "authority_required")

             check!(
               not effect?(skill, title),
               "the refused #{skill} had an effect over #{binding}"
             )
           end

           check!(note_count() == before, "row count changed")
           "#{skill} REJECTED authority_required on three bindings; no #{class} effect"
         end}
      ]
    end

    def scenarios("outcome:unknown:refused") do
      [
        {"an unclassified skill is REJECTED on every binding even with a standing grant",
         fn info ->
           with_agent(fn agent ->
             capability = cap("unclassified_note")
             principal = agent.principal
             {:ok, _authority} = Grant.grant(principal, capability)

             try do
               for binding <- @bindings do
                 result = send_skill(info, binding, agent.token, "unclassified_note", %{})
                 expect_refused!(result, "consequence_unclassified")

                 check!(
                   result.task["artifacts"] in [nil, []],
                   "the unclassified action produced an artifact over #{binding}"
                 )
               end

               "unclassified_note REJECTED consequence_unclassified on three bindings despite a grant"
             after
               Grant.revoke(principal, capability)
             end
           end)
         end}
      ]
    end

    def scenarios(_name), do: []

    # == wire ===================================================================

    @doc """
    Sends `skill` as one `message/send` over `binding` (`:jsonrpc` on the
    `/a2a` mount, `:http_json`, `:grpc`) with the bearer `token`, and answers
    `%{task, state, text, message_id, binding}`. Raises `Failure` when no task
    came back.
    """
    @spec send_skill(map(), atom(), String.t(), String.t(), map(), keyword()) :: map()
    def send_skill(info, binding, token, skill, data, opts \\ []) do
      message_id = Keyword.get(opts, :message_id) || "msg-sim-authority-" <> unique()

      params = %{
        "message" => %{
          "messageId" => message_id,
          "role" => "ROLE_USER",
          "parts" => [%{"data" => data}],
          "metadata" => %{"skill" => skill}
        }
      }

      task = wire_task(binding, info, token, params)

      %{
        task: task,
        state: get_in(task, ["status", "state"]),
        text: Jason.encode!(task),
        message_id: message_id,
        binding: binding
      }
    end

    defp wire_task(:jsonrpc, info, token, params) do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "message/send", "params" => params}

      case http(info.a2a_url, token, body) do
        %{"result" => %{"task" => task}} -> task
        %{"result" => %{"status" => _} = task} -> task
        other -> fail!("JSON-RPC send answered #{clip(inspect(other))}")
      end
    end

    defp wire_task(:http_json, info, token, params) do
      case http(info.rest_url <> "/message:send", token, params) do
        %{"task" => task} -> task
        %{"status" => _} = task -> task
        other -> fail!("HTTP+JSON send answered #{clip(inspect(other))}")
      end
    end

    defp wire_task(:grpc, info, token, params) do
      metadata = %{"a2a-version" => "1.1", "authorization" => "Bearer " <> token}

      case Wire.grpc(info.grpc_target, "SendMessage", params, metadata) do
        {:ok, %{"reply" => %{"task" => task}}} -> task
        {:ok, other} -> fail!("gRPC send answered #{clip(inspect(other))}")
        {:error, reason} -> fail!("gRPC send failed: #{clip(reason)}")
      end
    end

    defp http(url, token, body) do
      headers = [
        {"a2a-version", "1.1"},
        {"authorization", "Bearer " <> token},
        {"content-type", "application/json"}
      ]

      case Wire.http(:post, url, headers, Jason.encode!(body)) do
        {:ok, %{"raw" => raw, "status" => status}} ->
          case Jason.decode(raw) do
            {:ok, decoded} -> decoded
            {:error, _} -> fail!("HTTP #{status} from #{url}: #{clip(raw)}")
          end

        {:error, reason} ->
          fail!(clip(reason))
      end
    end

    # == the real bus (leases, borrowed grants) =================================

    defp run_bus(command, agent, title, extra \\ []) do
      message = Message.new_user([Part.Data.new(%{"title" => title})])

      CommandBus.run(
        command,
        message,
        Note,
        [history: [], auth_identity: Auth.identity(agent.token)] ++ extra
      )
    end

    defp gate_command(agent, title) do
      Command.new(cap("create_note"),
        command_id: "sim-gate-" <> unique(),
        agent_id: "AshA2A.Sim.Note",
        principal_id: agent.principal,
        authority: Grant.authorize(Auth.identity(agent.token), cap("create_note")),
        input: %{"title" => title}
      )
    end

    # A signed lease for the command `run_gate/4` builds, with exactly one of
    # the gate's four checks broken (`:valid` breaks none). Returns the lease
    # and the public key that is to verify it.
    defp gate_lease(agent, title, tamper) do
      command = gate_command(agent, title)
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      other_pub = :crypto.generate_key(:eddsa, :ed25519) |> elem(0)
      zeros = "sha256:" <> String.duplicate("0", 64)

      lease =
        case tamper do
          :valid ->
            Lease.for_command(command)

          :scope ->
            command |> Lease.for_command() |> struct(scope_digest: zeros)

          :root ->
            command |> Lease.for_command() |> struct(root_digest: zeros)

          :signature ->
            Lease.for_command(command)

          :clock ->
            command
            |> Lease.for_command(issued_monotonic_ms: nil)
            |> struct(not_before: ~U[2020-01-01 00:00:00Z], expires_at: ~U[2020-01-02 00:00:00Z])
        end

      {:ok, signed} = Lease.sign(lease, priv)
      {signed, if(tamper == :signature, do: other_pub, else: pub)}
    end

    # The command of `gate_lease/3` is rebuilt with a fresh id, so the lease
    # carries the scope of the title: the gate's scope digest covers the
    # capability and input, not the command id.
    defp run_gate(agent, title, lease, public_key) do
      run_bus(gate_command(agent, title), agent, title,
        lease: lease,
        lease_public_key: public_key
      )
    end

    # == brokers ================================================================

    defp memory_broker,
      do: %{label: "InMemory", ref: InMemory, verify: &InMemory.verify(&1, [])}

    defp ekv_broker(name),
      do: %{label: "EKV", ref: {Ekv, [name: name]}, verify: &Ekv.verify(&1, name: name)}

    defp label(:memory), do: "InMemory"
    defp label(:ekv), do: "EKV"

    defp with_broker_under_test(:memory, fun), do: fun.(memory_broker())
    defp with_broker_under_test(:ekv, fun), do: with_ekv(fun)

    # A real on-disk EKV instance for one probe, and the durable broker on it.
    defp with_ekv(fun) do
      name = :"sim_authority_ekv_#{System.unique_integer([:positive])}"
      dir = Path.join(System.tmp_dir!(), "ash_a2a_sim_authority_ekv_#{unique()}")

      {:ok, sup} =
        Supervisor.start_link([{EKV, name: name, data_dir: dir, cluster_size: 1}],
          strategy: :one_for_one
        )

      try do
        fun.(ekv_broker(name))
      after
        Supervisor.stop(sup, :normal, 10_000)
        File.rm_rf(dir)
      end
    end

    # Makes `broker` (a module or `{module, opts}`) the host's
    # `:authority_broker` for the length of `fun`.
    defp with_broker(broker, fun) do
      previous = Application.fetch_env(:ash_a2a, :authority_broker)
      Application.put_env(:ash_a2a, :authority_broker, broker)

      try do
        fun.()
      after
        case previous do
          {:ok, value} -> Application.put_env(:ash_a2a, :authority_broker, value)
          :error -> Application.delete_env(:ash_a2a, :authority_broker)
        end
      end
    end

    defp with_kill_switch(fun) do
      fun.()
    after
      _ = reset_kill_switch()
    end

    # == callers and grants =====================================================

    defp fresh_agent do
      token = "sim-agent-authority-" <> unique()
      %{token: token, principal: Auth.principal(token)}
    end

    defp fresh_principal, do: Identity.principal("sim-authority-" <> unique())

    defp with_agent(fun), do: with_agent(memory_broker(), fun)

    # Runs `fun` for a fresh caller and revokes whatever it was granted.
    defp with_agent(broker, fun) do
      agent = fresh_agent()

      try do
        fun.(agent)
      after
        for skill <- @mutating, Grant.granted?(agent.principal, cap(skill), broker: broker.ref) do
          Grant.revoke(agent.principal, cap(skill), broker: broker.ref)
        end
      end
    end

    defp grant!(agent, skill, opts \\ []) do
      case Grant.grant(agent.principal, cap(skill), opts) do
        {:ok, authority} -> {:ok, authority}
        other -> fail!("grant #{skill}: #{clip(inspect(other))}")
      end
    end

    defp cap(skill) do
      case Enum.find(AshA2A.Info.capability_index(Note), &(to_string(&1.name) == skill)) do
        nil -> fail!("no skill #{skill}")
        found -> found.id
      end
    end

    defp past, do: DateTime.add(DateTime.utc_now(), -60, :second)

    # == checks =================================================================

    defp receipt!(message_id) do
      case fetch_receipt(message_id) do
        {:ok, receipt} -> receipt
        :error -> fail!("no receipt committed for message #{message_id}")
      end
    end

    defp effect?("publish_note", title), do: title in Note.publications()
    defp effect?(_skill, title), do: note_by_title(title) != nil

    defp note_by_title(title) do
      Note |> Ash.read!(authorize?: false) |> Enum.find(&(&1.title == title))
    end

    defp note_count, do: Note |> Ash.read!(authorize?: false) |> length()

    defp expect_state!(result, expected) do
      check!(
        result.state == expected,
        "over #{result.binding} expected #{expected}, got #{inspect(result.state)}: #{clip(result.text)}"
      )
    end

    defp expect_refused!(result, code) do
      expect_state!(result, @rejected)

      check!(
        result.text =~ code,
        "over #{result.binding} the refusal does not name #{code}: #{clip(result.text)}"
      )
    end

    defp unique, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    defp check!(true, _message), do: :ok
    defp check!(_falsy, message), do: fail!(message)

    @spec fail!(String.t()) :: no_return()
    defp fail!(message), do: raise(Failure, message: message)

    defp clip(text, max \\ 400) do
      text = text |> to_string() |> String.replace(~r/\s+/, " ")
      if String.length(text) > max, do: String.slice(text, 0, max) <> "...", else: text
    end
  end
end
