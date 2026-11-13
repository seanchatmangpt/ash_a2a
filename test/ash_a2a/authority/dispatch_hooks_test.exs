# SPDX-License-Identifier: MIT

defmodule AshA2A.DispatchHooksFixtures.Item do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.DispatchHooksFixtures.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :ping, :string do
      run(fn _input, _context -> {:ok, "pong"} end)
    end
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end

  a2a do
    skill(:ping, :ping, consequence: :observe)
  end

  authority do
    gate(:disabled)
  end

  hooks do
    pre_dispatch([:pre_hook])
    post_dispatch([:post_hook])
  end
end

defmodule AshA2A.DispatchHooksFixtures.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DispatchHooksFixtures.Item)
  end
end

defmodule AshA2A.DispatchHooksFixtures.Hooks do
  @moduledoc false
  def pre(event), do: relay(:pre, event)
  def post(event), do: relay(:post, event)
  def deny(_event), do: {:error, :nope}

  defp relay(tag, event) do
    send(:dispatch_hooks_sink, {tag, event.phase, event.skill_id})
    :ok
  end
end

defmodule AshA2A.DispatchHooksTest do
  use ExUnit.Case, async: false

  alias AshA2A.DispatchHooksFixtures.{Hooks, Item}

  setup do
    Process.register(self(), :dispatch_hooks_sink)
    old = Application.get_env(:ash_a2a, :dispatch_hooks)
    on_exit(fn ->
      if old, do: Application.put_env(:ash_a2a, :dispatch_hooks, old),
        else: Application.delete_env(:ash_a2a, :dispatch_hooks)
    end)
    :ok
  end

  defp msg, do: AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

  test "gate and both hooks are read by the dispatcher and fire" do
    assert AshA2A.Info.authority_gate(Item) == :disabled
    Application.put_env(:ash_a2a, :dispatch_hooks, %{pre_hook: {Hooks, :pre}, post_hook: {Hooks, :post}})

    assert {:reply, _} = AshA2A.Dispatcher.dispatch(:ping, msg(), Item)
    assert_received {:pre, :pre_dispatch, _}
    assert_received {:post, :post_dispatch, _}
  end

  test "pre hook denial refuses before execution; unresolved hook fails closed" do
    Application.put_env(:ash_a2a, :dispatch_hooks, %{pre_hook: {Hooks, :deny}, post_hook: {Hooks, :post}})
    assert {:error, {:pre_dispatch_hook, {:pre_hook, :nope}}} = AshA2A.Dispatcher.dispatch(:ping, msg(), Item)
    refute_received {:post, _, _}

    Application.delete_env(:ash_a2a, :dispatch_hooks)
    assert {:error, {:pre_dispatch_hook, {:pre_hook, :hook_unresolved}}} =
             AshA2A.Dispatcher.dispatch(:ping, msg(), Item)
  end
end

defmodule AshA2A.DisabledGateTopologyTest do
  use ExUnit.Case, async: false

  # gate(:disabled) is enforced at compile time for exposed :change/:external_do skills
  # (AshA2A.Verify topology) and at dispatch for anchored skills; a compile-valid
  # :disabled resource can therefore only host :observe skills, so the refusal that
  # is reachable and observable is the compile-time one.
  test "gate :disabled with a :change skill is refused at compile time" do
    src = """
    defmodule AshA2A.DisabledGateTopologyTest.Bad do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshA2A]

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:read])
        action :mutate, :string do
          run(fn _i, _c -> {:ok, "x"} end)
        end
      end

      a2a do
        skill(:mutate, :mutate, consequence: :change)
      end

      authority do
        gate(:disabled)
      end
    end
    """

    # The refusal surfaces either as a raised error or (Spark verifiers run in
    # after_verify) as a compiler diagnostic; collect both channels.
    {result, diagnostics} =
      Code.with_diagnostics([log: false], fn ->
        try do
          Code.compile_string(src)
          nil
        rescue
          e -> Exception.message(e)
        end
      end)

    err =
      [result | Enum.map(diagnostics, & &1.message)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    assert err =~ "requires an active gate"
  end
end
