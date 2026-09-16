defmodule AshA2A.Postcondition do
  @moduledoc """
  Independent postcondition observation for the consequence path
  (RFC-SA2A-002 §8, §39, §73).

  The actuator must not be the sole attestor of its own success:

      ActuatorReport ≠ PostconditionObservation

  A caller of `AshA2A.CommandBus.run/4` declares the intended effect of a
  consequence-bearing command as a postcondition:

      postcondition = %AshA2A.Postcondition{
        id: "ledger.value_persisted",
        verifier: MyApp.LedgerVerifier,
        expect: %{key: "k1", value: "v1"}
      }

      AshA2A.CommandBus.run(command, message, MyResource, postcondition: postcondition)

  `:expect` is the intended effect, derived by the caller from the command it
  submits -- never from the dispatch reply. After dispatch, the bus evaluates
  `c:verify/2` and records exactly one of

    * `:verified` -- an independent post-state read matches the intended effect
    * `:contradicted` -- an independent post-state read refutes it
    * `:unverified` -- no postcondition was declared, the actuator made no
      success claim, the verifier crashed/timed out/returned garbage, or the
      verifier's verdict was not independent of the actuator's report

  in `receipt.metadata.postcondition`, and emits
  `[:ash_a2a, :command_bus, :postcondition]` telemetry. A `:contradicted`
  postcondition never yields completed standing: the receipt status becomes
  `:postcondition_contradicted` (the contradiction itself is still committed
  as evidence) and `run/4` returns `{:error, %{code:
  :postcondition_contradicted}}`. A missing postcondition is recorded as
  `:unverified`, never as `:verified`.

  ## Independence

  The verifier runs in a separately spawned process (no access to the
  dispatching process's state) and is handed a `AshA2A.Postcondition.Probe`
  carrying command identity and the actuator's report. Independence is then
  checked, not assumed: the bus evaluates the verifier a second time with the
  actuator's report replaced by a contradicting counterfactual failure report
  while post-state is held fixed. A verifier that reads post-state reaches
  the same verdict both times. A verifier whose verdict tracks the report --
  e.g. one that only reads the actuator's return object -- changes its verdict,
  and the observation is recorded as `:unverified` with reason
  `:verifier_not_independent` (§73: "A verifier that reads only the
  actuator's return object is not independent").

  Consequences of that rule, stated so they are not silently assumed:

    * the verdict must be a function of `:expect` and independently read
      post-state; a verifier that *verifies* by comparing the report with
      state is flagged non-independent (it may still use the report to refine
      a contradiction);
    * a concurrent writer changing post-state between the two reads can make
      an independent verifier look dependent -- that fails closed to
      `:unverified`, never to `:verified`;
    * a verifier engineered to recognise the counterfactual report can evade
      the check; the check detects report dependence, not deliberate
      deception. The Chicago court (`CHI-POST`) qualifies discrimination
      against real lying and divergent actuators.
  """

  alias AshA2A.Receipt

  @enforce_keys [:id, :verifier]
  defstruct [:id, :verifier, expect: nil]

  @type status :: :verified | :contradicted | :unverified

  @type t :: %__MODULE__{id: String.t(), verifier: module(), expect: term()}

  @type verdict ::
          {:verified, map()} | {:contradicted, map()} | {:unverified, atom() | String.t()}

  @type observation :: %{
          status: status(),
          reason: atom() | nil,
          postcondition_id: String.t() | nil,
          verifier: String.t() | nil,
          independent: boolean() | nil,
          evidence: map()
        }

  @doc """
  Verifies the intended effect `expect` against post-state read through a path
  independent of the actuator's report. `probe.actuator_report` is available,
  but a verdict that depends on it is detected and not accepted (see moduledoc).
  """
  @callback verify(expect :: term(), AshA2A.Postcondition.Probe.t()) :: verdict()

  defmodule Probe do
    @moduledoc """
    What a postcondition verifier is handed: command identity, the command's
    own input, and the actuator's report. It deliberately carries no reader --
    the verifier instantiates its own.
    """
    defstruct [
      :command_id,
      :capability_id,
      :execution_id,
      :receipt_id,
      :consequence,
      :command_input,
      :actuator_report
    ]

    @type t :: %__MODULE__{}
  end

  @default_timeout_ms 5_000

  @doc false
  def __sa2a_refusal_codes__, do: %{postcondition_contradicted: :refused_meta_rigor}

  @doc """
  Evaluates `postcondition` (or its absence) for one dispatched command.

  Returns `nil` only for a non-consequence-bearing (`:observe`) command with no
  declared postcondition -- there is no consequence claim to observe.
  Options: `:postcondition_timeout_ms` (default #{@default_timeout_ms}).
  """
  @spec evaluate(t() | nil, Probe.t(), keyword()) :: observation() | nil
  def evaluate(nil, %Probe{consequence: :observe}, _opts), do: nil

  def evaluate(nil, %Probe{}, _opts),
    do: observation(:unverified, :no_postcondition_declared, nil, nil, %{})

  def evaluate(%__MODULE__{verifier: verifier} = pc, %Probe{} = probe, opts)
      when is_atom(verifier) do
    timeout = Keyword.get(opts, :postcondition_timeout_ms, @default_timeout_ms)

    cond do
      not (Code.ensure_loaded?(verifier) and function_exported?(verifier, :verify, 2)) ->
        observation(:unverified, :verifier_not_implemented, pc, nil, %{})

      not success_claim?(probe.actuator_report) ->
        observation(:unverified, :no_success_claim, pc, nil, %{})

      true ->
        actual = run_isolated(verifier, pc.expect, probe, timeout)

        counterfactual =
          run_isolated(verifier, pc.expect, counterfactual_probe(probe), timeout)

        judge(pc, actual, counterfactual)
    end
  end

  def evaluate(%__MODULE__{} = pc, %Probe{}, _opts),
    do: observation(:unverified, :verifier_not_implemented, pc, nil, %{})

  @doc """
  Records `observation` on the receipt. `:contradicted` replaces a completed
  status with `:postcondition_contradicted` -- a refuted success claim never
  keeps completed standing.
  """
  @spec apply_to_receipt(Receipt.t(), observation() | nil) :: Receipt.t()
  def apply_to_receipt(%Receipt{} = receipt, nil), do: receipt

  def apply_to_receipt(%Receipt{} = receipt, %{status: :contradicted} = observation) do
    AshA2A.Receipt.Binding.transition(
      receipt,
      %{
        receipt
        | status: :postcondition_contradicted,
          metadata: Map.put(receipt.metadata, :postcondition, observation)
      },
      :postcondition
    )
  end

  def apply_to_receipt(%Receipt{} = receipt, observation),
    do:
      AshA2A.Receipt.Binding.transition(
        receipt,
        %{receipt | metadata: Map.put(receipt.metadata, :postcondition, observation)},
        :postcondition
      )

  @doc """
  Shapes the consequence result: a committed receipt whose postcondition was
  contradicted is returned as an error, not `{:ok, receipt}`.
  """
  @spec consequence_result(term(), observation() | nil) :: term()
  def consequence_result({:ok, %Receipt{} = receipt}, %{status: :contradicted} = observation) do
    {:error,
     %{
       code: :postcondition_contradicted,
       detail:
         "independent post-state observation contradicted the actuator's success report; " <>
           "the contradiction is receipted and has no completed standing",
       postcondition: observation,
       receipt: receipt
     }}
  end

  def consequence_result(result, _observation), do: result

  @doc "Telemetry metadata for `[:ash_a2a, :command_bus, :postcondition]`."
  @spec telemetry_metadata(observation()) :: map()
  def telemetry_metadata(observation) do
    %{
      outcome: observation.status,
      reason: observation.reason,
      postcondition_id: observation.postcondition_id,
      verifier: observation.verifier,
      independent: observation.independent
    }
  end

  # --- internals -------------------------------------------------------------

  defp judge(pc, {:unverified, reason}, _counterfactual),
    do: observation(:unverified, reason_atom(reason), pc, nil, %{"detail" => to_string(reason)})

  defp judge(pc, {status, evidence}, {status, _}),
    do: observation(status, nil, pc, true, evidence)

  defp judge(pc, {status, evidence}, counterfactual) do
    observation(:unverified, :verifier_not_independent, pc, false, %{
      "verdict_under_actuator_report" => Atom.to_string(status),
      "verdict_under_counterfactual_report" => verdict_name(counterfactual),
      "actual_evidence" => evidence
    })
  end

  defp observation(status, reason, pc, independent, evidence) do
    %{
      status: status,
      reason: reason,
      postcondition_id: pc && pc.id,
      verifier: pc && inspect(pc.verifier),
      independent: independent,
      evidence: evidence
    }
  end

  defp success_claim?({:reply, _}), do: true
  defp success_claim?(_), do: false

  # A failure report the actuator did not make. Deliberately not a refusal
  # code: it exists only to hold post-state fixed while the report changes.
  defp counterfactual_probe(%Probe{} = probe),
    do: %{probe | actuator_report: {:error, %{reason: :counterfactual_failure_report}}}

  # Separately spawned process: the verifier shares no process state with the
  # dispatch, and a crash/timeout is an observation, never a verdict.
  defp run_isolated(verifier, expect, probe, timeout) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        verdict =
          try do
            normalize(verifier.verify(expect, probe))
          rescue
            exception -> {:unverified, "verifier_raised: " <> Exception.message(exception)}
          catch
            kind, reason -> {:unverified, "verifier_#{kind}: #{inspect(reason, limit: 5)}"}
          end

        send(parent, {ref, verdict})
      end)

    receive do
      {^ref, verdict} ->
        Process.demonitor(monitor, [:flush])
        verdict

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:unverified, "verifier_crashed: #{inspect(reason, limit: 5)}"}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:unverified, :verifier_timeout}
    end
  end

  defp normalize({status, evidence})
       when status in [:verified, :contradicted] and is_map(evidence),
       do: {status, evidence}

  defp normalize({:unverified, reason}) when is_atom(reason) or is_binary(reason),
    do: {:unverified, reason}

  defp normalize(other),
    do: {:unverified, "verifier_invalid_verdict: #{inspect(other, limit: 5)}"}

  defp reason_atom(reason) when is_atom(reason), do: reason
  defp reason_atom("verifier_raised" <> _), do: :verifier_raised
  defp reason_atom("verifier_crashed" <> _), do: :verifier_crashed
  defp reason_atom("verifier_invalid_verdict" <> _), do: :verifier_invalid_verdict
  defp reason_atom("verifier_" <> _), do: :verifier_raised
  defp reason_atom(_), do: :verifier_unverified

  defp verdict_name({status, _}) when is_atom(status), do: Atom.to_string(status)
end
