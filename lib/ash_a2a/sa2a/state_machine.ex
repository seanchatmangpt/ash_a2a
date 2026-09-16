defmodule AshA2A.SA2A.StateMachine do
  @moduledoc """
  The RFC S41 admission-state-machine **prefix** that the conformance court
  proves portable:

      RECEIVED -> PARSED -> IDENTIFIED -> STRUCTURALLY_VALID
               -> SEMANTICALLY_VALID -> CLOSED -> FALSIFIER_CLEAN -> ADMITTED

  ## Scope: this prefix stops at ADMITTED, deliberately

  Nothing beyond `ADMITTED` is evaluated here. No command is dispatched, no
  authority is consulted, no receipt is claimed, `AshA2A.CommandBus` is never
  touched. Actuation would put an HTTP client or a database adapter inside
  the measurement, and a flaky one of those would contaminate evidence that
  is supposed to be about GraphLaw portability and nothing else. Authority
  and the BRCE consequence boundary are a separate, later qualification.

  ## Every hop is decided by real engine output

  No hop is assumed. Each reads a specific field of the real
  `validate_all/5` or `run_hooks/2` payload the runtime returned:

    * `PARSED` -- `graph_hash(base)` returned a 64-char hex digest rather
      than the `{"error": ...}` JSON GraphLaw returns instead of raising.
    * `IDENTIFIED` -- the `graph_hash` field *inside* the `validate_all/5`
      result equals that digest. Two independent paths through the engine
      identified the same graph.
    * `STRUCTURALLY_VALID` -- the `SHACL` dialect did not report a refusal.
    * `SEMANTICALLY_VALID` -- the `SHEX` dialect did not report a refusal.
    * `CLOSED` -- the `DATALOG` dialect admitted its materialisation and
      `OWL_RL` did not refuse.
    * `FALSIFIER_CLEAN` -- the `N3_DENIAL` dialect found no denial
      violations, and replay verification agreed with itself
      (`first_hash == second_hash`).
    * `ADMITTED` -- `run_hooks/2` reported `ADMITTED`.

  `UNSUPPORTED` and `PROFILE_NOT_ADMITTED` are *not* failures: they are how
  GraphLaw reports "no shapes/schema/profile were provided for this vector".
  A vector that supplies no SHACL shapes has nothing to be structurally
  invalid against. Both runtimes must nonetheless report the identical
  status, which the court checks via the state trace.
  """

  @order [
    :received,
    :parsed,
    :identified,
    :structurally_valid,
    :semantically_valid,
    :closed,
    :falsifier_clean,
    :admitted
  ]

  @non_refusal ~w(ADMITTED UNSUPPORTED PROFILE_NOT_ADMITTED)

  @typedoc "The outcome of evaluating the S41 prefix for one vector in one runtime."
  @type t :: %{
          admission: :admitted | :refused,
          reached: atom(),
          trace: [String.t()],
          typed_reason: String.t() | nil
        }

  @doc "The full S41 prefix, in order."
  @spec states() :: [atom()]
  def states, do: @order

  @doc """
  Evaluates the prefix against one runtime's real outputs.

  `input_graph_hash` is the raw `graph_hash(base)` return value,
  `validation` the decoded `validate_all/5` result, `hooks` the decoded
  `run_hooks/2` result. Either decoded payload may be `{:error, reason}`,
  which refuses at the hop that needed it rather than crashing.
  """
  @spec evaluate(String.t(), {:ok, map()} | {:error, term()}, {:ok, map()} | {:error, term()}) ::
          t()
  def evaluate(input_graph_hash, validation, hooks) do
    steps = [
      {:parsed, fn -> parsed(input_graph_hash) end},
      {:identified, fn -> identified(input_graph_hash, validation) end},
      {:structurally_valid, fn -> dialect(validation, "SHACL") end},
      {:semantically_valid, fn -> dialect(validation, "SHEX") end},
      {:closed, fn -> closed(validation) end},
      {:falsifier_clean, fn -> falsifier_clean(validation) end},
      {:admitted, fn -> admitted(hooks) end}
    ]

    walk(steps, :received, ["RECEIVED"])
  end

  defp walk([], reached, trace),
    do: %{admission: :admitted, reached: reached, trace: Enum.reverse(trace), typed_reason: nil}

  defp walk([{state, check} | rest], _reached, trace) do
    label = state |> Atom.to_string() |> String.upcase()

    case check.() do
      {:ok, note} ->
        walk(rest, state, ["#{label}(#{note})" | trace])

      {:refused, reason} ->
        %{
          admission: :refused,
          reached: previous(state),
          trace: Enum.reverse(["#{label}=REFUSED(#{reason})" | trace]),
          typed_reason: "#{label}:#{reason}"
        }
    end
  end

  defp previous(state) do
    index = Enum.find_index(@order, &(&1 == state))
    Enum.at(@order, max(index - 1, 0))
  end

  defp parsed(hash) do
    if hex64?(hash) do
      {:ok, "hex64"}
    else
      {:refused, "GRAPH_HASH_NOT_HEX:#{truncate(hash)}"}
    end
  end

  defp identified(hash, {:ok, validation}) do
    case Map.get(validation, "graph_hash") do
      ^hash -> {:ok, "graph_hash_agrees"}
      other -> {:refused, "IDENTITY_MISMATCH:#{truncate(to_string(other))}"}
    end
  end

  defp identified(_hash, {:error, reason}),
    do: {:refused, "VALIDATION_UNAVAILABLE:#{inspect(reason)}"}

  defp dialect({:ok, validation}, name) do
    case find_dialect(validation, name) do
      nil ->
        {:refused, "DIALECT_ABSENT:#{name}"}

      %{"status" => status} = found when status in @non_refusal ->
        {:ok, "#{name}=#{status}|#{Map.get(found, "triples_out")}"}

      %{"status" => status} = found ->
        {:refused, "#{name}:#{status}:#{Map.get(found, "detail")}"}
    end
  end

  defp dialect({:error, reason}, name),
    do: {:refused, "#{name}:VALIDATION_UNAVAILABLE:#{inspect(reason)}"}

  defp closed({:ok, _} = validation) do
    with {:ok, datalog} <- dialect(validation, "DATALOG"),
         {:ok, owl} <- dialect(validation, "OWL_RL") do
      {:ok, "#{datalog};#{owl}"}
    end
  end

  defp closed({:error, reason}), do: {:refused, "CLOSURE_UNAVAILABLE:#{inspect(reason)}"}

  defp falsifier_clean({:ok, validation} = wrapped) do
    replay = Map.get(validation, "replay", %{})
    first = Map.get(replay, "first_hash")
    second = Map.get(replay, "second_hash")
    status = Map.get(replay, "status")

    cond do
      match?({:refused, _}, dialect(wrapped, "N3_DENIAL")) ->
        {:refused, denial} = dialect(wrapped, "N3_DENIAL")
        {:refused, denial}

      status != "ADMITTED" ->
        {:refused, "REPLAY:#{status}"}

      first != second ->
        {:refused,
         "REPLAY_HASH_DIVERGENCE:#{truncate(to_string(first))}!=#{truncate(to_string(second))}"}

      true ->
        {:ok, "replay=#{status}"}
    end
  end

  defp falsifier_clean({:error, reason}),
    do: {:refused, "FALSIFIER_UNAVAILABLE:#{inspect(reason)}"}

  defp admitted({:ok, hooks}) do
    case Map.get(hooks, "status") do
      "ADMITTED" -> {:ok, "hooks=ADMITTED"}
      other -> {:refused, "HOOKS:#{other}"}
    end
  end

  defp admitted({:error, reason}), do: {:refused, "HOOKS_UNAVAILABLE:#{inspect(reason)}"}

  defp find_dialect(validation, name) do
    validation
    |> Map.get("dialects", [])
    |> List.wrap()
    |> Enum.find(&(Map.get(&1, "dialect") == name))
  end

  defp hex64?(value) when is_binary(value),
    do: byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp hex64?(_), do: false

  defp truncate(value) when is_binary(value), do: String.slice(value, 0, 80)
  defp truncate(value), do: value |> inspect() |> String.slice(0, 80)
end
