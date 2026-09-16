defmodule AshA2A.Chicago.Fixtures.ReceiptBindingAttestation do
  @moduledoc """
  Shared, real fixtures for the Gate 9 receipt-binding court
  (`AshA2A.Chicago.Courts.ReceiptBinding`, `CHI-RECEIPT`) and the attestation
  court (`AshA2A.Chicago.Courts.Attestation`, `SA2A-ATTEST`), RFC-SA2A-002
  §24, §40, §72, §128.

  Nothing here replaces a component under qualification:

    * receipts come from the real `AshA2A.CommandBus.run/4` over the real ETS
      `AshA2A.Chicago.Fixtures.Postcondition.Ledger` (reused from Gate 8) with
      a real `AshA2A.ReceiptStore.Memory` and a real independent
      `LedgerVerifier` postcondition, read back from the store by command id;
    * receipts "at rest" are real `:erlang.term_to_binary/1` files in the run's
      evidence directory; a tamper rewrites the decoded term and the file, and
      the consumer reads the bytes back (`persist!/3`, `read_back!/1`);
    * the MAC key is environment configuration (`with_key/2` sets and restores
      `:ash_a2a, :receipt_binding_key`), i.e. fault injection around the real
      binding, not a replacement for it (§10).

  `mappings/0` admits the SUT boundary telemetry both courts read. Both courts
  declare it; `AshA2A.Chicago.Runner.ocel_mappings/1` admits a shared mapping
  once.
  """

  alias AshA2A.{Authority, Command, CommandBus, Identity, Postcondition, Receipt, SemanticSubject}
  alias AshA2A.Chicago.Fixtures.Postcondition, as: Ledgers
  alias AshA2A.Chicago.Fixtures.Postcondition.{Ledger, LedgerVerifier}
  alias AshA2A.Chicago.Ocel.Mapping

  @doc "OCEL mappings for the receipt-binding, standing, attestation and evidence-class boundaries."
  @spec mappings() :: [Mapping.t()]
  def mappings do
    receipt_objects = fn _m, meta ->
      [
        {"receipt", meta[:receipt_id], "receipt"},
        {"command", meta[:command_id], "command"},
        {"capability", meta[:capability_id], "capability"}
      ]
    end

    evidence_objects = fn _m, meta ->
      [
        {"evidence_class", meta[:chain_digest], "result"},
        {"evidence_class", meta[:prior_chain_digest], "prior"},
        {"evidence", meta[:offered_evidence_digest], "offered"}
      ]
    end

    [
      Mapping.new!(
        event: [:ash_a2a, :receipt, :binding, :bind],
        activity: "receipt.binding.bind",
        source: __MODULE__,
        objects: receipt_objects,
        attributes: fn _m, meta -> Map.take(meta, [:stage, :outcome, :code, :keyed, :links]) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :receipt, :binding, :verify],
        activity: "receipt.binding.verify",
        source: __MODULE__,
        objects: receipt_objects,
        attributes: fn _m, meta ->
          Map.take(meta, [:outcome, :code, :fields, :stage, :keyed, :key_configured])
        end
      ),
      Mapping.new!(
        event: [:ash_a2a, :semantic, :standing, :transition],
        activity: "semantic.standing.transition",
        source: __MODULE__,
        objects: fn _m, meta -> [{"envelope", meta[:envelope_id], "envelope"}] end,
        attributes: fn _m, meta ->
          Map.take(meta, [:from, :to, :outcome, :code, :forbidden_inference_sources])
        end
      ),
      Mapping.new!(
        event: [:ash_a2a, :evidence, :promote],
        activity: "evidence.promote",
        source: __MODULE__,
        objects: evidence_objects,
        attributes: fn _m, meta -> Map.take(meta, [:from, :to, :outcome, :code]) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :evidence, :assert],
        activity: "evidence.assert",
        source: __MODULE__,
        objects: evidence_objects,
        attributes: fn _m, meta -> Map.take(meta, [:from, :to, :outcome, :code]) end
      )
    ] ++
      for decision <- [:build, :verify] do
        Mapping.new!(
          event: [:ash_a2a, :attestation, decision],
          activity: "attestation.#{decision}",
          source: __MODULE__,
          objects: fn _m, meta ->
            Enum.map(List.wrap(meta[:receipt_ids]), &{"receipt", &1, "attested"})
          end,
          attributes: fn _m, meta ->
            Map.take(meta, [
              :outcome,
              :code,
              :field,
              :receipts,
              :receipt_binding,
              :binding_keyed,
              :evidence_class
            ])
          end
        )
      end
  end

  @doc "`sha256:` digest of a seed, in the `AshA2A.SemanticSubject` format."
  @spec sha(String.t()) :: String.t()
  def sha(seed), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

  @doc """
  Runs `fun.(store_opts)` against a fresh, real `AshA2A.ReceiptStore.Memory`.
  """
  @spec with_store((keyword() -> result)) :: result when result: var
  def with_store(fun) do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)

    try do
      fun.(name: name)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  @doc """
  Runs `fun` with `:ash_a2a, :receipt_binding_key` set to `key` (`nil`
  deletes it), restoring the previous value afterwards.
  """
  @spec with_key(binary() | nil, (-> result)) :: result when result: var
  def with_key(key, fun) do
    previous = Application.fetch_env(:ash_a2a, :receipt_binding_key)

    if key,
      do: Application.put_env(:ash_a2a, :receipt_binding_key, key),
      else: Application.delete_env(:ash_a2a, :receipt_binding_key)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:ash_a2a, :receipt_binding_key, value)
        :error -> Application.delete_env(:ash_a2a, :receipt_binding_key)
      end
    end
  end

  @doc """
  One real consequence-bearing execution through `AshA2A.CommandBus.run/4`
  with every §40 identity field populated (actor, semantic subject,
  authority grant with constraints, plan digest, idempotency identity,
  intended effect) and an independent `LedgerVerifier` postcondition.

  `action` is `:honest_write` (verified, completed) or `:lying_write`
  (contradicted). Returns `%{receipt: store read-back, reply: run/4 return,
  key: ledger key}`.
  """
  @spec execute(String.t(), atom(), keyword()) :: %{
          receipt: Receipt.t() | nil,
          reply: term(),
          key: String.t()
        }
  def execute(tag, action, store_opts) when action in [:honest_write, :lying_write] do
    key = "#{tag}-#{System.unique_integer([:positive])}"
    capability = Ledgers.capability(action)
    principal = Identity.principal("chicago-receipt-subject")

    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: sha("graph:" <> key),
        projection_digest: sha("projection:" <> key),
        manufacturer_digest: sha("manufacturer:" <> key)
      )

    command =
      Command.new(capability,
        command_id: "chicago-receipt-" <> key,
        agent_id: "chicago-receipt-agent",
        principal_id: principal,
        semantic_subject: subject,
        authority:
          Authority.new(principal, capability,
            token_id: "tok-" <> key,
            constraints: %{scope: "ledger:write"}
          ),
        input: %{key: key, value: "X"}
      )

    message = A2A.Message.new_user([A2A.Part.Data.new(%{"key" => key, "value" => "X"})])

    reply =
      CommandBus.run(command, message, Ledger,
        store_opts: store_opts,
        plan_digest: sha("plan:" <> key),
        postcondition: %Postcondition{
          id: "ledger.value_persisted",
          verifier: LedgerVerifier,
          expect: %{key: key, value: "X"}
        }
      )

    receipt =
      case AshA2A.ReceiptStore.Memory.fetch(command.command_id, store_opts) do
        {:ok, %Receipt{} = receipt} -> receipt
        :error -> nil
      end

    %{receipt: receipt, reply: reply, key: key}
  end

  @doc "Writes `receipt` as ETF bytes under `dir/receipt_binding/<name>.etf`; returns the path."
  @spec persist!(Path.t(), String.t(), term()) :: Path.t()
  def persist!(dir, name, receipt) do
    path = Path.join([dir, "receipt_binding", name <> ".etf"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(receipt))
    path
  end

  @doc "Reads a persisted receipt back from its bytes on disk (the consumer's read path)."
  @spec read_back!(Path.t()) :: term()
  def read_back!(path), do: path |> File.read!() |> :erlang.binary_to_term()
end
