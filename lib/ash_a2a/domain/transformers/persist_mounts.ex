# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/commits>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Domain.Transformers.PersistMounts do
  @moduledoc """
  Records the persisted mount specs for `AshA2A.Domain`'s `transport.mount`
  entities (Workstream3 G5, lane G-I):

  - `ash_a2a_domain_mounts` -- every declared per-agent mount, as
    `AshA2A.Domain.Mount` structs.
  - `ash_a2a_domain_default_mount` -- the `transport.default_mount` option,
    or the historical default `"/a2a"` when it is not declared.

  The pre-existing `PersistConfig` runs after this transformer and keeps the
  persisted `ash_a2a_domain_transport` map's lane-B shape (`mount:` key fed
  from the `default_mount` option), so `AshA2A.Domain.Info.mount/1` and the
  derived card endpoint keep their semantics.
  """

  use Spark.Dsl.Transformer

  alias AshA2A.Domain.Mount
  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: false

  @impl true
  def before?(AshA2A.Domain.Transformers.PersistConfig), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    mounts =
      dsl_state
      |> Transformer.get_entities([:transport])
      |> Enum.filter(&match?(%Mount{}, &1))

    default_path = Transformer.get_option(dsl_state, [:transport], :default_mount, "/a2a")

    {:ok,
     dsl_state
     |> Transformer.persist(:ash_a2a_domain_mounts, mounts)
     |> Transformer.persist(:ash_a2a_domain_default_mount, default_path)}
  end
end
