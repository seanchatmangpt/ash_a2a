defmodule AshA2A.Test.Support.CommandWorker do
  @moduledoc """
  Real `Oban.Worker` for GAP D's Oban delivery qualification
  (`test/ash_a2a/oban_delivery_qualification_test.exs`). `perform/1`
  reconstructs a real `AshA2A.Command` -- and the `A2A.Message` carrying its
  input, which `AshA2A.Dispatcher` actually reads -- from a real,
  DB-persisted `Oban.Job.args` map (the exact shape
  `AshA2A.Delivery.Oban.payload/1` produces), then re-admits it through
  `AshA2A.CommandBus.run/4` exactly as any other `CommandBus` caller would.

  This is the real point `AshA2A.Delivery.Oban`'s own moduledoc makes:
  "the Oban worker that eventually receives this payload must reconstruct
  an admitted command and call `AshA2A.CommandBus`; an Oban job id is never
  promoted to A2A TaskID or to an execution receipt." Oban's own
  at-least-once delivery guarantee (a job may be picked up and `perform/1`
  invoked more than once for the same logical command, e.g. after a crash
  mid-attempt) never bypasses `CommandBus`'s own replay/conflict semantics
  -- a second `perform/1` for the same reconstructed command
  (`command_id` + identical `fingerprint`) replays the already-committed
  receipt instead of re-executing the real Ash action a second time.

  ## Live authority re-verification (real gap closed)

  Real hardening pass finding (`test/ash_a2a/chicago/hardening/
  adapter_crash_safety_test.exs`, "real defect ... revoked-but-unexpired
  authority still actuates"): `ObanAuthority.reconstruct/2` restores the
  ORIGINAL `expires_at` from enqueue-time job args, so it correctly refuses
  an authority that has since expired -- but a REVOKED grant with no
  expiry, or one whose expiry has not yet passed, has nothing in the
  reconstructed struct that could ever reflect the revocation.
  `CommandBus.admit/2`'s own `Authority.admits?/2` check only inspects the
  struct it is handed; it never re-queries the broker. `perform/1` below
  therefore re-verifies LIVE broker standing via
  `ObanAuthority.verify_live!/3` before every fresh dispatch.

  That gate is conditional, not unconditional, for a real, separately
  proven reason (same hardening pass, same test file): gating every
  `perform/1` on live standing unconditionally would spuriously refuse a
  legitimate Oban at-least-once REDELIVERY of a command whose receipt is
  ALREADY durable, the instant its principal's grant is revoked AFTER the
  real consequence already happened -- even though `CommandBus.run/4`'s own
  claim/replay logic would have replayed the stored receipt without
  touching Ash again. Revoking authority must never invalidate evidence of
  a consequence that already happened. So the receipt store is peeked
  first (cheap, never itself a source of authority): an existing receipt
  means this is redelivery-of-an-already-actuated command, and live
  re-verification is skipped on purpose; no receipt yet means a genuinely
  fresh (or still in-flight) attempt, which DOES need live standing
  re-verified before `CommandBus` ever sees it.

  Deliberately scoped to `AshA2A.Test.Fixture.Item` (this repo's real
  `:create`/`:update`/`:destroy`-shaped Chicago-style test fixture) rather
  than accepting an arbitrary `resource_or_domain` at runtime: a real
  production worker resolves its dispatch target the same way -- one
  worker module per bounded command family, statically wired in code --
  not by trusting an arbitrary module-name string riding along in
  caller-supplied job args (which would let an untrusted job payload name
  any compiled module).
  """

  use Oban.Worker, queue: :commands, max_attempts: 3

  alias AshA2A.{Command, CommandBus, Delivery.ObanAuthority, SemanticSubject}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    principal_value = raw_value(args["principal_id"])
    reconstructed = reconstruct_command(args, principal_value)
    store = CommandBus.default_store()

    # Peek before re-verifying live standing: an already-durable receipt
    # means this is redelivery of an already-actuated command (skip live
    # re-verification on purpose -- see moduledoc), never a fresh attempt.
    authority_result =
      case store.fetch(reconstructed.command_id, []) do
        {:ok, _already_durable_receipt} ->
          {:ok, reconstructed.authority}

        :error ->
          ObanAuthority.verify_live!(reconstructed.authority, args["capability_id"])
      end

    with {:ok, live_authority} <- authority_result do
      command = %{reconstructed | authority: live_authority}
      message = A2A.Message.new_user([A2A.Part.Data.new(args["input"] || %{})])

      case CommandBus.run(command, message, AshA2A.Test.Fixture.Item) do
        {:ok, _receipt} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- Real reconstruction from `AshA2A.Delivery.Oban.payload/1`'s shape --
  #
  # `payload/1` externalizes every `AshA2A.Identity` as its `"kind:value"`
  # wire string (`Identity.external/1`); `raw_value/1` below reverses that
  # for the one part each identity opt actually needs -- the raw value --
  # since `AshA2A.Command.new/2`'s `command_id:`/`agent_id:`/
  # `principal_id:`/`task_id:` opts already re-tag a raw value with the
  # correct kind (`AshA2A.Command.ensure_identity/2`).
  #
  # `AshA2A.Command.fingerprint/1` is recomputed fresh here from these
  # reconstructed fields -- never trusted from `args["fingerprint"]`, which
  # `payload/1` carries only as delivery-time observational metadata, not
  # as executable truth. Because reconstruction is a pure function of the
  # same persisted `args`, two `perform/1` runs over the identical job
  # always agree on the same real fingerprint, which is exactly what lets
  # `AshA2A.CommandBus`'s claim/replay logic in `AshA2A.ReceiptStore`
  # recognize the second run as the same command rather than a new one.
  defp reconstruct_command(args, principal_value) do
    Command.new(args["capability_id"],
      command_id: raw_value(args["command_id"]),
      agent_id: raw_value(args["agent_id"]),
      principal_id: principal_value,
      task_id: args["task_id"] && raw_value(args["task_id"]),
      input: args["input"] || %{},
      authority: reconstruct_authority(args, principal_value),
      semantic_subject: reconstruct_semantic_subject(args),
      metadata: args["metadata"] || %{}
    )
  end

  # `AshA2A.Delivery.Oban.payload/1` carries the authority's `token_id`
  # external string (`authority_token(command.authority)`) and its real
  # `expires_at` (`authority_expires_at(command.authority)`), not a full
  # serialized `AshA2A.Authority` struct (source, issued_at,
  # evidence/constraints are all real host-runtime state, not
  # wire-portable command content). What `AshA2A.CommandBus.admit/2`
  # actually checks via `AshA2A.Authority.admits?/2` is `subject ==
  # command.principal_id`, `capability_id == command.capability_id`, and
  # `not expired?(authority)` -- all three fully reconstructable from
  # `args` via `AshA2A.Delivery.ObanAuthority.reconstruct/2` -- so this real
  # (not faked) `AshA2A.Authority` struct admits identically to the one the
  # original caller held, without inventing unavailable evidence, AND
  # honors the ORIGINAL time bound rather than always reconstructing an
  # unbounded authority (see `AshA2A.Delivery.Oban`'s moduledoc for the
  # enqueue-time-snapshot-vs-live-grant gap this closes).
  defp reconstruct_authority(args, principal_value) do
    ObanAuthority.reconstruct(args, principal_value)
  end

  # `AshA2A.Delivery.Oban.payload/1` carries the same four fields
  # `AshA2A.Command.fingerprint/1` folds into its hash via
  # `SemanticSubject.fingerprint_token/1` (graph_digest, projection_digest,
  # manufacturer_digest, ephemeral?), omitting all four keys entirely when
  # the original command's `semantic_subject` was nil. Rebuilding a real
  # `AshA2A.SemanticSubject` here (never a bare map) is what lets a
  # continuation-flow command's reconstructed `Command.fingerprint` agree
  # with the fingerprint computed by the original caller, which is exactly
  # the discriminator `AshA2A.ReceiptStore`'s claim logic uses to
  # distinguish a legitimate replay from a `:command_conflict`.
  defp reconstruct_semantic_subject(%{"semantic_subject_graph_digest" => graph_digest} = args)
       when is_binary(graph_digest) do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: graph_digest,
        projection_digest: args["semantic_subject_projection_digest"],
        manufacturer_digest: args["semantic_subject_manufacturer_digest"],
        ephemeral?: Map.get(args, "semantic_subject_ephemeral", true)
      )

    subject
  end

  defp reconstruct_semantic_subject(_args), do: nil

  defp raw_value(external) when is_binary(external) do
    case String.split(external, ":", parts: 2) do
      [_kind, value] -> value
      [value] -> value
    end
  end
end
