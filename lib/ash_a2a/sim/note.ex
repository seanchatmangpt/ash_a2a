# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Compiled only when Bandit is available, like the rest of the simulation
# server (see AshA2A.Sim.Server).
if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.Note do
    @moduledoc """
    The simulation server's resource: an ETS-backed note store that exposes one
    skill for every action type and every consequence class the `a2a` DSL
    supports.

    | Skill | Ash action | Consequence | Gate |
    |---|---|---|---|
    | `list_notes` | `:read` | `:observe` | authentication only |
    | `create_note` | `:create` | `:change` | standing authority grant |
    | `update_note` | `:update` | `:change` | standing authority grant |
    | `delete_note` | `:destroy` | `:change` | standing authority grant |
    | `count_notes` | generic `:count_notes` | `:observe` | authentication only |
    | `ping` | generic `:ping` | `:observe` | authentication only; `reply :message` |
    | `slow_count` | generic `:slow_count` | `:observe` | authentication only |
    | `step_up` | generic `:step_up` | `:observe` | authentication only |
    | `publish_note` | generic `:publish_note` | `:external_do` | standing authority grant |
    | `unclassified_note` | generic `:unclassified_note` | `:unknown` | always refused |
    | `bad_reply` | generic `:bad_reply` | `:observe` | authentication only; answers with a non-A2A value (`-32006`) |

    `slow_count` sleeps for `delay_ms` before answering, which gives a client a
    task that is still running when it asks to cancel it. `step_up` parks its
    task at auth-required until the caller sends an `otp`. `publish_note` appends
    to `publications/0`, a list kept outside the Ash data layer, so the
    `:external_do` effect can be observed separately from the note rows.

    Read the rows directly with `Ash.read!(AshA2A.Sim.Note, authorize?: false)`
    to confirm what a wire call changed.
    """

    use Ash.Resource,
      domain: AshA2A.Sim.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshA2A]

    @publications {__MODULE__, :publications}

    attributes do
      uuid_primary_key :id
      attribute :title, :string, public?: true, allow_nil?: false
      attribute :body, :string, public?: true
      create_timestamp :inserted_at
      update_timestamp :updated_at
    end

    actions do
      defaults [:read]

      create :create do
        accept [:title, :body]
      end

      update :update do
        accept [:title, :body]
      end

      destroy :destroy

      action :count_notes, :map do
        run fn _input, _context ->
          {:ok, %{count: length(Ash.read!(__MODULE__, authorize?: false))}}
        end
      end

      action :ping, :map do
        argument :echo, :string

        run fn input, _context ->
          {:ok, %{pong: input.arguments[:echo] || "pong"}}
        end
      end

      action :slow_count, :map do
        argument :delay_ms, :integer, allow_nil?: false, constraints: [min: 0, max: 60_000]

        run fn input, _context ->
          # SLEEP-CLASS: SCHEDULING — simulated work interval declared by the caller
          Process.sleep(input.arguments.delay_ms)
          {:ok, %{count: length(Ash.read!(__MODULE__, authorize?: false))}}
        end
      end

      action :publish_note, :map do
        argument :title, :string, allow_nil?: false

        run fn input, _context ->
          __MODULE__.record_publication(input.arguments.title)
          {:ok, %{published: input.arguments.title}}
        end
      end

      action :step_up, :term do
        argument :otp, :string, allow_nil?: true

        run fn input, _context ->
          case input.arguments[:otp] do
            nil ->
              {:ok,
               {:auth_required, [AshA2A.Protocol.Part.Text.new("send the one-time code as otp")]}}

            _otp ->
              {:ok, %{stepped_up: true}}
          end
        end
      end

      action :unclassified_note, :map do
        run fn _input, _context -> {:ok, %{ran: true}} end
      end

      # Answers with a value that is not a JSON value (a pid): the dispatcher
      # cannot build an A2A Part from it, so the send is an
      # InvalidAgentResponseError (-32006).
      action :bad_reply, :term do
        run fn _input, _context -> {:ok, %{not_json: self()}} end
      end
    end

    # `lease_required?` needs a real Ash authorizer on the target. The policy is
    # permissive on purpose: the a2a authority gate is the boundary under test.
    policies do
      bypass always() do
        authorize_if always()
      end
    end

    a2a do
      skill :list_notes, :read do
        description "List notes (observe: authentication only)"
      end

      skill :create_note, :create do
        description "Create a note (change: needs a standing authority grant)"
        lease_required? true
      end

      skill :update_note, :update do
        description "Update a note by id (change: needs a standing authority grant)"
        lease_required? true
      end

      skill :delete_note, :destroy do
        description "Delete a note by id (change: needs a standing authority grant)"
        lease_required? true
      end

      skill :count_notes, :count_notes do
        description "Count notes (observe generic action)"
        consequence :observe
      end

      skill :ping, :ping do
        description "Answer with a bare Message and no task (observe; message-only)"
        consequence :observe
        reply(:message)
      end

      skill :slow_count, :slow_count do
        description "Count notes after sleeping delay_ms (observe; cancelable while running)"
        consequence :observe
      end

      skill :step_up, :step_up do
        description "Ask for a one-time code, then answer once it is sent (observe; auth-required)"
        consequence :observe
      end

      skill :publish_note, :publish_note do
        description "Record a publication outside the data layer (external_do)"
        consequence :external_do
        lease_required? true
      end

      skill :bad_reply, :bad_reply do
        description "Answer with a value that is not an A2A part (observe; -32006)"
        consequence :observe
      end

      skill :unclassified_note, :unclassified_note do
        description "A generic action nobody classified (unknown: always refused)"
      end
    end

    @doc "Titles recorded by the `publish_note` skill, oldest first."
    @spec publications() :: [String.t()]
    def publications, do: :persistent_term.get(@publications, [])

    @doc "Forgets every recorded publication."
    @spec reset_publications() :: :ok
    def reset_publications do
      :persistent_term.put(@publications, [])
      :ok
    end

    @doc false
    def record_publication(title) do
      :global.trans({@publications, self()}, fn ->
        :persistent_term.put(@publications, publications() ++ [title])
      end)

      :ok
    end
  end
end
