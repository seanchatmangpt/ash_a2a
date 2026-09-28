defmodule AshA2A.ObanDeliveryDedupTest do
  @moduledoc """
  R11: `AshA2A.Delivery.Oban.enqueue/3` must hold at most one live job per
  admitted command (`command_id` + `fingerprint`), and
  `AshA2A.Delivery.Oban.perform_result/2` must turn a CommandBus claim that
  is still held elsewhere into an Oban snooze instead of a burned attempt.

  Real Postgres-backed `oban_jobs` table and a real `Oban` instance (same
  setup as `oban_delivery_qualification_test.exs`), a real
  `AshA2A.CommandBus` and a real `AshA2A.ReceiptStore.Memory` claim. No
  mocks.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo

  import Ecto.Query

  alias AshA2A.{Command, CommandBus, Delivery, Identity}
  alias AshA2A.Authority.Grant
  alias AshA2A.Test.Support.CommandWorker

  @oban_name AshA2A.Test.ObanDedup
  @capability_id "AshA2A.Test.Fixture.Item.create"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    start_supervised!(AshA2A.Test.Repo)

    case Ecto.Migrator.up(
           AshA2A.Test.Repo,
           20_260_913_000_001,
           AshA2A.Test.Repo.Migrations.AddObanJobsTable,
           log: false
         ) do
      :ok -> :ok
      :already_up -> :ok
    end

    start_supervised!(
      {Oban, name: @oban_name, repo: AshA2A.Test.Repo, queues: [], plugins: false}
    )

    :ok
  end

  setup do
    # Run-unique: oban_jobs rows persist across runs and dedup is by command_id.
    %{
      suffix:
        Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <>
          "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    }
  end

  test "enqueueing the same command twice yields one live job", %{suffix: suffix} do
    command = build_command("dedup-#{suffix}", %{label: "a-#{suffix}"})

    assert {:ok, %Delivery{provider_ref: first_id} = first} = enqueue(command)
    assert first.metadata.deduplicated? == false

    assert {:ok, %Delivery{provider_ref: second_id} = second} = enqueue(command)
    assert second.metadata.deduplicated? == true
    assert second_id == first_id

    assert [_one] = jobs_for(command)
  end

  test "same command_id with different content is not absorbed", %{suffix: suffix} do
    a = build_command("conflict-#{suffix}", %{label: "a-#{suffix}"})

    b =
      %{a | input: %{label: "b-#{suffix}"}} |> then(&%{&1 | fingerprint: Command.fingerprint(&1)})

    refute a.fingerprint == b.fingerprint

    assert {:ok, %Delivery{provider_ref: a_id}} = enqueue(a)
    assert {:ok, %Delivery{provider_ref: b_id} = b_delivery} = enqueue(b)
    refute a_id == b_id
    assert b_delivery.metadata.deduplicated? == false
    assert length(jobs_for(a)) == 2
  end

  test "a discarded job does not block a legitimate re-enqueue", %{suffix: suffix} do
    command = build_command("discarded-#{suffix}", %{label: "d-#{suffix}"})

    assert {:ok, %Delivery{provider_ref: first_id}} = enqueue(command)

    AshA2A.Test.Repo.update_all(
      from(j in Oban.Job, where: j.id == ^first_id),
      set: [state: "discarded", discarded_at: DateTime.utc_now()]
    )

    assert {:ok, %Delivery{provider_ref: second_id} = second} = enqueue(command)
    refute second_id == first_id
    assert second.metadata.deduplicated? == false
  end

  test "callers can opt out with job_opts unique: false", %{suffix: suffix} do
    command = build_command("optout-#{suffix}", %{label: "o-#{suffix}"})

    opts = [name: @oban_name, job_opts: [queue: :commands, unique: false]]
    assert {:ok, %Delivery{provider_ref: a}} = Delivery.Oban.enqueue(CommandWorker, command, opts)
    assert {:ok, %Delivery{provider_ref: b}} = Delivery.Oban.enqueue(CommandWorker, command, opts)
    refute a == b
    assert length(jobs_for(command)) == 2
  end

  test "a real in-flight CommandBus claim maps to a snooze, not a burned attempt",
       %{suffix: suffix} do
    command = build_command("inflight-#{suffix}", %{label: "i-#{suffix}"})
    store = CommandBus.default_store()

    # A real claim held by a first executor that has not committed yet.
    assert {:execute, _execution_id} = store.claim(command, [])

    message = A2A.Message.new_user([A2A.Part.Data.new(%{"label" => "i-#{suffix}"})])
    result = CommandBus.run(command, message, AshA2A.Test.Fixture.Item)

    assert {:error, %{code: :in_flight}} = result
    assert {:snooze, 30} = Delivery.Oban.perform_result(result)
    assert {:snooze, 5} = Delivery.Oban.perform_result(result, 5)
  end

  test "perform_result/2 passes success and other refusals through" do
    assert :ok = Delivery.Oban.perform_result(:ok)
    assert :ok = Delivery.Oban.perform_result({:ok, :receipt})
    assert {:snooze, 30} = Delivery.Oban.perform_result({:error, :in_flight})
    assert {:snooze, 30} = Delivery.Oban.perform_result({:error, %{code: :actuation_in_flight}})

    assert {:error, %{code: :command_conflict}} =
             Delivery.Oban.perform_result({:error, %{code: :command_conflict}})

    assert {:error, {:unexpected_command_bus_result, :weird}} =
             Delivery.Oban.perform_result(:weird)
  end

  defp enqueue(command) do
    Delivery.Oban.enqueue(CommandWorker, command,
      name: @oban_name,
      job_opts: [queue: :commands]
    )
  end

  defp jobs_for(command) do
    command_id = Identity.external(command.command_id)

    AshA2A.Test.Repo.all(
      from(j in Oban.Job,
        where: fragment("?->>'command_id' = ?", j.args, ^command_id),
        where: j.state not in ["cancelled", "discarded"]
      )
    )
  end

  defp build_command(command_id, input) do
    principal = Identity.principal("subject-#{command_id}")
    {:ok, authority} = Grant.grant(principal, @capability_id)

    Command.new(@capability_id,
      command_id: command_id,
      agent_id: "agent-#{command_id}",
      principal_id: principal,
      authority: authority,
      input: input
    )
  end
end
