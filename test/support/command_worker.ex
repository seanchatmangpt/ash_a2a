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

  alias AshA2A.{Authority, Command, CommandBus, Identity, SemanticSubject}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    command = reconstruct_command(args)
    message = A2A.Message.new_user([A2A.Part.Data.new(args["input"] || %{})])

    case CommandBus.run(command, message, AshA2A.Test.Fixture.Item) do
      {:ok, _receipt} -> :ok
      {:error, reason} -> {:error, reason}
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
  defp reconstruct_command(args) do
    principal_value = raw_value(args["principal_id"])

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

  # `AshA2A.Delivery.Oban.payload/1` carries only the authority's
  # `token_id` external string (`authority_token(command.authority)`), not
  # a full serialized `AshA2A.Authority` struct (source, issued_at,
  # evidence/constraints are all real host-runtime state, not
  # wire-portable command content). What `AshA2A.CommandBus.admit/2`
  # actually checks via `AshA2A.Authority.admits?/2` is `subject ==
  # command.principal_id` and `capability_id == command.capability_id` --
  # both fully reconstructable from `args` -- so this real (not faked)
  # `AshA2A.Authority` struct admits identically to the one the original
  # caller held, without inventing unavailable evidence.
  defp reconstruct_authority(%{"authority_token_id" => nil}, _principal_value), do: nil

  defp reconstruct_authority(%{"authority_token_id" => external} = args, principal_value)
       when is_binary(external) do
    Authority.new(Identity.principal(principal_value), args["capability_id"],
      token_id: raw_value(external)
    )
  end

  defp reconstruct_authority(_args, _principal_value), do: nil

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
