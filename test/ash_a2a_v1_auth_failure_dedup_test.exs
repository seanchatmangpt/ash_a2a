# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Lane ERRC-1 court: the duplicated `auth_failure?/1` clause family in
# `AshA2A.Transport.Runtime` is eliminated.
#
# Part (a) is structural: the lib source is parsed and the AST walked, so the
# check holds against the REAL compiled module definition (not a regex).
# Part (b) is behavioral, Chicago-style: a real `use AshA2A.Agent` GenServer
# runs the full `AshA2A.Transport.Runtime` path (`handle_message_call/6` ->
# `prepare_task/5` -> `spawn_worker` -> `run_handler/3` -> `finish/5` ->
# `apply_reply/2`) over the three wire shapes the classifier served --
# auth-required mapping, rejected mapping, fallback false -- with real
# state-based assertions on the returned and re-fetched task structs.
# No Mock/mox/patch/monkeypatch.

defmodule AshA2A.Errc1AuthFailureDedup.Fixture do
  @moduledoc """
  Real ETS fixture resource backing the transport-runtime agent below. Its
  generic action is never dispatched (the agent overrides `handle_message/2`
  to emit the direct error-contract shapes), but the `use AshA2A.Agent` card
  build reads its compiled capability index -- the same pattern as the
  `AshA2A.V1AuthRequired.Fixture` fixture in
  `test/ash_a2a_v1_auth_required_state_test.exs`.
  """

  use Ash.Resource,
    domain: AshA2A.Errc1AuthFailureDedup.FixtureDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      run(fn _input, _context ->
        {:ok, %{text: "ok"}}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.Errc1AuthFailureDedup.FixtureDomain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Errc1AuthFailureDedup.Fixture)
  end
end

