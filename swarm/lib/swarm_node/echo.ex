defmodule SwarmNode.Echo do
  @moduledoc """
  Real, minimal `Ash.Resource` whose one real generic action answers with
  the REAL BEAM node (`Kernel.node/0`) that actually executed it. This is
  the entire swarm-test payload: dispatching this skill against a peer
  pod's registered `SwarmNode.EchoAgent` and observing a `node` field that
  differs from the caller's own `node()` is the real, falsifiable proof
  that a live, distributed cross-pod `A2A.Agent` dispatch occurred --
  never a same-process/same-node stand-in.
  """

  use Ash.Resource,
    domain: SwarmNode.EchoDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A]

  actions do
    action :ping, :map do
      argument(:from, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok,
         %{
           node: to_string(node()),
           from: input.arguments.from,
           replied_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}
      end)
    end
  end

  a2a do
    skill(:ping, :ping, consequence: :observe)
  end
end

defmodule SwarmNode.EchoDomain do
  @moduledoc "Real domain for `SwarmNode.Echo`."

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SwarmNode.Echo)
  end
end
