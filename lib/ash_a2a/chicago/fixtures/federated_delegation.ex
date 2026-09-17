defmodule AshA2A.Chicago.Fixtures.FederatedDelegation.PeerB do
  @moduledoc """
  The delegate side of the `SA2A-FED` court (RFC-SA2A-001 §54 Confused Deputy
  Prevention, RFC-SA2A-002 §75 transport independence extended to a genuinely
  distinct second peer).

  `:record` is a real `:change` skill through the full real
  `AshA2A.CommandBus` -> `AshA2A.Authority.Grant` -> `AshA2A.Dispatcher` path
  -- exactly the same admission machinery `AshA2A.Chicago.Fixtures.Brce.Ledger`
  uses. The row it writes stamps `principal` from the REAL resolved
  `context.actor` (the transport-verified identity `AshA2A.ContextResolver`
  put there, per `dispatcher.ex:421` / `agent.ex:816` -- `actor:
  exec_context.actor`), never from caller-supplied input, so a court reading
  rows back independently (`Ash.read!/1`) can tell WHICH principal peer B
  itself believes actuated -- the confused-deputy question RFC-SA2A-001 §54
  asks of a federation hop.
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.FederatedDelegation.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
    attribute(:principal, :string, public?: true, allow_nil?: true)
  end

  actions do
    defaults([:read])

    create :record do
      accept([:label])

      change(fn changeset, context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :principal,
          AshA2A.Chicago.Fixtures.FederatedDelegation.actor_identity(context.actor)
        )
      end)
    end
  end

  a2a do
    skill(:record, :record)
  end
end

defmodule AshA2A.Chicago.Fixtures.FederatedDelegation.PeerA do
  @moduledoc """
  The originating side of the `SA2A-FED` court. `:delegate_write` is a real
  `:change` skill: its own action is admitted through peer A's own
  `AshA2A.CommandBus` exactly like any other consequence-bearing skill (it
  writes a real `DelegationLog` row proving peer A's own hop actuated), and
  its real effect is a genuine cross-process A2A call
  (`AshA2A.Chicago.Fixtures.FederatedDelegation.delegate/3`) into a second,
  genuinely distinct real `A2A.Agent` GenServer (peer B) -- never a function
  call into peer B's Ash resource directly, and never a call that mints its
  own authority for peer B.

  The identity forwarded to peer B is `context.actor` -- the SAME
  transport-verified principal peer A's own admission already resolved --
  never a peer-A-owned identity and never something the caller supplied as
  free-form input. This is RFC-SA2A-001 §54's rule made concrete: "A peer
  MUST NOT use its own authority merely because another peer requested an
  operation" -- peer A relays the originating principal, it does not
  substitute itself, and peer B's own `AshA2A.Authority.Grant` broker decides
  -- independently -- whether that principal may actuate `record` on peer B.
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.FederatedDelegation.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :delegate_write, :map do
      argument(:label, :string, allow_nil?: false)
      argument(:peer_b_name, :string, allow_nil?: false)
      argument(:bypass, :boolean, default: false)

      run(fn input, context ->
        {:ok,
         AshA2A.Chicago.Fixtures.FederatedDelegation.delegate(
           input.arguments.label,
           input.arguments.peer_b_name,
           context.actor,
           input.arguments.bypass
         )}
      end)
    end
  end

  a2a do
    skill(:delegate_write, :delegate_write, consequence: :change)
  end
end

defmodule AshA2A.Chicago.Fixtures.FederatedDelegation.DelegationLog do
  @moduledoc """
  Peer A's own real, independently-readable post-state: one row per
  `delegate_write` actuation (never peer B's `PeerB` rows -- a separate real
  resource, so the court can tell peer A's own receipted hop apart from
  whatever peer B independently decided).
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.FederatedDelegation.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
    attribute(:principal, :string, public?: true, allow_nil?: true)
  end

  actions do
    defaults([:read, create: [:label, :principal]])
  end
end

defmodule AshA2A.Chicago.Fixtures.FederatedDelegation.Domain do
  @moduledoc """
  Real fixture domain for the `SA2A-FED` court. `validate_config_inclusion?:
  false` (same convention as every other Chicago fixture domain) keeps `mix
  compile --warnings-as-errors` clean without registering this fixture as a
  host application domain.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Fixtures.FederatedDelegation.PeerB)
    resource(AshA2A.Chicago.Fixtures.FederatedDelegation.PeerA)
    resource(AshA2A.Chicago.Fixtures.FederatedDelegation.DelegationLog)
  end
end

