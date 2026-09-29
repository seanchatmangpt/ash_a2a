defmodule AshA2A.ConsequenceKernel.PreparedRecordCodec do
  alias AshA2A.Identity.Canonical
  @schema "sa2a.prepared-effect.v1"
  def encode(prepared) do
    Canonical.encode(%{"schema" => @schema, "prepared_digest" => prepared.prepared_digest,
      "request_id" => prepared.instance.request_id, "effect_id" => prepared.instance.effect_id,
      "subject_digest" => prepared.instance.subject_digest, "authority_epoch" => prepared.authority_epoch,
      "consequence_class" => to_string(prepared.consequence_class)})
  end
  def schema, do: @schema
end
