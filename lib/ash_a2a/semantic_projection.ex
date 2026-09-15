defmodule AshA2A.SemanticProjection do
  @moduledoc """
  Deterministic semantic/process projection of canonical AshA2A evidence.

  This module is read-only. It projects committed receipts and canonical
  capabilities into machine-readable evidence and, when `ash_r2rml` is
  available, joins the capability to that package's public
  `mapping_result/1` inspection surface. It never executes SPARQL, mutates RDF,
  or grants command authority.
  """

  alias AshA2A.{Identity, Receipt}

  @spec receipt(Receipt.t()) :: map()
  def receipt(%Receipt{} = receipt) do
    %{
      receipt_id: external(receipt.receipt_id),
      command_id: external(receipt.command_id),
      execution_id: external(receipt.execution_id),
      task_id: external(receipt.task_id),
      agent_id: external(receipt.agent_id),
      principal_id: external(receipt.principal_id),
      capability_id: receipt.capability_id,
      fingerprint: receipt.fingerprint,
      consequence: receipt.consequence,
      status: receipt.status,
      standing: receipt.standing,
      replayed?: receipt.replayed?,
      recorded_at: DateTime.to_iso8601(receipt.recorded_at)
    }
  end

  @spec capability(module(), String.t()) :: {:ok, map()} | {:error, term()}
  def capability(resource_or_domain, capability_id) when is_binary(capability_id) do
    case AshA2A.Info.skill(resource_or_domain, capability_id) do
      {:ok, skill} ->
        {:ok,
         %{
           capability_id: skill.id,
           name: skill.name,
           resource: inspect(skill.resource),
           domain: inspect(skill.domain),
           action: skill.action,
           r2rml_mapping_result: r2rml_mapping_result(skill.resource)
         }}

      {:error, :skill_not_found} ->
        {:error, {:capability_not_found, capability_id}}
    end
  end

  @spec r2rml_mapping_result(module()) :: term()
  def r2rml_mapping_result(resource) when is_atom(resource) do
    if Code.ensure_loaded?(AshR2RML) and function_exported?(AshR2RML, :mapping_result, 1) do
      try do
        apply(AshR2RML, :mapping_result, [resource])
      rescue
        error -> {:error, {:ash_r2rml_mapping_error, error.__struct__, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:ash_r2rml_mapping_throw, kind, reason}}
      end
    else
      {:unsupported, :ash_r2rml}
    end
  end

  @spec ocel_event(Receipt.t()) :: map()
  def ocel_event(%Receipt{} = receipt) do
    semantic = receipt(receipt)

    %{
      "event_id" => semantic.receipt_id,
      "event_type" => "ash_a2a.receipt.#{semantic.status}",
      "event_time" => semantic.recorded_at,
      "attributes" => %{
        "command_id" => semantic.command_id,
        "execution_id" => semantic.execution_id,
        "task_id" => semantic.task_id,
        "agent_id" => semantic.agent_id,
        "principal_id" => semantic.principal_id,
        "capability_id" => semantic.capability_id,
        "fingerprint" => semantic.fingerprint,
        "consequence" => to_string(semantic.consequence),
        "status" => to_string(semantic.status),
        "standing" => to_string(semantic.standing),
        "replayed" => semantic.replayed?
      },
      # Always present, defaulting to `[]`, so every emitted event carries
      # the OCEL 2.0 E2O relationships field key -- matching
      # `AshA2A.Telemetry.OcelForwarder.build_dispatch_event/2`'s own
      # `"relationships" => relationships(metadata)` (ocel_forwarder.ex:168),
      # which always includes the key too. Without this default,
      # `OcelForwarder.receipt_event/1`'s nil-dispatch branch
      # (ocel_forwarder.ex:157-158, taken whenever no CommandBus-routed
      # dispatch span was stashed ahead of this receipt commit) returned
      # this base event unmodified, so the key was absent entirely rather
      # than present-and-empty. beam4pm's `decode_relationships/1` already
      # treats a missing key as `{:ok, []}`, so this is behavior-preserving
      # for the current deployed consumer -- it only closes the gap for a
      # stricter OCEL 2.0 parser that requires the field key to always be
      # present.
      "relationships" => []
    }
  end

  defp external(nil), do: nil
  defp external(%Identity{} = identity), do: Identity.external(identity)
end
