defmodule AshA2A.Replan.PortableSchema do
  @moduledoc false

  @external_resource Path.expand("../../../priv/sa2a/replan-envelope-v1.schema.json", __DIR__)
  @schema File.read!(@external_resource)
  @digest "sha256:" <> (:crypto.hash(:sha256, @schema) |> Base.encode16(case: :lower))

  def json, do: @schema
  def decode!, do: Jason.decode!(@schema)
  def digest, do: @digest
  def id, do: "sa2a/replan-envelope/v1"
end
