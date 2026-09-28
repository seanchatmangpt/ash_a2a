defmodule AshA2A.Test.MisbehavingDurableServerProvider do
  @moduledoc """
  API-compatible DurableServer provider whose every operation returns the
  shape stored in this module's `:persistent_term` slot -- a real
  implementation of the provider contract (`AshA2A.Durability.DurableServer`
  substitution seam), not an interaction-verifying mock. Used to drive the
  adapter's result typing through shapes the real `DurableServer.Supervisor`
  can produce (`{:error, ...}`, raises such as the `ArgumentError` from a bad
  child spec, and exits from timed requests) plus undocumented shapes a
  faulty provider could return.
  """

  @slot {__MODULE__, :behavior}

  def set(behavior), do: :persistent_term.put(@slot, behavior)
  def clear, do: :persistent_term.erase(@slot)

  def ensure_started_child(_sup, _spec, _opts), do: behave(:ensure_started_child)
  def rehome_child(_sup, _spec, _opts), do: behave(:rehome_child)
  def terminate_and_cordon_child(_sup, _key, _opts), do: behave(:terminate_and_cordon_child)
  def uncordon_child(_sup, _key), do: behave(:uncordon_child)
  def terminate_and_delete_child(_sup, _key, _timeout), do: behave(:terminate_and_delete_child)
  def lookup(_sup, _key), do: behave(:lookup)

  defp behave(function) do
    case :persistent_term.get(@slot) do
      {:return, value} -> value
      :raise -> raise ArgumentError, "bad child spec for #{function}"
      :exit -> exit({:timeout, {GenServer, :call, [function]}})
      :throw -> throw({:thrown_by, function})
    end
  end
end

defmodule AshA2A.DurableServerProviderResultTest do
  @moduledoc """
  R10: `AshA2A.Durability.DurableServer` must only receipt a provider's
  documented success shapes and must never let a provider raise/exit/throw
  crash the caller.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Durability.DurableServer
  alias AshA2A.{Identity, RuntimeReceipt}
  alias AshA2A.Test.MisbehavingDurableServerProvider, as: Provider

  setup do
    previous = Application.get_env(:ash_a2a, :durable_server_provider)
    Application.put_env(:ash_a2a, :durable_server_provider, Provider)

    on_exit(fn ->
      Provider.clear()

      if is_nil(previous) do
        Application.delete_env(:ash_a2a, :durable_server_provider)
      else
        Application.put_env(:ash_a2a, :durable_server_provider, previous)
      end
    end)

    %{task_id: Identity.task("provider-result-#{System.unique_integer([:positive])}")}
  end

  defp operations(task_id) do
    [
      {:ensure_started_child,
       fn -> DurableServer.ensure_task(:sup, __MODULE__, task_id, %{}) end},
      {:rehome_child, fn -> DurableServer.rehome_task(:sup, __MODULE__, task_id, %{}) end},
      {:terminate_and_cordon_child, fn -> DurableServer.cordon_task(:sup, task_id) end},
      {:uncordon_child, fn -> DurableServer.uncordon_task(:sup, task_id) end},
      {:terminate_and_delete_child, fn -> DurableServer.delete_task(:sup, task_id) end}
    ]
  end

  test "documented success shapes are receipted", %{task_id: task_id} do
    pid = self()

    for {function, call} <- operations(task_id) do
      success =
        if function in [:ensure_started_child, :rehome_child],
          do: {:ok, {pid, %{}}},
          else: :ok

      Provider.set({:return, success})
      assert {:ok, %RuntimeReceipt{operation: ^function}} = call.()
    end
  end

  test "undocumented provider returns are typed errors, never receipts", %{task_id: task_id} do
    for {function, call} <- operations(task_id),
        bad <- [
          :error,
          :ignore,
          nil,
          {:error, :a, :b},
          self(),
          {:ok, :wrong_op_shape},
          {:ok, nil},
          {:ok, {:not_a_pid, %{}}}
        ] do
      # `{:ok, {pid, meta}}` with a real pid is the only ensure/rehome success
      # shape; `{:ok, nil}` / `{:ok, :atom}` name no started process.
      Provider.set({:return, bad})

      assert {:error, {:unexpected_provider_result, ^function, ^bad}} = call.(),
             "#{function} receipted #{inspect(bad)}"
    end

    # The `:ok`-returning operations do not accept a bare `:ok` for ensure/rehome.
    Provider.set({:return, :ok})

    assert {:error, {:unexpected_provider_result, :ensure_started_child, :ok}} =
             DurableServer.ensure_task(:sup, __MODULE__, task_id, %{})
  end

  test "provider {:error, _} passes through unchanged", %{task_id: task_id} do
    Provider.set({:return, {:error, :not_found}})

    for {_function, call} <- operations(task_id) do
      assert {:error, :not_found} = call.()
    end
  end

  test "provider raise, exit and throw become typed errors instead of crashing the caller",
       %{task_id: task_id} do
    for {function, call} <- operations(task_id) do
      Provider.set(:raise)
      assert {:error, {:durable_server_raised, ^function, message}} = call.()
      assert message =~ "bad child spec"

      Provider.set(:exit)
      assert {:error, {:durable_server_exit, ^function, {:timeout, _}}} = call.()

      Provider.set(:throw)
      assert {:error, {:durable_server_throw, ^function, {:thrown_by, ^function}}} = call.()
    end

    Provider.set(:exit)
    assert {:error, {:durable_server_exit, :lookup, _}} = DurableServer.lookup(:sup, task_id)
  end
end