defmodule AshA2A.Errc1AuthFailureDedup.TransportAgent do
  @moduledoc """
  Real `use AshA2A.Agent` GenServer whose `handle_message/2` emits the exact
  error shapes the transport classifier (`apply_reply/2`'s cond) maps:

  * `{:error, {:auth_required, _}}` -- the parked, resumable `:auth_required`
    producer (auth-required mapping).
  * `{:error, :forbidden}` -- the refusal-before-effect producer (rejected
    mapping, via `admission_refusal?/1` ahead of the classifier in the same
    cond).
  * `{:error, {:domain_specific, _}}` -- an unclassified error (fallback
    false: terminal `:failed`).

  The override changes WHO emits the tuple, not the machinery under test:
  the message still runs the full real `AshA2A.Transport.Runtime` path that
  carries the surviving single `auth_failure?/1` family.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Errc1AuthFailureDedup.Fixture,
    name: "errc1_auth_failure_dedup_transport_agent"

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _context) do
    case AshA2A.Protocol.Message.text(message) do
      "expired" ->
        {:error, {:auth_required, "credentials expired"}}

      "forbidden" ->
        {:error, :forbidden}

      "unclassified" ->
        {:error, {:domain_specific, "boom"}}

      text ->
        {:reply, [AshA2A.Protocol.Part.Text.new("ok: " <> text)]}
    end
  end
end

defmodule AshA2A.V1AuthFailureDedupTest do
  @moduledoc """
  Structural court: exactly ONE `auth_failure?/1` definition family in
  `AshA2A.Transport.Runtime`, one call site in `apply_reply/2`'s cond, and
  the sibling `admission_refusal?/1` family untouched.
  """

  use ExUnit.Case, async: true

  @runtime_source (fn ->
                     path = Path.expand("../lib/ash_a2a/transport/runtime.ex", __DIR__)
                     File.read!(path)
                   end).()

  @runtime_ast Code.string_to_quoted!(@runtime_source)

  defp defp_clauses(ast, name, arity) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:defp, _meta, [{^name, _, args} = head, _body]} = form, acc ->
          if length(args || []) == arity do
            {form, [head | acc]}
          else
            {form, acc}
          end

        form, acc ->
          {form, acc}
      end)

    Enum.reverse(acc)
  end

  defp call_sites(ast, name, arity) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {^name, _meta, args} = call, acc when is_list(args) and length(args) == arity ->
          {call, [call | acc]}

        form, acc ->
          {form, acc}
      end)

    Enum.reverse(acc)
  end

  test "exactly one auth_failure?/1 definition family (four clauses)" do
    heads = defp_clauses(@runtime_ast, :auth_failure?, 1)
    assert length(heads) == 4
  end

  test "no duplicated clause patterns inside the family" do
    heads = defp_clauses(@runtime_ast, :auth_failure?, 1)
    patterns = Enum.map(heads, &elem(&1, 0))
    assert Enum.uniq(patterns) == patterns
  end

  test "exactly one auth_failure?/1 call site (the cond guard in apply_reply/2)" do
    # defp heads are patterns, not calls, but the walk above catches both
    # name/arity shapes; exclude the definition heads by filtering to the
    # guard form `auth_failure?(reason)` inside the cond.
    sites = call_sites(@runtime_ast, :auth_failure?, 1)
    assert Enum.count(sites, fn {_name, _meta, args} -> match?([{^:reason, _, nil}], args) end) == 1
  end

  test "sibling admission_refusal?/1 family is untouched (seven clauses, unique)" do
    heads = defp_clauses(@runtime_ast, :admission_refusal?, 1)
    assert length(heads) == 7
    patterns = Enum.map(heads, &elem(&1, 0))
    assert Enum.uniq(patterns) == patterns
  end

  test "no defp clause family in the module duplicates a head pattern" do
    # Regression guard for the exact defect class removed here: two adjacent,
    # identical `defp` clause families surviving as dead code.
    families =
      @runtime_ast
      |> Macro.prewalk(%{}, fn
        {:defp, _, [{name, _, args} = head, _]} = form, acc when is_atom(name) ->
          arity = length(args || [])
          {form, Map.update(acc, {name, arity}, [elem(head, 0)], &[elem(head, 0) | &1])}

        form, acc ->
          {form, acc}
      end)
      |> elem(1)

    for {_key, patterns} <- families do
      assert Enum.uniq(patterns) == patterns
    end
  end
end

defmodule AshA2A.V1AuthFailureDedupBehaviorTest do
  @moduledoc """
  Behavioral court: the surviving single `auth_failure?/1` family still
  answers correctly for the wire shapes it served, through the REAL
  transport-runtime path (real GenServer, real off-mailbox worker, real
  `apply_reply/2` classification, SEC-08 redaction).
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{Message, Task}

  setup do
    name = :"errc1_dedup_transport_#{System.unique_integer([:positive])}"
    {:ok, pid} = AshA2A.Errc1AuthFailureDedup.TransportAgent.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, agent: name}
  end

  defp call(agent, text), do: AshA2A.Errc1AuthFailureDedup.TransportAgent.call(agent, Message.new_user(text))

  test "auth-required mapping: {:error, {:auth_required, _}} parks :auth_required (redacted)", %{
    agent: agent
  } do
    assert {:ok, task} = call(agent, "expired")

    assert task.status.state == :auth_required
    refute Task.terminal?(task)

    # SEC-08: the reason is redacted before it becomes the wire-visible
    # status message.
    assert %Message{role: :agent} = status_msg = task.status.message
    [text_part] = status_msg.parts
    assert text_part.text =~ "Auth required:"
    assert text_part.text =~ "auth_required"

    assert {:ok, %Task{status: %{state: :auth_required}}} =
             AshA2A.Errc1AuthFailureDedup.TransportAgent.get_task(agent, task.id)
  end

  test "rejected mapping: {:error, :forbidden} lands terminal :rejected", %{agent: agent} do
    assert {:ok, task} = call(agent, "forbidden")

    assert task.status.state == :rejected
    assert Task.terminal?(task)

    assert %Message{role: :agent} = status_msg = task.status.message
    [text_part] = status_msg.parts
    assert text_part.text =~ "Rejected:"
    assert text_part.text =~ "forbidden"
  end

  test "fallback false: unclassified {:error, _} lands terminal :failed", %{agent: agent} do
    assert {:ok, task} = call(agent, "unclassified")

    assert task.status.state == :failed
    assert Task.terminal?(task)

    assert %Message{role: :agent} = status_msg = task.status.message
    [text_part] = status_msg.parts
    assert text_part.text =~ "Error:"
    refute text_part.text =~ "Auth required:"
    refute text_part.text =~ "Rejected:"
  end
end
