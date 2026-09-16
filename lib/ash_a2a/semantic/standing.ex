defmodule AshA2A.Semantic.Standing do
  @moduledoc """
  RFC-SA2A-001 S51 -- the standing transition machine at a peer boundary.

  ## The claim this module makes structurally

      Message_A -> Candidate_B -> GraphLaw_B -> O*_B

  and never

      Message_A -> O*_B

  The second path is not merely discouraged here; it is unrepresentable.
  `transition/2` is a total function over a closed transition table, and
  `{:received, :admitted}` is not in it. A caller that tries to promote a
  freshly-received message straight to admitted standing gets
  `{:error, :illegal_standing_transition}`. The ledger
  (`AshA2A.Semantic.Standing.Ledger`) records only transitions this function
  allowed, so a recorded history that skips `:candidate` cannot exist.

  ## The states

    * `:received` -- bytes arrived. Nothing has been decided. This is the
      standing of every inbound message, Semantic A2A or not.
    * `:candidate` -- the bytes parsed into a well-formed envelope carrying
      the negotiated profile. Still decides nothing: a candidate is a
      proposal, and a proposal from a peer is not evidence.
    * `:admitted` -- the *receiving* peer's own engine validated the graph
      against the receiving peer's own shapes. This is `O*`, and it is the
      only state this module treats as semantic truth.
    * `:refused` -- the receiving peer's engine rejected the graph, or a
      structural precondition failed. Terminal.
    * `:unsupported` -- the profile was not negotiated, or the peer cannot
      run admission at all. Distinct from `:refused` on purpose:
      `UNSUPPORTED != REFUSED`. "I did not check" and "I checked and said no"
      are different facts and a receipt must not conflate them.

  Both `:admitted` and `:refused` are terminal: re-admitting an already
  decided envelope is an error, not an idempotent no-op, because a second
  admission would be a second decision with no second observation behind it.
  """

  @type t :: :received | :candidate | :admitted | :refused | :unsupported

  @states [:received, :candidate, :admitted, :refused, :unsupported]

  # The complete, closed transition table. Every edge that exists is here;
  # everything else is illegal by construction.
  @transitions %{
    received: [:candidate, :unsupported, :refused],
    candidate: [:admitted, :refused, :unsupported],
    admitted: [],
    refused: [],
    unsupported: []
  }

  @doc "Every state in the machine."
  @spec states() :: [t()]
  def states, do: @states

  @doc "The legal successors of a state."
  @spec successors(t()) :: [t()]
  def successors(state) when state in @states, do: Map.fetch!(@transitions, state)

  @doc """
  The initial standing of anything that arrives from a peer.

  Always `:received`. There is no option to start elsewhere.
  """
  @spec initial() :: t()
  def initial, do: :received

  @doc """
  Attempts a standing transition.

  Returns `{:ok, to}` for a legal edge, `{:error, :illegal_standing_transition}`
  otherwise. In particular `transition(:received, :admitted)` is an error:
  that edge is exactly `Message_A -> O*_B`.
  """
  @spec transition(t(), t()) :: {:ok, t()} | {:error, :illegal_standing_transition}
  def transition(from, to) when from in @states and to in @states do
    if to in Map.fetch!(@transitions, from) do
      {:ok, to}
    else
      {:error, :illegal_standing_transition}
    end
  end

  def transition(_from, _to), do: {:error, :illegal_standing_transition}

  @doc "Whether a state is terminal (no legal successors)."
  @spec terminal?(t()) :: boolean()
  def terminal?(state) when state in @states, do: successors(state) == []

  @doc """
  Whether a state constitutes admitted semantic state (`O*`).

  Only `:admitted`. Notably `:unsupported` is not admitted, so a peer that
  could not run its engine never gains standing by default.
  """
  @spec admitted?(t()) :: boolean()
  def admitted?(:admitted), do: true
  def admitted?(_), do: false
end

defmodule AshA2A.Semantic.Standing.Ledger do
  @moduledoc """
  Real, observable standing history for one peer.

  A supervised `Agent` process holding the ordered list of standing
  transitions this peer actually performed. It exists so a cross-peer test
  can assert on the receiving peer's *internal* transitions rather than only
  on its reply: a peer whose reply says "admitted" but whose ledger shows no
  `:candidate -> :admitted` edge has not done the thing the reply claims.

  The ledger cannot record an illegal transition. `record/4` runs
  `AshA2A.Semantic.Standing.transition/2` first and appends only on `{:ok,
  _}`, so a history containing `:received` followed directly by `:admitted`
  for one envelope is not producible through this API.
  """

  use Agent

  alias AshA2A.Semantic.Standing

  @type entry :: %{
          envelope_id: String.t(),
          from: Standing.t(),
          to: Standing.t(),
          reason: term(),
          at: integer()
        }

  @doc "Starts a ledger. `:name` registers it for a peer."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    Agent.start_link(fn -> [] end, Keyword.take(opts, [:name]))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc """
  Records one standing transition, refusing illegal ones.

  Returns `{:ok, to}` and appends, or `{:error, :illegal_standing_transition}`
  and appends nothing.
  """
  @spec record(Agent.agent(), String.t(), {Standing.t(), Standing.t()}, term()) ::
          {:ok, Standing.t()} | {:error, :illegal_standing_transition}
  def record(ledger, envelope_id, {from, to}, reason \\ nil) do
    case Standing.transition(from, to) do
      {:ok, ^to} ->
        entry = %{
          envelope_id: envelope_id,
          from: from,
          to: to,
          reason: reason,
          at: System.monotonic_time()
        }

        Agent.update(ledger, fn entries -> entries ++ [entry] end)
        {:ok, to}

      {:error, _} = error ->
        error
    end
  end

  @doc "All recorded transitions, oldest first."
  @spec entries(Agent.agent()) :: [entry()]
  def entries(ledger), do: Agent.get(ledger, & &1)

  @doc "Recorded transitions for one envelope, oldest first."
  @spec entries(Agent.agent(), String.t()) :: [entry()]
  def entries(ledger, envelope_id) do
    ledger
    |> entries()
    |> Enum.filter(&(&1.envelope_id == envelope_id))
  end

  @doc """
  The ordered standing path for one envelope, e.g.
  `[:received, :candidate, :admitted]`.
  """
  @spec path(Agent.agent(), String.t()) :: [Standing.t()]
  def path(ledger, envelope_id) do
    case entries(ledger, envelope_id) do
      [] -> []
      [first | _] = transitions -> [first.from | Enum.map(transitions, & &1.to)]
    end
  end

  @doc "The current standing of one envelope, or `nil` if unseen."
  @spec current(Agent.agent(), String.t()) :: Standing.t() | nil
  def current(ledger, envelope_id) do
    case path(ledger, envelope_id) do
      [] -> nil
      path -> List.last(path)
    end
  end

  @doc "Clears the ledger. Test-setup convenience only."
  @spec reset(Agent.agent()) :: :ok
  def reset(ledger), do: Agent.update(ledger, fn _ -> [] end)
end