defmodule AshA2A.Chicago.Fixtures.FederatedDelegation.PeerBAgent do
  @moduledoc """
  The generated `use AshA2A.Agent` projection over `PeerB` -- peer B's own
  real supervised `A2A.Agent` GenServer, started per stimulus and registered
  under a unique local name so peer A's action can reach it the same way any
  remote caller would: by name/address, never by importing peer B's Ash
  resource module and calling it in-process.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Chicago.Fixtures.FederatedDelegation.PeerB,
    name: "chicago_fed_peer_b_agent"
end

defmodule AshA2A.Chicago.Fixtures.FederatedDelegation.PeerAAgent do
  @moduledoc "The generated `use AshA2A.Agent` projection over `PeerA` -- peer A's own real supervised process."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Chicago.Fixtures.FederatedDelegation.PeerA,
    name: "chicago_fed_peer_a_agent"
end

defmodule AshA2A.Chicago.Fixtures.FederatedDelegation do
  @moduledoc """
  Shared real cross-peer delegation logic and independent post-state readers
  for the `SA2A-FED` court (federated delegation across two genuinely
  distinct real `A2A.Agent` peer processes).
  """

  alias AshA2A.Chicago.Fixtures.FederatedDelegation.{DelegationLog, PeerB}

  @doc """
  Extracts a stable string identity from whatever shape `context.actor`
  carries (the raw `A2A.Plug.Auth`-verified `auth_identity`, e.g. `%{identity:
  "..."}` or its string-keyed JSON-decoded form) -- never re-derives an
  identity from anything else. `nil` when unauthenticated.
  """
  @spec actor_identity(term()) :: String.t() | nil
  def actor_identity(nil), do: nil
  def actor_identity(id) when is_binary(id), do: id
  def actor_identity(%{identity: id}), do: to_string(id)
  def actor_identity(%{"identity" => id}), do: to_string(id)
  def actor_identity(other), do: inspect(other, limit: 5)

  @doc """
  Real peer-A-side effect of `delegate_write`: persists peer A's own
  `DelegationLog` row (peer A's own consequence -- proof its own hop
  actuated), then either

    * (`bypass: false`, the lawful path) makes a real `A2A.call/3` into peer
      B's named agent process for peer B's `record` skill, forwarding the
      SAME `identity` peer A's own admission resolved (never peer A's own
      identity, never a fresh one) as `"a2a.auth"` metadata -- exactly the
      shape `A2A.Plug.Auth` produces and every other Chicago court's agent
      stimuli already use; or
    * (`bypass: true`, the attack surface CHI-FED-003 attempts) skips peer
      B's own `A2A.Agent`/`AshA2A.CommandBus` front door entirely and calls
      `AshA2A.Dispatcher.dispatch/5` against peer B's `PeerB` resource
      directly -- the exact same bypass surface `CHI-BRCE-001`/`002` already
      attacks in-process, attempted here as if a compromised or buggy peer A
      tried to reach around peer B's own boundary instead of addressing it.
  """
  @spec delegate(String.t(), String.t(), term(), boolean()) :: map()
  def delegate(label, peer_b_name, identity, bypass?) do
    principal = actor_identity(identity)

    {:ok, _log} =
      DelegationLog
      |> Ash.Changeset.for_create(:create, %{label: label, principal: principal})
      |> Ash.create()

    if bypass? do
      reply = bypass_peer_b(label, identity)
      %{"mode" => "bypass", "label" => label, "reply" => inspect(reply, limit: 8)}
    else
      reply = forward_to_peer_b(peer_b_name, label, identity)
      %{"mode" => "forward", "label" => label, "reply" => inspect(reply, limit: 8)}
    end
  end

  defp forward_to_peer_b(peer_b_name, label, identity) do
    case Process.whereis(String.to_existing_atom(peer_b_name)) do
      nil ->
        {:error, :peer_b_unavailable}

      pid ->
        message = A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])
        message = %{message | metadata: %{"skill" => "record"}}
        A2A.call(pid, message, metadata: %{"a2a.auth" => %{identity: identity}})
    end
  rescue
    ArgumentError -> {:error, :peer_b_unavailable}
  end

  # CHI-FED-003's fault surface: reaching peer B's own consequence directly
  # through the dispatcher, bypassing peer B's Agent/CommandBus entirely --
  # never routed through peer B's named agent process at all. `identity` is
  # still the real, legitimately-granted principal (not forged) so this
  # isolates the boundary being tested to "does federation open a shortcut
  # around peer B's own front door", never conflating it with an authority
  # question CHI-FED-002 already covers.
  defp bypass_peer_b(label, identity) do
    message = A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])
    AshA2A.Dispatcher.dispatch(:record, message, PeerB, [], identity)
  end

  @doc "Independent reader: every `PeerB` row currently persisted, as `{label, principal}` pairs."
  @spec peer_b_rows() :: [{String.t(), String.t() | nil}]
  def peer_b_rows, do: PeerB |> Ash.read!() |> Enum.map(&{&1.label, &1.principal})

  @doc "Independent reader: every `DelegationLog` row currently persisted, as `{label, principal}` pairs."
  @spec delegation_log_rows() :: [{String.t(), String.t() | nil}]
  def delegation_log_rows, do: DelegationLog |> Ash.read!() |> Enum.map(&{&1.label, &1.principal})
end
