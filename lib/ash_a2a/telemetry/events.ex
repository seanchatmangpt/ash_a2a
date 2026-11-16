# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.Events do
  @moduledoc """
  Catalog of the `:telemetry` events AshA2A emits, plus a logging helper.

  `all/0` returns one map per event:

      %{event: [atom], measurements: [atom], metadata: [atom], description: String.t()}

  Use it to build dashboards, alert rules or an allow-list of handlers without
  grepping the source:

      for %{event: event} <- AshA2A.Telemetry.Events.all(), do: event

  `attach_logger/1` attaches one handler to every catalogued event and logs the
  event name, the measurements and the metadata **keys** (never the values, so
  receipts, endpoints and principals do not leak into logs):

      :ok = AshA2A.Telemetry.Events.attach_logger(level: :debug)
      :ok = AshA2A.Telemetry.Events.detach_logger()

  ## What is and is not guaranteed

    * Event **names** are enforced by `test/telemetry_catalog_test.exs`, which
      scans `lib/` for event-name lists and fails when an emitted name is
      missing here or when a catalogued name has no matching text in `lib/`.
      That test is textual: for events built from a dynamic suffix (for example
      `[:ash_a2a, :command_bus | suffix]`) it can only check the prefix, and a
      consumer mentioning a name satisfies the "nothing emits it" direction.
    * `measurements` and `metadata` are the primary keys read from the emit
      sites at the time of writing. They are a guide, not a schema; a given
      emit may add or omit keys.
    * Span events (`:telemetry.span/3`) are listed as their `:start`, `:stop`
      and `:exception` members.
    * The conformance-court harness family `[:ash_a2a, :chicago, ...]`
      (`lib/ash_a2a/chicago/`) is test-harness output and is deliberately not
      catalogued; see `docs/reference/telemetry.md`.
    * `unemitted_prefixes/0` lists event prefixes that exist in `lib/` but that
      no code path currently emits.

  The same catalog is mirrored by hand in `docs/reference/telemetry.md`.
  """

  require Logger

  @handler_id "ash_a2a-telemetry-events-logger"

  @type entry :: %{
          event: [atom()],
          measurements: [atom()],
          metadata: [atom()],
          description: String.t()
        }

  @doc """
  Event-name prefixes that appear in `lib/` but are not emitted by any caller.

    * `[:ash_a2a, :replan]` - `AshA2A.Replan.Telemetry.emit/3` has no caller.
    * `[:ash_a2a, :gall, :closure]` - `AshA2A.Gall.Closure.TelemetryEnvelope`
      only builds the event map and never executes it.
  """
  @spec unemitted_prefixes() :: [[atom()]]
  def unemitted_prefixes, do: [[:ash_a2a, :replan], [:ash_a2a, :gall, :closure]]

  @doc "The handler id used by `attach_logger/1` and `detach_logger/1`."
  @spec logger_handler_id() :: String.t()
  def logger_handler_id, do: @handler_id

  @doc """
  Attaches a logging handler to every catalogued event.

  Options:

    * `:level` - Logger level, default `:info`.
    * `:events` - restrict to these event names (default: every catalogued event).

  Returns `:ok`, or `{:error, :already_exists}` when the logger is already
  attached. Call `detach_logger/0` first to re-attach with other options.
  """
  @spec attach_logger(keyword()) :: :ok | {:error, :already_exists}
  def attach_logger(opts \\ []) do
    level = Keyword.get(opts, :level, :info)
    events = Keyword.get(opts, :events, Enum.map(all(), & &1.event))

    :telemetry.attach_many(
      @handler_id,
      events,
      &__MODULE__.handle_event/4,
      %{level: level}
    )
  end

  @doc "Detaches the handler attached by `attach_logger/1`."
  @spec detach_logger() :: :ok | {:error, :not_found}
  def detach_logger, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(event, measurements, metadata, %{level: level}) do
    Logger.log(level, fn ->
      "telemetry " <>
        inspect(event) <>
        " measurements=" <>
        inspect(measurements, limit: 10, printable_limit: 80) <>
        " metadata_keys=" <> inspect(metadata_keys(metadata))
    end)

    :ok
  end

  defp metadata_keys(metadata) when is_map(metadata), do: metadata |> Map.keys() |> Enum.sort()
  defp metadata_keys(_other), do: []

  @doc "Every catalogued event, as `t:entry/0` maps."
  @spec all() :: [entry()]
  def all do
    [
      e(
        [:a2a, :agent, :call, :start],
        [:system_time, :monotonic_time],
        [:agent, :message_id],
        "Protocol.call to an agent process (span start)"
      ),
      e(
        [:a2a, :agent, :call, :stop],
        [:duration, :monotonic_time],
        [:agent, :message_id],
        "Protocol.call to an agent process (span stop)"
      ),
      e(
        [:a2a, :agent, :call, :exception],
        [:duration, :monotonic_time],
        [:agent, :message_id, :kind, :reason, :stacktrace],
        "Protocol.call to an agent process (span exception)"
      ),
      e(
        [:a2a, :agent, :message, :start],
        [:system_time, :monotonic_time],
        [:reply_type],
        "agent message handling (span start)"
      ),
      e(
        [:a2a, :agent, :message, :stop],
        [:duration, :monotonic_time],
        [:reply_type],
        "agent message handling (span stop)"
      ),
      e(
        [:a2a, :agent, :message, :exception],
        [:duration, :monotonic_time],
        [:reply_type, :kind, :reason, :stacktrace],
        "agent message handling (span exception)"
      ),
      e(
        [:a2a, :agent, :cancel, :start],
        [:system_time, :monotonic_time],
        [:task_id],
        "agent cancel handling (span start)"
      ),
      e(
        [:a2a, :agent, :cancel, :stop],
        [:duration, :monotonic_time],
        [:task_id],
        "agent cancel handling (span stop)"
      ),
      e(
        [:a2a, :agent, :cancel, :exception],
        [:duration, :monotonic_time],
        [:task_id, :kind, :reason, :stacktrace],
        "agent cancel handling (span exception)"
      ),
      e(
        [:a2a, :bidi, :input],
        [:count],
        [:task_id],
        "uplink message accepted into a running task"
      ),
      e(
        [:a2a, :push_config, :volatile],
        [:count],
        [:task_id, :config_id],
        "push config stored in memory only"
      ),
      e(
        [:a2a, :push_notification, :delivery],
        [:duration],
        [:task_id, :context_id, :config_id, :url, :result],
        "push notification delivery result"
      ),
      e(
        [:a2a, :task, :late_event_dropped],
        [:count],
        [:task_id, :terminal_state, :event],
        "event after terminal state dropped"
      ),
      e(
        [:a2a, :task, :transition],
        [:system_time],
        [:task_id, :context_id, :from, :to],
        "task state transition"
      ),
      e(
        [:a2a, :task, :transition_refused],
        [:system_time],
        [:task_id, :from, :to, :reason],
        "illegal task transition refused"
      ),
      e([:a2a, :task_store, :put_failed], [:count], [:task_id, :reason], "task store put failed"),
      e(
        [:ash_a2a, :a2a_transport, :push, :attempt],
        [:count],
        [:task_id, :config_id, :attempt, :outcome],
        "one signed webhook push attempt"
      ),
      e(
        [:ash_a2a, :agent, :cancel],
        [],
        [:resource_or_domain, :task_id, :context_id, :actor, :tenant],
        "agent task cancelled"
      ),
      e(
        [:ash_a2a, :agent, :cancel_hook_error],
        [],
        [:resource_or_domain, :task_id, :error],
        "on-cancel hook raised or failed"
      ),
      e(
        [:ash_a2a, :agent, :dispatch],
        [:system_time],
        [:resource_or_domain, :route],
        "agent routed a skill dispatch"
      ),
      e([:ash_a2a, :attestation, :build], [], [:outcome, :code], "attestation build decision"),
      e([:ash_a2a, :attestation, :verify], [], [:outcome, :code], "attestation verify decision"),
      e(
        [:ash_a2a, :authority, :broker, :lookup],
        [],
        [:outcome],
        "authority broker grant lookup"
      ),
      e(
        [:ash_a2a, :authority, :decision],
        [:system_time],
        [:outcome, :reason, :capability_id, :policy],
        "authority grant decision (granted or refused)"
      ),
      e(
        [:ash_a2a, :authority, :decision_envelope, :verdict],
        [],
        [:outcome, :code],
        "decision envelope verdict"
      ),
      e(
        [:ash_a2a, :authority, :grant, :issue],
        [:system_time],
        [:outcome, :reason, :capability_id],
        "authority grant issue lifecycle"
      ),
      e(
        [:ash_a2a, :authority, :grant, :revoke],
        [:system_time],
        [:outcome, :reason, :capability_id],
        "authority grant revoke lifecycle"
      ),
      e(
        [:ash_a2a, :authority, :grant, :renew],
        [:system_time],
        [:outcome, :reason, :capability_id],
        "authority grant renew lifecycle"
      ),
      e(
        [:ash_a2a, :authzen, :monotonic, :refused],
        [:system_time],
        [:code, :digest, :depth, :parent_effective, :requested, :excess],
        "delegation widening refused"
      ),
      e(
        [:ash_a2a, :cluster, :checkpoint, :terminal_skipped],
        [:count],
        [:task_id, :state],
        "terminal task not checkpointed"
      ),
      e(
        [:ash_a2a, :cluster, :drain, :init],
        [:count],
        [:drain_manager, :drain_timeout_ms, :signal_handler],
        "drain manager init"
      ),
      e(
        [:ash_a2a, :cluster, :drain, :cordon],
        [:count],
        [:drain_manager, :reason, :tracked],
        "drain manager cordon"
      ),
      e(
        [:ash_a2a, :cluster, :drain, :complete],
        [:count],
        [:drain_manager, :checkpointed, :cordon_to_exit_ms],
        "drain manager complete"
      ),
      e(
        [:ash_a2a, :cluster, :drain, :task_skipped],
        [:count],
        [:drain_manager, :task_id, :reason],
        "drain manager task_skipped"
      ),
      e(
        [:ash_a2a, :cluster, :handover],
        [:count],
        [:task_id, :source_node, :reason, :checkpointed_at],
        "checkpoint handover broadcast"
      ),
      e(
        [:ash_a2a, :cluster, :handover, :completed],
        [:count],
        [:task_id, :node],
        "handed-over task completed"
      ),
      e(
        [:ash_a2a, :command_bus, :preflight],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :outcome, :code],
        "CommandBus preflight stage"
      ),
      e(
        [:ash_a2a, :command_bus, :target],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :outcome, :consequence, :code],
        "CommandBus target resolution stage"
      ),
      e(
        [:ash_a2a, :command_bus, :admission],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :outcome, :consequence, :code],
        "CommandBus admission stage"
      ),
      e(
        [:ash_a2a, :command_bus, :kill_switch],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :outcome, :code],
        "CommandBus kill-switch stage"
      ),
      e(
        [:ash_a2a, :command_bus, :claim],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :outcome, :code],
        "CommandBus claim stage"
      ),
      e(
        [:ash_a2a, :command_bus, :prepare],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :outcome, :code],
        "CommandBus prepare stage"
      ),
      e(
        [:ash_a2a, :command_bus, :commit],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :outcome, :status],
        "CommandBus commit stage"
      ),
      e(
        [:ash_a2a, :command_bus, :work_order],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :outcome, :work_order_digest, :code],
        "CommandBus work-order admission"
      ),
      e(
        [:ash_a2a, :command_bus, :pre_do_gate],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :outcome, :code],
        "CommandBus pre-DO refusal gate"
      ),
      e(
        [:ash_a2a, :command_bus, :lease_gate],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :outcome, :mask, :code],
        "CommandBus two-port lease gate"
      ),
      e(
        [:ash_a2a, :command_bus, :actuation_commit],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :outcome, :reason, :receipt_id],
        "CommandBus actuation commit failed after retries"
      ),
      e(
        [:ash_a2a, :command_bus, :commitment],
        [:system_time],
        [:command_id, :capability_id, :principal_id, :transition, :consequence],
        "CommandBus conditional commitment transition"
      ),
      e(
        [:ash_a2a, :command_bus, :actuate, :start],
        [:system_time],
        [:command_id, :capability_id, :principal_id],
        "CommandBus actuation start"
      ),
      e(
        [:ash_a2a, :command_bus, :actuate, :stop],
        [:system_time, :duration],
        [:command_id, :capability_id, :principal_id, :outcome],
        "CommandBus actuation stop"
      ),
      e(
        [:ash_a2a, :command_bus, :postcondition],
        [],
        [:outcome, :reason, :postcondition_id, :verifier, :independent],
        "postcondition verdict"
      ),
      e(
        [:ash_a2a, :command_bus, :swallowed_failure],
        [:count],
        [:site, :kind],
        "best-effort CommandBus step failed"
      ),
      e(
        [:ash_a2a, :copilot, :stage_skipped],
        [:count],
        [:stage, :coordinator_id],
        "copilot pipeline stage skipped"
      ),
      e(
        [:ash_a2a, :dispatch, :start],
        [:system_time, :monotonic_time],
        [:resource_or_domain, :skill_name],
        "skill dispatch (span start)"
      ),
      e(
        [:ash_a2a, :dispatch, :stop],
        [:duration, :monotonic_time],
        [:resource_or_domain, :skill_name],
        "skill dispatch (span stop)"
      ),
      e(
        [:ash_a2a, :dispatch, :exception],
        [:duration, :monotonic_time],
        [:resource_or_domain, :skill_name, :kind, :reason, :stacktrace],
        "skill dispatch (span exception)"
      ),
      e(
        [:ash_a2a, :dispatch, :brce_gate],
        [:system_time],
        [:outcome, :reason],
        "sole-DO fence verdict"
      ),
      e(
        [:ash_a2a, :dispatch, :actuate],
        [:system_time],
        [:anchored],
        "dispatch actuation anchor"
      ),
      e(
        [:ash_a2a, :enterprise, :pipeline, :completed],
        [:duration_ns],
        [:stages, :dlp_findings, :cmek, :affidavit],
        "enterprise pipeline completed"
      ),
      e(
        [:ash_a2a, :enterprise, :pipeline, :refused],
        [:duration_ns],
        [:stage, :code],
        "enterprise pipeline refused"
      ),
      e(
        [:ash_a2a, :episode, :planning],
        [:duration_us],
        [:outcome],
        "semantic episode: planning stage"
      ),
      e(
        [:ash_a2a, :episode, :allocation],
        [],
        [:kind, :outcome, :code, :envelope_id],
        "semantic episode: allocation decision"
      ),
      e(
        [:ash_a2a, :episode, :start],
        [],
        [:outcome],
        "semantic episode: episode reached executor"
      ),
      e(
        [:ash_a2a, :episode, :admission],
        [:duration_us],
        [:outcome, :code],
        "semantic episode: episode admission"
      ),
      e([:ash_a2a, :episode, :bound], [], [:outcome], "semantic episode: bound decision"),
      e(
        [:ash_a2a, :episode, :stop],
        [:duration_us, :memory_peak_bytes],
        [:outcome],
        "semantic episode: episode terminal outcome"
      ),
      e(
        [:ash_a2a, :episode, :transition, :request],
        [],
        [:outcome],
        "semantic episode: transition reached a stage"
      ),
      e(
        [:ash_a2a, :episode, :transition, :start],
        [:in_flight],
        [:outcome],
        "semantic episode: route admitted into window"
      ),
      e(
        [:ash_a2a, :episode, :transition, :stop],
        [:authority_us, :do_us],
        [:outcome],
        "semantic episode: route outcome"
      ),
      e(
        [:ash_a2a, :evidence, :promote],
        [:system_time],
        [
          :from,
          :to,
          :prior_chain_digest,
          :offered_evidence_digest,
          :outcome,
          :code,
          :chain_digest
        ],
        "evidence class promotion"
      ),
      e(
        [:ash_a2a, :evidence, :assert],
        [:system_time],
        [:from, :to, :prior_chain_digest, :outcome, :code, :chain_digest],
        "evidence class assertion"
      ),
      e(
        [:ash_a2a, :finops, :chargeback],
        [:tokens, :system_time],
        [:cost_center, :budget_account_id, :ceiling, :consumed, :admitted, :code],
        "FinOps chargeback tag per admission decision"
      ),
      e(
        [:ash_a2a, :graph_law, :wasm, :batch],
        [:calls],
        [:wasm_path, :outcome, :code],
        "GraphLaw wasm batch (historical :graph_law spelling)"
      ),
      e(
        [:ash_a2a, :graphlaw, :engine, :call],
        [:system_time, :verify_us, :total_us, :startup_us, :peak_memory_bytes],
        [:outcome, :mode],
        "GraphLaw engine call"
      ),
      e(
        [:ash_a2a, :graphlaw, :engine, :load, :start],
        [:system_time],
        [:bytes],
        "GraphLaw engine load start"
      ),
      e(
        [:ash_a2a, :graphlaw, :engine, :load, :stop],
        [:system_time],
        [:outcome, :code, :import_count, :expected_sha256],
        "GraphLaw engine load stop"
      ),
      e(
        [:ash_a2a, :graphlaw, :host, :recycle],
        [:system_time],
        [:wasm_sha256, :reason],
        "warm wasm host instance recycled"
      ),
      e([:ash_a2a, :health, :checked], [:duration], [:status], "health check run"),
      e(
        [:ash_a2a, :hook_reactor, :hook, :admission],
        [:duration_us],
        [:outcome],
        "hook reactor: hook meta-admission"
      ),
      e(
        [:ash_a2a, :hook_reactor, :hook, :evaluate],
        [:duration_us],
        [:outcome],
        "hook reactor: per-hook evaluation"
      ),
      e(
        [:ash_a2a, :hook_reactor, :intent, :constructed],
        [:duration_us],
        [:outcome],
        "hook reactor: candidate intent built"
      ),
      e(
        [:ash_a2a, :hook_reactor, :intent, :idempotency],
        [:duration_us],
        [:outcome],
        "hook reactor: receipt-store idempotency lookup"
      ),
      e(
        [:ash_a2a, :hook_reactor, :intent, :route_start],
        [],
        [:outcome],
        "hook reactor: route admitted into parallel window"
      ),
      e(
        [:ash_a2a, :hook_reactor, :intent, :routed],
        [],
        [:outcome],
        "hook reactor: CommandBus outcome for the intent"
      ),
      e(
        [:ash_a2a, :hook_reactor, :cascade, :start],
        [],
        [:outcome],
        "hook reactor: cascade start"
      ),
      e(
        [:ash_a2a, :hook_reactor, :cascade, :bound],
        [:requested, :ceiling],
        [:outcome],
        "hook reactor: cascade bound decision"
      ),
      e(
        [:ash_a2a, :hook_reactor, :cascade, :stop],
        [],
        [:outcome],
        "hook reactor: cascade terminal outcome"
      ),
      e([:ash_a2a, :llm, :invoke], [:count], [:site, :role], "LLM role invocation"),
      e(
        [:ash_a2a, :planner, :invoke],
        [:count],
        [:planner, :role, :outcome],
        "planner invocation"
      ),
      e([:ash_a2a, :logic, :closure, :start], [], [:outcome, :code], "logic closure stage start"),
      e(
        [:ash_a2a, :logic, :closure, :entailment],
        [],
        [:outcome, :code],
        "logic closure stage entailment"
      ),
      e(
        [:ash_a2a, :logic, :closure, :engine],
        [],
        [:outcome, :code],
        "logic closure stage engine"
      ),
      e(
        [:ash_a2a, :logic, :closure, :decision],
        [],
        [:outcome, :code],
        "logic closure stage decision"
      ),
      e([:ash_a2a, :logic, :closure, :stop], [], [:outcome, :code], "logic closure stage stop"),
      e([:ash_a2a, :ocel, :delivered], [:duration], [:endpoint], "OCEL POST delivered"),
      e(
        [:ash_a2a, :ocel, :failed],
        [:duration],
        [:endpoint, :status, :reason],
        "OCEL POST failed"
      ),
      e([:ash_a2a, :ocel, :ignored], [:count], [], "OCEL forwarder ignored an event"),
      e(
        [:ash_a2a, :ocel, :shed],
        [:count],
        [:endpoint, :reason],
        "OCEL event shed at in-flight ceiling"
      ),
      e([:ash_a2a, :ocel, :unconvertible], [:count], [], "event not convertible to OCEL"),
      e(
        [:ash_a2a, :ocel_broadcaster, :dropped],
        [:count],
        [:broadcaster, :dropped_total],
        "SIEM buffer drop-oldest"
      ),
      e(
        [:ash_a2a, :ocel_broadcaster, :flush_failed],
        [:count],
        [:broadcaster, :reason],
        "SIEM sink flush failed"
      ),
      e(
        [:ash_a2a, :ocel_broadcaster, :unconvertible],
        [:count],
        [:broadcaster, :kind],
        "event not convertible for SIEM"
      ),
      e(
        [:ash_a2a, :planning, :admit],
        [:capability_count],
        [:outcome, :code, :planner, :formalism, :fingerprint, :standing, :authority],
        "plan admission"
      ),
      e([:ash_a2a, :planning, :preflight], [], [:outcome, :code], "plan preflight verdict"),
      e(
        [:ash_a2a, :protocol, :plug, :authorize_refused],
        [],
        [:operation, :task_id, :refusal, :wire_code],
        "protocol plug authorize refusal"
      ),
      e(
        [:ash_a2a, :reactor, :compensate],
        [:count],
        [:command_id, :reason, :options],
        "reactor compensation"
      ),
      e(
        [:ash_a2a, :reconciliation, :classified],
        [:system_time],
        [:command_id, :receipt_id, :status, :resolved_as],
        "reconciliation classified"
      ),
      e(
        [:ash_a2a, :reconciliation, :reconciled],
        [:system_time],
        [:command_id, :receipt_id, :status, :resolved_as],
        "reconciliation reconciled"
      ),
      e(
        [:ash_a2a, :reconciliation, :compensated],
        [:system_time],
        [:command_id, :receipt_id, :status, :resolved_as],
        "reconciliation compensated"
      ),
      e([:ash_a2a, :receipt, :binding, :bind], [], [:outcome, :code], "receipt binding bind"),
      e([:ash_a2a, :receipt, :binding, :verify], [], [:outcome, :code], "receipt binding verify"),
      e([:ash_a2a, :receipt, :committed], [], [:receipt], "final receipt committed"),
      e(
        [:ash_a2a, :receipt, :outboxed],
        [],
        [:receipt],
        "pending receipt journaled pre-dispatch"
      ),
      e(
        [:ash_a2a, :receipt_outbox, :decode_failed],
        [:count],
        [:cause],
        "outbox journal entry undecodable"
      ),
      e(
        [:ash_a2a, :receipt_outbox, :sync_dir_failed],
        [:count],
        [:dir, :reason],
        "outbox directory fsync failed"
      ),
      e(
        [:ash_a2a, :receipt_outbox, :reconciler, :tick],
        [:committed, :remaining],
        [],
        "outbox reconciler drain summary"
      ),
      e(
        [:ash_a2a, :receipt_outbox, :reconciler, :corrupt],
        [:count],
        [:filenames, :reasons],
        "undecodable journal files"
      ),
      e(
        [:ash_a2a, :receipt_outbox, :reconciler, :stuck],
        [:attempts],
        [:command_id, :receipt_id, :threshold],
        "journal entry stuck past threshold"
      ),
      e(
        [:ash_a2a, :replay, :chain_sealed],
        [:system_time],
        [:chain_id, :chain_ref, :length, :commands, :evidence_bytes, :link_root, :basis_root],
        "evidence chain sealed"
      ),
      e(
        [:ash_a2a, :replay, :verified],
        [:system_time, :verify_us, :total_us, :startup_us, :peak_memory_bytes],
        [:outcome, :mode],
        "offline replay verdict"
      ),
      e([:ash_a2a, :router, :tier_refused], [], [:tier, :reason], "request router tier refused"),
      e([:ash_a2a, :router, :tier_selected], [], [:tier], "request router tier selected"),
      e(
        [:ash_a2a, :runtime, :configured],
        [:system_time],
        [:receipt_store, :durable, :data_dir_tmp, :receipt_outbox_dir_tmp],
        "boot-time runtime posture"
      ),
      e([:ash_a2a, :sa2a, :conformance, :judged], [], [:outcome], "SA2A conformance judged"),
      e([:ash_a2a, :sa2a, :conformance, :replayed], [], [:outcome], "SA2A conformance replayed"),
      e(
        [:ash_a2a, :sa2a, :conformance, :runtime_identity],
        [],
        [:outcome],
        "SA2A conformance runtime_identity"
      ),
      e(
        [:ash_a2a, :sa2a, :conformance, :vector_judged],
        [],
        [:outcome],
        "SA2A conformance vector_judged"
      ),
      e([:ash_a2a, :security, :dlp], [:duration_ns, :findings], [:types], "DLP filter run"),
      e(
        [:ash_a2a, :security_profile, :dev_bypass],
        [],
        [:profile],
        "dev_bypass build stamped receipts"
      ),
      e(
        [:ash_a2a, :security_profile, :legacy_compat],
        [],
        [:profile],
        "legacy_compat boot posture"
      ),
      e(
        [:ash_a2a, :semantic, :admission, :start],
        [],
        [:candidate_digest],
        "semantic admission pipeline start"
      ),
      e(
        [:ash_a2a, :semantic, :admission, :stage],
        [],
        [:stage, :outcome],
        "semantic admission stage attempted"
      ),
      e(
        [:ash_a2a, :semantic, :admission, :stop],
        [],
        [:outcome, :code],
        "semantic admission pipeline stop"
      ),
      e(
        [:ash_a2a, :semantic, :allocation],
        [:count],
        [:class, :resolver],
        "unknown-class allocation"
      ),
      e(
        [:ash_a2a, :semantic, :allocator, :decision],
        [],
        [:outcome, :code],
        "semantic allocator decision"
      ),
      e(
        [:ash_a2a, :semantic, :bounds, :delegate],
        [],
        [:outcome, :code],
        "semantic bounds delegation"
      ),
      e(
        [:ash_a2a, :semantic, :canonical_graph, :digest],
        [],
        [:outcome, :code],
        "canonical graph digest"
      ),
      e(
        [:ash_a2a, :semantic, :canonical_graph, :pin],
        [],
        [:outcome, :code],
        "canonical graph pin"
      ),
      e(
        [:ash_a2a, :semantic, :canonical_graph, :compare],
        [],
        [:outcome, :code],
        "canonical graph compare"
      ),
      e([:ash_a2a, :semantic, :construct], [], [:outcome, :code], "CONSTRUCT pipeline stage"),
      e(
        [:ash_a2a, :semantic, :extension, :negotiate],
        [],
        [:outcome, :code],
        "extension negotiation"
      ),
      e(
        [:ash_a2a, :semantic, :falsifier_suite, :admit],
        [],
        [:outcome, :code],
        "falsifier suite admission"
      ),
      e([:ash_a2a, :semantic, :hooks, :run], [], [:outcome, :code], "GraphLaw hook execution"),
      e([:ash_a2a, :semantic, :ir_admission], [], [:outcome, :code], "IR admission verdict"),
      e([:ash_a2a, :semantic, :iri, :mint_private], [], [:outcome, :code], "private IRI mint"),
      e([:ash_a2a, :semantic, :iri, :resolve], [], [:outcome, :code], "IRI resolve"),
      e(
        [:ash_a2a, :semantic, :llm_boundary, :candidate],
        [],
        [:outcome, :code],
        "LLM boundary candidate"
      ),
      e(
        [:ash_a2a, :semantic, :machine_experience, :register],
        [:classes],
        [:class, :kind, :fingerprint],
        "machine-experience class register"
      ),
      e(
        [:ash_a2a, :semantic, :machine_experience, :compile_back],
        [:count],
        [:class, :kind, :fingerprint],
        "machine-experience compile-back"
      ),
      e(
        [:ash_a2a, :semantic, :machine_experience, :unregister],
        [:classes],
        [:class, :reason, :removed],
        "machine-experience class unregister"
      ),
      e(
        [:ash_a2a, :semantic, :mapping, :register],
        [],
        [:outcome, :code],
        "mapping register (legacy call site)"
      ),
      e(
        [:ash_a2a, :semantic, :mapping_registry, :register],
        [],
        [:outcome, :code],
        "mapping registry register"
      ),
      e(
        [:ash_a2a, :semantic, :mapping_registry, :reconcile],
        [],
        [:outcome, :code],
        "mapping registry reconcile"
      ),
      e(
        [:ash_a2a, :semantic, :meta_admission, :confer],
        [:system_time],
        [:kind, :outcome],
        "meta-admission confer"
      ),
      e(
        [:ash_a2a, :semantic, :meta_admission, :standing],
        [:system_time],
        [:kind, :outcome],
        "meta-admission standing"
      ),
      e([:ash_a2a, :semantic, :ontology, :project], [], [:outcome, :code], "ontology projection"),
      e(
        [:ash_a2a, :semantic, :ontology_cache, :load],
        [],
        [:outcome, :code],
        "ontology cache load"
      ),
      e(
        [:ash_a2a, :semantic, :peer, :receive],
        [],
        [:activated, :message_id],
        "peer received a message"
      ),
      e([:ash_a2a, :semantic, :peer, :admission, :start], [], [:peer], "peer admission start"),
      e(
        [:ash_a2a, :semantic, :peer, :decision],
        [],
        [:outcome, :path],
        "peer admission decision"
      ),
      e(
        [:ash_a2a, :semantic, :plan_package],
        [:system_time],
        [:outcome, :code, :profile],
        "plan package decision"
      ),
      e(
        [:ash_a2a, :semantic, :plan_package, :build],
        [],
        [:outcome, :code],
        "plan package build"
      ),
      e(
        [:ash_a2a, :semantic, :plan_package, :verify],
        [],
        [:outcome, :code],
        "plan package verify"
      ),
      e(
        [:ash_a2a, :semantic, :plan_projection, :verify],
        [],
        [:outcome, :code],
        "plan projection verify"
      ),
      e(
        [:ash_a2a, :semantic, :root_manifest, :load],
        [],
        [:outcome, :code],
        "root manifest load"
      ),
      e(
        [:ash_a2a, :semantic, :root_manifest, :verify],
        [],
        [:outcome, :code],
        "root manifest verify"
      ),
      e(
        [:ash_a2a, :semantic, :root_manifest, :mutate],
        [],
        [:outcome, :code],
        "root manifest mutate"
      ),
      e([:ash_a2a, :semantic, :select], [], [:outcome, :code], "SELECT pipeline stage"),
      e(
        [:ash_a2a, :semantic, :sparql_update, :decision],
        [],
        [:outcome, :mutating],
        "SPARQL update admission decision"
      ),
      e(
        [:ash_a2a, :semantic, :standing, :transition],
        [],
        [:outcome, :code],
        "standing ledger transition"
      ),
      e(
        [:ash_a2a, :semantic, :term, :operational_use],
        [],
        [:outcome, :code],
        "term operational use (second call site)"
      ),
      e(
        [:ash_a2a, :semantic, :term_registry, :build],
        [],
        [:outcome, :code],
        "term registry build"
      ),
      e(
        [:ash_a2a, :semantic, :term_registry, :operational_use],
        [],
        [:outcome, :code],
        "term registry operational use"
      ),
      e(
        [:ash_a2a, :semantic, :unknown, :admit_for_do],
        [:count],
        [:class, :reason],
        "unknown admitted for DO"
      ),
      e(
        [:ash_a2a, :siem, :delivered],
        [:events, :duration],
        [:platform, :endpoint],
        "SIEM batch delivered"
      ),
      e(
        [:ash_a2a, :siem, :failed],
        [:events, :duration],
        [:platform, :endpoint, :reason],
        "SIEM batch failed"
      ),
      e([:ash_a2a, :task, :orphan_failed], [:count], [:task_id], "orphan task failed by sweep"),
      e(
        [:ash_a2a, :task, :orphan_sweep_unsupported],
        [:count],
        [:store, :reason],
        "store cannot sweep orphans"
      ),
      e(
        [:ash_a2a, :event_journal, :append_failed],
        [:count],
        [:task_id, :generation, :operation],
        "event journal append or trim failed"
      ),
      e(
        [:ash_a2a, :task_events, :journal_error],
        [:count],
        [:task_id, :seq],
        "task event journal error"
      ),
      e(
        [:ash_a2a, :transport, :plug, :list_refused],
        [],
        [:subject, :refusal, :wire_code],
        "task-list wire refusal"
      ),
      e(
        [:ash_a2a, :transport, :request, :start],
        [:system_time, :monotonic_time],
        [:transport, :method],
        "transport request (HTTP/JSON-RPC/gRPC) (span start)"
      ),
      e(
        [:ash_a2a, :transport, :request, :stop],
        [:duration, :monotonic_time],
        [:transport, :method],
        "transport request (HTTP/JSON-RPC/gRPC) (span stop)"
      ),
      e(
        [:ash_a2a, :transport, :request, :exception],
        [:duration, :monotonic_time],
        [:transport, :method, :kind, :reason, :stacktrace],
        "transport request (HTTP/JSON-RPC/gRPC) (span exception)"
      ),
      e(
        [:ash_a2a, :transport, :request, :error],
        [:count],
        [:transport, :method],
        "discrete transport error"
      )
    ]
  end

  defp e(event, measurements, metadata, description) do
    %{event: event, measurements: measurements, metadata: metadata, description: description}
  end
end
