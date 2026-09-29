defmodule AshA2A.ReceiptStore do
  @moduledoc """
  Behaviour for replay-safe command receipt storage.

  A store owns the atomic command-id claim. Implementations must distinguish
  same-id/same-fingerprint replay from same-id/different-fingerprint conflict.

  "Replay" here means idempotent command re-submission / command dedup (the
  Stripe-style idempotency-key pattern): a claim keys on a single
  `command_id` and compares it against a content-hash `fingerprint` computed
  from that one command (`AshA2A.Command.fingerprint/1`). This is distinct
  from process-mining token-replay / conformance checking (Rozinat & van der
  Aalst, "Conformance checking of processes based on monitoring real
  behavior," Information Systems 33(1), 2008), which replays an ordered
  trace of events sharing a case identifier through a reference process
  model -- no trace or process model is involved in this claim/commit path.

  ## Actuation claims (RFC-SA2A-001 S55)

  `claim/2` keys on the *request* (`command_id`). S55 additionally requires
  detecting a previously prepared or executed **effect** before repeating it,
  which a fresh `command_id` on a client retry defeats. The three optional
  callbacks below add that second index, keyed on
  `AshA2A.Actuation.identity/2`'s effect-derived actuation id:

    * `c:claim_actuation/3` -- called by `AshA2A.CommandBus` *after* the
      command claim succeeds and *before* DO, for `:change`/`:external_do`
      only. `{:duplicate, receipt}` means this exact effect already completed
      under some other command id, and the bus returns that receipt instead of
      crossing the boundary a second time.
    * `c:commit_actuation/3` -- records the finalized receipt against the
      actuation id once the outcome is observed.
    * `c:release_actuation/2` -- drops a prepared-but-never-executed actuation
      claim, so a refusal after the claim does not permanently wedge the
      effect.

  A store that does not implement them is unchanged: `AshA2A.CommandBus`
  checks `function_exported?/3` and skips actuation claiming entirely, which is
  why `AshA2A.ReceiptStore`'s existing three-callback contract still describes
  a complete, working store.
  """

  alias AshA2A.{Actuation, Command, Receipt}

  @type claim_result ::
          {:execute, AshA2A.Identity.t()}
          | {:replay, Receipt.t()}
          | {:error, :command_conflict | :in_flight}

  @typedoc """
  Result of claiming an actuation identity.

    * `:proceed` -- no prior prepared or executed record for this effect
    * `{:duplicate, receipt}` -- this effect already completed; the receipt is
      the prior outcome and MUST be returned rather than re-actuating
    * `{:error, :actuation_in_flight}` -- another claimant prepared this effect
      and has not finished; refuse rather than double-actuate
    * `{:error, :actuation_store_unavailable}` -- the effect-level claim store
      could not be consulted; callers enforcing idempotency must refuse before DO.
    * `{:error, :actuation_conflict}` -- the same actuation id is held with a
      different idempotency key, which means two callers disagree about what
      the external token for this effect is
  """
  @type actuation_claim_result ::
          :proceed
          | {:duplicate, Receipt.t()}
          | {:error, :actuation_in_flight | :actuation_conflict | :actuation_store_unavailable}

  @callback claim(Command.t(), keyword()) :: claim_result()
  @callback commit(Receipt.t(), keyword()) :: :ok
  @callback fetch(AshA2A.Identity.t(), keyword()) :: {:ok, Receipt.t()} | :error

  @callback claim_actuation(Actuation.t(), Command.t(), keyword()) :: actuation_claim_result()
  @callback commit_actuation(Actuation.t(), Receipt.t(), keyword()) :: :ok | {:error, term()}
  @callback release_actuation(Actuation.t(), keyword()) :: :ok

  @doc """
  Fencing check (finding R4): `:ok` when `execution_id` still holds the claim
  for `command_id`, `{:error, :stale_execution}` when the claim was reclaimed
  by another execution. `AshA2A.CommandBus` calls it after preparing the
  receipt anchor and before DO, when the store exports it.
  """
  @callback confirm_claim(AshA2A.Identity.t(), AshA2A.Identity.t(), keyword()) ::
              :ok | {:error, term()}

  @optional_callbacks claim_actuation: 3,
                      commit_actuation: 3,
                      release_actuation: 2,
                      confirm_claim: 3

  @doc """
  True when `store` declares itself durable by exporting `durable?/0`
  returning `true` (a convention, not a callback, so existing stores that
  already export it need no `@impl`).
  """
  @spec durable?(module()) :: boolean()
  def durable?(store) when is_atom(store) do
    Code.ensure_loaded?(store) and function_exported?(store, :durable?, 0) and store.durable?()
  end

  @doc """
  Boot-time durability check for the at-most-once machinery (findings R2,
  R12, PERF-09). Intended to be called from `AshA2A.Application.start/2`
  before the supervision tree starts; returns `:ok` or the first violation.

  Inputs are read from `opts`, falling back to application env:

    * `:production` (`config :ash_a2a, :production`, default `false`; forced
      on under the `:strict` `AshA2A.SecurityProfile`)
    * `:receipt_store` (`config :ash_a2a, :receipt_store`, default
      `AshA2A.ReceiptStore.Memory`) and whether it was set explicitly
    * `:receipt_outbox_dir`, `:receipt_store_ekv_opts[:data_dir]`,
      `:receipt_store_ekv_opts[:cluster_size]`, `:kill_switch_path`
    * `:allow_memory_receipt_store` (escape hatch, default `false`)

  Rules (all fail closed):

    1. A durable store with the outbox journal unset or under
       `System.tmp_dir!/0` -> `{:error, {:non_durable_outbox_dir, dir}}`: the
       outbox anchor is the at-most-once proof and must live as long as the
       claim store.
    2. `Ekv` with its `:data_dir` unset or under the tmp dir ->
       `{:error, {:non_durable_receipt_store_data_dir, dir}}`.
    3. In production: the receipt store must be set explicitly
       (`{:error, :receipt_store_not_configured}`), must not be `Memory`
       unless allowed (`{:error, {:non_durable_receipt_store, Memory}}`),
       EKV `cluster_size` must be >= 3
       (`{:error, {:insufficient_cluster_size, n}}`), and `:kill_switch_path`
       must be set outside the tmp dir
       (`{:error, {:non_durable_kill_switch_path, path}}`).
  """
  @spec boot_check(keyword()) :: :ok | {:error, term()}
  def boot_check(opts \\ []) do
    env = fn key, default ->
      Keyword.get(opts, key, Application.get_env(:ash_a2a, key, default))
    end

    # RFC-SA2A-007: the :strict profile implies the production rule set.
    production? = env.(:production, false) == true or AshA2A.SecurityProfile.strict?()

    explicit_store =
      Keyword.get(opts, :receipt_store, Application.get_env(:ash_a2a, :receipt_store))

    store = explicit_store || AshA2A.ReceiptStore.Memory
    outbox_dir = env.(:receipt_outbox_dir, nil)
    ekv_opts = env.(:receipt_store_ekv_opts, [])
    kill_switch_path = env.(:kill_switch_path, nil)
    allow_memory? = env.(:allow_memory_receipt_store, false) == true

    cond do
      production? and is_nil(explicit_store) ->
        {:error, :receipt_store_not_configured}

      production? and store == AshA2A.ReceiptStore.Memory and not allow_memory? ->
        {:error, {:non_durable_receipt_store, store}}

      durable?(store) and not durable_path?(outbox_dir) ->
        {:error, {:non_durable_outbox_dir, outbox_dir}}

      store == AshA2A.ReceiptStore.Ekv and not durable_path?(Keyword.get(ekv_opts, :data_dir)) ->
        {:error, {:non_durable_receipt_store_data_dir, Keyword.get(ekv_opts, :data_dir)}}

      production? and store == AshA2A.ReceiptStore.Ekv and
          Keyword.get(ekv_opts, :cluster_size, 1) < 3 ->
        {:error, {:insufficient_cluster_size, Keyword.get(ekv_opts, :cluster_size, 1)}}

      production? and not durable_path?(kill_switch_path) ->
        {:error, {:non_durable_kill_switch_path, kill_switch_path}}

      true ->
        :ok
    end
  end

  @doc "True when `path` is set and does not live under `System.tmp_dir!/0`."
  @spec durable_path?(term()) :: boolean()
  def durable_path?(path) when is_binary(path) and path != "" do
    expanded = Path.expand(path)
    tmp = System.tmp_dir!() |> Path.expand()
    tmp_real = resolve(tmp)

    not Enum.any?([tmp, tmp_real, "/tmp", "/private/tmp", "/var/tmp"], fn root ->
      expanded == root or String.starts_with?(expanded, root <> "/") or
        resolve(expanded) == root or String.starts_with?(resolve(expanded), root <> "/")
    end)
  end

  def durable_path?(_path), do: false

  # Resolves a leading symlinked prefix (macOS `/var` -> `/private/var`) so a
  # tmp dir cannot be laundered through a symlink spelling.
  defp resolve(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} -> Path.expand(List.to_string(target), Path.dirname(path))
      _ -> resolve_parent(path)
    end
  end

  defp resolve_parent("/"), do: "/"

  defp resolve_parent(path) do
    parent = Path.dirname(path)

    if parent == path,
      do: path,
      else: Path.join(resolve(parent), Path.basename(path))
  end
end
